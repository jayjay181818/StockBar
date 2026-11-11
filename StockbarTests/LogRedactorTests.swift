import XCTest
import Security
@testable import Stockbar

final class LogRedactorTests: XCTestCase {
    func testRedactionIsIdempotentAndRepairsCorruptedMarkers() {
        let original = "Authorization: Bearer secret-token API_KEY=secret [REDACTED]]]]"
        let once = LogRedactor.redact(original)
        let twice = LogRedactor.redact(once)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(
            once,
            "Authorization: Bearer [REDACTED] API_KEY=[REDACTED] [REDACTED]"
        )
    }

    func testRedactsAPIKeysInURLQueryStrings() {
        // Given: A Python/requests style URL error with secrets in query parameters.
        let input = """
        403 Client Error: Forbidden for url: https://financialmodelingprep.com/api/v3/historical-price-full/AAPL?from=2026-01-01&apikey=secret-fmp-key&access_token=secret-token
        """

        // When: The message is sanitized for logging.
        let redacted = LogRedactor.redact(input)

        // Then: Secret values are removed while useful context remains.
        XCTAssertFalse(redacted.contains("secret-fmp-key"))
        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertTrue(redacted.contains("apikey=[REDACTED]"))
        XCTAssertTrue(redacted.contains("access_token=[REDACTED]"))
        XCTAssertTrue(redacted.contains("historical-price-full/AAPL"))
    }

    func testRedactsBearerAndEnvironmentStyleTokens() {
        // Given: Common credential formats that can appear in stderr or exceptions.
        let input = "Authorization: Bearer abc.def.ghi FMP_API_KEY=topsecret TWELVE_DATA_API_KEY: othersecret"

        // When: The message is sanitized for logging.
        let redacted = LogRedactor.redact(input)

        // Then: No raw credential material remains.
        XCTAssertFalse(redacted.contains("abc.def.ghi"))
        XCTAssertFalse(redacted.contains("topsecret"))
        XCTAssertFalse(redacted.contains("othersecret"))
        XCTAssertTrue(redacted.contains("Bearer [REDACTED]"))
        XCTAssertTrue(redacted.contains("FMP_API_KEY=[REDACTED]"))
        XCTAssertTrue(redacted.contains("TWELVE_DATA_API_KEY: [REDACTED]"))
    }

    func testRedactsRawPythonStderrAndExceptionText() {
        // Given: Python stderr containing nested exception text and provider URLs.
        let input = """
        requests.exceptions.HTTPError: 403 Client Error for url: https://financialmodelingprep.com/api/v3/quote/MU?apikey=secret-from-stderr
        RuntimeError: fallback failed with API_KEY: nested-secret and token=nested-token
        """

        // When: The stderr block is sanitized as a single log message.
        let redacted = LogRedactor.redact(input)

        // Then: Secret material is removed without hiding the useful provider/error context.
        XCTAssertFalse(redacted.contains("secret-from-stderr"))
        XCTAssertFalse(redacted.contains("nested-secret"))
        XCTAssertFalse(redacted.contains("nested-token"))
        XCTAssertTrue(redacted.contains("apikey=[REDACTED]"))
        XCTAssertTrue(redacted.contains("API_KEY: [REDACTED]"))
        XCTAssertTrue(redacted.contains("token=[REDACTED]"))
        XCTAssertTrue(redacted.contains("requests.exceptions.HTTPError"))
    }

    func testDetectsUnredactedSecretsWithoutFlaggingRedactedValues() {
        // Given: One raw credential and one already-sanitized credential.
        let raw = "https://financialmodelingprep.com/api/v3/quote/MU?apikey=secret-from-log"
        let safe = "https://financialmodelingprep.com/api/v3/quote/MU?apikey=[REDACTED]"

        // When/Then: Only the raw value is treated as a leak.
        XCTAssertTrue(LogRedactor.containsUnredactedSecret(raw))
        XCTAssertFalse(LogRedactor.containsUnredactedSecret(safe))
    }

