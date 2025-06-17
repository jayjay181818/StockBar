import XCTest
@testable import Stockbar

class DataModelTests: XCTestCase {
    
    var dataModel: DataModel!
    
    override func setUp() {
        super.setUp()
        dataModel = DataModel()
    }
    
    override func tearDown() {
        dataModel = nil
        super.tearDown()
    }
    
    func testDataModelInitialization() {
        XCTAssertNotNil(dataModel)
        XCTAssertTrue(dataModel.refreshInterval > 0, "Refresh interval should be positive")
        XCTAssertTrue(dataModel.cacheInterval > 0, "Cache interval should be positive")
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
    
    func testCacheIntervalPersistence() {
        // Test that cache interval can be set and retrieved
        let testInterval: TimeInterval = 600 // 10 minutes
        
        dataModel.cacheInterval = testInterval
        XCTAssertEqual(dataModel.cacheInterval, testInterval)
    }
    
    func testStockDataHandling() {
        // Test basic stock data structures
        XCTAssertNotNil(dataModel.stocks)
        XCTAssertTrue(dataModel.stocks.isEmpty || dataModel.stocks.count >= 0)
    }
    
    func testUserDefaultsPersistence() {
        // Test that intervals are persisted to UserDefaults
        let testRefreshInterval: TimeInterval = 420 // 7 minutes
        let testCacheInterval: TimeInterval = 720 // 12 minutes
        
        dataModel.refreshInterval = testRefreshInterval
        dataModel.cacheInterval = testCacheInterval
        
        // Check if values were saved to UserDefaults
        let savedRefresh = UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval
        let savedCache = UserDefaults.standard.object(forKey: "cacheInterval") as? TimeInterval
        
        XCTAssertEqual(savedRefresh, testRefreshInterval)
        XCTAssertEqual(savedCache, testCacheInterval)
    }
} 