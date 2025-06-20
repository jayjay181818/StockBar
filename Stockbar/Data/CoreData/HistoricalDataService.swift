import Foundation
import CoreData

protocol HistoricalDataServiceProtocol {
    func savePriceSnapshots(_ snapshots: [PriceSnapshot]) async throws
    func fetchPriceSnapshots(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot]
    func fetchAllPriceSnapshots(for symbol: String) async throws -> [PriceSnapshot]
    func savePortfolioSnapshot(_ snapshot: HistoricalPortfolioSnapshot) async throws
    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async throws -> [HistoricalPortfolioSnapshot]
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot]
    func deletePriceSnapshots(for symbol: String, before date: Date) async throws
    func deletePortfolioSnapshots(before date: Date) async throws
    func getDataCount(for symbol: String) async throws -> Int
    func getPortfolioSnapshotCount() async throws -> Int
}

class CoreDataHistoricalDataService: HistoricalDataServiceProtocol {
    private let coreDataStack: CoreDataStack
    
    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }
    
    // MARK: - Price Snapshots
    
    func savePriceSnapshots(_ snapshots: [PriceSnapshot]) async throws {
        try await coreDataStack.performBackgroundTask { context in
            for snapshot in snapshots {
                // Check if snapshot already exists to avoid duplicates
                let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "symbol == %@ AND timestamp == %@", 
                                                   snapshot.symbol, 
                                                   snapshot.timestamp as NSDate)
                
                let existingSnapshots = try context.fetch(fetchRequest)
                
                if existingSnapshots.isEmpty {
                    _ = PriceSnapshotEntity.fromPriceSnapshot(snapshot, in: context)
                }
            }
            
            Logger.shared.debug("Saved \(snapshots.count) price snapshots to Core Data")
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
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toPriceSnapshot() }
        }
    }
    
    func fetchAllPriceSnapshots(for symbol: String) async throws -> [PriceSnapshot] {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toPriceSnapshot() }
        }
    }
    
    func deletePriceSnapshots(for symbol: String, before date: Date) async throws {
        try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "PriceSnapshotEntity")
            fetchRequest.predicate = NSPredicate(format: "symbol == %@ AND timestamp < %@",
                                               symbol,
                                               date as NSDate)
            
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try context.execute(deleteRequest)
            
            Logger.shared.debug("Deleted price snapshots for \(symbol) before \(date)")
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
                Logger.shared.debug("Saved portfolio snapshot to Core Data for \(snapshot.date)")
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
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toHistoricalPortfolioSnapshot() }
        }
    }
    
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot] {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let entities = try context.fetch(fetchRequest)
            return entities.map { $0.toHistoricalPortfolioSnapshot() }
        }
    }
    
    func deletePortfolioSnapshots(before date: Date) async throws {
        try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "PortfolioSnapshotEntity")
            fetchRequest.predicate = NSPredicate(format: "timestamp < %@", date as NSDate)
            
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try context.execute(deleteRequest)
            
            Logger.shared.debug("Deleted portfolio snapshots before \(date)")
        }
    }
    
    func getPortfolioSnapshotCount() async throws -> Int {
        return try await coreDataStack.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            return try context.count(for: fetchRequest)
        }
    }
    
    // MARK: - Data Management
    
    func optimizeData(maxPriceSnapshotsPerSymbol: Int = 2500, maxPortfolioSnapshots: Int = 2000) async throws {
        try await coreDataStack.performBackgroundTask { context in
            // Get all unique symbols
            let symbolFetchRequest: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "PriceSnapshotEntity")
            symbolFetchRequest.propertiesToFetch = ["symbol"]
            symbolFetchRequest.returnsDistinctResults = true
            symbolFetchRequest.resultType = .dictionaryResultType
            
            let symbolResults = try context.fetch(symbolFetchRequest) as! [[String: Any]]
            let symbols = symbolResults.compactMap { $0["symbol"] as? String }
            
            // Optimize price snapshots for each symbol
            for symbol in symbols {
                try self.optimizePriceSnapshots(for: symbol, maxCount: maxPriceSnapshotsPerSymbol, in: context)
            }
            
            // Optimize portfolio snapshots
            try self.optimizePortfolioSnapshots(maxCount: maxPortfolioSnapshots, in: context)
            
            Logger.shared.info("Optimized Core Data storage: max \(maxPriceSnapshotsPerSymbol) price snapshots per symbol, max \(maxPortfolioSnapshots) portfolio snapshots")
        }
    }
    
    private func optimizePriceSnapshots(for symbol: String, maxCount: Int, in context: NSManagedObjectContext) throws {
        let countRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
        countRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
        
        let count = try context.count(for: countRequest)
        
        if count > maxCount {
            let excessCount = count - maxCount
            
            let deleteRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            deleteRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            deleteRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            deleteRequest.fetchLimit = excessCount
            
            let entitiesToDelete = try context.fetch(deleteRequest)
            
            for entity in entitiesToDelete {
                context.delete(entity)
            }
            
            Logger.shared.debug("Deleted \(excessCount) old price snapshots for \(symbol)")
        }
    }
    
    private func optimizePortfolioSnapshots(maxCount: Int, in context: NSManagedObjectContext) throws {
        let countRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
        let count = try context.count(for: countRequest)
        
        if count > maxCount {
            let excessCount = count - maxCount
            
            let deleteRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            deleteRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            deleteRequest.fetchLimit = excessCount
            
            let entitiesToDelete = try context.fetch(deleteRequest)
            
            for entity in entitiesToDelete {
                context.delete(entity)
            }
            
            Logger.shared.debug("Deleted \(excessCount) old portfolio snapshots")
        }
    }
}