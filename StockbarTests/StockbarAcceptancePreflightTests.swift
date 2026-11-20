import XCTest
@testable import Stockbar

final class StockbarAcceptancePreflightTests: XCTestCase {
    private var root: URL!
    private let runID = "acceptance-12345678"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptancePreflightTests-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertTrue(report.loopbackFolyncAllowed)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(#""loopbackFolyncAllowed" : true"#))
        XCTAssertTrue(report.keychainService.contains(runID))
        XCTAssertEqual(report.launchOptions, .none)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).localizedCaseInsensitiveContains("bearer"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".stockbar-acceptance-run").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Application Support/Stockbar/StockbarDataModel.sqlite").path))

        for path in report.resolvedWritablePaths {
            XCTAssertTrue(URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        }
    }

    func testPreflightRecordsTheLaunchOptionsTheAppWillApply() throws {
        var environment = environment
        environment["STOCKBAR_ACCEPTANCE_APPEARANCE"] = "dark"
        environment["STOCKBAR_ACCEPTANCE_SECTION"] = "allocation"
        environment["STOCKBAR_ACCEPTANCE_CURRENCY"] = "nope"
        var output = Data()
        _ = try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar", "--acceptance-preflight"],
            environment: environment
        ) { output.append($0) }

        let report = try JSONDecoder().decode(StockbarAcceptancePreflightReport.self, from: output)
        XCTAssertEqual(report.launchOptions, StockbarAcceptanceLaunchOptions(appearance: .dark, section: "allocation"))
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains(#""appearance" : "dark""#))
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

    func testBootstrapLeavesLoopbackConfigurationInASeedAndTheTokenInKeychain() throws {
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
        XCTAssertEqual(report.scopeID, "all")
        XCTAssertEqual(Set(report.enabledRoutes), Set(FolyncSupplementalRoute.allCases.map(\.rawValue)))
        let seedURL = try XCTUnwrap(runtime.folyncSettingsSeedURL)
        let seedData = try Data(contentsOf: seedURL)
        let settings = try JSONDecoder().decode(FolyncStoredSettings.self, from: seedData)
        XCTAssertEqual(settings.baseURL, "http://127.0.0.1:49152")
        XCTAssertTrue(settings.isEnabled)
        XCTAssertFalse(settings.supplemental.allowLegacyFallback)
        XCTAssertEqual(try FolyncCredentialStore(service: runtime.folyncKeychainService).load(), "synthetic-acceptance-token")
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("synthetic-acceptance-token"))
        XCTAssertFalse(String(decoding: seedData, as: UTF8.self).contains("synthetic-acceptance-token"))
    }

    func testBootstrapRefusesAnEndpointOffThisMacAndWritesNoSeed() throws {
        let manifestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptanceManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manifestRoot) }
        let tokenFile = manifestRoot.appendingPathComponent("token")
        try Data("synthetic-acceptance-token".utf8).write(to: tokenFile, options: .atomic)
        let manifest = manifestRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: [
            "baseURL": "http://folync.invalid:49152",
            "tokenFile": tokenFile.path
        ]).write(to: manifest, options: .atomic)
        var bootstrapEnvironment = environment
        bootstrapEnvironment["STOCKBAR_FOLYNC_MANIFEST"] = manifest.path
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: bootstrapEnvironment)

        XCTAssertThrowsError(try StockbarAcceptancePreflight.bootstrapIfRequested(
            arguments: ["Stockbar", "--acceptance-bootstrap"],
            environment: bootstrapEnvironment
        ) { _ in XCTFail("A refused bootstrap must not report") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runtime.folyncSettingsSeedURL).path))
    }

    private var environment: [String: String] {
        [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": runID,
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]
    }
}

/// The Folync settings an acceptance run starts with travel from the bootstrap
/// to the app in a seed file, and the app writes them into its own defaults.
/// A unit test cannot show why (a test process creates its own keys); these
/// show who writes what, and that nothing but an explicit acceptance run
/// looks for a seed.
final class StockbarAcceptanceSeededSettingsTests: XCTestCase {
    private static let settingsKey = "folync.portfolio-source.settings.v2"
    private var root: URL!
    private var manifestRoot: URL!
    private var runID: String!
    /// Resolved before anything is in the root, as the harness's processes do.
    private var runtime: StockbarAcceptanceRuntime!

