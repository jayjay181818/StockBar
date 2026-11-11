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

    func testARefreshPassAppliesGoodQuotesAndKeepsTheOldPriceForAFailedOne() async throws {
        let suiteName = TestDefaultsSuite.makeName("RefreshPass-")
        defer { TestDefaultsSuite.remove(suiteName) }

        let network = FakeQuoteNetwork(results: [
            StockFetchResult(currency: "USD", symbol: "AAPL", shortName: "Apple", regularMarketTime: 1_700_000_000,
                             exchangeTimezoneName: "America/New_York", regularMarketPrice: 190,
                             regularMarketPreviousClose: 188, displayPrice: 190),
            // A failed quote: the script reports NaN prices.
            StockFetchResult(currency: nil, symbol: "MSFT", shortName: nil, regularMarketTime: nil,
                             exchangeTimezoneName: nil, regularMarketPrice: .nan,
                             regularMarketPreviousClose: .nan, displayPrice: .nan)
        ])
        let refresh = RefreshService(networkService: network, cacheCoordinator: CacheCoordinator(defaults: UserDefaults(suiteName: suiteName)!))
        refresh.setDataModel(dataModel)

        let failing = makeRealTimeTrade("MSFT")
        failing.realTimeInfo.currentPrice = 400
        failing.realTimeInfo.prevClosePrice = 395
        // TSLA is held but not asked for, so it must not be fetched or touched.
        dataModel.realTimeTrades = [makeRealTimeTrade("AAPL"), failing, makeRealTimeTrade("TSLA")]

        await refresh.performRefreshAllTrades(limitedTo: ["aapl", "msft"], force: true)

        let requested = await network.requestedSymbols
        XCTAssertEqual(requested.map { Set($0) }, [["AAPL", "MSFT"]], "one batch request for the two symbols asked for")
        let bySymbol = Dictionary(uniqueKeysWithValues: dataModel.realTimeTrades.map { ($0.trade.name, $0.realTimeInfo) })
        XCTAssertEqual(try XCTUnwrap(bySymbol["AAPL"]).currentPrice, 190, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bySymbol["AAPL"]).prevClosePrice, 188, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bySymbol["MSFT"]).currentPrice, 400, accuracy: 0.0001, "a failed quote keeps the last price")
        XCTAssertEqual(dataModel.quoteRefreshStatus.attemptedCount, 2)
        XCTAssertEqual(dataModel.quoteRefreshStatus.failedCount, 1)
    }
}

private actor FakeQuoteNetwork: NetworkService {
    private let results: [StockFetchResult]
    private(set) var requestedSymbols: [[String]] = []

    init(results: [StockFetchResult]) { self.results = results }

    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        throw NetworkError.noData("not used")
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        requestedSymbols.append(symbols.map { $0.uppercased() })
        return results.filter { result in symbols.contains { $0.uppercased() == result.symbol } }
    }

    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] { [] }

    func verifyAPIKey(service: String) async throws -> Bool { true }
}
