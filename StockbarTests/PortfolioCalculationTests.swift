import Combine
import SwiftUI
import XCTest
@testable import Stockbar

@MainActor
class PortfolioCalculationTests: XCTestCase {

    var trades: [RealTimeTrade]!
    var currencyConverter: CurrencyConverter!
    var service: PortfolioCalculationService!

    // XCTest calls synchronous setUp/tearDown on the main thread. The async
    // variants would add ~0.2 s of scheduling overhead to each of these tests.
    nonisolated override func setUp() {
        super.setUp()
        // `assumeIsolated` traps unless this already runs on the main actor, so
        // the alias never crosses isolation; it only satisfies Swift 6's
        // region checks, which reject capturing a non-Sendable test case.
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated { test.setUpFixtures() }
    }

    nonisolated override func tearDown() {
        nonisolated(unsafe) let test = self
        MainActor.assumeIsolated { test.tearDownFixtures() }
        super.tearDown()
    }

    private func setUpFixtures() {
        currencyConverter = CurrencyConverter(
            exchangeRates: [
                "USD": 1.0,
                "GBP": 0.79,
                "EUR": 0.92,
                "JPY": 149.50,
                "CAD": 1.36
            ],
            refreshOnInit: false,
            loadHistoryOnInit: false
        )
        service = PortfolioCalculationService(currencyConverter: currencyConverter)
        trades = []
    }

    private func tearDownFixtures() {
        trades.removeAll()
        trades = nil
        service = nil
        currencyConverter = nil
    }

    // MARK: - Net Gains Calculation Tests

    func testACostInAnotherCurrencyIsConvertedToTheQuoteCurrency() {
        // A US share costed in pounds: £79 a share is $100 at 0.79.
        let inPounds = Position(unitSize: "10", positionAvgCost: "79", currency: "USD", costCurrency: "GBP")
        XCTAssertEqual(inPounds.averageCost(for: "AAPL", inQuoteCurrency: "USD", converter: currencyConverter), 100, accuracy: 0.001)
        // Pence, written "GBp", on a share that is not UK-listed.
        let inPence = Position(unitSize: "10", positionAvgCost: "7900", currency: "USD", costCurrency: "GBp")
        XCTAssertEqual(inPence.averageCost(for: "AAPL", inQuoteCurrency: "USD", converter: currencyConverter), 100, accuracy: 0.001)
        // A UK share costed in pence and quoted in pounds is only normalised, once.
        let ukPence = Position(unitSize: "10", positionAvgCost: "486", currency: "GBP", costCurrency: "GBX")
        XCTAssertEqual(ukPence.averageCost(for: "AV.L", inQuoteCurrency: "GBP", converter: currencyConverter), 4.86, accuracy: 0.0001)
        // No stated cost currency: used as entered.
        let unstated = Position(unitSize: "10", positionAvgCost: "79", currency: "USD")
        XCTAssertEqual(unstated.averageCost(for: "AAPL", inQuoteCurrency: "USD", converter: currencyConverter), 79, accuracy: 0.001)
    }

    func testCalculateNetGainsWithSingleStock() {
        // Create a stock with profit
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0 // $20 profit per share
        tradingInfo.currency = "USD"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        trades.append(realTimeTrade)

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        // Expected: (170 - 150) * 10 = 200 USD profit
        XCTAssertEqual(result.amount, 200.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithLoss() {
        // Create a stock with loss
        let trade = Trade(name: "TSLA", position: Position(unitSize: "5", positionAvgCost: "250", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 200.0 // $50 loss per share
        tradingInfo.currency = "USD"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        trades.append(realTimeTrade)

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        // Expected: (200 - 250) * 5 = -250 USD loss
        XCTAssertEqual(result.amount, -250.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithPreMarketDataUsesDisplayPrice() {
        let trade = Trade(
            name: "MU",
            position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD")
        )
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.preMarketPrice = 180.0
        tradingInfo.marketState = "PRE"
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 300.0, accuracy: 0.01)
    }

    func testCalculateNetGainsWithZeroPreMarketPriceFallsBackToCurrentPrice() {
        let trade = Trade(
            name: "BABA",
            position: Position(unitSize: "10", positionAvgCost: "100", currency: "USD", costCurrency: "USD")
        )
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 125.0
        tradingInfo.preMarketPrice = 0.0
        tradingInfo.marketState = "PRE"
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 250.0, accuracy: 0.01)
    }

    func testCalculateNetGainsWithMultipleStocks() {
        // Stock 1: Profit
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        trades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // Stock 2: Loss
        let trade2 = Trade(name: "TSLA", position: Position(unitSize: "5", positionAvgCost: "250", currency: "USD", costCurrency: "USD"))
        var tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 200.0
        tradingInfo2.currency = "USD"
        trades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        // Expected: (+200 - 250) = -50 USD net loss
        XCTAssertEqual(result.amount, -50.0, accuracy: 0.01)
    }

    func testCalculateNetGainsWithMixedCurrencies() {
        // USD stock
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        trades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // GBP stock
        let trade2 = Trade(name: "BP.L", position: Position(unitSize: "100", positionAvgCost: "4", currency: "GBP", costCurrency: "GBP"))
        var tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 5.0
        tradingInfo2.currency = "GBP"
        trades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        // AAPL: (170 - 150) * 10 = 200 USD
        // BP: (5 - 4) * 100 = 100 GBP = 126.58 USD (100 / 0.79)
        // Total: 200 + 126.58 = 326.58 USD
        XCTAssertGreaterThan(result.amount, 300.0)
        XCTAssertLessThan(result.amount, 350.0)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithGBXStocks() {
        // UK stock in GBX (pence)
        let trade = Trade(name: "LLOY.L", position: Position(unitSize: "1000", positionAvgCost: "0.50", currency: "GBP", costCurrency: "GBP"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 0.60 // 60 pence = 0.60 GBP
        tradingInfo.currency = "GBP"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        trades.append(realTimeTrade)

        let result = service.calculateNetGains(trades: trades, preferredCurrency: "GBP")

        // Expected: (0.60 - 0.50) * 1000 = 100 GBP profit
        XCTAssertEqual(result.amount, 100.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "GBP")
    }

    // MARK: - Net Value Calculation Tests

    func testCalculateNetValueWithSingleStock() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        // Expected: 170 * 10 = 1700 USD
        XCTAssertEqual(result.amount, 1700.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetValueWithPreMarketDataUsesDisplayPrice() {
        let trade = Trade(
            name: "MU",
            position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD")
        )
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.preMarketPrice = 180.0
        tradingInfo.marketState = "PRE"
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 1800.0, accuracy: 0.01)
    }

    func testCalculateNetValueWithZeroPreMarketPriceFallsBackToCurrentPrice() {
        let trade = Trade(
            name: "BABA",
            position: Position(unitSize: "10", positionAvgCost: "100", currency: "USD", costCurrency: "USD")
        )
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 125.0
        tradingInfo.preMarketPrice = 0.0
        tradingInfo.marketState = "PRE"
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 1250.0, accuracy: 0.01)
    }

    func testCalculateNetValueWithMultipleStocks() {
        // Stock 1
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        trades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // Stock 2
        let trade2 = Trade(name: "GOOGL", position: Position(unitSize: "5", positionAvgCost: "130", currency: "USD", costCurrency: "USD"))
        var tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 140.0
        tradingInfo2.currency = "USD"
        trades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        // Expected: (170 * 10) + (140 * 5) = 1700 + 700 = 2400 USD
        XCTAssertEqual(result.amount, 2400.0, accuracy: 0.01)
    }

    func testCalculateNetValueWithMixedCurrencies() {
        // USD stock
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        trades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // EUR stock
        let trade2 = Trade(name: "SAP", position: Position(unitSize: "10", positionAvgCost: "100", currency: "EUR", costCurrency: "EUR"))
        var tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 120.0
        tradingInfo2.currency = "EUR"
        trades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        // AAPL: 170 * 10 = 1700 USD
        // SAP: 120 * 10 = 1200 EUR = ~1304 USD (1200 / 0.92)
        // Total: ~3004 USD
        XCTAssertGreaterThan(result.amount, 2900.0)
        XCTAssertLessThan(result.amount, 3100.0)
    }

    // MARK: - Edge Case Tests

    func testCalculateNetGainsWithNoStocks() {
        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 0.0)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetValueWithNoStocks() {
        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 0.0)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithNaNPrice() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = Double.nan
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        let result = service.calculateNetGains(trades: trades, preferredCurrency: "USD")

        // Should handle NaN gracefully (likely skip or return 0)
        XCTAssertTrue(result.amount == 0.0 || result.amount.isNaN)
    }

    func testCalculateNetValueWithZeroUnits() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "0", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        let result = service.calculateNetValue(trades: trades, preferredCurrency: "USD")

        XCTAssertEqual(result.amount, 0.0)
    }

    func testCurrencyPreferenceAffectsOutput() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        trades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        // Test USD preference
        let usdResult = service.calculateNetGains(trades: trades, preferredCurrency: "USD")
        XCTAssertEqual(usdResult.currency, "USD")

        // Test GBP preference
        let gbpResult = service.calculateNetGains(trades: trades, preferredCurrency: "GBP")
        XCTAssertEqual(gbpResult.currency, "GBP")

        // Values should be different due to conversion
        XCTAssertNotEqual(usdResult.amount, gbpResult.amount)
    }

    // MARK: - Display Portfolio Summary Tests

    func testDisplayPortfolioSummary_WithSingleStock_IncludesCostBasisAndPercentages() {
        // Given
        trades = [
            makeRealTimeTrade(symbol: "AAPL", units: "10", avgCost: "150", currentPrice: 170, previousClose: 160)
        ]

        // When
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "USD")

        // Then
        XCTAssertEqual(summary.totalValue, 1700.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalCost, 1500.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGain, 200.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGainPct, 13.333, accuracy: 0.01)
        XCTAssertEqual(summary.dayGain, 100.0, accuracy: 0.01)
        XCTAssertEqual(summary.dayGainPct, 6.25, accuracy: 0.01)
        XCTAssertEqual(summary.ownedPositionCount, 1)
    }

    func testDisplayPortfolioSummary_WithPreMarketData_UsesDisplayPrice() {
        // Given
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.prevClosePrice = 160.0
        tradingInfo.currency = "USD"
        tradingInfo.marketState = "PRE"
        tradingInfo.preMarketPrice = 180.0

        let trade = Trade(
            name: "AAPL",
            position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD")
        )
        trades = [RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)]

        // When
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "USD")

        // Then
        XCTAssertEqual(summary.totalValue, 1800.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGain, 300.0, accuracy: 0.01)
        XCTAssertEqual(summary.dayGain, 200.0, accuracy: 0.01)
    }

    func testDisplayPortfolioSummary_WithMixedCurrencies_ConvertsOnceToPreferredCurrency() {
        // Given
        trades = [
            makeRealTimeTrade(symbol: "AAPL", units: "10", avgCost: "150", currentPrice: 170, previousClose: 160),
            makeRealTimeTrade(
                symbol: "BP.L",
                units: "100",
                avgCost: "4",
                currentPrice: 5,
                previousClose: 4.5,
                currency: "GBP",
                costCurrency: "GBP"
            )
        ]

        // When
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "USD")

