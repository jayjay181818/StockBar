import Darwin
import XCTest
@testable import Stockbar

/// Drives the real `stockbar_worker.py` against a stand-in `get_stock_data.py`,
/// so no market-data provider is ever contacted.
final class PythonWorkerPoolTests: XCTestCase {
    private var directory: URL!
    private var pool: PythonWorkerPool!

    private static let interpreter = "/usr/bin/python3"
    private static let workerSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Stockbar/Resources/stockbar_worker.py")

    private static let fakeScript = """
        import json, os, sys, time
        args = sys.argv[1:]
        if args[:1] == ["--sleep"]:
            time.sleep(float(args[1]))
        if args[:1] == ["--fail"]:
            print("bad things", file=sys.stderr)
            sys.exit(3)
        print(json.dumps({"pid": os.getpid(), "args": args, "mark": os.environ.get("STOCKBAR_TEST_MARK")}))
        print("diagnostic", file=sys.stderr)
        """

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.interpreter), "No system Python")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonWorkerPoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.workerSource, to: directory.appendingPathComponent("stockbar_worker.py"))
        try Self.fakeScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        pool = PythonWorkerPool(maxWorkers: 1)
    }

    override func tearDown() async throws {
        await pool?.stopIdleWorkers()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var scriptURL: URL { directory.appendingPathComponent("get_stock_data.py") }

    private func makeRunner(mark: String = "a") -> PythonProcessRunner {
        PythonProcessRunner(
            config: PythonConfiguration(interpreterPath: Self.interpreter, environment: ["STOCKBAR_TEST_MARK": mark]),
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: true),
            workerPool: pool
        )
    }

    private struct Output: Decodable {
        let pid: Int32
        let args: [String]
        let mark: String?
    }

    private func run(_ runner: PythonProcessRunner, _ arguments: [String], timeout: TimeInterval = 20) async throws -> (Output, PythonProcessResult) {
        let result = try await runner.run(arguments: [scriptURL.path] + arguments, timeoutSeconds: timeout, logContext: "worker test")
        let line = (String(bytes: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (try JSONDecoder().decode(Output.self, from: Data(line.utf8)), result)
    }

    private func waitUntilGone(_ pid: Int32) async throws -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testRequestRecognisesOnlyBridgeScriptsWithAWorkerBesideThem() {
        XCTAssertEqual(
            PythonWorkerRequest(arguments: [scriptURL.path, "--json", "AAPL"]),
            PythonWorkerRequest(arguments: [scriptURL.path, "--json", "AAPL"])
        )
        XCTAssertEqual(PythonWorkerRequest(arguments: [scriptURL.path, "--json", "AAPL"])?.arguments, ["--json", "AAPL"])
        XCTAssertNil(PythonWorkerRequest(arguments: ["-c", "print(1)"]))
        XCTAssertNil(PythonWorkerRequest(arguments: [directory.appendingPathComponent("other.py").path]))
        XCTAssertNil(PythonWorkerRequest(arguments: ["/nonexistent/get_stock_data.py"]))
    }

    func testRequestsReuseOneWorkerAndKeepTheScriptProtocol() async throws {
        let runner = makeRunner()

        let (first, firstResult) = try await run(runner, ["--json", "AAPL"])
        let (second, _) = try await run(runner, ["--json", "MSFT"])

        XCTAssertEqual(first.pid, second.pid, "Both requests should be served by the same worker process")
        XCTAssertEqual(first.args, ["--json", "AAPL"])
        XCTAssertEqual(second.args, ["--json", "MSFT"])
        XCTAssertEqual(first.mark, "a")
        XCTAssertEqual(firstResult.exitCode, 0)
        XCTAssertEqual(String(bytes: firstResult.stderr, encoding: .utf8), "diagnostic\n")
        let workerCount = await pool.workerCount
        XCTAssertEqual(workerCount, 1)
    }

    func testExitCodeAndStderrComeBackAndTheWorkerSurvives() async throws {
        let runner = makeRunner()
        let (before, _) = try await run(runner, [])

        let failed = try await runner.run(arguments: [scriptURL.path, "--fail"], timeoutSeconds: 20, logContext: "worker test")
        let (after, _) = try await run(runner, [])

        XCTAssertEqual(failed.exitCode, 3)
        XCTAssertEqual(String(bytes: failed.stderr, encoding: .utf8), "bad things\n")
        XCTAssertTrue(failed.stdout.isEmpty)
        XCTAssertEqual(before.pid, after.pid)
    }

    func testTimeoutStopsTheWorkerAndTheNextRequestStartsAFreshOne() async throws {
        let runner = makeRunner()
        let (warm, _) = try await run(runner, [])

        do {
            _ = try await runner.run(arguments: [scriptURL.path, "--sleep", "30"], timeoutSeconds: 0.5, logContext: "worker test")
            XCTFail("Expected timeout")
        } catch NetworkError.timeout {
            // expected
        }

        let stopped = try await waitUntilGone(warm.pid)
        XCTAssertTrue(stopped, "The timed-out worker must be stopped")
        let (fresh, _) = try await run(runner, [])
        XCTAssertNotEqual(fresh.pid, warm.pid)
    }

    func testCancellationStopsTheWorker() async throws {
        let runner = makeRunner()
        let (warm, _) = try await run(runner, [])
        let scriptPath = scriptURL.path

        let task = Task {
            try await runner.run(arguments: [scriptPath, "--sleep", "30"], timeoutSeconds: 60, logContext: "worker test")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        let stopped = try await waitUntilGone(warm.pid)
        XCTAssertTrue(stopped, "The cancelled worker must be stopped")
    }

    func testChangedEnvironmentReplacesTheWorker() async throws {
        let (old, _) = try await run(makeRunner(mark: "a"), [])

        let (new, _) = try await run(makeRunner(mark: "b"), [])

        XCTAssertEqual(new.mark, "b", "Settings reach the script through the environment, so a change needs a new worker")
        XCTAssertNotEqual(new.pid, old.pid)
        let stopped = try await waitUntilGone(old.pid)
        XCTAssertTrue(stopped)
    }

    func testABusyPoolRunsTheRequestAsItsOwnProcess() async throws {
        let runner = makeRunner()
        let (warm, _) = try await run(runner, [])
        let scriptPath = scriptURL.path
        let slow = Task {
            try await runner.run(arguments: [scriptPath, "--sleep", "1"], timeoutSeconds: 20, logContext: "worker test")
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let (meanwhile, _) = try await run(runner, ["--json", "AAPL"])

        XCTAssertNotEqual(meanwhile.pid, warm.pid, "With the only worker busy, the request must not wait for it")
        XCTAssertEqual(meanwhile.args, ["--json", "AAPL"])
        _ = try await slow.value
    }

    func testABrokenWorkerFallsBackToRunningTheScriptDirectly() async throws {
        try "import sys\nsys.exit(0)\n".write(
            to: directory.appendingPathComponent("stockbar_worker.py"), atomically: true, encoding: .utf8
        )

        let runner = makeRunner()

        let (output, result) = try await run(runner, ["--json", "AAPL"])
        let (again, _) = try await run(runner, ["--json", "MSFT"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(output.args, ["--json", "AAPL"])
        XCTAssertEqual(again.args, ["--json", "MSFT"])
        let workerCount = await pool.workerCount
        XCTAssertEqual(workerCount, 0, "A failed setup is not retried straight away")
    }
}