    func testRedactsTrading212BasicAuthAndAccountIdentifiers() {
        // Given: Trading 212 auth and account identifiers that must never land in logs.
        let input = """
        Authorization: Basic YXBpLWtleTpzZWNyZXQ=
        TRADING212_API_KEY=public-key TRADING212_API_SECRET: private-secret
        accountId: 123456789
        """

        // When: The message is sanitized.
        let redacted = LogRedactor.redact(input)

        // Then: Credentials and account numbers are removed.
        XCTAssertFalse(redacted.contains("YXBpLWtleTpzZWNyZXQ="))
        XCTAssertFalse(redacted.contains("public-key"))
        XCTAssertFalse(redacted.contains("private-secret"))
        XCTAssertFalse(redacted.contains("123456789"))
        XCTAssertTrue(redacted.contains("Authorization: Basic [REDACTED]"))
        XCTAssertTrue(redacted.contains("TRADING212_API_KEY=[REDACTED]"))
        XCTAssertTrue(redacted.contains("TRADING212_API_SECRET: [REDACTED]"))
        XCTAssertTrue(redacted.contains("accountId: [REDACTED]"))
    }
}

final class LogAuditFixTests: XCTestCase {
    // MARK: Redactor

    func testRedactsCredentialsWhateverTheNameIsWrappedIn() {
        let cases = [
            #"{"apiKey": "abc123def456", "ok": true}"#,
            #"{'api_key': 'abc123def456'}"#,
            "X-API-Key: abc123def456",
            "FMP_API_KEY=abc123def456",
            "client_secret=abc123def456",
            "refreshToken: abc123def456",
            #"password="correct horse battery""#,
            "https://example.com/v1?signature=abc123def456&symbol=MU",
            "https://user:abc123def456@example.com/path",
            "Cookie: session=abc123def456; other=xyz",
            "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
        ]

        for line in cases {
            let redacted = LogRedactor.redact(line)
            XCTAssertFalse(redacted.contains("abc123def456"), line)
            XCTAssertFalse(redacted.contains("correct horse"), line)
            XCTAssertFalse(redacted.contains("dozjgNryP4J3"), line)
            XCTAssertTrue(redacted.contains("[REDACTED]"), line)
            XCTAssertTrue(LogRedactor.containsUnredactedSecret(line), line)
            XCTAssertFalse(LogRedactor.containsUnredactedSecret(redacted), redacted)
            XCTAssertEqual(LogRedactor.redact(redacted), redacted, "Redaction must be stable when repeated")
        }
    }

    func testLeavesOrdinaryTextAlone() {
        let ordinary = [
            "Sector allocation: Basic Materials 12.5%, Technology 40%",
            "Fetched 12345 snapshots for 17 symbols",
            "Basic plan selected",
            "Refresh interval 900 seconds; 3 tokens in the menu bar template"
        ]

        for line in ordinary {
            XCTAssertEqual(LogRedactor.redact(line), line)
            XCTAssertFalse(LogRedactor.containsUnredactedSecret(line), line)
        }
    }

    func testReplacesTheAccountNameInPathsWithoutCountingItAsALeak() {
        let line = "Cache at /Users/someone/Library/Caches/com.stockbar/x.json and /Users/Shared/a"

        let redacted = LogRedactor.redact(line)

        XCTAssertEqual(redacted, "Cache at ~/Library/Caches/com.stockbar/x.json and /Users/Shared/a")
        XCTAssertFalse(LogRedactor.containsUnredactedSecret(line))
    }

    // MARK: Logger

    private func makeLogDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testTailReturnsTheLastLinesWholeAndInOrder() async throws {
        let directory = try makeLogDirectory()
        let fileURL = directory.appendingPathComponent("stockbar.log")
        // Long enough that the tail spans several 64 KB reads.
        let padding = String(repeating: "x", count: 300)
        let lines = (0..<1_000).map { "line \($0) \(padding)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: fileURL)
        let logger = Logger(fileURL: fileURL)

        let tail = await logger.getTailLogs(maxLines: 400)
        let everything = await logger.getTailLogs(maxLines: 5_000)
        let none = await logger.getTailLogs(maxLines: 0)

        XCTAssertEqual(tail, Array(lines.suffix(400)))
        XCTAssertEqual(everything, lines)
        XCTAssertEqual(none, [])
    }

    func testEachRecordIsOneLineWithAnOffsetTimestamp() async throws {
        let directory = try makeLogDirectory()
        let logger = Logger(fileURL: directory.appendingPathComponent("stockbar.log"))

        await logger.error("Traceback (most recent call last):\n  File \"x.py\", line 1\nValueError: bad")
        let lines = await logger.getTailLogs(maxLines: 10)

        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("Traceback (most recent call last): ⏎ File"), line)
        XCTAssertTrue(line.contains("[ERROR]"), line)
        let stamp = try XCTUnwrap(RuntimeIssueMonitor.timestamp(of: line), line)
        XCTAssertLessThan(abs(stamp.timeIntervalSinceNow), 60)
    }

