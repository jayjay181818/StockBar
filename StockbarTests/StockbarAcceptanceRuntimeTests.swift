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

    func testBenchmarkRefreshIsOnlyForAnAcceptanceRunWithProvidersOff() throws {
        let acceptance = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])
        let asked = [
            BenchmarkRefreshSettings.enabledKey: "1",
            BenchmarkRefreshSettings.passesKey: "4",
            BenchmarkRefreshSettings.spacingKey: "30"
        ]
        XCTAssertEqual(
            BenchmarkRefreshSettings.make(environment: asked, runtime: acceptance),
            BenchmarkRefreshSettings(passes: 4, spacing: 30)
        )

        // The app outside an acceptance run never takes it, whatever its environment says.
        let production = try StockbarAcceptanceRuntime.resolve(environment: [:])
        XCTAssertNil(BenchmarkRefreshSettings.make(environment: asked, runtime: production))

        // Not asked for, or asked for with figures it does not accept.
        XCTAssertNil(BenchmarkRefreshSettings.make(environment: [:], runtime: acceptance))
        let refused = [
            (BenchmarkRefreshSettings.enabledKey, "0"),
            (BenchmarkRefreshSettings.passesKey, "0"),
            (BenchmarkRefreshSettings.passesKey, "many"),
            (BenchmarkRefreshSettings.spacingKey, "1"),
            (BenchmarkRefreshSettings.spacingKey, "")
        ]
        for (key, value) in refused {
            var environment = asked
            environment[key] = value
            XCTAssertNil(BenchmarkRefreshSettings.make(environment: environment, runtime: acceptance), "\(key)=\(value)")
        }
    }

    func testBenchmarkQuotesAreRefusedUntilArmedAndThenMoveWithEachBatch() async throws {
        let service = BenchmarkQuoteService(policy: StockbarProviderAccessPolicy(liveRequestsAllowed: false))
        do {
            _ = try await service.fetchBatchQuotes(for: ["AAPL"])
            XCTFail("Quotes before arm() must be refused as in any acceptance run")
        } catch let error as ProviderAccessError {
            XCTAssertEqual(error, .disabledForAcceptance(.python))
        }

        await service.arm()
        let first = try await service.fetchBatchQuotes(for: ["AAPL", "MSFT"])
        let second = try await service.fetchBatchQuotes(for: ["AAPL", "MSFT"])
        XCTAssertEqual(first.map(\.symbol), ["AAPL", "MSFT"])
        XCTAssertNotEqual(first[0].regularMarketPrice, second[0].regularMarketPrice)
        XCTAssertEqual(first[0].regularMarketPreviousClose, second[0].regularMarketPreviousClose)
        XCTAssertNotEqual(first[0].regularMarketPreviousClose, first[1].regularMarketPreviousClose)
        for quote in first + second {
            XCTAssertTrue((40..<400).contains(quote.regularMarketPreviousClose), quote.symbol)
            XCTAssertGreaterThan(quote.regularMarketPrice, quote.regularMarketPreviousClose)
            XCTAssertEqual(quote.displayPrice, quote.regularMarketPrice)
            XCTAssertNil(quote.failure)
        }
        // The same symbol gets the same price in every launch.
        XCTAssertEqual(
            BenchmarkQuoteService.quote(for: "AAPL", batch: 1, time: 0).regularMarketPrice,
            first[0].regularMarketPrice
        )

        // History is not part of the workload.
        do {
            _ = try await service.fetchHistoricalData(for: "AAPL", from: .distantPast, to: Date())
            XCTFail("History must stay refused")
        } catch let error as ProviderAccessError {
            XCTAssertEqual(error, .disabledForAcceptance(.python))
        }
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

    func testCacheManagerLeavesTheFileAloneWhenTheStoredValueIsUnchanged() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache-unchanged", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)
        let file = manager.diskCacheDirectory.appendingPathComponent("dates.cache")
        // A rewrite replaces the file, so it gets a new file number, and stamps it with a new time.
        func fileNumber() throws -> UInt64? {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        func dates(insertedInReverse: Bool) -> [String: Date] {
            // Twenty keys, so that two encodings would not order them alike by chance.
            let indices = insertedInReverse ? Array((0..<20).reversed()) : Array(0..<20)
            var result: [String: Date] = [:]
            for index in indices {
                result["SYM\(index)"] = Date(timeIntervalSinceReferenceDate: Double(index) * 86_400.5)
            }
            return result
        }

        manager.store(dates(insertedInReverse: false), forKey: "dates")
        manager.flush()
        let written = try Data(contentsOf: file)
        let writtenNumber = try fileNumber()

        // The value is encoded with its keys in order. That is what makes two
        // encodings of a dictionary the same bytes: left unsorted, the order
        // varies with where the encoder's memory happens to be.
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let payload = try XCTUnwrap((envelope["data"] as? String).flatMap { Data(base64Encoded: $0) })
        let keysAsWritten = try XCTUnwrap(String(data: payload, encoding: .utf8))
            .split(separator: "\"").filter { $0.hasPrefix("SYM") }.map(String.init)
        XCTAssertEqual(keysAsWritten.count, 20)
        XCTAssertEqual(keysAsWritten, keysAsWritten.sorted())

        // The same value again, as other dictionaries built in another order.
        XCTAssertEqual(dates(insertedInReverse: true), dates(insertedInReverse: false))
        for _ in 0..<5 {
            manager.store(dates(insertedInReverse: true), forKey: "dates")
        }
        manager.flush()
        XCTAssertEqual(try Data(contentsOf: file), written)
        XCTAssertEqual(try fileNumber(), writtenNumber)

        // A changed value is written.
        var changed = dates(insertedInReverse: false)
        changed["SYM3"] = Date(timeIntervalSinceReferenceDate: 1)
        manager.store(changed, forKey: "dates")
        manager.flush()
        XCTAssertNotEqual(try fileNumber(), writtenNumber)
        XCTAssertEqual(CacheManager(cacheRoot: cacheRoot).retrieve([String: Date].self, forKey: "dates"), changed)

        // A value read from its file counts as held: storing it again writes nothing.
        let second = CacheManager(cacheRoot: cacheRoot)
        XCTAssertEqual(second.retrieve([String: Date].self, forKey: "dates"), changed)
        let read = try Data(contentsOf: file)
        let readNumber = try fileNumber()
        second.store(changed, forKey: "dates")
        second.flush()
        XCTAssertEqual(try Data(contentsOf: file), read)
        XCTAssertEqual(try fileNumber(), readNumber)

        // Once the memory copies are dropped, nothing says what the file holds, so it is written.
        second.clearMemoryCache()
        second.store(changed, forKey: "dates")
        second.flush()
        XCTAssertNotEqual(try fileNumber(), readNumber)
        XCTAssertEqual(CacheManager(cacheRoot: cacheRoot).retrieve([String: Date].self, forKey: "dates"), changed)

        // A removed value is written when it is stored again.
        second.remove(forKey: "dates")
        second.store(changed, forKey: "dates")
        second.flush()
        XCTAssertEqual(CacheManager(cacheRoot: cacheRoot).retrieve([String: Date].self, forKey: "dates"), changed)
    }

    func testCacheManagerWritesAnUnchangedValueWhoseFileIsMissingIt() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache-unsaved", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)
        let file = manager.diskCacheDirectory.appendingPathComponent("numbers.cache")

        // With its folder gone the write fails. The value is still served from memory.
        try FileManager.default.removeItem(at: manager.diskCacheDirectory)
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(manager.retrieve([Int].self, forKey: "numbers"), [1, 2])

        // The same value again: it never reached the file, so this time it is written.
        try FileManager.default.createDirectory(at: manager.diskCacheDirectory, withIntermediateDirectories: true)
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(CacheManager(cacheRoot: cacheRoot).retrieve([Int].self, forKey: "numbers"), [1, 2])

        // A file found unreadable is removed. Asking for another type than was
        // stored is what makes the read go to the file while the value is held.
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(manager.retrieve([String: Int].self, forKey: "numbers"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(CacheManager(cacheRoot: cacheRoot).retrieve([Int].self, forKey: "numbers"), [1, 2])
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
