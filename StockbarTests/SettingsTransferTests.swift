@preconcurrency import CoreData
import XCTest
@testable import Stockbar

/// Settings export and import. Every test uses its own defaults suite,
/// temporary directory, configuration file and test-only Keychain services;
/// nothing reads or writes the real app data or production Keychain items.
final class SettingsTransferTests: XCTestCase {
    private let password = "correct horse battery"
    private var root: URL!
    private var sides: [TransferSide] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarSettingsTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sides.forEach { $0.removeArtifacts() }
        sides = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Round trips

    func testSettingsAndKeysRoundTripIntoFreshIsolatedStores() async throws {
        let source = try makeSide("source")
        source.defaults.set("dark", forKey: "appearanceMode")
        source.defaults.set(900.0, forKey: "refreshInterval")
        source.defaults.set(3, forKey: MenuBarDisplaySettings.UserDefaultsKey.decimalPlaces)
        source.defaults.set(true, forKey: "trading212.enabled")
        source.defaults.set("live", forKey: "trading212.environment")
        let folyncSettings = try JSONEncoder().encode(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.example.test", scopeID: "all", pollingIntervalSeconds: 60
        ))
        source.defaults.set(folyncSettings, forKey: "folync.portfolio-source.settings.v2")
        try source.configuration.applyImportedValues(
            fmpAPIKey: "fmp-test-key", twelveDataAPIKey: "td-test-key", dataSourcePriority: ["fmp", "yfinance"]
        )
        let live = Trading212AuthConfiguration(apiKey: "t212-live-key", apiSecret: "t212-live-secret")
        let demo = Trading212AuthConfiguration(apiKey: "t212-demo-key", apiSecret: "t212-demo-secret")
        try source.trading212.save(live, environment: .live)
        try source.trading212.save(demo, environment: .demo)
        try source.folync.save(token: "folync-test-token", for: "https://folync.example.test")

        let target = try makeSide("target")
        target.defaults.set(false, forKey: "showColorCoding")

        let file = root.appendingPathComponent("settings.stockbarexport")
        let manifest = try await source.service.export(.settingsAndKeys, password: password, to: file)
        XCTAssertEqual(manifest.exportType, .settingsAndKeys)
        XCTAssertNil(manifest.databaseBytes)

