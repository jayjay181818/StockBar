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
            range: .day,
            now: now,
            maxPoints: 1000
        )

        // Then
        XCTAssertLessThanOrEqual(sampled.count, 1000)
        XCTAssertEqual(sampled.first?.date, points.first?.date)
        XCTAssertEqual(sampled.last?.date, now)
        XCTAssertEqual(sampled.last?.price, 1300)
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
