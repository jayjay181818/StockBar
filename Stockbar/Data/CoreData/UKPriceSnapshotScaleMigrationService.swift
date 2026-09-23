@preconcurrency import CoreData
import Foundation

/// One-time repair of UK price snapshots stored on the wrong pence/pound scale.
///
/// Unlike OHLC rows (all pence before their fix), stored price snapshots can mix
/// scales within one symbol, so a blanket ÷100 is unsafe. Each symbol's most
/// recent valid snapshot — written by the current pipeline, which normalises
/// GBX once at the provider boundary — is the reference; older rows more than
/// `UKPriceScale.mismatchRatio` away are rescaled by 100.
///
/// Guarded by a version marker because a second run could compound errors if a
/// reference itself were wrong.
actor UKPriceSnapshotScaleMigrationService {
    static let shared = UKPriceSnapshotScaleMigrationService()

    private static let migrationVersion = 1
    private static let markerKey = "priceSnapshots.uk-scale-repair.version"

    struct Row: Equatable, Sendable {
        var timestamp: Date
        var price: Double
        var previousClose: Double
    }

    private let coreDataStack: CoreDataStack
    private let defaults: UserDefaults

    init(
        coreDataStack: CoreDataStack = .shared,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults
    ) {
        self.coreDataStack = coreDataStack
        self.defaults = defaults
    }

    /// Returns the UK symbols whose stored snapshots were changed.
    @discardableResult
    func migrateIfNeeded() async -> Set<String> {
        guard defaults.integer(forKey: Self.markerKey) < Self.migrationVersion else {
            return []
        }
        do {
            let (rows, symbols) = try await repairStoredSnapshots()
            defaults.set(Self.migrationVersion, forKey: Self.markerKey)
            await Logger.shared.info(
                rows > 0
                    ? "🔄 MIGRATION: rescaled \(rows) UK price snapshots across \(symbols.count) symbols"
                    : "🔄 MIGRATION: no UK price snapshots needed scale repair"
            )
            return symbols
        } catch {
            await Logger.shared.error(
                "🔄 MIGRATION: UK price snapshot repair failed, will retry next launch: \(error.localizedDescription)"
            )
            return []
        }
    }

    /// Pure core: rescales rows relative to the newest valid price.
    static func repairedRows(_ rows: [Row], symbol: String) -> [Row] {
        guard let reference = rows
            .filter({ $0.price.isFinite && $0.price > 0 })
            .max(by: { $0.timestamp < $1.timestamp })?
            .price else {
            return rows
        }
        return rows.map { row in
            var repaired = row
            repaired.price = UKPriceScale.normalized(row.price, reference: reference, symbol: symbol)
            repaired.previousClose = UKPriceScale.normalized(row.previousClose, reference: reference, symbol: symbol)
            return repaired
        }
    }

    private func repairStoredSnapshots() async throws -> (rows: Int, symbols: Set<String>) {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = PriceSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "symbol ENDSWITH[c] %@ OR symbol ENDSWITH[c] %@ OR symbol ENDSWITH[c] %@",
                ".L", ".LON", ".XC"
            )
            let entities = try context.fetch(request)
            let bySymbol = Dictionary(grouping: entities) { $0.symbol ?? "" }

            var changedRows = 0
            var changedSymbols: Set<String> = []
            for (symbol, group) in bySymbol where !symbol.isEmpty {
                let rows = group.map {
                    Row(timestamp: $0.timestamp ?? .distantPast, price: $0.price, previousClose: $0.previousClose)
                }
                let repaired = Self.repairedRows(rows, symbol: symbol)
                for (entity, row) in zip(group, repaired) {
                    guard row.price.bitPattern != entity.price.bitPattern
                        || row.previousClose.bitPattern != entity.previousClose.bitPattern else { continue }
                    entity.price = row.price
                    entity.previousClose = row.previousClose
                    changedRows += 1
                    changedSymbols.insert(symbol)
                }
            }
            if context.hasChanges {
                try context.save()
            }
            return (changedRows, changedSymbols)
        }
    }
}
