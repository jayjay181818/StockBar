import os
import XCTest
@testable import Stockbar

final class OHLCFetchServiceTests: XCTestCase {
    func testFolyncOHLCOverlayDoesNotRunPythonOrPersistSnapshots() async throws {
        let point = OHLCSnapshot(
            symbol: "DFTX",
            timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            open: 10,
            high: 11,
            low: 9,
            close: 10.5,
            volume: 50
        )
        let router = FixtureSupplementalOHLCProvider(result: .folync(
            [point],
            status: .current,
            metadata: FolyncSeriesMetadata(
                interval: "1h",
                availableFrom: "2025-06-15T15:06:40Z",
                availableTo: "2025-06-15T15:06:40Z",
                pointCount: 1,
                coverageComplete: true,
                generatedAt: "2026-07-13T10:00:00.000Z",
                reasonCodes: []
            )
        ))
        let runner = FailingPythonProcessRunner()
        let store = FixtureOHLCStore()
        let service = OHLCFetchService(
            pythonScriptPath: "/tmp/get_ohlc_data.py",
            processRunner: runner,
            ohlcDataStore: store,
            supplementalProvider: router
        )

        let snapshots = try await service.fetchOHLCData(symbol: "MNMD", period: "1mo", interval: "1d")

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.symbol, "DFTX")
        XCTAssertEqual(snapshots.first?.close, 10.5)
        let runnerCalls = await runner.callCount()
        let savedSnapshots = await store.savedSnapshots()
        XCTAssertEqual(runnerCalls, 0)
        XCTAssertTrue(savedSnapshots.isEmpty)

        let routed = try await service.fetchOHLCDataWithSource(symbol: "MNMD", period: "1mo", interval: "1d")
        XCTAssertEqual(routed.sourceStatus, .current)
        XCTAssertEqual(routed.coverageLabel, "1 points · 1h · complete")
    }

    func testFetchOHLCDataUsesAsyncRunnerAndPersistsSnapshots() async throws {
        // Given: A fixture process result from the Python OHLC script.
        let json = """
        {
          "success": true,
          "symbol": "AAPL",
          "period": "1mo",
          "interval": "1d",
          "data": [
            {
              "timestamp": "2026-04-24T00:00:00Z",
              "open": 100.0,
              "high": 110.0,
              "low": 95.0,
              "close": 108.0,
              "volume": 12345
            }
          ],
          "error": null
        }
        """
        let runner = FixturePythonProcessRunner(
            result: PythonProcessResult(
                stdout: Data(json.utf8),
                stderr: Data("url=https://example.test?apikey=secret".utf8),
                exitCode: 0
            )
        )
        let store = FixtureOHLCStore()
        let service = OHLCFetchService(
            pythonScriptPath: "/tmp/get_ohlc_data.py",
            processRunner: runner,
            ohlcDataStore: store
        )

        // When: Fetching OHLC data.
        let snapshots = try await service.fetchOHLCData(symbol: "AAPL", period: "1mo", interval: "1d")

        // Then: The runner was used asynchronously and snapshots were persisted through the injected store.
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.symbol, "AAPL")
        XCTAssertEqual(snapshots.first?.close, 108.0)
        let saved = await store.savedSnapshots()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.volume, 12345)
        let capturedArguments = await runner.capturedArguments()
        XCTAssertEqual(capturedArguments, ["/tmp/get_ohlc_data.py", "AAPL", "1mo", "1d"])
    }
}

final class OHLCCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func candles(
        symbol: String = "AAPL",
        interval: String,
        step: TimeInterval,
        count: Int,
        newestAge: TimeInterval
    ) -> [OHLCSnapshot] {
        let newest = now.addingTimeInterval(-newestAge)
        return (0..<count).map { index in
            OHLCSnapshot(
                symbol: symbol,
                timestamp: newest.addingTimeInterval(-step * TimeInterval(count - 1 - index)),
                open: 100, high: 101, low: 99, close: 100.5, volume: 10,
                interval: interval
            )
        }
    }

    private func makeService(seeded: [OHLCSnapshot]) async -> OHLCFetchService {
        let store = FixtureOHLCStore()
        await store.seed(seeded)
        return OHLCFetchService(
            pythonScriptPath: "/tmp/get_ohlc_data.py",
            processRunner: FailingPythonProcessRunner(),
            ohlcDataStore: store
        )
    }

    func testCacheHitWhenIntervalRangeAndFreshnessMatch() async throws {
        // 1y of weekly bars, newest two days old (inside one interval).
        let service = await makeService(seeded: candles(interval: "1wk", step: 7 * day, count: 52, newestAge: 2 * day))

        let cached = try await service.getCachedOHLCData(symbol: "AAPL", period: "1y", interval: "1wk", now: now)

        XCTAssertEqual(cached.count, 52)
    }

    func testCacheMissForDifferentInterval() async throws {
        // Only 5m bars are stored; a weekly request must not be served by them.
        let service = await makeService(seeded: candles(interval: "5m", step: 300, count: 78, newestAge: 60))

        let cached = try await service.getCachedOHLCData(symbol: "AAPL", period: "1y", interval: "1wk", now: now)

        XCTAssertTrue(cached.isEmpty)
    }

    func testCacheMissWhenStoredRowsPredateIntervalTracking() async throws {
        let legacy = candles(interval: "1d", step: day, count: 30, newestAge: 3600).map {
            OHLCSnapshot(symbol: $0.symbol, timestamp: $0.timestamp, open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume)
        }
        let service = await makeService(seeded: legacy)

        let cached = try await service.getCachedOHLCData(symbol: "AAPL", period: "1mo", interval: "1d", now: now)

        XCTAssertTrue(cached.isEmpty)
    }

    func testCacheMissWhenRangeIsNotCovered() async throws {
        // One month of daily bars cannot satisfy a 1y request at the same interval.
        let service = await makeService(seeded: candles(interval: "1d", step: day, count: 30, newestAge: 3600))

        let oneYear = try await service.getCachedOHLCData(symbol: "AAPL", period: "1y", interval: "1d", now: now)
        let oneMonth = try await service.getCachedOHLCData(symbol: "AAPL", period: "1mo", interval: "1d", now: now)

        XCTAssertTrue(oneYear.isEmpty)
        XCTAssertEqual(oneMonth.count, 30)
    }

    func testStaleNewestCandleTriggersRefetch() async throws {
        // 5m bars whose newest candle is 20 minutes old: more than one interval stale.
        let stale = candles(interval: "5m", step: 300, count: 78, newestAge: 1200)
        let fresh = candles(interval: "5m", step: 300, count: 78, newestAge: 120)

        let staleCached = try await makeService(seeded: stale)
            .getCachedOHLCData(symbol: "AAPL", period: "1d", interval: "5m", now: now)
        let freshCached = try await makeService(seeded: fresh)
            .getCachedOHLCData(symbol: "AAPL", period: "1d", interval: "5m", now: now)
        let staleFallback = try await makeService(seeded: stale)
            .getCachedOHLCData(symbol: "AAPL", period: "1d", interval: "5m", now: now, allowStale: true)

        XCTAssertTrue(staleCached.isEmpty)
        XCTAssertEqual(freshCached.count, 78)
        XCTAssertEqual(staleFallback.count, 78)
    }

    func testSaveSnapshotsUpsertsExistingCandleAndKeepsIntervalsSeparate() async throws {
        let service = OHLCDataService(coreDataStack: .shared)
        let symbol = "UPSERT-\(UUID().uuidString)"
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        func candle(close: Double, volume: Int64, interval: String) -> OHLCSnapshot {
            OHLCSnapshot(symbol: symbol, timestamp: timestamp, open: 10, high: max(11, close), low: 9, close: close, volume: volume, interval: interval)
        }

        // A partial candle, then the same candle once it has formed.
        try await service.saveSnapshots([candle(close: 10.2, volume: 5, interval: "5m")])
        try await service.saveSnapshots([candle(close: 12.5, volume: 90, interval: "5m")])
        // Same timestamp at another interval is a different candle.
        try await service.saveSnapshots([candle(close: 11, volume: 1, interval: "1d")])

        let fiveMinute = try await service.fetchSnapshots(symbol: symbol, interval: "5m", startDate: nil, endDate: nil)
        let daily = try await service.fetchSnapshots(symbol: symbol, interval: "1d", startDate: nil, endDate: nil)

        XCTAssertEqual(fiveMinute.count, 1)
        XCTAssertEqual(fiveMinute.first?.close ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(fiveMinute.first?.high ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(fiveMinute.first?.volume, 90)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.close ?? 0, 11, accuracy: 0.0001)

        try await service.deleteSnapshots(symbol: symbol)
    }
}

