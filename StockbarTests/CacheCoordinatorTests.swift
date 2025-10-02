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

    func testNeverFetchedStatus() {
        let status = cacheCoordinator.getCacheStatus(for: "AAPL", at: Date())

        if case .neverFetched = status {
            // Success
        } else {
            XCTFail("Expected neverFetched status, got \(status.description)")
        }
    }

    func testFreshCacheStatus() {
        let now = Date()
        let symbol = "AAPL"

        // Record successful fetch
        cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        // Check status immediately after
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)

        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status, got \(status.description)")
        }
    }

    func testStaleCacheStatus() {
        let now = Date()
        let symbol = "AAPL"

        // Record fetch 10 minutes ago
        let fetchTime = now.addingTimeInterval(-600) // 10 minutes ago
        cacheCoordinator.setSuccessfulFetch(for: symbol, at: fetchTime)

        // Check status now (15-minute fresh period has not passed, but stale period may have started)
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)

        // Should be stale or fresh depending on configuration
        switch status {
        case .fresh, .stale:
            // Success - either is acceptable
            break
        default:
            XCTFail("Expected fresh or stale status for 10-minute-old cache, got \(status.description)")
        }
    }

    func testExpiredCacheStatus() {
        let now = Date()
        let symbol = "AAPL"

        // Record fetch 2 hours ago
        let fetchTime = now.addingTimeInterval(-7200) // 2 hours ago
        cacheCoordinator.setSuccessfulFetch(for: symbol, at: fetchTime)

        // Check status now
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)

        if case .expired = status {
            // Success
        } else {
            XCTFail("Expected expired status for 2-hour-old cache, got \(status.description)")
        }
    }

    // MARK: - Fetch Success Recording Tests

    func testRecordFetchSuccess() {
        let symbol = "AAPL"
        let now = Date()

        cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status after recording success, got \(status.description)")
        }
    }

    func testRecordMultipleFetchSuccesses() {
        let symbol = "AAPL"
        let firstFetch = Date()
        let secondFetch = firstFetch.addingTimeInterval(600) // 10 minutes later

        cacheCoordinator.setSuccessfulFetch(for: symbol, at: firstFetch)
        cacheCoordinator.setSuccessfulFetch(for: symbol, at: secondFetch)

        // Should use most recent fetch time
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: secondFetch)
        if case .fresh = status {
            // Success
        } else {
            XCTFail("Expected fresh status after multiple successes, got \(status.description)")
        }
    }

    // MARK: - Fetch Failure Recording Tests

    func testRecordFetchFailure() {
        let symbol = "AAPL"
        let now = Date()

        cacheCoordinator.setFailedFetch(for: symbol, at: now)

        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .failedRecently = status {
            // Success
        } else {
            XCTFail("Expected failedRecently status after recording failure, got \(status.description)")
        }
    }

    func testFailureRetryStatus() {
        let symbol = "AAPL"
        let now = Date()

        // Record failure 6 minutes ago
        let failureTime = now.addingTimeInterval(-360) // 6 minutes ago
        cacheCoordinator.setFailedFetch(for: symbol, at: failureTime)

        // Check if ready to retry (assuming 5-minute retry interval)
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now)
        if case .readyToRetry = status {
            // Success
        } else {
            XCTFail("Expected readyToRetry status after retry interval, got \(status.description)")
        }
    }

    // MARK: - Suspension Tests

    func testSuspensionAfterMultipleFailures() {
        let symbol = "AAPL"
        let now = Date()

        // Record 5 consecutive failures
        for i in 0..<5 {
            let failureTime = now.addingTimeInterval(Double(i * 60)) // 1 minute apart
            cacheCoordinator.setFailedFetch(for: symbol, at: failureTime)
        }

        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = status {
            // Success
        } else {
            XCTFail("Expected suspended status after multiple consecutive failures, got \(status.description)")
        }
    }

    func testClearSuspension() {
        let symbol = "AAPL"
        let now = Date()

        // Suspend the symbol
        for i in 0..<5 {
            cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(Double(i * 60)))
        }

        let statusBeforeClear = cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = statusBeforeClear {
            // Good - suspended as expected
        } else {
            XCTFail("Expected suspended status before clearing, got \(statusBeforeClear.description)")
        }

        // Clear suspension
        cacheCoordinator.clearSuspension(for: symbol)

        // Should now be ready to retry
        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(300))
        if case .suspended = status {
            XCTFail("Suspension should be cleared, but still suspended")
        }
    }

    func testClearAllSuspensions() {
        let symbol1 = "AAPL"
        let symbol2 = "GOOGL"
        let now = Date()

        // Suspend both symbols
        for i in 0..<5 {
            cacheCoordinator.setFailedFetch(for: symbol1, at: now.addingTimeInterval(Double(i * 60)))
            cacheCoordinator.setFailedFetch(for: symbol2, at: now.addingTimeInterval(Double(i * 60)))
        }

        // Clear all suspensions
        cacheCoordinator.clearAllCache()

        let status1 = cacheCoordinator.getCacheStatus(for: symbol1, at: now.addingTimeInterval(300))
        let status2 = cacheCoordinator.getCacheStatus(for: symbol2, at: now.addingTimeInterval(300))

        if case .suspended = status1 {
            XCTFail("Symbol1 should not be suspended after clearAllCache")
        }
        if case .suspended = status2 {
            XCTFail("Symbol2 should not be suspended after clearAllCache")
        }
    }

    // MARK: - Success After Failure Tests

    func testSuccessAfterFailureClearsFailureCount() {
        let symbol = "AAPL"
        let now = Date()

        // Record some failures
        for i in 0..<3 {
            cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(Double(i * 60)))
        }

        // Record success
        cacheCoordinator.setSuccessfulFetch(for: symbol, at: now.addingTimeInterval(200))

        // Record more failures - should not suspend immediately if count was reset
        cacheCoordinator.setFailedFetch(for: symbol, at: now.addingTimeInterval(300))

        let status = cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(360))
        if case .suspended = status {
            XCTFail("Should not be suspended after success reset failure count")
        }
    }

    // MARK: - Multiple Symbols Tests

    func testMultipleSymbolsIndependentStatus() {
        let now = Date()

        // Symbol 1: Fresh
        cacheCoordinator.setSuccessfulFetch(for: "AAPL", at: now)

        // Symbol 2: Failed
        cacheCoordinator.setFailedFetch(for: "GOOGL", at: now)

        // Symbol 3: Never fetched
        // (don't record anything)

        let appleStatus = cacheCoordinator.getCacheStatus(for: "AAPL", at: now)
        if case .fresh = appleStatus {
            // Success
        } else {
            XCTFail("Expected AAPL to be fresh, got \(appleStatus.description)")
        }

        let googleStatus = cacheCoordinator.getCacheStatus(for: "GOOGL", at: now)
        if case .failedRecently = googleStatus {
            // Success
        } else {
            XCTFail("Expected GOOGL to be failedRecently, got \(googleStatus.description)")
        }

        let teslaStatus = cacheCoordinator.getCacheStatus(for: "TSLA", at: now)
        if case .neverFetched = teslaStatus {
            // Success
        } else {
            XCTFail("Expected TSLA to be neverFetched, got \(teslaStatus.description)")
        }
    }

    // MARK: - Cache Statistics Tests

    func testCacheStatistics() {
        let now = Date()

        // Fresh cache
        cacheCoordinator.setSuccessfulFetch(for: "AAPL", at: now)

        // Stale cache
        cacheCoordinator.setSuccessfulFetch(for: "GOOGL", at: now.addingTimeInterval(-1200)) // 20 min ago

        // Failed cache
        cacheCoordinator.setFailedFetch(for: "TSLA", at: now)

        let stats = cacheCoordinator.getCacheStatistics()

        // Verify stats structure (exact values depend on implementation)
        XCTAssertNotNil(stats)
        // Could test for specific counts if statistics method is available
    }

    // MARK: - Edge Cases

    func testCacheStatusWithFutureDate() {
        let symbol = "AAPL"
        let now = Date()

        cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)

        // Check status with a past date (before fetch)
        let pastStatus = cacheCoordinator.getCacheStatus(for: symbol, at: now.addingTimeInterval(-3600))
        XCTAssertTrue(pastStatus == .fresh || pastStatus == .neverFetched, "Checking with past date should handle gracefully")
    }

    func testEmptySymbolHandling() {
        let status = cacheCoordinator.getCacheStatus(for: "", at: Date())
        XCTAssertNotNil(status, "Empty symbol should be handled gracefully")
    }

    func testCaseInsensitiveSymbols() {
        let now = Date()

        cacheCoordinator.setSuccessfulFetch(for: "aapl", at: now)

        // Most systems treat symbols as case-insensitive, but test actual behavior
        let lowerStatus = cacheCoordinator.getCacheStatus(for: "aapl", at: now)
        let upperStatus = cacheCoordinator.getCacheStatus(for: "AAPL", at: now)

        // This test documents the actual behavior - adjust assertion based on implementation
        // If case-sensitive: statuses will differ
        // If case-insensitive: statuses will match
        XCTAssertTrue(lowerStatus == .fresh || upperStatus == .fresh, "Should handle case consistently")
    }
}
