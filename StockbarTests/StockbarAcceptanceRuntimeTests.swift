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
        XCTAssertTrue(runtime.liveProviderRequestsAllowed)
    }

    func testCurrentProcessRuntimeAutomaticallyIsolatesXCTest() throws {
        // Given: An XCTest process without explicit acceptance variables.
        let environment = ["XCTestConfigurationFilePath": "/tmp/StockbarTests.xctestconfiguration"]

        // When: Resolving the runtime used by process-wide singletons.
        let runtime = try StockbarAcceptanceRuntime.resolveCurrent(
            environment: environment,
            fileManager: .default,
            processIdentifier: 4242
        )

        // Then: Every process-wide writer is rooted in a deterministic temporary test domain.
        XCTAssertTrue(runtime.isEnabled)
        XCTAssertEqual(runtime.runID, "xctest-4242")
        XCTAssertFalse(runtime.liveProviderRequestsAllowed)
        XCTAssertEqual(runtime.defaultsSuiteName, "com.stockbar.acceptance.xctest-4242")
        XCTAssertEqual(
            runtime.folyncKeychainService,
            "com.stockbar.folync.acceptance.xctest-4242"
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        XCTAssertTrue(try runtime.root.unwrap().standardizedFileURL.path.hasPrefix(temporaryRoot))
        XCTAssertTrue(try runtime.cacheRoot.unwrap().isDescendant(of: runtime.root.unwrap()))
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
        XCTAssertFalse(runtime.liveProviderRequestsAllowed)
        XCTAssertTrue(try runtime.applicationSupportRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.bundleApplicationSupportRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.cacheRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.coreDataStoreURL.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.folyncSnapshotCacheRoot.unwrap().isDescendant(of: root))
        XCTAssertTrue(try runtime.folyncSupplementalCacheRoot.unwrap().isDescendant(of: root))
        XCTAssertEqual(runtime.defaultsSuiteName, "com.stockbar.acceptance.\(runID)")
    }

    func testCacheManagerUsesAnExplicitAcceptanceCacheRoot() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)

        XCTAssertTrue(manager.diskCacheDirectory.isDescendant(of: root))
        XCTAssertTrue(manager.archiveCacheDirectory.isDescendant(of: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.diskCacheDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.archiveCacheDirectory.path))
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