    override func setUpWithError() throws {
        runID = "acceptance-" + UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptanceSeedTests-\(UUID().uuidString)", isDirectory: true)
        manifestRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptanceSeedManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestRoot, withIntermediateDirectories: true)
        runtime = try StockbarAcceptanceRuntime.resolve(environment: environment)
    }

    override func tearDownWithError() throws {
        if let runtime {
            try? FolyncCredentialStore(service: runtime.folyncKeychainService).delete()
            if let suiteName = runtime.defaultsSuiteName {
                UserDefaults(suiteName: suiteName)?.removeObject(forKey: Self.settingsKey)
            }
        }
        for directory in [root, manifestRoot].compactMap({ $0 }) where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Bootstrap

    func testBootstrapWritesAnOwnerOnlySeedInsideTheRootAndNothingIntoTheSuite() throws {
        let runtime = try bootstrap(baseURL: "http://127.0.0.1:49152")

        let seedURL = try XCTUnwrap(runtime.folyncSettingsSeedURL)
        XCTAssertTrue(seedURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertFalse(seedURL.path.contains("/Library/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: seedURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try seedFiles(), [seedURL.lastPathComponent], "the temporary file is renamed, not left behind")

        let seeded = try JSONDecoder().decode(FolyncStoredSettings.self, from: Data(contentsOf: seedURL))
        XCTAssertEqual(seeded, expectedSettings(baseURL: "http://127.0.0.1:49152"))

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Preferences", isDirectory: true).path
        ), "the bootstrap must not create the defaults suite")
        XCTAssertNil(try suite(runtime).object(forKey: Self.settingsKey))
    }

    func testPreflightWritesNothingIntoTheSuite() throws {
        XCTAssertEqual(try StockbarAcceptancePreflight.runIfRequested(
            arguments: ["Stockbar", "--acceptance-preflight"],
            environment: environment
        ) { _ in }, 0)

        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.path))
    }

    // MARK: Adoption

    func testAdoptionMovesEverySeededFieldIntoTheSuiteAndRemovesTheSeed() throws {
        let runtime = try bootstrap(baseURL: "http://localhost:49153")
        let defaults = try suite(runtime)

        XCTAssertTrue(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults))

        XCTAssertEqual(FolyncSettingsStore(defaults: defaults).load(), expectedSettings(baseURL: "http://localhost:49153"))
        let stored = try XCTUnwrap(defaults.data(forKey: Self.settingsKey))
        XCTAssertEqual(try JSONDecoder().decode(FolyncStoredSettings.self, from: stored).supplemental,
                       expectedSettings(baseURL: "").supplemental)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runtime.folyncSettingsSeedURL).path))
    }

    func testAdoptionKeepsAnArbitrarySeedExactly() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seeded = FolyncStoredSettings(
            isEnabled: false,
            baseURL: "http://[::1]:49154",
            scopeID: "pf_demo",
            pollingIntervalSeconds: 300,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: false,
                candlestickCharts: true,
                benchmarkMarketData: false,
                exchangeRates: true,
                allowLegacyFallback: true,
                dividends: false,
                tradeAnalysis: true,
                transactions: false
            )
        )
        try JSONEncoder().encode(seeded).write(to: try XCTUnwrap(runtime.folyncSettingsSeedURL))
        let defaults = try suite(runtime)

        XCTAssertTrue(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults))

        XCTAssertEqual(FolyncSettingsStore(defaults: defaults).load(), seeded)
    }

    func testAdoptingTwiceIsHarmless() throws {
        let runtime = try bootstrap(baseURL: "http://127.0.0.1:49152")
        let defaults = try suite(runtime)
        XCTAssertTrue(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults))
        // The app changes a setting after launch; a second adoption must not undo it.
        FolyncSettingsStore(defaults: defaults).setEnabled(false)

        XCTAssertFalse(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults))

        var expected = expectedSettings(baseURL: "http://127.0.0.1:49152")
        expected.isEnabled = false
        XCTAssertEqual(FolyncSettingsStore(defaults: defaults).load(), expected)
    }

    func testAMissingSeedDoesNothing() throws {
        let defaults = try suite(runtime)

        XCTAssertFalse(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults))

        XCTAssertNil(defaults.object(forKey: Self.settingsKey))
    }

    func testAnUnreadableSeedFailsAndChangesNothing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seedURL = try XCTUnwrap(runtime.folyncSettingsSeedURL)
        try Data("{\"isEnabled\": true".utf8).write(to: seedURL)
        let defaults = try suite(runtime)

        XCTAssertThrowsError(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(
            runtime: runtime, defaults: defaults
        )) { error in
            guard case StockbarAcceptancePreflightError.seedUnreadable = error else {
                return XCTFail("Expected seedUnreadable, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("seed could not be read"))
        }
        XCTAssertNil(defaults.object(forKey: Self.settingsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedURL.path))
    }

    func testASeedThatIsNotARegularFileFails() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = manifestRoot.appendingPathComponent("elsewhere.json")
        try JSONEncoder().encode(expectedSettings(baseURL: "http://127.0.0.1:49152")).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: try XCTUnwrap(runtime.folyncSettingsSeedURL),
            withDestinationURL: target
        )
        let defaults = try suite(runtime)

        XCTAssertThrowsError(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults)) { error in
            guard case StockbarAcceptancePreflightError.seedUnreadable = error else {
                return XCTFail("Expected seedUnreadable, got \(error)")
            }
        }
        XCTAssertNil(defaults.object(forKey: Self.settingsKey))
    }

    func testASeedNamingAFolyncOffThisMacIsRefused() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seedURL = try XCTUnwrap(runtime.folyncSettingsSeedURL)
        try JSONEncoder().encode(expectedSettings(baseURL: "https://folync.invalid")).write(to: seedURL)
        let defaults = try suite(runtime)

        XCTAssertThrowsError(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: runtime, defaults: defaults)) { error in
            guard case StockbarAcceptancePreflightError.unsafeEndpoint = error else {
                return XCTFail("Expected unsafeEndpoint, got \(error)")
            }
        }
        XCTAssertNil(defaults.object(forKey: Self.settingsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedURL.path))
    }

    func testLoopbackEndpointRule() {
        for allowed in ["http://127.0.0.1:1", "http://localhost:2", "http://LOCALHOST:3", "http://[::1]:4"] {
            XCTAssertTrue(StockbarAcceptancePreflight.isLoopbackFolyncEndpoint(allowed), allowed)
        }
        for refused in [
            "https://127.0.0.1:1", "http://user:pass@127.0.0.1:1", "http://user@localhost:1",
            "http://127.0.0.2:1", "http://folync.invalid", "http://localhost.invalid:1", "", "not a url"
        ] {
            XCTAssertFalse(StockbarAcceptancePreflight.isLoopbackFolyncEndpoint(refused), refused)
        }
    }

    // MARK: Only an explicit acceptance run

    func testANormalLaunchNeverLooksForASeed() throws {
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [:])
        XCTAssertNil(runtime.folyncSettingsSeedURL)
        var defaultsRequested = false

        XCTAssertFalse(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(
            runtime: runtime,
            defaults: { defaultsRequested = true; return UserDefaults.standard }()
        ))
        XCTAssertFalse(defaultsRequested)
    }

    func testAutomaticTestIsolationNeverAdoptsASeed() throws {
        let runtime = try StockbarAcceptanceRuntime.resolveCurrent(
            environment: [:],
            uniqueSuffix: UUID().uuidString.lowercased(),
            isRunningUnderXCTest: true
        )
        XCTAssertFalse(runtime.isExplicitAcceptanceRun)
        let isolatedRoot = try XCTUnwrap(runtime.root)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        let seedURL = try XCTUnwrap(runtime.folyncSettingsSeedURL)
        try JSONEncoder().encode(expectedSettings(baseURL: "http://127.0.0.1:49152")).write(to: seedURL)
        var defaultsRequested = false

        XCTAssertFalse(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(
            runtime: runtime,
            defaults: { defaultsRequested = true; return UserDefaults.standard }()
        ))
        XCTAssertFalse(defaultsRequested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedURL.path))
    }

    func testARunWithoutTheLoopbackExceptionNeverAdoptsASeed() throws {
        let explicit: StockbarAcceptanceRuntime = runtime
        let withoutException = StockbarAcceptanceRuntime(
            root: explicit.root,
            runID: explicit.runID,
            folyncKeychainService: explicit.folyncKeychainService,
            liveProviderRequestsAllowed: false,
            loopbackFolyncAllowed: false
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seedURL = try XCTUnwrap(withoutException.folyncSettingsSeedURL)
        try JSONEncoder().encode(expectedSettings(baseURL: "http://127.0.0.1:49152")).write(to: seedURL)
        let defaults = try suite(explicit)

        XCTAssertFalse(try StockbarAcceptancePreflight.adoptSeededSettingsIfPresent(runtime: withoutException, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: Self.settingsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedURL.path))
    }

    // MARK: Helpers

    private var environment: [String: String] {
        [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": runID,
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]
    }

    private func expectedSettings(baseURL: String) -> FolyncStoredSettings {
        FolyncStoredSettings(
            isEnabled: true,
            baseURL: baseURL,
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: true,
                candlestickCharts: true,
                benchmarkMarketData: true,
                exchangeRates: true,
                allowLegacyFallback: false,
                dividends: true,
                tradeAnalysis: true,
                transactions: true
            )
        )
    }

    private func suite(_ runtime: StockbarAcceptanceRuntime) throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: XCTUnwrap(runtime.defaultsSuiteName)))
    }

    private func seedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("seed") }
    }

    /// Runs `--acceptance-bootstrap` against a manifest for `baseURL`, as the
    /// harness does, and returns the run's runtime.
    private func bootstrap(baseURL: String) throws -> StockbarAcceptanceRuntime {
        let tokenFile = manifestRoot.appendingPathComponent("token")
        try Data("synthetic-acceptance-token".utf8).write(to: tokenFile, options: .atomic)
        let manifest = manifestRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["baseURL": baseURL, "tokenFile": tokenFile.path])
            .write(to: manifest, options: .atomic)
        var bootstrapEnvironment = environment
        bootstrapEnvironment["STOCKBAR_FOLYNC_MANIFEST"] = manifest.path
        XCTAssertEqual(try StockbarAcceptancePreflight.bootstrapIfRequested(
            arguments: ["Stockbar", "--acceptance-bootstrap"],
            environment: bootstrapEnvironment
        ) { _ in }, 0)
        return runtime
    }
}
