import XCTest
@testable import Stockbar

class CurrencyConverterTests: XCTestCase {

    var converter: CurrencyConverter!

    override func setUp() {
        super.setUp()
        converter = CurrencyConverter(
            exchangeRates: [
            "USD": 1.0,
            "GBP": 0.79,
            "EUR": 0.92,
            "JPY": 149.50,
            "CAD": 1.36,
            "AUD": 1.53
            ],
            refreshOnInit: false,
            loadHistoryOnInit: false
        )
    }

    override func tearDown() {
        converter = nil
        super.tearDown()
    }

    // MARK: - Basic Currency Conversion Tests

    func testUSDToGBPConversion() {
        let result = converter.convert(amount: 100, from: "USD", to: "GBP")
        XCTAssertEqual(result, 79.0, accuracy: 0.01, "100 USD should convert to approximately 79 GBP")
    }

    func testGBPToUSDConversion() {
        let result = converter.convert(amount: 79, from: "GBP", to: "USD")
        XCTAssertEqual(result, 100.0, accuracy: 0.01, "79 GBP should convert to approximately 100 USD")
    }

    func testSameCurrencyConversion() {
        let result = converter.convert(amount: 100, from: "USD", to: "USD")
        XCTAssertEqual(result, 100.0, "Converting to same currency should return same amount")
    }

    func testMultipleCurrencyPairs() {
        // USD -> EUR
        let usdToEur = converter.convert(amount: 100, from: "USD", to: "EUR")
        XCTAssertEqual(usdToEur, 92.0, accuracy: 0.01)

        // EUR -> JPY
        let eurToJpy = converter.convert(amount: 100, from: "EUR", to: "JPY")
        XCTAssertGreaterThan(eurToJpy, 0)

        // JPY -> CAD
        let jpyToCad = converter.convert(amount: 1000, from: "JPY", to: "CAD")
        XCTAssertGreaterThan(jpyToCad, 0)
    }

    // MARK: - GBX to GBP Conversion Tests (Critical for UK stocks)

    func testGBXToGBPConversion() {
        // GBX is pence, GBP is pounds (1 GBP = 100 GBX)
        let result = converter.convert(amount: 150, from: "GBX", to: "GBP")
        XCTAssertEqual(result, 1.5, accuracy: 0.001, "150 pence should equal 1.5 pounds")
    }

    func testGBPToGBXConversion() {
        let result = converter.convert(amount: 1.5, from: "GBP", to: "GBX")
        XCTAssertEqual(result, 150.0, accuracy: 0.01, "1.5 pounds should equal 150 pence")
    }

    func testGBXToUSDConversion() {
        // GBX -> GBP -> USD
        let result = converter.convert(amount: 100, from: "GBX", to: "USD")
        // 100 GBX = 1 GBP, 1 GBP ≈ 1.266 USD (1 / 0.79)
        XCTAssertEqual(result, 1.266, accuracy: 0.01)
    }

    func testUSDToGBXConversion() {
        // USD -> GBP -> GBX
        let result = converter.convert(amount: 1.266, from: "USD", to: "GBX")
        // 1.266 USD ≈ 1 GBP = 100 GBX
        XCTAssertEqual(result, 100.0, accuracy: 1.0)
    }

    // MARK: - Edge Case Tests

    func testZeroAmountConversion() {
        let result = converter.convert(amount: 0, from: "USD", to: "GBP")
        XCTAssertEqual(result, 0.0, "Converting zero should return zero")
    }

    func testNegativeAmountConversion() {
        let result = converter.convert(amount: -100, from: "USD", to: "GBP")
        XCTAssertEqual(result, -79.0, accuracy: 0.01, "Negative amounts should convert correctly")
    }

    func testNaNConversion() {
        let result = converter.convert(amount: Double.nan, from: "USD", to: "GBP")
        XCTAssertTrue(result.isNaN, "Converting NaN should return NaN")
    }

    func testInfinityConversion() {
        let result = converter.convert(amount: Double.infinity, from: "USD", to: "GBP")
        XCTAssertTrue(result.isInfinite, "Converting infinity should return infinity")
    }

    func testVeryLargeAmountConversion() {
        let result = converter.convert(amount: 1_000_000_000, from: "USD", to: "GBP")
        XCTAssertGreaterThan(result, 0)
        XCTAssertTrue(result.isFinite)
    }

