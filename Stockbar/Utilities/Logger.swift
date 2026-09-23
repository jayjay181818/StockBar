import Foundation

/// Logging levels for the application
public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error

    fileprivate var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
    
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "🔴"
        }
    }
}

/// A logging service for the application
public actor Logger {
    public static let shared = Logger()
    private static let persistedRepairVersion = 2
    private let fileManager: FileManager
    private let dateFormatter: DateFormatter
    private let logFileURL: URL?
    private var logCounter = 0
    
    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        if Self.isRunningUnderXCTest {
            logFileURL = nil
        } else {
            let directory = Self.resolveLogDirectoryURL(fileManager: fileManager)
            logFileURL = directory?.appendingPathComponent("stockbar.log")
            if let directory {
                Self.repairPersistedLogFilesOnce(in: directory, fileManager: fileManager)
            }
        }
    }

    public static var isDebugLoggingEnabled: Bool {
        let environmentValue = ProcessInfo.processInfo.environment["STOCKBAR_DEBUG_LOGGING"]?.lowercased()
        return environmentValue == "1" ||
            environmentValue == "true" ||
            StockbarRuntimeStorage.userDefaults.bool(forKey: "stockbar.debugLoggingEnabled")
    }
    
    /// Logs a message with the specified level.
    ///
    /// - Note: `message` is `@autoclosure`, so the caller's string
    ///   interpolation is only evaluated if the message will actually be
    ///   emitted (debug logging is off by default).
    ///
    ///   The closure is evaluated in the **caller's** isolation domain
    ///   (`isolation: #isolation`) and only the resulting `String` crosses
    ///   into the actor. Passing the closure itself into the actor made it
    ///   read the caller's actor-isolated state from the logger's executor —
    ///   a real data race the compiler reported at every call site.
    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(level) else { return }
        let text = message()
        await write(level, text, file: file, function: function, line: line)
    }

    /// Fire-and-forget logging for synchronous code. The level check and
    /// message evaluation happen immediately on the caller's side; only the
    /// finished `String` is sent to the actor. Prefer this over wrapping
    /// `await logger.debug(...)` in a `Task`, which captures (possibly
    /// non-Sendable) caller state in an escaping closure just to build text.
    public nonisolated func post(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard Self.shouldLog(level) else { return }
        let text = message()
        Task { await self.write(level, text, file: file, function: function, line: line) }
    }

    private func write(_ level: LogLevel, _ message: String, file: String, function: String, line: Int) {
        let timestamp = dateFormatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        let safeMessage = LogRedactor.redact(message)

        let logMessage = "\(timestamp) \(level.emoji) [\(level.rawValue.uppercased())] [\(filename):\(line)] \(function): \(safeMessage)"

        // Print to console in debug
        #if DEBUG
        print(logMessage)
        #endif

        // Write to file
        writeToLogFile(logMessage)
    }

    private static func shouldLog(_ level: LogLevel) -> Bool {
        if level == .debug {
            return isDebugLoggingEnabled
        }
        return level.priority >= LogLevel.info.priority
    }

    private func writeToLogFile(_ message: String) {
        guard let logFileURL = getLogFileURL() else { return }
        
        let messageWithNewline = message + "\n"
        guard let data = messageWithNewline.data(using: .utf8) else { return }

        do {
            if fileManager.fileExists(atPath: logFileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                defer { try? fileHandle.close() }

                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
            }

            // Check if log file needs compacting after writing
            compactLogFileIfNeeded()
        } catch {
            // Avoid crashing the app if the file system rejects the write
            #if DEBUG
            print("Logger failed to persist log entry: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func getLogFileURL() -> URL? {
        return logFileURL
    }

    private func getLogDirectoryURL() -> URL? {
        Self.resolveLogDirectoryURL(fileManager: fileManager)
    }

    private static func resolveLogDirectoryURL(fileManager: FileManager) -> URL? {
        if let acceptanceRoot = StockbarRuntimeStorage.acceptance.root {
            return createLogDirectory(
                acceptanceRoot.appendingPathComponent("Logs/com.stockbar", isDirectory: true),
                fileManager: fileManager
            )
        }

        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }

        let bundlePathComponent: String
        if let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty {
            bundlePathComponent = bundleIdentifier
        } else {
            bundlePathComponent = "Stockbar"
        }
        let logsURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bundlePathComponent, isDirectory: true)

        return createLogDirectory(logsURL, fileManager: fileManager)
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }

    private static func createLogDirectory(_ directory: URL, fileManager: FileManager) -> URL? {
        guard !fileManager.fileExists(atPath: directory.path) else { return directory }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            #if DEBUG
            print("Logger failed to create Logs directory: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private static func repairPersistedLogFilesOnce(in baseURL: URL, fileManager: FileManager) {
        let markerURL = baseURL.appendingPathComponent(".redaction-repair-v\(persistedRepairVersion)")
        guard !fileManager.fileExists(atPath: markerURL.path) else { return }

        for fileName in ["stockbar.log", "stockbar.1.log", "stockbar.2.log"] {
            let fileURL = baseURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            guard (try? streamRepairLog(at: fileURL, fileManager: fileManager)) != nil else { return }
        }

        try? Data().write(to: markerURL, options: .atomic)
    }

    private static func streamRepairLog(at fileURL: URL, fileManager: FileManager) throws {
        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).repair-\(UUID().uuidString)")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: fileURL)
        let output = try FileHandle(forWritingTo: temporaryURL)

        do {
            defer {
                try? input.close()
                try? output.close()
            }

            var pending = Data()
            while true {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                pending.append(chunk)

                while let newline = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                    pending.removeSubrange(pending.startIndex...newline.lowerBound)
                    let repaired = LogRedactor.redact(String(decoding: lineData, as: UTF8.self)) + "\n"
                    try output.write(contentsOf: Data(repaired.utf8))
                }
            }

            if !pending.isEmpty {
                let repaired = LogRedactor.redact(String(decoding: pending, as: UTF8.self))
                try output.write(contentsOf: Data(repaired.utf8))
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
    }
    
    public func debug(
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(.debug) else { return }
        let text = message()
        await write(.debug, text, file: file, function: function, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(.info) else { return }
        let text = message()
        await write(.info, text, file: file, function: function, line: line)
    }

    public func warning(
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(.warning) else { return }
        let text = message()
        await write(.warning, text, file: file, function: function, line: line)
    }

    public func error(
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(.error) else { return }
        let text = message()
        await write(.error, text, file: file, function: function, line: line)
    }

    public func critical(
        _ message: @autoclosure () -> String,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) async {
        guard Self.shouldLog(.error) else { return }
        let text = message()
        await write(.error, text, file: file, function: function, line: line)
    }
    
    /// Gets recent log entries from the log file
    /// - Parameter maxLines: Maximum number of lines to return (default: 500)
    /// - Returns: Array of log entry strings
    public func getRecentLogs(maxLines: Int = 500) -> [String] {
        getTailLogs(maxLines: maxLines)
    }
    
    /// Gets only the most recent logs using a tail-like approach for large files
    /// - Parameter maxLines: Maximum number of lines to return
    /// - Returns: Array of recent log entry strings
    public func getTailLogs(maxLines: Int = 100) -> [String] {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else {
            return ["No log file found"]
        }

        return getTailLogsFromLargeFile(fileURL: logFileURL, maxLines: max(0, maxLines))
    }
    
    /// Efficiently reads the last N lines from a large log file
    private func getTailLogsFromLargeFile(fileURL: URL, maxLines: Int) -> [String] {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }
            
            let fileSize = try fileHandle.seekToEnd()
            let chunkSize = min(8192, Int(fileSize)) // Read 8KB chunks
            var buffer = Data()
            var lines: [String] = []
            var position = Int64(fileSize)
            
            // Read backwards in chunks until we have enough lines
            while lines.count < maxLines && position > 0 {
                let readSize = min(chunkSize, Int(position))
                position = max(0, position - Int64(readSize))
                
                try fileHandle.seek(toOffset: UInt64(position))
                let chunk = fileHandle.readData(ofLength: readSize)
                
                // Prepend chunk to buffer
                buffer = chunk + buffer
                
                // Split into lines and check if we have enough
                let content = String(data: buffer, encoding: .utf8) ?? ""
                let newLines = content.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .map { line in
                        let safeLine = LogRedactor.redact(line)
                        if safeLine.count > 1000 {
                            return String(safeLine.prefix(1000)) + " ... [truncated]"
                        }
                        return safeLine
                    }
                
                lines = newLines
                
                // If we have enough lines or reached the beginning, stop
                if lines.count >= maxLines || position == 0 {
                    break
                }
            }
            
            // Return the last maxLines
            return Array(lines.suffix(maxLines))
        } catch {
            return ["Error reading large log file: \(error.localizedDescription)"]
        }
    }
    
    /// Clears the log file
    public func clearLogs() {
        guard let logFileURL = getLogFileURL() else { return }
        
        do {
            if fileManager.fileExists(atPath: logFileURL.path) {
                try fileManager.removeItem(at: logFileURL)
            }
        } catch {
            write(.error, "Failed to clear logs: \(error.localizedDescription)", file: #file, function: #function, line: #line)
        }
    }
    
    /// Gets the log file path for display
    public func getLogFilePath() -> String? {
        return getLogFileURL()?.path
    }
    
    /// Rotates the log file if it exceeds maximum size (10MB)
    private func compactLogFileIfNeeded() {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else { return }

        // Only check every 50 log entries to avoid performance impact
        logCounter += 1
        guard logCounter % 50 == 0 else { return }

        do {
            let fileAttributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
            if let fileSize = fileAttributes[.size] as? Int64 {
                // Rotate if file is larger than 10MB
                if fileSize > 10_000_000 {
                    rotateLogFiles(currentLogURL: logFileURL)
                    logCounter = 0
                    return
                }
            }

            if logCounter >= 10_000 {
                rotateLogFiles(currentLogURL: logFileURL)
                logCounter = 0
            }
        } catch {
            // Silent failure to avoid logging loops
        }
    }

    /// Rotates log files keeping the last 3 files
    /// stockbar.log -> stockbar.1.log
    /// stockbar.1.log -> stockbar.2.log
    /// stockbar.2.log -> deleted
    private func rotateLogFiles(currentLogURL: URL) {
        do {
            let baseURL = currentLogURL.deletingLastPathComponent()
            let baseFileName = "stockbar"

            // Delete oldest log (stockbar.2.log)
            let oldestLog = baseURL.appendingPathComponent("\(baseFileName).2.log")
            if fileManager.fileExists(atPath: oldestLog.path) {
                try fileManager.removeItem(at: oldestLog)
            }

            // Rotate stockbar.1.log -> stockbar.2.log
            let log1 = baseURL.appendingPathComponent("\(baseFileName).1.log")
            if fileManager.fileExists(atPath: log1.path) {
                try fileManager.moveItem(at: log1, to: oldestLog)
            }

            // Rotate stockbar.log -> stockbar.1.log
            if fileManager.fileExists(atPath: currentLogURL.path) {
                try fileManager.moveItem(at: currentLogURL, to: log1)
            }

            // Create new empty log file with rotation message
            let timestamp = dateFormatter.string(from: Date())
            let message = "\(timestamp) ℹ️ [INFO] [Logger.swift] rotateLogFiles: Log files rotated (previous logs saved as .1.log and .2.log)\n"
            try message.write(to: currentLogURL, atomically: true, encoding: .utf8)
        } catch {
            // Silent failure to avoid logging loops
        }
    }
    
    /// Clears all log files (current and rotated)
    public func clearAllLogs() {
        guard let baseURL = getLogFileURL()?.deletingLastPathComponent() else { return }

        let logFiles = ["stockbar.log", "stockbar.1.log", "stockbar.2.log"]

        for logFile in logFiles {
            let fileURL = baseURL.appendingPathComponent(logFile)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        // Create new empty log file
        if let newLogURL = getLogFileURL() {
            let timestamp = dateFormatter.string(from: Date())
            let message = "\(timestamp) ℹ️ [INFO] [Logger.swift] clearAllLogs: All log files cleared by user\n"
            try? message.write(to: newLogURL, atomically: true, encoding: .utf8)
        }
    }

    /// Gets total size of all log files in MB
    public nonisolated func getTotalLogSize() -> Double {
        guard let baseURL = Self.resolveLogDirectoryURL(fileManager: .default) else { return 0 }

        let logFiles = ["stockbar.log", "stockbar.1.log", "stockbar.2.log"]
        var totalSize: Int64 = 0

        for logFile in logFiles {
            let fileURL = baseURL.appendingPathComponent(logFile)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return Double(totalSize) / 1_000_000.0 // Convert to MB
    }
}
