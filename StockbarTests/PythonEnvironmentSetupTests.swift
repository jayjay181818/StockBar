import XCTest
@testable import Stockbar

/// Runs `PythonEnvironmentSetup` against stand-in scripts, so nothing is
/// downloaded or installed.
@MainActor
final class PythonEnvironmentSetupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonEnvironmentSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSetup(script: String?, liveRequestsAllowed: Bool = true) throws -> PythonEnvironmentSetup {
        var scriptPath: String?
        if let script {
            let url = directory.appendingPathComponent("setup.sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            scriptPath = url.path
        }
        let requirements = directory.appendingPathComponent("requirements.txt")
        try "yfinance==1.2.0\n".write(to: requirements, atomically: true, encoding: .utf8)
        return PythonEnvironmentSetup(
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: liveRequestsAllowed),
            scriptPath: scriptPath,
            requirementsPath: requirements.path,
            supportDirectory: directory.appendingPathComponent("support", isDirectory: true),
            timeoutSeconds: 30
        )
    }

    func testSuccessfulRunPassesTheAppsPathsAndSucceeds() async throws {
        let setup = try makeSetup(script: """
            mkdir -p "$STOCKBAR_SUPPORT_DIR"
            printf '%s\\n%s\\n' "$STOCKBAR_SUPPORT_DIR" "$STOCKBAR_REQUIREMENTS" > "$STOCKBAR_SUPPORT_DIR/received"
            echo "Installing packages..."
            echo "Done."
            """)

        await setup.setUp()

        XCTAssertEqual(setup.state, .succeeded)
        let received = try String(
            contentsOf: directory.appendingPathComponent("support/received"), encoding: .utf8
        ).split(separator: "\n").map(String.init)
        XCTAssertEqual(received, [
            directory.appendingPathComponent("support").path,
            directory.appendingPathComponent("requirements.txt").path,
        ])
    }

    func testFailureReportsTheScriptsLastLines() async throws {
        let setup = try makeSetup(script: """
            echo "Creating environment..."
            echo "Needs uv or Python 3.10 or later." >&2
            exit 1
            """)

        await setup.setUp()

        guard case .failed(let message) = setup.state else {
            return XCTFail("Expected failure, got \(setup.state)")
        }
        XCTAssertTrue(message.contains("Needs uv or Python 3.10 or later."), message)
        XCTAssertFalse(setup.isRunning)
    }

    func testBlockedProviderNeverRunsTheScript() async throws {
        let marker = directory.appendingPathComponent("ran")
        let setup = try makeSetup(script: "touch '\(marker.path)'", liveRequestsAllowed: false)

        await setup.setUp()

        guard case .failed = setup.state else { return XCTFail("Expected failure, got \(setup.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMissingScriptFails() async throws {
        let setup = try makeSetup(script: nil)

        await setup.setUp()

        XCTAssertEqual(setup.state, .failed("The setup script is missing from the app bundle."))
    }

    func testInterpreterSource() {
        let managed = "/Support/python-env/bin/python3"

        XCTAssertEqual(PythonEnvironmentSetup.source(configured: "/x/python3", managedInterpreter: managed) { _ in false }, .configured)
        XCTAssertEqual(PythonEnvironmentSetup.source(configured: nil, managedInterpreter: managed) { $0 == managed }, .stockbar)
        XCTAssertEqual(PythonEnvironmentSetup.source(configured: "", managedInterpreter: managed) { _ in false }, .notSetUp)
    }
}