    func testRotatesBySizeOnlyAndExportsAndClearsEveryFile() async throws {
        let directory = try makeLogDirectory()
        let fileURL = directory.appendingPathComponent("stockbar.log")
        let logger = Logger(fileURL: fileURL, rotateAboveBytes: 20_000)
        let padding = String(repeating: "y", count: 500)

        // Size is checked every 50 lines, so this passes the limit several times.
        for index in 0..<420 {
            await logger.info("entry \(index) \(padding)")
        }

        let files = await logger.existingLogFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(files, ["stockbar.2.log", "stockbar.1.log", "stockbar.log"])
        let newest = await logger.getTailLogs(maxLines: 1)
        XCTAssertTrue(newest.first?.contains("entry 419 ") ?? false)

        let exportURL = directory.appendingPathComponent("export.log")
        try await logger.exportAllLogs(to: exportURL)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("==== stockbar.2.log ===="))
        XCTAssertTrue(exported.contains("==== stockbar.log ===="))
        XCTAssertTrue(exported.contains("entry 419 "))
        let older = try XCTUnwrap(exported.range(of: "==== stockbar.2.log ===="))
        let current = try XCTUnwrap(exported.range(of: "==== stockbar.log ===="))
        XCTAssertLessThan(older.lowerBound, current.lowerBound, "Oldest file comes first")

        await logger.clearAllLogs()
        let remaining = await logger.existingLogFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(remaining, ["stockbar.log"])
        await logger.info("after clearing")
        let afterClear = await logger.getTailLogs(maxLines: 10)
        XCTAssertEqual(afterClear.count, 2, "The cleared note and the new line, in the new file")
    }

    func testManyLinesDoNotRotateASmallFile() async throws {
        let directory = try makeLogDirectory()
        let logger = Logger(fileURL: directory.appendingPathComponent("stockbar.log"))

        for index in 0..<10_200 {
            await logger.info("short \(index)")
        }

        let files = await logger.existingLogFileURLs().map(\.lastPathComponent)
        XCTAssertEqual(files, ["stockbar.log"], "10,000 lines is about 1 MB; only size rotates the log")
    }

    // MARK: Issue monitor

    func testMonitorCountsEachLineOnceAndOnlyInsideItsWindow() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        let recent = formatter.string(from: now.addingTimeInterval(-60))
        let old = formatter.string(from: now.addingTimeInterval(-3_600))
        let logs = [
            "\(old) 🔴 [ERROR] [A.swift:1] f(): an hour ago",
            "\(recent) 🔴 [ERROR] [A.swift:1] f(): request timed out",
            "\(recent) 🔴 [ERROR] [A.swift:1] f(): provider exited 1",
            "\(recent) ⚠️ [WARNING] [A.swift:1] f(): provider slow",
            "\(recent) ℹ️ [INFO] [A.swift:1] f(): fine"
        ]

        let snapshot = RuntimeIssueMonitor.scan(logs: logs, since: now.addingTimeInterval(-600))

        XCTAssertEqual(snapshot.scannedLineCount, 4)
        XCTAssertEqual(snapshot.errorCount, 1, "The timeout is not also an error")
        XCTAssertEqual(snapshot.timeoutCount, 1)
        XCTAssertEqual(snapshot.warningCount, 1)
        XCTAssertEqual(snapshot.summary, "1 error, 1 timeout, 1 warning")
    }

    func testMonitorReadsTheOlderTimestampFormatAndSaysNothingWhenHealthy() {
        let line = "2026-07-24 10:15:00 ℹ️ [INFO] [A.swift:1] f(): fine"

        XCTAssertNotNil(RuntimeIssueMonitor.timestamp(of: line))
        XCTAssertNil(RuntimeIssueMonitor.timestamp(of: "ERROR no time stamp here"))
        XCTAssertNil(RuntimeIssueMonitor.scan(logs: [line]).summary)
    }

    // MARK: Folync polling and memory pressure

    func testRepeatedFolyncFailuresSlowDownToFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNil(FolyncRefreshSchedule.repeatedFailureBackoff(consecutiveFailures: 1, at: now),
                     "The first failure keeps the regular minute")
        XCTAssertEqual(FolyncRefreshSchedule.repeatedFailureBackoff(consecutiveFailures: 2, at: now),
                       now.addingTimeInterval(120))
        XCTAssertEqual(FolyncRefreshSchedule.repeatedFailureBackoff(consecutiveFailures: 3, at: now),
                       now.addingTimeInterval(300))
        XCTAssertEqual(FolyncRefreshSchedule.repeatedFailureBackoff(consecutiveFailures: 50, at: now),
                       now.addingTimeInterval(300))
    }

    func testFolyncFailureCategoriesAndLoopbackAddresses() throws {
        XCTAssertEqual(FolyncRefreshSchedule.failureCategory(FolyncPortfolioSourceError.unavailable(503)), "http-503")
        XCTAssertEqual(FolyncRefreshSchedule.failureCategory(FolyncPortfolioSourceError.unauthorized), "unauthorized")
        XCTAssertEqual(FolyncRefreshSchedule.failureCategory(URLError(.timedOut)), "timeout")
        XCTAssertEqual(FolyncRefreshSchedule.failureCategory(URLError(.notConnectedToInternet)), "offline")
        XCTAssertEqual(FolyncRefreshSchedule.failureCategory(URLError(.cannotFindHost)), "unreachable")

        XCTAssertTrue(FolyncRefreshSchedule.isLoopback(try XCTUnwrap(URL(string: "http://localhost:8080"))))
        XCTAssertTrue(FolyncRefreshSchedule.isLoopback(try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))))
        XCTAssertFalse(FolyncRefreshSchedule.isLoopback(try XCTUnwrap(URL(string: "https://folync.example.com"))))
    }

    func testOtherAppsMemoryPressureLeavesSmallCachesAlone() {
        XCTAssertFalse(MemoryManagementService.shouldEvictCaches(
            systemPressureIsCritical: false, ownUsageMB: 90, ownUsageLimitMB: 150
        ))
        XCTAssertTrue(MemoryManagementService.shouldEvictCaches(
            systemPressureIsCritical: false, ownUsageMB: 151, ownUsageLimitMB: 150
        ))
        XCTAssertTrue(MemoryManagementService.shouldEvictCaches(
            systemPressureIsCritical: true, ownUsageMB: 90, ownUsageLimitMB: 150
        ))
    }
}

