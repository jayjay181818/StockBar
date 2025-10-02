import Foundation

/// Logging levels for the application
public enum LogLevel: String {
    case debug
    case info
    case warning
    case error
    
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
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter
    private var logCounter = 0
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    
    /// Logs a message with the specified level
    /// - Parameters:
    ///   - level: The severity level of the log
    ///   - message: The message to log
    ///   - file: The file where the log was called
    ///   - function: The function where the log was called
    ///   - line: The line number where the log was called
    public func log(
        _ level: LogLevel,
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let filename = (file as NSString).lastPathComponent
        
        let logMessage = "\(timestamp) \(level.emoji) [\(level.rawValue.uppercased())] [\(filename):\(line)] \(function): \(message)"
        
        // Print to console in debug
        #if DEBUG
        print(logMessage)
        #endif
        
        // Write to file
        writeToLogFile(logMessage)
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
        guard let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let bundlePathComponent = Bundle.main.bundleIdentifier?.isEmpty == false
            ? Bundle.main.bundleIdentifier!
            : "Stockbar"
        let appSupportURL = baseURL.appendingPathComponent(bundlePathComponent, isDirectory: true)

        if !fileManager.fileExists(atPath: appSupportURL.path) {
            do {
                try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                #if DEBUG
                print("Logger failed to create Application Support directory: \(error.localizedDescription)")
                #endif
                return nil
            }
        }

        return appSupportURL.appendingPathComponent("stockbar.log")
    }
    
    public func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, message, file: file, function: function, line: line)
    }

    public func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, message, file: file, function: function, line: line)
    }

    public func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, message, file: file, function: function, line: line)
    }

    public func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, message, file: file, function: function, line: line)
    }

    public func critical(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, message, file: file, function: function, line: line)
    }
    
    /// Gets recent log entries from the log file
    /// - Parameter maxLines: Maximum number of lines to return (default: 500)
    /// - Returns: Array of log entry strings
    public func getRecentLogs(maxLines: Int = 500) -> [String] {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else {
            return ["No log file found"]
        }
        
        do {
            // Check file size first - if it's too large, provide a warning
            let fileAttributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
            if let fileSize = fileAttributes[.size] as? Int64, fileSize > 100_000_000 { // 100MB
                return ["Log file is too large (\(fileSize / 1_000_000)MB). Consider clearing logs."]
            }
            
            let content = try String(contentsOf: logFileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { line in
                    // Truncate extremely long lines to prevent UI issues
                    if line.count > 1000 {
                        return String(line.prefix(1000)) + " ... [truncated]"
                    }
                    return line
                }
            
            // Return the last maxLines entries
            if lines.count > maxLines {
                return Array(lines.suffix(maxLines))
            } else {
                return lines
            }
        } catch let error as NSError {
            // Provide more specific error information
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadCorruptFileError {
                return ["Error: Log file appears to be corrupted. Try clearing logs."]
            } else if error.domain == NSCocoaErrorDomain && error.code == NSFileReadInapplicableStringEncodingError {
                return ["Error: Log file has encoding issues. Try clearing logs."]
            } else {
                return ["Error reading log file: \(error.localizedDescription)", "Try clearing logs or check file permissions."]
            }
        } catch {
            return ["Error reading log file: \(error.localizedDescription)", "Try clearing logs or check file permissions."]
        }
    }
    
    /// Gets only the most recent logs using a tail-like approach for large files
    /// - Parameter maxLines: Maximum number of lines to return
    /// - Returns: Array of recent log entry strings
    public func getTailLogs(maxLines: Int = 100) -> [String] {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else {
            return ["No log file found"]
        }
        
        do {
            // For large files, use a more memory-efficient approach
            let fileAttributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
            if let fileSize = fileAttributes[.size] as? Int64, fileSize > 10_000_000 { // 10MB
                return getTailLogsFromLargeFile(fileURL: logFileURL, maxLines: maxLines)
            }
            
            // For smaller files, use the standard approach
            return getRecentLogs(maxLines: maxLines)
        } catch {
            return ["Error accessing log file: \(error.localizedDescription)"]
        }
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
                        if line.count > 1000 {
                            return String(line.prefix(1000)) + " ... [truncated]"
                        }
                        return line
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
            log(.error, "Failed to clear logs: \(error.localizedDescription)")
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
                    return
                }
            }

            // Also check line count as a secondary measure
            let content = try String(contentsOf: logFileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

            if lines.count > 10000 {
                rotateLogFiles(currentLogURL: logFileURL)
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
    public func getTotalLogSize() -> Double {
        guard let baseURL = getLogFileURL()?.deletingLastPathComponent() else { return 0 }

        let logFiles = ["stockbar.log", "stockbar.1.log", "stockbar.2.log"]
        var totalSize: Int64 = 0

        for logFile in logFiles {
            let fileURL = baseURL.appendingPathComponent(logFile)
            if fileManager.fileExists(atPath: fileURL.path),
               let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }

        return Double(totalSize) / 1_000_000.0 // Convert to MB
    }
}
