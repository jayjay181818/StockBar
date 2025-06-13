import Foundation
import CoreData

/// Service responsible for migrating trade data from UserDefaults to Core Data
class TradeDataMigrationService {
    
    private let tradeDataService = TradeDataService()
    private let decoder = JSONDecoder()
    private let logger = Logger.shared
    
    // MARK: - Migration Status
    
    /// Check if trades have been migrated from UserDefaults to Core Data
    func areTradesMigrated() async -> Bool {
        return await tradeDataService.areTradesMigrated()
    }
    
    /// Check if trading info has been migrated from UserDefaults to Core Data
    func isTradingInfoMigrated() async -> Bool {
        return await tradeDataService.isTradingInfoMigrated()
    }
    
    // MARK: - Migration Methods
    
    /// Migrate all trade data from UserDefaults to Core Data
    func migrateAllTradeData() async throws {
        logger.info("🔄 MIGRATION: Starting trade data migration from UserDefaults to Core Data")
        
        // Check if migration has already been completed
        let tradesAlreadyMigrated = await areTradesMigrated()
        let tradingInfoAlreadyMigrated = await isTradingInfoMigrated()
        
        if tradesAlreadyMigrated && tradingInfoAlreadyMigrated {
            logger.info("✅ MIGRATION: Trade data migration already completed")
            return
        }
        
        var migrationSuccess = true
        
        // Migrate trades if not already migrated
        if !tradesAlreadyMigrated {
            do {
                try await migrateTrades()
                logger.info("✅ MIGRATION: Successfully migrated trades to Core Data")
            } catch {
                logger.error("❌ MIGRATION: Failed to migrate trades: \(error)")
                migrationSuccess = false
            }
        } else {
            logger.info("⏭️ MIGRATION: Trades already migrated, skipping")
        }
        
        // Migrate trading info if not already migrated
        if !tradingInfoAlreadyMigrated {
            do {
                try await migrateTradingInfo()
                logger.info("✅ MIGRATION: Successfully migrated trading info to Core Data")
            } catch {
                logger.error("❌ MIGRATION: Failed to migrate trading info: \(error)")
                migrationSuccess = false
            }
        } else {
            logger.info("⏭️ MIGRATION: Trading info already migrated, skipping")
        }
        
        if migrationSuccess {
            logger.info("🎉 MIGRATION: Complete trade data migration successful")
        } else {
            throw TradeDataMigrationError.migrationFailed
        }
    }
    
    /// Migrate trades from UserDefaults to Core Data
    private func migrateTrades() async throws {
        logger.info("🔄 MIGRATION: Migrating trades from UserDefaults")
        
        // Load trades from UserDefaults
        guard let data = UserDefaults.standard.object(forKey: "usertrades") as? Data else {
            logger.info("ℹ️ MIGRATION: No trades found in UserDefaults, creating empty Core Data storage")
            return
        }
        
        let trades: [Trade]
        do {
            trades = try decoder.decode([Trade].self, from: data)
            logger.info("📊 MIGRATION: Found \(trades.count) trades in UserDefaults")
        } catch {
            logger.error("❌ MIGRATION: Failed to decode trades from UserDefaults: \(error)")
            throw TradeDataMigrationError.decodingFailed(error)
        }
        
        // Save trades to Core Data
        do {
            try await tradeDataService.saveAllTrades(trades)
            logger.info("💾 MIGRATION: Successfully saved \(trades.count) trades to Core Data")
            
            // Verify migration
            let migratedTrades = try await tradeDataService.loadAllTrades()
            logger.info("✅ MIGRATION: Verified \(migratedTrades.count) trades in Core Data")
            
        } catch {
            logger.error("❌ MIGRATION: Failed to save trades to Core Data: \(error)")
            throw TradeDataMigrationError.coreDataSaveFailed(error)
        }
    }
    
    /// Migrate trading info from UserDefaults to Core Data
    private func migrateTradingInfo() async throws {
        logger.info("🔄 MIGRATION: Migrating trading info from UserDefaults")
        
        // Load trading info from UserDefaults
        guard let data = UserDefaults.standard.object(forKey: "tradingInfoData") as? Data else {
            logger.info("ℹ️ MIGRATION: No trading info found in UserDefaults, creating empty Core Data storage")
            return
        }
        
        let tradingInfoDict: [String: TradingInfo]
        do {
            tradingInfoDict = try decoder.decode([String: TradingInfo].self, from: data)
            logger.info("📊 MIGRATION: Found trading info for \(tradingInfoDict.count) symbols in UserDefaults")
        } catch {
            logger.error("❌ MIGRATION: Failed to decode trading info from UserDefaults: \(error)")
            throw TradeDataMigrationError.decodingFailed(error)
        }
        
        // Save trading info to Core Data
        do {
            try await tradeDataService.saveAllTradingInfo(tradingInfoDict)
            logger.info("💾 MIGRATION: Successfully saved trading info for \(tradingInfoDict.count) symbols to Core Data")
            
            // Verify migration
            let migratedTradingInfo = try await tradeDataService.loadAllTradingInfo()
            logger.info("✅ MIGRATION: Verified trading info for \(migratedTradingInfo.count) symbols in Core Data")
            
        } catch {
            logger.error("❌ MIGRATION: Failed to save trading info to Core Data: \(error)")
            throw TradeDataMigrationError.coreDataSaveFailed(error)
        }
    }
    
    // MARK: - Backup and Recovery
    
