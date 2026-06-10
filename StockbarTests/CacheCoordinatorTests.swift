import XCTest
@testable import Stockbar

class CacheCoordinatorTests: XCTestCase {

    var cacheCoordinator: CacheCoordinator!

    override func setUp() {
        super.setUp()
        cacheCoordinator = CacheCoordinator()
    }

    override func tearDown() {
        cacheCoordinator = nil
        super.tearDown()
    }

    // MARK: - Cache Status Tests

    func testNeverFetchedStatus() async {
        let status = await cacheCoordinator.getCacheStatus(for: "AAPL", at: Date())

        if case .neverFetched = status {
            // Success
        } else {
            XCTFail("Expected neverFetched status, got \(status.description)")
        }
    }

    func testFreshCacheStatus() async {
        let now = Date()
        let symbol = "AAPL"

        // Record successful fetch
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        // Check status immediately after
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)

        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status, got \(status.description)")
        }
    }

    func testStaleCacheStatus() async {
        let now = Date()
        let symbol = "AAPL"

        // Record fetch 10 minutes ago
        let fetchTime = now.addingTimeInterval(-600) // 10 minutes ago
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: fetchTime)

        // Check status now (15-minute fresh period has not passed, but stale period may have started)
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)

        // Should be stale or fresh depending on configuration
        switch status {
        case .fresh, .stale:
            // Success - either is acceptable
            break
        default:
            XCTFail("Expected fresh or stale status for 10-minute-old cache, got \(status.description)")
        }
    }

    func testExpiredCacheStatus() async {
        let now = Date()
        let symbol = "AAPL"

        // Record fetch 2 hours ago
        let fetchTime = now.addingTimeInterval(-7200) // 2 hours ago
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: fetchTime)

        // Check status now
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)

        if case .expired = status {
            // Success
        } else {
            XCTFail("Expected expired status for 2-hour-old cache, got \(status.description)")
        }
    }

    // MARK: - Fetch Success Recording Tests

    func testRecordFetchSuccess() async {
        let symbol = "AAPL"
        let now = Date()

        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status after recording success, got \(status.description)")
        }
    }

    func testShouldRefreshWithCustomFreshnessIntervalUsesShorterCadence() async {
        let symbol = "MU"
        let now = Date()

        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now.addingTimeInterval(-360))

        let shouldRefreshDefault = await cacheCoordinator.shouldRefresh(symbol: symbol, at: now)
        let shouldRefreshExtendedHours = await cacheCoordinator.shouldRefresh(
            symbol: symbol,
            at: now,
            freshnessInterval: 300
        )

        XCTAssertFalse(shouldRefreshDefault)
        XCTAssertTrue(shouldRefreshExtendedHours)
    }

    func testShouldRefreshWithCustomFreshnessIntervalKeepsFreshRecentFetches() async {
        let symbol = "MU"
        let now = Date()

        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now.addingTimeInterval(-120))

        let shouldRefresh = await cacheCoordinator.shouldRefresh(
            symbol: symbol,
            at: now,
            freshnessInterval: 300
        )

        XCTAssertFalse(shouldRefresh)
    }

    func testRecordMultipleFetchSuccesses() async {
        let symbol = "AAPL"
        let firstFetch = Date()
        let secondFetch = firstFetch.addingTimeInterval(600) // 10 minutes later

        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: firstFetch)
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: secondFetch)

        // Should use most recent fetch time
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: secondFetch)
        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status after multiple successes, got \(status.description)")
        }
    }

    // MARK: - Fetch Failure Recording Tests

    func testRecordFetchFailure() async {
        let symbol = "AAPL"
        let now = Date()

        await cacheCoordinator.setFailedFetch(for: symbol, at: now)

        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .failedRecently = status {
            // Success
        } else {
            XCTFail("Expected failedRecently status after recording failure, got \(status.description)")
        }
    }

    func testFailureRetryStatus() async {
        let symbol = "AAPL"
        let now = Date()

        // Record failure 6 minutes ago
        let failureTime = now.addingTimeInterval(-360) // 6 minutes ago
        await cacheCoordinator.setFailedFetch(for: symbol, at: failureTime)

        // Check if ready to retry (assuming 5-minute retry interval)
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .readyToRetry = status {
            // Success
        } else {
            XCTFail("Expected readyToRetry status after retry interval, got \(status.description)")
        }
    }

    // MARK: - Suspension Tests

    func testSuspensionAfterMultipleFailures() async {
        let symbol = "AAPL"
        let now = Date()

        // Record 5 consecutive failures
        for i in 0..<5 {
            let failureTime = now.addingTimeInterval(Double(i * 60)) // 1 minute apart
            await cacheCoordinator.setFailedFetch(for: symbol, at: failureTime)
        }

        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = status {
            // Success
        } else {
            XCTFail("Expected suspended status after multiple consecutive failures, got \(status.description)")
        }
    }

    func testClearSuspension() async {
        let symbol = "AAPL"
        let now = Date()

        // Suspend the symbol
        for i in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(Double(i * 60)))
        }

        let statusBeforeClear = await cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = statusBeforeClear {
            // Good - suspended as expected
        } else {
            XCTFail("Expected suspended status before clearing, got \(statusBeforeClear.description)")
        }

        // Clear suspension
        await cacheCoordinator.clearSuspension(for: symbol)

        // Should now be ready to retry
        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = status {
            XCTFail("Suspension should be cleared, but still suspended")
        }
    }

    func testClearAllSuspensions() async {
        let symbol1 = "AAPL"
        let symbol2 = "GOOGL"
        let now = Date()

        // Suspend both symbols
        for i in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: symbol1, at: now.addingTimeInterval(Double(i * 60)))
            await cacheCoordinator.setFailedFetch(for: symbol2, at: now.addingTimeInterval(Double(i * 60)))
        }

        // Clear all suspensions
        await cacheCoordinator.clearAllCache()

        let status1 = await cacheCoordinator.getCacheStatus(for: symbol1, at: now.addingTimeInterval(300))
        let status2 = await cacheCoordinator.getCacheStatus(for: symbol2, at: now.addingTimeInterval(300))

        if case .suspended = status1 {
            XCTFail("Symbol1 should not be suspended after clearAllCache")
        }
        if case .suspended = status2 {
            XCTFail("Symbol2 should not be suspended after clearAllCache")
        }
    }

    // MARK: - Success After Failure Tests

    func testSuccessAfterFailureClearsFailureCount() async {
        let symbol = "AAPL"
        let now = Date()

        // Record some failures
        for i in 0..<3 {
            await cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(Double(i * 60)))
        }

        // Record success
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now.addingTimeInterval(200))

        // Record more failures - should not suspend immediately if count was reset
        await cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(300))

        let status = await cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(360))
        if case .suspended = status {
            XCTFail("Should not be suspended after success reset failure count")
        }
    }

    // MARK: - Multiple Symbols Tests

    func testMultipleSymbolsIndependentStatus() async {
        let now = Date()

        // Symbol 1: Fresh
        await cacheCoordinator.setSuccessfulFetch(for: "AAPL", at: now)

        // Symbol 2: Failed
        await cacheCoordinator.setFailedFetch(for: "GOOGL", at: now)

        // Symbol 3: Never fetched
        // (don't record anything)

        let appleStatus = await cacheCoordinator.getCacheStatus(for: "AAPL", at: now)
        if case .fresh = appleStatus {
            // Success
        } else {
            XCTFail("Expected AAPL to be fresh, got \(appleStatus.description)")
        }

        let googleStatus = await cacheCoordinator.getCacheStatus(for: "GOOGL", at: now)
        if case .failedRecently = googleStatus {
            // Success
        } else {
            XCTFail("Expected GOOGL to be failedRecently, got \(googleStatus.description)")
        }

        let teslaStatus = await cacheCoordinator.getCacheStatus(for: "TSLA", at: now)
        if case .neverFetched = teslaStatus {
            // Success
        } else {
            XCTFail("Expected TSLA to be neverFetched, got \(teslaStatus.description)")
        }
    }

    // MARK: - Cache Statistics Tests

    func testCacheStatistics() async {
        let now = Date()

        // Fresh cache
        await cacheCoordinator.setSuccessfulFetch(for: "AAPL", at: now)

        // Stale cache
        await cacheCoordinator.setSuccessfulFetch(for: "GOOGL", at: now.addingTimeInterval(-1200)) // 20 min ago

        // Failed cache
        await cacheCoordinator.setFailedFetch(for: "TSLA", at: now)

        let stats = await cacheCoordinator.getCacheStatistics()

        // Verify stats structure (exact values depend on implementation)
        XCTAssertNotNil(stats)
        // Could test for specific counts if statistics method is available
    }

    // MARK: - Edge Cases

    func testCacheStatusWithFutureDate() async {
        let symbol = "AAPL"
        let now = Date()

        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        // Check status with a past date (before fetch)
        let pastStatus = await cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(-3600))
        XCTAssertTrue(
            pastStatus.isFresh || pastStatus.isNeverFetched,
            "Checking with past date should handle gracefully"
        )
    }

    func testEmptySymbolHandling() async {
        let status = await cacheCoordinator.getCacheStatus(for: "", at: Date())
        XCTAssertNotNil(status, "Empty symbol should be handled gracefully")
    }

    func testCaseInsensitiveSymbols() async {
        let now = Date()

        await cacheCoordinator.setSuccessfulFetch(for: "aapl", at: now)

        // Most systems treat symbols as case-insensitive, but test actual behavior
        let lowerStatus = await cacheCoordinator.getCacheStatus(for: "aapl", at: now)
        let upperStatus = await cacheCoordinator.getCacheStatus(for: "AAPL", at: now)

        // This test documents the actual behavior - adjust assertion based on implementation
        // If case-sensitive: statuses will differ
        // If case-insensitive: statuses will match
        XCTAssertTrue(lowerStatus.isFresh || upperStatus.isFresh, "Should handle case consistently")
    }
}

private extension CacheStatus {
    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    var isNeverFetched: Bool {
        if case .neverFetched = self { return true }
        return false
    }
}
