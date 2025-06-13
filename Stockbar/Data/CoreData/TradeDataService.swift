import Foundation
import CoreData

/// Service for managing trade data persistence in Core Data
class TradeDataService {
    
    // MARK: - Core Data Stack Access
    
    private var persistentContainer: NSPersistentContainer {
        return CoreDataStack.shared.persistentContainer
    }
    
    private var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    // MARK: - Trade Management
    
    /// Saves all current trades to Core Data, replacing existing trades
    func saveAllTrades(_ trades: [Trade]) async throws {
        try await context.perform {
            // Delete existing trades
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            let existingTrades = try self.context.fetch(fetchRequest)
            for trade in existingTrades {
                self.context.delete(trade)
            }
            
            // Create new trade entities
            for trade in trades {
                _ = TradeEntity.fromTrade(trade, in: self.context)
            }
            
            try self.context.save()
        }
    }
    
    /// Loads all trades from Core Data
    func loadAllTrades() async throws -> [Trade] {
        return try await context.perform {
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TradeEntity.name, ascending: true)]
            
            let tradeEntities = try self.context.fetch(fetchRequest)
            return tradeEntities.map { $0.toTrade() }
        }
    }
    
    /// Saves a single trade
    func saveTrade(_ trade: Trade) async throws {
        try await context.perform {
            // Check if trade already exists
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "name == %@", trade.name)
            
            let existingTrades = try self.context.fetch(fetchRequest)
            
            if let existingTrade = existingTrades.first {
                // Update existing trade
                existingTrade.updateFromTrade(trade)
            } else {
                // Create new trade
                _ = TradeEntity.fromTrade(trade, in: self.context)
            }
            
            try self.context.save()
        }
    }
    
    /// Deletes a trade by symbol name
    func deleteTrade(withName name: String) async throws {
        try await context.perform {
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "name == %@", name)
            
            let trades = try self.context.fetch(fetchRequest)
            for trade in trades {
                self.context.delete(trade)
            }
            
            try self.context.save()
        }
    }
    
    // MARK: - Trading Info Management
    
    /// Saves trading info for a symbol
    func saveTradingInfo(_ tradingInfo: TradingInfo, forSymbol symbol: String) async throws {
        try await context.perform {
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            
            let existingInfos = try self.context.fetch(fetchRequest)
            
            if let existingInfo = existingInfos.first {
                // Update existing trading info
                existingInfo.updateFromTradingInfo(tradingInfo)
            } else {
                // Create new trading info
                _ = TradingInfoEntity.fromTradingInfo(tradingInfo, symbol: symbol, in: self.context)
            }
            
            try self.context.save()
        }
    }
    
    /// Loads trading info for a symbol
    func loadTradingInfo(forSymbol symbol: String) async throws -> TradingInfo? {
        return try await context.perform {
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "symbol == %@", symbol)
            
            let tradingInfos = try self.context.fetch(fetchRequest)
            return tradingInfos.first?.toTradingInfo()
        }
    }
    
    /// Loads all trading info as a dictionary
    func loadAllTradingInfo() async throws -> [String: TradingInfo] {
        return try await context.perform {
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            let tradingInfoEntities = try self.context.fetch(fetchRequest)
            
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
        try await context.perform {
            // Delete existing trading info
            let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            let existingInfos = try self.context.fetch(fetchRequest)
            for info in existingInfos {
                self.context.delete(info)
            }
            
            // Create new trading info entities
            for (symbol, tradingInfo) in tradingInfoDict {
                _ = TradingInfoEntity.fromTradingInfo(tradingInfo, symbol: symbol, in: self.context)
            }
            
            try self.context.save()
        }
    }
    
    // MARK: - Migration Helpers
    
    /// Checks if trades have been migrated to Core Data
    func areTradesMigrated() async -> Bool {
        do {
            return try await context.perform {
                let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
                fetchRequest.fetchLimit = 1
                let trades = try self.context.fetch(fetchRequest)
                return !trades.isEmpty
            }
        } catch {
            Logger.shared.error("Failed to check trade migration status: \(error)")
            return false
        }
    }
    
    /// Checks if trading info has been migrated to Core Data
    func isTradingInfoMigrated() async -> Bool {
        do {
            return try await context.perform {
                let fetchRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
                fetchRequest.fetchLimit = 1
                let infos = try self.context.fetch(fetchRequest)
                return !infos.isEmpty
            }
        } catch {
            Logger.shared.error("Failed to check trading info migration status: \(error)")
            return false
        }
    }
}