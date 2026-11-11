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
    
    func testRefreshIntervalIsClampedToTheSupportedRange() {
        dataModel.refreshInterval = 300
        XCTAssertEqual(dataModel.refreshInterval, 300)

        // Out-of-range values are pulled back, in the model and in what is stored.
        let range = RefreshService.refreshIntervalRange
        dataModel.refreshInterval = range.upperBound * 10
        XCTAssertEqual(dataModel.refreshInterval, range.upperBound)
        XCTAssertEqual(
            StockbarRuntimeStorage.userDefaults.object(forKey: "refreshInterval") as? TimeInterval,
            range.upperBound
        )

        dataModel.refreshInterval = range.lowerBound / 2 + 1
        XCTAssertEqual(dataModel.refreshInterval, range.lowerBound)
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
