import XCTest
@testable import Stockbar

final class LogRedactorTests: XCTestCase {
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
}
