import XCTest
@testable import Stockbar

@MainActor
class DataModelTests: XCTestCase {
    
    var dataModel: DataModel!
    private var originalRefreshInterval: Any?
    
    override func setUp() async throws {
        try await super.setUp()
        originalRefreshInterval = StockbarRuntimeStorage.userDefaults.object(forKey: "refreshInterval")
        dataModel = DataModel(
            currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false),
            startRuntimeServices: false
        )
    }
    
    override func tearDown() async throws {
        dataModel = nil
        if let originalRefreshInterval {
            StockbarRuntimeStorage.userDefaults.set(originalRefreshInterval, forKey: "refreshInterval")
        } else {
            StockbarRuntimeStorage.userDefaults.removeObject(forKey: "refreshInterval")
        }
        try await super.tearDown()
    }
    
    func testDataModelInitialization() {
        XCTAssertNotNil(dataModel)
        XCTAssertTrue(dataModel.refreshInterval > 0, "Refresh interval should be positive")
        XCTAssertTrue(
            dataModel.isInitialPortfolioSourceResolved,
            "Non-runtime models should not leave menu-bar synchronization permanently gated"
        )
    }

    func testSymbolStatusItemSyncWaitsForInitialPortfolioSourceResolution() {
        XCTAssertFalse(
            SymbolStatusItemSyncPolicy.shouldSync(initialPortfolioSourceResolved: false)
        )
        XCTAssertTrue(
            SymbolStatusItemSyncPolicy.shouldSync(initialPortfolioSourceResolved: true)
        )
    }
    
    func testRefreshCadenceCalculation() {
        // Test that refresh interval affects cadence properly
        let originalInterval = dataModel.refreshInterval
        
        // Set to 5 minutes (300 seconds)
        dataModel.refreshInterval = 300
        XCTAssertEqual(dataModel.refreshInterval, 300)
        
        // Set to 15 minutes (900 seconds)
        dataModel.refreshInterval = 900
        XCTAssertEqual(dataModel.refreshInterval, 900)
        
        // Restore original interval
        dataModel.refreshInterval = originalInterval
    }
    
    func testStockDataHandling() {
        // Test basic stock data structures
        let trades = dataModel.realTimeTrades
        XCTAssertGreaterThanOrEqual(trades.count, 0)
    }
    
    func testUserDefaultsPersistence() {
        // Test that intervals are persisted to UserDefaults
        let testRefreshInterval: TimeInterval = 420 // 7 minutes
        
        dataModel.refreshInterval = testRefreshInterval
        
        // Check if values were saved to UserDefaults
        let savedRefresh = StockbarRuntimeStorage.userDefaults.object(forKey: "refreshInterval") as? TimeInterval
        
        XCTAssertEqual(savedRefresh, testRefreshInterval)
    }


    private func makeRealTimeTrade(_ symbol: String, units: String = "1", showInMenuBar: Bool = true) -> RealTimeTrade {
        var trade = Trade(name: symbol, position: Position(unitSize: units, positionAvgCost: "10"))
        trade.showInMenuBar = showInMenuBar
        return RealTimeTrade(trade: trade, realTimeInfo: TradingInfo())
    }

    func testDuplicateSymbolRowsAreFlaggedCaseInsensitively() {
        let first = makeRealTimeTrade("AAPL")
        let duplicate = makeRealTimeTrade(" aapl ")
        let other = makeRealTimeTrade("MSFT")
        dataModel.realTimeTrades = [first, duplicate, other]

        XCTAssertTrue(dataModel.hasDuplicateSymbol(first))
        XCTAssertTrue(dataModel.hasDuplicateSymbol(duplicate))
        XCTAssertFalse(dataModel.hasDuplicateSymbol(other))
    }

    func testBlankAndHiddenRowsDoNotCreateMenuBarItems() {
        let blank = makeRealTimeTrade("   ")
        let hidden = makeRealTimeTrade("MSFT", showInMenuBar: false)
        let visible = makeRealTimeTrade("AAPL")

        let menuBarTrades = StockMenuBarController.menuBarTrades(from: [blank, hidden, visible])

        XCTAssertEqual(menuBarTrades.map(\.trade.name), ["AAPL"])
    }
}