        // Then
        XCTAssertEqual(summary.totalValue, 2332.91, accuracy: 0.1)
        XCTAssertEqual(summary.totalCost, 2006.33, accuracy: 0.1)
        XCTAssertEqual(summary.totalGain, 326.58, accuracy: 0.1)
        XCTAssertEqual(summary.ownedPositionCount, 2)
    }

    func testTrading212BrokerSummaryUsesAccountValueIncludingCash() {
        // Given
        trades = [
            makeRealTimeTrade(symbol: "MU", units: "150", avgCost: "76.79", currentPrice: 700, previousClose: 690)
        ]
        let snapshot = Trading212BrokerValuationSnapshot(
            accountKey: "Trading212|live|stocksAndSharesISA|label|credential|account",
            currency: "GBP",
            accountValue: 171_344.61,
            investmentsValue: 171_343.22,
            cashValue: 1.39,
            totalUnrealizedProfitLoss: 80_277.20,
            totalCost: 91_066.02,
            positionsByManualSymbol: [:],
            updatedAt: Date()
        )

        // When
        let netValue = service.calculateNetValue(
            trades: trades,
            preferredCurrency: "GBP",
            brokerValuationSnapshot: snapshot
        )
        let summary = service.calculateDisplayPortfolioSummary(
            trades: trades,
            preferredCurrency: "GBP",
            brokerValuationSnapshot: snapshot
        )

        // Then
        XCTAssertEqual(netValue.amount, 171_344.61, accuracy: 0.01)
        XCTAssertEqual(summary.totalValue, 171_344.61, accuracy: 0.01)
        XCTAssertEqual(summary.totalGain, 80_277.20, accuracy: 0.01)
        XCTAssertEqual(summary.totalCost, 91_066.02, accuracy: 0.01)
        XCTAssertEqual(summary.valuationSource, .brokerProvided)
    }

    func testTrading212BrokerSummaryDoesNotRevalueUsdHoldingsThroughLocalFxWhenBrokerGbpValuesExist() {
        // Given: local MU valuation would be 105,000 USD * 0.79 = 82,950 GBP.
        trades = [
            makeRealTimeTrade(symbol: "MU", units: "150", avgCost: "76.79", currentPrice: 700, previousClose: 690)
        ]
        let snapshot = Trading212BrokerValuationSnapshot(
            accountKey: "Trading212|live|stocksAndSharesISA|label|credential|account",
            currency: "GBP",
            accountValue: 171_344.61,
            investmentsValue: 171_343.22,
            cashValue: 1.39,
            totalUnrealizedProfitLoss: 80_277.20,
            totalCost: 91_066.02,
            positionsByManualSymbol: [
                "MU": Trading212BrokerPositionValuation(
                    manualSymbol: "MU",
                    instrumentId: "US:MU",
                    brokerCurrentValue: 114_987,
                    brokerTotalCost: 11_518.50,
                    brokerUnrealizedProfitLoss: 103_468.50,
                    fxImpact: nil,
                    currency: "GBP",
                    updatedAt: Date()
                )
            ],
            updatedAt: Date()
        )

        // When
        let summary = service.calculateDisplayPortfolioSummary(
            trades: trades,
            preferredCurrency: "GBP",
            brokerValuationSnapshot: snapshot
        )

        // Then
        XCTAssertEqual(summary.totalValue, 171_344.61, accuracy: 0.01)
        XCTAssertNotEqual(summary.totalValue, 82_950.0, accuracy: 0.01)
    }

    func testTrading212BrokerSummaryFallsBackToLocalCalculationWhenSnapshotMissing() {
        trades = [
            makeRealTimeTrade(symbol: "AAPL", units: "10", avgCost: "150", currentPrice: 170, previousClose: 160)
        ]

        let summary = service.calculateDisplayPortfolioSummary(
            trades: trades,
            preferredCurrency: "USD",
            brokerValuationSnapshot: nil
        )

        XCTAssertEqual(summary.totalValue, 1700.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGain, 200.0, accuracy: 0.01)
        XCTAssertEqual(summary.valuationSource, .localCalculationFallback)
    }

    func testDisplayPortfolioSummary_WithUKAutoDetectedGBXCost_NormalizesToGBP() {
        // Given
        trades = [
            makeRealTimeTrade(
                symbol: "SSE.L",
                units: "100",
                avgCost: "250",
                currentPrice: 2.75,
                previousClose: 2.5,
                currency: "GBP",
                costCurrency: nil
            )
        ]

        // When
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "GBP")

        // Then
        XCTAssertEqual(summary.totalValue, 275.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalCost, 250.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGain, 25.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalGainPct, 10.0, accuracy: 0.01)
    }

    func testDisplayPortfolioSummary_ExcludesWatchlistAndInvalidPrices() {
        // Given
        var watchlistTrade = Trade(
            name: "MSFT",
            position: Position(unitSize: "10", positionAvgCost: "100", currency: "USD", costCurrency: "USD")
        )
        watchlistTrade.isWatchlistOnly = true

        let watchlistInfo = makeTradingInfo(currentPrice: 200, previousClose: 190)
        let invalidTrade = makeRealTimeTrade(
            symbol: "TSLA",
            units: "5",
            avgCost: "250",
            currentPrice: .nan,
            previousClose: 240
        )

        trades = [
            makeRealTimeTrade(symbol: "AAPL", units: "10", avgCost: "150", currentPrice: 170, previousClose: 160),
            RealTimeTrade(trade: watchlistTrade, realTimeInfo: watchlistInfo),
            invalidTrade
        ]

        // When
        let summary = service.calculateDisplayPortfolioSummary(trades: trades, preferredCurrency: "USD")

        // Then
        XCTAssertEqual(summary.totalValue, 1700.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalCost, 1500.0, accuracy: 0.01)
        XCTAssertEqual(summary.ownedPositionCount, 1)
    }

    func testPositionProfitLossSummaryIncludesDayAndTotalAmountAndPercent() {
        // Given
        let trade = makeRealTimeTrade(
            symbol: "AAPL",
            units: "10",
            avgCost: "150",
            currentPrice: 170,
            previousClose: 160
        )

        // When
        let summary = service.calculatePositionProfitLoss(for: trade)

        // Then
        XCTAssertEqual(summary.dayAmount, 100.0, accuracy: 0.01)
        XCTAssertEqual(summary.dayPercent, 6.25, accuracy: 0.01)
        XCTAssertEqual(summary.totalAmount, 200.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalPercent, 13.333, accuracy: 0.01)
        XCTAssertEqual(summary.currency, "USD")
    }

    func testPositionProfitLossUsesBrokerUnrealizedProfitLossWhenAvailable() {
        let trade = makeRealTimeTrade(
            symbol: "MU",
            units: "150",
            avgCost: "76.79",
            currentPrice: 700,
            previousClose: 690
        )
        let valuation = Trading212BrokerPositionValuation(
            manualSymbol: "MU",
            instrumentId: "US:MU",
            brokerCurrentValue: 114_987,
            brokerTotalCost: 11_518.50,
            brokerUnrealizedProfitLoss: 103_468.50,
            fxImpact: nil,
            currency: "GBP",
            updatedAt: Date()
        )

        let summary = service.calculatePositionProfitLoss(for: trade, brokerValuation: valuation)

        // $10 a share on 150 shares is $1,500, shown in the row's currency: £1,185 at 0.79.
        XCTAssertEqual(summary.dayAmount, 1185.0, accuracy: 0.01)
        XCTAssertEqual(summary.totalAmount, 103_468.50, accuracy: 0.01)
        XCTAssertEqual(summary.totalPercent, 898.28, accuracy: 0.01)
        XCTAssertEqual(summary.currency, "GBP")
    }

    func testHoldingsCurrencyFormatterUsesSymbolsSignsAndGrouping() {
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(12_345.67, currency: "USD"), "+$12,345.67")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(-1_111.11, currency: "GBP"), "-£1,111.11")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(1_234.5, currency: "EUR"), "+€1,234.50")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(987.65, currency: "CHF"), "+987.65 CHF")
    }

    func testHoldingsCurrencyFormatterAddsUsdSecondaryOnlyForNonUsdAmounts() {
        XCTAssertEqual(
            HoldingsCurrencyFormatter.amountWithUSDSecondary(
                10_000.00,
                currency: "GBP",
                usdAmount: 12_700.00
            ),
            "£10,000.00 ($12,700.00)"
        )
        XCTAssertEqual(
            HoldingsCurrencyFormatter.signedAmountWithUSDSecondary(
                2_000.50,
                currency: "GBP",
                usdAmount: 2_540.64
            ),
            "+£2,000.50 (+$2,540.64)"
        )
        XCTAssertEqual(
            HoldingsCurrencyFormatter.amountWithUSDSecondary(
                1_234.56,
                currency: "USD",
                usdAmount: 1_234.56
            ),
            "$1,234.56"
        )
    }

    func testMenuPopoverFormatterUsesCurrencySymbolsAndGroupingForCompactAmounts() {
        XCTAssertEqual(
            MenuPopoverFormatter.currency(12_345.42, currency: "USD", includeSign: true),
            "+$12,345"
        )
        XCTAssertEqual(
            MenuPopoverFormatter.currency(-19_876.1, currency: "GBP", includeSign: true),
            "-£19,876"
        )
        XCTAssertEqual(
            MenuPopoverFormatter.currency(1_147.72, currency: "USD"),
            "$1,147.7"
        )
    }

    func testPortfolioHistoryRejectsCurrencyMixingAndPartialWeekReturn() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let values = [
            StoredPortfolioValue(date: now.addingTimeInterval(-7200), totalValue: 214981, currency: "USD"),
            StoredPortfolioValue(date: now.addingTimeInterval(-3600), totalValue: 165525, currency: "GBP"),
            StoredPortfolioValue(date: now, totalValue: 165525, currency: "GBP")
        ]
        let stored = PortfolioMenuChartDataBuilder.matchingCurrencyPoints(values, currency: "GBP")
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.value == 165525 })
        let partial = stored.map { MenuChartDataPoint(date: $0.date, price: $0.value, symbol: "Portfolio") }
        XCTAssertFalse(PortfolioMenuChartDataBuilder.coversRange(partial, range: .week, now: now))
        let full = [MenuChartDataPoint(date: now.addingTimeInterval(-7 * 86400), price: 160000, symbol: "Portfolio")] + partial
        XCTAssertTrue(PortfolioMenuChartDataBuilder.coversRange(full, range: .week, now: now))
    }

    func testPortfolioMenuChartDataBuilder_WithNoHistory_DoesNotInventPerformance() {
        // Given
        let now = Date(timeIntervalSince1970: 1_000_000)

        // When
        let points = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: [],
            currentValue: 2500,
            range: .day,
            now: now
        )

        // Then
        XCTAssertTrue(points.isEmpty)
        XCTAssertNil(PortfolioMenuChartDataBuilder.rangeChange(for: points))
    }

    func testPortfolioMenuChartDataBuilder_FiltersAppendsAndSortsPoints() {
        // Given
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldPoint = ChartDataPoint(date: now.addingTimeInterval(-90_000), value: 1000)
        let validPoint = ChartDataPoint(date: now.addingTimeInterval(-60), value: 1500)
        let earlierPoint = ChartDataPoint(date: now.addingTimeInterval(-600), value: 1400)
        let invalidPoint = ChartDataPoint(date: now.addingTimeInterval(-30), value: .nan)

        // When
        let points = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: [validPoint, oldPoint, invalidPoint, earlierPoint],
            currentValue: 1750,
            range: .day,
            now: now
        )

        // Then
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].price, 1400)
        XCTAssertEqual(points[1].price, 1500)
        XCTAssertEqual(points[2].price, 1750)
        XCTAssertEqual(points[2].date, now)
    }

    func testPortfolioMenuChartDataBuilderRangeChangeMatchesFirstAndLastPoints() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let points = [
            MenuChartDataPoint(
                date: now.addingTimeInterval(-3600),
                price: 160_564,
                symbol: "Portfolio"
            ),
            MenuChartDataPoint(
                date: now,
                price: 147_521,
                symbol: "Portfolio"
            )
        ]

        let change = PortfolioMenuChartDataBuilder.rangeChange(for: points)

        XCTAssertEqual(change?.value ?? .nan, -13_043, accuracy: 0.001)
        XCTAssertEqual(change?.percent ?? .nan, -8.1232, accuracy: 0.001)
    }

    func testPortfolioMenuChartDataBuilderRangeChangeRejectsInvalidBaseline() {
        let points = [
            MenuChartDataPoint(date: Date(), price: 0, symbol: "Portfolio"),
            MenuChartDataPoint(date: Date(), price: 100, symbol: "Portfolio")
        ]

        XCTAssertNil(PortfolioMenuChartDataBuilder.rangeChange(for: points))
    }

    func testPortfolioMenuPerformanceResolverUsesFolyncDayMetricsInsteadOfChartChange() {
        let summary = DisplayPortfolioSummary(
            totalValue: 142_141.33,
            totalGain: 88_334.78,
            totalGainPct: 164.17,
            dayGain: -11_023.97,
            dayGainPct: -7.1974,
            totalCost: 53_805.39,
            ownedPositionCount: 13,
            currency: "GBP",
            valuationSource: .folyncProvided
        )
        let misleadingChartChange = PortfolioMenuRangeChange(value: 23_897.70, percent: 20.29)

        let resolved = PortfolioMenuPerformanceResolver.resolve(
            summary: summary,
            range: .day,
            chartChange: misleadingChartChange
        )

        XCTAssertEqual(resolved?.value ?? .nan, -11_023.97, accuracy: 0.001)
        XCTAssertEqual(resolved?.percent ?? .nan, -7.1974, accuracy: 0.0001)
    }

    func testPortfolioMenuDayReferenceResolverUsesTheSameFolyncDayMetrics() {
        let summary = DisplayPortfolioSummary(
            totalValue: 142_141.33,
            totalGain: 88_334.78,
            totalGainPct: 164.17,
            dayGain: -11_023.97,
            dayGainPct: -7.1974,
            totalCost: 53_805.39,
            ownedPositionCount: 13,
            currency: "GBP",
            valuationSource: .folyncProvided
        )

        let reference = PortfolioMenuDayReferenceResolver.resolve(
            summary: summary,
            range: .day
        )
        let displayedChange = PortfolioMenuPerformanceResolver.resolve(
            summary: summary,
            range: .day,
            chartChange: PortfolioMenuRangeChange(value: 23_897.70, percent: 20.29)
        )

        XCTAssertEqual(reference?.referenceValue ?? .nan, 153_165.30, accuracy: 0.001)
        XCTAssertEqual(reference?.currentValue ?? .nan, 142_141.33, accuracy: 0.001)
        XCTAssertEqual(reference?.change, displayedChange)
    }

    func testPortfolioMenuDayReferenceResolverRejectsMissingOrImpossibleFolyncMetrics() {
        let missingMetrics = DisplayPortfolioSummary(
            totalValue: 142_141.33,
            totalGain: 88_334.78,
            totalGainPct: 164.17,
            dayGain: .nan,
            dayGainPct: .nan,
            totalCost: 53_805.39,
            ownedPositionCount: 13,
            currency: "GBP",
            valuationSource: .folyncProvided
        )
        let impossibleReference = DisplayPortfolioSummary(
            totalValue: 100,
            totalGain: 0,
            totalGainPct: 0,
            dayGain: 150,
            dayGainPct: 0,
            totalCost: 100,
            ownedPositionCount: 1,
            currency: "GBP",
            valuationSource: .folyncProvided
        )

        XCTAssertNil(
            PortfolioMenuDayReferenceResolver.resolve(
                summary: missingMetrics,
                range: .day
            )
        )
        XCTAssertNil(
            PortfolioMenuDayReferenceResolver.resolve(
                summary: impossibleReference,
                range: .day
            )
        )
    }

    func testPortfolioMenuDayReferenceResolverIsOnlyUsedForFolyncDayRange() {
        let folyncSummary = DisplayPortfolioSummary(
            totalValue: 10_500,
            totalGain: 500,
            totalGainPct: 5,
            dayGain: 25,
            dayGainPct: 0.24,
            totalCost: 10_000,
            ownedPositionCount: 2,
            currency: "GBP",
            valuationSource: .folyncProvided
        )
        let localSummary = DisplayPortfolioSummary(
            totalValue: 10_500,
            totalGain: 500,
            totalGainPct: 5,
            dayGain: 25,
            dayGainPct: 0.24,
            totalCost: 10_000,
            ownedPositionCount: 2,
            currency: "GBP"
        )

        XCTAssertNil(
            PortfolioMenuDayReferenceResolver.resolve(
                summary: folyncSummary,
                range: .week
            )
        )
        XCTAssertNil(
            PortfolioMenuDayReferenceResolver.resolve(
                summary: localSummary,
                range: .day
            )
        )
    }

    func testPortfolioMenuPerformanceResolverDoesNotInventFolyncDayFallback() {
        let summary = DisplayPortfolioSummary(
            totalValue: 142_141.33,
            totalGain: 88_334.78,
            totalGainPct: 164.17,
            dayGain: .nan,
            dayGainPct: .nan,
            totalCost: 53_805.39,
            ownedPositionCount: 13,
            currency: "GBP",
            valuationSource: .folyncProvided
        )

        let resolved = PortfolioMenuPerformanceResolver.resolve(
            summary: summary,
            range: .day,
            chartChange: PortfolioMenuRangeChange(value: 23_897.70, percent: 20.29)
        )

        XCTAssertNil(resolved)
    }

    func testPortfolioMenuPerformanceResolverScopesFolyncAuthorityToDayRange() {
        let summary = DisplayPortfolioSummary(
            totalValue: 142_141.33,
            totalGain: 88_334.78,
            totalGainPct: 164.17,
            dayGain: -11_023.97,
            dayGainPct: -7.1974,
            totalCost: 53_805.39,
            ownedPositionCount: 13,
            currency: "GBP",
            valuationSource: .folyncProvided
        )
        let chartChange = PortfolioMenuRangeChange(value: 4_250, percent: 3.08)

        XCTAssertEqual(
            PortfolioMenuPerformanceResolver.resolve(
                summary: summary,
                range: .week,
                chartChange: chartChange
            ),
            chartChange
        )
        XCTAssertEqual(
            PortfolioMenuPerformanceResolver.resolve(
                summary: summary,
                range: .month,
                chartChange: chartChange
            ),
            chartChange
        )
    }

    func testPortfolioMenuPerformanceResolverKeepsLocalChartChange() {
        let summary = DisplayPortfolioSummary(
            totalValue: 10_500,
            totalGain: 500,
            totalGainPct: 5,
            dayGain: 25,
            dayGainPct: 0.24,
            totalCost: 10_000,
            ownedPositionCount: 2,
            currency: "GBP"
        )
        let chartChange = PortfolioMenuRangeChange(value: 40, percent: 0.38)

        XCTAssertEqual(
            PortfolioMenuPerformanceResolver.resolve(
                summary: summary,
                range: .day,
                chartChange: chartChange
            ),
            chartChange
        )
    }

    func testPortfolioMenuChartDataBuilder_DownsamplesPreservingFirstAndLastPoints() {
        // Given
        let now = Date(timeIntervalSince1970: 1_000_000)
        let start = now.addingTimeInterval(-3600)
        let points = (0..<1200).map { index in
            ChartDataPoint(
                date: start.addingTimeInterval(Double(index)),
                value: Double(index + 1)
            )
        }

        // When
        let sampled = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: points,
            currentValue: 1300,
            range: .month,
            now: now,
            maxPoints: 1000
        )

        // Then
        XCTAssertLessThanOrEqual(sampled.count, 1000)
        XCTAssertEqual(sampled.first?.date, points.first?.date)
        XCTAssertEqual(sampled.last?.date, now)
        XCTAssertEqual(sampled.last?.price, 1300)
    }

    func testPortfolioMenuChartDataBuilder_DayRangeBucketsIntoTwoMinutePointsAndUsesCurrentEndpoint() {
        // Given
        let now = Date(timeIntervalSince1970: 3_600)
        let rawPoints = [
            ChartDataPoint(date: Date(timeIntervalSince1970: 3_005), value: 1000),
            ChartDataPoint(date: Date(timeIntervalSince1970: 3_050), value: 1001),
            ChartDataPoint(date: Date(timeIntervalSince1970: 3_130), value: 1002),
            ChartDataPoint(date: Date(timeIntervalSince1970: 3_190), value: 1003)
        ]

        // When
        let points = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: rawPoints,
            currentValue: 1250,
            range: .day,
            now: now
        )

        // Then
        XCTAssertLessThan(points.count, rawPoints.count + 1)
        XCTAssertEqual(points.last?.date, now)
        XCTAssertEqual(points.last?.price, 1250)
        XCTAssertEqual(points.map(\.price), [1001, 1003, 1250])
    }

    @MainActor
    func testHistoricalDataManagerReturnsMemoryLivePortfolioSamplesForMenuChart() {
        // Given
        let manager = HistoricalDataManager.shared
        let start = Date().addingTimeInterval(-5 * 60)
        let expectedValues = (0..<6).map { 987_000.0 + Double($0) }

        for (index, value) in expectedValues.enumerated() {
            manager.recordLivePortfolioSample(
                totalValue: value,
                totalGains: value - 900_000,
                timestamp: start.addingTimeInterval(Double(index * 30))
            )
        }

        // When
        let samples = manager.getStoredPortfolioValues(for: .day)
        let sampleValues = samples.map(\.value)

        // Then
        for value in expectedValues {
            XCTAssertTrue(
                sampleValues.contains { abs($0 - value) < 0.0001 },
                "Expected live portfolio value \(value) to be available to the menu chart"
            )
        }
    }

    @MainActor
    func testPortfolioMenuValuesDayRangeBuildsSyntheticHistoryFromCurrentHoldings() {
        // Given
        let manager = HistoricalDataManager.shared
        let now = Date()
        let symbolA = "SYNTHA-\(UUID().uuidString)"
        let symbolB = "SYNTHB-\(UUID().uuidString)"
        let sampleDates = [
            now.addingTimeInterval(-20 * 60),
            now.addingTimeInterval(-16 * 60),
            now.addingTimeInterval(-12 * 60)
        ]

        for (index, date) in sampleDates.enumerated() {
            manager.recordLivePriceSample(
                symbol: symbolA,
                price: 100 + Double(index * 10),
                previousClose: 100,
                timestamp: date
            )
            manager.recordLivePriceSample(
                symbol: symbolB,
                price: 200 + Double(index * 5),
                previousClose: 200,
                timestamp: date
            )
        }

        let trades = [
            makeRealTimeTrade(symbol: symbolA, units: 10, currentPrice: 140, currency: "USD"),
            makeRealTimeTrade(symbol: symbolB, units: 5, currentPrice: 230, currency: "USD")
        ]

        // When
        let points = manager.getPortfolioMenuValues(
            for: .day,
            currentTrades: trades,
            preferredCurrency: "USD",
            now: now,
            scheduleMissingHistoryFetches: false
        )

        // Then
        let syntheticValues = [2_000.0, 2_125.0, 2_250.0]
        for expectedValue in syntheticValues {
            XCTAssertTrue(
                points.contains { abs($0.value - expectedValue) < 0.0001 },
                "Expected synthetic portfolio value \(expectedValue)"
            )
        }
    }

    @MainActor
    func testPortfolioMenuValuesCanDisableSyntheticHistoryForFolyncAuthority() {
        // Keep this source-authority fixture independent of shared FX refreshes.
        let sharedConverter = CurrencyConverter.shared
        let originalRates = sharedConverter.exchangeRates
        sharedConverter.exchangeRates = ["USD": 1.0, "GBP": 0.79]
        defer { sharedConverter.exchangeRates = originalRates }

        let manager = HistoricalDataManager.shared
        let now = Date()
        let coveredSymbol = "SYNTHCOVERED-\(UUID().uuidString)"
        let missingSymbol = "SYNTHMISSING-\(UUID().uuidString)"
        let coveredSubtotal = 8_765_432.10
        let missingSubtotal = 1_234_567.90
        let fullPortfolioValue = coveredSubtotal + missingSubtotal
        // The covered holding was 100 lower earlier; the one with no history
        // is carried at today's value rather than left out of the total.
        let earlierCoveredPrice = coveredSubtotal - 100
        let syntheticValue = earlierCoveredPrice + missingSubtotal
        let sampleDates = [
            now.addingTimeInterval(-20 * 60),
            now.addingTimeInterval(-16 * 60),
            now.addingTimeInterval(-12 * 60)
        ]

        manager.recordLivePortfolioSample(
            totalValue: fullPortfolioValue,
            totalGains: 1_000_000,
            timestamp: now.addingTimeInterval(-18 * 60)
        )
        for sampleDate in sampleDates {
            manager.recordLivePriceSample(
                symbol: coveredSymbol,
                price: earlierCoveredPrice,
                previousClose: earlierCoveredPrice,
                timestamp: sampleDate
            )
        }

        let trades = [
            makeRealTimeTrade(
                symbol: coveredSymbol,
                units: 1,
                currentPrice: coveredSubtotal,
                currency: "GBP"
            ),
            makeRealTimeTrade(
                symbol: missingSymbol,
                units: 1,
                currentPrice: missingSubtotal,
                currency: "GBP"
            )
        ]
        let syntheticPoints = manager.getPortfolioMenuValues(
            for: .day,
            currentTrades: trades,
            preferredCurrency: "GBP",
            now: now,
            scheduleMissingHistoryFetches: false
        )
        let authoritativePoints = manager.getPortfolioMenuValues(
            for: .day,
            currentTrades: trades,
            preferredCurrency: "GBP",
            now: now,
            scheduleMissingHistoryFetches: false,
            allowSyntheticPositionHistory: false
        )

        XCTAssertTrue(
            syntheticPoints.contains { abs($0.value - syntheticValue) < 0.0001 },
            "The fixture must produce a synthetic point from position history"
        )
        XCTAssertFalse(
            syntheticPoints.contains { abs($0.value - earlierCoveredPrice) < 0.0001 },
            "A holding with no history must not be dropped from the synthetic total"
        )
        XCTAssertTrue(
            authoritativePoints.contains { abs($0.value - fullPortfolioValue) < 0.0001 },
            "Folync-authoritative charts must retain full portfolio samples"
        )
        XCTAssertFalse(
            authoritativePoints.contains { abs($0.value - syntheticValue) < 0.0001 },
            "Folync-authoritative charts must not merge synthetic position history"
        )
    }

    @MainActor
    func testPortfolioMenuValuesDayRangeConvertsMixedCurrencySyntheticValues() {
        // Given
        let sharedConverter = CurrencyConverter.shared
        let originalRates = sharedConverter.exchangeRates
        let originalRefreshTime = sharedConverter.lastRefreshTime
        let originalRefreshSuccess = sharedConverter.lastRefreshSuccess
        sharedConverter.exchangeRates = ["USD": 1.0, "GBP": 0.79]
        sharedConverter.lastRefreshTime = Date()
        sharedConverter.lastRefreshSuccess = true
        defer {
            sharedConverter.exchangeRates = originalRates
            sharedConverter.lastRefreshTime = originalRefreshTime
            sharedConverter.lastRefreshSuccess = originalRefreshSuccess
        }

        let manager = HistoricalDataManager.shared
        let now = Date()
        let usdSymbol = "SYNTHUSD-\(UUID().uuidString)"
        let gbpSymbol = "SYNTHGBP-\(UUID().uuidString)"
        let sampleDates = [
            now.addingTimeInterval(-15 * 60),
            now.addingTimeInterval(-13 * 60),
            now.addingTimeInterval(-11 * 60)
        ]

        for sampleDate in sampleDates {
            manager.recordLivePriceSample(symbol: usdSymbol, price: 100, previousClose: 100, timestamp: sampleDate)
            manager.recordLivePriceSample(symbol: gbpSymbol, price: 50, previousClose: 50, timestamp: sampleDate)
        }

        let trades = [
            makeRealTimeTrade(symbol: usdSymbol, units: 10, currentPrice: 120, currency: "USD"),
            makeRealTimeTrade(symbol: gbpSymbol, units: 10, currentPrice: 60, currency: "GBP")
        ]

        // When
        let points = manager.getPortfolioMenuValues(
            for: .day,
            currentTrades: trades,
            preferredCurrency: "USD",
            now: now,
            scheduleMissingHistoryFetches: false
        )

        // Then
        XCTAssertTrue(
            points.contains { $0.value > 1_500 && $0.value < 1_900 },
            "Expected mixed USD/GBP synthetic value to be converted into USD"
        )
    }

    @MainActor
    func testPortfolioMenuValuesDayRangeSkipsLowValueCoverageTimestamps() {
        // Given
        let manager = HistoricalDataManager.shared
        let now = Date()
        let coveredSymbol = "SYNTHLOW-\(UUID().uuidString)"
        let missingHighValueSymbol = "SYNTHHIGH-\(UUID().uuidString)"
        let sampleDate = now.addingTimeInterval(-15 * 60)

        manager.recordLivePriceSample(symbol: coveredSymbol, price: 10, previousClose: 10, timestamp: sampleDate)

        let trades = [
            makeRealTimeTrade(symbol: coveredSymbol, units: 10, currentPrice: 10, currency: "USD"),
            makeRealTimeTrade(symbol: missingHighValueSymbol, units: 100, currentPrice: 100, currency: "USD")
        ]

        // When
        let points = manager.getPortfolioMenuValues(
            for: .day,
            currentTrades: trades,
            preferredCurrency: "USD",
            now: now,
            scheduleMissingHistoryFetches: false
        )

        // Then
        XCTAssertFalse(
            points.contains { abs($0.value - 100.0) < 0.0001 },
            "Low coverage point should be skipped instead of drawing a misleading portfolio value"
        )
    }

    @MainActor
    func testPortfolioMenuValuesWeekRangeKeepsStoredPortfolioBehavior() {
        // Given
        let manager = HistoricalDataManager.shared
        let now = Date()
        let symbol = "SYNTHWEEK-\(UUID().uuidString)"
        let sampleDate = now.addingTimeInterval(-15 * 60)
        let syntheticOnlyValue = 4_321.0

        manager.recordLivePriceSample(symbol: symbol, price: syntheticOnlyValue, previousClose: syntheticOnlyValue, timestamp: sampleDate)
        let trades = [makeRealTimeTrade(symbol: symbol, units: 1, currentPrice: syntheticOnlyValue, currency: "USD")]

        // When
        let points = manager.getPortfolioMenuValues(
            for: .week,
            currentTrades: trades,
            preferredCurrency: "USD",
            now: now,
            scheduleMissingHistoryFetches: false
        )

        // Then
        XCTAssertFalse(
            points.contains { abs($0.value - syntheticOnlyValue) < 0.0001 },
            "Week range should not synthesize portfolio values from symbol-level menu samples"
        )
    }

    @MainActor
    func testPortfolioMenuHistoryFetchCandidatesExcludeWatchlistRows() {
        // Given
        let manager = HistoricalDataManager.shared
        let now = Date()
        let heldSymbol = "FETCHHELD-\(UUID().uuidString)"
        let watchlistSymbol = "FETCHWATCH-\(UUID().uuidString)"
        let trades = [
            makeRealTimeTrade(symbol: heldSymbol, units: 10, currentPrice: 100, currency: "USD"),
            makeRealTimeTrade(symbol: watchlistSymbol, units: 10, currentPrice: 100, currency: "USD", isWatchlistOnly: true)
        ]

        // When
        let candidates = manager.portfolioMenuHistoryFetchCandidates(
            currentTrades: trades,
            startDate: now.addingTimeInterval(-24 * 60 * 60),
            endDate: now
        )

        // Then
        XCTAssertTrue(candidates.contains(heldSymbol))
        XCTAssertFalse(candidates.contains(watchlistSymbol))
    }

    func testHistoricalFetchRequestGateDeduplicatesInFlightAndCooldownRequests() {
        var gate = HistoricalFetchRequestGate()
        let now = Date(timeIntervalSince1970: 100_000)
        let key = "price|AAPL|1D|revision:1"

        XCTAssertTrue(gate.reserve(key: key, now: now, cooldown: 600))
        XCTAssertFalse(gate.reserve(key: key, now: now, cooldown: 600))

        gate.complete(key: key)
        XCTAssertFalse(
            gate.reserve(
                key: key,
                now: now.addingTimeInterval(599),
                cooldown: 600
            )
        )
        XCTAssertTrue(
            gate.reserve(
                key: key,
                now: now.addingTimeInterval(600),
                cooldown: 600
            )
        )
    }

    func testHistoricalFetchRequestGateKeepsSymbolsAndRevisionsIndependent() {
        var gate = HistoricalFetchRequestGate()
        let now = Date(timeIntervalSince1970: 100_000)

        XCTAssertTrue(
            gate.reserve(
                key: "price|AAPL|1D|revision:1",
                now: now,
                cooldown: 600
            )
        )
        XCTAssertTrue(
            gate.reserve(
                key: "price|MSFT|1D|revision:1",
                now: now,
                cooldown: 600
            )
        )
        XCTAssertTrue(
            gate.reserve(
                key: "price|AAPL|1D|revision:2",
                now: now,
                cooldown: 600
            )
        )
    }

    func testMenuChartDataBuilder_DayRangeBucketsIntoTwoMinutePointsAndUsesCurrentEndpoint() {
        // Given
        let now = Date(timeIntervalSince1970: 3_600)
        let storedPoints = [
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_005), price: 100, symbol: "BABA"),
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_050), price: 101, symbol: "BABA"),
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_130), price: 102, symbol: "BABA"),
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_190), price: 103, symbol: "BABA")
        ]

        // When
        let points = MenuChartDataBuilder.preparePricePoints(
            storedPoints: storedPoints,
            currentPrice: 111,
            symbol: "BABA",
            range: .day,
            now: now
        )

        // Then
        XCTAssertEqual(points.map(\.price), [101, 103, 111])
        XCTAssertEqual(points.last?.date, now)
    }

    func testMenuChartDataBuilder_WeekRangePreservesStoredPointsAndUsesCurrentEndpoint() {
        // Given
        let now = Date(timeIntervalSince1970: 3_600)
        let storedPoints = [
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_005), price: 100, symbol: "BABA"),
            MenuChartDataPoint(date: Date(timeIntervalSince1970: 3_050), price: 101, symbol: "BABA")
        ]

        // When
        let points = MenuChartDataBuilder.preparePricePoints(
            storedPoints: storedPoints,
            currentPrice: 111,
            symbol: "BABA",
            range: .week,
            now: now
        )

        // Then
        XCTAssertEqual(points.map(\.price), [100, 101, 111])
        XCTAssertEqual(points.last?.date, now)
    }

    @MainActor
    func testHistoricalDataManagerReturnsMemoryLiveSamplesForMenuChart() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "TESTLIVE-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(300)

        for index in 0..<10 {
            manager.recordLivePriceSample(
                symbol: symbol,
                price: 100 + Double(index),
                previousClose: 100,
                timestamp: start.addingTimeInterval(Double(index * 30))
            )
        }

        // When
        let samples = manager.getPriceSnapshots(for: symbol, from: start, to: end)

        // Then
        XCTAssertEqual(samples.count, 10)
        XCTAssertEqual(samples.map(\.price), (0..<10).map { 100 + Double($0) })
    }

    @MainActor
    func testIndividualStockChartDataIncludesMemoryLiveSamples() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "TESTCHARTLIVE-\(UUID().uuidString)"
        let storedStart = Date().addingTimeInterval(-90 * 60)
        let storedSnapshots = (0..<10).map { index in
            PriceSnapshot(
                timestamp: storedStart.addingTimeInterval(Double(index * 300)),
                price: 100 + Double(index),
                previousClose: 100,
                symbol: symbol
            )
        }
        manager.addImportedSnapshots(storedSnapshots, for: symbol)

        manager.recordLivePriceSample(
            symbol: symbol,
            price: 250,
            previousClose: 100,
            timestamp: Date().addingTimeInterval(-60)
        )
        manager.recordLivePriceSample(
            symbol: symbol,
            price: 251,
            previousClose: 100,
            timestamp: Date().addingTimeInterval(-30)
        )

        // When
        let points = manager.getChartData(for: .individualStock(symbol), timeRange: .day)

        // Then
        XCTAssertTrue(points.contains { abs($0.value - 250) < 0.0001 })
        XCTAssertTrue(points.contains { abs($0.value - 251) < 0.0001 })
    }

    @MainActor
    func testImportedSameDaySnapshotsMergeByTimestampNotDay() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "TESTBACKFILL-\(UUID().uuidString)"
        // Within the full-detail retention window, so intraday points are kept.
        let dayStart = Calendar.current.startOfDay(for: Date().addingTimeInterval(-2 * 86_400))
        let afternoonStart = dayStart.addingTimeInterval(14 * 60 * 60)
        let existingSnapshots = (0..<10).map { index in
            PriceSnapshot(
                timestamp: afternoonStart.addingTimeInterval(Double(index * 60)),
                price: 200 + Double(index),
                previousClose: 200,
                symbol: symbol
            )
        }
        manager.addImportedSnapshots(existingSnapshots, for: symbol)

        let backfilledMorningSnapshots = (0..<3).map { index in
            PriceSnapshot(
                timestamp: dayStart.addingTimeInterval(Double(index * 60)),
                price: 150 + Double(index),
                previousClose: 150,
                symbol: symbol
            )
        }

        // When
        manager.addImportedSnapshots(backfilledMorningSnapshots, for: symbol)
        let snapshots = manager.getPriceSnapshots(
            for: symbol,
            from: dayStart,
            to: dayStart.addingTimeInterval(24 * 60 * 60)
        )

        // Then
        XCTAssertEqual(snapshots.count, existingSnapshots.count + backfilledMorningSnapshots.count)
        for expectedPrice in [150.0, 151.0, 152.0] {
            XCTAssertTrue(
                snapshots.contains { abs($0.price - expectedPrice) < 0.0001 },
                "Expected same-day backfilled price \(expectedPrice) to be retained"
            )
        }
    }

    @MainActor
    func testMenuPriceHistoryFetchCandidateIsTrueWhenNoSnapshotsAreAvailable() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "EMPTYMENU-\(UUID().uuidString)"
        let now = Date()

        // When
        let shouldFetch = manager.shouldFetchMenuPriceHistory(
            for: symbol,
            from: now.addingTimeInterval(-24 * 60 * 60),
            to: now
        )

        // Then
        XCTAssertTrue(shouldFetch)
    }

    @MainActor
    func testMenuPriceHistoryFetchCandidateIsFalseWhenEnoughSnapshotsAreAvailable() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "FILLEDMENU-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 20_000)
        let end = start.addingTimeInterval(600)

        for index in 0..<10 {
            manager.recordLivePriceSample(
                symbol: symbol,
                price: 200 + Double(index),
                previousClose: 200,
                timestamp: start.addingTimeInterval(Double(index * 60))
            )
        }

        // When
        let shouldFetch = manager.shouldFetchMenuPriceHistory(for: symbol, from: start, to: end)

        // Then
        XCTAssertFalse(shouldFetch)
    }

    @MainActor
    func testMenuChartSelectionSurvivesViewModelRecreationForSameSymbol() {
        // Given
        let manager = HistoricalDataManager.shared
        let symbol = "RANGE-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 30_000)

        for index in 0..<10 {
            manager.recordLivePriceSample(
                symbol: symbol,
                price: 300 + Double(index),
                previousClose: 300,
                timestamp: start.addingTimeInterval(Double(index * 60))
            )
        }

        let suiteName = TestDefaultsSuite.makeName("StockbarTests.MenuChartRange.")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaultsSuite.remove(suiteName) }
        let selectionStore = MenuChartTimeRangeSelectionStore(defaults: defaults)
        let firstViewModel = MenuChartViewModel(
            symbol: symbol,
            currentPrice: 310,
            benchmarkSymbol: nil,
            timeRangeSelectionStore: selectionStore
        )
        firstViewModel.setTimeRange(.week)

        // When
        let recreatedViewModel = MenuChartViewModel(
            symbol: symbol,
            currentPrice: 311,
            benchmarkSymbol: nil,
            timeRangeSelectionStore: selectionStore
        )

        // Then
        XCTAssertEqual(recreatedViewModel.selectedTimeRange, .week)
    }

    func testStockbarMainSectionIncludesSettingsDestination() {
        // Given / When
        let sections = StockbarMainSection.allCases

        // Then
        XCTAssertTrue(sections.contains(.settings))
        XCTAssertEqual(StockbarMainSection.settings.title, "Settings")
        XCTAssertEqual(StockbarMainSection.settings.systemImage, "gearshape")
    }

    // MARK: - Portfolio Persistence Safety

    func testPortfolioCSVExportExcludesBenchmarkRows() {
        let benchmark = Trade(
            name: "^GSPC",
            position: Position(unitSize: "0", positionAvgCost: "0", currency: "USD", costCurrency: "USD"),
            isWatchlistOnly: true,
            showInMenuBar: false
        )
        let stock = Trade(
            name: "MU",
            position: Position(unitSize: "150", positionAvgCost: "76.79", currency: "USD", costCurrency: "USD")
        )

        let csv = PortfolioManager.exportToCSV(trades: [
            RealTimeTrade(trade: benchmark, realTimeInfo: TradingInfo()),
            RealTimeTrade(trade: stock, realTimeInfo: TradingInfo())
        ])

        XCTAssertFalse(csv.contains("^GSPC"))
        XCTAssertTrue(csv.contains("MU,150.0,76.79,USD"))
    }

    func testPortfolioCSVImportRejectsBenchmarkRows() {
        let csv = """
        Symbol,Units,AvgPositionCost,CostCurrency
        ^FTSE,0,0,USD
        SSE.L,100,17.622,GBP
        """

        let result = PortfolioManager.importFromCSV(csv)

        XCTAssertEqual(result.trades.map(\.name), ["SSE.L"])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("internal benchmark"))
    }

    func testLegacyTradeJSONDecodesMissingMenuVisibility() throws {
        let json = """
        [{
          "name": "MU",
          "position": {
            "_unitSize": "150",
            "positionAvgCostString": "76.79",
            "currency": "USD"
          },
          "isWatchlistOnly": false
        }]
        """

        let decoded = try JSONDecoder().decode([Trade].self, from: Data(json.utf8))

        XCTAssertEqual(decoded[0].name, "MU")
        XCTAssertFalse(decoded[0].isWatchlistOnly)
        XCTAssertTrue(decoded[0].showInMenuBar)
    }

    func testLivePortfolioSamplesOnlyJoinASeriesInTheirCurrency() {
        let manager = HistoricalDataManager.shared
        let now = Date()
        manager.recordLivePortfolioSample(totalValue: 4_321.5, totalGains: 21.5, currency: "GBP", timestamp: now.addingTimeInterval(-60))

        let gbpValues = manager.getStoredPortfolioValues(for: .day, currency: "GBP").map(\.value)
        let usdValues = manager.getStoredPortfolioValues(for: .day, currency: "USD").map(\.value)

        XCTAssertTrue(gbpValues.contains { abs($0 - 4_321.5) < 0.0001 })
        XCTAssertFalse(usdValues.contains { abs($0 - 4_321.5) < 0.0001 })
    }

    func testPerformanceMetricsUseDailyClosesAndOnlyAnnualiseLongSpans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))!
        func point(_ hours: Double, _ value: Double) -> ChartDataPoint {
            ChartDataPoint(date: start.addingTimeInterval(hours * 3_600), value: value)
        }
        // Three intraday samples on day one, then one close each on days two and three.
        let shortSeries = [point(0, 100), point(1, 90), point(2, 100), point(24, 110), point(48, 99)]

        let short = try XCTUnwrap(HistoricalDataManager.performanceMetrics(
            points: shortSeries, previousPoint: nil, currency: "GBP", calendar: calendar
        ))
        XCTAssertEqual(short.totalReturn, -1, accuracy: 0.0001)
        XCTAssertEqual(short.winRate ?? -1, 50, accuracy: 0.0001, "Two daily returns: +10%, then -10%")
        XCTAssertNil(short.annualizedReturn, "Two days must not be annualised")
        XCTAssertEqual(short.currency, "GBP")

        let longSeries = [point(0, 100), point(24 * 365.25, 110)]
        let long = try XCTUnwrap(HistoricalDataManager.performanceMetrics(
            points: longSeries, previousPoint: nil, currency: "GBP", calendar: calendar
        ))
        XCTAssertEqual(long.annualizedReturn ?? .nan, 10, accuracy: 0.01)
    }

    func testCustomPortfolioRangeUsesTheChosenDates() {
        let manager = HistoricalDataManager.shared
        let now = Date()
        let from = now.addingTimeInterval(-200 * 86_400)
        let to = now.addingTimeInterval(-150 * 86_400)

        let bounds = manager.portfolioRangeBounds(for: .custom, customFrom: from, customTo: to, now: now)
        XCTAssertEqual(bounds.start, from)
        XCTAssertEqual(bounds.end, to)
        XCTAssertEqual(manager.portfolioRangeBounds(for: .month, customFrom: from, customTo: to, now: now).end, now)
    }

    func testPriceHistoryCoverageNeedsPointsNearTheRangeStart() {
        let end = Date()
        let start = end.addingTimeInterval(-30 * 86_400)
        let recent = (0..<20).map {
            PriceSnapshot(timestamp: end.addingTimeInterval(-Double($0) * 3_600), price: 10, previousClose: 10, symbol: "X")
        }.reversed()
        let early = [PriceSnapshot(timestamp: start.addingTimeInterval(86_400), price: 10, previousClose: 10, symbol: "X")]

        XCTAssertFalse(HistoricalDataManager.snapshotsReachRangeStart(Array(recent), from: start, to: end))
        XCTAssertTrue(HistoricalDataManager.snapshotsReachRangeStart(early + recent, from: start, to: end))
    }

    private func makeRealTimeTrade(
        symbol: String,
        units: String,
        avgCost: String,
        currentPrice: Double,
        previousClose: Double,
        currency: String = "USD",
        costCurrency: String? = "USD"
    ) -> RealTimeTrade {
        let trade = Trade(
            name: symbol,
            position: Position(unitSize: units, positionAvgCost: avgCost, currency: currency, costCurrency: costCurrency)
        )
        return RealTimeTrade(
            trade: trade,
            realTimeInfo: makeTradingInfo(currentPrice: currentPrice, previousClose: previousClose, currency: currency)
        )
    }

    private func makeRealTimeTrade(
        symbol: String,
        units: Double,
        currentPrice: Double,
        currency: String,
        isWatchlistOnly: Bool = false
    ) -> RealTimeTrade {
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = currentPrice
        tradingInfo.prevClosePrice = currentPrice
        tradingInfo.currency = currency

        let trade = Trade(
            name: symbol,
            position: Position(
                unitSize: String(units),
                positionAvgCost: String(currentPrice),
                currency: currency,
                costCurrency: currency
            ),
            isWatchlistOnly: isWatchlistOnly
        )

        return RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
    }

    private func makeTradingInfo(
        currentPrice: Double,
        previousClose: Double,
        currency: String = "USD"
    ) -> TradingInfo {
        var tradingInfo = TradingInfo()
        tradingInfo.currentPrice = currentPrice
        tradingInfo.prevClosePrice = previousClose
        tradingInfo.currency = currency
        return tradingInfo
    }

    @MainActor
    private final class SchedulerOperationStub {
        private let started: XCTestExpectation
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var outcome: HistoricalPriceFetchOutcome
        private(set) var startCount = 0

        init(
            started: XCTestExpectation,
            outcome: HistoricalPriceFetchOutcome = .success
        ) {
            self.started = started
            self.outcome = outcome
        }

        func run() async -> HistoricalPriceFetchOutcome {
            startCount += 1
            started.fulfill()
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            return outcome
        }

        func finish(_ outcome: HistoricalPriceFetchOutcome) {
            self.outcome = outcome
            let continuations = self.continuations
            self.continuations = []
            continuations.forEach { $0.resume() }
        }
    }

    private func makePriceSnapshot(
        timestamp: Date,
        price: Double,
        symbol: String
    ) -> PriceSnapshot {
        PriceSnapshot(
            timestamp: timestamp,
            price: price,
            previousClose: price,
            volume: nil,
            symbol: symbol
        )
    }

    func testHistoricalFetchRequestGateEmptyResultsUseExponentialBackoffUpToSixHours() {
        var gate = HistoricalFetchRequestGate()
        let startTime = Date(timeIntervalSince1970: 100_000)
        let cooldown: TimeInterval = 600
        let delays: [TimeInterval] = [1_800, 3_600, 7_200, 14_400, 21_600, 21_600]

        XCTAssertTrue(gate.reserve(key: "price|AAPL|1D", now: startTime, cooldown: cooldown))
        gate.complete(key: "price|AAPL|1D", outcome: .empty, now: startTime, cooldown: cooldown)

        var completionTime = startTime
        for delay in delays {
            let retryTime = completionTime.addingTimeInterval(delay)
            XCTAssertFalse(
                gate.reserve(
                    key: "price|AAPL|1D",
                    now: retryTime.addingTimeInterval(-1),
                    cooldown: cooldown
                )
            )
            XCTAssertTrue(gate.reserve(key: "price|AAPL|1D", now: retryTime, cooldown: cooldown))
            gate.complete(key: "price|AAPL|1D", outcome: .empty, now: retryTime, cooldown: cooldown)
            completionTime = retryTime
        }
    }

    func testHistoricalFetchRequestGateSuccessAndCancelledOutcomesResetEmptyBackoff() {
        var gate = HistoricalFetchRequestGate()
        let startTime = Date(timeIntervalSince1970: 200_000)
        let key = "price|MSFT|1W"
        let cooldown: TimeInterval = 600

        XCTAssertTrue(gate.reserve(key: key, now: startTime, cooldown: cooldown))
        gate.complete(key: key, outcome: .empty, now: startTime, cooldown: cooldown)

        let forcedTime = startTime.addingTimeInterval(100)
        XCTAssertTrue(gate.reserve(key: key, now: forcedTime, cooldown: cooldown, force: true))
        gate.complete(key: key, now: forcedTime, cooldown: cooldown)
        XCTAssertFalse(gate.reserve(key: key, now: forcedTime.addingTimeInterval(599), cooldown: cooldown))
        XCTAssertTrue(gate.reserve(key: key, now: forcedTime.addingTimeInterval(600), cooldown: cooldown))

        gate.complete(key: key, outcome: .empty, now: forcedTime.addingTimeInterval(600), cooldown: cooldown)
        XCTAssertFalse(gate.reserve(key: key, now: forcedTime.addingTimeInterval(700), cooldown: cooldown))

        XCTAssertTrue(
            gate.reserve(
                key: key,
                now: forcedTime.addingTimeInterval(700),
                cooldown: cooldown,
                force: true
            )
        )
        gate.complete(key: key, outcome: .cancelled, now: forcedTime.addingTimeInterval(700), cooldown: cooldown)
        XCTAssertTrue(gate.reserve(key: key, now: forcedTime.addingTimeInterval(701), cooldown: cooldown))
    }

    @MainActor
    func testHistoricalPriceFetchSchedulerRunsMaximumTwoRequestsAndStartsQueuedRequestWhenOneCompletes() async {
        let currentTime = Date(timeIntervalSince1970: 300_000)
        let scheduler = HistoricalPriceFetchScheduler(
            maximumConcurrentRequests: 2,
            cooldown: 600,
            now: { currentTime }
        )
        let firstStarted = XCTestExpectation(description: "First request starts")
        let secondStarted = XCTestExpectation(description: "Second request starts")
        let thirdStarted = XCTestExpectation(description: "Queued request starts after completion")
        let first = SchedulerOperationStub(started: firstStarted)
        let second = SchedulerOperationStub(started: secondStarted)
        let third = SchedulerOperationStub(started: thirdStarted)

        XCTAssertTrue(scheduler.schedule(key: "price|AAA|1D") { await first.run() })
        XCTAssertTrue(scheduler.schedule(key: "price|BBB|1D") { await second.run() })
        XCTAssertTrue(scheduler.schedule(key: "price|CCC|1D") { await third.run() })
        XCTAssertFalse(scheduler.schedule(key: "price|CCC|1D") { await third.run() })
        XCTAssertFalse(scheduler.schedule(key: "price|CCC|1D", force: true) { await third.run() })
        XCTAssertFalse(scheduler.schedule(key: "price|AAA|1D", force: true) { await first.run() })

        await fulfillment(of: [firstStarted, secondStarted], timeout: 1)
        XCTAssertEqual(first.startCount, 1)
        XCTAssertEqual(second.startCount, 1)
        XCTAssertEqual(third.startCount, 0)

        first.finish(.success)
        await fulfillment(of: [thirdStarted], timeout: 1)
        XCTAssertEqual(third.startCount, 1)
        XCTAssertEqual(second.startCount, 1)

        second.finish(.success)
        third.finish(.success)
    }

    @MainActor
    func testHistoricalPriceFetchSchedulerForceBypassesEmptyRetryWithoutDuplicatingInFlightRequest() async {
        var currentTime = Date(timeIntervalSince1970: 400_000)
        let scheduler = HistoricalPriceFetchScheduler(
            maximumConcurrentRequests: 1,
            cooldown: 600,
            now: { currentTime }
        )
        let key = "price|EMPTY|1D"
        let firstStarted = XCTestExpectation(description: "Empty request starts")
        let forcedStarted = XCTestExpectation(description: "Forced retry starts")
        let sentinelStarted = XCTestExpectation(description: "Completion barrier starts")
        let first = SchedulerOperationStub(started: firstStarted)
        let forced = SchedulerOperationStub(started: forcedStarted)
        let sentinel = SchedulerOperationStub(started: sentinelStarted)

        XCTAssertTrue(scheduler.schedule(key: key) { await first.run() })
        await fulfillment(of: [firstStarted], timeout: 1)
        first.finish(.empty)

        XCTAssertTrue(scheduler.schedule(key: "price|BARRIER|1D") { await sentinel.run() })
        await fulfillment(of: [sentinelStarted], timeout: 1)
        sentinel.finish(.success)

        currentTime = currentTime.addingTimeInterval(100)
        XCTAssertFalse(scheduler.schedule(key: key) { await forced.run() })
        XCTAssertTrue(scheduler.schedule(key: key, force: true) { await forced.run() })
        await fulfillment(of: [forcedStarted], timeout: 1)
        XCTAssertFalse(scheduler.schedule(key: key, force: true) { await forced.run() })
        XCTAssertEqual(forced.startCount, 1)

        forced.finish(.success)
    }

    func testInstrumentAliasHistoryLookupCombinesStoredAndLiveAliasSeriesWithoutChangingPoints() {
        let requested = "NEW"
        let alias = "OLD"
        let stored = [
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: 101, symbol: alias),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: 201, symbol: alias),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 400), price: 0, symbol: alias)
        ]
        let live = [
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: 203, symbol: requested),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 300), price: 303, symbol: requested)
        ]

        let combined = InstrumentAliasHistoryLookup.combinedSnapshots(
            for: requested,
            aliases: [alias],
            storedBySymbol: [alias: stored, requested: []],
            liveBySymbol: [requested: live]
        )

        XCTAssertEqual(combined.map(\.timestamp.timeIntervalSince1970), [100, 200, 300])
        XCTAssertEqual(combined.map(\.price), [101, 203, 303])
        XCTAssertEqual(combined.map(\.symbol), [alias, requested, requested])
    }

    func testAWindowOfTheCombinedHistoryHasTheSamePricesAsTheWholeSeriesCutToIt() {
        let requested = "NEW"
        let alias = "OLD"
        let olderAlias = "OLDER"
        let base = 1_700_000_000.0
        func price(_ offset: Double, _ value: Double, _ symbol: String) -> PriceSnapshot {
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: base + offset), price: value, symbol: symbol)
        }
        func window(_ from: Double, _ to: Double) -> ClosedRange<Date> {
            Date(timeIntervalSince1970: base + from)...Date(timeIntervalSince1970: base + to)
        }
        // Prices that share a millisecond with one across a window's edge,
        // where a later alias or a live sample wins, and two invalid prices.
        let stored = [
            olderAlias: [price(120, 20, olderAlias), price(150, 21, olderAlias)],
            alias: [price(99.9994, 1, alias), price(100, 2, alias), price(100.0004, 3, alias), price(150, 4, alias),
                    price(199.9996, 5, alias), price(200.0004, 6, alias), price(250, 7, alias),
                    price(300.00049, 14, alias)],
            requested: [price(99.9996, 8, requested), price(150.0002, 9, requested), price(200.0001, 10, requested),
                        price(160, .nan, requested), price(170, 0, requested)]
        ]
        let live = [
            olderAlias: [price(120.0002, 22, olderAlias)],
            alias: [price(120.0003, 23, alias)],
            requested: [price(100.0001, 11, requested), price(199.9999, 12, requested), price(200.0006, 13, requested),
                        price(299.99951, 15, requested)]
        ]
        let aliases = [olderAlias, alias]
        let whole = InstrumentAliasHistoryLookup.combinedSnapshots(
            for: requested, aliases: aliases, storedBySymbol: stored, liveBySymbol: live
        )
        func windowed(_ window: ClosedRange<Date>) -> [PriceSnapshot] {
            InstrumentAliasHistoryLookup.combinedSnapshots(
                for: requested, aliases: aliases, storedBySymbol: stored, liveBySymbol: live, within: window
            )
        }
        let windows = [
            window(100, 200), window(99.9995, 200.0005), window(100.0002, 199.9998), window(100, 100),
            window(300.00048, 400), window(-base, 1_000)
        ]

        for window in windows {
            let expected = whole.filter { window.contains($0.timestamp) }
            let read = windowed(window)
            XCTAssertEqual(read.map(\.timestamp), expected.map(\.timestamp), "\(window)")
            XCTAssertEqual(read.map(\.price), expected.map(\.price), "\(window)")
            XCTAssertEqual(read.map(\.symbol), expected.map(\.symbol), "\(window)")
        }
        // At each edge of the first window a live sample won over the stored
        // prices, and the price just past its end is out.
        XCTAssertEqual(windowed(windows[0]).map(\.price), [11, 23, 9, 12])
        // Here those live samples fall outside while prices they won over
        // fall inside, and neither may appear.
        XCTAssertEqual(windowed(windows[2]).map(\.price), [23, 9])
        // The live sample 0.97 ms before this window wins over the stored
        // price 0.01 ms inside it, so reading must reach 1 ms past an edge.
        XCTAssertEqual(windowed(windows[4]).map(\.price), [])
        XCTAssertEqual(windowed(windows[5]).map(\.price), whole.map(\.price))
    }

    func testAliasPriceSnapshotCacheLooksUpASeriesWithoutBuildingOne() {
        var cache = AliasPriceSnapshotCache(pointLimit: 2, entryLimit: 4)
        func series(_ symbol: String) -> [PriceSnapshot] {
            [makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: 101, symbol: symbol)]
        }
        var resolveCount = 0

        XCTAssertNil(cache.cachedSnapshots(for: "NEW", aliases: ["OLD"]))
        _ = cache.snapshots(for: "NEW", aliases: ["OLD"]) { resolveCount += 1; return series("NEW") }
        XCTAssertEqual(resolveCount, 1, "the lookup that missed stored nothing")
        XCTAssertEqual(cache.cachedSnapshots(for: "NEW", aliases: ["OLD"])?.map(\.price), [101])

        // A lookup that hits counts as a use: NEW outlives OTHER when a
        // third series needs the room.
        _ = cache.snapshots(for: "OTHER", aliases: []) { series("OTHER") }
        XCTAssertNotNil(cache.cachedSnapshots(for: "NEW", aliases: ["OLD"]))
        _ = cache.snapshots(for: "THIRD", aliases: []) { series("THIRD") }
        XCTAssertNil(cache.cachedSnapshots(for: "OTHER", aliases: []))
        XCTAssertNotNil(cache.cachedSnapshots(for: "NEW", aliases: ["OLD"]))

        // A series cached for another alias list is not this symbol's, and is dropped.
        XCTAssertNil(cache.cachedSnapshots(for: "NEW", aliases: ["RENAMED"]))
        XCTAssertNil(cache.cachedSnapshots(for: "NEW", aliases: ["OLD"]))
        cache.removeAll()
        XCTAssertNil(cache.cachedSnapshots(for: "THIRD", aliases: []))
    }

    func testAliasPriceSnapshotCacheInvalidatesOnAliasChangeAndExplicitRemoval() {
        var cache = AliasPriceSnapshotCache(pointLimit: 10, entryLimit: 4)
        let original = [
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: 101, symbol: "NEW"),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: 202, symbol: "NEW")
        ]
        let rebuilt = [
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 300), price: 303, symbol: "NEW")
        ]
        var resolved = original
        var resolveCount = 0

        let firstRead = cache.snapshots(for: "NEW", aliases: ["OLD"]) {
            resolveCount += 1
            return resolved
        }
        let repeatedRead = cache.snapshots(for: "NEW", aliases: ["OLD"]) {
            resolveCount += 1
            return resolved
        }
        XCTAssertEqual(firstRead.map(\.id), repeatedRead.map(\.id))
        XCTAssertEqual(repeatedRead.map(\.timestamp), original.map(\.timestamp))
        XCTAssertEqual(repeatedRead.map(\.price), original.map(\.price))
        XCTAssertEqual(resolveCount, 1)

        cache.removeAll()
        resolved = rebuilt
        let afterRemoveAll = cache.snapshots(for: "NEW", aliases: ["OLD"]) {
            resolveCount += 1
            return resolved
        }
        XCTAssertEqual(afterRemoveAll.map(\.price), rebuilt.map(\.price))
        XCTAssertEqual(resolveCount, 2)

        resolved = original
        let afterAliasChange = cache.snapshots(for: "NEW", aliases: ["OTHER"]) {
            resolveCount += 1
            return resolved
        }
        XCTAssertEqual(afterAliasChange.map(\.timestamp), original.map(\.timestamp))
        XCTAssertEqual(resolveCount, 3)
    }

    func testAliasPriceSnapshotCacheEvictsLeastRecentlyUsedEntryForPointBudget() {
        var cache = AliasPriceSnapshotCache(pointLimit: 8, entryLimit: 4)
        var resolveCountBySymbol: [String: Int] = [:]

        func load(_ symbol: String, price: Double) -> [PriceSnapshot] {
            resolveCountBySymbol[symbol, default: 0] += 1
            return [
                makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: price, symbol: symbol),
                makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: price + 1, symbol: symbol)
            ]
        }

        _ = cache.snapshots(for: "A", aliases: []) { load("A", price: 101) }
        _ = cache.snapshots(for: "B", aliases: []) { load("B", price: 201) }
        _ = cache.snapshots(for: "C", aliases: []) { load("C", price: 301) }
        _ = cache.snapshots(for: "A", aliases: []) { load("A", price: 101) }
        _ = cache.snapshots(for: "D", aliases: []) { load("D", price: 401) }
        _ = cache.snapshots(for: "E", aliases: []) {
            resolveCountBySymbol["E", default: 0] += 1
            return [
                makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: 501, symbol: "E"),
                makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: 502, symbol: "E"),
                makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 300), price: 503, symbol: "E")
            ]
        }

        XCTAssertEqual(resolveCountBySymbol, ["A": 1, "B": 1, "C": 1, "D": 1, "E": 1])
        _ = cache.snapshots(for: "A", aliases: []) { load("A", price: 101) }
        _ = cache.snapshots(for: "D", aliases: []) { load("D", price: 401) }
        XCTAssertEqual(resolveCountBySymbol["A"], 1)
        XCTAssertEqual(resolveCountBySymbol["D"], 1)

        _ = cache.snapshots(for: "B", aliases: []) { load("B", price: 201) }
        _ = cache.snapshots(for: "C", aliases: []) { load("C", price: 301) }
        XCTAssertEqual(resolveCountBySymbol["B"], 2)
        XCTAssertEqual(resolveCountBySymbol["C"], 2)
    }

    func testAliasPriceSnapshotCacheDoesNotCacheSeriesLargerThanPointBudget() {
        var cache = AliasPriceSnapshotCache(pointLimit: 2, entryLimit: 4)
        let series = [
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 100), price: 101, symbol: "NEW"),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 200), price: 202, symbol: "NEW"),
            makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 300), price: 303, symbol: "NEW")
        ]
        var resolveCount = 0

        let firstRead = cache.snapshots(for: "NEW", aliases: []) {
            resolveCount += 1
            return series
        }
        let repeatedRead = cache.snapshots(for: "NEW", aliases: []) {
            resolveCount += 1
            return series
        }

        XCTAssertEqual(firstRead.map(\.timestamp), series.map(\.timestamp))
        XCTAssertEqual(repeatedRead.map(\.price), series.map(\.price))
        XCTAssertEqual(resolveCount, 2)
    }

    @MainActor
    func testHistoricalDataManagerPriceSnapshotRollingWindowReflectsStoredAndLiveChanges() {
        let manager = HistoricalDataManager.shared
        let symbol = "ROLLING-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 500_000)
        let beforeWindow = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let windowStart = now.addingTimeInterval(-6 * 24 * 60 * 60)
        let middle = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let stored = [
            makePriceSnapshot(timestamp: beforeWindow, price: 101, symbol: symbol),
            makePriceSnapshot(timestamp: windowStart, price: 202, symbol: symbol),
            makePriceSnapshot(timestamp: middle, price: 303, symbol: symbol)
        ]

        manager.priceSnapshots[symbol] = stored
        XCTAssertEqual(
            manager.getPriceSnapshots(for: symbol, from: windowStart, to: now).map(\.price),
            [202, 303]
        )

        manager.recordLivePriceSample(symbol: symbol, price: 404, previousClose: 303, timestamp: now)
        XCTAssertEqual(
            manager.getPriceSnapshots(for: symbol, from: windowStart, to: now).map(\.price),
            [202, 303, 404]
        )

        // The same window once the whole series is built and cached, and a
        // range that ends before it starts.
        XCTAssertEqual(manager.aliasAwarePriceSnapshots(for: symbol).map(\.price), [101, 202, 303, 404])
        XCTAssertEqual(
            manager.getPriceSnapshots(for: symbol, from: windowStart, to: now).map(\.price),
            [202, 303, 404]
        )
        XCTAssertTrue(manager.getPriceSnapshots(for: symbol, from: now, to: windowStart).isEmpty)

        manager.priceSnapshots[symbol] = []
        XCTAssertEqual(
            manager.getPriceSnapshots(for: symbol, from: windowStart, to: now).map(\.price),
            [404]
        )
    }

    @MainActor
    func testPriceChangeSignalOnlyAffectsTheSymbolsThatChanged() {
        let manager = HistoricalDataManager.shared
        let shown = "SHOWN-\(UUID().uuidString)"
        let other = "OTHER-\(UUID().uuidString)"
        defer {
            manager.priceSnapshots.removeValue(forKey: shown)
            manager.priceSnapshots.removeValue(forKey: other)
        }

        XCTAssertTrue(manager.priceDataChange(nil, affects: [shown]), "an unspecified change affects every chart")
        XCTAssertTrue(manager.priceDataChange([shown.uppercased()], affects: [shown.lowercased()]))
        XCTAssertFalse(manager.priceDataChange([other.uppercased()], affects: [shown]))

        let before = manager.priceSeriesFingerprint(for: [shown])
        manager.priceSnapshots[other] = [makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), price: 1, symbol: other)]
        XCTAssertEqual(manager.priceSeriesFingerprint(for: [shown]), before, "another symbol's update must not reload this chart")

        manager.priceSnapshots[shown] = [makePriceSnapshot(timestamp: Date(timeIntervalSince1970: 2_000), price: 2, symbol: shown)]
        XCTAssertNotEqual(manager.priceSeriesFingerprint(for: [shown]), before)
    }

    @MainActor
    func testSymbolChartLoadsOnceOnPresentationAndCoalescesRangeAndPriceChanges() async {
        let suite = TestDefaultsSuite.makeName("StockbarTests.ChartLoads.")
        let defaults = UserDefaults(suiteName: suite)!
        defer { TestDefaultsSuite.remove(suite) }
        let model = MenuChartViewModel(
            symbol: "CHART-\(UUID().uuidString)", currentPrice: 100, benchmarkSymbol: nil,
            timeRangeSelectionStore: MenuChartTimeRangeSelectionStore(defaults: defaults)
        )
        model.updateCurrentPrice(101)
        model.setTimeRange(.week)
        XCTAssertEqual(model.loadGeneration, 0, "An undisplayed chart must not load history")

        let loaded = expectation(description: "One initial load finishes")
        let subscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        model.activate()
        model.activate()
        model.loadChartData()
        model.setTimeRange(.month)
        model.updateCurrentPrice(105)
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 1)
        XCTAssertEqual(model.selectedTimeRange, .month)
        XCTAssertEqual(model.chartData.last?.price, 105, "The coalesced load must use the latest price")
        model.deactivate()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testSymbolChartCancelsHiddenLoadAndUsesLatestStoredHistoryWhenReopened() async {
        let manager = HistoricalDataManager.shared
        let symbol = "VISIBLE-\(UUID().uuidString)"
        let now = Date()
        let series = (0..<12).map { index in
            makePriceSnapshot(timestamp: now.addingTimeInterval(Double(index - 12) * 60),
                              price: Double(100 + index), symbol: symbol)
        }
        let suite = TestDefaultsSuite.makeName("StockbarTests.ChartVisibility.")
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            TestDefaultsSuite.remove(suite)
            manager.priceSnapshots.removeValue(forKey: symbol)
        }
        let model = MenuChartViewModel(
            symbol: symbol, currentPrice: 112, benchmarkSymbol: nil,
            timeRangeSelectionStore: MenuChartTimeRangeSelectionStore(defaults: defaults)
        )
        model.activate()
        model.deactivate() // Cancel the queued first load before it does any work.
        manager.priceSnapshots[symbol] = series
        model.updateCurrentPrice(120)
        model.loadChartData()
        XCTAssertEqual(model.loadGeneration, 0)

        let loaded = expectation(description: "Reopened chart uses latest data")
        let subscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        model.activate()
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 1)
        XCTAssertEqual(model.chartData.last?.price, 120)
        XCTAssertGreaterThan(model.chartData.count, 1)
        model.deactivate()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testPortfolioChartCoalescesPresentationUpdatesAndDetectsInPlaceHoldingsChanges() async {
        let holding = makeRealTimeTrade(symbol: "INPUT-\(UUID().uuidString)", units: 1, currentPrice: 100, currency: "USD")
        let model = PortfolioMenuChartViewModel(currentValue: 100, currentTrades: [holding],
                                               preferredCurrency: "USD", valuationSource: .localCalculationFallback)
        let initial = expectation(description: "Initial portfolio load")
        let firstSubscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in initial.fulfill() }
        model.activate()
        model.update(currentValue: 100, currentTrades: [holding], preferredCurrency: "USD", valuationSource: .localCalculationFallback)
        model.setTimeRange(.day)
        model.loadChartData()
        await fulfillment(of: [initial], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 1)

        let changed = expectation(description: "In-place holding edit reloads even with the same total")
        let secondSubscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in changed.fulfill() }
        holding.trade.position.unitSizeString = "2"
        model.update(currentValue: 100, currentTrades: [holding], preferredCurrency: "USD", valuationSource: .localCalculationFallback)
        model.update(currentValue: 100, currentTrades: [holding], preferredCurrency: "USD", valuationSource: .localCalculationFallback)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 2)
        model.deactivate()
        withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }

    @MainActor
    func testPortfolioChartStartsInRequestedRangeAndRefreshesOnReappearance() async {
        let model = PortfolioMenuChartViewModel(currentValue: 100, currentTrades: [],
                                               preferredCurrency: "USD", valuationSource: .localCalculationFallback,
                                               initialRange: .week)
        XCTAssertEqual(model.selectedTimeRange, .week)
        XCTAssertEqual(model.loadGeneration, 0)
        let initial = expectation(description: "Week loads without an initial day load")
        let firstSubscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in initial.fulfill() }
        model.activate()
        await fulfillment(of: [initial], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 1)
        model.deactivate()
        model.setTimeRange(.month)
        model.update(currentValue: 200, currentTrades: [], preferredCurrency: "GBP", valuationSource: .localCalculationFallback)
        XCTAssertEqual(model.loadGeneration, 1, "Hidden charts should retain inputs without loading")
        let reopened = expectation(description: "Month reloads when shown again")
        let secondSubscription = model.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in reopened.fulfill() }
        model.activate()
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertEqual(model.loadGeneration, 2)
        XCTAssertEqual(model.selectedTimeRange, .month)
        model.deactivate()
        withExtendedLifetime((firstSubscription, secondSubscription)) {}
    }

}