final class PythonNetworkServiceTests: XCTestCase {
    func testBatchQuotesUseOneJSONProcessAndReturnPartialPlaceholders() async throws {
        let response = """
        [
          {
            "symbol": "AAPL",
            "success": true,
            "quote": {
              "symbol": "AAPL",
              "price": 201.5,
              "regularMarketPrice": 200.0,
              "previousClose": 198.0,
              "timestamp": 1750000000,
              "fetchedAt": 1750000123.5,
              "currency": "USD"
            }
          },
          {
            "symbol": "BAD",
            "success": false,
            "error": {"error_code": "RATE_LIMIT", "message": "Throttled"}
          },
          {
            "symbol": "MSFT",
            "success": true,
            "quote": {
              "symbol": "MSFT",
              "price": 410.0,
              "previousClose": 405.0,
              "timestamp": 1750000001,
              "currency": "USD"
            }
          }
        ]
        """
        let runner = FixturePythonProcessRunner(
            result: PythonProcessResult(
                stdout: Data(response.utf8),
                stderr: Data(),
                exitCode: 0
            )
        )
        let service = PythonNetworkService(
            config: PythonConfiguration(interpreterPath: "/usr/bin/python3"),
            processRunner: runner,
            scriptPath: "/tmp/get_stock_data.py"
        )

        let results = try await service.fetchBatchQuotes(for: ["AAPL", "BAD", "MSFT"])

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].regularMarketPrice, 200)
        XCTAssertTrue(results[1].regularMarketPrice.isNaN)
        XCTAssertEqual(results[1].failure, .rateLimited)
        XCTAssertNil(results[0].failure)
        XCTAssertEqual(results[2].regularMarketPrice, 410)
        // The key the script writes in PythonTests' test_each_quote_says_when_it_was_fetched.
        XCTAssertEqual(results[0].fetchedAt, 1750000123.5)
        XCTAssertNil(results[2].fetchedAt)
        let capturedArguments = await runner.capturedArguments()
        XCTAssertEqual(
            capturedArguments,
            ["/tmp/get_stock_data.py", "--json", "--deadline-seconds", "30", "AAPL", "BAD", "MSFT"]
        )
    }

    func testSingleQuoteUsesTheSameJSONBatchPath() async throws {
        let response = """
        [{"symbol":"AAPL","success":true,"quote":{"symbol":"AAPL","price":201.5,"previousClose":198.0,"timestamp":1750000000,"currency":"USD"}}]
        """
        let runner = FixturePythonProcessRunner(
            result: PythonProcessResult(stdout: Data(response.utf8), stderr: Data(), exitCode: 0)
        )
        let service = PythonNetworkService(
            config: PythonConfiguration(interpreterPath: "/usr/bin/python3"),
            processRunner: runner,
            scriptPath: "/tmp/get_stock_data.py"
        )

        let result = try await service.fetchQuote(for: "AAPL")

        XCTAssertEqual(result.symbol, "AAPL")
        let capturedArguments = await runner.capturedArguments()
        XCTAssertEqual(capturedArguments, ["/tmp/get_stock_data.py", "--json", "--deadline-seconds", "30", "AAPL"])
    }

    func testMalformedSuccessfulQuoteBecomesPlaceholderWithoutFailingAdjacentSymbols() async throws {
        let response = """
        [
          {
            "symbol": "AAPL",
            "success": true,
            "quote": {
              "symbol": "AAPL",
              "price": 201.5,
              "regularMarketPrice": 200.0,
              "previousClose": 198.0,
              "timestamp": 1750000000,
              "currency": "USD"
            }
          },
          {
            "symbol": "^GSPC",
            "success": true,
            "quote": {
              "symbol": "^GSPC",
              "price": 7428.78,
              "regularMarketPrice": 7428.78,
              "previousClose": null,
              "timestamp": 1750000001,
              "currency": "USD"
            }
          }
        ]
        """
        let runner = FixturePythonProcessRunner(
            result: PythonProcessResult(
                stdout: Data(response.utf8),
                stderr: Data(),
                exitCode: 0
            )
        )
        let service = PythonNetworkService(
            config: PythonConfiguration(interpreterPath: "/usr/bin/python3"),
            processRunner: runner,
            scriptPath: "/tmp/get_stock_data.py"
        )

        let results = try await service.fetchBatchQuotes(for: ["AAPL", "^GSPC"])

        XCTAssertEqual(results[0].regularMarketPrice, 200)
        XCTAssertTrue(results[1].regularMarketPrice.isNaN)
        XCTAssertEqual(results[1].failure, .noData)
        XCTAssertNil(results[0].failure)
        XCTAssertTrue(results[1].regularMarketPreviousClose.isNaN)
    }

    func testSingleMalformedSuccessfulQuoteThrowsNoData() async {
        let response = """
        [{
          "symbol": "^GSPC",
          "success": true,
          "quote": {
            "symbol": "^GSPC",
            "price": 7428.78,
            "regularMarketPrice": 7428.78,
            "previousClose": 0,
            "timestamp": 1750000001,
            "currency": "USD"
          }
        }]
        """
        let runner = FixturePythonProcessRunner(
            result: PythonProcessResult(
                stdout: Data(response.utf8),
                stderr: Data(),
                exitCode: 0
            )
        )
        let service = PythonNetworkService(
            config: PythonConfiguration(interpreterPath: "/usr/bin/python3"),
            processRunner: runner,
            scriptPath: "/tmp/get_stock_data.py"
        )

        do {
            _ = try await service.fetchQuote(for: "^GSPC")
            XCTFail("Malformed single-symbol quote should not be accepted")
        } catch let error as NetworkError {
            guard case .noData = error else {
                return XCTFail("Expected noData, got \(error)")
            }
        } catch {
            XCTFail("Expected NetworkError.noData, got \(error)")
        }
    }
}

