//
//  OHLCDataService.swift
//  Stockbar
//
//  Created for UI/UX Enhancement v2.3.0 - Phase 1B
//  OHLC (Open, High, Low, Close) data management service
//

import Foundation
import CoreData

/// Service for managing OHLC candlestick data in Core Data
/// Provides storage, retrieval, and cleanup operations for chart data
actor OHLCDataService {
    // MARK: - Properties

    private let coreDataStack: CoreDataStack

    // MARK: - Configuration

    /// Maximum number of OHLC snapshots to keep per symbol
    private let maxSnapshotsPerSymbol = 10000

    /// Minimum interval between OHLC snapshots (to prevent duplicates)
    private let minimumSnapshotInterval: TimeInterval = 60 // 1 minute

    // MARK: - Initialization

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Public Methods

    /// Save a single OHLC snapshot
    func saveSnapshot(
        symbol: String,
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int64
    ) async throws {
        let context = coreDataStack.newBackgroundContext()

        try await context.perform {
            // Check for duplicate within minimum interval
            if try self.hasDuplicateSnapshot(
                symbol: symbol,
                timestamp: timestamp,
                context: context
            ) {
                return // Skip duplicate
            }

            // Create new snapshot
            let snapshot = OHLCSnapshotEntity(context: context)
            snapshot.id = UUID()
            snapshot.symbol = symbol
            snapshot.timestamp = timestamp
            snapshot.openPrice = open
            snapshot.highPrice = high
            snapshot.lowPrice = low
            snapshot.closePrice = close
            snapshot.volume = volume

            try context.save()

            // Cleanup old snapshots
            try self.cleanupOldSnapshots(symbol: symbol, context: context)
        }
    }

    /// Save multiple OHLC snapshots (batch operation)
    func saveSnapshots(_ snapshots: [OHLCSnapshot]) async throws {
        let context = coreDataStack.newBackgroundContext()

        try await context.perform {
            for snapshot in snapshots {
                // Check for duplicate
                if try self.hasDuplicateSnapshot(
                    symbol: snapshot.symbol,
                    timestamp: snapshot.timestamp,
                    context: context
                ) {
                    continue // Skip duplicate
                }

                // Create entity
                let entity = OHLCSnapshotEntity(context: context)
                entity.id = UUID()
                entity.symbol = snapshot.symbol
                entity.timestamp = snapshot.timestamp
                entity.openPrice = snapshot.open
                entity.highPrice = snapshot.high
                entity.lowPrice = snapshot.low
                entity.closePrice = snapshot.close
                entity.volume = snapshot.volume
            }

            try context.save()

            // Cleanup old snapshots for all affected symbols
            let symbols = Set(snapshots.map { $0.symbol })
            for symbol in symbols {
                try self.cleanupOldSnapshots(symbol: symbol, context: context)
            }
        }
    }

    /// Fetch OHLC snapshots for a symbol within an optional date range
    func fetchSnapshots(
        symbol: String,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [OHLCSnapshot] {
        let context = coreDataStack.viewContext

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
        let context = coreDataStack.viewContext

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

    /// Fetch the most recent OHLC snapshot for a symbol
    func fetchLatestSnapshot(symbol: String) async throws -> OHLCSnapshot? {
        let context = coreDataStack.viewContext

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "symbol == %@", symbol)
            request.sortDescriptors = [
                NSSortDescriptor(key: "timestamp", ascending: false)
            ]
            request.fetchLimit = 1

            guard let entity = try context.fetch(request).first else {
                return nil
            }

            return OHLCSnapshot(
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

    /// Delete OHLC snapshots older than a specified date
    func deleteSnapshotsOlderThan(date: Date) async throws {
        let context = coreDataStack.newBackgroundContext()

        try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "timestamp < %@", date as NSDate)

            let entities = try context.fetch(request)
            for entity in entities {
                context.delete(entity)
            }

            try context.save()
        }
    }

    /// Get count of OHLC snapshots for a symbol
    func getSnapshotCount(symbol: String) async throws -> Int {
        let context = coreDataStack.viewContext

        return try await context.perform {
            let request = OHLCSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "symbol == %@", symbol)
            return try context.count(for: request)
        }
    }

    // MARK: - Private Methods

    /// Check if a snapshot already exists within the minimum interval
    private nonisolated func hasDuplicateSnapshot(
        symbol: String,
        timestamp: Date,
        context: NSManagedObjectContext
    ) throws -> Bool {
        let startRange = timestamp.addingTimeInterval(-minimumSnapshotInterval)
        let endRange = timestamp.addingTimeInterval(minimumSnapshotInterval)

        let request = OHLCSnapshotEntity.fetchRequest()
        request.predicate = NSPredicate(
            format: "symbol == %@ AND timestamp >= %@ AND timestamp <= %@",
            symbol,
            startRange as NSDate,
            endRange as NSDate
        )
        request.fetchLimit = 1

        let count = try context.count(for: request)
        return count > 0
    }

    /// Clean up old snapshots to maintain the maximum limit per symbol
    private nonisolated func cleanupOldSnapshots(
        symbol: String,
        context: NSManagedObjectContext
    ) throws {
        let request = OHLCSnapshotEntity.fetchRequest()
        request.predicate = NSPredicate(format: "symbol == %@", symbol)
        request.sortDescriptors = [
            NSSortDescriptor(key: "timestamp", ascending: false)
        ]

        let entities = try context.fetch(request)

        // Delete excess snapshots (keep newest)
        if entities.count > maxSnapshotsPerSymbol {
            let entitiesToDelete = entities.dropFirst(maxSnapshotsPerSymbol)
            for entity in entitiesToDelete {
                context.delete(entity)
            }
            try context.save()
        }
    }
}

// MARK: - OHLC Snapshot Model

/// In-memory representation of an OHLC candlestick data point
struct OHLCSnapshot: Codable, Identifiable {
    let id: UUID
    let symbol: String
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int64

    init(
        id: UUID = UUID(),
        symbol: String,
        timestamp: Date,
        open: Double,
        high: Double,
        low: Double,
        close: Double,
        volume: Int64
    ) {
        self.id = id
        self.symbol = symbol
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
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
