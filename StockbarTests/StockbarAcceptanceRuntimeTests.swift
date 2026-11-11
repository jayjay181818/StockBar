import CoreData
import XCTest
@testable import Stockbar

final class StockbarAcceptanceRuntimeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarAcceptanceRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testProductionRuntimeKeepsNormalServiceAndProviderAccess() throws {
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [:])

        XCTAssertFalse(runtime.isEnabled)
        XCTAssertNil(runtime.root)
        XCTAssertEqual(runtime.folyncKeychainService, "com.stockbar.folync")
        XCTAssertEqual(runtime.credentialsKeychainService, "com.stockbar.credentials")
        XCTAssertTrue(runtime.liveProviderRequestsAllowed)
    }

    func testCurrentProcessRuntimeAutomaticallyIsolatesXCTest() throws {
        // Given: An XCTest process without explicit acceptance variables.
        let environment = ["XCTestConfigurationFilePath": "/tmp/StockbarTests.xctestconfiguration"]

        // When: Resolving the runtime used by process-wide singletons.
        let runtime = try StockbarAcceptanceRuntime.resolveCurrent(
            environment: environment,
            fileManager: .default,
            processIdentifier: 4242,
            uniqueSuffix: "run-0001"
        )

        // Then: Every process-wide writer is rooted in a per-run temporary test domain.
        XCTAssertTrue(runtime.isEnabled)
        XCTAssertEqual(runtime.runID, "xctest-4242-run-0001")
        XCTAssertFalse(runtime.liveProviderRequestsAllowed)
        XCTAssertEqual(
            runtime.defaultsSuiteName,
            try runtime.root.unwrap().appendingPathComponent("Preferences/com.stockbar.acceptance.xctest-4242-run-0001").path
        )
        XCTAssertEqual(
            runtime.folyncKeychainService,
            "com.stockbar.folync.acceptance.xctest-4242-run-0001"
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        XCTAssertTrue(try runtime.root.unwrap().standardizedFileURL.path.hasPrefix(temporaryRoot))
        XCTAssertTrue(try runtime.cacheRoot.unwrap().isDescendant(of: runtime.root.unwrap()))
    }

    func testAutomaticXCTestRunIDsDifferForReusedProcessIdentifiers() throws {
        // Given: Two runs that happen to get the same PID.
        let environment = ["XCTestConfigurationFilePath": "/tmp/StockbarTests.xctestconfiguration"]

        // When: Resolving with the default (random) suffix.
        let first = try StockbarAcceptanceRuntime.resolveCurrent(environment: environment, processIdentifier: 4242)
        let second = try StockbarAcceptanceRuntime.resolveCurrent(environment: environment, processIdentifier: 4242)

        // Then: They never share a root, defaults suite or Keychain namespace, and the ID stays valid.
        XCTAssertNotEqual(first.runID, second.runID)
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertNotEqual(first.folyncKeychainService, second.folyncKeychainService)
        XCTAssertTrue(try XCTUnwrap(first.runID).count <= 64)
    }

    func testAutomaticXCTestCleanupRemovesRootButNeverExplicitAcceptanceRoots() throws {
        // Given: An automatic XCTest runtime with files in its root.
        let environment = ["XCTestConfigurationFilePath": "/tmp/StockbarTests.xctestconfiguration"]
        let automatic = try StockbarAcceptanceRuntime.resolveCurrent(environment: environment, processIdentifier: 4242)
        let automaticRoot = try automatic.root.unwrap()
        try FileManager.default.createDirectory(at: automaticRoot, withIntermediateDirectories: true)

        // When: The cleanup runs.
        automatic.removeAutomaticTestArtifacts()

        // Then: The automatic root is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: automaticRoot.path))

        // And: An explicit acceptance runtime is left alone.
        let explicit = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        explicit.removeAutomaticTestArtifacts()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testCurrentProcessRuntimePrefersExplicitAcceptanceEnvironmentDuringXCTest() throws {
        // Given: XCTest plus the explicit combined-acceptance environment.
        let environment = [
            "XCTestConfigurationFilePath": "/tmp/StockbarTests.xctestconfiguration",
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]

        // When: Resolving the process-wide runtime.
        let runtime = try StockbarAcceptanceRuntime.resolveCurrent(
            environment: environment,
            fileManager: .default,
            processIdentifier: 4242
        )

        // Then: The caller-provided acceptance identity wins over automatic XCTest isolation.
        XCTAssertEqual(runtime.root, root.standardizedFileURL)
        XCTAssertEqual(runtime.runID, "acceptance-12345678")
    }

    func testAcceptanceRuntimeConfinesAllResolvedStorageAndDisablesProviders() throws {
        let runID = "acceptance-12345678"
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": runID,
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])

        XCTAssertTrue(runtime.isEnabled)
        XCTAssertEqual(runtime.root, root.standardizedFileURL)
        XCTAssertEqual(runtime.folyncKeychainService, "com.stockbar.folync.acceptance.\(runID)")
        XCTAssertEqual(runtime.credentialsKeychainService, "com.stockbar.credentials.acceptance.\(runID)")
        XCTAssertFalse(runtime.liveProviderRequestsAllowed)
        XCTAssertTrue(try runtime.applicationSupportRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.bundleApplicationSupportRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.cacheRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.coreDataStoreURL.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.folyncSnapshotCacheRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.folyncSupplementalCacheRoot.unwrap().isDescendant(of: root))
        XCTAssertEqual(
            runtime.defaultsSuiteName,
            root.standardizedFileURL.appendingPathComponent("Preferences/com.stockbar.acceptance.\(runID)").path
        )
    }

    func testCacheManagerUsesAnExplicitAcceptanceCacheRoot() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)

        XCTAssertTrue(manager.diskCacheDirectory.isDescendant(of: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.diskCacheDirectory.path))
    }

    func testCacheManagerKeepsValuesAcrossInstancesAndReadsFilesFromEarlierVersions() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache-values", isDirectory: true)
        let first = CacheManager(cacheRoot: cacheRoot)
        first.store(["AAPL": 3], forKey: "counts")
        first.flush()

        // A new instance has nothing in memory, so this reads the file.
        let second = CacheManager(cacheRoot: cacheRoot)
        XCTAssertEqual(second.retrieve([String: Int].self, forKey: "counts"), ["AAPL": 3])
        XCTAssertNil(second.retrieve([String: Int].self, forKey: "missing"))

        // The layout the tiered cache wrote: the value as base64 JSON in `data`.
        let legacy = """
        {"key":"old","data":"\(Data("[1,2]".utf8).base64EncodedString())","timestamp":0,"size":5,        "compressionLevel":"light","accessCount":4,"lastAccessed":0}
        """
        try Data(legacy.utf8).write(to: second.diskCacheDirectory.appendingPathComponent("old.cache"))
        XCTAssertEqual(second.retrieve([Int].self, forKey: "old"), [1, 2])

        second.remove(forKey: "counts")
        second.flush()
        XCTAssertNil(CacheManager(cacheRoot: cacheRoot).retrieve([String: Int].self, forKey: "counts"))

        // An unreadable file is removed, not left to fail on every launch.
        let broken = second.diskCacheDirectory.appendingPathComponent("broken.cache")
        try Data("not json".utf8).write(to: broken)
        XCTAssertNil(second.retrieve([Int].self, forKey: "broken"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
    }

    func testAcceptanceRuntimeRequiresCompleteEnvironment() {
        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path
        ]))
        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]))
        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678"
        ]))
    }

    func testAcceptanceRuntimeRejectsUnsafeRootsAndRunIDs() throws {
        let common = [
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]
        for unsafePath in ["/", NSHomeDirectory(), "."] {
            var environment = common
            environment["STOCKBAR_ACCEPTANCE_ROOT"] = unsafePath
            XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: environment))
        }

        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "../../normal-service",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]))

        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("unsafe-acceptance-child").path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]))
    }

    func testMatchingMarkerAllowsSafeRestartButForeignContentsAreRejected() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("existing.txt"))
        let environment = [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ]
        XCTAssertThrowsError(try StockbarAcceptanceRuntime.resolve(environment: environment))

        try FileManager.default.removeItem(at: root.appendingPathComponent("existing.txt"))
        try Data("acceptance-12345678\n".utf8)
            .write(to: root.appendingPathComponent(".stockbar-acceptance-run"), options: .atomic)
        XCTAssertNoThrow(try StockbarAcceptanceRuntime.resolve(environment: environment))
    }

    func testCoreDataUsesAcceptanceSQLiteStoreOutsideXCTest() throws {
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])
        let description = NSPersistentStoreDescription()

        try CoreDataStack.configureStoreDescription(
            description,
            runtime: runtime,
            isRunningUnderXCTest: false,
            fileManager: .default
        )

        XCTAssertEqual(description.type, NSSQLiteStoreType)
        XCTAssertEqual(description.url, runtime.coreDataStoreURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try runtime.applicationSupportRoot.unwrap().path))
    }

    func testSQLitePragmasUseTheDocumentedCoreDataOption() {
        let description = NSPersistentStoreDescription()
        description.type = NSSQLiteStoreType

        CoreDataStack.applySQLiteOptions(to: description)

        let pragmas = description.options[NSSQLitePragmasOption] as? [String: String]
        XCTAssertEqual(pragmas?["journal_mode"], "WAL")
        XCTAssertEqual(pragmas?["synchronous"], "NORMAL")
        XCTAssertEqual(pragmas?["cache_size"], "-8000")
        XCTAssertNil(description.options["temp_store_directory"])
    }
}

