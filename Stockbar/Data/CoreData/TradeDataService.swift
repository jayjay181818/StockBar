import CoreData
import Foundation

private actor TradeDataWriteGate {
    static let shared = TradeDataWriteGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Service for managing trade data persistence in Core Data
final class TradeDataService: @unchecked Sendable {
    
    // MARK: - Core Data Stack Access
    
    private var persistentContainer: NSPersistentContainer {
        return CoreDataStack.shared.persistentContainer
    }
    
    // MARK: - Trade Management
    
    /// Saves all current trades to Core Data, replacing existing trades
    func saveAllTrades(_ trades: [Trade]) async throws {
        let uniqueTrades = Self.deduplicatedTrades(trades)

        await TradeDataWriteGate.shared.wait()
        do {
            try await CoreDataStack.shared.performBackgroundTask { context in
                // Update in place and leave unchanged rows alone. Deleting and
                // reinserting the table on every save rewrote every row hundreds of
                // times a day. All changes still land in one save, so a failure
                // keeps the old rows.
                var remaining = Dictionary(uniqueTrades.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                for existing in try context.fetch(TradeEntity.fetchRequest()) {
                    guard let name = existing.name, let trade = remaining.removeValue(forKey: name) else {
                        // No longer held, or a duplicate row for a name already handled.
                        context.delete(existing)
                        continue
                    }
                    if !existing.matches(trade) {
                        existing.updateFromTrade(trade)
                    }
                }
                for trade in uniqueTrades where remaining[trade.name] != nil {
                    _ = TradeEntity.fromTrade(trade, in: context)
                }
            }
            await TradeDataWriteGate.shared.signal()
        } catch {
            await TradeDataWriteGate.shared.signal()
            throw error
        }
    }
    
    /// Loads all trades from Core Data
    func loadAllTrades() async throws -> [Trade] {
        return try await CoreDataStack.shared.performBackgroundTask { context in
            let fetchRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TradeEntity.name, ascending: true)]
            
            let tradeEntities = try context.fetch(fetchRequest)
            return Self.deduplicatedTrades(tradeEntities.map { $0.toTrade() })
        }
    }

    private static func deduplicatedTrades(_ trades: [Trade]) -> [Trade] {
        var seenSymbols: Set<String> = []
        var uniqueTrades: [Trade] = []

        for trade in trades {
            let symbol = trade.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !symbol.isEmpty, !seenSymbols.contains(symbol) else { continue }

            seenSymbols.insert(symbol)
            uniqueTrades.append(trade)
        }

        return uniqueTrades
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
            // Updated in place in one save; unchanged rows are not rewritten.
            var remaining = tradingInfoDict
            for existing in try context.fetch(TradingInfoEntity.fetchRequest()) {
                guard let symbol = existing.symbol, let info = remaining.removeValue(forKey: symbol) else {
                    context.delete(existing)
                    continue
                }
                if !existing.matches(info) {
                    existing.updateFromTradingInfo(info)
                }
            }
            for (symbol, tradingInfo) in remaining {
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