    func testVerySmallAmountConversion() {
        let result = converter.convert(amount: 0.0001, from: "USD", to: "GBP")
        XCTAssertGreaterThan(result, 0)
        XCTAssertLessThan(result, 1)
    }

    // MARK: - Invalid Currency Tests

    func testInvalidSourceCurrency() {
        let result = converter.convert(amount: 100, from: "XXX", to: "USD")
        XCTAssertEqual(result, 100.0, "Unknown source currency should return original amount")
    }

    func testInvalidTargetCurrency() {
        let result = converter.convert(amount: 100, from: "USD", to: "XXX")
        XCTAssertEqual(result, 100.0, "Unknown target currency should return original amount")
    }

    func testEmptySourceCurrency() {
        let result = converter.convert(amount: 100, from: "", to: "USD")
        XCTAssertEqual(result, 100.0)
    }

    func testEmptyTargetCurrency() {
        let result = converter.convert(amount: 100, from: "USD", to: "")
        XCTAssertEqual(result, 100.0)
    }

    // MARK: - Rate Availability Tests

    func testAllSupportedCurrenciesHaveRates() {
        let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"]

        for currency in supportedCurrencies {
            XCTAssertNotNil(converter.exchangeRates[currency], "\(currency) should have an exchange rate")
            XCTAssertGreaterThan(converter.exchangeRates[currency] ?? 0, 0, "\(currency) rate should be positive")
        }
    }

    func testRoundTripConversion() {
        // Convert USD -> GBP -> USD should return original amount (within rounding)
        let original = 100.0
        let toGBP = converter.convert(amount: original, from: "USD", to: "GBP")
        let backToUSD = converter.convert(amount: toGBP, from: "GBP", to: "USD")

        XCTAssertEqual(backToUSD, original, accuracy: 0.01, "Round-trip conversion should preserve value")
    }

    func testActivatesLatestHistoricalRatesBeforeHardCodedFallback() throws {
        let suiteName = "CurrencyConverterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "currencyRateHistory"

        let historicalSnapshot = CurrencyRateSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            rates: ["GBP": 0.752, "EUR": 0.91],
            baseCurrency: "USD"
        )
        defaults.set(try JSONEncoder().encode([historicalSnapshot]), forKey: key)

        let historicalConverter = CurrencyConverter(
            exchangeRates: [:],
            refreshOnInit: false,
            loadHistoryOnInit: true,
            defaults: defaults
        )

