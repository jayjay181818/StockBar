@preconcurrency import CoreData
import Foundation

/// Thins stored history to the resolution the app reads back.
///
/// Every launch loads the price table and keeps all points from the last 31
/// days plus one point per earlier day; the portfolio table is read the same
/// way with a 90-day window. The rows in between were written every few
/// minutes and never read again, so the store grew by about 165 MB a year.
/// This deletes exactly those rows, and price rows for symbols that left the
/// portfolio long ago.
struct HistoricalStoreCompaction: Sendable {
    struct Result: Equatable, Sendable {
        var priceRowsDeleted = 0
        var portfolioSnapshotsDeleted = 0
        var unheldPriceRowsDeleted = 0

        var total: Int { priceRowsDeleted + portfolioSnapshotsDeleted + unheldPriceRowsDeleted }
    }

    /// Days of price history kept at full resolution, as `thinnedPriceHistory` keeps in memory.
    static let priceFullResolutionDays = 31
    /// Price rows of a symbol no longer held are kept until its newest row is this old.
    static let unheldRetentionDays = 90

    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Of the rows before `cutoff`, every one that is not the last of its
    /// group and calendar day. Rows must be sorted by group, then time.
    static func redundantRows<ID>(
        _ rows: [(group: String, timestamp: Date, id: ID)],
        before cutoff: Date,
        calendar: Calendar = .current
    ) -> [ID] {
        var redundant: [ID] = []
        var previous: (group: String, day: Date, id: ID)?
        for row in rows where row.timestamp < cutoff {
            let day = calendar.startOfDay(for: row.timestamp)
            if let previous, previous.group == row.group, previous.day == day {
                redundant.append(previous.id)
            }
            previous = (row.group, day, row.id)
        }
        return redundant
    }

    /// `heldSymbols` are the symbols in the portfolio now, with their aliases,
    /// upper-cased. Pass nil to leave other symbols' rows alone.
    func compact(
        heldSymbols: Set<String>?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> Result {
        try await coreDataStack.performBackgroundTask { context in
            try Self.compact(in: context, heldSymbols: heldSymbols, now: now, calendar: calendar)
        }
    }

    static func compact(
        in context: NSManagedObjectContext,
        heldSymbols: Set<String>?,
        now: Date,
        calendar: Calendar = .current
    ) throws -> Result {
        let today = calendar.startOfDay(for: now)
        guard let priceCutoff = calendar.date(byAdding: .day, value: -Self.priceFullResolutionDays, to: today),
              let portfolioCutoff = calendar.date(
                byAdding: .day, value: -HistoricalDataManager.fullResolutionPortfolioDays, to: today
              ),
              let unheldCutoff = calendar.date(byAdding: .day, value: -Self.unheldRetentionDays, to: today) else {
            return Result()
        }
        var result = Result()

        if let heldSymbols {
            for (symbol, newest) in try newestPriceRowBySymbol(in: context)
            where !heldSymbols.contains(symbol.uppercased()) && newest < unheldCutoff {
                let ids = try objectIDs(
                    entityName: "PriceSnapshotEntity",
                    predicate: NSPredicate(format: "symbol == %@", symbol),
                    in: context
                )
                try delete(ids, in: context)
                result.unheldPriceRowsDeleted += ids.count
            }
        }

        let priceRows = try rows(
            entityName: "PriceSnapshotEntity", groupKey: "symbol", before: priceCutoff, in: context
        )
        let redundantPrices = redundantRows(priceRows, before: priceCutoff, calendar: calendar)
        try delete(redundantPrices, in: context)
        result.priceRowsDeleted = redundantPrices.count

        let portfolioRows = try rows(
            entityName: "PortfolioSnapshotEntity", groupKey: "currency", before: portfolioCutoff, in: context
        )
        let redundantPortfolio = redundantRows(portfolioRows, before: portfolioCutoff, calendar: calendar)
        // Deleted as objects so each snapshot's position rows go with it.
        try delete(redundantPortfolio, in: context, cascading: true)
        result.portfolioSnapshotsDeleted = redundantPortfolio.count

        return result
    }

    private static func rows(
        entityName: String,
        groupKey: String,
        before cutoff: Date,
        in context: NSManagedObjectContext
    ) throws -> [(group: String, timestamp: Date, id: NSManagedObjectID)] {
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)
        request.propertiesToFetch = [objectIDExpression, groupKey, "timestamp"]
        request.sortDescriptors = [
            NSSortDescriptor(key: groupKey, ascending: true),
            NSSortDescriptor(key: "timestamp", ascending: true)
        ]
        return try context.fetch(request).compactMap { row in
            guard let id = row["objectID"] as? NSManagedObjectID,
                  let timestamp = row["timestamp"] as? Date else { return nil }
            return (row[groupKey] as? String ?? "", timestamp, id)
        }
    }

    /// One small indexed query per symbol; a GROUP BY would be a single
    /// query but only SQLite stores support it.
    private static func newestPriceRowBySymbol(in context: NSManagedObjectContext) throws -> [String: Date] {
        let symbolsRequest = NSFetchRequest<NSDictionary>(entityName: "PriceSnapshotEntity")
        symbolsRequest.resultType = .dictionaryResultType
        symbolsRequest.propertiesToFetch = ["symbol"]
        symbolsRequest.returnsDistinctResults = true
        let symbols = Set(try context.fetch(symbolsRequest).compactMap { $0["symbol"] as? String })

        var result: [String: Date] = [:]
        for symbol in symbols {
            let request = NSFetchRequest<NSDictionary>(entityName: "PriceSnapshotEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["timestamp"]
            request.predicate = NSPredicate(format: "symbol == %@", symbol)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.fetchLimit = 1
            if let date = try context.fetch(request).first?["timestamp"] as? Date {
                result[symbol] = date
            }
        }
        return result
    }

    private static func objectIDs(
        entityName: String,
        predicate: NSPredicate,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObjectID] {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
        request.resultType = .managedObjectIDResultType
        request.predicate = predicate
        return try context.fetch(request)
    }

    private static var objectIDExpression: NSExpressionDescription {
        let description = NSExpressionDescription()
        description.name = "objectID"
        description.expression = NSExpression.expressionForEvaluatedObject()
        description.expressionResultType = .objectIDAttributeType
        return description
    }

    /// Deletes in chunks so no single transaction holds hundreds of thousands
    /// of rows. A SQLite store deletes rows directly; other stores (tests run
    /// in memory) and cascading deletes go through managed objects.
    private static func delete(
        _ ids: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        cascading: Bool = false
    ) throws {
        let stores = context.persistentStoreCoordinator?.persistentStores ?? []
        let canBatchDelete = !cascading && !stores.isEmpty && stores.allSatisfy { $0.type == NSSQLiteStoreType }
        for chunk in ids.chunked(into: canBatchDelete ? 20_000 : 500) {
            if canBatchDelete {
                try context.execute(NSBatchDeleteRequest(objectIDs: chunk))
            } else {
                for id in chunk {
                    context.delete(context.object(with: id))
                }
                try context.save()
                context.reset()
            }
        }
    }
}
