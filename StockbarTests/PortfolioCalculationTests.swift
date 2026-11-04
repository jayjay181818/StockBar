import Combine
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
        MainActor.assumeIsolated {
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
    }

    nonisolated override func tearDown() {
        MainActor.assumeIsolated {
            trades.removeAll()
            trades = nil
            service = nil
            currencyConverter = nil
        }
        super.tearDown()
    }

    // MARK: - Net Gains Calculation Tests

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

        XCTAssertEqual(summary.dayAmount, 1500.0, accuracy: 0.01)
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
        let snapshots = [
            HistoricalPortfolioSnapshot(date: now.addingTimeInterval(-7200), totalValue: 214981,
                totalGains: 0, totalCost: 0, currency: "USD", portfolioComposition: [:]),
            HistoricalPortfolioSnapshot(date: now.addingTimeInterval(-3600), totalValue: 165525,
                totalGains: 0, totalCost: 0, currency: "GBP", portfolioComposition: [:]),
            HistoricalPortfolioSnapshot(date: now, totalValue: 165525,
                totalGains: 0, totalCost: 0, currency: "GBP", portfolioComposition: [:])
        ]
        let stored = PortfolioMenuChartDataBuilder.matchingCurrencyPoints(snapshots, currency: "GBP")
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
                price: coveredSubtotal,
                previousClose: coveredSubtotal,
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
            syntheticPoints.contains { abs($0.value - coveredSubtotal) < 0.0001 },
            "The fixture must reproduce the misleading partial synthetic subtotal"
        )
        XCTAssertTrue(
            authoritativePoints.contains { abs($0.value - fullPortfolioValue) < 0.0001 },
            "Folync-authoritative charts must retain full portfolio samples"
        )
        XCTAssertFalse(
            authoritativePoints.contains { abs($0.value - coveredSubtotal) < 0.0001 },
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

        let suiteName = "StockbarTests.MenuChartRange.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
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

        manager.priceSnapshots[symbol] = []
        XCTAssertEqual(
            manager.getPriceSnapshots(for: symbol, from: windowStart, to: now).map(\.price),
            [404]
        )
    }
    @MainActor
    func testSymbolChartLoadsOnceOnPresentationAndCoalescesRangeAndPriceChanges() async {
        let suite = "StockbarTests.ChartLoads.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
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
        let suite = "StockbarTests.ChartVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
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
