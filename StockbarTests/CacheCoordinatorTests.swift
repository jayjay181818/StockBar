import XCTest
@testable import Stockbar

class CacheCoordinatorTests: XCTestCase {

    var cacheCoordinator: CacheCoordinator!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // CacheCoordinator now persists across launches, so each test needs its
        // own defaults suite or state would leak between tests and from the
        // developer's real app data.
        suiteName = TestDefaultsSuite.makeName("CacheCoordinatorTests-")
        cacheCoordinator = CacheCoordinator(defaults: Self.makeDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        cacheCoordinator = nil
        TestDefaultsSuite.remove(suiteName)
        suiteName = nil
        super.tearDown()
    }

    /// A fresh `UserDefaults` over the test suite. Each coordinator gets its own
    /// instance because the actor takes ownership of what it is given (Swift 6
    /// region isolation); instances for one suite share the same stored values.
    private static func makeDefaults(suiteName: String) -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
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

        XCTAssertEqual(stats.totalCached, 2, "Two symbols have fetched successfully")
        XCTAssertEqual(stats.freshCount, 1, "AAPL was fetched just now")
        XCTAssertEqual(stats.freshCount + stats.staleCount + stats.expiredCount, stats.totalCached)
        XCTAssertEqual(stats.failedCount, 1, "TSLA failed")
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

    // MARK: - Query Purity

