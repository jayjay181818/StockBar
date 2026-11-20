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
