@preconcurrency import CoreData // Ensure CoreData is imported
@preconcurrency import Foundation

struct MigrationVerificationReport: Equatable, Sendable {
    let sourcePriceSnapshots: Int
    let sourcePortfolioSnapshots: Int
    let sourceHadTrades: Bool
    let sourceHadTradingInfo: Bool
    let destinationPriceSnapshots: Int
    let destinationPortfolioSnapshots: Int
    let tradesValid: Bool

    var succeeded: Bool {
        destinationPriceSnapshots >= sourcePriceSnapshots
            && destinationPortfolioSnapshots >= sourcePortfolioSnapshots
            && (!sourceHadTrades || tradesValid)
    }
}

private actor MigrationExecutionGate {
    private var inFlight: Task<Void, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }
}

final class DataMigrationService: @unchecked Sendable {
    static let shared = DataMigrationService()
    
    private let coreDataService: HistoricalDataServiceProtocol
    private let tradeDataMigrationService = TradeDataMigrationService()
    private let userDefaults = StockbarRuntimeStorage.userDefaults
    private let coreDataStack = CoreDataStack.shared // Added for direct context access
    private let executionGate = MigrationExecutionGate()
    
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
        /// Set once the pre-v3 PortfolioSnapshotEntity rows are deleted, so a
        /// migration that fails later does not delete history again next launch.
        static let preV3PortfolioSnapshotsDeleted = "preV3PortfolioSnapshotsDeleted"
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
        try await executionGate.run { [self] in
            try await performFullMigrationUnlocked()
        }
    }

    private func performFullMigrationUnlocked() async throws {
        Task { await Logger.shared.info("DataMigrationService: Starting full migration check. Stored version: \(migrationVersionStored), Current app version: \(currentMigrationVersion)") }
        
        // Check if we have UserDefaults data that needs migration regardless of version
        let userTradesData = userDefaults.data(forKey: "usertrades")
        let tradingInfoDataContent = userDefaults.data(forKey: "tradingInfoData")
        let hasUserTrades = userTradesData != nil
        let hasTradingInfo = tradingInfoDataContent != nil
        let needsDataMigration =
            (hasUserTrades && !userDefaults.bool(forKey: MigrationKeys.tradesMigrated))
            || (hasTradingInfo && !userDefaults.bool(forKey: MigrationKeys.tradingInfoMigrated))
        
        Task { await Logger.shared.info("DataMigrationService: UserDefaults data check - usertrades: \(hasUserTrades) (size: \(userTradesData?.count ?? 0)), tradingInfoData: \(hasTradingInfo) (size: \(tradingInfoDataContent?.count ?? 0)), needsDataMigration: \(needsDataMigration)") }
        
        // Debug: List all UserDefaults keys to see what's available
        let allKeys = userDefaults.dictionaryRepresentation().keys.sorted()
        let tradeKeys = allKeys.filter { $0.contains("trade") || $0.contains("info") }
        Task { await Logger.shared.debug("DataMigrationService: Available UserDefaults keys: \(tradeKeys)") }
        
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

                // Delete the old-schema entities exactly once. Without its own marker this
                // ran on every launch until verification passed, deleting newly
                // computed snapshots each time.
                // Version 0 means there is no record of an older version: a fresh install, or
                // preferences that were reset. Neither has old-schema rows, and after a reset the
                // store holds current snapshots that must not be deleted.
                if migrationVersionStored > 0,
                   !userDefaults.bool(forKey: MigrationKeys.preV3PortfolioSnapshotsDeleted) {
                    try await deleteOldPortfolioSnapshotEntities()
                    userDefaults.set(true, forKey: MigrationKeys.preV3PortfolioSnapshotsDeleted)
                    Task { await Logger.shared.info("DataMigrationService: Deleted old PortfolioSnapshotEntity instances (if any existed).") }
                }

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
            }
            
            // Migrate trades from UserDefaults
            let hasUserTrades = userDefaults.data(forKey: "usertrades") != nil
            let hasCoreDataTrades = await tradeDataMigrationService.areTradesMigrated()
            if (!userDefaults.bool(forKey: MigrationKeys.tradesMigrated) || (hasUserTrades && !hasCoreDataTrades))
                && (migrationVersionStored < currentMigrationVersion || hasUserTrades) {
                try await migrateTrades()
            }
            
            // Migrate trading info from UserDefaults
            let hasTradingInfo = userDefaults.data(forKey: "tradingInfoData") != nil
            if !userDefaults.bool(forKey: MigrationKeys.tradingInfoMigrated) && (migrationVersionStored < currentMigrationVersion || hasTradingInfo) {
                try await migrateTradingInfo()
            }

            let report = try await verifyMigration()
            guard report.succeeded else {
                throw NSError(
                    domain: "DataMigrationService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Migration copy verification failed"]
                )
            }

            userDefaults.set(true, forKey: MigrationKeys.priceSnapshotsMigrated)
            userDefaults.set(true, forKey: MigrationKeys.portfolioSnapshotsMigrated)
            userDefaults.set(true, forKey: MigrationKeys.tradesMigrated)
            userDefaults.set(true, forKey: MigrationKeys.tradingInfoMigrated)
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
            do {
                let storeType = context.persistentStoreCoordinator?.persistentStores.first?.type
                let deletedCount: Int

                if storeType == NSInMemoryStoreType {
                    let fetchRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
                    let snapshots = try context.fetch(fetchRequest)
                    snapshots.forEach(context.delete)
                    deletedCount = snapshots.count
                } else {
                    let fetchRequest: NSFetchRequest<NSFetchRequestResult> = PortfolioSnapshotEntity.fetchRequest()
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                    deleteRequest.resultType = .resultTypeCount
                    let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                    deletedCount = result?.result as? Int ?? 0
                }

                if context.hasChanges {
                    try context.save()
                }
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
                let snapshotCount = allSnapshots.count
                Task { await Logger.shared.info("Loaded \(snapshotCount) snapshots from tiered cache") }
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
                let snapshotCount = legacySnapshots.values.flatMap { $0 }.count
                Task { await Logger.shared.info("Loaded additional \(snapshotCount) snapshots from legacy storage") }
            } catch {
                Task { await Logger.shared.error("Failed to decode legacy price snapshots: \(error)") }
            }
        }
        
        // Remove duplicates based on symbol and timestamp, keeping the first of each
        // in one pass (the old lookup per key was quadratic).
        var seen = Set<String>()
        return allSnapshots.filter { seen.insert("\($0.symbol)_\($0.timestamp.timeIntervalSince1970)").inserted }
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

        // Both keys can hold the same dates. Keep the first (enhanced) snapshot per
        // date so the copy and the verification count compare like with like;
        // duplicates made verification fail on every launch.
        var seenDates: Set<Date> = []
        return allSnapshots.filter { seenDates.insert($0.date).inserted }
    }
    
    private func convertLegacyPortfolioSnapshot(_ legacy: PortfolioSnapshot) -> HistoricalPortfolioSnapshot {
        let portfolioComposition = Dictionary(firstValuesFor: 
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
    
    func verifyMigration() async throws -> MigrationVerificationReport {
        Task { await Logger.shared.info("Verifying migration...") }

        let sourcePriceCount = loadPriceSnapshotsFromUserDefaults().count
        let sourcePortfolioCount = loadPortfolioSnapshotsFromUserDefaults().count
        let sourceHadTrades = userDefaults.data(forKey: "usertrades") != nil
        let sourceHadTradingInfo = userDefaults.data(forKey: "tradingInfoData") != nil
        let portfolioCount = try await coreDataService.getPortfolioSnapshotCount()
        let totalPriceSnapshots = try await coreDataService.getTotalPriceSnapshotCount()
        let tradesValid: Bool
        if sourceHadTrades {
            tradesValid = (try? await tradeDataMigrationService.validateMigration()) ?? false
        } else {
            tradesValid = true
        }
        let report = MigrationVerificationReport(
            sourcePriceSnapshots: sourcePriceCount,
            sourcePortfolioSnapshots: sourcePortfolioCount,
            sourceHadTrades: sourceHadTrades,
            sourceHadTradingInfo: sourceHadTradingInfo,
            destinationPriceSnapshots: totalPriceSnapshots,
            destinationPortfolioSnapshots: portfolioCount,
            tradesValid: tradesValid
        )

        Task {
            await Logger.shared.info(
                "Migration verification: source prices=\(sourcePriceCount), destination prices=\(totalPriceSnapshots), source portfolio=\(sourcePortfolioCount), destination portfolio=\(portfolioCount), trades valid=\(tradesValid)"
            )
        }
        return report
    }
}

// MARK: - Array Extension for Chunking

// Array extension moved to HistoricalDataManager.swift to avoid duplicates
