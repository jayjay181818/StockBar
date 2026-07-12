import XCTest
@testable import Stockbar

class PortfolioCalculationTests: XCTestCase {

    var trades: [RealTimeTrade]!
    var currencyConverter: CurrencyConverter!
    var service: PortfolioCalculationService!

    override func setUp() {
        super.setUp()

        // Set up mock currency converter
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

    override func tearDown() {
        trades.removeAll()
        trades = nil
        service = nil
        currencyConverter = nil
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
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(100_123.56, currency: "USD"), "+$100,123.56")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(-2_763.66, currency: "GBP"), "-£2,763.66")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(1_234.5, currency: "EUR"), "+€1,234.50")
        XCTAssertEqual(HoldingsCurrencyFormatter.signedAmount(987.65, currency: "CHF"), "+987.65 CHF")
    }

    func testHoldingsCurrencyFormatterAddsUsdSecondaryOnlyForNonUsdAmounts() {
        XCTAssertEqual(
            HoldingsCurrencyFormatter.amountWithUSDSecondary(
                132_830.74,
                currency: "GBP",
                usdAmount: 179_826.22
            ),
            "£132,830.74 ($179,826.22)"
        )
        XCTAssertEqual(
            HoldingsCurrencyFormatter.signedAmountWithUSDSecondary(
                81_006.93,
                currency: "GBP",
                usdAmount: 109_657.25
            ),
            "+£81,006.93 (+$109,657.25)"
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
            MenuPopoverFormatter.currency(103_253.42, currency: "USD", includeSign: true),
            "+$103,253"
        )
        XCTAssertEqual(
            MenuPopoverFormatter.currency(-31_088.1, currency: "GBP", includeSign: true),
            "-£31,088"
        )
        XCTAssertEqual(
            MenuPopoverFormatter.currency(1_147.72, currency: "USD"),
            "$1,147.7"
        )
    }

    func testPortfolioMenuChartDataBuilder_WithNoHistory_CreatesFlatFallback() {
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
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.price, 2500)
        XCTAssertEqual(points.last?.price, 2500)
        XCTAssertEqual(points.first?.date, MenuChartTimeRange.day.startDate(from: now))
        XCTAssertEqual(points.last?.date, now)
    }

    func testPortfolioMenuChartDataBuilder_FiltersAppendsAndSortsPoints() {
        // Given
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldPoint = ChartDataPoint(date: now.addingTimeInterval(-90_000), value: 1000)
        let validPoint = ChartDataPoint(date: now.addingTimeInterval(-60), value: 1500)
        let invalidPoint = ChartDataPoint(date: now.addingTimeInterval(-30), value: .nan)

        // When
        let points = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: [validPoint, oldPoint, invalidPoint],
            currentValue: 1750,
            range: .day,
            now: now
        )

        // Then
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].price, 1500)
        XCTAssertEqual(points[1].price, 1750)
        XCTAssertEqual(points[1].date, now)
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
    func testPortfolioMenuValuesDayRangeConvertsMixedCurrencySyntheticValues() {
        // Given
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
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
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
}