private extension Optional {
    func unwrap(file: StaticString = #filePath, line: UInt = #line) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}

private extension URL {
    func isDescendant(of root: URL) -> Bool {
        let candidate = standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        return candidate.hasPrefix(prefix)
    }
}

final class StockbarAutosavePolicyTests: XCTestCase {
    private let production = StockbarAcceptanceRuntime(
        root: nil, runID: nil,
        folyncKeychainService: StockbarAcceptanceRuntime.productionFolyncKeychainService,
        liveProviderRequestsAllowed: true)
    private let acceptance = StockbarAcceptanceRuntime(
        root: URL(fileURLWithPath: "/tmp/stockbar-acceptance-test", isDirectory: true), runID: "run-12345678",
        folyncKeychainService: "com.stockbar.folync.acceptance.run-12345678",
        liveProviderRequestsAllowed: false)

    func testProductionKeepsTheRealAutosaveNames() {
        XCTAssertEqual(StockbarAutosavePolicy.windowFrameName("StockbarMainWindow", acceptance: production), "StockbarMainWindow")
        XCTAssertEqual(StockbarAutosavePolicy.statusItemName("com.stockbar.portfolio", acceptance: production), "com.stockbar.portfolio")
    }

    func testAcceptanceNeverUsesTheProductionAutosaveNames() {
        XCTAssertNil(StockbarAutosavePolicy.windowFrameName("StockbarMainWindow", acceptance: acceptance),
                     "the window frame must not be saved or restored under acceptance")
        let statusName = StockbarAutosavePolicy.statusItemName("com.stockbar.portfolio", acceptance: acceptance)
        XCTAssertNotEqual(statusName, "com.stockbar.portfolio")
        XCTAssertTrue(statusName.hasSuffix(".acceptance.run-12345678"))
    }
}
