import Foundation
import CoreData // Ensure CoreData is imported

class DataMigrationService {
    static let shared = DataMigrationService()
    
    private let coreDataService: HistoricalDataServiceProtocol
    private let tradeDataMigrationService = TradeDataMigrationService()
    private let userDefaults = UserDefaults.standard
    private let coreDataStack = CoreDataStack.shared // Added for direct context access
    
    private init(coreDataService: HistoricalDataServiceProtocol = CoreDataHistoricalDataService()) {
        self.coreDataService = coreDataService
    }
    
    // MARK: - Migration Status
    
    private enum MigrationKeys {
        static let priceSnapshotsMigrated = "priceSnapshotsMigratedToCoreData"
        static let portfolioSnapshotsMigrated = "portfolioSnapshotsMigratedToCoreData" // This flag might need re-evaluation
        static let tradesMigrated = "tradesMigratedToCoreData"
        static let tradingInfoMigrated = "tradingInfoMigratedToCoreData"
        static let migrationVersion = "coreDataMigrationVersion"
        static let needsRetroactiveCalculationAfterMigration = "needsRetroactiveCalculationAfterMigration" // New flag
    }
    
    // Increment this version due to PortfolioSnapshotEntity schema change
    private let currentMigrationVersion = 3 // Assuming previous was 2
    
    var isPriceSnapshotsMigrated: Bool {
        // If overall migration version is up-to-date, individual flags are less critical
        // but can be kept for very granular checks or older migration paths.
        return userDefaults.bool(forKey: MigrationKeys.priceSnapshotsMigrated) || migrationVersionStored >= currentMigrationVersion
    }
    
    var isPortfolioSnapshotsMigrated: Bool {
        // This specific flag might become misleading due to schema change.
        // Rely more on the overall migrationVersion.
        return userDefaults.bool(forKey: MigrationKeys.portfolioSnapshotsMigrated) || migrationVersionStored >= currentMigrationVersion
    }
    
