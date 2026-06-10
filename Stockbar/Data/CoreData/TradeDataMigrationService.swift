@preconcurrency import Foundation
@preconcurrency import CoreData

/// Errors that can occur during trade data migration
enum TradeDataMigrationError: Error {
    case decodingFailed(Error)
    case validationFailed
    case migrationIncomplete
    case coreDataError(Error)
}

/// Service responsible for migrating trade data from UserDefaults to Core Data
final class TradeDataMigrationService: @unchecked Sendable {
    
    private let tradeDataService = TradeDataService()
    private let decoder = JSONDecoder()
    private let logger = Logger.shared
    private let migrationKey = "TradeDataMigrationCompleted"
    
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
    func migrateAllData() async throws {
        Task { await logger.info("🔄 MIGRATION: Starting trade data migration from UserDefaults to Core Data") }
        
        // Check if migration has already been completed
        if UserDefaults.standard.bool(forKey: migrationKey) {
            let hasLegacyTrades = UserDefaults.standard.data(forKey: "usertrades") != nil
            let hasCoreDataTrades = await tradeDataService.areTradesMigrated()
            if !hasLegacyTrades || hasCoreDataTrades {
                Task { await logger.info("✅ MIGRATION: Trade data migration already completed") }
                return
            }

            Task { await logger.warning("⚠️ MIGRATION: Migration was marked complete but Core Data has no trades; rerunning from UserDefaults") }
        }
        
        do {
            // Migrate trades
            try await migrateTradesFromUserDefaults()
            
            try await migrateTradingInfoFromUserDefaults()
            
            if try await validateMigration() {
                Task { await logger.info("✅ MIGRATION: Successfully migrated trades to Core Data") }
            } else {
                Task { await logger.error("❌ MIGRATION: Failed to migrate trades") }
                throw TradeDataMigrationError.validationFailed
            }
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to migrate trades: \(error)") }
            throw error
        }
        
        if UserDefaults.standard.object(forKey: "usertrades") == nil && UserDefaults.standard.object(forKey: "tradingInfoData") == nil {
            Task { await logger.info("⏭️ MIGRATION: Trades already migrated, skipping") }
        }
        
        // Migrate trading info
        do {
            try await migrateTradingInfoFromUserDefaults()
            if try await validateMigration() {
                Task { await logger.info("✅ MIGRATION: Successfully migrated trading info to Core Data") }
            } else {
                Task { await logger.error("❌ MIGRATION: Failed to migrate trading info") }
                throw TradeDataMigrationError.validationFailed
            }
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to migrate trading info: \(error)") }
            throw error
        }
        
        if UserDefaults.standard.object(forKey: "tradingInfoData") == nil {
            Task { await logger.info("⏭️ MIGRATION: Trading info already migrated, skipping") }
        }
        
        // Mark migration as completed
        UserDefaults.standard.set(true, forKey: migrationKey)
        Task { await logger.info("🎉 MIGRATION: Complete trade data migration successful") }
    }
    
    private func migrateTradesFromUserDefaults() async throws {
        Task { await logger.info("🔄 MIGRATION: Migrating trades from UserDefaults") }
        
        // Check if UserDefaults has trade data (using correct key)
        guard let tradesData = UserDefaults.standard.data(forKey: "usertrades") else {
            Task { await logger.info("ℹ️ MIGRATION: No trades found in UserDefaults, creating empty Core Data storage") }
            try backupUserDefaultsData()
            return
        }
        
        // Decode trades from UserDefaults
        let trades: [Trade]
        do {
            trades = try JSONDecoder().decode([Trade].self, from: tradesData)
                .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }
            Task { await logger.info("📊 MIGRATION: Found \(trades.count) portfolio trades in UserDefaults") }
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to decode trades from UserDefaults: \(error)") }
            throw TradeDataMigrationError.decodingFailed(error)
        }
        
