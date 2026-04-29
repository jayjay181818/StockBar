import Foundation

enum RuntimeIssueSeverity: Equatable, Sendable {
    case healthy
    case warning
    case critical
}

struct RuntimeIssueSnapshot: Equatable, Sendable {
    let scannedLineCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let recoveryEventCount: Int
    let secretLeakCount: Int

    var severity: RuntimeIssueSeverity {
        if secretLeakCount > 0 {
            return .critical
        }
        if errorCount > 0 || timeoutCount > 0 || recoveryEventCount > 0 {
            return .warning
        }
        return .healthy
    }
}

actor RuntimeIssueMonitor {
    static let shared = RuntimeIssueMonitor()

    private var monitoringTask: Task<Void, Never>?
    private var lastSnapshot: RuntimeIssueSnapshot?

    func start(
        logger: Logger = .shared,
        intervalSeconds: UInt64 = 600,
        maxLines: Int = 500
    ) {
        guard monitoringTask == nil else { return }

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                let logs = await logger.getTailLogs(maxLines: maxLines)
                let snapshot = Self.scan(logs: logs)
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

    static func scan(logs: [String]) -> RuntimeIssueSnapshot {
        var errorCount = 0
        var timeoutCount = 0
        var recoveryEventCount = 0
        var secretLeakCount = 0

        for log in logs {
            let lowercasedLog = log.lowercased()

            if LogRedactor.containsUnredactedSecret(log) {
                secretLeakCount += 1
            }

            if lowercasedLog.contains("error") ||
                lowercasedLog.contains("failed") ||
                lowercasedLog.contains("exception") ||
                lowercasedLog.contains("fatal") ||
                lowercasedLog.contains("crash") {
                errorCount += 1
            }

            if lowercasedLog.contains("timeout") || lowercasedLog.contains("timed out") {
                timeoutCount += 1
            }

            if lowercasedLog.contains("core data store load failed") ||
                lowercasedLog.contains("store-load-failure") {
                recoveryEventCount += 1
            }
        }

        return RuntimeIssueSnapshot(
            scannedLineCount: logs.count,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            recoveryEventCount: recoveryEventCount,
            secretLeakCount: secretLeakCount
        )
    }

    private func publish(snapshot: RuntimeIssueSnapshot, logger: Logger) async {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        switch snapshot.severity {
        case .healthy:
            await logger.debug("Runtime monitor healthy after scanning \(snapshot.scannedLineCount) recent log line(s)")
        case .warning:
            await logger.warning(
                "Runtime monitor observed warning signals: errors=\(snapshot.errorCount), " +
                "timeouts=\(snapshot.timeoutCount), recoveryEvents=\(snapshot.recoveryEventCount)"
            )
        case .critical:
            await logger.error(
                "Runtime monitor detected possible unredacted secret material in logs. " +
                "secretLeaks=\(snapshot.secretLeakCount), scannedLines=\(snapshot.scannedLineCount)"
            )
        }
    }
}