final class PortfolioBackupFormatTests: XCTestCase {
    func testParseAmountReadsGroupingAndLocaleDecimalsAndRejectsJunk() {
        let uk = Locale(identifier: "en_GB")
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(Position.parseAmount("1,000", locale: uk), 1_000)
        XCTAssertEqual(Position.parseAmount(" 10.25 ", locale: german), 10.25, "A plain '.' decimal works in any locale")
        XCTAssertEqual(Position.parseAmount("12,50", locale: german), 12.5)
        XCTAssertEqual(Position.parseAmount("0", locale: uk), 0, "Watchlist rows can hold zero units")
        XCTAssertNil(Position.parseAmount("abc", locale: uk))
        XCTAssertNil(Position.parseAmount("-5", locale: uk))
        XCTAssertNil(Position.parseAmount("", locale: uk))
        XCTAssertTrue(Position.isReadableAmount("  "))
        XCTAssertFalse(Position.isReadableAmount("12x"))
    }

    func testBackupRoundTripKeepsWatchlistMenuBarAndCurrencyAndSurvivesBlankCost() throws {
        let watched = Trade(
            name: "VOD.L",
            position: Position(unitSize: "0", positionAvgCost: "", currency: "GBP", costCurrency: "GBX"),
            isWatchlistOnly: true,
            showInMenuBar: false
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = PortfolioExportData.nonFiniteEncoding
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = PortfolioExportData.nonFiniteDecoding

        let data = try encoder.encode([PortfolioExportData(from: watched)])
        let restored = try XCTUnwrap(try decoder.decode([PortfolioExportData].self, from: data).first).toTrade()

        XCTAssertTrue(restored.isWatchlistOnly)
        XCTAssertFalse(restored.showInMenuBar)
        XCTAssertEqual(restored.position.currency, "GBP")
        XCTAssertEqual(restored.position.costCurrency, "GBX")
        XCTAssertEqual(restored.position.positionAvgCostString, "", "A blank cost stays blank rather than failing the backup")
    }

    func testBackupsWrittenBeforeTheNewFieldsStillDecode() throws {
        let old = #"[{"symbol":"AAPL","units":5,"avgPositionCost":150.5,"costCurrency":"USD"}]"#
        let trade = try XCTUnwrap(try JSONDecoder().decode([PortfolioExportData].self, from: Data(old.utf8)).first).toTrade()
        XCTAssertEqual(trade.name, "AAPL")
        XCTAssertFalse(trade.isWatchlistOnly)
        XCTAssertTrue(trade.showInMenuBar)
        XCTAssertEqual(trade.position.currency, "USD")
        XCTAssertEqual(trade.position.positionAvgCost, 150.5)
    }
}

final class PriceAlertConditionTests: XCTestCase {
    func testPercentChangeIsMeasuredFromPreviousCloseAndFiresOnce() {
        let alert = PriceAlert(symbol: "AV.L", condition: .percentChange, threshold: 5)
        // A slow 1%-per-refresh climb from a 100 close.
        let prices: [Double] = [101, 102, 103, 104, 105.2, 106, 107]
        var last = 100.0
        var fired: [Double] = []
        for price in prices {
            if alert.conditionMet(currentPrice: price, previousPrice: last, previousClose: 100) { fired.append(price) }
            last = price
        }
        XCTAssertEqual(fired, [105.2], "Fires when the day's move first reaches 5%, then not again")
        XCTAssertTrue(alert.conditionMet(currentPrice: 94, previousPrice: 99, previousClose: 100), "Falls count too")
        XCTAssertFalse(alert.conditionMet(currentPrice: 110, previousPrice: 104, previousClose: .nan), "No close, no % alert")
    }

