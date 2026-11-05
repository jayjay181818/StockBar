@preconcurrency import CoreData
import Foundation

/// Rescales UK OHLC rows that were persisted in pence (GBX) before
/// `get_ohlc_data.py` learned to convert GBX -> GBP.
///
/// Every row in `OHLCSnapshotEntity` is written by exactly one code path —
/// `OHLCFetchService.fetchOHLCDataWithSource`, which persists the output of
/// `get_ohlc_data.py`. Folync-sourced candles return before that save and are
/// never stored, and `NetworkService.fetchBatchOHLCData` has no callers. So
/// prior to this migration, every stored UK row is in pence and no stored row
/// is already in pounds — which makes a blanket rescale of UK symbols safe.
///
/// The migration runs once, guarded by a version marker, because it is not
/// idempotent: applying it twice would divide correct GBP values by 100 again.
///
/// Version 1 divided every UK row by 100, but London lines quoted in USD or GBP
/// (such as CSPX.L) were already in major units and ended up 100x too low.
/// Version 2 deletes the stored UK candles instead: they are a cache that
/// `get_ohlc_data.py` refetches using the provider's reported currency.
actor OHLCPenceMigrationService {
    static let shared = OHLCPenceMigrationService()

    /// Bump this if the migration ever needs to run again for a new reason.
    private static let migrationVersion = 2
    private static let markerKey = "ohlc.pence-rescale.version"

    private let coreDataStack: CoreDataStack
    private let defaults: UserDefaults

    init(
        coreDataStack: CoreDataStack = .shared,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults
    ) {
        self.coreDataStack = coreDataStack
        self.defaults = defaults
    }

    /// Removes cached UK OHLC rows exactly once so they are refetched with the
    /// correct scale.
    @discardableResult
    func migrateIfNeeded() async -> Int {
        guard defaults.integer(forKey: Self.markerKey) < Self.migrationVersion else {
            return 0
        }

        do {
            let removed = try await deleteUKSnapshots()
            defaults.set(Self.migrationVersion, forKey: Self.markerKey)
            await Logger.shared.info(
                "🔄 MIGRATION: removed \(removed) cached UK OHLC rows; they are refetched in the reported currency"
            )
            return removed
        } catch {
            // Leave the marker unset so the migration retries next launch rather
            // than silently leaving half-converted data behind.
            await Logger.shared.error(
                "🔄 MIGRATION: UK OHLC rescale failed, will retry next launch: \(error.localizedDescription)"
            )
            return 0
        }
    }

    private func deleteUKSnapshots() async throws -> Int {
        let context = coreDataStack.newBackgroundContext()

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            // Core Data has no ENDSWITH-any-of, so match the suffixes explicitly.
            request.predicate = NSPredicate(
                format: "symbol ENDSWITH[c] %@ OR symbol ENDSWITH[c] %@ OR symbol ENDSWITH[c] %@",
                ".L", ".LON", ".XC"
            )

            let entities = try context.fetch(request)
            guard !entities.isEmpty else { return 0 }

            for entity in entities {
                context.delete(entity)
            }

            try context.save()
            return entities.count
        }
    }
}