    var isTradesMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.tradesMigrated) || migrationVersionStored >= currentMigrationVersion
    }
    
    var isTradingInfoMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.tradingInfoMigrated) || migrationVersionStored >= currentMigrationVersion
    }
    
    var migrationVersionStored: Int {
        return userDefaults.integer(forKey: MigrationKeys.migrationVersion)
    }

    var needsRetroactiveCalculation: Bool {
        get { userDefaults.bool(forKey: MigrationKeys.needsRetroactiveCalculationAfterMigration) }
        set { userDefaults.set(newValue, forKey: MigrationKeys.needsRetroactiveCalculationAfterMigration) }
    }
    
    // MARK: - Full Migration
    
    func performFullMigration() async throws {
        Task { await Logger.shared.info("DataMigrationService: Starting full migration check. Stored version: \(migrationVersionStored), Current app version: \(currentMigrationVersion)") }
        
        // Check if we have UserDefaults data that needs migration regardless of version
        let userTradesData = userDefaults.data(forKey: "usertrades")
        let tradingInfoDataContent = userDefaults.data(forKey: "tradingInfoData")
        let hasUserTrades = userTradesData != nil
        let hasTradingInfo = tradingInfoDataContent != nil
        let needsDataMigration = hasUserTrades || hasTradingInfo
        
        Task { await Logger.shared.info("DataMigrationService: UserDefaults data check - usertrades: \(hasUserTrades) (size: \(userTradesData?.count ?? 0)), tradingInfoData: \(hasTradingInfo) (size: \(tradingInfoDataContent?.count ?? 0)), needsDataMigration: \(needsDataMigration)") }
        
        // Debug: List all UserDefaults keys to see what's available
        let allKeys = userDefaults.dictionaryRepresentation().keys.sorted()
        let tradeKeys = allKeys.filter { $0.contains("trade") || $0.contains("info") }
        Task { await Logger.shared.info("DataMigrationService: Available UserDefaults keys: \(tradeKeys)") }
        
        if migrationVersionStored >= currentMigrationVersion && !needsDataMigration {
            Task { await Logger.shared.info("DataMigrationService: Migration already up-to-date (version \(currentMigrationVersion)) and no UserDefaults data found. No full migration needed.") }
            // Check if a pending retroactive calculation is needed from a previous partial migration
            if needsRetroactiveCalculation {
                Task { await Logger.shared.info("DataMigrationService: Pending retroactive calculation flag is set.") }
                // Consider how to trigger this or notify HistoricalDataManager
            }
            return
        }
        
        Task { await Logger.shared.info("DataMigrationService: Migration required from version \(migrationVersionStored) to \(currentMigrationVersion).") }

        do {
            // Handle PortfolioSnapshotEntity schema change (if migrating from version < 3)
            if migrationVersionStored < 3 {
                Task { await Logger.shared.info("DataMigrationService: Migrating schema aspects related to pre-version 3 for PortfolioSnapshotEntity. Stored version: \(migrationVersionStored).") }

                // Delete old entities regardless, as the schema might be incompatible even if empty.
                // This is harmless on a fresh install (migrationVersionStored == 0) as it will delete nothing.
                try await deleteOldPortfolioSnapshotEntities()
                Task { await Logger.shared.info("DataMigrationService: Attempted deletion of old PortfolioSnapshotEntity instances (if any existed).") }

                // Only set the retroactive calculation flag if we are upgrading from an actual previous version (1 or 2)
                // that would have had data in the old format.
                if migrationVersionStored > 0 {
                    needsRetroactiveCalculation = true
                    Task { await Logger.shared.info("DataMigrationService: Marked that retroactive portfolio calculation is needed post-migration from version \(migrationVersionStored).") }
                } else {
                    Task { await Logger.shared.info("DataMigrationService: Fresh install (version 0). Schema is current. No v3-specific retroactive calculation trigger needed from this step.") }
                }
            }

            // Migrate price snapshots from UserDefaults (if not done and older version)
            if !userDefaults.bool(forKey: MigrationKeys.priceSnapshotsMigrated) && migrationVersionStored < currentMigrationVersion {
                try await migratePriceSnapshots()
                userDefaults.set(true, forKey: MigrationKeys.priceSnapshotsMigrated)
            }
            
            // Portfolio snapshots from UserDefaults (if not done and older version)
            // This migration might also need adjustment if the target Core Data structure changed.
            // However, the deleteOldPortfolioSnapshotEntities might make this redundant if it clears all.
            // For safety, ensure this runs before the delete if it's intended to migrate UserDefaults to the *new* structure.
            // Given the strategy is delete & recalc for PortfolioSnapshots, this specific migration might be less relevant
            // unless it's about getting *other* portfolio-related data from UserDefaults.
            // The current migratePortfolioSnapshots loads from UD and saves to CD. If old CD entities are deleted,
            // this will effectively populate with UD data, which will then be stored with the new (correct) structure.
            if !userDefaults.bool(forKey: MigrationKeys.portfolioSnapshotsMigrated) && migrationVersionStored < currentMigrationVersion {
                try await migratePortfolioSnapshots() // This will now use the corrected CoreDataExtensions
                userDefaults.set(true, forKey: MigrationKeys.portfolioSnapshotsMigrated)
            }
            
            // Migrate trades from UserDefaults
            let hasUserTrades = userDefaults.data(forKey: "usertrades") != nil
            if !userDefaults.bool(forKey: MigrationKeys.tradesMigrated) && (migrationVersionStored < currentMigrationVersion || hasUserTrades) {
                try await migrateTrades()
                userDefaults.set(true, forKey: MigrationKeys.tradesMigrated)
            }
            
            // Migrate trading info from UserDefaults
            let hasTradingInfo = userDefaults.data(forKey: "tradingInfoData") != nil
            if !userDefaults.bool(forKey: MigrationKeys.tradingInfoMigrated) && (migrationVersionStored < currentMigrationVersion || hasTradingInfo) {
                try await migrateTradingInfo()
                userDefaults.set(true, forKey: MigrationKeys.tradingInfoMigrated)
            }
            
            // Update migration version
            userDefaults.set(currentMigrationVersion, forKey: MigrationKeys.migrationVersion)
            Task { await Logger.shared.info("DataMigrationService: Migration to version \(currentMigrationVersion) completed successfully.") }
            
        } catch {
            Task { await Logger.shared.error("DataMigrationService: Migration failed: \(error)") }
            throw error
        }
    }

    private func deleteOldPortfolioSnapshotEntities() async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PortfolioSnapshotEntity.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            deleteRequest.resultType = .resultTypeCount // Get count of deleted items

            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0
                try context.save()
                Task { await Logger.shared.info("DataMigrationService: Deleted \(deletedCount) old PortfolioSnapshotEntity instances for schema migration.") }
            } catch {
                Task { await Logger.shared.error("DataMigrationService: Failed to delete old PortfolioSnapshotEntity instances: \(error)") }
                throw error // Re-throw to be caught by performFullMigration
            }
        }
    }
    
    // MARK: - Price Snapshots Migration
    
    private func migratePriceSnapshots() async throws {
        Task { await Logger.shared.info("Migrating price snapshots from UserDefaults to Core Data...") }
        
        // Load existing price snapshots from UserDefaults
        let existingSnapshots = loadPriceSnapshotsFromUserDefaults()
        
        if existingSnapshots.isEmpty {
            Task { await Logger.shared.info("No price snapshots found in UserDefaults") }
            return
        }
        
        Task { await Logger.shared.info("Found \(existingSnapshots.count) price snapshots to migrate") }
        
        // Save to Core Data in batches to avoid memory issues
        let batchSize = 100
        let batches = existingSnapshots.chunked(into: batchSize)
        
        for (index, batch) in batches.enumerated() {
            try await coreDataService.savePriceSnapshots(batch)
            Task { await Logger.shared.debug("Migrated batch \(index + 1)/\(batches.count) (\(batch.count) items)") }
        }
        
        Task { await Logger.shared.info("Successfully migrated \(existingSnapshots.count) price snapshots") }
    }
    
    private func loadPriceSnapshotsFromUserDefaults() -> [PriceSnapshot] {
        var allSnapshots: [PriceSnapshot] = []
        
        // Check if we have the tiered cache system data
        if let cacheData = userDefaults.data(forKey: "tieredCacheData") {
            do {
                let tieredCache = try JSONDecoder().decode([String: [PriceSnapshot]].self, from: cacheData)
                for (_, snapshots) in tieredCache {
                    allSnapshots.append(contentsOf: snapshots)
                }
                Task { await Logger.shared.info("Loaded \(allSnapshots.count) snapshots from tiered cache") }
            } catch {
                Task { await Logger.shared.error("Failed to decode tiered cache data: \(error)") }
            }
        }
        
        // Also check for legacy priceSnapshots key
        if let legacyData = userDefaults.data(forKey: "priceSnapshots") {
            do {
                let legacySnapshots = try JSONDecoder().decode([String: [PriceSnapshot]].self, from: legacyData)
                for (_, snapshots) in legacySnapshots {
                    allSnapshots.append(contentsOf: snapshots)
                }
                Task { await Logger.shared.info("Loaded additional \(legacySnapshots.values.flatMap { $0 }.count) snapshots from legacy storage") }
            } catch {
                Task { await Logger.shared.error("Failed to decode legacy price snapshots: \(error)") }
            }
        }
        
        // Remove duplicates based on symbol and timestamp
        let uniqueSnapshots = Array(Set(allSnapshots.map { "\($0.symbol)_\($0.timestamp.timeIntervalSince1970)" }))
            .compactMap { key in
                allSnapshots.first { "\($0.symbol)_\($0.timestamp.timeIntervalSince1970)" == key }
            }
        
        return uniqueSnapshots
    }
    
    // MARK: - Portfolio Snapshots Migration
    
    private func migratePortfolioSnapshots() async throws {
        Task { await Logger.shared.info("Migrating portfolio snapshots from UserDefaults to Core Data...") }
        
        // Load existing portfolio snapshots from UserDefaults
        let existingSnapshots = loadPortfolioSnapshotsFromUserDefaults()
        
        if existingSnapshots.isEmpty {
            Task { await Logger.shared.info("No portfolio snapshots found in UserDefaults") }
            return
        }
        
        Task { await Logger.shared.info("Found \(existingSnapshots.count) portfolio snapshots to migrate") }
        
        // Save to Core Data
        for snapshot in existingSnapshots {
            try await coreDataService.savePortfolioSnapshot(snapshot)
        }
        
        Task { await Logger.shared.info("Successfully migrated \(existingSnapshots.count) portfolio snapshots") }
    }
    
    // MARK: - Trade Data Migration
    
    private func migrateTrades() async throws {
        Task { await Logger.shared.info("Migrating trades from UserDefaults to Core Data...") }
        try await tradeDataMigrationService.migrateAllData()
    }
    
    private func migrateTradingInfo() async throws {
        Task { await Logger.shared.info("Migrating trading info from UserDefaults to Core Data...") }
        // Trading info is handled within the migrateAllTradeData method
        // This method is kept separate for granular migration control
    }
    
    private func loadPortfolioSnapshotsFromUserDefaults() -> [HistoricalPortfolioSnapshot] {
        var allSnapshots: [HistoricalPortfolioSnapshot] = []
        
        // Check for enhanced portfolio snapshots
        if let data = userDefaults.data(forKey: "historicalPortfolioSnapshots") {
            do {
                let snapshots = try JSONDecoder().decode([HistoricalPortfolioSnapshot].self, from: data)
                allSnapshots.append(contentsOf: snapshots)
                Task { await Logger.shared.info("Loaded \(snapshots.count) enhanced portfolio snapshots") }
            } catch {
                Task { await Logger.shared.error("Failed to decode enhanced portfolio snapshots: \(error)") }
            }
        }
        
        // Check for legacy portfolio snapshots and convert them
        if let legacyData = userDefaults.data(forKey: "portfolioSnapshots") {
            do {
                let legacySnapshots = try JSONDecoder().decode([PortfolioSnapshot].self, from: legacyData)
                let convertedSnapshots = legacySnapshots.map { convertLegacyPortfolioSnapshot($0) }
                allSnapshots.append(contentsOf: convertedSnapshots)
                Task { await Logger.shared.info("Loaded and converted \(legacySnapshots.count) legacy portfolio snapshots") }
            } catch {
                Task { await Logger.shared.error("Failed to decode legacy portfolio snapshots: \(error)") }
            }
        }
        
        return allSnapshots
    }
    
    private func convertLegacyPortfolioSnapshot(_ legacy: PortfolioSnapshot) -> HistoricalPortfolioSnapshot {
        let portfolioComposition = Dictionary(uniqueKeysWithValues: 
            legacy.priceSnapshots.map { snapshot in
                let positionSnapshot = PositionSnapshot(
                    symbol: snapshot.symbol,
                    units: 1.0, // Default units since legacy doesn't have this
                    priceAtDate: snapshot.price,
                    valueAtDate: snapshot.price,
                    currency: "USD" // Default currency
                )
                return (snapshot.symbol, positionSnapshot)
            }
        )
        
        return HistoricalPortfolioSnapshot(
            date: legacy.timestamp,
            totalValue: legacy.totalValue,
            totalGains: legacy.totalGains,
            totalCost: legacy.totalValue - legacy.totalGains,
            currency: legacy.currency,
            portfolioComposition: portfolioComposition
        )
    }
    
    // MARK: - Cleanup
    
    func cleanupLegacyData() {
        Task { await Logger.shared.info("Cleaning up legacy UserDefaults data...") }
        
        let keysToRemove = [
            "priceSnapshots",
            "portfolioSnapshots",
            "historicalPortfolioSnapshots",
            "tieredCacheData"
            // Note: We're keeping "usertrades" and "tradingInfoData" as backup for now
            // These can be removed in a future version after validation
        ]
        
        for key in keysToRemove {
            userDefaults.removeObject(forKey: key)
        }
        
        Task { await Logger.shared.info("Legacy data cleanup completed") }
    }
    
    // MARK: - Verification
    
    func verifyMigration() async throws -> Bool {
        Task { await Logger.shared.info("Verifying migration...") }
        
        // Check that data exists in Core Data
        let portfolioCount = try await coreDataService.getPortfolioSnapshotCount()
        
        // Get count of price snapshots for all symbols
        var totalPriceSnapshots = 0
        // This is a simplified check - in a real implementation you'd want to check specific symbols
        
        // Check trade data migration
        let tradesValid = (try? await tradeDataMigrationService.validateMigration()) ?? false
        
        Task { await Logger.shared.info("Verification: \(portfolioCount) portfolio snapshots, \(totalPriceSnapshots) price snapshots, trades valid: \(tradesValid)") }
        
        return (portfolioCount > 0 || totalPriceSnapshots > 0) && tradesValid
    }
}

// MARK: - Array Extension for Chunking

// Array extension moved to HistoricalDataManager.swift to avoid duplicates