    func testAboveAndBelowStillFireOnCrossing() {
        let above = PriceAlert(symbol: "AAPL", condition: .above, threshold: 150)
        XCTAssertTrue(above.conditionMet(currentPrice: 151, previousPrice: 149))
        XCTAssertFalse(above.conditionMet(currentPrice: 152, previousPrice: 151))
        let below = PriceAlert(symbol: "AAPL", condition: .below, threshold: 150)
        XCTAssertTrue(below.conditionMet(currentPrice: 149, previousPrice: 150))
    }

    func testStoredIdentityAndCooldownSurviveRebuilding() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_000)
        let triggered = Date(timeIntervalSince1970: 2_000)
        var alert = PriceAlert(
            id: id, symbol: "AAPL", condition: .above, threshold: 150,
            isEnabled: true, createdAt: created, lastTriggered: triggered
        )
        alert.isEnabled = false
        XCTAssertEqual(alert.id, id)
        XCTAssertEqual(alert.createdAt, created)
        XCTAssertEqual(alert.lastTriggered, triggered)
        XCTAssertFalse(alert.conditionMet(currentPrice: 151, previousPrice: 149), "Paused alerts never fire")
    }
}

@MainActor
final class PriceAlertBatchTests: XCTestCase {
    /// A refresh's prices are checked as one batch, so the last checked prices
    /// are saved once, not once for every alerted symbol whose price moved.
    func testBatchSavesLastCheckedPricesOnce() {
        let service = PriceAlertService.shared
        let defaults = StockbarRuntimeStorage.userDefaults
        let key = PriceAlertService.lastKnownPricesKey
        let storedBefore = defaults.object(forKey: key)
        // Paused alerts are remembered like active ones but never fire, so the
        // test sends no notifications and asks for no permission.
        let symbols = ["BATCHA", "BATCHB", "BATCHC"]
        let alerts = symbols.map {
            PriceAlert(symbol: $0, condition: .above, threshold: 1_000_000, isEnabled: false)
        }
        for alert in alerts { service.addAlert(alert) }
        let checks = symbols.enumerated().map { index, symbol in
            PriceAlertService.PriceCheck(
                symbol: symbol, currentPrice: 100 + Double(index), previousPrice: 99, currency: "USD"
            )
        }
        defer {
            for alert in alerts { service.removeAlert(id: alert.id) }
            service.checkAlerts(checks)  // Forgets the prices of symbols without alerts.
            defaults.set(storedBefore, forKey: key)
        }

        let writes = DefaultsWriteCounter(defaults: defaults, key: key)
        service.checkAlerts(checks)
        XCTAssertEqual(writes.count, 1, "Three changed prices are saved together")
        let stored = defaults.dictionary(forKey: key) as? [String: Double]
        XCTAssertEqual(stored?["BATCHA"], 100)
        XCTAssertEqual(stored?["BATCHC"], 102)

        service.checkAlerts(checks)
        XCTAssertEqual(writes.count, 1, "Unchanged prices are not saved again")
    }
}