        XCTAssertTrue(historicalConverter.activateLatestHistoricalRatesIfAvailable())
        XCTAssertEqual(historicalConverter.convert(amount: 100, from: "USD", to: "GBP"), 75.2, accuracy: 0.01)
        XCTAssertEqual(historicalConverter.lastRefreshTime, historicalSnapshot.timestamp)
    }

    func testGBXRoundTripConversion() {
        // Convert GBX -> USD -> GBX should return original amount (within rounding)
        let original = 350.0 // 350 pence
        let toUSD = converter.convert(amount: original, from: "GBX", to: "USD")
        let backToGBX = converter.convert(amount: toUSD, from: "USD", to: "GBX")

        XCTAssertEqual(backToGBX, original, accuracy: 1.0, "GBX round-trip conversion should preserve value")
    }

    func testFolyncUSDBaseRatesDriveCrossConversionWithoutLegacyRequest() async {
        let legacyRequests = LockedRequestCounter()
        let router = FixedFolyncFXRouter(result: .folync(
            rates: ["USD": 1, "GBP": 0.8, "EUR": 0.9, "JPY": 150, "CAD": 1.35, "AUD": 1.5],
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            status: .current
        ))
        let folyncConverter = CurrencyConverter(
            exchangeRates: ["USD": 1, "GBP": 0.75, "EUR": 0.85],
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: router,
            legacyRefreshObserver: { legacyRequests.increment() }
        )

        await folyncConverter.refreshRatesFromConfiguredSource(force: true)

        XCTAssertEqual(folyncConverter.convert(amount: 80, from: "GBP", to: "EUR"), 90, accuracy: 0.001)
        XCTAssertEqual(folyncConverter.convert(amount: 100, from: "GBP", to: "GBX"), 10_000, accuracy: 0.001)
        XCTAssertEqual(folyncConverter.getExchangeRateInfo(from: "USD", to: "GBX").rate, 80, accuracy: 0.001)
        XCTAssertEqual(folyncConverter.getExchangeRateInfo(from: "GBp", to: "USD").rate, 0.0125, accuracy: 0.000_001)
        XCTAssertEqual(folyncConverter.getExchangeRateInfo(from: "GBP", to: "GBX").rate, 100, accuracy: 0.001)
        XCTAssertEqual(folyncConverter.getExchangeRateInfo(from: "GBX", to: "GBP").rate, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(folyncConverter.sourceStatus, .current)
        XCTAssertTrue(folyncConverter.lastRefreshSuccess)
        XCTAssertEqual(legacyRequests.value, 0)
        let requestCount = await router.requestCount
        XCTAssertEqual(requestCount, 1)

        await folyncConverter.deactivateFolyncOverlay()
        XCTAssertEqual(folyncConverter.exchangeRates["GBP"], 0.75)
        XCTAssertEqual(folyncConverter.sourceStatus, .legacy)
    }

    func testFailedRefreshDoesNotReportRatesAsJustUpdatedButStillThrottles() async {
        let router = FixedFolyncFXRouter(result: .unavailable)
        let converter = CurrencyConverter(
            exchangeRates: [:],
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: router
        )

        await converter.refreshRatesFromConfiguredSource(force: true)
        await converter.refreshRatesFromConfiguredSource(force: false)

        XCTAssertEqual(converter.lastRefreshTime, .distantPast)
        XCTAssertEqual(converter.getTimeSinceRefresh(), "Never")
        XCTAssertFalse(converter.lastRefreshSuccess)
        let requestCount = await router.requestCount
        XCTAssertEqual(requestCount, 1, "A failed attempt must still start the retry cooldown")
    }

    @MainActor
    func testFreshInstallWarnsAboutHardCodedRatesAfterFirstAttemptFails() async {
        let converter = CurrencyConverter(
            exchangeRates: [:], refreshOnInit: false, loadHistoryOnInit: false,
            supplementalRouter: FixedFolyncFXRouter(result: .legacy))

        // Before any refresh attempt finishes, conversions are "not ready", not "degraded".
        _ = converter.convert(amount: 100, from: "USD", to: "GBP")
        await Task.yield()
        XCTAssertFalse(converter.isUsingFallbackRates)

        // The first attempt fails with no saved history: lastRefreshTime stays distantPast.
        converter.finishFailedLegacyRefresh()
        for _ in 0..<100 where !converter.isUsingFallbackRates { await Task.yield() }

        XCTAssertEqual(converter.lastRefreshTime, .distantPast)
        XCTAssertTrue(converter.isUsingFallbackRates, "a fresh install on hard-coded rates must be flagged")
        XCTAssertEqual(converter.convert(amount: 100, from: "USD", to: "GBP"), 74, accuracy: 0.001)
    }

    @MainActor
    func testFailedLegacyRefreshRetriesSoonAndSuccessCancelsTheRetry() async throws {
        let suiteName = "CurrencyRetry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // refreshOnInit starts the hourly timer; the router keeps it offline.
        let converter = CurrencyConverter(
            exchangeRates: [:], refreshOnInit: true, loadHistoryOnInit: false,
            supplementalRouter: FixedFolyncFXRouter(result: .unavailable), defaults: defaults)

        converter.finishFailedLegacyRefresh()
        XCTAssertTrue(converter.hasPendingFailedRefreshRetry, "a failed fetch must retry before the next hourly refresh")
        XCTAssertLessThan(CurrencyConverter.failedRefreshRetryDelay, 3_600)

        converter.finishSuccessfulLegacyRefresh(rates: ["USD": 1, "GBP": 0.75])
        XCTAssertFalse(converter.hasPendingFailedRefreshRetry)
        XCTAssertTrue(converter.lastRefreshSuccess)
        XCTAssertEqual(converter.exchangeRates["GBP"], 0.75)
    }

    @MainActor
    func testConverterWithoutScheduledRefreshesDoesNotRetry() {
        let converter = CurrencyConverter(
            exchangeRates: [:], refreshOnInit: false, loadHistoryOnInit: false,
            supplementalRouter: FixedFolyncFXRouter(result: .legacy))

        converter.finishFailedLegacyRefresh()

        XCTAssertFalse(converter.hasPendingFailedRefreshRetry)
    }

    func testIncompleteFolyncCrossRateNeverSplicesHardCodedLegacyValues() async {
        let legacyRequests = LockedRequestCounter()
        let router = FixedFolyncFXRouter(result: .folync(
            rates: ["USD": 1, "GBP": 0.8],
            asOf: Date(timeIntervalSince1970: 1_700_000_000),
            status: .partial
        ))
        let converter = CurrencyConverter(
            exchangeRates: ["USD": 1, "GBP": 0.75, "EUR": 0.85],
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: router,
            legacyRefreshObserver: { legacyRequests.increment() }
        )

        await converter.refreshRatesFromConfiguredSource(force: true)

        XCTAssertTrue(converter.convert(amount: 80, from: "GBP", to: "EUR").isNaN)
        XCTAssertEqual(converter.sourceStatus, .partial)
        XCTAssertEqual(legacyRequests.value, 0)
    }

    func testMinorUnitCurrenciesConvertThroughTheirMajorCurrency() {
        let converter = CurrencyConverter(
            exchangeRates: ["USD": 1, "ZAR": 18, "ILS": 3.7],
            refreshOnInit: false,
            loadHistoryOnInit: false
        )

        XCTAssertEqual(converter.convert(amount: 1_800, from: "ZAc", to: "USD"), 1, accuracy: 0.000_001)
        XCTAssertEqual(converter.convert(amount: 1_800, from: "ZAC", to: "USD"), 1, accuracy: 0.000_001)
        XCTAssertEqual(converter.convert(amount: 370, from: "ILA", to: "USD"), 1, accuracy: 0.000_001)
        XCTAssertEqual(converter.convert(amount: 1, from: "USD", to: "ILA"), 370, accuracy: 0.000_001)
        XCTAssertEqual(CurrencyConverter.minorUnitMajorCurrency("GBX"), "GBP")
        XCTAssertNil(CurrencyConverter.minorUnitMajorCurrency("USD"))
    }

    func testRatesBecomeStaleAfterADayWithoutARefresh() async {
        let router = FixedFolyncFXRouter(result: .folync(
            rates: ["USD": 1, "GBP": 0.8],
            asOf: Date(),
            status: .current
        ))
        let converter = CurrencyConverter(
            exchangeRates: ["USD": 1, "GBP": 0.75],
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: router
        )

        await converter.refreshRatesFromConfiguredSource(force: true)

        XCTAssertFalse(converter.ratesAreStale(now: Date()))
        XCTAssertTrue(converter.ratesAreStale(now: Date().addingTimeInterval(25 * 3600)))
    }

    @MainActor
    func testPositionWithoutAnExchangeRateIsLeftOutOfTotals() async {
        let router = FixedFolyncFXRouter(result: .folync(
            rates: ["USD": 1, "GBP": 0.8],
            asOf: Date(),
            status: .partial
        ))
        let converter = CurrencyConverter(
            exchangeRates: ["USD": 1, "GBP": 0.75, "CHF": 0.9],
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: router
        )
        await converter.refreshRatesFromConfiguredSource(force: true)
        XCTAssertTrue(converter.convert(amount: 1, from: "CHF", to: "USD").isNaN)

        let trades = [
            makeTrade(symbol: "AAPL", currency: "USD", price: 110, previousClose: 100),
            makeTrade(symbol: "NESN.SW", currency: "CHF", price: 90, previousClose: 80)
        ]
        let service = PortfolioCalculationService(currencyConverter: converter)
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(summary.totalValue, 1_100, accuracy: 0.001)
        XCTAssertEqual(summary.totalCost, 1_000, accuracy: 0.001)
        XCTAssertEqual(summary.dayGain, 100, accuracy: 0.001)
        XCTAssertEqual(summary.ownedPositionCount, 1)
        XCTAssertTrue(service.calculateNetGains(trades: trades, preferredCurrency: "USD").amount.isFinite)
        XCTAssertTrue(service.calculateNetValue(trades: trades, preferredCurrency: "USD").amount.isFinite)
    }

    private func makeTrade(symbol: String, currency: String, price: Double, previousClose: Double) -> RealTimeTrade {
        var info = TradingInfo()
        info.currentPrice = price
        info.prevClosePrice = previousClose
        info.currency = currency
        let trade = Trade(
            name: symbol,
            position: Position(unitSize: "10", positionAvgCost: "100", currency: currency, costCurrency: currency)
        )
        return RealTimeTrade(trade: trade, realTimeInfo: info)
    }
}

