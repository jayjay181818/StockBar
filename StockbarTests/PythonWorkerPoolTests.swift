import Darwin
import os
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
            open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "started"), "w").close()
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

    /// Waits for the `--sleep` script to report that it is running, rather
    /// than sleeping for a fixed time and hoping it has started.
    private func waitUntilSleepStarted() async throws {
        let marker = directory.appendingPathComponent("started")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("The slow script never started")
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
        try await waitUntilSleepStarted()
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

    func testAnIdleWorkerStopsAfterTheIdleTimeoutAndSoDoesTheOneThatReplacesIt() async throws {
        pool = PythonWorkerPool(maxWorkers: 1, idleTimeout: { .seconds(1) })
        let runner = makeRunner()
        let (idle, _) = try await run(runner, [])
        let pooled = await pool.workerCount
        XCTAssertEqual(pooled, 1, "The request must have been served by a pooled worker, not a one-off process")

        let stopped = try await waitUntilGone(idle.pid)

        XCTAssertTrue(stopped, "A worker nobody is using must give its memory back")
        let workerCount = await pool.workerCount
        XCTAssertEqual(workerCount, 0)
        let (fresh, _) = try await run(runner, ["--json", "AAPL"])
        XCTAssertNotEqual(fresh.pid, idle.pid)
        XCTAssertEqual(fresh.args, ["--json", "AAPL"])
        // The first stop ended the pool's idle check; the new worker must restart
        // it, or only the first worker of a session would ever stop.
        let stoppedAgain = try await waitUntilGone(fresh.pid)
        XCTAssertTrue(stoppedAgain, "Every later worker must stop when idle too")
    }

    func testAWorkerUsedAgainWithinTheIdleTimeoutKeepsRunning() async throws {
        pool = PythonWorkerPool(maxWorkers: 1, idleTimeout: { .seconds(3) })
        let runner = makeRunner()
        let (first, _) = try await run(runner, [])

        // Each gap is well inside the timeout; together they outlast it. A
        // refresh interval shorter than the timeout must not restart the worker.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(700))
            let (next, _) = try await run(runner, [])
            XCTAssertEqual(next.pid, first.pid)
        }
    }

    func testAShortenedIdleTimeoutAppliesAtOnce() async throws {
        let timeout = OSAllocatedUnfairLock(initialState: Duration.seconds(10 * 60))
        pool = PythonWorkerPool(maxWorkers: 1, idleTimeout: { timeout.withLock { $0 } })
        let runner = makeRunner()
        let (idle, _) = try await run(runner, [])

        // The pool's idle check is now asleep for a quarter of ten minutes.
        timeout.withLock { $0 = .seconds(1) }
        await pool.idleTimeoutChanged()

        let stopped = try await waitUntilGone(idle.pid)
        XCTAssertTrue(stopped, "Turning the setting on must not wait out the old timeout")
        let workerCount = await pool.workerCount
        XCTAssertEqual(workerCount, 0)
    }

    func testALengthenedIdleTimeoutKeepsTheWorkerThatIsIdleNow() async throws {
        let timeout = OSAllocatedUnfairLock(initialState: Duration.seconds(1))
        pool = PythonWorkerPool(maxWorkers: 1, idleTimeout: { timeout.withLock { $0 } })
        let runner = makeRunner()
        let (idle, _) = try await run(runner, [])

        // Turned off while a worker is idle and the short check is pending.
        timeout.withLock { $0 = .seconds(10 * 60) }
        await pool.idleTimeoutChanged()

        try await Task.sleep(for: .milliseconds(1_500))
        let (again, _) = try await run(runner, [])
        XCTAssertEqual(again.pid, idle.pid, "Turning the setting off must keep the worker that would have stopped")
    }

    func testTheAppsPoolFollowsTheQuitWhenIdleSetting() async throws {
        // Under XCTest the app's store is an isolated suite. The switch in
        // Settings writes to this store, and the app's pool must read it.
        guard StockbarRuntimeStorage.acceptance.defaultsSuiteName != nil else {
            return XCTFail("Tests must not run against the real defaults")
        }
        let defaults = StockbarRuntimeStorage.userDefaults
        let key = PythonWorkerPool.quitWhenIdleKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(true, forKey: key)
        // The pool stops a worker between one and one and a quarter timeouts
        // after its last request.
        let on = await PythonWorkerPool.shared.idleTimeout
        XCTAssertGreaterThan(on, .seconds(60 + 5), "The shortest refresh interval, plus its timer tolerance, must reuse its worker")
        XCTAssertLessThan(on * 5 / 4, .seconds(5 * 60), "At the default refresh interval the worker must exit between refreshes")

        // Never set: on, the same as a store where it was turned on.
        defaults.removeObject(forKey: key)
        XCTAssertTrue(PythonWorkerPool.quitWhenIdleDefault)
        XCTAssertTrue(PythonWorkerPool.quitsWhenIdle(in: defaults))
        let unset = await PythonWorkerPool.shared.idleTimeout
        XCTAssertEqual(unset, on, "Never changed, the setting is on")

        defaults.set(false, forKey: key)
        XCTAssertFalse(PythonWorkerPool.quitsWhenIdle(in: defaults))
        let off = await PythonWorkerPool.shared.idleTimeout
        XCTAssertEqual(off, .seconds(15 * 60), "Turned off, the app's pool must keep its workers for 15 minutes without a restart")

        let unconfigured = await PythonWorkerPool().idleTimeout
        XCTAssertEqual(unconfigured, off, "A pool that is given no timeout keeps its workers for 15 minutes")

        XCTAssertEqual(SettingsTransferKeys.settingsKeys[key], .bool, "The setting travels with an export")
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
        try await waitUntilSleepStarted()

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