private actor FixtureSupplementalOHLCProvider: FolyncSupplementalOHLCProviding {
    private let result: FolyncRoutedOHLCResult

    init(result: FolyncRoutedOHLCResult) {
        self.result = result
    }

    func routeOHLC(
        symbol: String,
        period: String,
        interval: String,
        from: Date?,
        to: Date?
    ) async throws -> FolyncRoutedOHLCResult {
        result
    }
}

private actor FailingPythonProcessRunner: PythonProcessRunning {
    private var calls = 0

    func run(arguments: [String], timeoutSeconds: TimeInterval, logContext: String) async throws -> PythonProcessResult {
        calls += 1
        throw OHLCFetchError.fetchFailed("Python must not run")
    }

    func callCount() -> Int { calls }
}

private actor FixturePythonProcessRunner: PythonProcessRunning {
    private let result: PythonProcessResult
    private var arguments: [String] = []

    init(result: PythonProcessResult) {
        self.result = result
    }

    func run(arguments: [String], timeoutSeconds: TimeInterval, logContext: String) async throws -> PythonProcessResult {
        self.arguments = arguments
        return result
    }

    func capturedArguments() -> [String] {
        arguments
    }
}

private actor FixtureOHLCStore: OHLCDataStoring {
    private var saved: [OHLCSnapshot] = []

    func saveSnapshots(_ snapshots: [OHLCSnapshot]) async throws {
        saved.append(contentsOf: snapshots)
    }

    func fetchSnapshots(symbol: String, interval: String?, startDate: Date?, endDate: Date?) async throws -> [OHLCSnapshot] {
        saved.filter {
            $0.symbol == symbol
                && $0.interval == interval
                && (startDate == nil || $0.timestamp >= startDate!)
                && (endDate == nil || $0.timestamp <= endDate!)
        }
    }

    func seed(_ snapshots: [OHLCSnapshot]) {
        saved = snapshots
    }

    func savedSnapshots() -> [OHLCSnapshot] {
        saved
    }
}

// MARK: - Instrument events

