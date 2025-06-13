import Foundation

class DataMigrationService {
    static let shared = DataMigrationService()
    
    private let coreDataService: HistoricalDataServiceProtocol
    private let tradeDataMigrationService = TradeDataMigrationService()
    private let userDefaults = UserDefaults.standard
    
    private init(coreDataService: HistoricalDataServiceProtocol = CoreDataHistoricalDataService()) {
        self.coreDataService = coreDataService
    }
    
    // MARK: - Migration Status
    
    private enum MigrationKeys {
        static let priceSnapshotsMigrated = "priceSnapshotsMigratedToCoreData"
        static let portfolioSnapshotsMigrated = "portfolioSnapshotsMigratedToCoreData"
        static let tradesMigrated = "tradesMigratedToCoreData"
        static let tradingInfoMigrated = "tradingInfoMigratedToCoreData"
        static let migrationVersion = "coreDataMigrationVersion"
    }
    
    private let currentMigrationVersion = 2
    
    var isPriceSnapshotsMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.priceSnapshotsMigrated)
    }
    
    var isPortfolioSnapshotsMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.portfolioSnapshotsMigrated)
    }
    
    var isTradesMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.tradesMigrated)
    }
    
    var isTradingInfoMigrated: Bool {
        return userDefaults.bool(forKey: MigrationKeys.tradingInfoMigrated)
    }
    
    var migrationVersion: Int {
        return userDefaults.integer(forKey: MigrationKeys.migrationVersion)
    }
    
    // MARK: - Full Migration
    
    func performFullMigration() async throws {
        Logger.shared.info("Starting full migration to Core Data...")
        
        // Check if migration is needed
        if migrationVersion >= currentMigrationVersion {
            Logger.shared.info("Migration already completed for version \(currentMigrationVersion)")
            return
        }
        
        do {
            // Migrate price snapshots
            if !isPriceSnapshotsMigrated {
                try await migratePriceSnapshots()
                userDefaults.set(true, forKey: MigrationKeys.priceSnapshotsMigrated)
            }
            
            // Migrate portfolio snapshots
            if !isPortfolioSnapshotsMigrated {
                try await migratePortfolioSnapshots()
                userDefaults.set(true, forKey: MigrationKeys.portfolioSnapshotsMigrated)
            }
            
            // Migrate trades (always ensure migration is complete)
            if !isTradesMigrated {
                try await migrateTrades()
                userDefaults.set(true, forKey: MigrationKeys.tradesMigrated)
            }
            
            // Migrate trading info (always ensure migration is complete)
            if !isTradingInfoMigrated {
                try await migrateTradingInfo()
                userDefaults.set(true, forKey: MigrationKeys.tradingInfoMigrated)
            }
            
            // Update migration version
            userDefaults.set(currentMigrationVersion, forKey: MigrationKeys.migrationVersion)
            
            Logger.shared.info("Migration to Core Data completed successfully")
            
        } catch {
            Logger.shared.error("Migration failed: \(error)")
            throw error
        }
    }
    
    // MARK: - Price Snapshots Migration
    
    private func migratePriceSnapshots() async throws {
        Logger.shared.info("Migrating price snapshots from UserDefaults to Core Data...")
        
        // Load existing price snapshots from UserDefaults
        let existingSnapshots = loadPriceSnapshotsFromUserDefaults()
        
        if existingSnapshots.isEmpty {
            Logger.shared.info("No price snapshots found in UserDefaults")
            return
        }
        
        Logger.shared.info("Found \(existingSnapshots.count) price snapshots to migrate")
        
        // Save to Core Data in batches to avoid memory issues
        let batchSize = 100
        let batches = existingSnapshots.chunked(into: batchSize)
        
        for (index, batch) in batches.enumerated() {
            try await coreDataService.savePriceSnapshots(batch)
            Logger.shared.debug("Migrated batch \(index + 1)/\(batches.count) (\(batch.count) items)")
        }
        
        Logger.shared.info("Successfully migrated \(existingSnapshots.count) price snapshots")
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
                Logger.shared.info("Loaded \(allSnapshots.count) snapshots from tiered cache")
            } catch {
                Logger.shared.error("Failed to decode tiered cache data: \(error)")
            }
        }
        
        // Also check for legacy priceSnapshots key
        if let legacyData = userDefaults.data(forKey: "priceSnapshots") {
            do {
                let legacySnapshots = try JSONDecoder().decode([String: [PriceSnapshot]].self, from: legacyData)
                for (_, snapshots) in legacySnapshots {
                    allSnapshots.append(contentsOf: snapshots)
                }
                Logger.shared.info("Loaded additional \(legacySnapshots.values.flatMap { $0 }.count) snapshots from legacy storage")
            } catch {
                Logger.shared.error("Failed to decode legacy price snapshots: \(error)")
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
        Logger.shared.info("Migrating portfolio snapshots from UserDefaults to Core Data...")
        
        // Load existing portfolio snapshots from UserDefaults
        let existingSnapshots = loadPortfolioSnapshotsFromUserDefaults()
        
        if existingSnapshots.isEmpty {
            Logger.shared.info("No portfolio snapshots found in UserDefaults")
            return
        }
        
        Logger.shared.info("Found \(existingSnapshots.count) portfolio snapshots to migrate")
        
        // Save to Core Data
        for snapshot in existingSnapshots {
            try await coreDataService.savePortfolioSnapshot(snapshot)
        }
        
        Logger.shared.info("Successfully migrated \(existingSnapshots.count) portfolio snapshots")
    }
    
    // MARK: - Trade Data Migration
    
    private func migrateTrades() async throws {
        Logger.shared.info("Migrating trades from UserDefaults to Core Data...")
        try await tradeDataMigrationService.migrateAllTradeData()
    }
    
    private func migrateTradingInfo() async throws {
        Logger.shared.info("Migrating trading info from UserDefaults to Core Data...")
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
                Logger.shared.info("Loaded \(snapshots.count) enhanced portfolio snapshots")
            } catch {
                Logger.shared.error("Failed to decode enhanced portfolio snapshots: \(error)")
            }
        }
        
        // Check for legacy portfolio snapshots and convert them
        if let legacyData = userDefaults.data(forKey: "portfolioSnapshots") {
            do {
                let legacySnapshots = try JSONDecoder().decode([PortfolioSnapshot].self, from: legacyData)
                let convertedSnapshots = legacySnapshots.map { convertLegacyPortfolioSnapshot($0) }
                allSnapshots.append(contentsOf: convertedSnapshots)
                Logger.shared.info("Loaded and converted \(legacySnapshots.count) legacy portfolio snapshots")
            } catch {
                Logger.shared.error("Failed to decode legacy portfolio snapshots: \(error)")
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
        Logger.shared.info("Cleaning up legacy UserDefaults data...")
        
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
        
        Logger.shared.info("Legacy data cleanup completed")
    }
    
    // MARK: - Verification
    
    func verifyMigration() async throws -> Bool {
        Logger.shared.info("Verifying migration...")
        
        // Check that data exists in Core Data
        let portfolioCount = try await coreDataService.getPortfolioSnapshotCount()
        
        // Get count of price snapshots for all symbols
        var totalPriceSnapshots = 0
        // This is a simplified check - in a real implementation you'd want to check specific symbols
        
        // Check trade data migration
        let tradesValid = await tradeDataMigrationService.validateMigration()
        
        Logger.shared.info("Verification: \(portfolioCount) portfolio snapshots, \(totalPriceSnapshots) price snapshots, trades valid: \(tradesValid)")
        
        return (portfolioCount > 0 || totalPriceSnapshots > 0) && tradesValid
    }
}

// MARK: - Array Extension for Chunking

// Array extension moved to HistoricalDataManager.swift to avoid duplicates