/// Counts writes to one defaults key through key-value observing.
private final class DefaultsWriteCounter: NSObject {
    private(set) var count = 0
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        count += 1
    }
}

final class PortfolioTotalReturnTests: XCTestCase {
    private func summary(value: Double = 1_100, netDeposits: Double?) -> DisplayPortfolioSummary {
        DisplayPortfolioSummary(
            totalValue: value, totalGain: 99, totalGainPct: 49.25, dayGain: 0, dayGainPct: 0,
            totalCost: 201, ownedPositionCount: 1, currency: "GBP",
            valuationSource: .folyncProvided, netDeposits: netDeposits
        )
    }

    func testNetDepositsAreUsedOnlyWhenChosenAndKnown() {
        let chosen = summary(netDeposits: 600).totalReturn(measuredAgainst: .netDeposits)
        XCTAssertEqual(chosen, PortfolioTotalReturn(
            gain: 500, percent: 500.0 / 600.0 * 100, basisAmount: 600, isMeasuredAgainstNetDeposits: true
        ))

        let notChosen = summary(netDeposits: 600).totalReturn(measuredAgainst: .holdingsCost)
        XCTAssertEqual(notChosen, PortfolioTotalReturn(
            gain: 99, percent: 49.25, basisAmount: 201, isMeasuredAgainstNetDeposits: false
        ))

        let unknown = summary(netDeposits: nil).totalReturn(measuredAgainst: .netDeposits)
        XCTAssertEqual(unknown, notChosen, "without net deposits P&L falls back to the cost of the holdings")
        XCTAssertEqual(unknown.basisLabel, "Cost Basis")
        XCTAssertFalse(summary(netDeposits: .nan).totalReturn(measuredAgainst: .netDeposits).isMeasuredAgainstNetDeposits)
    }

    func testNoPercentageWhenNothingWasPaidInOnBalance() {
        for deposits in [0.0, -250] {
            let result = summary(netDeposits: deposits).totalReturn(measuredAgainst: .netDeposits)
            XCTAssertEqual(result.gain, 1_100 - deposits)
            XCTAssertTrue(result.percent.isNaN, "\(deposits)")
            XCTAssertEqual(MenuPopoverFormatter.percent(result.percent), "")
        }
    }

    @MainActor
    func testTheChoiceDefaultsToNetDepositsAndIsRemembered() {
        let defaults = StockbarRuntimeStorage.userDefaults
        let key = PortfolioGainBasis.userDefaultsKey
        let storedBefore = defaults.object(forKey: key)
        defer { defaults.set(storedBefore, forKey: key) }
        defaults.removeObject(forKey: key)

        let model = DataModel(
            currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false),
            startRuntimeServices: false
        )
        XCTAssertEqual(model.portfolioGainBasis, .netDeposits)
        model.portfolioGainBasis = .holdingsCost
        XCTAssertEqual(defaults.string(forKey: key), "holdingsCost")
        XCTAssertNotNil(SettingsTransferKeys.settingsKeys[key], "the choice travels with a settings export")
    }
}

// MARK: - Overview: what the total is made of

@MainActor
final class PortfolioTotalCompositionTests: XCTestCase {
    private typealias Composition = PortfolioTotalComposition
    private typealias Figure = PortfolioTotalComposition.Figure

    private func make(total: Double = 84_310.47, deposits: Double = 68_408.36, unrealised: Double = 12_486.10,
                      realised: Double = 1_611.86, currency: String = "GBP",
                      currencies: [String?] = ["GBP", "GBP", "GBP", "GBP"]) -> Composition? {
        Composition(
            currency: currency,
            total: Figure(value: total, currency: currencies[0]),
            netDeposits: Figure(value: deposits, currency: currencies[1]),
            unrealised: Figure(value: unrealised, currency: currencies[2]),
            realised: Figure(value: realised, currency: currencies[3])
        )
    }

    func testTheRemainderIsWhatTheOtherThreeLeave() throws {
        let composition = try XCTUnwrap(make())
        XCTAssertEqual(composition.parts.map(\.kind), Composition.Kind.allCases)
        XCTAssertEqual(composition.parts.map(\.minorUnits), [6_840_836, 1_248_610, 161_186, 180_415])
        XCTAssertEqual(composition.parts.map(\.kind.title),
                       ["Net deposits", "Unrealised gains", "Realised gains", "Income, interest and fees"])
        XCTAssertEqual(composition.gainOnDeposits, 15_902.11, accuracy: 0.000_1)
    }

    func testThePartsShownAddUpToTheTotalShownAfterRounding() throws {
        // Each figure carries a fraction of a penny. Rounded on its own, the
        // remainder would show £49.99 and the parts would add up to £999.99.
        let composition = try XCTUnwrap(make(total: 1_000.006, deposits: 600.004, unrealised: 300.004, realised: 50.004))
        XCTAssertEqual(composition.totalMinorUnits, 100_001)
        XCTAssertEqual(composition.parts.last?.minorUnits, 5_001, "the rounding difference goes in the remainder")
        assertPartsAddUp(composition)

        var generator = SeededGenerator(seed: 20_261_120)
        for _ in 0..<500 {
            let figures = (0..<4).map { _ in Double.random(in: -50_000...150_000, using: &generator) }
            let random = try XCTUnwrap(make(total: figures[0], deposits: figures[1], unrealised: figures[2], realised: figures[3]))
            assertPartsAddUp(random)
        }
    }

