import AppKit
import CoreData
import SwiftUI
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
        XCTAssertFalse(runtime.loopbackFolyncAllowed)
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
        XCTAssertFalse(runtime.loopbackFolyncAllowed, "a test run must not reach a Folync on this Mac")
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
        XCTAssertTrue(runtime.loopbackFolyncAllowed)
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
        XCTAssertTrue(runtime.loopbackFolyncAllowed, "the harness's Folync stand-in on this Mac is the one exception")
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
        // varies from one encoding to the next.
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

    func testCacheManagerWritesAnUnchangedValueWhenItsFileDoesNotHoldIt() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache-unsaved", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)
        let file = manager.diskCacheDirectory.appendingPathComponent("numbers.cache")
        func fileNumber() throws -> UInt64? {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        func storedOnDisk() -> [Int]? {
            CacheManager(cacheRoot: cacheRoot).retrieve([Int].self, forKey: "numbers")
        }

        // An older value on disk, then a write that fails: with the folder
        // moved away there is nowhere to write. Memory still serves the new value.
        manager.store([1], forKey: "numbers")
        manager.flush()
        let parked = cacheRoot.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: manager.diskCacheDirectory, to: parked)
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(manager.retrieve([Int].self, forKey: "numbers"), [1, 2])

        // The folder is back with the older file in it. The same value again:
        // it never reached the file, so this time it is written.
        try FileManager.default.moveItem(at: parked, to: manager.diskCacheDirectory)
        XCTAssertEqual(storedOnDisk(), [1])
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(storedOnDisk(), [1, 2])

        // That write succeeded, so the next store of the value leaves the file alone again.
        let rewritten = try fileNumber()
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(try fileNumber(), rewritten)

        // A file deleted from outside the app is written again.
        try FileManager.default.removeItem(at: file)
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(storedOnDisk(), [1, 2])

        // A file found unreadable is removed. Asking for another type than was
        // stored is what makes the read go to the file while the value is held.
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(manager.retrieve([String: Int].self, forKey: "numbers"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        manager.store([1, 2], forKey: "numbers")
        manager.flush()
        XCTAssertEqual(storedOnDisk(), [1, 2])
    }

    func testCacheManagerFilesAgreeWithMemoryAfterConcurrentUse() throws {
        let cacheRoot = root.appendingPathComponent("Caches/stockbar-cache-concurrent", isDirectory: true)
        let manager = CacheManager(cacheRoot: cacheRoot)
        let keys = ["a", "b", "c"]

        // Stores, removes and reads of three keys from many threads at once.
        // Few distinct values, so that many of the stores find theirs unchanged.
        DispatchQueue.concurrentPerform(iterations: 600) { index in
            let key = keys[index % keys.count]
            switch (index / keys.count) % 5 {
            case 0, 1: manager.store([index % 4], forKey: key)
            case 2: manager.store([index % 2], forKey: key)
            case 3: manager.remove(forKey: key)
            default: _ = manager.retrieve([Int].self, forKey: key)
            }
        }
        manager.flush()

        // In whatever order they landed, each file holds what memory holds.
        let fromFiles = CacheManager(cacheRoot: cacheRoot)
        for key in keys {
            XCTAssertEqual(
                fromFiles.retrieve([Int].self, forKey: key), manager.retrieve([Int].self, forKey: key), key
            )
        }
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
        liveProviderRequestsAllowed: true, loopbackFolyncAllowed: false)
    private let acceptance = StockbarAcceptanceRuntime(
        root: URL(fileURLWithPath: "/tmp/stockbar-acceptance-test", isDirectory: true), runID: "run-12345678",
        folyncKeychainService: "com.stockbar.folync.acceptance.run-12345678",
        liveProviderRequestsAllowed: false, loopbackFolyncAllowed: true)

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

final class StockbarAcceptanceLaunchOptionsTests: XCTestCase {
    private let allOptions = [
        "STOCKBAR_ACCEPTANCE_APPEARANCE": "light",
        "STOCKBAR_ACCEPTANCE_SECTION": "risk",
        "STOCKBAR_ACCEPTANCE_CURRENCY": "gbp",
        "STOCKBAR_ACCEPTANCE_WINDOW": "min",
        "STOCKBAR_ACCEPTANCE_POPOVER": "portfolio"
    ]

    private let explicitRun = StockbarAcceptanceRuntime(
        root: URL(fileURLWithPath: "/tmp/stockbar-acceptance-test", isDirectory: true), runID: "run-12345678",
        folyncKeychainService: "com.stockbar.folync.acceptance.run-12345678",
        liveProviderRequestsAllowed: false, loopbackFolyncAllowed: true)

    func testAnExplicitAcceptanceRunReadsEveryOption() {
        XCTAssertTrue(explicitRun.isExplicitAcceptanceRun)
        let options = StockbarAcceptanceLaunchOptions.resolve(environment: allOptions, runtime: explicitRun)

        XCTAssertEqual(options.appearance, .light)
        XCTAssertEqual(options.section, StockbarMainSection.risk.rawValue)
        XCTAssertEqual(options.currency, "GBP")
        XCTAssertTrue(options.opensAtMinimumSize)
        XCTAssertTrue(options.opensPortfolioPopover)
    }

    func testANormalRunIgnoresTheOptions() throws {
        let normal = try StockbarAcceptanceRuntime.resolve(environment: allOptions)

        XCTAssertFalse(normal.isExplicitAcceptanceRun)
        XCTAssertEqual(StockbarAcceptanceLaunchOptions.resolve(environment: allOptions, runtime: normal), .none)
    }

    func testTheAutomaticXCTestIsolationIgnoresTheOptions() throws {
        // It has a root and a run identifier too, so `isEnabled` alone is not the gate.
        var environment = allOptions
        environment["XCTestConfigurationFilePath"] = "/tmp/StockbarTests.xctestconfiguration"
        let isolation = try StockbarAcceptanceRuntime.resolveCurrent(
            environment: environment, processIdentifier: 4242, uniqueSuffix: "run-0002", isRunningUnderXCTest: true
        )

        XCTAssertTrue(isolation.isEnabled)
        XCTAssertFalse(isolation.isExplicitAcceptanceRun)
        XCTAssertEqual(StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: isolation), .none)
        XCTAssertTrue(StockbarAcceptanceLaunchOptions.current.isEmpty, "the test process itself must not pick them up")
    }

    func testEachUnknownValueIsDroppedOnItsOwn() {
        let unknown: [(key: String, value: String)] = [
            ("STOCKBAR_ACCEPTANCE_APPEARANCE", "sepia"),
            ("STOCKBAR_ACCEPTANCE_SECTION", "performance"),
            ("STOCKBAR_ACCEPTANCE_CURRENCY", "XYZ"),
            ("STOCKBAR_ACCEPTANCE_WINDOW", "max"),
            ("STOCKBAR_ACCEPTANCE_POPOVER", "symbol")
        ]
        let expected = StockbarAcceptanceLaunchOptions.resolve(environment: allOptions, runtime: explicitRun)
        for (key, value) in unknown {
            var environment = allOptions
            environment[key] = value
            var withoutIt = expected
            switch key {
            case StockbarAcceptanceLaunchOptions.appearanceKey: withoutIt.appearance = nil
            case StockbarAcceptanceLaunchOptions.sectionKey: withoutIt.section = nil
            case StockbarAcceptanceLaunchOptions.currencyKey: withoutIt.currency = nil
            case StockbarAcceptanceLaunchOptions.popoverKey: withoutIt.opensPortfolioPopover = false
            default: withoutIt.opensAtMinimumSize = false
            }
            XCTAssertEqual(StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: explicitRun),
                           withoutIt, "\(key)=\(value) must be ignored and leave the other options alone")
        }
        XCTAssertEqual(StockbarAcceptanceLaunchOptions.resolve(environment: [:], runtime: explicitRun), .none)
        XCTAssertEqual(StockbarAcceptanceLaunchOptions.resolve(
            environment: ["STOCKBAR_ACCEPTANCE_SECTION": "  "], runtime: explicitRun), .none)
    }

    @MainActor
    func testApplyingWritesOnlyTheSettingsTheOptionsName() throws {
        let suite = "StockbarAcceptanceLaunchOptionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("USD", forKey: "preferredCurrency")

        StockbarAcceptanceLaunchOptions(appearance: .dark, section: "holdings").apply(to: defaults)

        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "dark")
        XCTAssertEqual(defaults.string(forKey: "mainWindow.selectedSection"), "holdings")
        XCTAssertEqual(defaults.string(forKey: "preferredCurrency"), "USD", "an option not given changes nothing")
        XCTAssertEqual(StockbarMainNavigationState(defaults: defaults).selectedSection, .holdings)
    }
}

