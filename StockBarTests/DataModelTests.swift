@testable import StockBar
import XCTest

class DataModelTests: XCTestCase {
    var sut: DataModel! // system under test
    var mockNetworkService: MockNetworkService!

    override func setUp() {
        super.setUp()
        mockNetworkService = MockNetworkService()
        sut = DataModel(networkService: mockNetworkService)
    }

    override func tearDown() {
        sut = nil
        mockNetworkService = nil
        super.tearDown()
    }

    func testCalculateNetGains() {
        // Given
        let trade = Trade(name: "AAPL",
                         position: Position(unitSize: "10",
                                         positionAvgCost: "150.00",
                                         currency: "USD"))
        sut.realTimeTrades = [RealTimeTrade(trade: trade,
                                          realTimeInfo: TradingInfo(currentPrice: 160.00))]

        // When
        let (amount, currency) = sut.calculateNetGains()

        // Then
        XCTAssertEqual(amount, 100.00, accuracy: 0.01)
        XCTAssertEqual(currency, "USD")
    }

    func testCurrencyConversion() {
        // Given
        let trade = Trade(name: "GOOGL",
                         position: Position(unitSize: "5",
                                         positionAvgCost: "2500.00",
                                         currency: "USD"))
        sut.realTimeTrades = [RealTimeTrade(trade: trade,
                                          realTimeInfo: TradingInfo(currentPrice: 2600.00))]
        sut.preferredCurrency = "EUR"

        // When
        let (amount, currency) = sut.calculateNetGains()

        // Then
        XCTAssertEqual(currency, "EUR")
        // Note: This test might need adjustment based on your currency conversion implementation
    }

    func testEmptyPortfolio() {
        // Given
        sut.realTimeTrades = []

        // When
        let (amount, currency) = sut.calculateNetGains()

        // Then
        XCTAssertEqual(amount, 0.0, accuracy: 0.01)
        XCTAssertEqual(currency, sut.preferredCurrency)
    }
}
