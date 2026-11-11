import Foundation
import Observation

/// Creates Stockbar's own Python environment by running the bundled
/// `setup_python_env.sh`, and reports which interpreter the bridge uses.
///
/// The bridge reloads `PythonConfiguration` for every request, so a new
/// environment is used from the next refresh without a relaunch.
@MainActor
@Observable
final class PythonEnvironmentSetup {
    static let shared = PythonEnvironmentSetup()

    enum State: Equatable {
        case idle
        /// Running; the latest progress line from the script.
        case running(String)
        case succeeded
        /// The script's last output lines, which explain what went wrong.
        case failed(String)
    }

    enum InterpreterSource: Equatable {
        /// The `pythonInterpreterPath` setting.
        case configured
        /// Stockbar's own environment.
        case stockbar
        /// Stockbar's own environment, not set up yet.
        case notSetUp
    }

    private(set) var state: State = .idle
    private(set) var interpreterPath = ""
    private(set) var interpreterSource: InterpreterSource = .notSetUp
    /// "Python 3.13.1", or nil while checking or when the interpreter cannot run.
    private(set) var interpreterVersion: String?
    private(set) var isCheckingVersion = false

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ObservationIgnored private let providerPolicy: StockbarProviderAccessPolicy
    @ObservationIgnored private let scriptPath: String?
    @ObservationIgnored private let requirementsPath: String?
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private let timeoutSeconds: TimeInterval
    @ObservationIgnored private let logger = Logger.shared

    init(
        providerPolicy: StockbarProviderAccessPolicy = .current,
        scriptPath: String? = Bundle.main.path(forResource: "setup_python_env", ofType: "sh"),
        requirementsPath: String? = Bundle.main.path(forResource: "requirements", ofType: "txt"),
        supportDirectory: URL = StockbarRuntimeStorage.stockbarApplicationSupportDirectory(),
        timeoutSeconds: TimeInterval = 15 * 60
    ) {
        self.providerPolicy = providerPolicy
        self.scriptPath = scriptPath
        self.requirementsPath = requirementsPath
        self.supportDirectory = supportDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    nonisolated static func source(
        configured: String?,
        managedInterpreter: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> InterpreterSource {
        if let configured, !configured.isEmpty { return .configured }
        return isExecutable(managedInterpreter) ? .stockbar : .notSetUp
    }

    /// Reads the interpreter the bridge would use now, and its version.
    func refreshInterpreterInfo() async {
        let config = PythonConfiguration.load()
        interpreterPath = config.interpreterPath
        interpreterSource = Self.source(
            configured: StockbarRuntimeStorage.userDefaults.string(forKey: "pythonInterpreterPath"),
            managedInterpreter: PythonConfiguration.managedInterpreterPath()
        )
        interpreterVersion = nil
        isCheckingVersion = true
        defer { isCheckingVersion = false }
        let runner = PythonProcessRunner(config: config, providerPolicy: providerPolicy, workerPool: nil)
        guard let result = try? await runner.run(arguments: ["--version"], timeoutSeconds: 10, logContext: "python version"),
              result.exitCode == 0 else { return }
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        interpreterVersion = String(bytes: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the environment. Does nothing while a build is running.
    func setUp() async {
        guard !isRunning else { return }
        state = .running("Starting…")
        do {
            try providerPolicy.authorize(.python)
            guard let scriptPath, let requirementsPath else {
                throw SetupError("The setup script is missing from the app bundle.")
            }
            let output = try await runScript(scriptPath, requirementsPath: requirementsPath)
            await logger.info("Python environment set up: \(output.last ?? "")")
            state = .succeeded
            // A rebuild keeps the same interpreter path, so retire workers
            // still running the previous environment.
            await PythonWorkerPool.shared.retireAllWorkers()
        } catch {
            let message = (error as? SetupError)?.message ?? error.localizedDescription
            await logger.error("Python environment setup failed: \(message)")
            state = .failed(message)
        }
        await refreshInterpreterInfo()
    }

    private struct SetupError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Runs the script, publishing each output line as progress. Returns the
    /// output lines; throws with the last lines when the script fails.
    private func runScript(_ scriptPath: String, requirementsPath: String) async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        var environment = ProcessInfo.processInfo.environment
        environment["STOCKBAR_REQUIREMENTS"] = requirementsPath
        environment["STOCKBAR_SUPPORT_DIR"] = supportDirectory.path
        // Test-only overrides of the uv download and its checksum; the app
        // never honours them from whatever environment launched it.
        environment["STOCKBAR_UV_URL"] = nil
        environment["STOCKBAR_UV_SHA256"] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lines = OutputLines()
        let reader = pipe.fileHandleForReading
        let finished: Task<Void, Never> = Task.detached { [weak self] in
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(bytes: pending[pending.startIndex..<newline], encoding: .utf8)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    pending = Data(pending[pending.index(after: newline)...])
                    guard !line.isEmpty else { continue }
                    await lines.append(line)
                    await self?.showProgress(line)
                }
            }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: SetupError("Could not start the setup script: \(error.localizedDescription)"))
                return
            }
            let timeout = timeoutSeconds
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
        }
        await finished.value

        let output = await lines.all
        guard status == 0 else {
            let detail = output.suffix(2).joined(separator: " ")
            throw SetupError(detail.isEmpty ? "The setup script stopped with status \(status)." : detail)
        }
        return output
    }

    private func showProgress(_ line: String) {
        guard isRunning else { return }
        state = .running(line)
    }
}

private actor OutputLines {
    private(set) var all: [String] = []
    func append(_ line: String) { all.append(line) }
}