    /// The figures as they are printed, read back, add up to the total as printed.
    private func assertPartsAddUp(_ composition: Composition, file: StaticString = #filePath, line: UInt = #line) {
        func pennies(_ text: String) -> Int64 {
            let digits = text.filter { $0.isNumber }
            return (Int64(digits) ?? 0) * (text.hasPrefix("-") ? -1 : 1)
        }
        let shown = composition.parts.map { pennies(StockbarOverviewView.legendFigure($0, currency: "GBP")) }
        let total = pennies(HoldingsCurrencyFormatter.amount(composition.total, currency: "GBP"))
        XCTAssertEqual(shown.reduce(0, +), total, file: file, line: line)
    }

    func testAFigureRoundedToPenniesPrintsAsTheFormatterPrintsIt() {
        // The hero and the card print `displayed(x)`; elsewhere the app prints `x`.
        var values: [Double] = [1.015, 2.675, 1.005, 0.125, 84_310.465, 1_000.006, -0.005, -2.675]
        values += (0..<2_000).map { Double($0 * 10 + 5) / 1_000 }
        values += (0..<2_000).map { 84_000 + Double($0 * 10 + 5) / 1_000 }
        for value in values {
            XCTAssertEqual(HoldingsCurrencyFormatter.amount(Composition.displayed(value), currency: "GBP"),
                           HoldingsCurrencyFormatter.amount(value, currency: "GBP"), "\(value)")
        }
    }

    func testTheCardIsNotBuiltFromMixedOrUnknownCurrencies() {
        XCTAssertNotNil(make(currencies: ["gbp", "GBP", " GBP", "GBP"]), "the same code, written differently")
        XCTAssertNil(make(currencies: ["GBP", "GBP", "GBP", "USD"]), "realised gains in another currency")
        XCTAssertNil(make(currencies: ["GBP", nil, "GBP", "GBP"]), "net deposits in an unknown currency")
        XCTAssertNil(make(currencies: [nil, "GBP", "GBP", "GBP"]))
        XCTAssertNil(make(currency: "USD"), "the page's currency differs from the figures'")
        XCTAssertNil(make(currency: ""))
        XCTAssertNil(make(realised: .nan), "an unknown figure is never taken as zero")
        XCTAssertNil(make(total: .infinity))
        XCTAssertNil(Composition(currency: "GBP", total: Figure(value: 10, currency: "GBP"),
                                 netDeposits: Figure(value: nil, currency: "GBP"),
                                 unrealised: Figure(value: 1, currency: "GBP"), realised: Figure(value: 1, currency: "GBP")))
    }

    @MainActor
    func testOnlyAFolyncPortfolioWithEveryFigureGetsTheCard() throws {
        let snapshot = try Self.snapshot()
        let deposits = try Self.netDeposits(68_408.36)
        let folync = Self.summary(source: .folyncProvided, netDeposits: 68_408.36)
        let composition = try XCTUnwrap(Composition.overview(summary: folync, snapshot: snapshot, netDeposits: deposits))
        XCTAssertEqual(composition.parts.map(\.minorUnits), [6_840_836, 1_248_610, 161_186, 180_415])
        XCTAssertFalse(composition.parts.contains { $0.isPartial })

        for source in [PortfolioValuationSource.localCalculationFallback, .marketDataFallback, .brokerProvided] {
            XCTAssertNil(Composition.overview(summary: Self.summary(source: source, netDeposits: 68_408.36),
                                              snapshot: snapshot, netDeposits: deposits), "\(source)")
        }
        XCTAssertNil(Composition.overview(summary: folync, snapshot: nil, netDeposits: deposits))
        XCTAssertNil(Composition.overview(summary: folync, snapshot: snapshot, netDeposits: nil))
        XCTAssertNil(Composition.overview(summary: Self.summary(source: .folyncProvided, netDeposits: nil),
                                          snapshot: snapshot, netDeposits: deposits))
        XCTAssertNil(Composition.overview(summary: folync, snapshot: snapshot,
                                          netDeposits: try Self.netDeposits(68_408.36, currency: "USD")))
        XCTAssertNil(Composition.overview(summary: folync, snapshot: try Self.snapshot(realisedCurrency: "USD"),
                                          netDeposits: deposits), "realised gains in dollars are not converted on their own")
        XCTAssertNil(Composition.overview(summary: folync, snapshot: try Self.snapshot(realisedQuality: "unavailable"),
                                          netDeposits: deposits), "a figure Folync marks unavailable is unknown")
        XCTAssertNil(Composition.overview(summary: folync, snapshot: try Self.snapshot(realised: "null"),
                                          netDeposits: deposits))

        let partial = try XCTUnwrap(Composition.overview(
            summary: folync, snapshot: try Self.snapshot(realisedQuality: "partial"), netDeposits: deposits
        ))
        XCTAssertEqual(partial.parts.map(\.isPartial), [false, false, true, true],
                       "a partial figure is marked, and so is the remainder taken from it")
        XCTAssertEqual(StockbarOverviewView.accessibilityLabel(partial.parts[2], currency: "GBP"),
                       "Realised gains, £1,611.86, partial")
    }

    @MainActor
    func testNegativeAndZeroPartsGetNoSegmentButKeepTheirFigure() throws {
        let composition = try XCTUnwrap(make(total: 900, deposits: 1_000, unrealised: -200, realised: 0))
        XCTAssertEqual(composition.parts.map(\.minorUnits), [100_000, -20_000, 0, 10_000])
        let fractions = composition.barFractions
        XCTAssertEqual(fractions[0], 1_000.0 / 1_100, accuracy: 0.000_001)
        XCTAssertEqual(fractions[1], 0, "a negative part has no length")
        XCTAssertEqual(fractions[2], 0, "nor has a zero one")
        XCTAssertEqual(fractions[3], 100.0 / 1_100, accuracy: 0.000_001)
        XCTAssertEqual(fractions.reduce(0, +), 1, accuracy: 0.000_001, "the positive parts share the whole bar")
        XCTAssertTrue(composition.barShowsPositivePartsOnly)
        XCTAssertEqual(StockbarOverviewView.positivePartsNote, "The bar shows the positive parts only.")

        let legend = composition.parts.map { StockbarOverviewView.legendFigure($0, currency: "GBP") }
        XCTAssertEqual(legend, ["£1,000.00", "-£200.00", "£0.00", "+£100.00"])
        XCTAssertEqual(composition.parts.map { StockbarOverviewView.accessibilityLabel($0, currency: "GBP") }, [
            "Net deposits, £1,000.00", "Unrealised gains, minus £200.00",
            "Realised gains, £0.00", "Income, interest and fees, £100.00",
        ])

        let zeroOnly = try XCTUnwrap(make(total: 1_100, deposits: 1_000, unrealised: 100, realised: 0))
        XCTAssertFalse(zeroOnly.barShowsPositivePartsOnly, "a zero part needs no note")
        let withdrawn = try XCTUnwrap(make(total: 100, deposits: -50, unrealised: 100, realised: 50))
        XCTAssertEqual(StockbarOverviewView.legendFigure(withdrawn.parts[0], currency: "GBP"), "-£50.00",
                       "more taken out than paid in")
        XCTAssertEqual(withdrawn.barFractions[0], 0)
    }

    @MainActor
    func testTheHeadingAndTotalReturnUseTheFiguresShown() throws {
        let composition = try XCTUnwrap(make())
        XCTAssertEqual(StockbarOverviewView.compositionHeading(composition), "What £84,310.47 is made of")
        let measured = PortfolioTotalReturn(gain: 15_902.11, percent: 23.246, basisAmount: 68_408.36,
                                            isMeasuredAgainstNetDeposits: true)
        let text = StockbarOverviewView.compositionReturnText(composition, totalReturn: measured)
        XCTAssertTrue(text.hasPrefix("total return +£15,902.11 ("), text)
        let againstCost = PortfolioTotalReturn(gain: 12_486.10, percent: 12, basisAmount: 1, isMeasuredAgainstNetDeposits: false)
        XCTAssertTrue(StockbarOverviewView.compositionReturnText(composition, totalReturn: againstCost)
            .hasPrefix("P&L against cost +£12,486.10"))
        XCTAssertEqual(StockbarOverviewView.compositionFootnote(cash: nil, positions: 1, currency: "GBP"), "1 position")
    }

    // MARK: Fixtures (invented figures)

    private static func summary(source: PortfolioValuationSource, netDeposits: Double?) -> DisplayPortfolioSummary {
        DisplayPortfolioSummary(
            totalValue: 84_310.47, totalGain: 12_486.10, totalGainPct: 18, dayGain: 512.36, dayGainPct: 0.61,
            totalCost: 69_000, ownedPositionCount: 9, currency: "GBP", valuationSource: source, netDeposits: netDeposits
        )
    }

    private static func netDeposits(_ amount: Double, currency: String = "GBP") throws -> FolyncNetDeposits {
        let json = """
        {"schemaVersion":2,"sourceRevision":"history-test",
         "scope":{"id":"all","name":"All portfolios","kind":"aggregate","currency":"\(currency)"},
         "range":"3m","interval":"1d","generatedAt":"2026-07-12T12:00:00Z","currency":"\(currency)",
         "quality":"complete","reasonCodes":[],
         "coverage":{"requestedFrom":"2026-04-12","requestedTo":"2026-07-12",
         "availableFrom":"2026-07-10","availableTo":"2026-07-11","pointCount":2,"complete":true},
         "portfolioSeries":[{"date":"2026-07-10","value":84000},{"date":"2026-07-11","value":84310.47}],
         "cashSeries":[],"holdingsSeries":[],
         "netContributionSeries":[{"date":"2026-07-10","value":68000},{"date":"2026-07-11","value":\(amount)}],
         "gainSeries":[],"twrSeries":[]}
        """
        let history = try JSONDecoder().decode(FolyncPortfolioHistory.self, from: Data(json.utf8))
        return try XCTUnwrap(FolyncNetDeposits(history: history))
    }

    private static func snapshot(realised: String = "1611.86", realisedCurrency: String = "GBP",
                                 realisedQuality: String = "complete") throws -> FolyncPortfolioSnapshot {
        func metric(_ value: String, currency: String = "GBP", quality: String = "complete") -> String {
            "{ \"value\": \(value), \"currency\": \"\(currency)\", \"quality\": \"\(quality)\", \"reasonCodes\": [], \"asOfDate\": \"2026-07-11\" }"
        }
        let json = """
        {
          "schemaVersion": 2, "sourceRevision": "revision-1", "generatedAt": "2026-07-12T12:00:00.000Z",
          "scope": { "id": "all", "name": "All portfolios", "kind": "aggregate", "currency": "GBP" },
          "freshness": {
            "responseGeneratedAt": "2026-07-12T12:00:00.000Z", "asOf": "2026-07-11", "status": "current", "reasonCodes": [],
            "sources": {
              "snapshots": { "asOfDate": "2026-07-11", "status": "clean", "generation": 1, "dirtySince": null, "rebuildStartedAt": null, "failedAt": null, "completedAt": "2026-07-12T11:55:00.000Z" },
              "prices": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "fx": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "provider": { "lastSuccessfulSyncAt": "2026-07-12T11:55:00.000Z", "ageSeconds": 300 }
            }
          },
          "totalValue": \(metric("84310.47")),
          "cash": \(metric("2940.18")),
          "profitLoss": {
            "unrealized": \(metric("12486.10")),
            "realized": \(metric(realised, currency: realisedCurrency, quality: realisedQuality)),
            "day": \(metric("512.36"))
          },
          "holdings": [{
            "portfolioId": "pf_demo", "assetId": "asset_demo", "ticker": "DEMO", "name": "Demo fund", "currency": "GBP",
            "shares": 100, "averageCost": 2.01, "currentPrice": 3, "previousClose": 2, "marketValue": 300, "costValue": 201,
            "dayGain": 100, "dayGainPct": 50, "totalGain": 99, "totalGainPct": 49.25, "allocationPct": 27.05,
            "valuation": \(metric("300"))
          }]
        }
        """
        return try JSONDecoder().decode(FolyncPortfolioSnapshot.self, from: Data(json.utf8))
    }
}

/// A small deterministic generator, so a failing case can be found again.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Overview: ranges, the range line, the notice, the hero figure

@MainActor
final class StockbarOverviewTextTests: XCTestCase {
    func testEverySourceGetsTheRangesItsGraphCanDraw() {
        let expected: [MenuChartTimeRange] = [.day, .week, .month, .threeMonths, .year, .all]
        for source in [PortfolioValuationSource.folyncProvided, .brokerProvided, .localCalculationFallback, .marketDataFallback] {
            XCTAssertEqual(StockbarOverviewView.offeredRanges(for: source), expected, "\(source)")
        }
        XCTAssertEqual(expected.map(\.rawValue), ["1D", "1W", "1M", "3M", "1Y", "All"], "the mock-up's order, without YTD")
        XCTAssertEqual(expected.map(\.chartTimeRange.folyncRange), ["1d", "1w", "1m", "3m", "1y", "all"],
                       "each one a range Folync's history route already serves")
        XCTAssertEqual(MenuChartTimeRange.menuRanges, [.day, .week, .month], "the menu-bar popovers keep their three")
        XCTAssertEqual(expected.map(StockbarOverviewView.rangeTitle),
                       ["1 day", "1 week", "1 month", "3 months", "1 year", "all time"])
    }

    func testAllCoversWhateverHistoryIsStoredIfItIsRecent() {
        let now = Date()
        let points = [now.addingTimeInterval(-40 * 86_400), now].map {
            MenuChartDataPoint(date: $0, price: 100, symbol: "Portfolio")
        }
        XCTAssertTrue(PortfolioMenuChartDataBuilder.coversRange(points, range: .all, now: now))
        XCTAssertFalse(PortfolioMenuChartDataBuilder.coversRange(points, range: .year, now: now))
        let old = points.map { MenuChartDataPoint(date: $0.date.addingTimeInterval(-30 * 86_400), price: 100, symbol: "Portfolio") }
        XCTAssertFalse(PortfolioMenuChartDataBuilder.coversRange(old, range: .all, now: now), "history that stopped a month ago")
    }

    func testStoredHistoryDrawsTheLongerRangesForALocalPortfolio() {
        // A local or Trading 212 portfolio draws from Stockbar's stored values (invented).
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let stored = stride(from: 400, through: 1, by: -1).map {
            ChartDataPoint(date: now.addingTimeInterval(-Double($0) * 86_400), value: 1_000 + Double(400 - $0))
        }
        for (range, days) in [(MenuChartTimeRange.threeMonths, 90.0), (.year, 365), (.all, 400)] {
            let points = PortfolioMenuChartDataBuilder.prepareChartPoints(
                storedPoints: stored, currentValue: 1_400, range: range, now: now
            )
            XCTAssertGreaterThan(points.count, 2, "\(range)")
            let first = try? XCTUnwrap(points.first)
            XCTAssertEqual(first.map { now.timeIntervalSince($0.date) / 86_400 } ?? 0, days, accuracy: 1, "\(range)")
            XCTAssertEqual(points.last?.price, 1_400, "\(range) ends at the current value")
            XCTAssertTrue(PortfolioMenuChartDataBuilder.coversRange(points, range: range, now: now), "\(range)")
            XCTAssertNotNil(PortfolioMenuChartDataBuilder.rangeChange(for: points), "\(range)")
        }
    }

    func testTheRangeLineSaysWhyItHasNoFigure() {
        func hint(_ source: PortfolioValuationSource = .folyncProvided, loading: Bool = false, unreachable: Bool = false,
                  stale: Bool = false, points: Int = 0, coverage: Bool = false) -> String {
            StockbarOverviewView.rangeChangeUnavailableHint(source: source, isLoading: loading, unreachable: unreachable,
                                                            stale: stale, pointCount: points, hasCoverage: coverage)
        }
        XCTAssertEqual(hint(stale: true, points: 40), "No current history from Folync")
        XCTAssertEqual(hint(unreachable: true), "Couldn't reach Folync")
        XCTAssertEqual(hint(loading: true, stale: true, points: 40), "Checking Folync")
        XCTAssertEqual(hint(points: 0), "Needs more stored history", "nothing for this period")
        XCTAssertEqual(hint(points: 40), "Folync marks this period partial")
        XCTAssertEqual(hint(points: 40, coverage: true), "No starting value for this period")
        XCTAssertEqual(hint(.localCalculationFallback, stale: true, points: 1), "Needs more stored history")
        XCTAssertEqual(StockbarOverviewView.unknownFigure, "–")
    }

    func testTheNoticeShowsOnlyWhileSavedFiguresStandInForFolync() throws {
        let gmt = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let british = Locale(identifier: "en_GB")
        let now = Date(timeIntervalSince1970: 1_795_000_000) // 18 Nov 2026, 11:06:40 UTC
        let earlier = now.addingTimeInterval(-3_600)
        func notice(_ state: FolyncConnectionState, snapshot: Bool = true, category: String? = "timeout",
                    savedAt: Date? = earlier) -> String? {
            StockbarOverviewView.unreachableNotice(state: state, hasSnapshot: snapshot, failureCategory: category,
                                                   savedAt: savedAt, now: now, locale: british, timeZone: gmt)
        }
        let cached = FolyncConnectionState.offlineCached(message: "The request timed out.")
        XCTAssertEqual(notice(cached), "Couldn't reach Folync. Showing the figures saved at 10:06.")
        XCTAssertEqual(notice(cached, category: "network-cannotConnectToHost"),
                       "Couldn't reach Folync. Showing the figures saved at 10:06.")
        XCTAssertEqual(notice(cached, category: "http-401"),
                       "Folync didn't send new figures. Showing the figures saved at 10:06.",
                       "an answer Stockbar could not use is not called unreachable")
        XCTAssertEqual(notice(cached, category: nil),
                       "Folync didn't send new figures. Showing the figures saved at 10:06.")
        XCTAssertEqual(notice(cached, savedAt: now.addingTimeInterval(-2 * 86_400)),
                       "Couldn't reach Folync. Showing the figures saved on 16 Nov at 11:06.")
        XCTAssertEqual(notice(cached, savedAt: nil), "Couldn't reach Folync. Showing the figures saved earlier.")

        XCTAssertNil(notice(.current(asOf: "2026-11-18")), "gone once Folync answers")
        XCTAssertNil(notice(.stale(asOf: nil, reasons: ["prices_stale"])), "Folync answered, with stale data")
        XCTAssertNil(notice(.connecting))
        XCTAssertNil(notice(cached, snapshot: false), "with nothing saved the page keeps its empty state")

        XCTAssertEqual(StockbarOverviewView.totalValueTitle(currency: "GBP", savedAt: nil), "Total value, GBP")
        XCTAssertEqual(StockbarOverviewView.totalValueTitle(currency: "GBP", savedAt: earlier, now: now,
                                                            locale: british, timeZone: gmt),
                       "Total value, GBP, as of 10:06")
        XCTAssertEqual(StockbarOverviewView.totalValueTitle(currency: "GBP", savedAt: now.addingTimeInterval(-2 * 86_400),
                                                            now: now, locale: british, timeZone: gmt),
                       "Total value, GBP, as of 16 Nov at 11:06")
    }

