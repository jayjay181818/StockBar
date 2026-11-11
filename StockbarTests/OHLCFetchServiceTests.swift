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