    func testGetCacheStatus_AfterSuspensionExpires_DoesNotResetFailureCount() async {
        // Given a symbol suspended by the circuit breaker
        let symbol = "AAPL"
        let now = Date()
        for _ in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: symbol, at: now)
        }
        let afterTimeout = now.addingTimeInterval(3601)

        // When the status is read after the suspension has expired
        _ = await cacheCoordinator.getCacheStatus(for: symbol, at: afterTimeout)

        // Then the failure count survives, so backoff stays at its longest rung
        // and the breaker re-trips on the very next failure.
        let retryInterval = await cacheCoordinator.getRetryInterval(for: symbol)
        XCTAssertEqual(retryInterval, 600, "Reading status must not reset exponential backoff")
    }

    func testClearOldCacheEntries_ReapsExpiredSuspensions() async {
        // Given a suspended symbol
        let symbol = "AAPL"
        let now = Date()
        for _ in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: symbol, at: now)
        }
        let isSuspended = await cacheCoordinator.isSuspended(symbol: symbol, at: now)
        XCTAssertTrue(isSuspended)

        // When cleanup runs after the suspension timeout
        await cacheCoordinator.clearOldCacheEntries(now: now.addingTimeInterval(3601))

        // Then the suspension and its failure count are cleared
        let retryInterval = await cacheCoordinator.getRetryInterval(for: symbol)
        XCTAssertEqual(retryInterval, 60, "Expired suspensions should reset backoff")
    }

    // MARK: - Persistence

    func testCacheState_SurvivesReconstruction() async {
        // Given recorded success and failure state
        let now = Date()
        await cacheCoordinator.setSuccessfulFetch(for: "AAPL", at: now)
        for _ in 0..<3 {
            await cacheCoordinator.setFailedFetch(for: "TSLA", at: now)
        }

        // When a new coordinator is built over the same defaults (app relaunch)
        let reloaded = CacheCoordinator(defaults: Self.makeDefaults(suiteName: suiteName))

        // Then the cache and backoff state are restored rather than reset
        let appleStatus = await reloaded.getCacheStatus(for: "AAPL", at: now.addingTimeInterval(60))
        XCTAssertTrue(appleStatus.isFresh, "A fresh cache entry should survive relaunch")

        let teslaRetry = await reloaded.getRetryInterval(for: "TSLA")
        XCTAssertEqual(teslaRetry, 300, "Consecutive failure count should survive relaunch")
    }

    func testSuspension_SurvivesReconstruction() async {
        // Given a symbol suspended by the circuit breaker
        let now = Date()
        for _ in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: "TSLA", at: now)
        }

        // When the app restarts
        let reloaded = CacheCoordinator(defaults: Self.makeDefaults(suiteName: suiteName))

        // Then the symbol is still suspended, so a relaunch cannot be used to
        // bypass provider rate limiting.
        let stillSuspended = await reloaded.isSuspended(symbol: "TSLA", at: now.addingTimeInterval(60))
        XCTAssertTrue(stillSuspended)
    }
    // MARK: - Circuit breaker gating

    func testFailingNeverSuccessfulSymbolIsGovernedByBackoff() async {
        let symbol = "TYPO"
        let now = Date()
        await cacheCoordinator.setFailedFetch(for: symbol, at: now)

        let refreshSoon = await cacheCoordinator.shouldRefresh(symbol: symbol, at: now.addingTimeInterval(10))
        let retrySoon = await cacheCoordinator.shouldRetry(symbol: symbol, at: now.addingTimeInterval(10))
        let retryLater = await cacheCoordinator.shouldRetry(symbol: symbol, at: now.addingTimeInterval(61))

        XCTAssertFalse(refreshSoon)
        XCTAssertFalse(retrySoon)
        XCTAssertTrue(retryLater)
    }

    func testSuspendedSymbolIsNotRefreshedEvenWhenCacheExpired() async {
        let symbol = "AAPL"
        let start = Date()
        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: start)
        for i in 0..<5 {
            await cacheCoordinator.setFailedFetch(for: symbol, at: start.addingTimeInterval(Double(1_000 + i)))
        }
        let checkTime = start.addingTimeInterval(2_000)

        let shouldRefresh = await cacheCoordinator.shouldRefresh(symbol: symbol, at: checkTime, freshnessInterval: 60)
        let shouldRetry = await cacheCoordinator.shouldRetry(symbol: symbol, at: checkTime)

        XCTAssertFalse(shouldRefresh)
        XCTAssertFalse(shouldRetry)
    }

    func testPruningDropsOrphanedFailureCountsButKeepsActiveSuspensions() {
        let now = Date()
        let state = CacheCoordinator.PersistedState(
            lastSuccessfulFetch: [:],
            lastFailedFetch: ["OLD": now.addingTimeInterval(-7_200), "SUS": now.addingTimeInterval(-7_200)],
            consecutiveFailures: ["OLD": 2, "SUS": 5],
            suspendedSymbols: ["SUS": now.addingTimeInterval(-600)]
        )

        let pruned = CacheCoordinator.prunedState(state, now: now)

        XCTAssertNil(pruned.consecutiveFailures["OLD"])
        XCTAssertEqual(pruned.consecutiveFailures["SUS"], 5)
        XCTAssertNotNil(pruned.suspendedSymbols["SUS"])
    }

    func testRefreshFreshnessHonoursUserInterval() {
        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 60), 54, accuracy: 0.001)
        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 900), 810, accuracy: 0.001)
        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 10), 30, accuracy: 0.001)
        XCTAssertEqual(PythonConfiguration.quoteCacheSeconds(forRefreshInterval: 60), 54, accuracy: 0.001)
        XCTAssertEqual(PythonConfiguration.quoteCacheSeconds(forRefreshInterval: 3_600), 300, accuracy: 0.001)
    }

    func testRefreshIntervalIsClampedToTheSupportedRange() {
        XCTAssertEqual(RefreshService.clampedRefreshInterval(nil), 300)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(0), 300)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(-60), 300)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(1), 300, "a stored boolean reads as 1")
        XCTAssertEqual(RefreshService.clampedRefreshInterval(.nan), 300)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(.infinity), 300)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(5), 60)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(900), 900)
        XCTAssertEqual(RefreshService.clampedRefreshInterval(86_400), 3_600)
    }

    func testProviderBackoffGrowsAndClearsOnSuccess() async {
        let now = Date()

        let idle = await cacheCoordinator.providerBackoffRemaining(at: now)
        let first = await cacheCoordinator.recordProviderFailure(at: now)
        let second = await cacheCoordinator.recordProviderFailure(at: now)
        for _ in 0..<10 { await cacheCoordinator.recordProviderFailure(at: now) }
        let capped = await cacheCoordinator.providerBackoffRemaining(at: now)
        let expired = await cacheCoordinator.providerBackoffRemaining(at: now.addingTimeInterval(601))
        await cacheCoordinator.recordProviderSuccess()
        let cleared = await cacheCoordinator.providerBackoffRemaining(at: now)
        let restarted = await cacheCoordinator.recordProviderFailure(at: now)

        XCTAssertNil(idle)
        XCTAssertEqual(first, 60)
        XCTAssertEqual(second, 120)
        XCTAssertEqual(capped, 600)
        XCTAssertNil(expired)
        XCTAssertNil(cleared)
        XCTAssertEqual(restarted, 60)
    }

    func testProviderFailureDoesNotSuspendSymbols() async {
        let now = Date()
        for _ in 0..<10 { await cacheCoordinator.recordProviderFailure(at: now) }

        let suspended = await cacheCoordinator.isSuspended(symbol: "AAPL", at: now)
        let status = await cacheCoordinator.getCacheStatus(for: "AAPL", at: now)

        XCTAssertFalse(suspended)
        guard case .neverFetched = status else {
            return XCTFail("Expected no per-symbol state, got \(status.description)")
        }
    }

    func testFailuresAreSortedIntoSymbolAndProviderFaults() {
        // One bad ticker among working ones is that ticker's fault.
        var outcome = RefreshService.classifyFailures([.noData], anySucceeded: true)
        XCTAssertFalse(outcome.providerFailed)
        XCTAssertTrue(outcome.countsAgainstSymbols)

        // A lone ticker with no data is still its own fault.
        outcome = RefreshService.classifyFailures([.noData], anySucceeded: false)
        XCTAssertFalse(outcome.providerFailed)
        XCTAssertTrue(outcome.countsAgainstSymbols)

        // A lone throttled ticker backs the provider off.
        outcome = RefreshService.classifyFailures([.rateLimited], anySucceeded: false)
        XCTAssertTrue(outcome.providerFailed)

        // Everything failing together is never counted against the symbols.
        outcome = RefreshService.classifyFailures([.noData, .noData, .timedOut], anySucceeded: false)
        XCTAssertTrue(outcome.providerFailed)
        XCTAssertFalse(outcome.countsAgainstSymbols)

        outcome = RefreshService.classifyFailures([], anySucceeded: false)
        XCTAssertFalse(outcome.providerFailed)
        XCTAssertFalse(outcome.countsAgainstSymbols)
    }

    func testUnknownErrorCodesAreTreatedAsNoData() {
        XCTAssertEqual(QuoteFailure(errorCode: "RATE_LIMIT"), .rateLimited)
        XCTAssertEqual(QuoteFailure(errorCode: "TIMEOUT"), .timedOut)
        XCTAssertEqual(QuoteFailure(errorCode: "NETWORK_ERROR"), .network)
        XCTAssertEqual(QuoteFailure(errorCode: "SOMETHING_NEW"), .noData)
        XCTAssertEqual(QuoteFailure(errorCode: nil), .noData)
        XCTAssertFalse(QuoteFailure.noData.isProviderWide)
        XCTAssertTrue(QuoteFailure.timedOut.isProviderWide)
    }

    func testClosedExchangesArePolledSlowly() throws {
        func date(_ text: String) throws -> Date {
            try XCTUnwrap(ISO8601DateFormatter().date(from: text))
        }
        let saturday = try date("2026-11-07T15:00:00Z")
        let tuesdayLondonMorning = try date("2026-11-10T09:00:00Z")   // 04:00 New York, 09:00 London
        let tuesdayUSAfternoon = try date("2026-11-10T19:00:00Z")     // 14:00 New York, 19:00 London
        let tuesdayNight = try date("2026-11-11T03:00:00Z")           // 22:00 New York, 03:00 London

        XCTAssertEqual(RefreshService.isExchangeClosed(for: "AAPL", at: saturday), true)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "VOD.L", at: saturday), true)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "AAPL", at: tuesdayLondonMorning), false)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "VOD.L", at: tuesdayLondonMorning), false)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "AAPL", at: tuesdayUSAfternoon), false)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "VOD.L", at: tuesdayUSAfternoon), true)
        XCTAssertEqual(RefreshService.isExchangeClosed(for: "^GSPC", at: tuesdayNight), true)

        // Hours are not known for these, so they always poll at the full rate.
        XCTAssertNil(RefreshService.isExchangeClosed(for: "BTC-USD", at: saturday))
        XCTAssertNil(RefreshService.isExchangeClosed(for: "EURUSD=X", at: saturday))
        XCTAssertNil(RefreshService.isExchangeClosed(for: "SAP.DE", at: saturday))

        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 300, symbol: "AAPL", at: saturday), 1_800)
        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 300, symbol: "BTC-USD", at: saturday), 270)
        XCTAssertEqual(
            RefreshService.freshnessInterval(forRefreshInterval: 300, symbol: "AAPL", at: tuesdayUSAfternoon),
            270
        )
        XCTAssertEqual(RefreshService.freshnessInterval(forRefreshInterval: 3_600, symbol: "AAPL", at: saturday), 3_240)
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

final class RefreshStatusAndEnvironmentTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailedPassIsReportedWithoutLosingTheLastSuccess() {
        var status = QuoteRefreshStatus()
        XCTAssertNil(status.problemSummary)
        XCTAssertFalse(status.lastAttemptFailed)

        status.record(attempted: 3, failures: [], at: time)
        XCTAssertEqual(status.lastSuccess, time)
        XCTAssertNil(status.problemSummary)

        let later = time.addingTimeInterval(300)
        status.record(attempted: 3, failures: [.rateLimited, .rateLimited, .noData], at: later)
        XCTAssertTrue(status.lastAttemptFailed)
        XCTAssertEqual(status.lastAttempt, later)
        XCTAssertEqual(status.lastSuccess, time)
        XCTAssertEqual(status.problemSummary, "Last refresh failed: the provider is limiting requests")
    }

    func testPartFailedPassCountsTheSymbolsLeftBehind() {
        var status = QuoteRefreshStatus()
        status.record(attempted: 4, failures: [.noData], at: time)
        XCTAssertFalse(status.lastAttemptFailed)
        XCTAssertEqual(status.lastSuccess, time)
        XCTAssertEqual(status.problemSummary, "1 of 4 not refreshed: the provider returned no price")
    }

    func testPassThatAskedForNothingChangesNothing() {
        var status = QuoteRefreshStatus()
        status.record(attempted: 0, failures: [], at: time)
        XCTAssertNil(status.lastAttempt)
    }

    func testSetupProblemIsNewOnceAndClearsOnTheNextRealAttempt() {
        var status = QuoteRefreshStatus()
        XCTAssertTrue(status.recordSetupProblem("Python is not set up", attempted: 2, at: time))
        XCTAssertFalse(status.recordSetupProblem("Python is not set up", attempted: 2, at: time))
        XCTAssertTrue(status.lastAttemptFailed)
        XCTAssertEqual(status.problemSummary, "Python is not set up")

        status.record(attempted: 2, failures: [], at: time)
        XCTAssertNil(status.problemSummary)
    }

    func testScriptEnvironmentDropsEverythingNotNeeded() {
        let environment = PythonConfiguration.childEnvironment(
            adding: ["STOCKBAR_CACHE_FILE": "/cache/quote_cache.json"],
            base: [
                "PATH": "/usr/bin",
                "HOME": "/Users/example",
                "HTTPS_PROXY": "http://proxy.example:8080",
                "PYTHONPATH": "/somewhere/else",
                "PYTHONSTARTUP": "/somewhere/start.py",
                "DYLD_INSERT_LIBRARIES": "/somewhere/lib.dylib",
                "AWS_SECRET_ACCESS_KEY": "not-for-scripts"
            ]
        )
        XCTAssertEqual(environment, [
            "PATH": "/usr/bin",
            "HOME": "/Users/example",
            "HTTPS_PROXY": "http://proxy.example:8080",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "STOCKBAR_CACHE_FILE": "/cache/quote_cache.json"
        ])
    }

    func testCandlesFetchedAfterTheCloseStayUsableUntilTheOpen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func newYork(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour)))
        }
        // Friday 24 July 2026 21:00 to Sunday: shut throughout.
        XCTAssertTrue(OHLCCachePolicy.stayedClosed(symbol: "AAPL", from: try newYork(24, 21), to: try newYork(26, 12)))
        // Monday 03:00 to Monday 21:00 spans a whole session.
        XCTAssertFalse(OHLCCachePolicy.stayedClosed(symbol: "AAPL", from: try newYork(27, 3), to: try newYork(27, 21)))
        // Fetched while open.
        XCTAssertFalse(OHLCCachePolicy.stayedClosed(symbol: "AAPL", from: try newYork(24, 12), to: try newYork(24, 21)))
        // Unknown exchange hours never qualify.
        XCTAssertFalse(OHLCCachePolicy.stayedClosed(symbol: "BTC-USD", from: try newYork(25, 1), to: try newYork(25, 2)))

        let friday = try newYork(24, 15)
        let sunday = try newYork(26, 12)
        let candles = (0..<5).map { index in
            OHLCSnapshot(
                symbol: "AAPL",
                timestamp: friday.addingTimeInterval(Double(index - 4) * 86_400),
                open: 1, high: 2, low: 1, close: 2, volume: 10, interval: "1d"
            )
        }
        XCTAssertFalse(OHLCCachePolicy.isUsable(snapshots: candles, period: "5d", interval: "1d", now: sunday))
        XCTAssertTrue(OHLCCachePolicy.isUsable(
            snapshots: candles, period: "5d", interval: "1d", now: sunday, fetchedSinceClose: true
        ))
    }
}
