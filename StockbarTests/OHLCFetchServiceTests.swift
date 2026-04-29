import XCTest
@testable import Stockbar

final class OHLCFetchServiceTests: XCTestCase {
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

    func fetchSnapshots(symbol: String, startDate: Date?, endDate: Date?) async throws -> [OHLCSnapshot] {
        saved.filter { $0.symbol == symbol }
    }

    func savedSnapshots() -> [OHLCSnapshot] {
        saved
    }
}
