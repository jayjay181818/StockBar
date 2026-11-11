//
//  OHLCDataService.swift
//  Stockbar
//
//  Created for UI/UX Enhancement v2.3.0 - Phase 1B
//  OHLC (Open, High, Low, Close) data management service
//

import CoreData
import Foundation

/// Service for managing OHLC candlestick data in Core Data
/// Provides storage, retrieval, and cleanup operations for chart data
actor OHLCDataService {
    // MARK: - Properties

    private let coreDataStack: CoreDataStack

    // MARK: - Configuration

    /// Maximum number of OHLC snapshots to keep per symbol
    private let maxSnapshotsPerSymbol = 10000

    // MARK: - Initialization

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Public Methods

    /// Upsert multiple OHLC snapshots (batch operation).
    ///
    /// A candle is identified by symbol + interval + timestamp. Existing rows are
    /// updated in place so a still-forming candle picks up its final OHLC/volume.
    func saveSnapshots(_ snapshots: [OHLCSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        let context = coreDataStack.newBackgroundContext()

        try await context.perform {
            let groups = Dictionary(grouping: snapshots) { SnapshotGroupKey(symbol: $0.symbol, interval: $0.interval) }
            for (key, group) in groups {
                let existing = try self.existingEntities(
                    symbol: key.symbol,
                    interval: key.interval,
                    timestamps: group.map(\.timestamp),
                    context: context
                )
                var byTimestamp: [Date: OHLCSnapshotEntity] = [:]
                for entity in existing {
                    guard let timestamp = entity.timestamp else { continue }
                    if byTimestamp[timestamp] == nil {
                        byTimestamp[timestamp] = entity
                    } else {
                        // Collapse duplicates left over from earlier versions.
                        context.delete(entity)
                    }
                }

                for snapshot in group {
                    let entity: OHLCSnapshotEntity
                    if let found = byTimestamp[snapshot.timestamp] {
                        entity = found
                    } else {
                        entity = OHLCSnapshotEntity(context: context)
                        entity.id = UUID()
                        entity.symbol = snapshot.symbol
                        entity.timestamp = snapshot.timestamp
                        byTimestamp[snapshot.timestamp] = entity
                    }
                    entity.interval = snapshot.interval
                    entity.openPrice = snapshot.open
                    entity.highPrice = snapshot.high
                    entity.lowPrice = snapshot.low
                    entity.closePrice = snapshot.close
                    // Folync overlays are never passed to this persistence path. Keep
                    // the legacy Core Data model non-optional for local-provider rows.
                    entity.volume = snapshot.volume ?? 0
                }
            }

            try context.save()

            // Cleanup old snapshots for all affected symbols
            let symbols = Set(snapshots.map { $0.symbol })
            for symbol in symbols {
                try self.cleanupOldSnapshots(symbol: symbol, context: context)
            }
        }
    }

    /// Fetch cached candles for one symbol at one interval (nil matches only
    /// rows stored before intervals were recorded).
    func fetchSnapshots(
        symbol: String,
        interval: String?,
        startDate: Date?,
        endDate: Date?
    ) async throws -> [OHLCSnapshot] {
        let context = coreDataStack.newBackgroundContext()

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            var predicates = [Self.symbolIntervalPredicate(symbol: symbol, interval: interval)]
            if let startDate {
                predicates.append(NSPredicate(format: "timestamp >= %@", startDate as NSDate))
            }
            if let endDate {
                predicates.append(NSPredicate(format: "timestamp <= %@", endDate as NSDate))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            return try context.fetch(request).map(Self.snapshot(from:))
        }
    }

    /// Fetch OHLC snapshots for a symbol within an optional date range
    func fetchSnapshots(
        symbol: String,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [OHLCSnapshot] {
        let context = coreDataStack.newBackgroundContext()

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()

            if let start = startDate, let end = endDate {
                request.predicate = NSPredicate(
                    format: "symbol == %@ AND timestamp >= %@ AND timestamp <= %@",
                    symbol,
                    start as NSDate,
                    end as NSDate
                )
            } else if let start = startDate {
                request.predicate = NSPredicate(
                    format: "symbol == %@ AND timestamp >= %@",
                    symbol,
                    start as NSDate
                )
            } else if let end = endDate {
                request.predicate = NSPredicate(
                    format: "symbol == %@ AND timestamp <= %@",
                    symbol,
                    end as NSDate
                )
            } else {
                request.predicate = NSPredicate(format: "symbol == %@", symbol)
            }

            request.sortDescriptors = [
                NSSortDescriptor(key: "timestamp", ascending: true)
            ]

            let entities = try context.fetch(request)
            return entities.map { entity in
                OHLCSnapshot(
                    symbol: entity.symbol ?? "",
                    timestamp: entity.timestamp ?? Date(),
                    open: entity.openPrice,
                    high: entity.highPrice,
                    low: entity.lowPrice,
                    close: entity.closePrice,
                    volume: entity.volume
                )
            }
        }
    }

    /// Fetch OHLC snapshots for a symbol within a date range
    func fetchSnapshots(
        symbol: String,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [OHLCSnapshot] {
        let context = coreDataStack.newBackgroundContext()

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(
                format: "symbol == %@ AND timestamp >= %@ AND timestamp <= %@",
                symbol,
                startDate as NSDate,
                endDate as NSDate
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "timestamp", ascending: true)
            ]

            let entities = try context.fetch(request)
            return entities.map { entity in
                OHLCSnapshot(
                    symbol: entity.symbol ?? "",
                    timestamp: entity.timestamp ?? Date(),
                    open: entity.openPrice,
                    high: entity.highPrice,
                    low: entity.lowPrice,
                    close: entity.closePrice,
                    volume: entity.volume
                )
            }
        }
    }

    /// Delete all OHLC snapshots for a symbol
    func deleteSnapshots(symbol: String) async throws {
        let context = coreDataStack.newBackgroundContext()

        try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "symbol == %@", symbol)

            let entities = try context.fetch(request)
            for entity in entities {
                context.delete(entity)
            }

            try context.save()
        }
    }

    // MARK: - Private Methods

    private struct SnapshotGroupKey: Hashable {
        let symbol: String
        let interval: String?
    }

    private nonisolated static func symbolIntervalPredicate(symbol: String, interval: String?) -> NSPredicate {
        if let interval {
            return NSPredicate(format: "symbol == %@ AND interval == %@", symbol, interval)
        }
        return NSPredicate(format: "symbol == %@ AND interval == nil", symbol)
    }

    private nonisolated static func snapshot(from entity: OHLCSnapshotEntity) -> OHLCSnapshot {
        OHLCSnapshot(
            symbol: entity.symbol ?? "",
            timestamp: entity.timestamp ?? Date(),
            open: entity.openPrice,
            high: entity.highPrice,
            low: entity.lowPrice,
            close: entity.closePrice,
            volume: entity.volume,
            interval: entity.interval
        )
    }

    /// Stored rows for the same symbol + interval within the timestamp span of a batch.
    private nonisolated func existingEntities(
        symbol: String,
        interval: String?,
        timestamps: [Date],
        context: NSManagedObjectContext
    ) throws -> [OHLCSnapshotEntity] {
        guard let first = timestamps.min(), let last = timestamps.max() else { return [] }
        let request = OHLCSnapshotEntity.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            Self.symbolIntervalPredicate(symbol: symbol, interval: interval),
            NSPredicate(format: "timestamp >= %@ AND timestamp <= %@", first as NSDate, last as NSDate)
        ])
        return try context.fetch(request)
    }

    /// Clean up old snapshots to maintain the maximum limit per symbol
    private nonisolated func cleanupOldSnapshots(
        symbol: String,
        context: NSManagedObjectContext
    ) throws {
        let request = OHLCSnapshotEntity.fetchRequest()
        request.predicate = NSPredicate(format: "symbol == %@", symbol)
        // Counting is one indexed query; loading every row after each save was not.
        guard try context.count(for: request) > maxSnapshotsPerSymbol else { return }

        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchOffset = maxSnapshotsPerSymbol
        for entity in try context.fetch(request) {
            context.delete(entity)
        }
        try context.save()
    }
}

// MARK: - OHLC Snapshot Model

/// In-memory representation of an OHLC candlestick data point
struct OHLCSnapshot: Codable, Identifiable, Sendable {
    let id: UUID
    let symbol: String
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// Nil for a non-persisted provider overlay when volume is unavailable.
    let volume: Int64?
    /// yfinance interval the candle was fetched at (for example "5m" or "1d").
    /// Nil for rows stored before intervals were recorded.
    let interval: String?

    init(
        id: UUID = UUID(),
        symbol: String,
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int64?,
        interval: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.interval = interval
    }

    /// Calculate the change from open to close
    var change: Double {
        close - open
    }

    /// Calculate the percentage change from open to close
    var changePercent: Double {
        guard open > 0 else { return 0 }
        return (change / open) * 100
    }

    /// Determine if this is a bullish (green) candle
    var isBullish: Bool {
        close >= open
    }

    /// Calculate the range (high - low)
    var range: Double {
        high - low
    }

    /// Calculate the body size (abs(close - open))
    var bodySize: Double {
        abs(close - open)
    }

    /// Calculate the upper wick size
    var upperWick: Double {
        high - max(open, close)
    }

    /// Calculate the lower wick size
    var lowerWick: Double {
        min(open, close) - low
    }
}
