import XCTest
@testable import Stockbar

final class StockbarAcceptancePreflightTests: XCTestCase {
    private var root: URL!
    private let runID = "acceptance-12345678"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptancePreflightTests-(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testIgnoresNormalApplicationLaunch() throws {
        let result = try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar"],
            environment: [:]
        ) { _ in XCTFail("Normal launch must not emit preflight output") }

        XCTAssertNil(result)
    }

    func testPreflightCreatesAndValidatesOnlyIsolatedStorage() throws {
        var output = Data()
        let status = try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar", "--acceptance-preflight"],
            environment: environment
        ) { output.append($0) }

        XCTAssertEqual(status, 0)
        let report = try JSONDecoder().decode(StockbarAcceptancePreflightReport.self, from: output)
        XCTAssertEqual(report.runID, runID)
        XCTAssertEqual(report.root, root.standardizedFileURL.path)
        XCTAssertFalse(report.liveProviderRequestsAllowed)
        XCTAssertTrue(report.keychainService.contains(runID))
        XCTAssertFalse(String(decoding: output, as: UTF8.self).localizedCaseInsensitiveContains("bearer"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".stockbar-acceptance-run").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Application Support/Stockbar/StockbarDataModel.sqlite").path))

        for path in report.resolvedWritablePaths {
            XCTAssertTrue(URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        }
    }

    func testPreflightAllowsRestartOnlyWithMatchingMarker() throws {
        _ = try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar", "--acceptance-preflight"],
            environment: environment
        ) { _ in }

        XCTAssertNoThrow(try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar", "--acceptance-preflight"],
            environment: environment
        ) { _ in })
    }

    func testBootstrapStoresOnlyLoopbackConfigurationInIsolatedDefaultsAndKeychain() throws {
        let manifestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptanceManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestRoot) }
        let tokenFile = manifestRoot.appendingPathComponent("token")
        try Data("synthetic-acceptance-token".utf8).write(to: tokenFile, options: .atomic)
        let manifest = manifestRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: [
            "baseURL": "http://127.0.0.1:49152",
            "tokenFile": tokenFile.path
        ]).write(to: manifest, options: .atomic)
        var bootstrapEnvironment = environment
        bootstrapEnvironment["STOCKBAR_FOLYNC_MANIFEST"] = manifest.path
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: bootstrapEnvironment)
        defer { try? FolyncCredentialStore(service: runtime.folyncKeychainService).delete() }

        var output = Data()
        XCTAssertEqual(try StockbarAcceptancePreflight.bootstrapIfRequested(
            arguments: ["Stockbar", "--acceptance-bootstrap"],
            environment: bootstrapEnvironment
        ) { output.append($0) }, 0)

        let report = try JSONDecoder().decode(StockbarAcceptanceBootstrapReport.self, from: output)
        XCTAssertTrue(report.configured)
        XCTAssertEqual(Set(report.enabledRoutes), Set(FolyncSupplementalRoute.allCases.map(\.rawValue)))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: runtime.defaultsSuiteName!))
        let settings = FolyncSettingsStore(defaults: defaults).load()
        XCTAssertEqual(settings.baseURL, "http://127.0.0.1:49152")
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.supplemental.allowLegacyFallback)
        XCTAssertEqual(try FolyncCredentialStore(service: runtime.folyncKeychainService).load(), "synthetic-acceptance-token")
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("synthetic-acceptance-token"))
    }

    private var environment: [String: String] {
        [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": runID,
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]
    }
}
