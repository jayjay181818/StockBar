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
    func getDataCount(for symbol: String) async throws -> Int
    func getTotalPriceSnapshotCount() async throws -> Int
    func getPortfolioSnapshotCount() async throws -> Int
}

final class CoreDataHistoricalDataService: HistoricalDataServiceProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    
    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
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
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "timestamp >= %@ AND timestamp <= %@",
                                               startDate as NSDate,
                                               endDate as NSDate)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            // Without this every snapshot's positions are a separate query.
            fetchRequest.relationshipKeyPathsForPrefetching = ["positionSnapshots"]
            fetchRequest.returnsObjectsAsFaults = false
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toHistoricalPortfolioSnapshot() }
        }
    }
    
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot] {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            // Without this every snapshot's positions are a separate query.
            fetchRequest.relationshipKeyPathsForPrefetching = ["positionSnapshots"]
            fetchRequest.returnsObjectsAsFaults = false
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toHistoricalPortfolioSnapshot() }
        }
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
