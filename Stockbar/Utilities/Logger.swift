import Foundation
import Synchronization

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
    /// Kept open between writes; reopening the file for every line was most
    /// of the cost of logging. Dropped whenever the file is rotated or cleared.
    private var writeHandle: FileHandle?
    private var didWriteSessionHeader = false
    /// Rotate once the current file passes this size.
    static let maximumLogFileBytes: Int64 = 10_000_000
    private let rotationLimit: Int64
    static let logFileNames = ["stockbar.log", "stockbar.1.log", "stockbar.2.log"]

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rotationLimit = Self.maximumLogFileBytes
        dateFormatter = Self.makeTimestampFormatter()
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

    /// A logger writing to `fileURL`, for tests of rotation and tail reading.
    init(fileURL: URL, rotateAboveBytes: Int64 = Logger.maximumLogFileBytes, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rotationLimit = rotateAboveBytes
        dateFormatter = Self.makeTimestampFormatter()
        logFileURL = fileURL
        didWriteSessionHeader = true
    }

    /// Local time with its UTC offset, so lines from either side of a clock
    /// change or another time zone still sort and compare correctly.
    private static func makeTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return formatter
    }

    /// The setting is read for every debug call that is not made, thousands
    /// of times a minute, so the answer is kept for a few seconds.
    private static let debugFlagCache = DebugFlagCache()

    public static var isDebugLoggingEnabled: Bool {
        debugFlagCache.value {
            let environmentValue = ProcessInfo.processInfo.environment["STOCKBAR_DEBUG_LOGGING"]?.lowercased()
            return environmentValue == "1" ||
                environmentValue == "true" ||
                StockbarRuntimeStorage.userDefaults.bool(forKey: "stockbar.debugLoggingEnabled")
        }
    }

    /// Lines go to standard output only when asked for. Printing every line
    /// in Debug builds doubled the work and flooded the Xcode console.
    private static let echoesToStandardOutput: Bool = {
        let value = ProcessInfo.processInfo.environment["STOCKBAR_LOG_STDOUT"]?.lowercased()
        return value == "1" || value == "true"
    }()
    
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
        let date = Date()
        await write(level, text, at: date, file: file, function: function, line: line)
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
        let date = Date()
        Task { await self.write(level, text, at: date, file: file, function: function, line: line) }
    }

    /// `date` is when the caller logged, not when the actor got round to
    /// writing: stamped on arrival, lines from different tasks could appear
    /// in the file in a different order from their times.
    private func write(
        _ level: LogLevel,
        _ message: String,
        at date: Date = Date(),
        file: String,
        function: String,
        line: Int
    ) {
        writeSessionHeaderIfNeeded()
        let timestamp = dateFormatter.string(from: date)
        let filename = (file as NSString).lastPathComponent
        let safeMessage = Self.singleLine(LogRedactor.redact(message))

        let logMessage = "\(timestamp) \(level.emoji) [\(level.rawValue.uppercased())] [\(filename):\(line)] \(function): \(safeMessage)"

        if Self.echoesToStandardOutput {
            print(logMessage)
        }

        // Write to file
        writeToLogFile(logMessage)
    }

    /// One record, one line. A message with line breaks in it (a Python
    /// traceback, say) used to become several lines with no timestamp or
    /// level, which every reader of the log then miscounted.
    static func singleLine(_ message: String) -> String {
        guard message.contains(where: \.isNewline) else { return message }
        return message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    /// The first line of each run: which build this is and what it runs on.
    private func writeSessionHeaderIfNeeded() {
        guard !didWriteSessionHeader else { return }
        didWriteSessionHeader = true
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let debug = Self.isDebugLoggingEnabled ? "on" : "off"
        writeToLogFile(
            "\(dateFormatter.string(from: Date())) ℹ️ [INFO] [Logger.swift] session: "
                + "==== Stockbar \(version) (\(build)) started · macOS \(system) · "
                + "pid \(ProcessInfo.processInfo.processIdentifier) · debug logging \(debug) ===="
        )
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
            if writeHandle == nil {
                if !fileManager.fileExists(atPath: logFileURL.path) {
                    fileManager.createFile(atPath: logFileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                writeHandle = handle
            }
            try writeHandle?.write(contentsOf: data)

            // Check if log file needs compacting after writing
            compactLogFileIfNeeded()
        } catch {
            // Avoid crashing the app if the file system rejects the write.
            // Reopen next time: the file may have been moved or deleted.
            closeWriteHandle()
            #if DEBUG
            print("Logger failed to persist log entry: \(error.localizedDescription)")
            #endif
        }
    }

    private func closeWriteHandle() {
        try? writeHandle?.close()
        writeHandle = nil
    }
    
    private func getLogFileURL() -> URL? {
        return logFileURL
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

        for fileName in Self.logFileNames {
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

            // Each chunk is cut at its last line break and handled as a whole,
            // inside its own autorelease pool. Removing one line at a time
            // from the front of the buffer copied the rest of it every time,
            // and temporary strings piled up until the loop ended: one repair
            // was seen to reach 936 MB.
            var carry = Data()
            let newline = UInt8(0x0A)
            // A "line" longer than this has no line breaks worth waiting for.
            let longestLine = 4 * 1024 * 1024
            var reachedEnd = false
            while !reachedEnd {
                try autoreleasepool {
                    let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty {
                        reachedEnd = true
                        return
                    }
                    carry.append(chunk)
                    let cut: Data.Index
                    if let lastBreak = carry.lastIndex(of: newline) {
                        cut = carry.index(after: lastBreak)
                    } else if carry.count > longestLine {
                        cut = carry.endIndex
                    } else {
                        return
                    }
                    let complete = carry[carry.startIndex..<cut]
                    let rest = Data(carry[cut...])
                    let repaired = String(decoding: complete, as: UTF8.self)
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { LogRedactor.redact(String($0)) }
                        .joined(separator: "\n")
                    try output.write(contentsOf: Data(repaired.utf8))
                    carry = rest
                }
            }

            if !carry.isEmpty {
                let repaired = LogRedactor.redact(String(decoding: carry, as: UTF8.self))
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
        let date = Date()
        await write(.debug, text, at: date, file: file, function: function, line: line)
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
        let date = Date()
        await write(.info, text, at: date, file: file, function: function, line: line)
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
        let date = Date()
        await write(.warning, text, at: date, file: file, function: function, line: line)
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
        let date = Date()
        await write(.error, text, at: date, file: file, function: function, line: line)
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
        let date = Date()
        await write(.error, text, at: date, file: file, function: function, line: line)
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
    /// - Parameter redacted: Pass false only to scan for leaks in memory;
    ///   never display or log the raw lines.
    public func getTailLogs(maxLines: Int = 100, redacted: Bool = true) -> [String] {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else {
            return ["No log file found"]
        }

        return getTailLogsFromLargeFile(fileURL: logFileURL, maxLines: max(0, maxLines), redacted: redacted)
    }
    
    /// Reads the last `maxLines` lines of a file.
    ///
    /// Walks back from the end counting line breaks in the raw bytes, then
    /// decodes and redacts what it found once. The old version decoded and
    /// redacted everything read so far again after each 8 KB step, so 2,000
    /// lines cost seconds of the logger's time.
    private func getTailLogsFromLargeFile(fileURL: URL, maxLines: Int, redacted: Bool = true) -> [String] {
        guard maxLines > 0 else { return [] }
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            let fileSize = try fileHandle.seekToEnd()
            let chunkSize: UInt64 = 64 * 1024
            var chunks: [Data] = []
            var newlineCount = 0
            var position = fileSize

            // One more line break than lines wanted, so the first line kept is whole.
            while position > 0 && newlineCount <= maxLines {
                let readSize = min(chunkSize, position)
                position -= readSize
                try fileHandle.seek(toOffset: position)
                let chunk = try fileHandle.read(upToCount: Int(readSize)) ?? Data()
                newlineCount += chunk.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
                chunks.append(chunk)
            }

            var buffer = Data()
            for chunk in chunks.reversed() { buffer.append(chunk) }
            var lines = String(decoding: buffer, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
            // Not at the start of the file: the first piece is the tail of a line.
            if position > 0, !lines.isEmpty { lines.removeFirst() }

            return lines.suffix(maxLines).map { line in
                let text = String(line)
                let safeLine = redacted ? LogRedactor.redact(text) : text
                if safeLine.count > 1000 {
                    return String(safeLine.prefix(1000)) + " ... [truncated]"
                }
                return safeLine
            }
        } catch {
            return ["Error reading large log file: \(error.localizedDescription)"]
        }
    }

    /// The path of each log file that exists, oldest first.
    public func existingLogFileURLs() -> [URL] {
        guard let baseURL = getLogFileURL()?.deletingLastPathComponent() else { return [] }
        return Self.logFileNames.reversed()
            .map { baseURL.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Writes every log file, oldest first, into one file at `destination`.
    /// Copied in pieces, so a full set of logs is never held in memory.
    public func exportAllLogs(to destination: URL) throws {
        let sources = existingLogFileURLs()
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).export-\(UUID().uuidString)")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }
            for source in sources {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                try output.write(contentsOf: Data("==== \(source.lastPathComponent) ====\n".utf8))
                while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }

    /// Clears the log file
    public func clearLogs() {
        guard let logFileURL = getLogFileURL() else { return }
        
        closeWriteHandle()
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
    
    /// Rotates the log file once it passes `maximumLogFileBytes`.
    private func compactLogFileIfNeeded() {
        guard let logFileURL = getLogFileURL() else { return }

        // Only check every 50 log entries to avoid performance impact
        logCounter += 1
        guard logCounter % 50 == 0 else { return }

        // Deleted or moved by something else: stop writing to the old file.
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            closeWriteHandle()
            return
        }

        do {
            let fileAttributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
            if let fileSize = fileAttributes[.size] as? Int64 {
                // By size only. Rotating after every 10,000 lines as well cut
                // files off at about 2 MB and threw history away early.
                if fileSize > rotationLimit {
                    rotateLogFiles(currentLogURL: logFileURL)
                    logCounter = 0
                }
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
        closeWriteHandle()
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
        closeWriteHandle()

        let logFiles = Self.logFileNames

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
}

/// Remembers the debug-logging setting for a few seconds at a time.
private final class DebugFlagCache: Sendable {
    private struct State {
        var cached = false
        var readAt = Date.distantPast
    }

    private let state = Mutex(State())

    func value(_ read: () -> Bool) -> Bool {
        state.withLock { state in
            let now = Date()
            if now.timeIntervalSince(state.readAt) > 5 {
                state.cached = read()
                state.readAt = now
            }
            return state.cached
        }
    }
}