    /// Create a backup of UserDefaults trade data before migration
    func backupUserDefaultsTradeData() throws {
        logger.info("💾 MIGRATION: Creating backup of UserDefaults trade data")
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let backupDate = ISO8601DateFormatter().string(from: Date())
        
        // Backup trades
        if let tradesData = UserDefaults.standard.object(forKey: "usertrades") as? Data {
            let tradesBackupURL = documentsPath.appendingPathComponent("trades_backup_\(backupDate).json")
            try tradesData.write(to: tradesBackupURL)
            logger.info("💾 MIGRATION: Trades backup saved to \(tradesBackupURL.path)")
        }
        
        // Backup trading info
        if let tradingInfoData = UserDefaults.standard.object(forKey: "tradingInfoData") as? Data {
            let tradingInfoBackupURL = documentsPath.appendingPathComponent("trading_info_backup_\(backupDate).json")
            try tradingInfoData.write(to: tradingInfoBackupURL)
            logger.info("💾 MIGRATION: Trading info backup saved to \(tradingInfoBackupURL.path)")
        }
        
        // Backup user data
        if let userData = UserDefaults.standard.object(forKey: "userData") as? Data {
            let userDataBackupURL = documentsPath.appendingPathComponent("user_data_backup_\(backupDate).json")
            try userData.write(to: userDataBackupURL)
            logger.info("💾 MIGRATION: User data backup saved to \(userDataBackupURL.path)")
        }
    }
    
    /// Clean up UserDefaults trade data after successful migration (optional)
    func cleanupUserDefaultsTradeData() {
        logger.warning("🗑️ MIGRATION: Cleaning up UserDefaults trade data (keeping as backup for now)")
        
        // For safety, we're not removing the UserDefaults data immediately
        // This can be done manually later or in a future version
        
        // UserDefaults.standard.removeObject(forKey: "usertrades")
        // UserDefaults.standard.removeObject(forKey: "tradingInfoData")
        // UserDefaults.standard.removeObject(forKey: "userData")
        
        logger.info("ℹ️ MIGRATION: UserDefaults cleanup skipped for safety - data remains as backup")
    }
    
    // MARK: - Migration Validation
    
    /// Validate that migrated data matches original UserDefaults data
    func validateMigration() async -> Bool {
        logger.info("🔍 MIGRATION: Validating migration integrity")
        
        var validationSuccess = true
        
        // Validate trades
        do {
            let userDefaultsTrades = loadTradesFromUserDefaults()
            let coreDataTrades = try await tradeDataService.loadAllTrades()
            
            if userDefaultsTrades.count != coreDataTrades.count {
                logger.error("❌ MIGRATION: Trade count mismatch - UserDefaults: \(userDefaultsTrades.count), Core Data: \(coreDataTrades.count)")
                validationSuccess = false
            } else {
                logger.info("✅ MIGRATION: Trade counts match (\(userDefaultsTrades.count))")
            }
            
            // Validate individual trades
            for userDefaultsTrade in userDefaultsTrades {
                if !coreDataTrades.contains(where: { $0.name == userDefaultsTrade.name }) {
                    logger.error("❌ MIGRATION: Trade \(userDefaultsTrade.name) missing from Core Data")
                    validationSuccess = false
                }
            }
            
        } catch {
            logger.error("❌ MIGRATION: Failed to validate trades: \(error)")
            validationSuccess = false
        }
        
        // Validate trading info
        do {
            let userDefaultsTradingInfo = loadTradingInfoFromUserDefaults()
            let coreDataTradingInfo = try await tradeDataService.loadAllTradingInfo()
            
            if userDefaultsTradingInfo.count != coreDataTradingInfo.count {
                logger.error("❌ MIGRATION: Trading info count mismatch - UserDefaults: \(userDefaultsTradingInfo.count), Core Data: \(coreDataTradingInfo.count)")
                validationSuccess = false
            } else {
                logger.info("✅ MIGRATION: Trading info counts match (\(userDefaultsTradingInfo.count))")
            }
            
        } catch {
            logger.error("❌ MIGRATION: Failed to validate trading info: \(error)")
            validationSuccess = false
        }
        
        if validationSuccess {
            logger.info("🎉 MIGRATION: Validation successful - all data migrated correctly")
        } else {
            logger.error("❌ MIGRATION: Validation failed - data integrity issues detected")
        }
        
        return validationSuccess
    }
    
    // MARK: - Helper Methods
    
    private func loadTradesFromUserDefaults() -> [Trade] {
        guard let data = UserDefaults.standard.object(forKey: "usertrades") as? Data else {
            return []
        }
        return (try? decoder.decode([Trade].self, from: data)) ?? []
    }
    
    private func loadTradingInfoFromUserDefaults() -> [String: TradingInfo] {
        guard let data = UserDefaults.standard.object(forKey: "tradingInfoData") as? Data else {
            return [:]
        }
        return (try? decoder.decode([String: TradingInfo].self, from: data)) ?? [:]
    }
}

// MARK: - Migration Errors

enum TradeDataMigrationError: Error, LocalizedError {
    case migrationFailed
    case decodingFailed(Error)
    case coreDataSaveFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .migrationFailed:
            return "Trade data migration failed"
        case .decodingFailed(let error):
            return "Failed to decode UserDefaults data: \(error.localizedDescription)"
        case .coreDataSaveFailed(let error):
            return "Failed to save to Core Data: \(error.localizedDescription)"
        }
    }
}