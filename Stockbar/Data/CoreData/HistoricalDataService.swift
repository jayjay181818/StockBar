@preconcurrency import CoreData
@preconcurrency import Foundation

protocol HistoricalDataServiceProtocol: Sendable {
    func savePriceSnapshots(_ snapshots: [PriceSnapshot]) async throws
    func fetchPriceSnapshots(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot]
    func fetchAllPriceSnapshots(for symbol: String) async throws -> [PriceSnapshot]
    func fetchStoredPriceSymbols() async throws -> [String]
    func savePortfolioSnapshot(_ snapshot: HistoricalPortfolioSnapshot) async throws
    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async throws -> [HistoricalPortfolioSnapshot]
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot]
    func fetchPortfolioValues(from startDate: Date, to endDate: Date) async throws -> [StoredPortfolioValue]
    func getDataCount(for symbol: String) async throws -> Int
    func getTotalPriceSnapshotCount() async throws -> Int
    func getPortfolioSnapshotCount() async throws -> Int
}

final class CoreDataHistoricalDataService: HistoricalDataServiceProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    /// Portfolio snapshots converted per round trip to the store. Each one
    /// brings its positions with it, so a long history read in one go holds
    /// several times its final size in managed objects while it is converted.
    private let portfolioFetchBatchSize: Int

    init(coreDataStack: CoreDataStack = .shared, portfolioFetchBatchSize: Int = 500) {
        self.coreDataStack = coreDataStack
        self.portfolioFetchBatchSize = max(1, portfolioFetchBatchSize)
    }
    
    // MARK: - Price Snapshots
    
    func savePriceSnapshots(_ snapshots: [PriceSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        
        // Use batch operations for better performance with large datasets
        if snapshots.count > 100 {
            try await savePriceSnapshotsBatch(snapshots)
        } else {
            try await savePriceSnapshotsIndividual(snapshots)
        }
    }
    
    private func savePriceSnapshotsBatch(_ snapshots: [PriceSnapshot]) async throws {
        // First, check for existing snapshots to avoid duplicates
        let existingKeys = try await getExistingSnapshotKeys(for: snapshots)
        
        // Filter out duplicates
        let newSnapshots = snapshots.filter { snapshot in
            let key = "\(snapshot.symbol)_\(snapshot.timestamp.timeIntervalSince1970)"
            return !existingKeys.contains(key)
        }
        
        guard !newSnapshots.isEmpty else {
            Task { await Logger.shared.debug("No new price snapshots to save (all already exist)") }
            return
        }
        
        // Convert to dictionary format for batch insert
        let snapshotDicts: [CoreDataBatchValues] = newSnapshots.map { snapshot in
            return [
                // A batch insert bypasses the entity code that sets the id.
                "id": UUID(),
                "symbol": snapshot.symbol,
                "timestamp": snapshot.timestamp,
                "price": snapshot.price,
                "previousClose": snapshot.previousClose,
                "volume": snapshot.volume
            ]
        }
        
        let insertedCount = try await coreDataStack.performBatchInsert(
            entity: PriceSnapshotEntity.self,
            objects: snapshotDicts,
            batchSize: 1000
        )
        
        Task { await Logger.shared.debug("Batch saved \(insertedCount) price snapshots to Core Data") }
    }
    
    private func savePriceSnapshotsIndividual(_ snapshots: [PriceSnapshot]) async throws {
        try await coreDataStack.performBackgroundTask { context in
            for snapshot in snapshots {
                // Check if snapshot already exists to avoid duplicates
                let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "symbol == %@ AND timestamp == %@", 
                                                   snapshot.symbol, 
                                                   snapshot.timestamp as NSDate)
                fetchRequest.fetchLimit = 1 // Optimize for existence check
                
                let existingSnapshots = try context.fetch(fetchRequest)
                
                if existingSnapshots.isEmpty {
                    _ = PriceSnapshotEntity.fromPriceSnapshot(snapshot, in: context)
                }
            }
            
            Task { await Logger.shared.debug("Saved \(snapshots.count) price snapshots to Core Data") }
        }
    }
    
    private func getExistingSnapshotKeys(for snapshots: [PriceSnapshot]) async throws -> Set<String> {
        return try await coreDataStack.performBackgroundTask { context in
            let symbols = Set(snapshots.map { $0.symbol })
            let timestamps = snapshots.map { $0.timestamp }
            let minTimestamp = timestamps.min() ?? Date()
            let maxTimestamp = timestamps.max() ?? Date()
            
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "symbol IN %@ AND timestamp >= %@ AND timestamp <= %@",
                symbols,
                minTimestamp as NSDate,
                maxTimestamp as NSDate
            )
            fetchRequest.propertiesToFetch = ["symbol", "timestamp"]
            fetchRequest.resultType = .managedObjectResultType
            
            let existingSnapshots = try context.fetch(fetchRequest)
            return Set(existingSnapshots.map { snapshot in
                "\(snapshot.symbol ?? "")_\(snapshot.timestamp?.timeIntervalSince1970 ?? 0)"
            })
        }
    }
    
    func fetchPriceSnapshots(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@ AND timestamp >= %@ AND timestamp <= %@",
                                               symbol,
                                               startDate as NSDate,
                                               endDate as NSDate)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            // Performance optimizations
            fetchRequest.fetchBatchSize = 500
            fetchRequest.includesSubentities = false
            fetchRequest.includesPropertyValues = true
            fetchRequest.returnsObjectsAsFaults = false
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toPriceSnapshot() }
        }
    }
    
    func fetchAllPriceSnapshots(for symbol: String) async throws -> [PriceSnapshot] {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            // Performance optimizations for potentially large datasets
            fetchRequest.fetchBatchSize = 1000
            fetchRequest.includesSubentities = false
            fetchRequest.includesPropertyValues = true
            fetchRequest.returnsObjectsAsFaults = false
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toPriceSnapshot() }
        }
    }
    
    /// Distinct symbols with stored price history.
    func fetchStoredPriceSymbols() async throws -> [String] {
        return try await coreDataStack.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "PriceSnapshotEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["symbol"]
            request.returnsDistinctResults = true
            return try context.fetch(request).compactMap { $0["symbol"] as? String }
        }
    }

    func getDataCount(for symbol: String) async throws -> Int {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            
            return try context.count(for: fetchRequest)
        }
    }
    
    // MARK: - Portfolio Snapshots
    
    func savePortfolioSnapshot(_ snapshot: HistoricalPortfolioSnapshot) async throws {
        try await coreDataStack.performBackgroundTask { context in
            // Check if snapshot already exists to avoid duplicates
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "timestamp == %@", snapshot.date as NSDate)
            
            let existingSnapshots = try context.fetch(fetchRequest)
            
            if existingSnapshots.isEmpty {
                _ = PortfolioSnapshotEntity.fromHistoricalPortfolioSnapshot(snapshot, in: context)
                Task { await Logger.shared.debug("Saved portfolio snapshot to Core Data for \(snapshot.date)") }
            }
        }
    }
    
    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async throws -> [HistoricalPortfolioSnapshot] {
        let batchSize = portfolioFetchBatchSize
        return try await coreDataStack.performBackgroundTask { context in
            try Self.portfolioSnapshots(
                matching: NSPredicate(format: "timestamp >= %@ AND timestamp <= %@",
                                      startDate as NSDate,
                                      endDate as NSDate),
                batchSize: batchSize,
                in: context
            )
        }
    }
    
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot] {
        let batchSize = portfolioFetchBatchSize
        return try await coreDataStack.performBackgroundTask { context in
            try Self.portfolioSnapshots(matching: nil, batchSize: batchSize, in: context)
        }
    }

    /// The date, total and currency of each snapshot in the range, oldest
    /// first. Positions are not read: they are most of a snapshot's rows, and
    /// a chart of the portfolio's value uses none of them.
    func fetchPortfolioValues(from startDate: Date, to endDate: Date) async throws -> [StoredPortfolioValue] {
        return try await coreDataStack.performBackgroundTask { context in
            try Self.portfolioValues(from: startDate, to: endDate, in: context)
        }
    }

    static func portfolioValues(
        from startDate: Date, to endDate: Date, in context: NSManagedObjectContext
    ) throws -> [StoredPortfolioValue] {
        let request = NSFetchRequest<NSDictionary>(entityName: "PortfolioSnapshotEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["timestamp", "totalValue", "currency"]
        request.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@",
                                        startDate as NSDate,
                                        endDate as NSDate)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        // The same defaults as toHistoricalPortfolioSnapshot().
        return try context.fetch(request).map { row in
            StoredPortfolioValue(
                date: row["timestamp"] as? Date ?? Date(),
                totalValue: row["totalValue"] as? Double ?? 0,
                currency: row["currency"] as? String ?? "USD"
            )
        }
    }

    /// Reads the matching snapshots oldest first, a batch at a time, and lets
    /// go of each batch's managed objects before reading the next. The context
    /// must have no unsaved changes: it is reset after every batch.
    static func portfolioSnapshots(
        matching predicate: NSPredicate?, batchSize: Int, in context: NSManagedObjectContext
    ) throws -> [HistoricalPortfolioSnapshot] {
        let idRequest = NSFetchRequest<NSManagedObjectID>(entityName: "PortfolioSnapshotEntity")
        idRequest.resultType = .managedObjectIDResultType
        idRequest.predicate = predicate
        idRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        let ids = try context.fetch(idRequest)

        var snapshots: [HistoricalPortfolioSnapshot] = []
        snapshots.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids[start..<min(start + batchSize, ids.count)])
            // The pool matters as much as the reset: converting a snapshot
            // leaves bridged strings, dates and sets behind until it drains.
            try autoreleasepool {
                let request: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
                request.predicate = NSPredicate(format: "self IN %@", batch)
                // Without this every snapshot's positions are a separate query.
                request.relationshipKeyPathsForPrefetching = ["positionSnapshots"]
                request.returnsObjectsAsFaults = false
                let entities = Dictionary(
                    try context.fetch(request).map { ($0.objectID, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                // The store returns a batch in no particular order.
                snapshots.append(contentsOf: batch.compactMap { entities[$0]?.toHistoricalPortfolioSnapshot() })
                context.reset()
            }
        }
        return snapshots
    }
    
    func getPortfolioSnapshotCount() async throws -> Int {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            return try context.count(for: fetchRequest)
        }
    }

    func getTotalPriceSnapshotCount() async throws -> Int {
        try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            return try context.count(for: fetchRequest)
        }
    }
    
    // MARK: - Data Management
    
}
