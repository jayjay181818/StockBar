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
        if let data = messageWithNewline.data(using: .utf8) {
            if fileManager.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    try? fileHandle.close()
                }
            } else {
                try? messageWithNewline.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
            
            // Check if log file needs compacting after writing
            compactLogFileIfNeeded()
        }
    }
    
    private func getLogFileURL() -> URL? {
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsPath.appendingPathComponent("stockbar.log")
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
    
    /// Compacts the log file if it exceeds 10,000 lines or 10MB
    private func compactLogFileIfNeeded() {
        guard let logFileURL = getLogFileURL(),
              fileManager.fileExists(atPath: logFileURL.path) else { return }
        
        // Only check every 50 log entries to avoid performance impact (reduced from 100)
        logCounter += 1
        guard logCounter % 50 == 0 else { return }
        
        do {
            // Check file size first
            let fileAttributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
            if let fileSize = fileAttributes[.size] as? Int64 {
                // Compact if file is larger than 10MB (reduced from previous larger size)
                if fileSize > 10_000_000 {
                    compactByFileSize(logFileURL: logFileURL, currentSize: fileSize)
                    return
                }
            }
            
            // Check line count
            let content = try String(contentsOf: logFileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            if lines.count > 5000 { // Reduced from 10,000 to keep files smaller
                compactByLineCount(logFileURL: logFileURL, lines: lines)
            }
        } catch {
            // If compaction fails, log the error (but don't create infinite loops)
            let timestamp = dateFormatter.string(from: Date())
            let errorMessage = "\(timestamp) ⚠️ [WARNING] [Logger.swift] compactLogFileIfNeeded: Compaction failed: \(error.localizedDescription)\n"
            
            // Try to write error message directly (bypass normal logging to avoid recursion)
            if let data = errorMessage.data(using: .utf8) {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }
    
    /// Compacts log file based on file size
    private func compactByFileSize(logFileURL: URL, currentSize: Int64) {
        do {
            // For very large files, read only the last portion
            let fileHandle = try FileHandle(forReadingFrom: logFileURL)
            defer { try? fileHandle.close() }
            
            // Read last 2MB of the file
            let readSize = min(2_000_000, Int(currentSize))
            let seekPosition = max(0, currentSize - Int64(readSize))
            
            try fileHandle.seek(toOffset: UInt64(seekPosition))
            let data = fileHandle.readData(ofLength: readSize)
            
            if let content = String(data: data, encoding: .utf8) {
                // Find the first complete line to avoid partial lines
                let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
                if lines.count > 1 {
                    // Skip the first line as it might be partial, keep the rest
                    let compactedLines = Array(lines.dropFirst())
                    let compactedContent = compactedLines.joined(separator: "\n") + "\n"
                    
                    // Add compaction notice
                    let timestamp = dateFormatter.string(from: Date())
                    let compactionMessage = "\(timestamp) ℹ️ [INFO] [Logger.swift] compactByFileSize: Log file compacted from \(currentSize / 1_000_000)MB to \(compactedContent.count / 1_000_000)MB\n"
                    let finalContent = compactionMessage + compactedContent
                    
                    try finalContent.write(to: logFileURL, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            // Silent failure to avoid logging loops
        }
    }
    
    /// Compacts log file based on line count
    private func compactByLineCount(logFileURL: URL, lines: [String]) {
        do {
            // Keep the most recent 2,000 lines (reduced from 5,000)
            let compactedLines = Array(lines.suffix(2000))
            let compactedContent = compactedLines.joined(separator: "\n") + "\n"
            
            // Add a log entry about the compaction
            let timestamp = dateFormatter.string(from: Date())
            let compactionMessage = "\(timestamp) ℹ️ [INFO] [Logger.swift] compactByLineCount: Log file compacted from \(lines.count) to \(compactedLines.count) lines\n"
            let finalContent = compactionMessage + compactedContent
            
            try finalContent.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            // Silent failure to avoid logging loops
        }
    }
}