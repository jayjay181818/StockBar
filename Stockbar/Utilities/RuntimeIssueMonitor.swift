import Foundation

enum RuntimeIssueSeverity: Equatable, Sendable {
    case healthy
    case warning
    case critical
}

/// What one scan of the log found. Each line is counted once: a timeout is a
/// timeout, not an error as well.
struct RuntimeIssueSnapshot: Equatable, Sendable {
    let scannedLineCount: Int
    /// Error lines that are not timeouts. Store recoveries are among them.
    let errorCount: Int
    /// Warning and error lines that report a timeout.
    let timeoutCount: Int
    /// Error lines that report a Core Data store being set aside.
    let recoveryEventCount: Int
    let secretLeakCount: Int
    /// Warning lines that are not timeouts.
    var warningCount: Int = 0

    var severity: RuntimeIssueSeverity {
        if secretLeakCount > 0 {
            return .critical
        }
        if errorCount > 0 || timeoutCount > 0 || recoveryEventCount > 0 {
            return .warning
        }
        return .healthy
    }

    /// One line for the Debug Logs window. Nil when there is nothing to say.
    var summary: String? {
        if secretLeakCount > 0 {
            return "Possible unredacted credential in the log (\(secretLeakCount) line\(secretLeakCount == 1 ? "" : "s"))"
        }
        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
        if timeoutCount > 0 { parts.append("\(timeoutCount) timeout\(timeoutCount == 1 ? "" : "s")") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

actor RuntimeIssueMonitor {
    static let shared = RuntimeIssueMonitor()

    /// How far back each scan looks. Lines older than this are left out, so a
    /// quiet hour does not keep reporting a problem from yesterday, and a busy
    /// minute cannot push a real one out of view.
    static let window: TimeInterval = 600

    private var monitoringTask: Task<Void, Never>?
    private var lastSnapshot: RuntimeIssueSnapshot?

    func start(
        logger: Logger = .shared,
        intervalSeconds: UInt64 = 600,
        maxLines: Int = 5_000
    ) {
        guard monitoringTask == nil else { return }

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                // Raw lines: a leak check on already-redacted text could never fire.
                let logs = await logger.getTailLogs(maxLines: maxLines, redacted: false)
                let snapshot = Self.scan(logs: logs, since: Date().addingTimeInterval(-Self.window))
                await self?.publish(snapshot: snapshot, logger: logger)

                let sleepNanos = max(intervalSeconds, 60) * 1_000_000_000
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func latestSnapshot() -> RuntimeIssueSnapshot? {
        lastSnapshot
    }

    /// Counts the issues in `logs`. With `since`, lines stamped before it are
    /// skipped. A line with no time stamp continues the entry above it (a Python
    /// traceback, say) and takes that entry's time; with no entry above, it is counted.
    static func scan(logs: [String], since: Date? = nil) -> RuntimeIssueSnapshot {
        var errorCount = 0
        var warningCount = 0
        var timeoutCount = 0
        var recoveryEventCount = 0
        var secretLeakCount = 0
        var scanned = 0

        var entryStamp: Date?
        for log in logs {
            if let stamp = timestamp(of: log) { entryStamp = stamp }
            if let since, let entryStamp, entryStamp < since {
                continue
            }
            scanned += 1

            let lowercasedLog = log.lowercased()
            let severity = severity(of: lowercasedLog)

            if LogRedactor.containsUnredactedSecret(log) {
                secretLeakCount += 1
            }

            // Monitor the structured severity emitted by Logger rather than
            // words such as "failed" in warning summaries. Ignore our own
            // summaries so a previous scan cannot feed back into the next one.
            guard !lowercasedLog.contains("runtimeissuemonitor.swift") else {
                continue
            }
            guard severity.isOperationalIssue else { continue }

            let containsTimeout =
                lowercasedLog.contains("timeout") || lowercasedLog.contains("timed out")
            if containsTimeout {
                timeoutCount += 1
                continue
            }

            if severity == .warning {
                warningCount += 1
                continue
            }

            errorCount += 1
            if lowercasedLog.contains("core data store load failed") ||
                lowercasedLog.contains("store-load-failure") {
                recoveryEventCount += 1
            }
        }

        return RuntimeIssueSnapshot(
            scannedLineCount: scanned,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            recoveryEventCount: recoveryEventCount,
            secretLeakCount: secretLeakCount,
            warningCount: warningCount
        )
    }

    /// The time at the start of a log line, in either the current format
    /// (with milliseconds and offset) or the one before it (local time).
    static func timestamp(of line: String) -> Date? {
        guard line.count >= 19, line.first?.isNumber == true else { return nil }
        if let end = line.index(line.startIndex, offsetBy: 28, limitedBy: line.endIndex),
           let date = currentFormat.date(from: String(line[..<end])) {
            return date
        }
        let end = line.index(line.startIndex, offsetBy: 19)
        return previousFormat.date(from: String(line[..<end]))
    }

    private static let currentFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return formatter
    }()

    private static let previousFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private enum ParsedLogSeverity {
        case debug
        case info
        case warning
        case error
        case unknown

        var isOperationalIssue: Bool {
            self == .warning || self == .error
        }
    }

    private static func severity(of lowercasedLog: String) -> ParsedLogSeverity {
        let trimmedLog = lowercasedLog.trimmingCharacters(in: .whitespacesAndNewlines)

        if lowercasedLog.contains("[error]") ||
            trimmedLog.hasPrefix("error ") ||
            trimmedLog.hasPrefix("error:") {
            return .error
        }
        if lowercasedLog.contains("[warning]") ||
            trimmedLog.hasPrefix("warning ") ||
            trimmedLog.hasPrefix("warning:") {
            return .warning
        }
        if lowercasedLog.contains("[info]") ||
            trimmedLog.hasPrefix("info ") ||
            trimmedLog.hasPrefix("info:") {
            return .info
        }
        if lowercasedLog.contains("[debug]") ||
            trimmedLog.hasPrefix("debug ") ||
            trimmedLog.hasPrefix("debug:") {
            return .debug
        }
        return .unknown
    }

    private func publish(snapshot: RuntimeIssueSnapshot, logger: Logger) async {
        guard snapshot != lastSnapshot else { return }
        let previous = lastSnapshot
        lastSnapshot = snapshot

        switch snapshot.severity {
        case .healthy:
            // Only worth a line when it follows trouble.
            if let previous, previous.severity != .healthy {
                await logger.info("Runtime monitor: no errors or timeouts in the last \(Int(Self.window / 60)) minutes")
            }
        case .warning:
            await logger.warning(
                "Runtime monitor, last \(Int(Self.window / 60)) minutes: errors=\(snapshot.errorCount) " +
                "(store recoveries=\(snapshot.recoveryEventCount)), timeouts=\(snapshot.timeoutCount), " +
                "warnings=\(snapshot.warningCount)"
            )
        case .critical:
            await logger.error(
                "Runtime monitor detected possible unredacted secret material in logs. " +
                "secretLeaks=\(snapshot.secretLeakCount), scannedLines=\(snapshot.scannedLineCount)"
            )
        }
    }
}
