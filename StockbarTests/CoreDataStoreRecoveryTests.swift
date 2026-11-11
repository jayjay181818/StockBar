import XCTest
@testable import Stockbar

final class CoreDataStoreRecoveryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory, FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCreateSafetyBackupCopiesSQLiteStoreAndSidecars() throws {
        // Given: A Core Data SQLite store with WAL sidecar files.
        let storeURL = temporaryDirectory.appendingPathComponent("StockbarDataModel.sqlite")
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        try Data("sqlite".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("shm".utf8).write(to: shmURL)

        let recoveryRoot = temporaryDirectory.appendingPathComponent("StoreRecovery", isDirectory: true)
        let recovery = CoreDataStoreRecovery(
            recoveryRoot: recoveryRoot,
            timestampProvider: { Date(timeIntervalSince1970: 1_777_777_777) }
        )

        // When: A safety backup is created.
        let result = try recovery.createSafetyBackup(for: storeURL)

        // Then: The original files are copied and left in place.
        let copiedNames = Set(result.copiedFiles.map(\.lastPathComponent))
        XCTAssertEqual(copiedNames, ["StockbarDataModel.sqlite", "StockbarDataModel.sqlite-wal", "StockbarDataModel.sqlite-shm"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testCreateSafetyBackupFailsWhenNoStoreFilesExist() {
        // Given: A missing store path.
        let missingStore = temporaryDirectory.appendingPathComponent("Missing.sqlite")
        let recovery = CoreDataStoreRecovery(recoveryRoot: temporaryDirectory)

        // When/Then: Recovery refuses to report success without copying data.
        XCTAssertThrowsError(try recovery.createSafetyBackup(for: missingStore)) { error in
            XCTAssertEqual(error as? CoreDataStoreRecoveryError, .noStoreFilesFound)
        }
    }

    func testRecoveryNoticeForBackedUpStoreIncludesBackupLocationAndNoDeletionMessage() {
        // Given: Core Data has failed to load but the store was safety-copied first.
        let backupDirectory = URL(fileURLWithPath: "/tmp/StockbarRecovery/store-load-failure-20260428")
        let state = CoreDataStoreLoadState.failedAndBackedUp(backupDirectory)

        // When: The startup recovery notice is built.
        let notice = CoreDataRecoveryNotice(state: state)

        // Then: The user-facing text explains that their original store was preserved.
        XCTAssertEqual(notice?.title, "Stockbar Preserved Your Portfolio Store")
        XCTAssertTrue(notice?.message.contains(backupDirectory.path) == true)
        XCTAssertTrue(notice?.message.contains("was not deleted") == true)
    }

    func testRecoveryNoticeForBackupFailureExplainsManualRecoveryRisk() {
        // Given: Core Data failed and even the safety copy could not be created.
        let state = CoreDataStoreLoadState.failedBackup("permission denied")

        // When: The startup recovery notice is built.
        let notice = CoreDataRecoveryNotice(state: state)

        // Then: The message tells the user not to keep working silently.
        XCTAssertEqual(notice?.title, "Stockbar Could Not Load Portfolio Storage")
        XCTAssertTrue(notice?.message.contains("permission denied") == true)
        XCTAssertTrue(notice?.message.contains("avoid making portfolio changes") == true)
    }
}

/// Saving the trade tables must touch only the rows that changed.
final class TradeTableUpsertTests: XCTestCase {
    private let service = TradeDataService()

    override func tearDown() async throws {
        try await service.saveAllTrades([])
        try await service.saveAllTradingInfo([:])
        try await super.tearDown()
    }

    private func trade(_ name: String, units: String) -> Trade {
        Trade(name: name, position: Position(unitSize: units, positionAvgCost: "10"))
    }

    private func tradeRows() async throws -> [String: (id: NSManagedObjectID, modified: Date?)] {
        try await CoreDataStack.shared.performBackgroundTask { context in
            var rows: [String: (id: NSManagedObjectID, modified: Date?)] = [:]
            for entity in try context.fetch(TradeEntity.fetchRequest()) {
                rows[entity.name ?? ""] = (entity.objectID, entity.lastModified)
            }
            return rows
        }
    }

    func testUnchangedTradesAreNotRewritten() async throws {
        try await service.saveAllTrades([trade("AAA", units: "1"), trade("BBB", units: "2"), trade("CCC", units: "3")])
        let before = try await tradeRows()

        try await service.saveAllTrades([trade("AAA", units: "1"), trade("BBB", units: "5"), trade("DDD", units: "4")])
        let after = try await tradeRows()

        XCTAssertEqual(Set(after.keys), ["AAA", "BBB", "DDD"])
        XCTAssertEqual(after["AAA"]?.id, before["AAA"]?.id)
        XCTAssertEqual(after["AAA"]?.modified, before["AAA"]?.modified, "an unchanged row must not be written")
        XCTAssertEqual(after["BBB"]?.id, before["BBB"]?.id, "a changed row is updated in place")
        XCTAssertNotEqual(after["BBB"]?.modified, before["BBB"]?.modified)

        let loaded = try await service.loadAllTrades()
        XCTAssertEqual(loaded.map(\.name), ["AAA", "BBB", "DDD"])
        XCTAssertEqual(loaded.first { $0.name == "BBB" }?.position.unitSizeString, "5")
    }

    func testUnchangedTradingInfoIsNotRewritten() async throws {
        var quoted = TradingInfo()
        quoted.currentPrice = 12.5
        quoted.prevClosePrice = 12
        quoted.currency = "USD"
        let unpriced = TradingInfo()

        func rows() async throws -> [String: Date?] {
            try await CoreDataStack.shared.performBackgroundTask { context in
                var rows: [String: Date?] = [:]
                for entity in try context.fetch(TradingInfoEntity.fetchRequest()) {
                    rows[entity.symbol ?? ""] = entity.lastModified
                }
                return rows
            }
        }

        try await service.saveAllTradingInfo(["AAA": quoted, "NAN": unpriced, "OLD": quoted])
        let before = try await rows()

        var moved = quoted
        moved.currentPrice = 13
        try await service.saveAllTradingInfo(["AAA": moved, "NAN": unpriced])
        let after = try await rows()

        XCTAssertEqual(Set(after.keys), ["AAA", "NAN"])
        XCTAssertNotEqual(after["AAA"], before["AAA"])
        XCTAssertEqual(after["NAN"], before["NAN"], "missing prices compare equal, so the row is left alone")
        let loaded = try await service.loadAllTradingInfo()
        XCTAssertEqual(loaded["AAA"]?.currentPrice, 13)
    }
}

/// The stored history is thinned to what the app reads back, and no further.
final class HistoricalStoreCompactionTests: XCTestCase {
    private let service = CoreDataHistoricalDataService()
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        try await super.setUp()
        try await deleteHistory()
    }

    override func tearDown() async throws {
        try await deleteHistory()
        try await super.tearDown()
    }

    private func deleteHistory() async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            for name in ["PriceSnapshotEntity", "PortfolioSnapshotEntity", "PositionSnapshotEntity"] {
                for object in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                    context.delete(object)
                }
            }
        }
    }

    private func date(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: calendar.date(
            byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)
        )!)!
    }

    private func price(_ symbol: String, daysAgo: Int, hour: Int, price: Double = 10) -> PriceSnapshot {
        PriceSnapshot(timestamp: date(daysAgo: daysAgo, hour: hour), price: price, previousClose: 9, volume: nil, symbol: symbol)
    }

    private func portfolio(daysAgo: Int, hour: Int, currency: String = "GBP") -> HistoricalPortfolioSnapshot {
        HistoricalPortfolioSnapshot(
            date: date(daysAgo: daysAgo, hour: hour), totalValue: 100, totalGains: 10, totalCost: 90, currency: currency,
            portfolioComposition: ["AAA": PositionSnapshot(symbol: "AAA", units: 1, priceAtDate: 100, valueAtDate: 100, currency: currency)]
        )
    }

    func testRedundantRowsKeepsTheLastOfEachGroupAndDay() {
        let cutoff = date(daysAgo: 31, hour: 0)
        let rows: [(group: String, timestamp: Date, id: Int)] = [
            ("AAA", date(daysAgo: 40, hour: 9), 1),
            ("AAA", date(daysAgo: 40, hour: 16), 2),
            ("AAA", date(daysAgo: 39, hour: 9), 3),
            ("AAA", date(daysAgo: 31, hour: 1), 4),
            ("AAA", date(daysAgo: 31, hour: 2), 5),
            ("BBB", date(daysAgo: 40, hour: 9), 6),
            ("BBB", date(daysAgo: 40, hour: 10), 7),
            ("BBB", date(daysAgo: 40, hour: 11), 8)
        ]

        XCTAssertEqual(
            HistoricalStoreCompaction.redundantRows(rows, before: cutoff, calendar: calendar),
            [1, 6, 7],
            "rows inside the full-resolution window are never touched"
        )
    }

    func testCompactionKeepsWhatTheAppReadsBack() async throws {
        let prices = [
            price("AAA", daysAgo: 60, hour: 9, price: 1), price("AAA", daysAgo: 60, hour: 12, price: 2),
            price("AAA", daysAgo: 60, hour: 16, price: 3), price("AAA", daysAgo: 59, hour: 16, price: 4),
            price("AAA", daysAgo: 5, hour: 9, price: 5), price("AAA", daysAgo: 5, hour: 10, price: 6),
            // Left the portfolio long ago, and recently.
            price("GONE", daysAgo: 200, hour: 9), price("GONE", daysAgo: 199, hour: 9),
            price("SOLD", daysAgo: 120, hour: 9), price("SOLD", daysAgo: 20, hour: 9),
            // Still used through an alias of a held symbol.
            price("ALIAS", daysAgo: 300, hour: 9)
        ]
        try await service.savePriceSnapshots(prices)
        for snapshot in [portfolio(daysAgo: 120, hour: 9), portfolio(daysAgo: 120, hour: 16),
                         portfolio(daysAgo: 120, hour: 17, currency: "USD"), portfolio(daysAgo: 10, hour: 9),
                         portfolio(daysAgo: 10, hour: 10)] {
            try await service.savePortfolioSnapshot(snapshot)
        }
        let stored = try await service.fetchAllPriceSnapshots(for: "AAA")
        let expectedInMemory = HistoricalDataManager.thinnedPriceHistory(stored, now: now, calendar: calendar)

        let result = try await HistoricalStoreCompaction()
            .compact(heldSymbols: ["AAA", "ALIAS"], now: now, calendar: calendar)

        XCTAssertEqual(result, .init(priceRowsDeleted: 2, portfolioSnapshotsDeleted: 1, unheldPriceRowsDeleted: 2))
        let remaining = try await service.fetchAllPriceSnapshots(for: "AAA")
        XCTAssertEqual(remaining.map(\.price), [3, 4, 5, 6])
        XCTAssertEqual(
            HistoricalDataManager.thinnedPriceHistory(remaining, now: now, calendar: calendar).map(\.price),
            expectedInMemory.map(\.price),
            "the in-memory history is the same before and after"
        )
        let gone = try await service.getDataCount(for: "GONE")
        let sold = try await service.getDataCount(for: "SOLD")
        let alias = try await service.getDataCount(for: "ALIAS")
        XCTAssertEqual([gone, sold, alias], [0, 2, 1])

        let snapshots = try await service.fetchAllPortfolioSnapshots()
        XCTAssertEqual(snapshots.map(\.currency), ["GBP", "USD", "GBP", "GBP"])
        XCTAssertEqual(snapshots.first?.date, date(daysAgo: 120, hour: 16))
        XCTAssertTrue(snapshots.allSatisfy { $0.portfolioComposition.count == 1 })
        let positionRows = try await CoreDataStack.shared.performBackgroundTask { context in
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PositionSnapshotEntity"))
        }
        XCTAssertEqual(positionRows, 4, "a deleted snapshot takes its position rows with it")

        let second = try await HistoricalStoreCompaction().compact(heldSymbols: ["AAA", "ALIAS"], now: now, calendar: calendar)
        XCTAssertEqual(second.total, 0)
    }

    /// The app's store is SQLite, where rows are deleted directly rather than
    /// through managed objects, and the weekly copy is taken from the open store.
    func testCompactionAndWeeklyCopyOnASQLiteStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CoreDataStack.shared.persistentContainer.managedObjectModel
        let container = NSPersistentContainer(name: "StockbarDataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("store.sqlite"))
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError)
        let context = container.newBackgroundContext()

        try context.performAndWait {
            for snapshot in [price("AAA", daysAgo: 60, hour: 9, price: 1), price("AAA", daysAgo: 60, hour: 16, price: 2),
                             price("AAA", daysAgo: 5, hour: 9, price: 3), price("GONE", daysAgo: 200, hour: 9)] {
                _ = PriceSnapshotEntity.fromPriceSnapshot(snapshot, in: context)
            }
            for snapshot in [portfolio(daysAgo: 120, hour: 9), portfolio(daysAgo: 120, hour: 16)] {
                _ = PortfolioSnapshotEntity.fromHistoricalPortfolioSnapshot(snapshot, in: context)
            }
            try context.save()

            let result = try HistoricalStoreCompaction.compact(in: context, heldSymbols: ["AAA"], now: now, calendar: calendar)

            XCTAssertEqual(result, .init(priceRowsDeleted: 1, portfolioSnapshotsDeleted: 1, unheldPriceRowsDeleted: 1))
            context.reset()
            let request: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            XCTAssertEqual(try context.fetch(request).map(\.price), [2, 3])
            XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PortfolioSnapshotEntity")), 1)
            XCTAssertEqual(try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "PositionSnapshotEntity")), 1)
        }

        var tick = 0.0
        let recovery = CoreDataStoreRecovery(
            recoveryRoot: directory.appendingPathComponent("StoreRecovery", isDirectory: true),
            timestampProvider: { tick += 1; return Date(timeIntervalSince1970: 1_790_000_000 + tick) }
        )
        let storeURL = try XCTUnwrap(container.persistentStoreCoordinator.persistentStores.first?.url)
        var copies: [URL] = []
        for _ in 0..<3 {
            copies.append(try recovery.createScheduledSafetyCopy(of: storeURL, model: model, keeping: 2))
        }

        XCTAssertEqual(copies.map { FileManager.default.fileExists(atPath: $0.path) }, [false, true, true])
        let summary = try CoreDataStoreTransfer.validateStore(at: copies[2], model: model)
        XCTAssertEqual(summary.priceSnapshotCount, 2)
        XCTAssertEqual(summary.portfolioSnapshotCount, 1)
    }

    func testUKScaleRepairRetriesSymbolsItHadToSkip() async throws {
        let suite = TestDefaultsSuite.makeName("UKScaleRepair-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaultsSuite.remove(suite) }
        let marker = "priceSnapshots.uk-scale-repair.version"
        // Two rows are too few to trust as their own reference.
        try await service.savePriceSnapshots([price("TEST.L", daysAgo: 2, hour: 9, price: 8.5),
                                              price("TEST.L", daysAgo: 1, hour: 9, price: 8.6)])
        // A second handle on the same suite: the actor keeps its own.
        let repair = UKPriceSnapshotScaleMigrationService(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))

        _ = await repair.migrateIfNeeded()
        XCTAssertEqual(defaults.integer(forKey: marker), 0, "a skipped symbol leaves the repair to run again")

        _ = await repair.migrateIfNeeded(savedQuotes: ["TEST.L": 8.6])
        XCTAssertEqual(defaults.integer(forKey: marker), 1)
    }

    func testUKScaleRepairGivesUpAfterAFewLaunches() async throws {
        let suite = TestDefaultsSuite.makeName("UKScaleRepair-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { TestDefaultsSuite.remove(suite) }
        try await service.savePriceSnapshots([price("TEST.L", daysAgo: 1, hour: 9, price: 8.6)])
        // A second handle on the same suite: the actor keeps its own.
        let repair = UKPriceSnapshotScaleMigrationService(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))

        for attempt in 1...UKPriceSnapshotScaleMigrationService.maxAttempts {
            XCTAssertEqual(defaults.integer(forKey: "priceSnapshots.uk-scale-repair.version"), 0, "before attempt \(attempt)")
            _ = await repair.migrateIfNeeded()
        }

        XCTAssertEqual(defaults.integer(forKey: "priceSnapshots.uk-scale-repair.version"), 1)
    }

    func testOtherSymbolsAreLeftAloneWhenTheHoldingsAreUnknown() async throws {
        try await service.savePriceSnapshots([price("GONE", daysAgo: 200, hour: 9)])

        let result = try await HistoricalStoreCompaction().compact(heldSymbols: nil, now: now, calendar: calendar)

        XCTAssertEqual(result.total, 0)
    }

    func testMaintenanceIsWeekly() {
        XCTAssertTrue(StoreMaintenance.isDue(lastRun: nil, now: now))
        XCTAssertFalse(StoreMaintenance.isDue(lastRun: now.addingTimeInterval(-6 * 86_400), now: now))
        XCTAssertTrue(StoreMaintenance.isDue(lastRun: now.addingTimeInterval(-7 * 86_400), now: now))
        XCTAssertTrue(StoreMaintenance.isDue(lastRun: now.addingTimeInterval(86_400), now: now), "clock set back")
    }

    func testAnUnchangedPriceIsRecordedOnceAnHour() {
        let last = price("AAA", daysAgo: 0, hour: 0)
        func next(after seconds: TimeInterval, price: Double = 10, previousClose: Double = 9) -> PriceSnapshot {
            PriceSnapshot(timestamp: last.timestamp.addingTimeInterval(seconds), price: price,
                          previousClose: previousClose, volume: nil, symbol: "AAA")
        }

        XCTAssertTrue(HistoricalDataManager.shouldRecordPrice(last, after: nil))
        XCTAssertFalse(HistoricalDataManager.shouldRecordPrice(next(after: 300), after: last))
        XCTAssertTrue(HistoricalDataManager.shouldRecordPrice(next(after: 300, price: 10.01), after: last))
        XCTAssertTrue(HistoricalDataManager.shouldRecordPrice(next(after: 300, previousClose: 10), after: last))
        XCTAssertTrue(HistoricalDataManager.shouldRecordPrice(next(after: 3600), after: last))
    }

    func testSnapshotIsDueWhenARefreshLandsSlightlyEarly() {
        XCTAssertTrue(HistoricalDataManager.isSnapshotDue(elapsed: 299.4, interval: 300))
        XCTAssertTrue(HistoricalDataManager.isSnapshotDue(elapsed: 270, interval: 300))
        XCTAssertFalse(HistoricalDataManager.isSnapshotDue(elapsed: 200, interval: 300))
    }

    @MainActor
    func testOnlyHeldPositionsAreStoredWithASnapshot() {
        func trade(_ name: String, units: String, watchOnly: Bool = false) -> RealTimeTrade {
            var info = TradingInfo()
            info.currentPrice = 5
            info.currency = "GBP"
            return RealTimeTrade(
                trade: Trade(name: name, position: Position(unitSize: units, positionAvgCost: "1"), isWatchlistOnly: watchOnly),
                realTimeInfo: info
            )
        }

        let stored = HistoricalDataManager.storedPositions(from: [
            trade("HELD", units: "2"), trade("ZERO", units: "0"), trade("WATCH", units: "3", watchOnly: true)
        ])

        XCTAssertEqual(Array(stored.keys), ["HELD"])
        XCTAssertEqual(stored["HELD"]?.valueAtDate, 10)
    }
}