final class InstrumentEventsServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_795_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let scriptPath = "/tmp/get_instrument_events.py"
    private var directory: URL!
    private var clock: OSAllocatedUnfairLock<Date>!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentEventsServiceTests-\(UUID().uuidString)", isDirectory: true)
        clock = OSAllocatedUnfairLock(initialState: start)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func advance(_ interval: TimeInterval) {
        clock.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    private func makeService(
        runner: InstrumentEventsRunnerStub,
        policy: StockbarProviderAccessPolicy = StockbarProviderAccessPolicy(liveRequestsAllowed: true)
    ) -> InstrumentEventsService {
        let clock = self.clock!
        return InstrumentEventsService(
            scriptPath: scriptPath,
            processRunner: runner,
            providerPolicy: policy,
            directory: directory,
            now: { clock.withLock { $0 } }
        )
    }

    private static func success(_ symbol: String, type: String? = "EQUITY", exDate: String? = "2026-11-28") -> String {
        let typeJSON = type.map { "\"\($0)\"" } ?? "null"
        let exJSON = exDate.map { "\"\($0)\"" } ?? "null"
        return """
        {"symbol": "\(symbol)", "success": true, "events": {"symbol": "\(symbol)", "instrumentType": \(typeJSON),
         "exDividendDate": \(exJSON), "dividendPayDate": null, "earningsDate": null, "earningsDateEnd": null,
         "dividends": [], "dividendCurrency": null, "fetchedAt": 1795000000.5}}
        """
    }

    private static func failure(_ symbol: String, code: String) -> String {
        """
        {"symbol": "\(symbol)", "success": false, "error": {"error_code": "\(code)", "message": "invented"}}
        """
    }

    private static func answer(_ entries: String...) -> InstrumentEventsRunnerStub.Response {
        .output("[" + entries.joined(separator: ",") + "]")
    }

    func testSavedEventsReadOnlyWhatIsSavedAndNeverRunTheHelper() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.success("ALPHA"))])
        let service = makeService(runner: runner)

        let before = await service.savedEvents(for: ["ALPHA"])
        var count = await runner.callCount()
        XCTAssertTrue(before.isEmpty, "nothing saved yet, so nothing to show")
        XCTAssertEqual(count, 0, "reading saved copies never runs the helper")

        _ = await service.events(for: ["ALPHA"])
        count = await runner.callCount()
        XCTAssertEqual(count, 1)

        // Two days on the copy is past its day, and is still read, without asking again.
        advance(2 * day)
        let saved = await service.savedEvents(for: ["alpha", "BETA", "-BAD", "ALPHA"])
        count = await runner.callCount()
        XCTAssertEqual(Array(saved.keys), ["ALPHA"])
        XCTAssertEqual(saved["ALPHA"]?.exDividendDate, InstrumentEventDay("2026-11-28"))
        XCTAssertEqual(count, 1, "an old copy is read, never refreshed")

        // Another service over the same folder reads the copy from disk, and runs nothing.
        let other = InstrumentEventsRunnerStub(responses: [.timeout])
        let fromDisk = await makeService(runner: other).savedEvents(for: ["ALPHA"])
        let otherCount = await other.callCount()
        XCTAssertEqual(fromDisk["ALPHA"]?.symbol, "ALPHA")
        XCTAssertEqual(otherCount, 0)
    }

    func testTheAcceptanceFixtureCanGiveAnEarningsRange() async throws {
        let fixture = try StockbarAcceptanceEventsFixture.decode(Data("""
        {"version": 1, "holdings": [
          {"symbol": "FAKERANGE", "earningsInDays": 30, "earningsEndInDays": 37},
          {"symbol": "FAKEONE", "earningsInDays": 9},
          {"symbol": "FAKEEND", "earningsEndInDays": 5}]}
        """.utf8))
        let clock = self.clock!
        let service = InstrumentEventsService(
            scriptPath: nil, processRunner: InstrumentEventsRunnerStub(responses: [.output("[]")]),
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
            directory: directory, now: { clock.withLock { $0 } }, fixture: fixture
        )
        let results = await service.events(for: ["FAKERANGE", "FAKEONE", "FAKEEND"])
        func offset(_ days: Int) -> InstrumentEventDay? {
            InstrumentEventDay.on(start.addingTimeInterval(Double(days) * day))
        }
        XCTAssertEqual(results[0].events?.earningsDate, offset(30))
        XCTAssertEqual(results[0].events?.earningsDateEnd, offset(37))
        XCTAssertEqual(results[1].events?.earningsDate, offset(9))
        XCTAssertNil(results[1].events?.earningsDateEnd, "a single date has no end")
        XCTAssertNil(results[2].events?.earningsDate)
        XCTAssertNil(results[2].events?.earningsDateEnd, "an end with no start is not a range")
    }

    func testTheAcceptanceFixtureAnswersInsteadOfTheHelperAndYahoo() async throws {
        let fixture = try StockbarAcceptanceEventsFixture.decode(Data("""
        {"version": 1, "holdings": [{"symbol": "FAKEUS", "instrumentType": "EQUITY", "currency": "USD",
          "dividends": [{"daysFromToday": -40, "amount": 0.25}], "exDividendInDays": 10, "payInDays": 20}]}
        """.utf8))
        let runner = InstrumentEventsRunnerStub(responses: [.output("[]")])
        let clock = self.clock!
        let service = InstrumentEventsService(
            scriptPath: nil, processRunner: runner,
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
            directory: directory, now: { clock.withLock { $0 } }, fixture: fixture
        )

        let results = await service.events(for: ["FAKEUS", "FAKENA"])
        let count = await runner.callCount()
        XCTAssertEqual(count, 0, "the helper never runs, and Yahoo is never asked")
        let events = try XCTUnwrap(results.first?.events)
        let today = try XCTUnwrap(InstrumentEventDay.on(start))
        func offset(_ days: Int) -> InstrumentEventDay? {
            InstrumentEventDay.on(start.addingTimeInterval(Double(days) * day))
        }
        XCTAssertEqual(events.dividends, [InstrumentDividend(date: try XCTUnwrap(offset(-40)), amount: 0.25)])
        XCTAssertEqual(events.exDividendDate, offset(10))
        XCTAssertEqual(events.dividendPayDate, offset(20))
        XCTAssertEqual(events.dividendCurrency, "USD")
        XCTAssertEqual(events.instrumentType, .equity)
        XCTAssertNotNil(today)
        XCTAssertEqual(results.last?.outcome, .failed(.noData), "a symbol the fixture does not name has no data")
        // The answer is saved like Yahoo's: a second ask inside the day is answered from it.
        let again = await service.events(for: ["FAKEUS"])
        XCTAssertEqual(again.first?.isStale, false)
        XCTAssertEqual(again.first?.outcome, results.first?.outcome)
    }

    func testDecodesEveryFieldAndKeepsNullAsNil() async {
        let full = """
        [{"symbol": "ALPHA", "success": true, "events": {"symbol": "ALPHA", "instrumentType": "EQUITY",
          "exDividendDate": "2026-11-28", "dividendPayDate": "2026-12-10", "earningsDate": "2027-01-28",
          "earningsDateEnd": "2027-02-04", "dividends": [{"date": "2026-02-05", "amount": 0.25},
          {"date": "2026-05-07", "amount": 0.26}], "dividendCurrency": "USD", "fetchedAt": 1795000000.5}},
         {"symbol": "GAMMA.L", "success": true, "events": {"symbol": "GAMMA.L", "instrumentType": "WARRANT",
          "exDividendDate": null, "dividendPayDate": null, "earningsDate": null, "earningsDateEnd": null,
          "dividends": null, "dividendCurrency": null, "fetchedAt": 1795000000}}]
        """
        let runner = InstrumentEventsRunnerStub(responses: [.output(full)])
        let service = makeService(runner: runner)

        let results = await service.events(for: ["ALPHA", "GAMMA.L"])

        XCTAssertEqual(results.map(\.symbol), ["ALPHA", "GAMMA.L"])
        XCTAssertTrue(results.allSatisfy { $0.source == .yahoo && $0.failure == nil })
        let alpha = results[0].events
        XCTAssertEqual(alpha?.instrumentType, .equity)
        XCTAssertEqual(alpha?.exDividendDate, InstrumentEventDay(year: 2026, month: 11, day: 28))
        XCTAssertEqual(alpha?.dividendPayDate?.description, "2026-12-10")
        XCTAssertEqual(alpha?.earningsDate?.description, "2027-01-28")
        XCTAssertEqual(alpha?.earningsDateEnd?.description, "2027-02-04")
        XCTAssertEqual(alpha?.dividends?.map(\.amount), [0.25, 0.26])
        XCTAssertEqual(alpha?.dividendCurrency, "USD")
        XCTAssertEqual(results[0].fetchedAt, Date(timeIntervalSince1970: 1_795_000_000.5))

        let fund = results[1].events
        XCTAssertEqual(fund?.instrumentType, .other("WARRANT"))
        XCTAssertEqual(fund?.instrumentType?.rawValue, "WARRANT")
        XCTAssertNil(fund?.exDividendDate)
        XCTAssertNil(fund?.dividendPayDate)
        XCTAssertNil(fund?.earningsDate)
        XCTAssertNil(fund?.earningsDateEnd)
        XCTAssertNil(fund?.dividends, "null stays nil, not an empty list")
        XCTAssertNil(fund?.dividendCurrency)

        XCTAssertNil(InstrumentEventDay("2026-02-30"))
        XCTAssertNil(InstrumentEventDay("NaT"))
        XCTAssertNil(InstrumentEventDay("2026-1-05"))
        XCTAssertLessThan(InstrumentEventDay("2026-09-18")!, InstrumentEventDay("2026-11-28")!)
    }

    func testOneUnreadableEntryDoesNotFailTheOthers() async {
        let bad = """
        {"symbol": "BETA.L", "success": true, "events": {"symbol": "BETA.L", "exDividendDate": "18/09/2026", "fetchedAt": 1}}
        """
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.success("ALPHA"), bad)])
        let service = makeService(runner: runner)

        let results = await service.events(for: ["ALPHA", "BETA.L"])

        XCTAssertNil(results[0].failure)
        XCTAssertNotNil(results[0].events)
        guard case .failed(.scriptFailed) = results[1].outcome else {
            return XCTFail("Expected an unreadable-answer failure, got \(results[1].outcome)")
        }
    }

    func testSavedCopyIsUsedInsideADayAndRefreshedAfter() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA", exDate: "2026-11-28")),
            Self.answer(Self.success("ALPHA", exDate: "2027-02-20")),
        ])
        let service = makeService(runner: runner)

        _ = await service.events(for: ["ALPHA"])
        advance(23 * hour)
        let sameDay = await service.events(for: ["ALPHA"])
        let callsInsideTheDay = await runner.callCount()
        advance(2 * hour)
        let nextDay = await service.events(for: ["ALPHA"])

        XCTAssertEqual(callsInsideTheDay, 1)
        XCTAssertEqual(sameDay[0].events?.exDividendDate?.description, "2026-11-28")
        XCTAssertEqual(sameDay[0].outcome, .events(sameDay[0].events!, .current))
        let totalCalls = await runner.callCount()
        XCTAssertEqual(totalCalls, 2)
        XCTAssertEqual(nextDay[0].events?.exDividendDate?.description, "2027-02-20")

        // A new service (a relaunch) reads the saved copy instead of running the script.
        let relaunched = makeService(runner: InstrumentEventsRunnerStub(responses: [.output("[]")]))
        let fromDisk = await relaunched.events(for: ["ALPHA"])
        XCTAssertEqual(fromDisk[0].events?.exDividendDate?.description, "2027-02-20")
        XCTAssertNil(fromDisk[0].failure)
    }

    func testSeveralSymbolsGoInOneRunWithoutRepeats() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.success("ALPHA"), Self.success("BETA.L"))])
        let service = makeService(runner: runner)

        let results = await service.events(for: ["alpha", "ALPHA", " BETA.L", "-BAD", "ALPHA"])

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
        let arguments = try XCTUnwrap(calls.first)
        XCTAssertEqual(arguments.first, scriptPath)
        XCTAssertEqual(Array(arguments.suffix(2)), ["ALPHA", "BETA.L"])
        XCTAssertTrue(arguments.contains("--json"))
        XCTAssertFalse(arguments.contains("-BAD"), "Invalid symbols never reach the script")
        XCTAssertEqual(results.map(\.symbol), ["ALPHA", "BETA.L", "-BAD"])
        XCTAssertEqual(results[2].outcome, .failed(.invalidSymbol))
    }

    func testCallersAtTheSameTimeShareOneRun() async {
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.success("ALPHA"), Self.success("BETA.L"))])
        await runner.hold()
        let service = makeService(runner: runner)

        let first = Task { await service.events(for: ["ALPHA", "BETA.L"]) }
        await runner.waitForCalls(1)
        let second = Task { await service.events(for: ["BETA.L"]) }
        await waitUntil { await service.sharedRunWaits == 1 }
        await runner.release()

        let firstResults = await first.value
        let secondResults = await second.value
        let calls = await runner.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(firstResults.compactMap(\.events).count, 2)
        XCTAssertEqual(secondResults.first?.events?.symbol, "BETA.L")
        XCTAssertNil(secondResults.first?.failure)
    }

    func testStaleCopyWhenYahooDoesNotAnswer() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA")),
            Self.answer(Self.failure("ALPHA", code: "NETWORK_ERROR"), Self.failure("BETA.L", code: "NETWORK_ERROR")),
            .timeout,
        ])
        let service = makeService(runner: runner)

        let saved = await service.events(for: ["ALPHA"])
        advance(3 * day)
        let failed = await service.events(for: ["ALPHA", "BETA.L"])
        let timedOut = await service.events(for: ["ALPHA"])

        XCTAssertEqual(failed[0].outcome, .events(saved[0].events!, .stale(.network)))
        XCTAssertTrue(failed[0].isStale)
        XCTAssertEqual(failed[1].outcome, .failed(.network), "No saved copy: a failure that says why")
        XCTAssertEqual(timedOut[0].outcome, .events(saved[0].events!, .stale(.timedOut)))
    }

    func testNoRunWhenTheProviderPolicyRefuses() async {
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.success("ALPHA"))])
        let refused = makeService(runner: runner, policy: StockbarProviderAccessPolicy(liveRequestsAllowed: false))

        let results = await refused.events(for: ["ALPHA"], forceRefresh: true)

        let refusedCalls = await runner.callCount()
        XCTAssertEqual(refusedCalls, 0)
        XCTAssertEqual(results[0].outcome, .failed(.providerDisabled))

        // The app's own policy under XCTest isolation refuses too.
        let isolated = makeService(runner: runner, policy: .current)
        let isolatedResults = await isolated.events(for: ["ALPHA"])
        let isolatedCalls = await runner.callCount()
        XCTAssertEqual(isolatedCalls, 0)
        XCTAssertEqual(isolatedResults[0].outcome, .failed(.providerDisabled))
    }

    func testRateLimitPausesRunsForAnHourEvenWhenForced() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA"), Self.failure("BETA.L", code: "RATE_LIMIT")),
            Self.answer(Self.success("BETA.L")),
        ])
        let service = makeService(runner: runner)
        let pauseEnds = start.addingTimeInterval(hour)

        let limited = await service.events(for: ["ALPHA", "BETA.L"])
        advance(59 * 60)
        let paused = await service.events(for: ["BETA.L"], forceRefresh: true)
        let pausedCalls = await runner.callCount()
        advance(2 * 60)
        let resumed = await service.events(for: ["BETA.L"])

        XCTAssertNil(limited[0].failure)
        XCTAssertEqual(limited[1].outcome, .failed(.rateLimited(retryAfter: pauseEnds)))
        XCTAssertEqual(paused[0].outcome, .failed(.rateLimited(retryAfter: pauseEnds)))
        XCTAssertEqual(pausedCalls, 1, "No run inside the hour, forced or not")
        let resumedCalls = await runner.callCount()
        XCTAssertEqual(resumedCalls, 2)
        XCTAssertNil(resumed[0].failure)
    }

    func testSymbolYahooDoesNotKnowIsNotAskedForAgainThatDay() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA"), Self.failure("NOSUCH", code: "NO_DATA")),
            Self.answer(Self.failure("NOSUCH", code: "NO_DATA")),
            Self.answer(Self.success("NOSUCH")),
        ])
        let service = makeService(runner: runner)

        let first = await service.events(for: ["ALPHA", "NOSUCH"])
        advance(hour)
        let again = await service.events(for: ["ALPHA", "NOSUCH"])
        let callsInsideTheDay = await runner.callCount()
        let forced = await service.events(for: ["NOSUCH"], forceRefresh: true)
        let callsAfterForce = await runner.callCount()
        advance(day)
        let nextDay = await service.events(for: ["NOSUCH"])
        let callsNextDay = await runner.callCount()

        XCTAssertEqual(first[1].outcome, .failed(.noData))
        XCTAssertEqual(again[1].outcome, .failed(.noData))
        XCTAssertEqual(callsInsideTheDay, 1, "Yahoo is not asked again that day for a symbol it does not know")
        XCTAssertEqual(forced[0].outcome, .failed(.noData))
        XCTAssertEqual(callsAfterForce, 2, "A forced refresh still asks")
        XCTAssertNil(nextDay[0].failure)
        XCTAssertEqual(callsNextDay, 3)
    }

    func testRateLimitForTheWholeRunAlsoPauses() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            .output(#"{"error": true, "error_code": "RATE_LIMIT", "message": "invented", "timestamp": 1}"#),
        ])
        let service = makeService(runner: runner)

        _ = await service.events(for: ["ALPHA"])
        advance(10 * 60)
        let paused = await service.events(for: ["ALPHA"])

        let calls = await runner.callCount()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(paused[0].outcome, .failed(.rateLimited(retryAfter: start.addingTimeInterval(hour))))
    }

    func testForcedRefreshRunsInsideTheDay() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA", exDate: "2026-11-28")),
            Self.answer(Self.success("ALPHA", exDate: "2026-12-01")),
        ])
        let service = makeService(runner: runner)

        _ = await service.events(for: ["ALPHA"])
        advance(hour)
        let forced = await service.events(for: ["ALPHA"], forceRefresh: true)

        let calls = await runner.callCount()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(forced[0].events?.exDividendDate?.description, "2026-12-01")
        XCTAssertNil(forced[0].failure)
    }

    func testSavedCopiesOlderThanThirtyDaysAreRemoved() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA")),
            Self.answer(Self.success("BETA.L")),
        ])
        let service = makeService(runner: runner)
        _ = await service.events(for: ["ALPHA"])
        advance(2 * day)
        _ = await service.events(for: ["BETA.L"])
        try Data("not json".utf8).write(to: directory.appendingPathComponent("events-BROKEN.json"))

        advance(29 * day)
        let relaunched = makeService(runner: InstrumentEventsRunnerStub(responses: [.timeout]))
        _ = await relaunched.events(for: [])

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["events-BETA.L.json"])
    }

    // MARK: Earnings history (invented figures)

    private static func history(_ symbol: String, reported: String = "1.52", estimated: String = "1.48",
                                currency: String? = "USD") -> String {
        let currencyJSON = currency.map { "\"\($0)\"" } ?? "null"
        return """
        {"symbol": "\(symbol)", "success": true, "earningsHistory": {"symbol": "\(symbol)",
         "earnings": [{"date": "2026-07-22", "reportedEPS": null, "estimatedEPS": null, "surprisePercent": null},
                      {"date": "2026-10-30", "reportedEPS": \(reported), "estimatedEPS": \(estimated),
                       "surprisePercent": 2.7}],
         "epsCurrency": \(currencyJSON), "fetchedAt": 1795000000.5}}
        """
    }

    func testEarningsHistoryIsItsOwnRunWithItsFlagAndDecodesEveryField() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.history("ALPHA"), Self.history("BETA.L", reported: "null", estimated: "null", currency: nil)),
        ])
        let service = makeService(runner: runner)

        let results = await service.earningsHistory(for: ["alpha", "BETA.L", "ALPHA", "-BAD"])

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1, "every symbol in one run")
        let arguments = try XCTUnwrap(calls.first)
        XCTAssertEqual(arguments.first, scriptPath)
        XCTAssertTrue(arguments.contains("--json"))
        XCTAssertTrue(arguments.contains(InstrumentEventsService.earningsHistoryFlag))
        XCTAssertEqual(Array(arguments.suffix(2)), ["ALPHA", "BETA.L"])
        XCTAssertEqual(results.map(\.symbol), ["ALPHA", "BETA.L", "-BAD"])
        XCTAssertEqual(results[2].outcome, .failed(.invalidSymbol))

        let alpha = try XCTUnwrap(results[0].history)
        XCTAssertEqual(alpha.epsCurrency, "USD")
        XCTAssertEqual(alpha.fetchedAt, Date(timeIntervalSince1970: 1_795_000_000.5))
        XCTAssertEqual(alpha.earnings, [
            InstrumentPastEarnings(date: try XCTUnwrap(InstrumentEventDay("2026-07-22")), reportedEPS: nil,
                                   estimatedEPS: nil, surprisePercent: nil),
            InstrumentPastEarnings(date: try XCTUnwrap(InstrumentEventDay("2026-10-30")), reportedEPS: 1.52,
                                   estimatedEPS: 1.48, surprisePercent: 2.7),
        ])
        XCTAssertNil(results[1].history?.epsCurrency)
        XCTAssertNil(results[1].history?.earnings.last?.reportedEPS)
        let runs = (await service.eventsRuns, await service.earningsHistoryRuns)
        XCTAssertEqual(runs.0, 0, "asking for past earnings never asks for events")
        XCTAssertEqual(runs.1, 1)
    }

    func testEarningsHistoryKeepsItsOwnDayLongCopiesBesideTheEvents() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA")),
            Self.answer(Self.history("ALPHA")),
            Self.answer(Self.history("ALPHA", reported: "1.60")),
        ])
        let service = makeService(runner: runner)

        _ = await service.events(for: ["ALPHA"])
        let first = await service.earningsHistory(for: ["ALPHA"])
        advance(23 * hour)
        let insideTheDay = await service.earningsHistory(for: ["ALPHA"])
        let insideCount = await runner.callCount()
        XCTAssertEqual(insideCount, 2, "a copy younger than a day is used, and the events copy never answers for it")
        XCTAssertEqual(insideTheDay, first)
        XCTAssertNil(insideTheDay[0].failure)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["earnings-history-ALPHA.json", "events-ALPHA.json"])

        // Another service over the same folder reads both copies from disk.
        let relaunched = makeService(runner: InstrumentEventsRunnerStub(responses: [.timeout]))
        let fromDisk = await relaunched.earningsHistory(for: ["ALPHA"])
        XCTAssertEqual(fromDisk[0].history, first[0].history)
        let savedEvents = await relaunched.savedEvents(for: ["ALPHA"])
        XCTAssertEqual(savedEvents["ALPHA"]?.exDividendDate, InstrumentEventDay("2026-11-28"))

        advance(2 * hour)
        let afterTheDay = await service.earningsHistory(for: ["ALPHA"])
        let afterCount = await runner.callCount()
        XCTAssertEqual(afterCount, 3, "after a day it is asked for again")
        XCTAssertEqual(afterTheDay[0].history?.earnings.last?.reportedEPS, 1.60)
    }

    func testEarningsHistoryStaleCopyAndNoDataForADay() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.history("ALPHA"), Self.failure("FUND", code: "NO_DATA")),
            Self.answer(Self.failure("ALPHA", code: "NETWORK_ERROR")),
        ])
        let service = makeService(runner: runner)

        let first = await service.earningsHistory(for: ["ALPHA", "FUND"])
        XCTAssertEqual(first[1].outcome, .failed(.noData), "no history is no data")
        let again = await service.earningsHistory(for: ["FUND"])
        let count = await runner.callCount()
        XCTAssertEqual(count, 1, "a symbol with no history is not asked for again that day")
        XCTAssertEqual(again[0].outcome, .failed(.noData))
        // ...and a symbol with no past earnings does not stop its events being asked for.
        let eventsRuns = await service.eventsRuns
        XCTAssertEqual(eventsRuns, 0)

        advance(2 * day)
        let failed = await service.earningsHistory(for: ["ALPHA"])
        XCTAssertEqual(failed[0].outcome, .history(first[0].history!, .stale(.network)))
        XCTAssertTrue(failed[0].isStale)
    }

    func testARateLimitOnEitherKindPausesBoth() async {
        let pauseEnds = start.addingTimeInterval(hour)
        do {
            let runner = InstrumentEventsRunnerStub(responses: [
                Self.answer(Self.failure("ALPHA", code: "RATE_LIMIT")),
                Self.answer(Self.success("ALPHA")),
            ])
            let service = makeService(runner: runner)
            let limited = await service.earningsHistory(for: ["ALPHA"])
            let events = await service.events(for: ["ALPHA"], forceRefresh: true)
            let count = await runner.callCount()
            XCTAssertEqual(limited[0].outcome, .failed(.rateLimited(retryAfter: pauseEnds)))
            XCTAssertEqual(events[0].outcome, .failed(.rateLimited(retryAfter: pauseEnds)),
                           "a rate limit on past earnings pauses the events")
            XCTAssertEqual(count, 1)
        }
        do {
            let runner = InstrumentEventsRunnerStub(responses: [
                .output(#"{"error": true, "error_code": "RATE_LIMIT", "message": "invented"}"#),
                Self.answer(Self.history("ALPHA")),
            ])
            let service = makeService(runner: runner)
            _ = await service.events(for: ["ALPHA"])
            let history = await service.earningsHistory(for: ["ALPHA"], forceRefresh: true)
            let count = await runner.callCount()
            XCTAssertEqual(history[0].outcome, .failed(.rateLimited(retryAfter: pauseEnds)),
                           "a rate limit on the events pauses past earnings")
            XCTAssertEqual(count, 1)
            advance(hour + 60)
            let resumed = await service.earningsHistory(for: ["ALPHA"])
            XCTAssertNotNil(resumed[0].history)
        }
    }

    func testEarningsHistoryIsRefusedAsTheEventsAre() async {
        let runner = InstrumentEventsRunnerStub(responses: [Self.answer(Self.history("ALPHA"))])
        let refused = makeService(runner: runner, policy: StockbarProviderAccessPolicy(liveRequestsAllowed: false))
        let results = await refused.earningsHistory(for: ["ALPHA"], forceRefresh: true)
        XCTAssertEqual(results[0].outcome, .failed(.providerDisabled))
        XCTAssertTrue(InstrumentEventsAnswers.allRefused(results))

        // The app's own policy under XCTest isolation refuses too.
        let isolated = makeService(runner: runner, policy: .current)
        let isolatedResults = await isolated.earningsHistory(for: ["ALPHA"])
        XCTAssertEqual(isolatedResults[0].outcome, .failed(.providerDisabled))

        // An acceptance run without the fixture: live providers off, no fixture.
        let clock = self.clock!
        let noFixture = InstrumentEventsService(
            scriptPath: scriptPath, processRunner: runner,
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
            directory: directory, now: { clock.withLock { $0 } }, fixture: nil
        )
        let noFixtureResults = await noFixture.earningsHistory(for: ["ALPHA"])
        XCTAssertEqual(noFixtureResults[0].outcome, .failed(.providerDisabled))
        let count = await runner.callCount()
        XCTAssertEqual(count, 0, "the helper never ran")
    }

    func testRunsOfTheTwoKindsNeverOverlapAndAreNotMistakenForEachOther() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA")),
            Self.answer(Self.history("ALPHA")),
        ])
        await runner.hold()
        let service = makeService(runner: runner)

        let events = Task { await service.events(for: ["ALPHA"]) }
        await runner.waitForCalls(1)
        let history = Task { await service.earningsHistory(for: ["ALPHA"]) }
        await waitUntil { await service.sharedRunWaits == 1 }
        let whileHeld = await runner.callCount()
        XCTAssertEqual(whileHeld, 1, "the second kind waits for the first run to end")
        await runner.release()

        let eventsResults = await events.value
        let historyResults = await history.value
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2, "the history caller ran its own run, not the events one")
        guard calls.count == 2 else { return }
        XCTAssertFalse(calls[0].contains(InstrumentEventsService.earningsHistoryFlag))
        XCTAssertTrue(calls[1].contains(InstrumentEventsService.earningsHistoryFlag))
        XCTAssertNotNil(eventsResults[0].events)
        XCTAssertEqual(historyResults[0].history?.earnings.count, 2)
    }

    func testAnEventsAnswerIsNotReadAsHistoryOrTheOtherWayRound() async {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.success("ALPHA")),
            Self.answer(Self.history("ALPHA")),
        ])
        let service = makeService(runner: runner)
        let history = await service.earningsHistory(for: ["ALPHA"])
        let events = await service.events(for: ["ALPHA"])
        XCTAssertEqual(history[0].outcome, .failed(.scriptFailed("Unreadable answer for ALPHA")))
        XCTAssertEqual(events[0].outcome, .failed(.scriptFailed("Unreadable answer for ALPHA")))
    }

    func testOldEarningsHistoryCopiesAreRemovedAndBrokenOnesToo() async throws {
        let runner = InstrumentEventsRunnerStub(responses: [
            Self.answer(Self.history("ALPHA")),
            Self.answer(Self.history("BETA.L")),
        ])
        let service = makeService(runner: runner)
        _ = await service.earningsHistory(for: ["ALPHA"])
        advance(2 * day)
        _ = await service.earningsHistory(for: ["BETA.L"])
        try Data("not json".utf8).write(to: directory.appendingPathComponent("earnings-history-BROKEN.json"))
        try Data("kept".utf8).write(to: directory.appendingPathComponent("notes.json"))

        advance(29 * day)
        let relaunched = makeService(runner: InstrumentEventsRunnerStub(responses: [.timeout]))
        _ = await relaunched.earningsHistory(for: [])

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["earnings-history-BETA.L.json", "notes.json"])
    }

    func testTheAcceptanceFixtureAnswersPastEarnings() async throws {
        let fixture = try StockbarAcceptanceEventsFixture.decode(Data("""
        {"version": 1, "holdings": [
          {"symbol": "FAKEUS", "epsCurrency": "USD", "pastEarnings": [
            {"daysFromToday": -27, "reportedEPS": 1.52, "estimatedEPS": 1.48, "surprisePercent": 2.7},
            {"daysFromToday": -118, "reportedEPS": 1.54},
            {"daysFromToday": -400, "reportedEPS": 9.99}]},
          {"symbol": "FAKELN.L", "pastEarnings": [{"daysFromToday": -60}]},
          {"symbol": "FAKEFD.L"}]}
        """.utf8))
        let runner = InstrumentEventsRunnerStub(responses: [.output("[]")])
        let clock = self.clock!
        let service = InstrumentEventsService(
            scriptPath: nil, processRunner: runner,
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
            directory: directory, now: { clock.withLock { $0 } }, fixture: fixture
        )
        let results = await service.earningsHistory(for: ["FAKEUS", "FAKELN.L", "FAKEFD.L"])
        let count = await runner.callCount()
        XCTAssertEqual(count, 0, "the helper never runs, and Yahoo is never asked")
        func offset(_ days: Int) throws -> InstrumentEventDay {
            try XCTUnwrap(InstrumentEventDay.on(start.addingTimeInterval(Double(days) * day)))
        }
        let us = try XCTUnwrap(results[0].history)
        XCTAssertEqual(us.epsCurrency, "USD")
        XCTAssertEqual(us.earnings, [
            InstrumentPastEarnings(date: try offset(-118), reportedEPS: 1.54, estimatedEPS: nil, surprisePercent: nil),
            InstrumentPastEarnings(date: try offset(-27), reportedEPS: 1.52, estimatedEPS: 1.48, surprisePercent: 2.7),
        ], "oldest first, and nothing older than a year")
        XCTAssertEqual(results[1].history?.earnings.map(\.reportedEPS), [nil])
        XCTAssertNil(results[1].history?.epsCurrency)
        XCTAssertEqual(results[2].outcome, .failed(.noData), "a holding without past earnings has no data")
        // The events answer for the same fixture is unchanged.
        let events = await service.events(for: ["FAKEUS"])
        XCTAssertNotNil(events[0].events)
    }

    func testAnOlderFixtureWithoutPastEarningsStillReads() throws {
        let fixture = try StockbarAcceptanceEventsFixture.decode(Data("""
        {"version": 1, "holdings": [{"symbol": "FAKEUS", "earningsInDays": 9}]}
        """.utf8))
        XCTAssertNil(fixture.holdings[0].pastEarnings)
        XCTAssertNil(fixture.holdings[0].epsCurrency)
        // It round-trips, as the bootstrap's copy does.
        let copy = try StockbarAcceptanceEventsFixture.decode(JSONEncoder().encode(fixture))
        XCTAssertEqual(copy, fixture)
        XCTAssertThrowsError(try StockbarAcceptanceEventsFixture.decode(Data("""
        {"version": 1, "holdings": [{"symbol": "REAL", "pastEarnings": []}]}
        """.utf8)))
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition never became true")
    }
}

/// Answers each run with the next response, repeating the last. Can hold a
/// run until released, to show what happens while one is under way.
private actor InstrumentEventsRunnerStub: PythonProcessRunning {
    enum Response: Sendable {
        case output(String)
        case timeout
    }

    private var responses: [Response]
    private var recorded: [[String]] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(arguments: [String], timeoutSeconds: TimeInterval, logContext: String) async throws -> PythonProcessResult {
        recorded.append(arguments)
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        switch response {
        case .output(let text):
            return PythonProcessResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
        case .timeout:
            throw NetworkError.timeout("invented timeout")
        }
    }

    func hold() { holding = true }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func callCount() -> Int { recorded.count }

    func calls() -> [[String]] { recorded }

    func waitForCalls(_ count: Int) async {
        for _ in 0..<2_000 where recorded.count < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
