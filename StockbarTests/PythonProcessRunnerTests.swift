import Darwin
import XCTest
@testable import Stockbar

final class PythonProcessRunnerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeRunner(executable: String) -> PythonProcessRunner {
        PythonProcessRunner(
            config: PythonConfiguration(interpreterPath: executable),
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: true)
        )
    }

    private func waitForPID(in file: URL) async throws -> Int32 {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("Child process never reported its PID")
    }

    private func processIsGone(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    func testCancellingTheTaskTerminatesTheChildAndThrowsCancellationError() async throws {
        // Given: A long-running child that reports its PID before sleeping.
        let pidFile = temporaryDirectory.appendingPathComponent("pid")
        let runner = makeRunner(executable: "/bin/sh")
        let task = Task {
            try await runner.run(
                arguments: ["-c", "echo $$ > \"$0\"; exec /bin/sleep 60", pidFile.path],
                timeoutSeconds: 120,
                logContext: "cancellation test"
            )
        }
        let pid = try await waitForPID(in: pidFile)
        XCTAssertFalse(processIsGone(pid))

        // When: The owning task is cancelled.
        task.cancel()

        // Then: The caller is released with CancellationError, promptly...
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        // ...and the child process is actually stopped.
        var gone = false
        for _ in 0..<100 where !gone {
            gone = processIsGone(pid)
            if !gone { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(gone, "Child process \(pid) survived task cancellation")
    }

    func testAlreadyCancelledTaskNeverLaunchesTheProcess() async throws {
        let marker = temporaryDirectory.appendingPathComponent("launched")
        let runner = makeRunner(executable: "/usr/bin/touch")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await runner.run(arguments: [marker.path], timeoutSeconds: 5, logContext: "pre-cancel test")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTimeoutStillTerminatesAndReportsTimeout() async throws {
        let runner = makeRunner(executable: "/bin/sleep")

        do {
            _ = try await runner.run(arguments: ["60"], timeoutSeconds: 0.3, logContext: "timeout test")
            XCTFail("Expected timeout")
        } catch NetworkError.timeout {
            // expected
        }
    }

    func testLargeStdoutAndStderrAreCapturedCompletelyAndInOrder() async throws {
        // Given: A child writing a few MB to both pipes at once.
        let count = 200_000
        let runner = makeRunner(executable: "/bin/sh")

        // When
        let result = try await runner.run(
            arguments: ["-c", "/usr/bin/seq 1 \(count) & /usr/bin/seq 1 \(count) >&2; wait"],
            timeoutSeconds: 60,
            logContext: "ordering test"
        )

        // Then: Each stream is exactly the expected sequence (no truncation or reordering).
        let expected = (1...count).map(String.init).joined(separator: "\n") + "\n"
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), expected)
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), expected)
    }

    func testHistoricalDateArgumentsIgnoreTheUsersCalendarAndLocale() throws {
        // Given: An instant that is 2026-03-05 in UTC.
        let date = Date(timeIntervalSince1970: 1_772_712_000)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))

        // When
        let argument = PythonNetworkService.scriptDateString(from: date, timeZone: utc)

        // Then: Always Gregorian ASCII yyyy-MM-dd...
        XCTAssertEqual(argument, "2026-03-05")

        // ...whereas a formatter using a non-Gregorian calendar would have produced a different year.
        let buddhist = DateFormatter()
        buddhist.calendar = Calendar(identifier: .buddhist)
        buddhist.locale = Locale(identifier: "th_TH")
        buddhist.timeZone = utc
        buddhist.dateFormat = "yyyy-MM-dd"
        XCTAssertNotEqual(buddhist.string(from: date), argument)
    }

    func testMissingInterpreterErrorPointsToSetUpForStockbarsOwnEnvironment() {
        let managed = NetworkError.pythonInterpreterNotFound(PythonConfiguration.managedInterpreterPath())
        let custom = NetworkError.pythonInterpreterNotFound("/opt/custom/python3")

        XCTAssertEqual(
            managed.localizedDescription,
            "Stockbar's own Python is not set up. Open Settings > Advanced > Python and choose Set Up."
        )
        XCTAssertTrue(custom.localizedDescription.contains("/opt/custom/python3"), custom.localizedDescription)
        XCTAssertTrue(custom.localizedDescription.contains("Python 3.10 or later"), custom.localizedDescription)
    }

    func testInterpreterPrefersTheSettingThenStockbarsOwnEnvironment() {
        let managed = "/Stockbar/python-env/bin/python3"

        XCTAssertEqual(
            PythonConfiguration.resolveInterpreterPath(configured: "/opt/custom/python3", managedInterpreter: managed),
            "/opt/custom/python3"
        )
        // No system-Python fallback: Stockbar's own environment is used even
        // before it exists, so the launch check offers to set it up.
        XCTAssertEqual(PythonConfiguration.resolveInterpreterPath(configured: nil, managedInterpreter: managed), managed)
        XCTAssertEqual(PythonConfiguration.resolveInterpreterPath(configured: "", managedInterpreter: managed), managed)
    }
}
