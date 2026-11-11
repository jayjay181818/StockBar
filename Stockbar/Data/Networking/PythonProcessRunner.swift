import Foundation

struct PythonProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

protocol PythonProcessRunning: Sendable {
    func run(arguments: [String], timeoutSeconds: TimeInterval, logContext: String) async throws -> PythonProcessResult
}

actor PythonProcessRunner: PythonProcessRunning {
    /// Grace period between SIGTERM and SIGKILL when a run times out or is cancelled.
    private static let terminationGraceNanoseconds: UInt64 = 5_000_000_000

    /// A pinned configuration (tests), or nil to rebuild the configuration for every run so
    /// interpreter, config-file, API-key and quote-cache settings changed after launch take effect.
    private let pinnedConfig: PythonConfiguration?
    private let providerPolicy: StockbarProviderAccessPolicy
    /// Serves bridge script requests from a running worker; nil runs every request as its own process.
    private let workerPool: PythonWorkerPool?
    private let logger = Logger.shared

    init(
        config: PythonConfiguration? = nil,
        providerPolicy: StockbarProviderAccessPolicy = .current,
        workerPool: PythonWorkerPool? = .shared
    ) {
        self.pinnedConfig = config
        self.providerPolicy = providerPolicy
        self.workerPool = workerPool
    }

    func run(
        arguments: [String],
        timeoutSeconds: TimeInterval,
        logContext: String
    ) async throws -> PythonProcessResult {
        try providerPolicy.authorize(.python)
        try Task.checkCancellation()

        let config = pinnedConfig ?? PythonConfiguration.load(includingAPIKeys: true)
        if let workerPool, let request = PythonWorkerRequest(arguments: arguments) {
            do {
                if let result = try await workerPool.run(
                    request, config: config, timeoutSeconds: timeoutSeconds, logContext: logContext
                ) {
                    return result
                }
            } catch PythonWorkerError.unavailable(let reason) {
                // A broken worker must not cost the request: run it directly.
                await logger.warning("\(logContext): Python worker unavailable (\(reason)); running the script directly")
                try Task.checkCancellation()
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        process.arguments = arguments
        process.environment = PythonConfiguration.childEnvironment(adding: config.environment)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBuffer = ProcessDataBuffer()
        let errorBuffer = ProcessDataBuffer()
        let control = ProcessRunControl(process: process)
        let logger = self.logger

        defer { control.cancelTimeout() }

        let result: PythonProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard control.install(continuation) else { return }

                // Each pipe is read to EOF by exactly one reader, so chunks can
                // never be appended out of order, and nothing is left unread
                // when the process exits (a multi-symbol --batch-ohlc response
                // is easily megabytes).
                let readersDone = DispatchGroup()
                readersDone.enter()
                readersDone.enter()

                process.terminationHandler = { proc in
                    let status = proc.terminationStatus
                    readersDone.notify(queue: .global(qos: .utility)) {
                        control.finish(.success(PythonProcessResult(
                            stdout: outputBuffer.contents,
                            stderr: errorBuffer.contents,
                            exitCode: status
                        )))
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    control.finish(.failure(error))
                    return
                }

                Self.startReader(outputPipe.fileHandleForReading, into: outputBuffer, group: readersDone)
                Self.startReader(errorPipe.fileHandleForReading, into: errorBuffer, group: readersDone)

                // A cancellation that raced the launch must still stop the child.
                if control.markLaunched() {
                    Task { await Self.terminateWithGrace(process, logContext: logContext, logger: logger, reason: "cancelled") }
                    return
                }

                let timeoutTask = Task {
                    let timeoutNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled, process.isRunning else { return }

                    control.markTimedOut()
                    await Self.terminateWithGrace(process, logContext: logContext, logger: logger, reason: "timeout reached")
                }
                control.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            control.cancel { [logContext, logger] process in
                Task { await Self.terminateWithGrace(process, logContext: logContext, logger: logger, reason: "cancelled") }
            }
        }

        if control.didTimeOut {
            throw NetworkError.timeout("\(logContext) timed out after \(Int(timeoutSeconds))s")
        }

        return result
    }

    /// Drains `handle` sequentially on its own queue until EOF.
    private static func startReader(_ handle: FileHandle, into buffer: ProcessDataBuffer, group: DispatchGroup) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            group.leave()
        }
    }

    /// SIGTERM, then SIGKILL after the grace period.
    ///
    /// SIGTERM alone is not enough: a child blocked in a syscall inside a C
    /// extension can ignore it, in which case terminationHandler never fires
    /// and the caller would hang forever despite the timeout.
    private static func terminateWithGrace(
        _ process: Process,
        logContext: String,
        logger: Logger,
        reason: String
    ) async {
        guard process.isRunning else { return }
        await logger.warning("\(logContext) \(reason), terminating process")
        process.terminate()

        try? await Task.sleep(nanoseconds: terminationGraceNanoseconds)
        if process.isRunning {
            await logger.error("\(logContext) ignored SIGTERM, sending SIGKILL")
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class ProcessDataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Lock-protected state shared by the launch, termination, timeout and
/// cancellation paths of one process run.
private final class ProcessRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<PythonProcessResult, Error>?
    private var finished = false
    private var cancelled = false
    private var launched = false
    private var timedOut = false
    private var timeoutTask: Task<Void, Never>?

    init(process: Process) {
        self.process = process
    }

    /// Stores the continuation. If the task was already cancelled, resumes it
    /// with `CancellationError` and returns false so the process is never launched.
    func install(_ continuation: CheckedContinuation<PythonProcessResult, Error>) -> Bool {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Returns true when cancellation arrived before the launch completed.
    func markLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launched = true
        return cancelled
    }

    func finish(_ result: Result<PythonProcessResult, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    /// Cancels the run: stops the child (via `terminate`) and resumes the caller
    /// immediately with `CancellationError`.
    func cancel(terminate: (Process) -> Void) {
        lock.lock()
        cancelled = true
        let shouldTerminate = launched && !finished
        let task = timeoutTask
        lock.unlock()

        task?.cancel()
        if shouldTerminate {
            terminate(process)
        }
        finish(.failure(CancellationError()))
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        timeoutTask = task
        let alreadyDone = finished
        lock.unlock()
        if alreadyDone { task.cancel() }
    }

    func cancelTimeout() {
        lock.lock()
        let task = timeoutTask
        lock.unlock()
        task?.cancel()
    }
}
