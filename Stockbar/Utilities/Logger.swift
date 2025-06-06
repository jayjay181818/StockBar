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
public class Logger {
    public static let shared = Logger()
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter
    
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
            let content = try String(contentsOf: logFileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
            
            // Return the last maxLines entries
            if lines.count > maxLines {
                return Array(lines.suffix(maxLines))
            } else {
                return lines
            }
        } catch {
            return ["Error reading log file: \(error.localizedDescription)"]
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
}