import Darwin
import Foundation

/// A bridge script request that a long-lived worker can serve.
struct PythonWorkerRequest: Equatable, Sendable {
    static let workerScriptName = "stockbar_worker.py"
    static let workerScripts: Set<String> = ["get_stock_data.py", "get_ohlc_data.py"]

    let workerPath: String
    let script: String
    let arguments: [String]

    /// Recognises `[<dir>/get_stock_data.py, args...]` when `stockbar_worker.py`
    /// sits next to the script. Anything else (`-c` snippets, test executables)
    /// returns nil and runs as a one-off process.
    init?(arguments: [String], fileManager: FileManager = .default) {
        guard let scriptPath = arguments.first else { return nil }
        let scriptURL = URL(fileURLWithPath: scriptPath)
        guard Self.workerScripts.contains(scriptURL.lastPathComponent) else { return nil }
        let workerURL = scriptURL.deletingLastPathComponent().appendingPathComponent(Self.workerScriptName)
        guard fileManager.fileExists(atPath: workerURL.path) else { return nil }
        self.workerPath = workerURL.path
        self.script = scriptURL.lastPathComponent
        self.arguments = Array(arguments.dropFirst())
    }
}

enum PythonWorkerError: Error, Equatable {
    /// The worker could not start or exited before replying.
    case unavailable(String)
}

