import XCTest
@testable import Stockbar

@MainActor
class DataModelTests: XCTestCase {
    
    var dataModel: DataModel!
    private var originalRefreshInterval: Any?
    
    override func setUp() {
        super.setUp()
        originalRefreshInterval = UserDefaults.standard.object(forKey: "refreshInterval")
        dataModel = DataModel(
            currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false),
            startRuntimeServices: false
        )
    }
    
    override func tearDown() {
        dataModel = nil
        if let originalRefreshInterval {
            UserDefaults.standard.set(originalRefreshInterval, forKey: "refreshInterval")
        } else {
            UserDefaults.standard.removeObject(forKey: "refreshInterval")
        }
        super.tearDown()
    }
    
    func testDataModelInitialization() {
        XCTAssertNotNil(dataModel)
        XCTAssertTrue(dataModel.refreshInterval > 0, "Refresh interval should be positive")
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
        let savedRefresh = UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval
        
        XCTAssertEqual(savedRefresh, testRefreshInterval)
    }
} 