// MARK: - Main window shell

@MainActor
final class StockbarMainWindowShellTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "StockbarMainWindowShellTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // Groups, order, titles and shortcuts

    func testTheSidebarHasThreeGroupsInTheirOrder() {
        XCTAssertEqual(StockbarMainSection.sidebarGroups.map(\.title), ["Portfolio", "Analysis", "System"])
        XCTAssertEqual(StockbarMainSection.sidebarGroups.map(\.sections), [
            [.overview, .holdings, .alerts],
            [.charts, .income, .risk, .allocation],
            [.dataHealth, .backups, .diagnostics, .settings]
        ])
        XCTAssertEqual(Set(StockbarMainSection.sidebarOrder), Set(StockbarMainSection.allCases))
        XCTAssertEqual(StockbarMainSection.sidebarOrder.count, StockbarMainSection.allCases.count,
                       "every section appears exactly once")
    }

    func testThePerformancePageIsTitledCharts() {
        XCTAssertEqual(StockbarMainSection.charts.title, "Charts")
        XCTAssertEqual(StockbarMainSection.charts.rawValue, "charts", "the stored value does not change")
        XCTAssertFalse(StockbarMainSection.allCases.map(\.title).contains("Performance"))
    }

    func testCommandNumbersFollowTheSidebarTopToBottom() {
        let numbered = StockbarMainSection.sidebarOrder.map(\.shortcutNumber)
        XCTAssertEqual(numbered, [1, 2, 3, 4, 5, 6, 7, 8, 9, nil, nil])
        XCTAssertEqual(StockbarMainSection.alerts.shortcutNumber, 3)
        XCTAssertEqual(StockbarMainSection.charts.shortcutNumber, 4)
        XCTAssertEqual(StockbarMainSection.income.shortcutNumber, 5)
        XCTAssertEqual(StockbarMainSection.dataHealth.shortcutNumber, 8)
        XCTAssertNil(StockbarMainSection.diagnostics.shortcutNumber, "only the first nine entries take a number")
        XCTAssertNil(StockbarMainSection.settings.shortcutNumber, "Settings keeps ⌘, and takes no number")
    }

    func testTheViewMenuIsBuiltFromTheSidebarGroups() throws {
        let menu = StockbarSidebarMenu.makeViewMenu(sectionTarget: nil, sectionAction: #selector(NSResponder.selectAll(_:)),
                                                    defaults: defaults)
        let sectionItems = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(sectionItems.compactMap { $0.representedObject as? String },
                       StockbarMainSection.sidebarOrder.map(\.rawValue))
        XCTAssertEqual(sectionItems.map(\.title), StockbarMainSection.sidebarOrder.map(\.title))
        XCTAssertEqual(sectionItems.map(\.keyEquivalent), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", ""])
        XCTAssertTrue(sectionItems.allSatisfy { $0.keyEquivalentModifierMask == .command })

        // A separator between groups, and one before the sidebar item.
        let separators = menu.items.enumerated().filter { $0.element.isSeparatorItem }.map(\.offset)
        XCTAssertEqual(separators, [3, 8, 13])

        let sidebar = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(sidebar.title, "Hide Sidebar")
        XCTAssertEqual(sidebar.keyEquivalent, "s")
        XCTAssertEqual(sidebar.keyEquivalentModifierMask, [.control, .command])
        XCTAssertEqual(sidebar.action, #selector(StockbarMainWindowController.toggleStockbarSidebar(_:)))
        XCTAssertNil(sidebar.target, "it goes to the main window through the responder chain")
    }

    // Collapse

    func testHidingTheSidebarIsRememberedAcrossLaunches() {
        let first = StockbarMainNavigationState(defaults: defaults)
        XCTAssertFalse(first.isSidebarHidden, "shown by default")
        first.toggleSidebar()
        XCTAssertTrue(first.isSidebarHidden)

        let relaunched = StockbarMainNavigationState(defaults: defaults)
        XCTAssertTrue(relaunched.isSidebarHidden)
        XCTAssertTrue(StockbarMainNavigationState.storedSidebarHidden(in: defaults))
        let menu = StockbarSidebarMenu.makeViewMenu(sectionTarget: nil, sectionAction: #selector(NSResponder.selectAll(_:)),
                                                    defaults: defaults)
        XCTAssertEqual(menu.items.last?.title, "Show Sidebar", "the menu is titled right before any window exists")

        relaunched.toggleSidebar()
        XCTAssertFalse(StockbarMainNavigationState(defaults: defaults).isSidebarHidden)
    }

    func testTheSelectedSectionIsStillRestored() {
        let state = StockbarMainNavigationState(defaults: defaults)
        state.selectedSection = .charts
        XCTAssertEqual(StockbarMainNavigationState(defaults: defaults).selectedSection, .charts)
        XCTAssertEqual(StockbarMainNavigationState(selectedSection: .risk, defaults: defaults).selectedSection, .risk,
                       "a section opened from elsewhere wins")
    }

    // Entries: dimmed and New

    func testEntriesReadTheirPositionAndAnyBadgeOrDimmedReason() throws {
        let plain = StockbarSidebarModel.groups()
        let entries = plain.flatMap(\.entries)
        XCTAssertEqual(entries.map(\.section), StockbarMainSection.sidebarOrder)
        XCTAssertEqual(entries.map(\.position), Array(1...11))
        XCTAssertTrue(entries.allSatisfy { !$0.isDimmed && !$0.isNew }, "nothing is marked unless passed in")
        XCTAssertEqual(entries[1].accessibilityValue, "2 of 11")

        let marked = StockbarSidebarModel.groups(dimmed: [.risk: "Needs more history."], new: [.charts]).flatMap(\.entries)
        let risk = try XCTUnwrap(marked.first { $0.section == .risk })
        let charts = try XCTUnwrap(marked.first { $0.section == .charts })
        XCTAssertTrue(risk.isDimmed)
        XCTAssertEqual(risk.accessibilityValue, "Dimmed. Needs more history., 6 of 11")
        XCTAssertTrue(charts.isNew)
        XCTAssertEqual(charts.accessibilityValue, "New, 4 of 11")
    }

    // Keyboard

    func testArrowsHomeAndEndMoveTheSelection() {
        typealias Model = StockbarSidebarModel
        XCTAssertEqual(Model.target(of: .next, from: .overview), .holdings)
        XCTAssertEqual(Model.target(of: .next, from: .alerts), .charts, "across a group heading")
        XCTAssertEqual(Model.target(of: .previous, from: .dataHealth), .allocation)
        XCTAssertNil(Model.target(of: .previous, from: .overview), "stops at the top")
        XCTAssertNil(Model.target(of: .next, from: .settings), "stops at the bottom")
        XCTAssertEqual(Model.target(of: .first, from: .risk), .overview)
        XCTAssertEqual(Model.target(of: .last, from: .risk), .settings)
        XCTAssertNil(Model.target(of: .last, from: .settings))
        XCTAssertEqual(Model.move(for: .upArrow), .previous)
        XCTAssertEqual(Model.move(for: .downArrow), .next)
        XCTAssertEqual(Model.move(for: .home), .first)
        XCTAssertEqual(Model.move(for: .end), .last)
        XCTAssertNil(Model.move(for: .leftArrow))
    }

    // Footer

    private func footerInputs(connection: FolyncConnectionState = .current(asOf: nil), folync: Bool = true,
                              category: String? = nil, savedAt: Date? = nil, lastUpdate: Date? = nil)
        -> StockbarSidebarFooterStatus.Inputs {
        StockbarSidebarFooterStatus.Inputs(
            sourceTitle: folync ? "Folync portfolio" : "Local portfolio", sourceIcon: "link", sourceHelp: "",
            isFolyncActive: folync, connection: connection, failureCategory: category,
            savedAt: savedAt, lastUpdate: lastUpdate
        )
    }

    private func footer(_ inputs: StockbarSidebarFooterStatus.Inputs, now: Date) -> StockbarSidebarFooterStatus {
        StockbarSidebarFooterStatus.make(inputs, now: now, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt,
                                         locale: Locale(identifier: "en_GB"))
    }

    func testTheFooterSaysWhereThePortfolioComesFromAndHowFreshItIs() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let fresh = footer(footerInputs(lastUpdate: now.addingTimeInterval(-20)), now: now)
        XCTAssertEqual(fresh, StockbarSidebarFooterStatus(title: "Folync portfolio", detail: "Updated just now", isWarning: false))
        XCTAssertEqual(fresh.accessibilityLabel, "Folync portfolio. Updated just now")

        let older = footer(footerInputs(folync: false, lastUpdate: now.addingTimeInterval(-180)), now: now)
        XCTAssertEqual(older.title, "Local portfolio")
        XCTAssertTrue(older.detail.hasPrefix("Updated 3 min"), older.detail)
        XCTAssertFalse(older.isWarning)

        XCTAssertEqual(footer(footerInputs(), now: now).detail, "Not updated yet")
    }

    func testTheFooterTurnsToAWarningWhenFolyncIsNotAnswering() {
        // 2026-11-20 14:05 UTC, and "now" 25 minutes later.
        let saved = Date(timeIntervalSince1970: 1_795_183_500)
        let now = saved.addingTimeInterval(25 * 60)
        let offline = FolyncConnectionState.offlineCached(message: "The request timed out.")

        let unreachable = footer(footerInputs(connection: offline, category: "timeout", savedAt: saved), now: now)
        XCTAssertTrue(unreachable.isWarning)
        XCTAssertEqual(unreachable.detail, "Couldn't reach Folync · figures from 14:05")
        XCTAssertEqual(unreachable.accessibilityLabel, "Folync portfolio. Couldn't reach Folync · figures from 14:05")

        let yesterday = footer(footerInputs(connection: offline, savedAt: saved.addingTimeInterval(-86_400)), now: now)
        XCTAssertEqual(yesterday.detail, "Couldn't reach Folync · figures from 19 Nov, 14:05")

        XCTAssertEqual(footer(footerInputs(connection: offline), now: now).detail,
                       "Couldn't reach Folync · showing saved figures", "a cold start from cache has no time")
        XCTAssertEqual(footer(footerInputs(connection: offline, category: "unauthorized", savedAt: saved), now: now).detail,
                       "Folync rejected the token · figures from 14:05")

        XCTAssertFalse(footer(footerInputs(connection: .stale(asOf: nil, reasons: []), savedAt: saved), now: now).isWarning,
                       "a stale answer is still an answer")
        XCTAssertFalse(footer(footerInputs(connection: offline, folync: false, savedAt: saved), now: now).isWarning,
                       "only a Folync portfolio shows the warning")
    }

    func testVoiceOverHearsTheFooterTurnToTheWarningAndBack() {
        let normal = StockbarSidebarFooterStatus(title: "Folync portfolio", detail: "Updated just now", isWarning: false)
        let later = StockbarSidebarFooterStatus(title: "Folync portfolio", detail: "Updated 1 min ago", isWarning: false)
        let warning = StockbarSidebarFooterStatus(title: "Folync portfolio",
                                                  detail: "Couldn't reach Folync · figures from 14:05", isWarning: true)
        XCTAssertNil(StockbarSidebarFooterStatus.announcement(from: normal, to: later), "routine ticks stay quiet")
        XCTAssertEqual(StockbarSidebarFooterStatus.announcement(from: normal, to: warning), warning.accessibilityLabel)
        XCTAssertEqual(StockbarSidebarFooterStatus.announcement(from: warning, to: normal), normal.accessibilityLabel)
    }

    // Panel and entry styles

    func testThePanelIsGlassOnlyWhereAvailableAndHonoursAccessibility() {
        for scheme in [ColorScheme.light, .dark] {
            let glass = StockbarShellPanelStyle.resolve(scheme: scheme, accessibility: .init(), glassAvailable: true)
            XCTAssertEqual(glass.kind, .glass)
            XCTAssertEqual(glass.strokeWidth, 0)
            let fallback = StockbarShellPanelStyle.resolve(scheme: scheme, accessibility: .init(), glassAvailable: false)
            XCTAssertEqual(fallback.kind, .material, "macOS 15.4 to 25 get a material")
            XCTAssertEqual(fallback.strokeWidth, 1, "with a hairline")
            let contrast = StockbarShellPanelStyle.resolve(scheme: scheme, accessibility: .init(increasedContrast: true),
                                                           glassAvailable: true)
            XCTAssertGreaterThan(contrast.strokeWidth, 1, "a visible stroke round the panel")
            XCTAssertTrue(contrast.strongText)
            XCTAssertFalse(glass.strongText)
            let solid = StockbarShellPanelStyle.resolve(scheme: scheme, accessibility: .init(reduceTransparency: true),
                                                        glassAvailable: true)
            XCTAssertEqual(solid.kind, .solid)
            XCTAssertEqual(NSColor(solid.solidFill ?? .clear).usingColorSpace(.sRGB)?.alphaComponent ?? 0, 1, accuracy: 0.001)
        }
    }

    func testSelectedHoveredAndPressedEntriesEachLookDifferent() {
        for scheme in [ColorScheme.light, .dark] {
            for accessibility in [StockbarSurfaceAccessibility(), .init(increasedContrast: true), .init(reduceTransparency: true)] {
                let styles = StockbarSidebarEntryState.allCases.map {
                    StockbarSidebarEntryStyle.resolve($0, scheme: scheme, accessibility: accessibility)
                }
                XCTAssertEqual(Set(styles.map(\.fill.description)).count, styles.count,
                               "\(scheme) \(accessibility): each state has its own fill")
            }
        }
        let solidSelected = StockbarSidebarEntryStyle.resolve(.selected, scheme: .dark, accessibility: .init(reduceTransparency: true))
        XCTAssertEqual(NSColor(solidSelected.fill).usingColorSpace(.sRGB)?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func testThePanelDrawsWhatItsSettingsAsk() {
        XCTAssertEqual(drawnPanel(accessibility: .init(), glass: false)?.kind, .material)
        XCTAssertEqual(drawnPanel(accessibility: .init(reduceTransparency: true), glass: true)?.kind, .solid)
        XCTAssertEqual(drawnPanel(accessibility: .init(increasedContrast: true), glass: true)?.strongText, true)
    }

    // The window

    func testTheWindowIsSeeThroughKeepsItsMinimumAndHoldsTheSidebarButton() throws {
        let store = StockbarRuntimeStorage.userDefaults
        let key = StockbarMainNavigationState.sidebarHiddenKey
        let original = store.object(forKey: key)
        defer { if let original { store.set(original, forKey: key) } else { store.removeObject(forKey: key) } }
        store.removeObject(forKey: key)

        let model = DataModel(currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false),
                              startRuntimeServices: false)
        let controller = StockbarMainWindowController(dataModel: model)
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isOpaque, "the desktop shows through")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.resizable))

        window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 400), display: false)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame.size, NSSize(width: 1060, height: 680), "no smaller than 1060 by 680")
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        XCTAssertEqual(window.frame.size, NSSize(width: 1200, height: 720), "and no larger than asked")

        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .stockbarToggleSidebar })
        XCTAssertEqual(item.label, "Hide Sidebar")
        XCTAssertEqual(item.action, #selector(StockbarMainWindowController.toggleStockbarSidebar(_:)))
        controller.toggleStockbarSidebar(item)
        XCTAssertEqual(item.label, "Show Sidebar")
        XCTAssertTrue(store.bool(forKey: key), "remembered")

        let menuItem = NSMenuItem(title: "", action: #selector(StockbarMainWindowController.toggleStockbarSidebar(_:)),
                                  keyEquivalent: "s")
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Show Sidebar")
        controller.toggleStockbarSidebar(menuItem)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Hide Sidebar")
        window.close()
    }

    private func drawnPanel(accessibility: StockbarSurfaceAccessibility, glass: Bool) -> StockbarShellPanelStyle? {
        let seen = PanelSeen()
        let host = NSHostingView(
            rootView: PanelProbe(seen: seen)
                .stockbarSidebarPanel()
                .environment(\.stockbarSurfaceAccessibilityOverride, accessibility)
                .environment(\.stockbarGlassAvailableOverride, glass)
        )
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        host.layoutSubtreeIfNeeded()
        return seen.value
    }
}

@MainActor
private final class PanelSeen {
    var value: StockbarShellPanelStyle?
}

private struct PanelProbe: View {
    @Environment(\.stockbarShellPanelStyle) private var style
    let seen: PanelSeen

    var body: some View {
        let _ = (seen.value = style)
        Color.clear
    }
}