final class RuntimeIssueMonitorTests: XCTestCase {
    func testScanFlagsSecretLeaksAsCritical() {
        // Given: Recent logs contain an unredacted provider URL.
        let logs = [
            "INFO refresh started",
            "ERROR 403 url=https://financialmodelingprep.com/api/v3/quote/MU?apikey=raw-secret"
        ]

        // When: The monitor scans recent logs.
        let snapshot = RuntimeIssueMonitor.scan(logs: logs)

        // Then: The issue is surfaced as critical and counted separately from normal errors.
        XCTAssertEqual(snapshot.secretLeakCount, 1)
        XCTAssertEqual(snapshot.errorCount, 1)
        XCTAssertEqual(snapshot.severity, .critical)
    }

    func testScanCountsRecoveryAndTimeoutEventsWithoutFlaggingRedactedProviderErrors() {
        // Given: Recent logs contain operational failures but no raw secrets.
        let logs = [
            "ERROR Core Data store load failed and was preserved at /tmp/recovery. Original store was not deleted.",
            "WARNING Python process timed out after 120 seconds",
            "ERROR 403 url=https://financialmodelingprep.com/api/v3/quote/MU?apikey=[REDACTED]"
        ]

        // When: The monitor scans recent logs.
        let snapshot = RuntimeIssueMonitor.scan(logs: logs)

        // Then: Recovery and timeout signals are visible, with warning severity.
        XCTAssertEqual(snapshot.secretLeakCount, 0)
        XCTAssertEqual(snapshot.recoveryEventCount, 1)
        XCTAssertEqual(snapshot.timeoutCount, 1)
        XCTAssertEqual(snapshot.errorCount, 2)
        XCTAssertEqual(snapshot.severity, .warning)
    }

    func testScanUsesStructuredSeverityAndIgnoresItsOwnSummary() {
        let logs = [
            "2026-07-24 [INFO] Backfill attempt failed and was recorded for retry",
            "2026-07-24 [WARNING] Provider request failed without timing out",
            "2026-07-24 [WARNING] [RuntimeIssueMonitor.swift:109] Runtime monitor observed warning signals: errors=4, timeouts=1",
            "2026-07-24 [ERROR] Provider process exited with status 1"
        ]

        let snapshot = RuntimeIssueMonitor.scan(logs: logs)

        XCTAssertEqual(snapshot.errorCount, 1)
        XCTAssertEqual(snapshot.timeoutCount, 0)
        XCTAssertEqual(snapshot.recoveryEventCount, 0)
        XCTAssertEqual(snapshot.severity, .warning)
    }
}
