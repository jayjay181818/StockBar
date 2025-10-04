import Foundation
import CoreData
import OSLog

/// Statistics about compression status
struct CompressionStats {
    let totalPriceSnapshots: Int
    let totalPortfolioSnapshots: Int
    let compressiblePriceSnapshots: Int
    let compressiblePortfolioSnapshots: Int
    let aggregatablePriceSnapshots: Int
    let compressionAge: TimeInterval
    let aggregationAge: TimeInterval
    
    var compressionRatio: Double {
        guard totalPriceSnapshots > 0 else { return 0 }
        return Double(compressiblePriceSnapshots) / Double(totalPriceSnapshots)
    }
    
    var potentialSpaceSavings: String {
        let compressibleRatio = Double(compressiblePriceSnapshots) / max(1, Double(totalPriceSnapshots))
        let aggregatableRatio = Double(aggregatablePriceSnapshots) / max(1, Double(totalPriceSnapshots))
        
        let compressionSavings = compressibleRatio * 0.75 // 75% compression for old data
        let aggregationSavings = aggregatableRatio * 0.90 // 90% compression for ancient data
        
        let totalSavings = (compressionSavings + aggregationSavings) * 100
        return String(format: "%.1f%%", min(totalSavings, 90))
    }
}

/// Service for compressing and managing older historical data to optimize storage and performance
actor DataCompressionService {
    static let shared = DataCompressionService()
    
    private let logger = Logger.shared
    private let coreDataStack = CoreDataStack.shared
    
    // Compression thresholds
    private let compressionAge: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    private let aggregationAge: TimeInterval = 365 * 24 * 60 * 60 // 1 year
    private let deletionAge: TimeInterval = 5 * 365 * 24 * 60 * 60 // 5 years
    
    // Compression ratios
    private let dailyCompressionRatio = 4 // Keep every 4th data point for older data
    private let weeklyCompressionRatio = 7 // Weekly aggregation for very old data
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Performs comprehensive data compression and cleanup
    func performDataCompression() async {
        await logger.info("🗜️ Starting comprehensive data compression")
        
        await compressionStep1_RemoveVeryOldData()
        await compressionStep2_AggregateAncientData()
        await compressionStep3_CompressOldData()
        await compressionStep4_OptimizeRecentData()
        
        await logger.info("🗜️ Data compression completed")
    }
    
    /// Performs lightweight compression for regular maintenance
    func performLightweightCompression() async {
        await logger.info("🗜️ Starting lightweight data compression")
        
        await compressionStep3_CompressOldData()
        await compressionStep4_OptimizeRecentData()
        
        await logger.info("🗜️ Lightweight compression completed")
    }
    
    /// Gets compression statistics
    func getCompressionStats() async -> CompressionStats {
        let context = coreDataStack.newBackgroundContext()
        
        return await context.perform {
            let priceRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            let portfolioRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            
            let totalPriceSnapshots = (try? context.count(for: priceRequest)) ?? 0
            let totalPortfolioSnapshots = (try? context.count(for: portfolioRequest)) ?? 0
            
            // Count old data that could be compressed
            let thirtyDaysAgo = Date().addingTimeInterval(-self.compressionAge)
            let oneYearAgo = Date().addingTimeInterval(-self.aggregationAge)
            
            priceRequest.predicate = NSPredicate(format: "timestamp < %@", thirtyDaysAgo as NSDate)
            let compressiblePriceSnapshots = (try? context.count(for: priceRequest)) ?? 0
            
            portfolioRequest.predicate = NSPredicate(format: "timestamp < %@", thirtyDaysAgo as NSDate)
            let compressiblePortfolioSnapshots = (try? context.count(for: portfolioRequest)) ?? 0
            
            priceRequest.predicate = NSPredicate(format: "timestamp < %@", oneYearAgo as NSDate)
            let aggregatablePriceSnapshots = (try? context.count(for: priceRequest)) ?? 0
            
            return CompressionStats(
                totalPriceSnapshots: totalPriceSnapshots,
                totalPortfolioSnapshots: totalPortfolioSnapshots,
                compressiblePriceSnapshots: compressiblePriceSnapshots,
                compressiblePortfolioSnapshots: compressiblePortfolioSnapshots,
                aggregatablePriceSnapshots: aggregatablePriceSnapshots,
                compressionAge: self.compressionAge,
                aggregationAge: self.aggregationAge
            )
        }
    }
    
    // MARK: - Compression Steps
    
    /// Step 1: Remove data older than 5 years (configurable)
    private func compressionStep1_RemoveVeryOldData() async {
        await logger.info("🗜️ Step 1: Removing very old data (>5 years)")
        
        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-deletionAge)
        
        await context.perform {
            do {
                // Remove old price snapshots
                let priceRequest: NSFetchRequest<NSFetchRequestResult> = PriceSnapshotEntity.fetchRequest()
                priceRequest.predicate = NSPredicate(format: "timestamp < %@", cutoffDate as NSDate)
                
                let priceBatchDelete = NSBatchDeleteRequest(fetchRequest: priceRequest)
                priceBatchDelete.resultType = .resultTypeCount
                
                let priceResult = try context.execute(priceBatchDelete) as? NSBatchDeleteResult
                let deletedPriceCount = priceResult?.result as? Int ?? 0
                
                // Remove old portfolio snapshots
                let portfolioRequest: NSFetchRequest<NSFetchRequestResult> = PortfolioSnapshotEntity.fetchRequest()
                portfolioRequest.predicate = NSPredicate(format: "timestamp < %@", cutoffDate as NSDate)
                
                let portfolioBatchDelete = NSBatchDeleteRequest(fetchRequest: portfolioRequest)
                portfolioBatchDelete.resultType = .resultTypeCount
                
                let portfolioResult = try context.execute(portfolioBatchDelete) as? NSBatchDeleteResult
                let deletedPortfolioCount = portfolioResult?.result as? Int ?? 0
                
                try context.save()
                
                Task { await self.logger.info("🗜️ Deleted \(deletedPriceCount) old price snapshots and \(deletedPortfolioCount) old portfolio snapshots") }
                
            } catch {
                Task { await self.logger.error("🗜️ Failed to remove very old data: \(error)") }
            }
        }
    }
    
    /// Step 2: Aggregate very old data (1+ years) into weekly summaries
    private func compressionStep2_AggregateAncientData() async {
        await logger.info("🗜️ Step 2: Aggregating ancient data into weekly summaries")
        
        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-aggregationAge)
        let compressionCutoff = Date().addingTimeInterval(-compressionAge)
        
        await context.perform {
            do {
                // Get symbols that have data older than 1 year
                let symbolRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
                symbolRequest.predicate = NSPredicate(format: "timestamp < %@ AND timestamp >= %@", 
                                                    compressionCutoff as NSDate, cutoffDate as NSDate)
                symbolRequest.propertiesToFetch = ["symbol"]
                symbolRequest.returnsDistinctResults = true
                
                let snapshots = try context.fetch(symbolRequest)
                let symbols = Set(snapshots.compactMap { $0.symbol })
                
                for symbol in symbols {
                    self.aggregateWeeklyDataForSymbolSync(symbol, before: compressionCutoff, context: context)
                }
                
                try context.save()
                
            } catch {
                Task { await self.logger.error("🗜️ Failed to aggregate ancient data: \(error)") }
            }
        }
    }
    
    /// Step 3: Compress old data (30+ days) by reducing density
    private func compressionStep3_CompressOldData() async {
        await logger.info("🗜️ Step 3: Compressing old data (>30 days)")
        
        let context = coreDataStack.newBackgroundContext()
        let cutoffDate = Date().addingTimeInterval(-compressionAge)
        
        await context.perform {
            do {
                // Get symbols that have data older than 30 days
                let symbolRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
                symbolRequest.predicate = NSPredicate(format: "timestamp < %@", cutoffDate as NSDate)
                symbolRequest.propertiesToFetch = ["symbol"]
                symbolRequest.returnsDistinctResults = true
                
                let snapshots = try context.fetch(symbolRequest)
                let symbols = Set(snapshots.compactMap { $0.symbol })
                
                var totalCompressed = 0
                
                for symbol in symbols {
                    let compressed = self.compressDataForSymbolSync(symbol, before: cutoffDate, context: context)
                    totalCompressed += compressed
                }
                
                try context.save()
                Task { await self.logger.info("🗜️ Compressed \(totalCompressed) data points") }
                
            } catch {
                Task { await self.logger.error("🗜️ Failed to compress old data: \(error)") }
            }
        }
    }
    
    /// Step 4: Optimize recent data storage
    private func compressionStep4_OptimizeRecentData() async {
        await logger.info("🗜️ Step 4: Optimizing recent data storage")
        
        let context = coreDataStack.newBackgroundContext()
        
        await context.perform {
            do {
                // Remove duplicate entries for recent data
                self.removeDuplicateEntriesSync(context: context)
                
                // Optimize Core Data storage
                try context.save()
                
            } catch {
                Task { await self.logger.error("🗜️ Failed to optimize recent data: \(error)") }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Aggregates data into weekly summaries for a specific symbol (async version)
    private func aggregateWeeklyDataForSymbol(_ symbol: String, before date: Date, context: NSManagedObjectContext) async {
        aggregateWeeklyDataForSymbolSync(symbol, before: date, context: context)
    }
    
    /// Aggregates data into weekly summaries for a specific symbol (sync version)
    private nonisolated func aggregateWeeklyDataForSymbolSync(_ symbol: String, before date: Date, context: NSManagedObjectContext) {
        do {
            let request: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "symbol == %@ AND timestamp < %@", symbol, date as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let snapshots = try context.fetch(request)
            
            if snapshots.count < weeklyCompressionRatio * 2 {
                return // Not enough data to compress
            }
            
            // Group by week
            let calendar = Calendar.current
            let groupedByWeek = Dictionary(grouping: snapshots) { snapshot in
                calendar.dateInterval(of: .weekOfYear, for: snapshot.timestamp ?? Date())?.start ?? Date()
            }
            
            var toDelete: [PriceSnapshotEntity] = []
            
            for (_, weekSnapshots) in groupedByWeek {
                if weekSnapshots.count > 1 {
                    // Keep the first snapshot of the week, delete the rest
                    let sortedWeekSnapshots = weekSnapshots.sorted { ($0.timestamp ?? Date.distantPast) < ($1.timestamp ?? Date.distantPast) }
                    
                    // Keep the first one, mark others for deletion
                    toDelete.append(contentsOf: sortedWeekSnapshots.dropFirst())
                }
            }
            
            // Delete the marked snapshots
            for snapshot in toDelete {
                context.delete(snapshot)
            }
            
            Task { await logger.debug("🗜️ Aggregated \(toDelete.count) snapshots for \(symbol) into weekly summaries") }
            
        } catch {
            Task { await logger.error("🗜️ Failed to aggregate weekly data for \(symbol): \(error)") }
        }
    }
    
    /// Compresses data for a specific symbol by reducing density (async version)
    private func compressDataForSymbol(_ symbol: String, before date: Date, context: NSManagedObjectContext) async -> Int {
        return compressDataForSymbolSync(symbol, before: date, context: context)
    }
    
    /// Compresses data for a specific symbol by reducing density (sync version)
    private nonisolated func compressDataForSymbolSync(_ symbol: String, before date: Date, context: NSManagedObjectContext) -> Int {
        do {
            let request: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            request.predicate = NSPredicate(format: "symbol == %@ AND timestamp < %@", symbol, date as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let snapshots = try context.fetch(request)
            
            if snapshots.count < dailyCompressionRatio * 2 {
                return 0 // Not enough data to compress
            }
            
            var toDelete: [PriceSnapshotEntity] = []
            
            // Keep every nth snapshot, delete others
            for (index, snapshot) in snapshots.enumerated() {
                if index % dailyCompressionRatio != 0 {
                    toDelete.append(snapshot)
                }
            }
            
            // Delete the marked snapshots
            for snapshot in toDelete {
                context.delete(snapshot)
            }
            
            Task { await logger.debug("🗜️ Compressed \(toDelete.count) snapshots for \(symbol)") }
            return toDelete.count
            
        } catch {
            Task { await logger.error("🗜️ Failed to compress data for \(symbol): \(error)") }
            return 0
        }
    }
    
    /// Removes duplicate entries (async version)
    private func removeDuplicateEntries(context: NSManagedObjectContext) async {
        removeDuplicateEntriesSync(context: context)
    }
    
    /// Removes duplicate entries (sync version)
    private nonisolated func removeDuplicateEntriesSync(context: NSManagedObjectContext) {
        do {
            // Remove duplicate price snapshots (same symbol + timestamp)
            let priceRequest: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            priceRequest.sortDescriptors = [
                NSSortDescriptor(key: "symbol", ascending: true),
                NSSortDescriptor(key: "timestamp", ascending: true)
            ]
            
            let priceSnapshots = try context.fetch(priceRequest)
            var seenPriceKeys = Set<String>()
            var duplicatePriceSnapshots: [PriceSnapshotEntity] = []
            
            for snapshot in priceSnapshots {
                let key = "\(snapshot.symbol ?? "")_\(snapshot.timestamp?.timeIntervalSince1970 ?? 0)"
                if seenPriceKeys.contains(key) {
                    duplicatePriceSnapshots.append(snapshot)
                } else {
                    seenPriceKeys.insert(key)
                }
            }
            
            for duplicate in duplicatePriceSnapshots {
                context.delete(duplicate)
            }
            
            Task { await logger.debug("🗜️ Removed \(duplicatePriceSnapshots.count) duplicate price snapshots") }
            
            // Remove duplicate portfolio snapshots (same timestamp + composition hash)
            let portfolioRequest: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            portfolioRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let portfolioSnapshots = try context.fetch(portfolioRequest)
            var seenPortfolioKeys = Set<String>()
            var duplicatePortfolioSnapshots: [PortfolioSnapshotEntity] = []
            
            for snapshot in portfolioSnapshots {
                let key = "\(snapshot.timestamp?.timeIntervalSince1970 ?? 0)_\(snapshot.compositionHash ?? "")"
                if seenPortfolioKeys.contains(key) {
                    duplicatePortfolioSnapshots.append(snapshot)
                } else {
                    seenPortfolioKeys.insert(key)
                }
            }
            
            for duplicate in duplicatePortfolioSnapshots {
                context.delete(duplicate)
            }
            
            Task { await logger.debug("🗜️ Removed \(duplicatePortfolioSnapshots.count) duplicate portfolio snapshots") }
            
        } catch {
            Task { await logger.error("🗜️ Failed to remove duplicate entries: \(error)") }
        }
    }
}

// MARK: - Supporting Types

// Note: CompressionStats struct is already defined at the top of the file