private actor FixedFolyncFXRouter: FolyncSupplementalFXRouting {
    let result: FolyncRoutedFXResult
    private(set) var requestCount = 0

    init(result: FolyncRoutedFXResult) {
        self.result = result
    }

    func routeFX() async -> FolyncRoutedFXResult {
        requestCount += 1
        return result
    }
}

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class UKPriceScaleRepairTests: XCTestCase {
    func testScaleRuleOnlyAffectsUKSymbolsWithHundredfoldMismatch() {
        XCTAssertEqual(UKPriceScale.normalized(862.4, reference: 8.62, symbol: "IAG.L"), 8.624, accuracy: 1e-9)
        XCTAssertEqual(UKPriceScale.normalized(0.0862, reference: 8.62, symbol: "IAG.L"), 8.62, accuracy: 1e-9)
        XCTAssertEqual(UKPriceScale.normalized(9.5, reference: 8.62, symbol: "IAG.L"), 9.5, accuracy: 1e-9)
        XCTAssertEqual(UKPriceScale.normalized(862.4, reference: 8.62, symbol: "AAPL"), 862.4, accuracy: 1e-9)
    }

    func testMigrationRepairsMixedScaleSeriesAgainstNewestRow() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0, price: 850, previousClose: 845),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0.addingTimeInterval(86_400), price: 8.55, previousClose: 850),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0.addingTimeInterval(172_800), price: 8.62, previousClose: 8.55)
        ]

        let repaired = UKPriceSnapshotScaleMigrationService.repairedRows(rows, symbol: "IAG.L", savedQuote: 8.6)

        XCTAssertEqual(repaired?.map(\.price), [8.5, 8.55, 8.62])
        XCTAssertEqual(repaired?.map(\.previousClose), [8.45, 8.5, 8.55])
    }

    func testMigrationLeavesConsistentSeriesUnchanged() {
        let rows = [
            UKPriceSnapshotScaleMigrationService.Row(timestamp: .distantPast, price: 8.5, previousClose: 8.4),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: Date(timeIntervalSince1970: 1_700_000_000), price: 8.55, previousClose: 8.5),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: Date(), price: 8.6, previousClose: 8.55)
        ]
        XCTAssertEqual(UKPriceSnapshotScaleMigrationService.repairedRows(rows, symbol: "IAG.L"), rows)
    }

    func testMigrationSkipsASymbolWhoseLatestRowsDisagreeWithoutASavedQuote() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0, price: 8.5, previousClose: 8.4),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0.addingTimeInterval(86_400), price: 8.55, previousClose: 8.5),
            // An old build wrote the newest row in pence: it must not become the reference.
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0.addingTimeInterval(172_800), price: 862, previousClose: 855)
        ]
        XCTAssertNil(UKPriceSnapshotScaleMigrationService.repairedRows(rows, symbol: "IAG.L"))
        XCTAssertNil(UKPriceSnapshotScaleMigrationService.repairedRows(Array(rows.prefix(2)), symbol: "IAG.L"),
                     "Too few rows to trust the newest one")
    }

    func testSavedQuoteOverridesAWrongScaleNewestRow() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = [
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0, price: 8.5, previousClose: 8.4),
            UKPriceSnapshotScaleMigrationService.Row(timestamp: t0.addingTimeInterval(86_400), price: 862, previousClose: 850)
        ]
        let repaired = UKPriceSnapshotScaleMigrationService.repairedRows(rows, symbol: "IAG.L", savedQuote: 8.7)
        XCTAssertEqual(repaired?.map(\.price), [8.5, 8.62])
        XCTAssertEqual(repaired?.map(\.previousClose), [8.4, 8.5])
    }
}
