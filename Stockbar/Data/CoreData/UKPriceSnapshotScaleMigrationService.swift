@preconcurrency import CoreData
import Foundation

/// One-time repair of UK price snapshots stored on the wrong pence/pound scale.
///
/// Unlike OHLC rows (all pence before their fix), stored price snapshots can mix
/// scales within one symbol, so a blanket ÷100 is unsafe. The reference is the
/// app's saved quote for the symbol (the current pipeline normalises GBX once at
/// the provider boundary). Without one, the newest stored row is used only when
/// the latest few rows agree on a scale; otherwise the symbol is skipped as
/// ambiguous. Rows more than `UKPriceScale.mismatchRatio` from the reference are
/// rescaled by 100, and their original values are saved to a JSON file first.
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
    func migrateIfNeeded(savedQuotes: [String: Double] = [:]) async -> Set<String> {
        guard defaults.integer(forKey: Self.markerKey) < Self.migrationVersion else {
            return []
        }
        do {
            let (rows, symbols) = try await repairStoredSnapshots(savedQuotes: savedQuotes)
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

    /// Rows that must agree on a scale before the newest one can be the reference.
    static let agreeingRowsWithoutQuote = 3

    /// Pure core: rescales rows relative to `savedQuote`, or to the newest valid
    /// row when the latest rows agree. Nil means the reference is ambiguous and the
    /// symbol must be left alone.
    static func repairedRows(_ rows: [Row], symbol: String, savedQuote: Double? = nil) -> [Row]? {
        let valid = rows
            .filter { $0.price.isFinite && $0.price > 0 }
            .sorted { $0.timestamp > $1.timestamp }
        guard !valid.isEmpty else { return rows }

        let reference: Double
        if let savedQuote, savedQuote.isFinite, savedQuote > 0 {
            reference = savedQuote
        } else {
            let latest = valid.prefix(agreeingRowsWithoutQuote)
            guard latest.count == agreeingRowsWithoutQuote,
                  latest.allSatisfy({ UKPriceScale.normalized($0.price, reference: valid[0].price, symbol: symbol) == $0.price })
            else { return nil }
            reference = valid[0].price
        }
        return rows.map { row in
            var repaired = row
            repaired.price = UKPriceScale.normalized(row.price, reference: reference, symbol: symbol)
            repaired.previousClose = UKPriceScale.normalized(row.previousClose, reference: reference, symbol: symbol)
            return repaired
        }
    }

    struct OriginalValue: Codable {
        var symbol: String
        var timestamp: Date
        var price: Double
        var previousClose: Double
    }

    private func repairStoredSnapshots(savedQuotes: [String: Double]) async throws -> (rows: Int, symbols: Set<String>) {
        let context = coreDataStack.newBackgroundContext()
        let backupDirectory = StockbarRuntimeStorage.stockbarApplicationSupportDirectory()
            .appendingPathComponent("Backups", isDirectory: true)
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
            var skippedSymbols: [String] = []
            var originals: [OriginalValue] = []
            for (symbol, group) in bySymbol where !symbol.isEmpty {
                let rows = group.map {
                    Row(timestamp: $0.timestamp ?? .distantPast, price: $0.price, previousClose: $0.previousClose)
                }
                guard let repaired = Self.repairedRows(rows, symbol: symbol, savedQuote: savedQuotes[symbol.uppercased()]) else {
                    skippedSymbols.append(symbol)
                    continue
                }
                for (entity, row) in zip(group, repaired) {
                    guard row.price.bitPattern != entity.price.bitPattern
                        || row.previousClose.bitPattern != entity.previousClose.bitPattern else { continue }
                    originals.append(OriginalValue(
                        symbol: symbol,
                        timestamp: entity.timestamp ?? .distantPast,
                        price: entity.price,
                        previousClose: entity.previousClose
                    ))
                    entity.price = row.price
                    entity.previousClose = row.previousClose
                    changedRows += 1
                    changedSymbols.insert(symbol)
                }
            }
            if !skippedSymbols.isEmpty {
                Logger.shared.post(.warning, "🔄 MIGRATION: skipped UK scale repair for \(skippedSymbols.sorted().joined(separator: ", ")): no reliable reference price")
            }
            if context.hasChanges {
                // Keep the values being replaced, so a wrong repair can be undone.
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
                let stamp = Int(Date().timeIntervalSince1970)
                try encoder.encode(originals).write(
                    to: backupDirectory.appendingPathComponent("uk-price-scale-repair-originals-\(stamp).json"),
                    options: .atomic
                )
                try context.save()
            }
            return (changedRows, changedSymbols)
        }
    }
}
