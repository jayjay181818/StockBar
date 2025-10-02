import XCTest
@testable import Stockbar

class PortfolioCalculationTests: XCTestCase {

    var dataModel: DataModel!

    override func setUp() {
        super.setUp()
        dataModel = DataModel()

        // Set up mock currency converter
        CurrencyConverter.shared.exchangeRates = [
            "USD": 1.0,
            "GBP": 0.79,
            "EUR": 0.92,
            "JPY": 149.50,
            "CAD": 1.36
        ]
    }

    override func tearDown() {
        dataModel.realTimeTrades.removeAll()
        dataModel = nil
        super.tearDown()
    }

    // MARK: - Net Gains Calculation Tests

    func testCalculateNetGainsWithSingleStock() {
        // Create a stock with profit
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0 // $20 profit per share
        tradingInfo.currency = "USD"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        dataModel.realTimeTrades.append(realTimeTrade)

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetGains()

        // Expected: (170 - 150) * 10 = 200 USD profit
        XCTAssertEqual(result.amount, 200.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithLoss() {
        // Create a stock with loss
        let trade = Trade(name: "TSLA", position: Position(unitSize: "5", positionAvgCost: "250", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 200.0 // $50 loss per share
        tradingInfo.currency = "USD"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        dataModel.realTimeTrades.append(realTimeTrade)

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetGains()

        // Expected: (200 - 250) * 5 = -250 USD loss
        XCTAssertEqual(result.amount, -250.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithMultipleStocks() {
        // Stock 1: Profit
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // Stock 2: Loss
        let trade2 = Trade(name: "TSLA", position: Position(unitSize: "5", positionAvgCost: "250", currency: "USD", costCurrency: "USD"))
        let tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 200.0
        tradingInfo2.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetGains()

        // Expected: (+200 - 250) = -50 USD net loss
        XCTAssertEqual(result.amount, -50.0, accuracy: 0.01)
    }

    func testCalculateNetGainsWithMixedCurrencies() {
        // USD stock
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // GBP stock
        let trade2 = Trade(name: "BP.L", position: Position(unitSize: "100", positionAvgCost: "4", currency: "GBP", costCurrency: "GBP"))
        let tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 5.0
        tradingInfo2.currency = "GBP"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetGains()

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
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 0.60 // 60 pence = 0.60 GBP
        tradingInfo.currency = "GBP"

        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: tradingInfo)
        dataModel.realTimeTrades.append(realTimeTrade)

        dataModel.preferredCurrency = "GBP"

        let result = dataModel.calculateNetGains()

        // Expected: (0.60 - 0.50) * 1000 = 100 GBP profit
        XCTAssertEqual(result.amount, 100.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "GBP")
    }

    // MARK: - Net Value Calculation Tests

    func testCalculateNetValueWithSingleStock() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetValue()

        // Expected: 170 * 10 = 1700 USD
        XCTAssertEqual(result.amount, 1700.0, accuracy: 0.01)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetValueWithMultipleStocks() {
        // Stock 1
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // Stock 2
        let trade2 = Trade(name: "GOOGL", position: Position(unitSize: "5", positionAvgCost: "130", currency: "USD", costCurrency: "USD"))
        let tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 140.0
        tradingInfo2.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetValue()

        // Expected: (170 * 10) + (140 * 5) = 1700 + 700 = 2400 USD
        XCTAssertEqual(result.amount, 2400.0, accuracy: 0.01)
    }

    func testCalculateNetValueWithMixedCurrencies() {
        // USD stock
        let trade1 = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo1 = TradingInfo()
        tradingInfo1.currentPrice = 170.0
        tradingInfo1.currency = "USD"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade1, realTimeInfo: tradingInfo1))

        // EUR stock
        let trade2 = Trade(name: "SAP", position: Position(unitSize: "10", positionAvgCost: "100", currency: "EUR", costCurrency: "EUR"))
        let tradingInfo2 = TradingInfo()
        tradingInfo2.currentPrice = 120.0
        tradingInfo2.currency = "EUR"
        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade2, realTimeInfo: tradingInfo2))

        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetValue()

        // AAPL: 170 * 10 = 1700 USD
        // SAP: 120 * 10 = 1200 EUR = ~1304 USD (1200 / 0.92)
        // Total: ~3004 USD
        XCTAssertGreaterThan(result.amount, 2900.0)
        XCTAssertLessThan(result.amount, 3100.0)
    }

    // MARK: - Edge Case Tests

    func testCalculateNetGainsWithNoStocks() {
        dataModel.preferredCurrency = "USD"
        let result = dataModel.calculateNetGains()

        XCTAssertEqual(result.amount, 0.0)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetValueWithNoStocks() {
        dataModel.preferredCurrency = "USD"
        let result = dataModel.calculateNetValue()

        XCTAssertEqual(result.amount, 0.0)
        XCTAssertEqual(result.currency, "USD")
    }

    func testCalculateNetGainsWithNaNPrice() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = Double.nan
        tradingInfo.currency = "USD"

        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetGains()

        // Should handle NaN gracefully (likely skip or return 0)
        XCTAssertTrue(result.amount == 0.0 || result.amount.isNaN)
    }

    func testCalculateNetValueWithZeroUnits() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "0", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))
        dataModel.preferredCurrency = "USD"

        let result = dataModel.calculateNetValue()

        XCTAssertEqual(result.amount, 0.0)
    }

    func testCurrencyPreferenceAffectsOutput() {
        let trade = Trade(name: "AAPL", position: Position(unitSize: "10", positionAvgCost: "150", currency: "USD", costCurrency: "USD"))
        let tradingInfo = TradingInfo()
        tradingInfo.currentPrice = 170.0
        tradingInfo.currency = "USD"

        dataModel.realTimeTrades.append(RealTimeTrade(trade: trade, realTimeInfo: tradingInfo))

        // Test USD preference
        dataModel.preferredCurrency = "USD"
        let usdResult = dataModel.calculateNetGains()
        XCTAssertEqual(usdResult.currency, "USD")

        // Test GBP preference
        dataModel.preferredCurrency = "GBP"
        let gbpResult = dataModel.calculateNetGains()
        XCTAssertEqual(gbpResult.currency, "GBP")

        // Values should be different due to conversion
        XCTAssertNotEqual(usdResult.amount, gbpResult.amount)
    }
}