/// Keeps `stockbar_worker.py` processes running so bridge requests skip
/// interpreter start-up and the yfinance/pandas imports (about half a second
/// per request).
///
/// Requests never queue behind each other: when every worker is busy, `run`
/// returns nil and the caller starts a one-off process as before. A worker is
/// replaced when the interpreter, worker script or environment changes, is
/// discarded after a timeout or cancellation, and exits after the idle
/// timeout unused or when the app quits (its stdin closes).
actor PythonWorkerPool {
    /// The app's pool. It reads the setting each time it looks for idle
    /// workers, so a change needs no restart.
    static let shared = PythonWorkerPool(idleTimeout: {
        idleTimeout(quitWhenIdle: quitsWhenIdle(in: StockbarRuntimeStorage.userDefaults))
    })

    /// Settings → Advanced → Memory → Quit Python Helper When Idle. On
    /// unless it was turned off.
    static let quitWhenIdleKey = "pythonHelper.quitWhenIdle"
    static let quitWhenIdleDefault = true

    /// The setting, or its default when it was never changed.
    static func quitsWhenIdle(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: quitWhenIdleKey) == nil ? quitWhenIdleDefault : defaults.bool(forKey: quitWhenIdleKey)
    }

    /// How long a worker nobody is using is kept. An idle worker holds about
    /// 70 MB.
    ///
    /// Off, it is kept for 15 minutes, so at a refresh interval shorter than
    /// that the next refresh finds it running. On, it is kept for one burst
    /// of work (a refresh pass, or a backfill whose requests are seconds
    /// apart) and each later pass starts a new one, about a third of a second
    /// of CPU. 90 seconds outlasts the shortest refresh interval, one minute,
    /// which therefore reuses its worker either way while its markets are
    /// open. A closed London or US listing is refetched every 30 minutes
    /// (`RefreshService.closedMarketFreshness`), longer than either timeout.
    static func idleTimeout(quitWhenIdle: Bool) -> Duration {
        quitWhenIdle ? .seconds(90) : .seconds(15 * 60)
    }

    private let maxWorkers: Int
    private let readIdleTimeout: @Sendable () -> Duration
    private let logger = Logger.shared
    private var idleWorkers: [(worker: PythonWorker, lastUsed: ContinuousClock.Instant)] = []
    private var busyCount = 0
    private var generation = 0
    private var reaper: Task<Void, Never>?
    /// A setup whose worker failed is skipped for `failureBackoff`, so a broken
    /// interpreter or worker script does not double the cost of every request.
    private let failureBackoff: Duration
    private var failedUntil: [PythonWorker.Key: ContinuousClock.Instant] = [:]

    init(
        maxWorkers: Int = 2,
        idleTimeout: @escaping @Sendable () -> Duration = { PythonWorkerPool.idleTimeout(quitWhenIdle: false) },
        failureBackoff: Duration = .seconds(5 * 60)
    ) {
        self.maxWorkers = maxWorkers
        self.readIdleTimeout = idleTimeout
        self.failureBackoff = failureBackoff
    }

    /// Runs `request` on a worker, or returns nil when all workers are busy.
    func run(
        _ request: PythonWorkerRequest,
        config: PythonConfiguration,
        timeoutSeconds: TimeInterval,
        logContext: String
    ) async throws -> PythonProcessResult? {
        let key = PythonWorker.Key(config: config, workerPath: request.workerPath)
        guard let worker = try checkOut(key) else { return nil }
        let startedGeneration = generation
        do {
            let result = try await worker.send(
                script: request.script,
                arguments: request.arguments,
                timeoutSeconds: timeoutSeconds,
                logContext: logContext
            )
            if startedGeneration == generation {
                checkIn(worker)
            } else {
                // The environment was rebuilt while this request ran; the worker
                // still has the old packages loaded.
                busyCount -= 1
                worker.stop()
            }
            return result
        } catch {
            busyCount -= 1
            worker.stop()
            if error is PythonWorkerError { failedUntil[key] = .now + failureBackoff }
            throw error
        }
    }

    /// How long an unused worker is kept, as of now.
    var idleTimeout: Duration { readIdleTimeout() }

    /// Live worker processes, idle or busy (tests).
    var workerCount: Int { idleWorkers.count + busyCount }

    /// Stops idle workers now and busy ones as they finish, after the Python
    /// environment was rebuilt.
    func retireAllWorkers() {
        generation += 1
        stopIdleWorkers()
    }

    /// Applies a changed idle timeout now. The pool's idle check may be asleep
    /// for a quarter of the old one.
    func idleTimeoutChanged() {
        reaper?.cancel()
        reaper = nil
        reapIdleWorkers { !$0.isRunning }
        if !idleWorkers.isEmpty { startReaperIfNeeded() }
    }

    /// Stops every idle worker (tests and shutdown).
    func stopIdleWorkers() {
        idleWorkers.forEach { $0.worker.stop() }
        idleWorkers.removeAll()
    }

    private func checkOut(_ key: PythonWorker.Key) throws -> PythonWorker? {
        if let until = failedUntil[key] {
            guard until <= .now else { return nil }
            failedUntil[key] = nil
        }
        reapIdleWorkers { $0.isRunning == false || $0.key != key }
        if let index = idleWorkers.lastIndex(where: { $0.worker.key == key }) {
            busyCount += 1
            return idleWorkers.remove(at: index).worker
        }
        guard busyCount + idleWorkers.count < maxWorkers else { return nil }
        let worker: PythonWorker
        do {
            worker = try PythonWorker(key: key, logger: logger)
        } catch {
            failedUntil[key] = .now + failureBackoff
            throw error
        }
        busyCount += 1
        return worker
    }

    private func checkIn(_ worker: PythonWorker) {
        busyCount -= 1
        guard worker.isRunning else { return }
        idleWorkers.append((worker, ContinuousClock.now))
        startReaperIfNeeded()
    }

    private func reapIdleWorkers(where shouldStop: (PythonWorker) -> Bool) {
        let now = ContinuousClock.now
        let timeout = idleTimeout
        idleWorkers.removeAll { entry in
            guard shouldStop(entry.worker) || now - entry.lastUsed >= timeout else { return false }
            entry.worker.stop()
            return true
        }
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            // The interval follows the timeout, which can change between checks.
            while let interval = await self?.reapInterval {
                do { try await Task.sleep(for: interval) } catch { return }
                if await self?.reapAndCheckEmpty() != false { return }
            }
        }
    }

    private var reapInterval: Duration { idleTimeout / 4 }

    /// Stops expired workers; returns true (and ends the reaper) once none are idle.
    private func reapAndCheckEmpty() -> Bool {
        // A reaper that `idleTimeoutChanged` replaced while it was waiting for
        // the pool ends here: `reaper` now holds its successor.
        guard !Task.isCancelled else { return true }
        reapIdleWorkers { !$0.isRunning }
        guard idleWorkers.isEmpty else { return false }
        reaper = nil
        return true
    }
}

