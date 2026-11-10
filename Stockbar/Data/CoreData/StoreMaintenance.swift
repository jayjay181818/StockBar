@preconcurrency import CoreData
import Foundation

/// Weekly upkeep of the Core Data store: a safety copy, then compaction of
/// history rows the app no longer reads. Nothing is deleted unless the copy
/// was made first.
actor StoreMaintenance {
    static let shared = StoreMaintenance()

    static let interval: TimeInterval = 7 * 86_400
    static let lastRunKey = "storeMaintenanceLastRun"
    /// Set after rows were deleted; the next launch reclaims the freed pages.
    static let vacuumPendingKey = "storeVacuumPending"
    static let safetyCopiesKept = 2

    private let coreDataStack: CoreDataStack
    private let defaults: UserDefaults
    private let recovery: CoreDataStoreRecovery
    private var isRunning = false

    init(
        coreDataStack: CoreDataStack = .shared,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults,
        recovery: CoreDataStoreRecovery = CoreDataStoreRecovery()
    ) {
        self.coreDataStack = coreDataStack
        self.defaults = defaults
        self.recovery = recovery
    }

    static func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        // A clock set back must not postpone maintenance for ever.
        return now.timeIntervalSince(lastRun) >= interval || lastRun > now
    }

    /// Runs when a week has passed since the last run. `heldSymbols` as for
    /// `HistoricalStoreCompaction.compact`.
    @discardableResult
    func runIfDue(heldSymbols: Set<String>?, now: Date = Date()) async -> HistoricalStoreCompaction.Result? {
        guard !isRunning,
              coreDataStack.storeLoadState == .loaded,
              Self.isDue(lastRun: defaults.object(forKey: Self.lastRunKey) as? Date, now: now) else { return nil }
        isRunning = true
        defer { isRunning = false }

        let container = coreDataStack.persistentContainer
        if let store = container.persistentStoreCoordinator.persistentStores.first,
           store.type == NSSQLiteStoreType, let storeURL = store.url {
            do {
                let copy = try recovery.createScheduledSafetyCopy(
                    of: storeURL, model: container.managedObjectModel, keeping: Self.safetyCopiesKept
                )
                await Logger.shared.info("Weekly database copy saved to \(copy.deletingLastPathComponent().lastPathComponent)")
            } catch {
                await Logger.shared.error("Weekly database copy failed, so no history was compacted: \(error.localizedDescription)")
                return nil
            }
        }

        do {
            let result = try await HistoricalStoreCompaction(coreDataStack: coreDataStack)
                .compact(heldSymbols: heldSymbols, now: now)
            defaults.set(now, forKey: Self.lastRunKey)
            if result.total > 0 {
                defaults.set(true, forKey: Self.vacuumPendingKey)
            }
            await coreDataStack.purgePersistentHistory(olderThan: 7 * 86_400, now: now)
            await Logger.shared.info(
                "Database compacted: removed \(result.priceRowsDeleted) price rows, "
                + "\(result.portfolioSnapshotsDeleted) portfolio snapshots and "
                + "\(result.unheldPriceRowsDeleted) rows for symbols no longer held"
            )
            return result
        } catch {
            await Logger.shared.error("Database compaction failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension CoreDataStoreRecovery {
    /// Consistent copy of the open store, kept beside the other safety copies
    /// under `StoreRecovery`. Only the `keeping` newest weekly copies stay.
    func createScheduledSafetyCopy(of storeURL: URL, model: NSManagedObjectModel, keeping: Int) throws -> URL {
        let directory = try makeBackupDirectory(prefix: "weekly")
        let destination = directory.appendingPathComponent(storeURL.lastPathComponent)
        do {
            try CoreDataStoreTransfer.copyStore(from: storeURL, to: destination, model: model)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        pruneBackupDirectories(prefix: "weekly", keeping: keeping)
        return destination
    }
}