    func testTheHeroFigureSplitsItsDecimalsInAnyLocale() {
        XCTAssertTrue(StockbarHeroFigure.split("£84,310.47") == ("£84,310", ".47"))
        XCTAssertTrue(StockbarHeroFigure.split("1,234.50 CHF") == ("1,234", ".50 CHF"))
        XCTAssertTrue(StockbarHeroFigure.split("£84,310") == ("£84,310", ""), "no decimals, nothing to split")
        XCTAssertTrue(StockbarHeroFigure.split("-") == ("-", ""))

        // Stockbar's own amounts use a point whatever the user's locale.
        let amount = HoldingsCurrencyFormatter.amount(84_310.47, currency: "GBP")
        XCTAssertTrue(StockbarHeroFigure.split(amount) == ("£84,310", ".47"))

        // Figures written the way other locales write them split at their separator.
        for identifier in ["en_GB", "de_DE", "fr_FR", "ja_JP"] {
            let locale = Locale(identifier: identifier)
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .currency
            formatter.currencyCode = "EUR"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            let text = formatter.string(from: 84_310.47) ?? ""
            let separator = formatter.decimalSeparator ?? "."
            let parts = StockbarHeroFigure.split(text, decimalSeparator: separator)
            XCTAssertEqual(parts.whole + parts.fraction, text, identifier)
            XCTAssertTrue(parts.fraction.hasPrefix(separator + "47"), "\(identifier): \(parts)")
            XCTAssertFalse(parts.whole.contains("47"), "\(identifier): \(parts)")
        }
    }

    func testTheCompositionCardReadsAsAHeadingAndThenEachPart() throws {
        let composition = try XCTUnwrap(PortfolioTotalComposition(
            currency: "GBP",
            total: .init(value: 84_310.47, currency: "GBP"),
            netDeposits: .init(value: 68_408.36, currency: "GBP"),
            unrealised: .init(value: 12_486.10, currency: "GBP"),
            realised: .init(value: -120, currency: "GBP")
        ))
        let exposure = StockbarOverviewCompositionCard.accessibility(
            composition, returnText: "total return +£15,902.11 (+23.25%)"
        )
        XCTAssertEqual(exposure, .init(
            heading: "What £84,310.47 is made of, total return +£15,902.11 (+23.25%)",
            parts: [
                "Net deposits, £68,408.36", "Unrealised gains, £12,486.10",
                "Realised gains, minus £120.00", "Income, interest and fees, £3,536.01",
            ]
        ))
        XCTAssertEqual(StockbarOverviewCompositionCard.accessibility(composition, returnText: "").heading,
                       "What £84,310.47 is made of")
    }
}

// MARK: - Portfolio popover

@MainActor
final class PortfolioMenuPopoverTests: XCTestCase {
    private let converter = CurrencyConverter(exchangeRates: ["USD": 1.0, "GBP": 0.79], refreshOnInit: false, loadHistoryOnInit: false)

    private func holding(_ symbol: String, price: Double, previousClose: Double, units: String = "10",
                         watchlist: Bool = false, identity: String? = nil, label: String? = nil) -> RealTimeTrade {
        var info = TradingInfo()
        info.currentPrice = price
        info.prevClosePrice = previousClose
        info.currency = "USD"
        let trade = Trade(name: symbol, position: Position(unitSize: units, positionAvgCost: "100", currency: "USD"),
                          isWatchlistOnly: watchlist)
        return RealTimeTrade(trade: trade, realTimeInfo: info, sourceIdentity: identity, displayLabel: label)
    }

    private func mover(_ symbol: String, _ percent: Double?) -> PortfolioMenuMover {
        PortfolioMenuMover(id: symbol, symbol: symbol, percent: percent)
    }

    private func movers(count: Int) -> [PortfolioMenuMover] {
        (0..<count).map { mover(String(format: "S%02d", $0), Double($0 % 7) - 3) }
    }

    func testMoversRunFromTheBiggestGainToTheBiggestLossWithUnknownChangesLast() {
        let ordered = PortfolioMenuMovers.ordered([
            mover("SHEL", -0.64), mover("ZZZ", nil), mover("NVDA", 2.69), mover("AAA", nil),
            mover("MSFT", 0.31), mover("HSBA", 0.31), mover("ULVR", -0.22), mover("AZN", .nan)
        ])
        XCTAssertEqual(ordered.map(\.symbol), ["NVDA", "HSBA", "MSFT", "ULVR", "SHEL", "AAA", "AZN", "ZZZ"],
                       "equal moves and unknown ones keep a stable order by symbol")
        // Moves that show the same at two decimals are a tie, ordered by symbol.
        XCTAssertEqual(PortfolioMenuMovers.ordered([mover("B", 0.3101), mover("A", 0.3099)]).map(\.symbol), ["A", "B"])
    }

    func testMoversTakeTheAppsOwnFigureForAPositionsDayAndListOnlyHoldings() {
        let service = PortfolioCalculationService(currencyConverter: converter)
        let benchmark = SymbolMetadata.benchmarkSymbols.sorted().first ?? "^GSPC"
        let trades = [
            holding("AAPL", price: 101, previousClose: 100),
            holding("MSFT", price: 99, previousClose: 100, label: "Microsoft"),
            holding("WATCH", price: 120, previousClose: 100, watchlist: true),
            holding(benchmark, price: 120, previousClose: 100),
            holding("SOLD", price: 120, previousClose: 100, units: "0"),
            holding("NOQUOTE", price: .nan, previousClose: 100),
            holding("DUP", price: 102, previousClose: 100, identity: "folync-1"),
            holding("DUP", price: 102, previousClose: 100, identity: "folync-1")
        ]
        let movers = PortfolioMenuMovers.movers(from: trades) { service.calculatePositionProfitLoss(for: $0).dayPercent }

        XCTAssertEqual(movers.map(\.symbol), ["DUP", "AAPL", "Microsoft", "NOQUOTE"],
                       "watch-list symbols, benchmarks and empty positions are not holdings; a holding is listed once")
        XCTAssertEqual(movers[1].percent ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(movers[2].percent ?? .nan, -1, accuracy: 1e-9)
        XCTAssertNil(movers[3].percent, "a change the app cannot work out is unknown, not zero")
        XCTAssertEqual(PortfolioMenuMovers.percentText(movers[3]), "–")
        XCTAssertTrue(PortfolioMenuMovers.movers(from: []) { _ in 0 }.isEmpty, "an empty portfolio has no rows")
    }

    func testMoversShowTheTickerAloneUnlessTwoHoldingsWouldReadTheSame() {
        let service = PortfolioCalculationService(currencyConverter: converter)
        let trades = [
            holding("NVDA", price: 103, previousClose: 100, identity: "folync-nvda", label: "NVDA · Demo portfolio"),
            holding("AAPL", price: 102, previousClose: 100, identity: "folync-aapl", label: "AAPL · Demo portfolio"),
            holding("VUSA", price: 101, previousClose: 100, identity: "folync-vusa-1", label: "VUSA · First portfolio"),
            holding("VUSA", price: 101, previousClose: 100, identity: "folync-vusa-2", label: "VUSA · Second portfolio"),
            holding("MSFT", price: 99, previousClose: 100, label: "Microsoft")
        ]
        let movers = PortfolioMenuMovers.movers(from: trades) { service.calculatePositionProfitLoss(for: $0).dayPercent }

        XCTAssertEqual(movers.map(\.symbol),
                       ["NVDA", "AAPL", "VUSA · First portfolio", "VUSA · Second portfolio", "Microsoft"],
                       "a row shows the ticker, and the portfolio only where two rows would otherwise read the same")
        XCTAssertEqual(PortfolioMenuMovers.ticker(of: " · Demo portfolio"), " · Demo portfolio", "never an empty name")
    }

    func testTheBarScaleIsTheLargestMoveRoundedUpToAWholePercentWithAFloorOfOne() {
        XCTAssertEqual(PortfolioMenuMovers.scale(for: [mover("A", 2.69), mover("B", -0.64)]), 3)
        XCTAssertEqual(PortfolioMenuMovers.scale(for: [mover("A", 0.5), mover("B", -3.0)]), 3, "a loss sets the scale too")
        XCTAssertEqual(PortfolioMenuMovers.scale(for: [mover("A", 0.12)]), 1)
        XCTAssertEqual(PortfolioMenuMovers.scale(for: [mover("A", nil)]), 1)
        XCTAssertEqual(PortfolioMenuMovers.scale(for: []), 1)
        XCTAssertEqual(PortfolioMenuMovers.scaleText(3), "± 3%")

        XCTAssertEqual(PortfolioMenuMovers.barFraction(mover("A", 1.5), scale: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PortfolioMenuMovers.barFraction(mover("A", -9), scale: 3), 1, "a bar never runs past its track")
        XCTAssertEqual(PortfolioMenuMovers.barFraction(mover("A", nil), scale: 3), 0)
        XCTAssertEqual(PortfolioMenuMovers.barFraction(mover("A", 0.001), scale: 3), 0, "a move that shows as 0.00% has no bar")
    }

    func testTheListScrollsPastTwelveRowsAndShowsFewerOnAShortScreen() {
        XCTAssertEqual([1, 12, 13, 40].map { PortfolioMenuMovers.shownRows(count: $0) }, [1, 12, 12, 12])
        XCTAssertEqual([1, 12, 13, 40].map { PortfolioMenuMovers.scrolls(count: $0) }, [false, false, true, true])
        XCTAssertEqual(PortfolioMenuMovers.listHeight(count: 40), 12 * PortfolioMenuMovers.rowHeight)

        // Room for five rows: the list shows five and scrolls.
        let fiveRows = PortfolioMenuMovers.rowHeight * 5 + 3
        XCTAssertEqual(PortfolioMenuMovers.shownRows(count: 40, availableHeight: fiveRows), 5)
        XCTAssertTrue(PortfolioMenuMovers.scrolls(count: 12, availableHeight: fiveRows))
        XCTAssertFalse(PortfolioMenuMovers.scrolls(count: 4, availableHeight: fiveRows))
        // Almost no room: never fewer than three rows, or than there are holdings.
        XCTAssertEqual(PortfolioMenuMovers.shownRows(count: 40, availableHeight: 10), PortfolioMenuMovers.minimumRows)
        XCTAssertEqual(PortfolioMenuMovers.shownRows(count: 2, availableHeight: 10), 2)

        // The popover's limit comes from the room under the menu bar.
        XCTAssertEqual(PortfolioMenuPopoverHeight.maximum(visibleHeight: 800), 800 - PortfolioMenuPopoverHeight.arrowAndMargin)
        XCTAssertNil(PortfolioMenuPopoverHeight.maximum(visibleHeight: nil))
    }

    func testTheHostedListIsOnlyAsTallAsTheRowsItShows() {
        func height(_ count: Int, room: CGFloat? = nil) -> CGFloat {
            let host = NSHostingView(rootView: PortfolioMenuMoversList(movers: movers(count: count), availableHeight: room)
                .frame(width: 308))
            return host.fittingSize.height
        }
        let one = height(1), twelve = height(12), thirteen = height(13), forty = height(40)
        XCTAssertEqual(twelve - one, 11 * PortfolioMenuMovers.rowHeight, accuracy: 1)
        XCTAssertEqual(thirteen, twelve, accuracy: 1, "from the thirteenth holding the list scrolls instead of growing")
        XCTAssertEqual(forty, twelve, accuracy: 1)
        XCTAssertEqual(twelve - height(40, room: PortfolioMenuMovers.rowHeight * 4), 8 * PortfolioMenuMovers.rowHeight, accuracy: 1,
                       "on a short screen the list gives up rows, not the popover's height limit")
        XCTAssertLessThan(height(0), one, "with no holdings one quiet line replaces the rows")
    }

    func testTheHeadingSaysTodaysMoversAtEveryRange() {
        let every: [MenuChartTimeRange] = [.day, .week, .month, .threeMonths, .year, .all]
        XCTAssertEqual(every.map(PortfolioMenuMovers.heading(for:)),
                       Array(repeating: "Today's movers", count: every.count))
        // The popover offers the three menu ranges; the longer ones are the Overview's.
        XCTAssertEqual(MenuChartTimeRange.menuRanges.map(PortfolioMenuFigures.rangeTitle), ["Today", "1 week", "1 month"])
    }

    func testADownDayReadsAsLossesInOrderAndAFallInTheHeadline() {
        let ordered = PortfolioMenuMovers.ordered([mover("NVDA", -1.84), mover("LGEN", 0.62), mover("AZN", -0.31)])
        XCTAssertEqual(ordered.map(\.symbol), ["LGEN", "AZN", "NVDA"])
        XCTAssertEqual(PortfolioMenuMovers.percentText(ordered[2], locale: Locale(identifier: "en_GB")), "▼ 1.84%")
        XCTAssertEqual(PortfolioMenuMovers.percentText(ordered[0], locale: Locale(identifier: "en_GB")), "▲ 0.62%")

        let summary = DisplayPortfolioSummary(totalValue: 83_824.27, totalGain: 15_415.91, totalGainPct: 22.5,
                                              dayGain: -486.20, dayGainPct: -0.58, totalCost: 68_408.36,
                                              ownedPositionCount: 9, currency: "GBP")
        let figures = PortfolioMenuFigures(summary: summary, change: PortfolioMenuRangeChange(value: -486.20, percent: -0.58),
                                           range: .day, basis: .holdingsCost)
        XCTAssertEqual(figures.changeSign, -1)
        XCTAssertEqual(figures.changeAmount, "▼ £486.20")
        XCTAssertEqual(figures.changePercent, MenuPopoverFormatter.percent(-0.58))
        XCTAssertEqual(figures.changeWord, "today")
        XCTAssertEqual(PortfolioMenuFigures.yesterdaysClose(summary: summary, range: .day) ?? .nan, 84_310.47, accuracy: 0.001)
        XCTAssertNil(PortfolioMenuFigures.yesterdaysClose(summary: summary, range: .week), "the dotted line is only on Today")
    }

    func testEachRowReadsAsOneSentence() {
        XCTAssertEqual(PortfolioMenuMovers.accessibilityText(mover("NVDA", 2.6899)), "NVDA, up 2.69 percent today")
        XCTAssertEqual(PortfolioMenuMovers.accessibilityText(mover("SHEL", -0.64)), "SHEL, down 0.64 percent today")
        XCTAssertEqual(PortfolioMenuMovers.accessibilityText(mover("AZN", 0.004)), "AZN, no change today")
        XCTAssertEqual(PortfolioMenuMovers.accessibilityText(mover("ULVR", nil)), "ULVR, change unknown")
        XCTAssertEqual(PortfolioMenuMovers.percentText(mover("AZN", -0.004), locale: Locale(identifier: "en_GB")), "0.00%",
                       "a move that rounds to nothing has no arrow")
    }

    func testTheFiguresAreInThePortfoliosCurrency() {
        let summary = DisplayPortfolioSummary(totalValue: 84_310.47, totalGain: 15_902.11, totalGainPct: 23.2,
                                              dayGain: 512.36, dayGainPct: 0.61, totalCost: 68_408.36,
                                              ownedPositionCount: 9, currency: "GBP", valuationSource: .folyncProvided,
                                              netDeposits: 68_408.36)
        let change = PortfolioMenuRangeChange(value: 512.36, percent: 0.61)
        let figures = PortfolioMenuFigures(summary: summary, change: change, range: .day, basis: .netDeposits)
        XCTAssertEqual(figures.header, "GBP, 9 positions")
        XCTAssertEqual(figures.total, "£84,310.47")
        XCTAssertEqual(StockbarSplitFigure.split(figures.total).whole, "£84,310")
        XCTAssertEqual(StockbarSplitFigure.split(figures.total).fraction, ".47")
        XCTAssertEqual(StockbarSplitFigure.split("-").whole, "-", "a missing figure is not split")
        XCTAssertEqual(figures.changeAmount, "▲ £512.36")
        XCTAssertEqual(figures.totalReturn, "+£15,902.11")
        XCTAssertEqual(figures.totalReturnSign, 1)
        XCTAssertEqual(figures.basisLabel, "Net deposits")
        XCTAssertEqual(figures.basis, "£68,408.36")

        let inEuros = DisplayPortfolioSummary(totalValue: 1_200, totalGain: -50, totalGainPct: -4, dayGain: 0, dayGainPct: 0,
                                              totalCost: 1_250, ownedPositionCount: 1, currency: "EUR")
        let euroFigures = PortfolioMenuFigures(summary: inEuros, change: nil, range: .week, basis: .netDeposits)
        XCTAssertEqual(euroFigures.header, "EUR, 1 position")
        XCTAssertEqual(euroFigures.total, "€1,200.00")
        XCTAssertEqual(euroFigures.totalReturn, "-€50.00")
        XCTAssertEqual(euroFigures.basisLabel, "Cost basis", "without net deposits the return is measured against cost")
        XCTAssertEqual(euroFigures.basis, "€1,250.00")
        XCTAssertNil(euroFigures.changeSign, "an unknown change is neither a gain nor a loss")
        XCTAssertEqual(euroFigures.changeAmount, "–")
        XCTAssertEqual(euroFigures.changeWord, "past week")
        XCTAssertNil(PortfolioMenuFigures.yesterdaysClose(summary: inEuros, range: .day),
                     "no dotted line where the day's change is not known")
    }

    func testIncreaseContrastStrengthensThePopoversText() {
        XCTAssertFalse(StockbarPopoverText.resolve(accessibility: .init()).secondaryIsPrimary)
        XCTAssertTrue(StockbarPopoverText.resolve(accessibility: .init(increasedContrast: true)).secondaryIsPrimary)
        XCTAssertFalse(StockbarPopoverText.resolve(accessibility: .init(reduceTransparency: true)).secondaryIsPrimary)
    }

    func testIncreaseContrastReachesTheViewsUnderThePopoversRoot() {
        func seen(_ accessibility: StockbarSurfaceAccessibility?) -> StockbarPopoverText? {
            let box = PopoverTextSeen()
            let host = NSHostingView(rootView: PopoverTextProbe(seen: box)
                .stockbarPopoverText()
                .environment(\.stockbarSurfaceAccessibilityOverride, accessibility))
            host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            host.layoutSubtreeIfNeeded()
            return box.value
        }
        XCTAssertEqual(seen(.init(increasedContrast: true))?.secondaryIsPrimary, true)
        XCTAssertEqual(seen(.init())?.secondaryIsPrimary, false)
    }

    func testTheWholePopoverStaysWithinTheRoomTheScreenLeaves() {
        let model = DataModel(currencyConverter: converter, startRuntimeServices: false)
        model.realTimeTrades = (0..<40).map { holding(String(format: "T%02d", $0), price: 100 + Double($0 % 7), previousClose: 101) }
        func fittingHeight(_ limit: CGFloat?) -> CGFloat {
            let host = NSHostingView(rootView: PortfolioMenuPopoverView(dataModel: model, actions: .noop, maximumHeight: limit))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            // The popover measures what is not the list, then gives the list the rest.
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.frame.size = host.fittingSize
            }
            return host.fittingSize.height
        }
        let unbounded = fittingHeight(nil)
        let limit = unbounded - 6 * PortfolioMenuMovers.rowHeight
        let bounded = fittingHeight(limit)
        XCTAssertLessThanOrEqual(bounded, limit + 1, "the popover is never taller than the room it is given")
        XCTAssertGreaterThan(bounded, limit - 2 * PortfolioMenuMovers.rowHeight, "it gives up only the rows it must")
    }
}

@MainActor
private final class PopoverTextSeen {
    var value: StockbarPopoverText?
}

private struct PopoverTextProbe: View {
    let seen: PopoverTextSeen
    @Environment(\.stockbarPopoverText) private var style