/// One `stockbar_worker.py` process serving one request at a time.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`; the pipe
/// readers, termination handler, timeout and cancellation paths all go
/// through it, and the pending continuation is resumed exactly once.
final class PythonWorker: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let interpreterPath: String
        let workerPath: String
        let environment: [String: String]

        init(config: PythonConfiguration, workerPath: String) {
            self.interpreterPath = config.interpreterPath
            self.workerPath = workerPath
            self.environment = config.environment
        }
    }

    private static let terminationGraceNanoseconds: UInt64 = 5_000_000_000

    let key: Key
    private let process = Process()
    private let requestHandle: FileHandle
    private let logger: Logger
    private let lock = NSLock()
    private var nextID = 0
    private var pending: (id: Int, continuation: CheckedContinuation<PythonProcessResult, Error>)?
    private var exited = false
    private var replyBuffer = Data()

    init(key: Key, logger: Logger) throws {
        self.key = key
        self.logger = logger

        process.executableURL = URL(fileURLWithPath: key.interpreterPath)
        process.arguments = [key.workerPath]
        process.environment = PythonConfiguration.childEnvironment(adding: key.environment)

        let requests = Pipe()
        let replies = Pipe()
        let diagnostics = Pipe()
        process.standardInput = requests
        process.standardOutput = replies
        process.standardError = diagnostics
        requestHandle = requests.fileHandleForWriting
        // A write after the worker died must fail, not raise SIGPIPE in the app.
        _ = fcntl(requestHandle.fileDescriptor, F_SETNOSIGPIPE, 1)

        process.terminationHandler = { [weak self] proc in
            self?.didExit(status: proc.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw PythonWorkerError.unavailable("could not launch \(key.interpreterPath): \(error.localizedDescription)")
        }
        startReplyReader(replies.fileHandleForReading)
        startDiagnosticsReader(diagnostics.fileHandleForReading)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !exited && process.isRunning
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func send(
        script: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        logContext: String
    ) async throws -> PythonProcessResult {
        try Task.checkCancellation()
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            nextID += 1
            return nextID
        }()
        var line = try JSONSerialization.data(
            withJSONObject: ["id": id, "script": script, "args": arguments] as [String: Any]
        )
        line.append(0x0A)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.fail(id: id, with: NetworkError.timeout("\(logContext) timed out after \(Int(timeoutSeconds))s")) {
                await self.logger.warning("\(logContext) timeout reached, stopping Python worker")
                self.stop()
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if exited {
                    lock.unlock()
                    continuation.resume(throwing: PythonWorkerError.unavailable("worker exited"))
                    return
                }
                pending = (id, continuation)
                lock.unlock()
                // Cancellation that arrived before the request was registered.
                if Task.isCancelled {
                    if fail(id: id, with: CancellationError()) { stop() }
                    return
                }
                do {
                    try requestHandle.write(contentsOf: line)
                } catch {
                    fail(id: id, with: PythonWorkerError.unavailable("could not send request: \(error.localizedDescription)"))
                }
            }
        } onCancel: { [weak self] in
            guard let self, self.fail(id: id, with: CancellationError()) else { return }
            self.stop()
        }
    }

    /// Closes the worker's stdin so it exits, then SIGTERM and SIGKILL if it
    /// is stuck in a request.
    func stop() {
        try? requestHandle.close()
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        Task.detached {
            try? await Task.sleep(nanoseconds: Self.terminationGraceNanoseconds)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Resumes the pending request with `error` if it is still `id`. Returns
    /// whether it did, so only one of timeout/cancel/exit acts.
    @discardableResult
    private func fail(id: Int, with error: Error) -> Bool {
        lock.lock()
        guard let current = pending, current.id == id else {
            lock.unlock()
            return false
        }
        pending = nil
        lock.unlock()
        current.continuation.resume(throwing: error)
        return true
    }

    private func didExit(status: Int32) {
        lock.lock()
        exited = true
        let current = pending
        pending = nil
        lock.unlock()
        current?.continuation.resume(throwing: PythonWorkerError.unavailable("worker exited with status \(status)"))
    }

    private func startReplyReader(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.didExit(status: -1)
                    return
                }
                self.receive(chunk)
            }
        }
    }

    /// Called only from the reply reader thread, which owns `replyBuffer`.
    private func receive(_ chunk: Data) {
        var searchStart = replyBuffer.endIndex
        replyBuffer.append(chunk)
        while let newline = replyBuffer[searchStart...].firstIndex(of: 0x0A) {
            let line = Data(replyBuffer[replyBuffer.startIndex..<newline])
            replyBuffer = Data(replyBuffer[replyBuffer.index(after: newline)...])
            searchStart = replyBuffer.startIndex
            deliver(line)
        }
    }

    private func deliver(_ line: Data) {
        lock.lock()
        let current = pending
        guard let current else {
            lock.unlock()
            return
        }
        guard let reply = try? JSONDecoder().decode(PythonWorkerReply.self, from: line), reply.id == current.id else {
            lock.unlock()
            // The worker is out of step with its requests; never reuse it.
            if fail(id: current.id, with: PythonWorkerError.unavailable("unreadable reply")) { stop() }
            return
        }
        pending = nil
        lock.unlock()
        current.continuation.resume(returning: PythonProcessResult(
            stdout: Data(reply.stdout.utf8),
            stderr: Data(reply.stderr.utf8),
            exitCode: reply.exitCode
        ))
    }

    /// The worker's own stderr: import-time warnings and crashes. Per-request
    /// diagnostics come back in each reply instead.
    private func startDiagnosticsReader(_ handle: FileHandle) {
        let logger = self.logger
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                let text = (String(bytes: chunk, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !text.contains("NotOpenSSLWarning") else { continue }
                Task { await logger.debug("Python worker: \(text)") }
            }
        }
    }
}

/// One reply line from `stockbar_worker.py`.
private struct PythonWorkerReply: Decodable {
    let id: Int?
    let exitCode: Int32
    let stdout: String
    let stderr: String

    enum CodingKeys: String, CodingKey {
        case id, stdout, stderr
        case exitCode = "exit_code"
    }
}
