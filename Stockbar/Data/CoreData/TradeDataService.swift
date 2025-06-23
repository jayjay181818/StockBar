import Foundation
import CoreData

/// Service for managing trade data persistence in Core Data
class TradeDataService {
    
    // MARK: - Core Data Stack Access
    
    private var persistentContainer: NSPersistentContainer {
        return CoreDataStack.shared.persistentContainer
    }
    
    // MARK: - Trade Management
    
    /// Saves all current trades to Core Data, replacing existing trades
    func saveAllTrades(_ trades: [Trade]) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            // Delete existing trades more efficiently with a batch delete request
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = TradeEntity.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try context.execute(deleteRequest)
            
            // Create new trade entities
            for trade in trades {
                _ = TradeEntity.fromTrade(trade, in: context)
            }
        }
    }
    
    /// Loads all trades from Core Data
    func loadAllTrades() async throws -> [Trade] {
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TradeEntity.name, ascending: true)]
            
            let tradeEntities = try context.fetch(fetchRequest)
            return tradeEntities.map { $0.toTrade() }
        }
    }
    
    /// Saves a single trade
    func saveTrade(_ trade: Trade) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            // Check if trade already exists
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "name == %@", trade.name)
            
            let existingTrades = try context.fetch(fetchRequest)
            
            if let existingTrade = existingTrades.first {
                // Update existing trade
                existingTrade.updateFromTrade(trade)
            } else {
                // Create new trade
                _ = TradeEntity.fromTrade(trade, in: context)
            }
        }
    }
    
    /// Deletes a trade by symbol name
    func deleteTrade(withName name: String) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "name == %@", name)
            
            let trades = try context.fetch(fetchRequest)
            for trade in trades {
                context.delete(trade)
            }
        }
    }
    
    // MARK: - Trading Info Management
    
    /// Saves trading info for a symbol
    func saveTradingInfo(_ tradingInfo: TradingInfo, forSymbol symbol: String) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            
            let existingInfos = try context.fetch(fetchRequest)
            
            if let existingInfo = existingInfos.first {
                // Update existing trading info
                existingInfo.updateFromTradingInfo(tradingInfo)
            } else {
                // Create new trading info
                _ = TradingInfoEntity.fromTradingInfo(tradingInfo, symbol: symbol, in: context)
            }
        }
    }
    
    /// Loads trading info for a symbol
    func loadTradingInfo(forSymbol symbol: String) async throws -> TradingInfo? {
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            
            let tradingInfos = try context.fetch(fetchRequest)
            return tradingInfos.first?.toTradingInfo()
        }
    }
    
    /// Loads all trading info as a dictionary
    func loadAllTradingInfo() async throws -> [String: TradingInfo] {
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            let tradingInfoEntities = try context.fetch(fetchRequest)
            
            var tradingInfoDict: [String: TradingInfo] = [:]
            for entity in tradingInfoEntities {
                if let symbol = entity.symbol {
                    tradingInfoDict[symbol] = entity.toTradingInfo()
                }
            }
            return tradingInfoDict
        }
    }
    
    /// Saves all trading info
    func saveAllTradingInfo(_ tradingInfoDict: [String: TradingInfo]) async throws {
        try await CoreDataStack.shared.performBackgroundTask { context in
            // Delete existing trading info efficiently
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = TradingInfoEntity.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try context.execute(deleteRequest)
            
            // Create new trading info entities
            for (symbol, tradingInfo) in tradingInfoDict {
                _ = TradingInfoEntity.fromTradingInfo(tradingInfo, symbol: symbol, in: context)
            }
        }
    }
    
    // MARK: - Migration Helpers
    
    /// Checks if trades have been migrated to Core Data
    func areTradesMigrated() async -> Bool {
        do {
            return try await CoreDataStack.shared.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
                fetchRequest.fetchLimit = 1
                let trades = try context.fetch(fetchRequest)
                return !trades.isEmpty
            }
        } catch {
            Task { await Logger.shared.error("Failed to check trade migration status: \(error)") }
            return false
        }
    }
    
    /// Checks if trading info has been migrated to Core Data
    func isTradingInfoMigrated() async -> Bool {
        do {
            return try await CoreDataStack.shared.performBackgroundTask { context in
                let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
                fetchRequest.fetchLimit = 1
                let infos = try context.fetch(fetchRequest)
                return !infos.isEmpty
            }
        } catch {
            Task { await Logger.shared.error("Failed to check trading info migration status: \(error)") }
            return false
        }
    }
}