        let prepared = try await target.service.prepareImport(from: file, password: password)
        XCTAssertFalse(prepared.includesDatabase)
        XCTAssertEqual(prepared.preview.settingsCount, 6)
        XCTAssertTrue(prepared.preview.includesDataSourcePriority)
        XCTAssertEqual(prepared.preview.credentialNames.count, 5)
        try await target.service.apply(prepared) { XCTFail("No portfolio backup for settings only"); return false }

        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "dark")
        XCTAssertEqual(target.defaults.double(forKey: "refreshInterval"), 900, accuracy: 0.001)
        XCTAssertEqual(target.defaults.object(forKey: MenuBarDisplaySettings.UserDefaultsKey.decimalPlaces) as? Int, 3)
        XCTAssertEqual(target.defaults.object(forKey: "trading212.enabled") as? Bool, true)
        XCTAssertEqual(target.defaults.data(forKey: "folync.portfolio-source.settings.v2"), folyncSettings)
        XCTAssertNil(target.defaults.object(forKey: "showColorCoding"), "Allowlisted settings absent from the file reset to defaults")

        let configuration = try target.configuration.exportableValues()
        XCTAssertEqual(configuration.fmpAPIKey, "fmp-test-key")
        XCTAssertEqual(configuration.twelveDataAPIKey, "td-test-key")
        XCTAssertEqual(configuration.dataSourcePriority, ["fmp", "yfinance"])
        XCTAssertEqual(try target.trading212.load(environment: .live), live)
        XCTAssertEqual(try target.trading212.load(environment: .demo), demo)
        XCTAssertEqual(try target.folync.load(for: "https://folync.example.test/any/path"), "folync-test-token")
    }

    func testCredentialsMissingFromTheFileAreLeftUnchanged() async throws {
        let source = try makeSide("source")
        try source.configuration.applyImportedValues(fmpAPIKey: "fmp-only", twelveDataAPIKey: nil, dataSourcePriority: nil)

        let target = try makeSide("target")
        try target.configuration.applyImportedValues(fmpAPIKey: "old-fmp", twelveDataAPIKey: "keep-td", dataSourcePriority: nil)
        let existing = Trading212AuthConfiguration(apiKey: "keep-key", apiSecret: "keep-secret")
        try target.trading212.save(existing, environment: .live)
        try target.folync.save(token: "keep-folync", for: Self.oldFolyncAddress)

        let file = root.appendingPathComponent("fmp.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)
        let prepared = try await target.service.prepareImport(from: file, password: password)
        XCTAssertEqual(prepared.preview.credentialNames, ["Financial Modeling Prep API key"])
        try await target.service.apply(prepared) { true }

        let configuration = try target.configuration.exportableValues()
        XCTAssertEqual(configuration.fmpAPIKey, "fmp-only")
        XCTAssertEqual(configuration.twelveDataAPIKey, "keep-td")
        XCTAssertEqual(try target.trading212.load(environment: .live), existing)
        XCTAssertEqual(try target.folync.load(), "keep-folync")
    }

    func testEverythingRoundTripReplacesStoreWithTradesAndSnapshots() async throws {
        let source = try makeSide("source", withStore: true)
        try source.store?.insertPortfolio(trades: ["AAPL", "VOD.L", "MSFT"], snapshots: 2, priceSnapshots: 4)
        source.defaults.set(3, forKey: "coreDataMigrationVersion")
        source.defaults.set(1, forKey: "ohlc.pence-rescale.version")
        source.defaults.set(["AAPL", "VOD.L", "MSFT"], forKey: "stockDisplayOrder")
        source.defaults.set("light", forKey: "appearanceMode")
        let brokerLinks = try makeBrokerLinksData()
        try write(brokerLinks, to: source.brokerLinksURL)

        let target = try makeSide("target", withStore: true)
        try target.store?.insertPortfolio(trades: ["OLD"], snapshots: 1, priceSnapshots: 1)
        target.defaults.set(true, forKey: "preV3PortfolioSnapshotsDeleted")

        XCTAssertGreaterThan(source.service.estimatedDatabaseBytes() ?? 0, 0)
        let file = root.appendingPathComponent("everything.stockbarexport")
        let manifest = try await source.service.export(.everything, password: password, to: file)
        XCTAssertEqual(manifest.exportType, .everything)

        let prepared = try await target.service.prepareImport(from: file, password: password)
        let database = try XCTUnwrap(prepared.preview.database)
        XCTAssertEqual(database.tradeCount, 3)
        XCTAssertEqual(database.portfolioSnapshotCount, 2)
        XCTAssertEqual(database.priceSnapshotCount, 4)
        XCTAssertTrue(database.includesBrokerLinks)

        let backups = Counter()
        try await target.service.apply(prepared) { backups.increment(); return true }

        XCTAssertEqual(backups.value, 1, "The existing portfolio backup runs before the store is replaced")
        XCTAssertEqual(try target.store?.tradeNames(), ["AAPL", "MSFT", "VOD.L"])
        XCTAssertEqual(try target.store?.count("PortfolioSnapshotEntity"), 2)
        XCTAssertEqual(try target.store?.count("PriceSnapshotEntity"), 4)
        XCTAssertTrue(target.store?.writesSuspended == true, "The replaced store stays read-only until relaunch")
        XCTAssertEqual(try Data(contentsOf: target.brokerLinksURL), brokerLinks)
        XCTAssertEqual(target.defaults.integer(forKey: "coreDataMigrationVersion"), 3)
        XCTAssertEqual(target.defaults.integer(forKey: "ohlc.pence-rescale.version"), 1)
        XCTAssertEqual(target.defaults.stringArray(forKey: "stockDisplayOrder"), ["AAPL", "VOD.L", "MSFT"])
        XCTAssertNil(target.defaults.object(forKey: "preV3PortfolioSnapshotsDeleted"))
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")

        let safetyCopies = try FileManager.default.contentsOfDirectory(atPath: target.recoveryRoot.path)
        XCTAssertEqual(safetyCopies.filter { $0.hasPrefix("pre-import-") }.count, 1)
        let stagingLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: target.stagingRoot.path)) ?? []
        XCTAssertTrue(stagingLeftovers.isEmpty, "Decrypted database copies are removed")
    }

    // MARK: - Rejected files

    func testWrongPasswordFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        await assertImportFails(file, target: target, password: "not the password", expected: .wrongPasswordOrDamaged)
    }

    func testTamperedCiphertextFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        var data = try Data(contentsOf: file)
        data[data.count - 40] ^= 0x01
        try data.write(to: file)
        await assertImportFails(file, target: target, expected: .wrongPasswordOrDamaged)
    }

    func testTamperedHeaderFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        var data = try Data(contentsOf: file)
        // First salt byte: magic (14) + version (2) + kdf (1) + iterations (4) + salt length (1).
        data[22] ^= 0x01
        try data.write(to: file)
        await assertImportFails(file, target: target, expected: .wrongPasswordOrDamaged)
    }

    func testTruncatedFileFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        let data = try Data(contentsOf: file)
        try data.prefix(data.count / 2).write(to: file)
        await assertImportFails(file, target: target, expected: .wrongPasswordOrDamaged)
        try data.prefix(30).write(to: file)
        await assertImportFails(file, target: target, expected: .damagedFile)
    }

    func testNewerFormatVersionFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        var data = try Data(contentsOf: file)
        data[14] = 0x00
        data[15] = 0x02
        try data.write(to: file)
        await assertImportFails(file, target: target, expected: .newerFormatVersion(2))
        do {
            try await target.service.checkImportFile(at: file)
            XCTFail("A newer format is rejected before a password is asked for")
        } catch {
            XCTAssertEqual(error as? SettingsTransferError, .newerFormatVersion(2))
        }
    }

    func testWrongMagicStringFailsWithNothingApplied() async throws {
        let (file, target) = try await exportSettingsFile()
        var data = try Data(contentsOf: file)
        data[0] = UInt8(ascii: "X")
        try data.write(to: file)
        await assertImportFails(file, target: target, expected: .notAnExportFile)
    }

    func testDatabaseFromAnIncompatibleModelIsRejectedWithNothingApplied() async throws {
        let foreignStore = root.appendingPathComponent("Foreign/StockbarDataModel.sqlite")
        try FileManager.default.createDirectory(at: foreignStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreignModel = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "SomethingElse"
        let attribute = NSAttributeDescription()
        attribute.name = "value"
        attribute.attributeType = .stringAttributeType
        entity.properties = [attribute]
        foreignModel.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: foreignModel)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: foreignStore)
        try coordinator.remove(store)

        let payload = SettingsTransferPayload(
            manifest: SettingsTransferManifest(
                exportType: .everything, createdAt: Date(), appVersion: "0", appBuild: "0",
                macOSVersion: "test", settingsCount: 1, credentialCount: 0, databaseBytes: nil
            ),
            settings: ["appearanceMode": .string("dark")],
            dataSourcePriority: nil,
            credentials: SettingsTransferCredentials(),
            database: SettingsTransferDatabase(
                storeFiles: try CoreDataStoreTransfer.readStoreFiles(at: foreignStore),
                brokerLinks: nil,
                state: [:]
            )
        )
        let file = root.appendingPathComponent("foreign.stockbarexport")
        try SettingsTransferContainer.seal(try payload.encoded(), password: password).write(to: file)

        let target = try makeSide("target", withStore: true)
        try target.store?.insertPortfolio(trades: ["KEEP"], snapshots: 0, priceSnapshots: 0)
        target.defaults.set("light", forKey: "appearanceMode")
        await assertImportFails(file, target: target, expected: .incompatibleDatabase)
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(try target.store?.tradeNames(), ["KEEP"])
    }

    // MARK: - Allowlist

    func testExcludedKeysAreNeverExportedOrOverwritten() async throws {
        let excluded: [String: Any] = [
            "pythonInterpreterPath": "/opt/source/python3",
            "pythonDependencyCheck.interpreterPath": "/opt/source/python3",
            "mainWindow.selectedSection": "holdings",
            "settings.selectedTab": "advanced",
            "cacheCoordinator.state.v1": Data("cache".utf8),
            "trading212.syncIntervalDefaultMigration.v1": true,
            "menuChartTimeRange.AAPL": "week",
            "lastBackupDate": Date(timeIntervalSince1970: 1_000)
        ]
        let source = try makeSide("source")
        excluded.forEach { source.defaults.set($0.value, forKey: $0.key) }
        source.defaults.set("dark", forKey: "appearanceMode")

        let file = root.appendingPathComponent("excluded.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)
        let payload = try SettingsTransferPayload.decode(
            try SettingsTransferContainer.open(try Data(contentsOf: file), password: password)
        )
        XCTAssertEqual(Set(payload.settings.keys), ["appearanceMode"])
        XCTAssertTrue(Set(SettingsTransferKeys.settingsKeys.keys).isDisjoint(with: excluded.keys))
        XCTAssertTrue(Set(SettingsTransferKeys.databaseStateKeys.keys).isDisjoint(with: excluded.keys))

        let target = try makeSide("target")
        target.defaults.set("/opt/target/python3", forKey: "pythonInterpreterPath")
        target.defaults.set("overview", forKey: "mainWindow.selectedSection")
        target.defaults.set(false, forKey: "trading212.syncIntervalDefaultMigration.v1")
        let prepared = try await target.service.prepareImport(from: file, password: password)
        try await target.service.apply(prepared) { true }

        XCTAssertEqual(target.defaults.string(forKey: "pythonInterpreterPath"), "/opt/target/python3")
        XCTAssertEqual(target.defaults.string(forKey: "mainWindow.selectedSection"), "overview")
        XCTAssertEqual(target.defaults.object(forKey: "trading212.syncIntervalDefaultMigration.v1") as? Bool, false)
        XCTAssertNil(target.defaults.object(forKey: "menuChartTimeRange.AAPL"))
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "dark")
    }

    // MARK: - Rollback

    func testFailurePartwayThroughSettingsImportRestoresPreviousState() async throws {
        let source = try makeSide("source")
        source.defaults.set("dark", forKey: "appearanceMode")
        try source.configuration.applyImportedValues(fmpAPIKey: "new-fmp", twelveDataAPIKey: nil, dataSourcePriority: nil)
        try source.trading212.save(Trading212AuthConfiguration(apiKey: "new-key", apiSecret: "new-secret"), environment: .live)
        try source.trading212.save(Trading212AuthConfiguration(apiKey: "new-demo", apiSecret: "new-demo-secret"), environment: .demo)
        try storeFolync(token: "new-folync", address: Self.newFolyncAddress, on: source)
        let file = root.appendingPathComponent("partial.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        target.defaults.set("light", forKey: "appearanceMode")
        let previous = Trading212AuthConfiguration(apiKey: "old-key", apiSecret: "old-secret")
        try target.trading212.save(previous, environment: .live)
        try storeFolync(token: "old-folync", address: Self.oldFolyncAddress, on: target)
        // An unreadable API key file makes the import fail after defaults and
        // Keychain items were already written.
        let configURL = target.configDirectory.appendingPathComponent(".stockbar_config.json")
        let unreadable = Data("not json".utf8)
        try write(unreadable, to: configURL)

        let prepared = try await target.service.prepareImport(from: file, password: password)
        do {
            try await target.service.apply(prepared) { true }
            XCTFail("The import should fail")
        } catch {
            XCTAssertEqual(error as? SettingsTransferError, .applyFailed)
        }

        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(try target.trading212.load(environment: .live), previous)
        XCTAssertFalse(target.trading212.hasCredentials(environment: .demo))
        XCTAssertEqual(try target.folync.load(for: Self.oldFolyncAddress), "old-folync", "The token goes back to its own server")
        XCTAssertEqual(try Data(contentsOf: configURL), unreadable)
    }

    func testFailurePartwayThroughEverythingImportRestoresStoreAndSettings() async throws {
        let source = try makeSide("source", withStore: true)
        try source.store?.insertPortfolio(trades: ["NEW1", "NEW2"], snapshots: 1, priceSnapshots: 1)
        source.defaults.set("dark", forKey: "appearanceMode")
        source.defaults.set(["NEW1", "NEW2"], forKey: "stockDisplayOrder")
        try write(try makeBrokerLinksData(), to: source.brokerLinksURL)
        try storeFolync(token: "new-folync", address: Self.newFolyncAddress, on: source)
        let file = root.appendingPathComponent("partial-everything.stockbarexport")
        _ = try await source.service.export(.everything, password: password, to: file)

        // Broker links cannot be written: their folder path is a file. That
        // step runs after the store has already been replaced.
        let blocker = root.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let target = try makeSide("target", withStore: true, brokerLinksURL: blocker.appendingPathComponent("broker_links.json"))
        try target.store?.insertPortfolio(trades: ["OLD"], snapshots: 3, priceSnapshots: 0)
        target.defaults.set("light", forKey: "appearanceMode")
        target.defaults.set(["OLD"], forKey: "stockDisplayOrder")
        try storeFolync(token: "old-folync", address: Self.oldFolyncAddress, on: target)

        let prepared = try await target.service.prepareImport(from: file, password: password)
        do {
            try await target.service.apply(prepared) { true }
            XCTFail("The import should fail")
        } catch {
            XCTAssertEqual(error as? SettingsTransferError, .applyFailed)
        }

        XCTAssertEqual(try target.store?.tradeNames(), ["OLD"])
        XCTAssertEqual(try target.store?.count("PortfolioSnapshotEntity"), 3)
        XCTAssertTrue(target.store?.writesSuspended == false, "Writes resume after a rollback")
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(target.defaults.stringArray(forKey: "stockDisplayOrder"), ["OLD"])
        XCTAssertEqual(try target.folync.load(), "old-folync")
    }

    func testFailedPortfolioBackupStopsTheImportBeforeAnythingChanges() async throws {
        let source = try makeSide("source", withStore: true)
        try source.store?.insertPortfolio(trades: ["NEW"], snapshots: 0, priceSnapshots: 0)
        source.defaults.set("dark", forKey: "appearanceMode")
        let file = root.appendingPathComponent("backup-fails.stockbarexport")
        _ = try await source.service.export(.everything, password: password, to: file)

        let target = try makeSide("target", withStore: true)
        try target.store?.insertPortfolio(trades: ["OLD"], snapshots: 0, priceSnapshots: 0)
        target.defaults.set("light", forKey: "appearanceMode")
        let prepared = try await target.service.prepareImport(from: file, password: password)
        do {
            try await target.service.apply(prepared) { false }
            XCTFail("The import should stop")
        } catch {
            guard case .backupFailed = error as? SettingsTransferError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertEqual(try target.store?.tradeNames(), ["OLD"])
        XCTAssertEqual(target.defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertTrue(target.store?.writesSuspended == false)
    }

    // MARK: - Store suspension and relaunch

    func testSuspendedStoreRejectsSavesWithAnErrorAndResumes() throws {
        let host = try TemporaryStoreHost(storeURL: root.appendingPathComponent("Suspend/StockbarDataModel.sqlite"))
        host.setTransferWritesSuspended(true)
        XCTAssertThrowsError(try host.insertPortfolio(trades: ["BLOCKED"], snapshots: 0, priceSnapshots: 0))
        host.setTransferWritesSuspended(false)
        try host.insertPortfolio(trades: ["ALLOWED"], snapshots: 0, priceSnapshots: 0)
        XCTAssertEqual(try host.tradeNames(), ["ALLOWED"])
        host.close()
    }

    func testRelaunchKeepsAcceptanceStorageAndNeverCarriesItIntoNormalRuns() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Stockbar.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Stockbar")
        let acceptanceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("acceptance-root")
        let acceptance = StockbarAcceptanceRuntime(
            root: acceptanceRoot,
            runID: "acceptance-run-0001",
            folyncKeychainService: "com.stockbar.folync.acceptance.acceptance-run-0001",
            liveProviderRequestsAllowed: false
        )
        let acceptancePlan = try StockbarRelauncher.launchPlan(
            runtime: acceptance, bundleURL: bundle, executableURL: executable,
            processIdentifier: 42, environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(acceptancePlan.arguments.last, executable.path)
        XCTAssertEqual(acceptancePlan.environment["STOCKBAR_ACCEPTANCE_ROOT"], acceptanceRoot.path)
        XCTAssertEqual(acceptancePlan.environment["STOCKBAR_ACCEPTANCE_RUN_ID"], "acceptance-run-0001")
        XCTAssertEqual(acceptancePlan.environment["STOCKBAR_DISABLE_LIVE_PROVIDERS"], "1")
        XCTAssertTrue(acceptancePlan.arguments.contains("42"))

        let production = StockbarAcceptanceRuntime(
            root: nil, runID: nil,
            folyncKeychainService: StockbarAcceptanceRuntime.productionFolyncKeychainService,
            liveProviderRequestsAllowed: true
        )
        let productionPlan = try StockbarRelauncher.launchPlan(
            runtime: production, bundleURL: bundle, executableURL: executable,
            processIdentifier: 42, environment: ["STOCKBAR_ACCEPTANCE_ROOT": "/tmp/stale"]
        )
        XCTAssertEqual(Array(productionPlan.arguments.suffix(2)), ["/usr/bin/open", bundle.path])
        XCTAssertNil(productionPlan.environment["STOCKBAR_ACCEPTANCE_ROOT"])

        XCTAssertThrowsError(try StockbarRelauncher.launchPlan(
            runtime: StockbarRuntimeStorage.acceptance, bundleURL: bundle, executableURL: executable,
            processIdentifier: 42, environment: [:]
        ))
        XCTAssertNotEqual(
            StockbarRuntimeStorage.acceptance.trading212KeychainService,
            StockbarAcceptanceRuntime.productionTrading212KeychainService
        )
    }

    // MARK: - Values a file may not set

    func testImportBoundsNumbersAndNeverTurnsOnAnOptionThatDeletesData() async throws {
        let source = try makeSide("source")
        source.defaults.set(-5, forKey: "backupRetentionDays")
        source.defaults.set(1.0, forKey: "refreshInterval")
        source.defaults.set(1_000_000, forKey: "debugLogMaxLines")
        source.defaults.set(-3, forKey: MenuBarDisplaySettings.UserDefaultsKey.decimalPlaces)
        source.defaults.set(14, forKey: "backfillCooldownHours")
        source.defaults.set(true, forKey: "trading212.deleteMissingLinkedHoldings")
        let file = root.appendingPathComponent("out-of-range.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        let prepared = try await target.service.prepareImport(from: file, password: password)
        XCTAssertTrue(prepared.preview.keepsDestructiveOptionsOff)
        try await target.service.apply(prepared) { true }

        XCTAssertEqual(target.defaults.integer(forKey: "backupRetentionDays"), 7)
        XCTAssertEqual(target.defaults.double(forKey: "refreshInterval"), 60, accuracy: 0.001)
        XCTAssertEqual(target.defaults.integer(forKey: "debugLogMaxLines"), 2000)
        XCTAssertEqual(target.defaults.integer(forKey: MenuBarDisplaySettings.UserDefaultsKey.decimalPlaces), 0)
        XCTAssertEqual(target.defaults.integer(forKey: "backfillCooldownHours"), 14, "Values in range are kept")
        XCTAssertEqual(target.defaults.object(forKey: "trading212.deleteMissingLinkedHoldings") as? Bool, false)

        // A Mac that already has the option on keeps it, and a file can turn it off.
        let already = try makeSide("already-on")
        already.defaults.set(true, forKey: "trading212.deleteMissingLinkedHoldings")
        let kept = try await already.service.prepareImport(from: file, password: password)
        XCTAssertFalse(kept.preview.keepsDestructiveOptionsOff)
        try await already.service.apply(kept) { true }
        XCTAssertTrue(already.defaults.bool(forKey: "trading212.deleteMissingLinkedHoldings"))
    }

    func testLeftoverStagedDatabaseCopiesAreRemovedAtLaunch() throws {
        let side = try makeSide("staging")
        let leftover = side.service.dependencies.stagingRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try write(Data("decrypted".utf8), to: leftover.appendingPathComponent("Stockbar.sqlite"))

        side.service.removeLeftoverStagedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertNoThrow(try makeSide("no-staging-folder").service.removeLeftoverStagedFiles())
    }

    func testFolyncAddressRejectsCredentialsQueryAndFragment() {
        for address in [
            "https://user:secret@folync.example.test",
            "https://user@folync.example.test",
            "https://folync.example.test/?token=abc",
            "https://folync.example.test/#section"
        ] {
            XCTAssertThrowsError(try FolyncEndpointPolicy.validate(URL(string: address)!), address) { error in
                XCTAssertEqual(error as? FolyncPortfolioSourceError, .invalidEndpoint)
            }
        }
        XCTAssertNoThrow(try FolyncEndpointPolicy.validate(URL(string: "https://folync.example.test/base")!))
        XCTAssertNoThrow(try FolyncEndpointPolicy.validate(URL(string: "http://localhost:8080")!))
    }

    // MARK: - Folync token and its server

    func testImportThatChangesTheFolyncAddressWithoutATokenNeverReusesTheStoredToken() async throws {
        let source = try makeSide("source")
        setFolyncAddress(Self.newFolyncAddress, on: source)
        let file = root.appendingPathComponent("address-only.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        try storeFolync(token: "old-folync", address: Self.oldFolyncAddress, on: target)
        let prepared = try await target.service.prepareImport(from: file, password: password)
        XCTAssertEqual(prepared.preview.credentialNames, [])
        try await target.service.apply(prepared) { true }

        XCTAssertEqual(FolyncSettingsStore(defaults: target.defaults).load().baseURL, Self.newFolyncAddress)
        XCTAssertThrowsError(try target.folync.load(for: Self.newFolyncAddress)) { error in
            XCTAssertEqual(error as? FolyncCredentialStoreError, .savedForAnotherServer)
        }
        XCTAssertEqual(try target.folync.load(for: Self.oldFolyncAddress), "old-folync")
    }

    func testTokenStoredByAnEarlierVersionIsTiedToTheAddressInUseBeforeAnImport() async throws {
        let source = try makeSide("source")
        setFolyncAddress(Self.newFolyncAddress, on: source)
        let file = root.appendingPathComponent("legacy-token.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        setFolyncAddress(Self.oldFolyncAddress, on: target)
        try target.folync.save(token: "old-folync", server: nil)
        let prepared = try await target.service.prepareImport(from: file, password: password)
        try await target.service.apply(prepared) { true }

        XCTAssertEqual(try target.folync.savedServer(), "https://old.folync.example.test:443")
        XCTAssertThrowsError(try target.folync.load(for: Self.newFolyncAddress))
    }

    func testExportLeavesOutATokenSavedForAnotherServer() async throws {
        let source = try makeSide("source")
        setFolyncAddress(Self.newFolyncAddress, on: source)
        try source.folync.save(token: "old-folync", for: Self.oldFolyncAddress)
        let file = root.appendingPathComponent("mismatch.stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        let prepared = try await target.service.prepareImport(from: file, password: password)
        XCTAssertEqual(prepared.preview.credentialNames, [])
    }

    func testFolyncTokenServerIgnoresPathAndCaseButNotSchemeHostOrPort() throws {
        let server = FolyncCredentialStore.server(of:)
        XCTAssertEqual(server("https://Folync.Example.test/api/"), "https://folync.example.test:443")
        XCTAssertEqual(server("https://folync.example.test"), server(" https://folync.example.test:443/x?y=1 "))
        XCTAssertNotEqual(server("https://folync.example.test"), server("http://folync.example.test"))
        XCTAssertNotEqual(server("https://folync.example.test"), server("https://folync.example.test:8443"))
        XCTAssertNotEqual(server("https://folync.example.test"), server("https://folync.example.test.evil.test"))
        XCTAssertNil(server(""))
        XCTAssertNil(server("folync.example.test"))

        let side = try makeSide("store")
        try side.folync.save(token: "first", for: Self.oldFolyncAddress)
        try side.folync.save(token: "second", for: Self.newFolyncAddress)
        XCTAssertThrowsError(try side.folync.load(for: Self.oldFolyncAddress))
        XCTAssertEqual(try side.folync.load(for: Self.newFolyncAddress), "second")
        try side.folync.delete()
        XCTAssertFalse(side.folync.hasToken())
        XCTAssertNil(try side.folync.savedServer())
    }

    // MARK: - Helpers

    private static let oldFolyncAddress = "https://old.folync.example.test"
    private static let newFolyncAddress = "https://new.folync.example.test"

    private func setFolyncAddress(_ address: String, on side: TransferSide) {
        FolyncSettingsStore(defaults: side.defaults).save(FolyncStoredSettings(
            isEnabled: true, baseURL: address, scopeID: "all", pollingIntervalSeconds: 60
        ))
    }

    private func storeFolync(token: String, address: String, on side: TransferSide) throws {
        setFolyncAddress(address, on: side)
        try side.folync.save(token: token, for: address)
    }

    private func exportSettingsFile() async throws -> (URL, TransferSide) {
        let source = try makeSide("source")
        source.defaults.set("dark", forKey: "appearanceMode")
        try storeFolync(token: "new-folync", address: Self.newFolyncAddress, on: source)
        let file = root.appendingPathComponent("rejected-\(UUID().uuidString).stockbarexport")
        _ = try await source.service.export(.settingsAndKeys, password: password, to: file)

        let target = try makeSide("target")
        target.defaults.set("light", forKey: "appearanceMode")
        try storeFolync(token: "old-folync", address: Self.oldFolyncAddress, on: target)
        return (file, target)
    }

    private func assertImportFails(
        _ file: URL,
        target: TransferSide,
        password: String? = nil,
        expected: SettingsTransferError,
        file sourceFile: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let before = target.defaults.dictionaryRepresentation().filter { $0.key == "appearanceMode" }
        let folyncBefore = try? target.folync.load()
        do {
            _ = try await target.service.prepareImport(from: file, password: password ?? self.password)
            XCTFail("Import should fail with \(expected)", file: sourceFile, line: line)
        } catch {
            XCTAssertEqual(error as? SettingsTransferError, expected, file: sourceFile, line: line)
        }
        let after = target.defaults.dictionaryRepresentation().filter { $0.key == "appearanceMode" }
        XCTAssertEqual(after as NSDictionary, before as NSDictionary, file: sourceFile, line: line)
        XCTAssertEqual(try? target.folync.load(), folyncBefore, file: sourceFile, line: line)
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: target.stagingRoot.path)) ?? []
        XCTAssertTrue(staging.isEmpty, file: sourceFile, line: line)
    }

    private func makeSide(_ name: String, withStore: Bool = false, brokerLinksURL: URL? = nil) throws -> TransferSide {
        let side = try TransferSide(
            root: root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true),
            withStore: withStore,
            brokerLinksURL: brokerLinksURL
        )
        sides.append(side)
        return side
    }

    private func makeBrokerLinksData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(BrokerLinkStoreSnapshot.empty(now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

/// One Mac's worth of isolated storage: defaults suite, config file,
/// test-only Keychain services, broker links, staging, recovery and an
/// optional SQLite store.
private final class TransferSide {
    let defaultsSuite: String
    let defaults: UserDefaults
    let configDirectory: URL
    let configuration: ConfigurationManager
    let trading212: Trading212CredentialStore
    let folync: FolyncCredentialStore
    let brokerLinksURL: URL
    let stagingRoot: URL
    let recoveryRoot: URL
    let store: TemporaryStoreHost?
    let service: SettingsTransferService

    init(root: URL, withStore: Bool, brokerLinksURL: URL?) throws {
        let id = UUID().uuidString
        let suite = TestDefaultsSuite.makeName("StockbarSettingsTransferTests-")
        let configDirectory = root.appendingPathComponent("com.stockbar", isDirectory: true)
        let configuration = ConfigurationManager(directory: configDirectory)
        let trading212 = Trading212CredentialStore(service: "com.stockbar.tests.settings-transfer.trading212.\(id)")
        let folync = FolyncCredentialStore(service: "com.stockbar.tests.settings-transfer.folync.\(id)")
        let links = brokerLinksURL ?? root.appendingPathComponent("Stockbar/BrokerLinks/broker_links.json")
        let stagingRoot = root.appendingPathComponent("Stockbar/TransferStaging", isDirectory: true)
        let recoveryRoot = root.appendingPathComponent("com.stockbar/StoreRecovery", isDirectory: true)
        let store = withStore
            ? try TemporaryStoreHost(storeURL: root.appendingPathComponent("Stockbar/StockbarDataModel.sqlite"))
            : nil

        defaultsSuite = suite
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.configDirectory = configDirectory
        self.configuration = configuration
        self.trading212 = trading212
        self.folync = folync
        self.brokerLinksURL = links
        self.stagingRoot = stagingRoot
        self.recoveryRoot = recoveryRoot
        self.store = store
        service = SettingsTransferService(dependencies: SettingsTransferDependencies(
            // No fallback to the standard domain: a test that reached it
            // would rewrite the real settings of whoever runs the tests.
            defaults: {
                guard let isolated = UserDefaults(suiteName: suite) else {
                    preconditionFailure("The test defaults suite could not be opened")
                }
                return isolated
            },
            configuration: configuration,
            trading212Credentials: trading212,
            folyncCredentials: folync,
            brokerLinksURL: links,
            stagingRoot: stagingRoot,
            recoveryRoot: recoveryRoot,
            storeHost: store,
            appInfo: SettingsTransferAppInfo(version: "9.9.9", build: "99", macOSVersion: "test")
        ))
    }

    func removeArtifacts() {
        store?.close()
        TestDefaultsSuite.remove(defaultsSuite)
        for environment in Trading212Environment.allCases {
            try? trading212.delete(environment: environment)
        }
        try? folync.delete()
    }
}

/// A SQLite store opened the way `CoreDataStack` opens the real one, using
/// the app's already-loaded model so entity classes are not registered twice.
private final class TemporaryStoreHost: SettingsTransferStoreHost, @unchecked Sendable {
    let container: NSPersistentContainer
    private let lock = NSLock()
    private var suspended = false

    init(storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        container = NSPersistentContainer(
            name: "StockbarDataModel",
            managedObjectModel: CoreDataStack.shared.persistentContainer.managedObjectModel
        )
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        CoreDataStack.applySQLiteOptions(to: description)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
    }

    var transferStoreURL: URL? {
        container.persistentStoreCoordinator.persistentStores.first?.url
    }

    /// Closes the store before its folder is deleted.
    func close() {
        let coordinator = container.persistentStoreCoordinator
        coordinator.performAndWait {
            coordinator.persistentStores.forEach { try? coordinator.remove($0) }
        }
    }

    var transferModel: NSManagedObjectModel {
        container.managedObjectModel
    }

    var writesSuspended: Bool {
        lock.withLock { suspended }
    }

    func setTransferWritesSuspended(_ suspended: Bool) {
        let coordinator = container.persistentStoreCoordinator
        coordinator.performAndWait {
            coordinator.persistentStores.forEach { $0.isReadOnly = suspended }
        }
        lock.withLock { self.suspended = suspended }
    }

    func insertPortfolio(trades: [String], snapshots: Int, priceSnapshots: Int) throws {
        let context = container.newBackgroundContext()
        try context.performAndWait {
            for name in trades {
                let trade = NSEntityDescription.insertNewObject(forEntityName: "TradeEntity", into: context)
                trade.setValue(name, forKey: "name")
                trade.setValue("10", forKey: "unitSize")
                trade.setValue("100", forKey: "positionAvgCost")
                trade.setValue("USD", forKey: "currency")
                trade.setValue(Date(), forKey: "lastModified")
            }
            for index in 0..<snapshots {
                let snapshot = NSEntityDescription.insertNewObject(forEntityName: "PortfolioSnapshotEntity", into: context)
                snapshot.setValue(UUID(), forKey: "id")
                snapshot.setValue(Date(timeIntervalSince1970: Double(1_700_000_000 + index * 86_400)), forKey: "timestamp")
                snapshot.setValue(1_000.0 + Double(index), forKey: "totalValue")
                let position = NSEntityDescription.insertNewObject(forEntityName: "PositionSnapshotEntity", into: context)
                position.setValue(trades.first ?? "AAPL", forKey: "symbol")
                position.setValue(snapshot, forKey: "portfolioSnapshot")
            }
            for index in 0..<priceSnapshots {
                let price = NSEntityDescription.insertNewObject(forEntityName: "PriceSnapshotEntity", into: context)
                price.setValue(UUID(), forKey: "id")
                price.setValue(trades.first ?? "AAPL", forKey: "symbol")
                price.setValue(100.0 + Double(index), forKey: "price")
                price.setValue(Date(timeIntervalSince1970: Double(1_700_000_000 + index * 60)), forKey: "timestamp")
            }
            try context.save()
        }
    }

    func tradeNames() throws -> [String] {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "TradeEntity")
            return try context.fetch(request).compactMap { $0.value(forKey: "name") as? String }.sorted()
        }
    }

    func count(_ entityName: String) throws -> Int {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