        // Save trades to Core Data
        do {
            try await tradeDataService.saveAllTrades(trades)
            Task { await logger.info("💾 MIGRATION: Successfully saved \(trades.count) trades to Core Data") }
            
            // Verify the migration
            let migratedTrades = try await tradeDataService.loadAllTrades()
            Task { await logger.info("✅ MIGRATION: Verified \(migratedTrades.count) trades in Core Data") }
            
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to save trades to Core Data: \(error)") }
            throw error
        }
    }
    
    private func migrateTradingInfoFromUserDefaults() async throws {
        Task { await logger.info("🔄 MIGRATION: Migrating trading info from UserDefaults") }
        
        // Check if UserDefaults has trading info data (using correct key)
        guard let tradingInfoData = UserDefaults.standard.data(forKey: "tradingInfoData") else {
            Task { await logger.info("ℹ️ MIGRATION: No trading info found in UserDefaults, creating empty Core Data storage") }
            try backupUserDefaultsData()
            return
        }
        
        // Decode trading info from UserDefaults
        let tradingInfoDict: [String: TradingInfo]
        do {
            tradingInfoDict = try JSONDecoder().decode([String: TradingInfo].self, from: tradingInfoData)
            Task { await logger.info("📊 MIGRATION: Found trading info for \(tradingInfoDict.count) symbols in UserDefaults") }
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to decode trading info from UserDefaults: \(error)") }
            throw TradeDataMigrationError.decodingFailed(error)
        }
        
        // Save trading info to Core Data
        do {
            try await tradeDataService.saveAllTradingInfo(tradingInfoDict)
            Task { await logger.info("💾 MIGRATION: Successfully saved trading info for \(tradingInfoDict.count) symbols to Core Data") }
            
            // Verify the migration
            let migratedTradingInfo = try await tradeDataService.loadAllTradingInfo()
            Task { await logger.info("✅ MIGRATION: Verified trading info for \(migratedTradingInfo.count) symbols in Core Data") }
            
        } catch {
            Task { await logger.error("❌ MIGRATION: Failed to save trading info to Core Data: \(error)") }
            throw error
        }
    }
    
    private func backupUserDefaultsData() throws {
        Task { await logger.info("💾 MIGRATION: Creating backup of UserDefaults trade data") }
        
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundlePathComponent = Bundle.main.bundleIdentifier?.isEmpty == false
            ? Bundle.main.bundleIdentifier!
            : "com.fhl43211.Stockbar"
        let backupDirectory = appSupport
            .appendingPathComponent(bundlePathComponent, isDirectory: true)
            .appendingPathComponent("Migration Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        
        // Backup trades
        if let tradesData = UserDefaults.standard.data(forKey: "usertrades") {
            let tradesBackupURL = backupDirectory.appendingPathComponent("trades_backup_\(Date().timeIntervalSince1970).json")
            try tradesData.write(to: tradesBackupURL)
            Task { await logger.info("💾 MIGRATION: Trades backup saved to \(tradesBackupURL.path)") }
        }
        
        // Backup trading info
        if let tradingInfoData = UserDefaults.standard.data(forKey: "tradingInfoData") {
            let tradingInfoBackupURL = backupDirectory.appendingPathComponent("tradingInfo_backup_\(Date().timeIntervalSince1970).json")
            try tradingInfoData.write(to: tradingInfoBackupURL)
            Task { await logger.info("💾 MIGRATION: Trading info backup saved to \(tradingInfoBackupURL.path)") }
        }
        
        // Backup other user data
        let userDataDict = UserDefaults.standard.dictionaryRepresentation()
        let userDataBackupURL = backupDirectory.appendingPathComponent("user_data_backup_\(Date().timeIntervalSince1970).plist")
        (userDataDict as NSDictionary).write(to: userDataBackupURL, atomically: true)
        Task { await logger.info("💾 MIGRATION: User data backup saved to \(userDataBackupURL.path)") }
    }
    
    private func cleanupUserDefaultsData() {
        Task { await logger.warning("🗑️ MIGRATION: Cleaning up UserDefaults trade data (keeping as backup for now)") }
        
        // For safety, we'll keep the UserDefaults data as backup
        // In a future version, we can add an option to clean it up
        // UserDefaults.standard.removeObject(forKey: "trades")
        // UserDefaults.standard.removeObject(forKey: "tradingInfo")
        
        Task { await logger.info("ℹ️ MIGRATION: UserDefaults cleanup skipped for safety - data remains as backup") }
    }
    
    func validateMigration() async throws -> Bool {
        Task { await logger.info("🔍 MIGRATION: Validating migration integrity") }
        
        // Compare UserDefaults trades with Core Data trades
        if let tradesData = UserDefaults.standard.data(forKey: "usertrades") {
            do {
                let userDefaultsTrades = try JSONDecoder().decode([Trade].self, from: tradesData)
                    .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }
                let coreDataTrades = try await tradeDataService.loadAllTrades()
                    .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }
                
                if userDefaultsTrades.count != coreDataTrades.count {
                    Task { await logger.error("❌ MIGRATION: Trade count mismatch - UserDefaults: \(userDefaultsTrades.count), Core Data: \(coreDataTrades.count)") }
                    return false
                } else {
                    Task { await logger.info("✅ MIGRATION: Trade counts match (\(userDefaultsTrades.count))") }
                }
                
                // Verify each trade exists in Core Data
                for userDefaultsTrade in userDefaultsTrades {
                    if !coreDataTrades.contains(where: { $0.name == userDefaultsTrade.name }) {
                        Task { await logger.error("❌ MIGRATION: Trade \(userDefaultsTrade.name) missing from Core Data") }
                        return false
                    }
                }
                
            } catch {
                Task { await logger.error("❌ MIGRATION: Failed to validate trades: \(error)") }
                return false
            }
        }
        
        // Compare UserDefaults trading info with Core Data trading info
        if let tradingInfoData = UserDefaults.standard.data(forKey: "tradingInfoData") {
            do {
                let userDefaultsTradingInfo = try JSONDecoder().decode([String: TradingInfo].self, from: tradingInfoData)
                let coreDataTradingInfo = try await tradeDataService.loadAllTradingInfo()
                
                if userDefaultsTradingInfo.count != coreDataTradingInfo.count {
                    Task { await logger.error("❌ MIGRATION: Trading info count mismatch - UserDefaults: \(userDefaultsTradingInfo.count), Core Data: \(coreDataTradingInfo.count)") }
                    return false
                } else {
                    Task { await logger.info("✅ MIGRATION: Trading info counts match (\(userDefaultsTradingInfo.count))") }
                }
                
            } catch {
                Task { await logger.error("❌ MIGRATION: Failed to validate trading info: \(error)") }
                return false
            }
        }
        
        let validationPassed = true // If we reach here, all validations passed
        if validationPassed {
            Task { await logger.info("🎉 MIGRATION: Validation successful - all data migrated correctly") }
        }
        
                return validationPassed
    }
}