    var body: some View {
        let _ = { seen.value = style }()
        Color.clear
    }
}

// MARK: - Holdings: weight, the Amounts/Percent switch, the strip and the line under the table

@MainActor
final class HoldingsWeightAndTextTests: XCTestCase {
    private let converter = CurrencyConverter(exchangeRates: ["USD": 1.0, "GBP": 0.8], refreshOnInit: false, loadHistoryOnInit: false)

    private func trade(_ symbol: String, price: Double, units: String, currency: String?,
                       watchlist: Bool = false, identity: String? = nil) -> RealTimeTrade {
        var info = TradingInfo()
        info.currentPrice = price
        info.prevClosePrice = price
        info.currency = currency
        let position = Position(unitSize: units, positionAvgCost: "1", currency: currency)
        return RealTimeTrade(trade: Trade(name: symbol, position: position, isWatchlistOnly: watchlist),
                             realTimeInfo: info, sourceIdentity: identity)
    }

    private func localModel(_ trades: [RealTimeTrade], currency: String = "GBP") -> DataModel {
        let model = DataModel(currencyConverter: converter, startRuntimeServices: false)
        let stored = StockbarRuntimeStorage.userDefaults.object(forKey: "preferredCurrency")
        addTeardownBlock { @MainActor in StockbarRuntimeStorage.userDefaults.set(stored, forKey: "preferredCurrency") }
        model.preferredCurrency = currency
        model.realTimeTrades = trades
        return model
    }

    /// Two invented Folync holdings: one with a weight, one without. Folync's
    /// weights are deliberately not the holdings' share of `totalValue`, so a
    /// weight worked out from values would not match.
    private func folyncSnapshot() throws -> FolyncPortfolioSnapshot {
        func metric(_ value: String) -> String {
            "{ \"value\": \(value), \"currency\": \"GBP\", \"quality\": \"complete\", \"reasonCodes\": [], \"asOfDate\": \"2026-07-11\" }"
        }
        func holding(_ asset: String, value: Int, allocation: String) -> String {
            """
            { "portfolioId": "pf_demo", "assetId": "\(asset)", "ticker": "\(asset.uppercased())", "name": "Fund \(asset)",
              "currency": "GBP", "shares": 10, "averageCost": 1, "currentPrice": \(value / 10), "previousClose": 1,
              "marketValue": \(value), "costValue": 10, "dayGain": 1, "dayGainPct": 1, "totalGain": 1, "totalGainPct": 1,
              "allocationPct": \(allocation), "valuation": \(metric("\(value)")) }
            """
        }
        let json = """
        {
          "schemaVersion": 2, "sourceRevision": "revision-1", "generatedAt": "2026-07-12T12:00:00.000Z",
          "scope": { "id": "all", "name": "All portfolios", "kind": "aggregate", "currency": "GBP" },
          "freshness": {
            "responseGeneratedAt": "2026-07-12T12:00:00.000Z", "asOf": "2026-07-11", "status": "current", "reasonCodes": [],
            "sources": {
              "snapshots": { "asOfDate": "2026-07-11", "status": "clean", "generation": 1, "dirtySince": null, "rebuildStartedAt": null, "failedAt": null, "completedAt": "2026-07-12T11:55:00.000Z" },
              "prices": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "fx": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "provider": { "lastSuccessfulSyncAt": "2026-07-12T11:55:00.000Z", "ageSeconds": 300 }
            }
          },
          "totalValue": \(metric("1000")),
          "cash": \(metric("100")),
          "profitLoss": { "unrealized": \(metric("12.5")), "realized": \(metric("0")), "day": \(metric("2")) },
          "holdings": [\(holding("a", value: 600, allocation: "25.5")), \(holding("b", value: 300, allocation: "null"))]
        }
        """
        return try JSONDecoder().decode(FolyncPortfolioSnapshot.self, from: Data(json.utf8))
    }

    // MARK: Weight

    func testAFolyncHoldingsWeightIsFolyncsFigureAsGivenAndDashWhenFolyncGivesNone() throws {
        let model = DataModel(currencyConverter: converter, startRuntimeServices: false)
        let given = trade("A", price: 60, units: "10", currency: "GBP", identity: "all|pf_demo|a")
        let missing = trade("B", price: 30, units: "10", currency: "GBP", identity: "all|pf_demo|b")
        let unmatched = trade("C", price: 30, units: "10", currency: "GBP", identity: "all|pf_demo|nowhere")
        let watch = trade("W", price: 5, units: "0", currency: "GBP", watchlist: true, identity: "all|pf_demo|a")
        model.realTimeTrades = [given, missing, unmatched, watch]
        model.folyncPortfolioSnapshot = try folyncSnapshot()
        let total = model.calculateNetValue()
        XCTAssertEqual(total.amount, 1000)

        let weight = model.calculatePositionWeight(for: given, netValue: total)
        XCTAssertEqual(weight, 25.5, "Folync's own figure, not 600 of 1,000")
        XCTAssertEqual(HoldingsWeight.text(weight), "25.5%")
        XCTAssertNil(model.calculatePositionWeight(for: missing, netValue: total), "never worked out from values")
        XCTAssertEqual(HoldingsWeight.text(model.calculatePositionWeight(for: missing, netValue: total)), "–")
        XCTAssertNil(model.calculatePositionWeight(for: unmatched, netValue: total))
        XCTAssertNil(model.calculatePositionWeight(for: watch, netValue: total), "a watchlist row has no weight")
        XCTAssertNil(HoldingsWeight.given(.nan))
        XCTAssertNil(HoldingsWeight.given(.infinity))
    }

    func testALocalHoldingsWeightIsItsShareOfTheNetValueInTheDisplayCurrency() {
        // $1,000 is £800 at 0.8; £200 more makes a net value of £1,000.
        let dollars = trade("USA", price: 100, units: "10", currency: "USD")
        let pounds = trade("GBR", price: 50, units: "4", currency: "GBP")
        let unpriced = trade("NOPRICE", price: 0, units: "10", currency: "GBP")
        let noCurrency = trade("NOCCY", price: 10, units: "1", currency: nil)
        let watch = trade("WATCH", price: 10, units: "5", currency: "GBP", watchlist: true)
        let model = localModel([dollars, pounds, unpriced, watch])
        let total = model.calculateNetValue()
        XCTAssertEqual(total.currency, "GBP")
        XCTAssertEqual(total.amount, 1000, accuracy: 0.000_1)

        XCTAssertEqual(model.calculatePositionWeight(for: dollars, netValue: total) ?? .nan, 80, accuracy: 0.000_1)
        XCTAssertEqual(model.calculatePositionWeight(for: pounds, netValue: total) ?? .nan, 20, accuracy: 0.000_1)
        XCTAssertEqual(HoldingsWeight.text(model.calculatePositionWeight(for: dollars, netValue: total)), "80.0%")
        XCTAssertNil(model.calculatePositionWeight(for: unpriced, netValue: total), "a value that is not known")
        XCTAssertNil(model.calculatePositionWeight(for: noCurrency, netValue: total), "no currency is not taken as dollars")
        XCTAssertNil(model.calculatePositionWeight(for: watch, netValue: total), "a watchlist row has no weight")
        XCTAssertNil(model.calculatePositionWeight(for: pounds, netValue: (0, "GBP")), "a total of zero")
        XCTAssertNil(model.calculatePositionWeight(for: pounds, netValue: (-5, "GBP")), "a total below zero")
        XCTAssertNil(model.calculatePositionWeight(for: pounds, netValue: (.nan, "GBP")), "a total that is not known")
    }

    func testAShareNeedsBothValuesBothCurrenciesAndARate() {
        let halve: (Double, String, String) -> Double = { amount, _, _ in amount / 2 }
        XCTAssertEqual(HoldingsWeight.share(value: 50, currency: "GBP", of: 200, currency: "GBP", convert: halve), 25,
                       "the same currency is not converted")
        XCTAssertEqual(HoldingsWeight.share(value: 50, currency: "USD", of: 200, currency: "GBP", convert: halve), 12.5)
        XCTAssertEqual(HoldingsWeight.share(value: 0, currency: "GBP", of: 200, currency: "GBP", convert: halve), 0)
        XCTAssertNil(HoldingsWeight.share(value: 50, currency: "XYZ", of: 200, currency: "GBP", convert: { _, _, _ in .nan }),
                     "no exchange rate")
        XCTAssertNil(HoldingsWeight.share(value: 50, currency: " ", of: 200, currency: "GBP", convert: halve))
        XCTAssertNil(HoldingsWeight.share(value: 50, currency: "GBP", of: 200, currency: "", convert: halve))
        XCTAssertNil(HoldingsWeight.share(value: .nan, currency: "GBP", of: 200, currency: "GBP", convert: halve))
        XCTAssertNil(HoldingsWeight.share(value: -1, currency: "GBP", of: 200, currency: "GBP", convert: halve))
        XCTAssertNil(HoldingsWeight.share(value: 50, currency: "GBP", of: 0, currency: "GBP", convert: halve))
        // Pence go through the converter, which divides them once.
        let model = DataModel(currencyConverter: converter, startRuntimeServices: false)
        XCTAssertEqual(HoldingsWeight.share(value: 5_000, currency: "GBX", of: 200, currency: "GBP",
                                            convert: model.currencyConverter.convert(amount:from:to:)) ?? .nan,
                       25, accuracy: 0.000_1)
    }

    func testWeightTextAndSortOrder() {
        XCTAssertEqual(HoldingsWeight.text(25.4567), "25.5%")
        XCTAssertEqual(HoldingsWeight.text(0), "0.0%")
        XCTAssertEqual(HoldingsWeight.text(100), "100.0%")
        XCTAssertEqual(HoldingsWeight.text(nil), "–")
        XCTAssertEqual(HoldingsWeight.text(.nan), "–")

        let rows = [("MID", 9.6 as Double?), ("NONE", nil), ("BIG", 25.5), ("SMALL", 4.8)].map { symbol, weight in
            HoldingsTableRow(trade: trade(symbol, price: 1, units: "1", currency: "GBP"), weight: weight)
        }
        let descending = rows.sorted(using: [KeyPathComparator(\HoldingsTableRow.weightSortKey, order: .reverse)])
        XCTAssertEqual(descending.map(\.trade.trade.name), ["BIG", "MID", "SMALL", "NONE"], "unknown weights last")
        let ascending = rows.sorted(using: [KeyPathComparator(\HoldingsTableRow.weightSortKey)])
        XCTAssertEqual(ascending.map(\.trade.trade.name), ["NONE", "SMALL", "MID", "BIG"])
    }

    // MARK: The Amounts/Percent switch

    func testTheSwitchIsOneRememberedChoiceForBothColumns() throws {
        XCTAssertEqual(HoldingsGainDisplayMode.allCases.map(\.title), ["Amounts", "Percent"])
        XCTAssertEqual(HoldingsGainDisplayMode.defaultValue, .amounts)
        let suiteName = "HoldingsWeightAndTextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(HoldingsGainDisplayMode.stored(in: defaults), .amounts, "amounts until chosen otherwise")
        defaults.set(HoldingsGainDisplayMode.percent.rawValue, forKey: HoldingsGainDisplayMode.storageKey)
        XCTAssertEqual(HoldingsGainDisplayMode.stored(in: defaults), .percent)
        defaults.set("sideways", forKey: HoldingsGainDisplayMode.storageKey)
        XCTAssertEqual(HoldingsGainDisplayMode.stored(in: defaults), .amounts, "an unreadable value is not a choice")
        XCTAssertEqual(HoldingsGainDisplayMode.storageKey, "holdings.gainDisplayMode")

        // Both columns are worded by the same function from the same choice.
        XCTAssertEqual(HoldingsText.gain(amount: 89.84, percent: 0.42, currency: "GBP", mode: .amounts), "+£89.84")
        XCTAssertEqual(HoldingsText.gain(amount: 89.84, percent: 0.42, currency: "GBP", mode: .percent), "+0.42%")
        XCTAssertEqual(HoldingsText.gain(amount: -64.1, percent: -1.234, currency: "GBP", mode: .amounts), "-£64.10")
        XCTAssertEqual(HoldingsText.gain(amount: -64.1, percent: -1.234, currency: "GBP", mode: .percent), "-1.23%")
        XCTAssertEqual(HoldingsText.gain(amount: .nan, percent: 1, currency: "GBP", mode: .amounts), "–")
        XCTAssertEqual(HoldingsText.gain(amount: 1, percent: .nan, currency: "GBP", mode: .percent), "–")
        XCTAssertNil(SettingsTransferKeys.settingsKeys[HoldingsGainDisplayMode.storageKey],
                     "a view choice, like the selected section, is not exported")
    }

    func testTheSwitchIsReadAsOneLabelledGroupOfTwoButtons() {
        let exposure = StockbarSegmentedControl<HoldingsGainDisplayMode>.accessibility(
            label: "Show gains as", options: HoldingsGainDisplayMode.allCases, selection: .percent, title: \.title
        )
        XCTAssertEqual(exposure.label, "Show gains as")
        XCTAssertEqual(exposure.segments.map(\.label), ["Amounts", "Percent"])
        XCTAssertEqual(exposure.segments.map(\.isSelected), [false, true])
    }

    // MARK: The strip

    func testTheStripsSecondLinesSayWhatEachTotalIs() {
        XCTAssertEqual(HoldingsText.netValueDetail(currency: "GBP", usdAmount: 111_080.99), "$111,080.99 in US dollars")
        XCTAssertNil(HoldingsText.netValueDetail(currency: "USD", usdAmount: 100), "no second line in dollars")
        XCTAssertNil(HoldingsText.netValueDetail(currency: "GBP", usdAmount: nil), "no rate, no second line")
        XCTAssertNil(HoldingsText.netValueDetail(currency: "GBP", usdAmount: .nan))

        XCTAssertEqual(HoldingsText.gainsDetail(source: .folync, currency: "GBP", usdAmount: 16_450.72),
                       "Unrealised, as Folync reports it. +$16,450.72 in US dollars")
        XCTAssertEqual(HoldingsText.gainsDetail(source: .trading212, currency: "EUR", usdAmount: -12),
                       "Unrealised, as Trading 212 reports it. -$12.00 in US dollars")
        XCTAssertEqual(HoldingsText.gainsDetail(source: .averageCost, currency: "USD", usdAmount: 5),
                       "Unrealised, against average cost")
        XCTAssertEqual(HoldingsText.gainsDetail(source: .averageCost, currency: "GBP", usdAmount: nil),
                       "Unrealised, against average cost")
    }

    func testTheGainsSourceFollowsTheFigureTheStripShows() throws {
        let model = localModel([trade("GBR", price: 50, units: "4", currency: "GBP")])
        XCTAssertEqual(model.netGainsSource, .averageCost, "a local portfolio: Stockbar's own sum")
        model.folyncPortfolioSnapshot = try folyncSnapshot()
        XCTAssertEqual(model.netGainsSource, .folync)
        XCTAssertEqual(model.calculateNetGains().amount, 12.5, "the figure the caption describes")
    }

    // MARK: The line under the table

    func testTheLineUnderTheTableCountsHoldingsAndWatchlistSymbols() {
        XCTAssertEqual(HoldingsText.footer(held: 9, watchlist: 2, weightIsFolyncs: true),
                       "9 holdings and 2 watchlist symbols. Weight is Folync's figure.")
        XCTAssertEqual(HoldingsText.footer(held: 1, watchlist: 1, weightIsFolyncs: false),
                       "1 holding and 1 watchlist symbol. Weight is each holding's value as a share of the net value.")
        XCTAssertEqual(HoldingsText.footer(held: 9, watchlist: 0, weightIsFolyncs: true),
                       "9 holdings. Weight is Folync's figure.")
        XCTAssertEqual(HoldingsText.footer(held: 3, watchlist: 0, weightIsFolyncs: nil), "3 holdings.",
                       "the editing table has no Weight column")
        XCTAssertEqual(HoldingsText.footer(held: 0, watchlist: 2, weightIsFolyncs: nil), "No holdings and 2 watchlist symbols.")
        XCTAssertNil(HoldingsText.footer(held: 0, watchlist: 0, weightIsFolyncs: true))
    }

    // MARK: VoiceOver

    func testARowReadsAsOneSentenceInEitherMode() {
        func sentence(_ mode: HoldingsGainDisplayMode, weight: Double? = 25.5) -> String {
            HoldingsText.rowSentence(HoldingsText.RowFigures(
                symbol: "VUSA", name: "Vanguard fund", isWatchlist: false, price: "£84.12", value: "£21,480.60",
                weight: weight,
                today: HoldingsText.gain(amount: 89.84, percent: 0.42, currency: "GBP", mode: mode), todaySign: 89.84,
                totalGain: HoldingsText.gain(amount: -64.1, percent: -2.5, currency: "GBP", mode: mode), totalSign: -64.1
            ))
        }
        XCTAssertEqual(sentence(.amounts),
                       "VUSA, Vanguard fund, price £84.12, value £21,480.60, weight 25.5%, today a gain of +£89.84, total gain a loss of -£64.10.")
        XCTAssertEqual(sentence(.percent),
                       "VUSA, Vanguard fund, price £84.12, value £21,480.60, weight 25.5%, today a gain of +0.42%, total gain a loss of -2.50%.")
        XCTAssertEqual(sentence(.amounts, weight: nil),
                       "VUSA, Vanguard fund, price £84.12, value £21,480.60, weight not known, today a gain of +£89.84, total gain a loss of -£64.10.")
        XCTAssertEqual(HoldingsText.rowSentence(HoldingsText.RowFigures(symbol: "TSLA", name: "TSLA", isWatchlist: true, price: "$338.20", value: "–",
                                                weight: nil, today: "–", todaySign: 0, totalGain: "–", totalSign: 0)),
                       "TSLA, watchlist only, price $338.20.")
        XCTAssertEqual(HoldingsText.rowSentence(HoldingsText.RowFigures(symbol: "NEW", name: "", isWatchlist: false, price: "-", value: "-",
                                                weight: nil, today: "–", todaySign: 0, totalGain: "–", totalSign: 0)),
                       "NEW, price not known, value not known, weight not known, today not known, total gain not known.")
        XCTAssertEqual(HoldingsText.rowSentence(HoldingsText.RowFigures(symbol: "FLAT", name: nil, isWatchlist: false, price: "£1.00", value: "£10.00",
                                                weight: 1, today: "£0.00", todaySign: 0, totalGain: "+0.00%", totalSign: 0)),
                       "FLAT, price £1.00, value £10.00, weight 1.0%, today unchanged at £0.00, total gain unchanged at +0.00%.")
    }

    // MARK: Layout

    func testTheEditingTableKeepsItsColumnWidths() {
        // The editing layout is not changed by the Weight column: its fields
        // keep their widths, and the table scrolls sideways where it is wider
        // than its card.
        XCTAssertEqual(HoldingsTableLayout.symbolWidth, 130)
        XCTAssertEqual(HoldingsTableLayout.unitsWidth, 110)
        XCTAssertEqual(HoldingsTableLayout.averageCostWidth, 110)
        XCTAssertEqual(HoldingsTableLayout.currencyWidth, 100)
        XCTAssertEqual(HoldingsTableLayout.contentWidth, 969)
    }
}
