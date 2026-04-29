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
    private let executablePath: String
    private let environment: [String: String]
    private let logger = Logger.shared

    init(config: PythonConfiguration = .load()) {
        self.executablePath = config.interpreterPath
        self.environment = config.environment
    }

    func run(
        arguments: [String],
        timeoutSeconds: TimeInterval,
        logContext: String
    ) async throws -> PythonProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = environment
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputBuffer = ProcessDataBuffer()
        let errorBuffer = ProcessDataBuffer()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                outputBuffer.append(chunk)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                errorBuffer.append(chunk)
            }
        }

        let timeoutState = ProcessTimeoutState()
        var timeoutTask: Task<Void, Never>?

        let result: PythonProcessResult = try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ProcessContinuationBox(
                continuation: continuation,
                outputPipe: outputPipe,
                errorPipe: errorPipe
            )

            process.terminationHandler = { proc in
                let remainingOutput = outputPipe.fileHandleForReading.availableData
                if !remainingOutput.isEmpty {
                    outputBuffer.append(remainingOutput)
                }

                let remainingError = errorPipe.fileHandleForReading.availableData
                if !remainingError.isEmpty {
                    errorBuffer.append(remainingError)
                }

                continuationBox.resume(.success(PythonProcessResult(
                    stdout: outputBuffer.contents,
                    stderr: errorBuffer.contents,
                    exitCode: proc.terminationStatus
                )))
            }

            do {
                try process.run()
            } catch {
                continuationBox.resume(.failure(error))
                return
            }

            timeoutTask = Task {
                let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                if process.isRunning {
                    timeoutState.markTimedOut()
                    await logger.warning("\(logContext) timeout reached, terminating process")
                    process.terminate()
                }
            }
        }

        timeoutTask?.cancel()

        if timeoutState.didTimeout {
            throw NetworkError.timeout("\(logContext) timed out after \(Int(timeoutSeconds))s")
        }

        return result
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

private final class ProcessTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

private final class ProcessContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<PythonProcessResult, Error>
    private let outputPipe: Pipe
    private let errorPipe: Pipe

    init(
        continuation: CheckedContinuation<PythonProcessResult, Error>,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) {
        self.continuation = continuation
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
    }

    func resume(_ result: Result<PythonProcessResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
