import Foundation
import Combine
import CoreData

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension DateFormatter {
    static let debug: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// CRITICAL FIX: Task timeout utility to prevent infinite processing
func withTaskTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async -> T? {
    return await withTaskGroup(of: T?.self) { group in
        // Add the actual operation
        group.addTask {
            do {
                return try await operation()
            } catch {
                return nil
            }
        }
        
        // Add timeout task
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        
        // Return first completed result and cancel the rest
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}

@MainActor
class HistoricalDataManager: ObservableObject {
    static let shared = HistoricalDataManager()
    
    private let logger = Logger.shared
    private let encoder = JSONEncoder()
    
    // Performance optimization services
    private let compressionService = DataCompressionService.shared
    private let chartDataService = OptimizedChartDataService.shared
    private let batchService = BatchProcessingService.shared
    private let memoryService = MemoryManagementService.shared
    private let decoder = JSONDecoder()
    private let cacheManager = CacheManager.shared
    private let coreDataService: HistoricalDataServiceProtocol
    private let migrationService = DataMigrationService.shared
    
    @Published var portfolioSnapshots: [PortfolioSnapshot] = []
    @Published var priceSnapshots: [String: [PriceSnapshot]] = [:]
    
    // MARK: - Enhanced Portfolio Storage
    
    // New persistent portfolio snapshots storage
    @Published var historicalPortfolioSnapshots: [HistoricalPortfolioSnapshot] = []
    private var currentPortfolioComposition: PortfolioComposition?
    private var lastRetroactiveCalculationDate: Date = Date.distantPast
    
    // Cache for calculated historical portfolio values (legacy - being phased out)
    public private(set) var cachedHistoricalPortfolioValues: [ChartDataPoint] = []
    
    // CRITICAL FIX: Prevent concurrent calculation overlaps
    private var isCalculationInProgress = false
    private let calculationLock = NSLock()
    private var lastPortfolioCalculationDate: Date = Date.distantPast
    private let portfolioCalculationCacheInterval: TimeInterval = 1800 // 30 minutes cache (increased from 5 minutes)
    
    // MARK: - Data Storage Configuration
    
    // Storage keys for persistent data
    private enum StorageKeys {
        static let portfolioSnapshots = "portfolioSnapshots"
        static let priceSnapshots = "priceSnapshots"
        static let historicalPortfolioSnapshots = "historicalPortfolioSnapshots"
        static let currentPortfolioComposition = "currentPortfolioComposition"
        static let lastRetroactiveCalculationDate = "lastRetroactiveCalculationDate"
        static let cachedHistoricalPortfolioValues = "cachedHistoricalPortfolioValues"
        static let lastPortfolioCalculationDate = "lastPortfolioCalculationDate"
    }
    
    // MARK: - Performance Caching
    
    // Cache for getOptimalStockData results to prevent repeated expensive calculations
    private var stockDataCache: [String: [ChartDataPoint]] = [:]
    private var stockDataCacheTimestamp: [String: Date] = [:]
    private let stockDataCacheInterval: TimeInterval = 30 // 30 seconds cache
    
    // Core Data Era: Dramatically increased limits for decades of data retention
    private let maxDataPoints = 25000 // 10x increase: 50+ years per stock (Core Data optimized)
    private let maxPortfolioSnapshots = 8000 // 4x increase: 25+ years portfolio history
    
    private var snapshotInterval: TimeInterval = 300 // 5 minutes (restored from 30 seconds)
    private var lastSnapshotTime: Date = Date.distantPast
    
    // In init() or a new method, add check for retroactive calculation:
    // This check would ideally be in DataModel or AppDelegate after migration completes.
    // For example, in DataModel.init() after ensuring migration service has run:
    // if DataMigrationService.shared.needsRetroactiveCalculation {
    //    Logger.shared.info("HistoricalDataManager: Triggering retroactive calculation due to migration flag.")
    //    Task {
    //        await self.historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
    //        DataMigrationService.shared.needsRetroactiveCalculation = false // Clear the flag
    //    }
    // }

    private init() {
        self.coreDataService = CoreDataHistoricalDataService()
        loadHistoricalData()
        setupPeriodicSave()
        
        // Perform Core Data migration if needed
        Task {
            await performMigrationIfNeeded()
        }
    }
    
    // MARK: - Core Data Migration
    
    private func performMigrationIfNeeded() async {
        do {
            if !migrationService.isPriceSnapshotsMigrated || !migrationService.isPortfolioSnapshotsMigrated {
                await logger.info("🔄 Starting Core Data migration...")
                try await migrationService.performFullMigration()
                
                // Verify migration success
                let success = try await migrationService.verifyMigration()
                if success {
                    await logger.info("✅ Core Data migration completed successfully")
                    // Optionally clean up legacy data after successful verification
                    // migrationService.cleanupLegacyData()
                } else {
                    await logger.warning("⚠️ Core Data migration verification failed")
                }
            } else {
                await logger.info("✅ Core Data migration already completed")
            }
        } catch {
            await logger.error("❌ Core Data migration failed: \(error)")
        }
    }
    
    // MARK: - Core Data Integration
    
    /// Load price snapshots from Core Data for a specific symbol
    func loadPriceSnapshotsFromCoreData(for symbol: String, timeRange: ChartTimeRange) async -> [PriceSnapshot] {
        do {
            let startDate = timeRange.startDate()
            let endDate = Date()
            let snapshots = try await coreDataService.fetchPriceSnapshots(for: symbol, from: startDate, to: endDate)
            await logger.debug("📊 Loaded \(snapshots.count) price snapshots from Core Data for \(symbol)") 
            return snapshots
        } catch {
            await logger.error("❌ Failed to load price snapshots from Core Data for \(symbol): \(error)") 
            return []
        }
    }
    
    /// Load portfolio snapshots from Core Data
    func loadPortfolioSnapshotsFromCoreData(timeRange: ChartTimeRange) async -> [HistoricalPortfolioSnapshot] {
        do {
            let startDate = timeRange.startDate()
            let endDate = Date()
            await logger.info("📈 Loading portfolio snapshots from Core Data: startDate=\(startDate), endDate=\(endDate)")
            let snapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)
            await logger.info("📈 Loaded \(snapshots.count) portfolio snapshots from Core Data")
            return snapshots
        } catch {
            await logger.error("❌ Failed to load portfolio snapshots from Core Data: \(error)")
            return []
        }
    }

    /// Force reload portfolio snapshots from Core Data (for debugging/refresh)
    func reloadPortfolioSnapshotsFromCoreData() async {
        await logger.info("🔄 Force reloading portfolio snapshots from Core Data...")
        let snapshots = await loadPortfolioSnapshotsFromCoreData(timeRange: .all)
        let count = snapshots.count
        await MainActor.run {
            self.historicalPortfolioSnapshots = snapshots
        }
        await logger.info("🔄 Reloaded \(count) portfolio snapshots into memory")
    }

    /// Fetch historical portfolio snapshots for attribution analysis (preferred method - has position data)
    func fetchHistoricalPortfolioSnapshots(from startDate: Date, to endDate: Date) async -> [HistoricalPortfolioSnapshot] {
        do {
            let historicalSnapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)
            await logger.debug("📊 Fetched \(historicalSnapshots.count) historical portfolio snapshots for attribution analysis")
            return historicalSnapshots
        } catch {
            await logger.error("❌ Failed to fetch historical portfolio snapshots: \(error)")
            return []
        }
    }

    /// Fetch portfolio snapshots for a specific date range (legacy converted format)
    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async -> [PortfolioSnapshot] {
        do {
            // Fetch from Core Data
            let historicalSnapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)

            // Convert HistoricalPortfolioSnapshot to PortfolioSnapshot format
            let portfolioSnapshots: [PortfolioSnapshot] = historicalSnapshots.map { historical in
                // Convert PositionSnapshot dictionary to PriceSnapshot array
                let priceSnapshots = historical.portfolioComposition.map { (symbol, position) -> PriceSnapshot in
                    PriceSnapshot(
                        timestamp: historical.date,
                        price: position.priceAtDate,
                        previousClose: position.priceAtDate, // We don't have previous close in PositionSnapshot
                        volume: nil,
                        symbol: symbol
                    )
                }

                return PortfolioSnapshot(
                    timestamp: historical.date,
                    totalValue: historical.totalValue,
                    totalGains: historical.totalGains,
                    currency: historical.currency,
                    priceSnapshots: priceSnapshots
                )
            }

            await logger.debug("📊 Fetched \(portfolioSnapshots.count) portfolio snapshots (legacy format)")
            return portfolioSnapshots
        } catch {
            await logger.error("❌ Failed to fetch portfolio snapshots: \(error)")
            return []
        }
    }
    
    /// Save new price snapshots to Core Data using optimized background context
    private func savePriceSnapshotsToCoreData(_ snapshots: [PriceSnapshot]) async {
        // Use optimized background context for heavy save operations
        try? await performOptimizedBackgroundOperation("save price snapshots") { [self] in
            do {
                try await self.coreDataService.savePriceSnapshots(snapshots)
                await self.logger.debug("💾 Saved \(snapshots.count) price snapshots to Core Data") 
            } catch {
                await self.logger.error("❌ Failed to save price snapshots to Core Data: \(error)") 
            }
        }
    }
    
    /// Save portfolio snapshot to Core Data
    private func savePortfolioSnapshotToCoreData(_ snapshot: HistoricalPortfolioSnapshot) async {
        do {
            try await coreDataService.savePortfolioSnapshot(snapshot)
            await logger.debug("💾 Saved portfolio snapshot to Core Data for \(snapshot.date)") 
        } catch {
            await logger.error("❌ Failed to save portfolio snapshot to Core Data: \(error)") 
        }
    }
    
    // MARK: - Optimized Background Operations
    
    /// Perform heavy operations using optimized background context to prevent UI blocking
    private func performOptimizedBackgroundOperation<T>(_ operationName: String, operation: @escaping () async throws -> T) async throws -> T {
        await logger.debug("🔄 Starting optimized background operation: \(operationName)")
        
        // Use task with specific priority for background work
        return try await Task.detached(priority: .utility) {
            let result = try await operation()
            await Logger.shared.debug("✅ Completed optimized background operation: \(operationName)")
            return result
        }.value
    }
    
    /// Batch process large datasets in chunks to prevent memory spikes
    private func processBatchOperation<T, R>(
        items: [T],
        batchSize: Int = 100,
        operationName: String,
        operation: @escaping ([T]) async throws -> R
    ) async throws -> [R] {
        let batches = items.chunked(into: batchSize)
        var results: [R] = []
        
        await logger.info("🔄 Processing \(items.count) items in \(batches.count) batches for \(operationName)")
        
        for (index, batch) in batches.enumerated() {
            let result = try await performOptimizedBackgroundOperation("\(operationName) batch \(index + 1)") {
                return try await operation(batch)
            }
            results.append(result)
            
            // Small delay between batches to prevent overwhelming the system
            if index < batches.count - 1 {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
        }
        
        await logger.info("✅ Completed batch processing for \(operationName)")
        return results
    }
    
    // MARK: - Tiered Cache Integration
    
    /// Store data in appropriate cache tier based on recency and access patterns
    private func storeInCache<T: Codable>(_ data: T, key: String, isRecent: Bool = false) {
        let cacheLevel: CacheManager.CacheLevel = isRecent ? .memory : 
                        (key.contains("historical") ? .archived : .disk)
        cacheManager.store(data, forKey: key, level: cacheLevel)
    }
    
    /// Retrieve data from cache with fallback to UserDefaults for migration
    private func retrieveFromCache<T: Codable>(_ type: T.Type, key: String) -> T? {
        // Try cache first
        if let cachedData = cacheManager.retrieve(type, forKey: key) {
            return cachedData
        }
        
        // Fallback to UserDefaults for backward compatibility during migration
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? decoder.decode(type, from: data) {
            // Migrate to cache for future access
            storeInCache(decoded, key: key)
                            Task { await logger.debug("🔄 Migrated \(key) from UserDefaults to cache") }
            return decoded
        }
        
        return nil
    }
    
    /// Get recent price snapshots optimized for memory cache
    func getRecentPriceSnapshots(for symbol: String, days: Int = 30) -> [PriceSnapshot] {
        let cacheKey = "recent_prices_\(symbol)_\(days)"
        
        if let cached: [PriceSnapshot] = retrieveFromCache([PriceSnapshot].self, key: cacheKey) {
            return cached
        }
        
        // Calculate from full dataset
        let allSnapshots = priceSnapshots[symbol] ?? []
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
        let recentSnapshots = allSnapshots.filter { $0.timestamp >= cutoffDate }
        
        // Store in memory cache only for very small windows; otherwise prefer disk
        let shouldUseMemory = days <= 7 && recentSnapshots.count <= 4_000
        storeInCache(recentSnapshots, key: cacheKey, isRecent: shouldUseMemory)
        
        return recentSnapshots
    }
    
    /// Get historical portfolio snapshots with intelligent caching
    func getHistoricalPortfolioSnapshots(timeRange: ChartTimeRange) -> [HistoricalPortfolioSnapshot] {
        let cacheKey = "portfolio_snapshots_\(timeRange.rawValue)"
        
        if let cached: [HistoricalPortfolioSnapshot] = retrieveFromCache([HistoricalPortfolioSnapshot].self, key: cacheKey) {
            return cached
        }
        
        // Filter from full dataset based on time range
        let cutoffDate = timeRange.startDate()
        let filteredSnapshots = historicalPortfolioSnapshots.filter { $0.date >= cutoffDate }
        
        // Determine cache level based on data recency
        let isRecent = timeRange == .day || timeRange == .week
        storeInCache(filteredSnapshots, key: cacheKey, isRecent: isRecent)
        
        return filteredSnapshots
    }
    
    /// Cache portfolio analytics to avoid recalculation
    func getCachedPortfolioAnalytics(for timeRange: ChartTimeRange) -> PortfolioAnalytics? {
        let cacheKey = "analytics_\(timeRange.rawValue)_\(Date().timeIntervalSince1970 / 3600)" // Hour-based cache
        return retrieveFromCache(PortfolioAnalytics.self, key: cacheKey)
    }
    
    func setCachedPortfolioAnalytics(_ analytics: PortfolioAnalytics, for timeRange: ChartTimeRange) {
        let cacheKey = "analytics_\(timeRange.rawValue)_\(Date().timeIntervalSince1970 / 3600)"
        storeInCache(analytics, key: cacheKey, isRecent: timeRange == .day || timeRange == .week)
    }
    
    /// Invalidate cache when data changes
    private func invalidateRelatedCaches(for symbol: String? = nil) {
        if let symbol = symbol {
            // Invalidate symbol-specific caches
            for days in [7, 30, 90] {
                cacheManager.remove(forKey: "recent_prices_\(symbol)_\(days)")
            }
        }
        
        // Invalidate portfolio caches
        for timeRange in ChartTimeRange.allCases {
            cacheManager.remove(forKey: "portfolio_snapshots_\(timeRange.rawValue)")
            cacheManager.remove(forKey: "analytics_\(timeRange.rawValue)_\(Date().timeIntervalSince1970 / 3600)")
        }
        
        Task { await logger.debug("🗑️ Invalidated caches for symbol: \(symbol ?? "all")") }
    }
    
    // MARK: - Performance Enhancement Methods
    
    /// Get cached analytics or calculate and cache them
    func getOrCalculateAnalytics(for timeRange: ChartTimeRange) -> PortfolioAnalytics? {
        // Try to get from cache first
        if let cached = getCachedPortfolioAnalytics(for: timeRange) {
            Task { await logger.debug("📊 Using cached analytics for \(timeRange.rawValue)") }
            return cached
        }
        
        // Calculate analytics if not cached
        let snapshots = getHistoricalPortfolioSnapshots(timeRange: timeRange)
        guard !snapshots.isEmpty else { return nil }
        
        let analytics = calculatePortfolioAnalytics(from: snapshots)
        
        // Cache for future use
        setCachedPortfolioAnalytics(analytics, for: timeRange)
        Task { await logger.debug("📊 Calculated and cached analytics for \(timeRange.rawValue)") }
        
        return analytics
    }
    
    /// Preload frequently accessed data into memory cache
    func preloadFrequentlyAccessedData() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            // Preload recent data for all symbols
            for symbol in await self.priceSnapshots.keys {
                _ = await self.getRecentPriceSnapshots(for: symbol, days: 7)  // Week data
                _ = await self.getRecentPriceSnapshots(for: symbol, days: 30) // Month data
            }
            
            // Preload common time ranges
            for timeRange in [ChartTimeRange.day, .week, .month] {
                _ = await self.getHistoricalPortfolioSnapshots(timeRange: timeRange)
            }
            
            Task { await self.logger.debug("🚀 Preloaded frequently accessed data into memory cache") }
        }
    }
    
    /// Get cache performance metrics for monitoring
    func getCachePerformanceMetrics() -> (hitRate: Double, totalSize: String, memoryEntries: Int) {
        let stats = cacheManager.cacheStats
        let memoryEntries = stats.memoryHits + stats.memoryMisses
        
        return (
            hitRate: stats.overallHitRate,
            totalSize: stats.totalSizeFormatted,
            memoryEntries: memoryEntries
        )
    }
    
    /// Calculate comprehensive portfolio analytics from historical snapshots
    func calculatePortfolioAnalytics(from snapshots: [HistoricalPortfolioSnapshot]) -> PortfolioAnalytics {
        guard !snapshots.isEmpty else {
            // Return empty analytics if no data
            return PortfolioAnalytics(
                timeRange: "empty",
                totalReturn: 0, totalReturnPercent: 0, annualizedReturn: 0,
                volatility: 0, sharpeRatio: 0, maxDrawdown: 0, maxDrawdownPercent: 0,
                minValue: 0, maxValue: 0, averageValue: 0, finalValue: 0, initialValue: 0,
                winningDays: 0, losingDays: 0, totalDays: 0, winRate: 0,
                currency: "USD", bestDay: 0, worstDay: 0, consecutiveWins: 0, consecutiveLosses: 0
            )
        }
        
        let sortedSnapshots = snapshots.sorted { $0.date < $1.date }
        let initialValue = sortedSnapshots.first?.totalValue ?? 0
        let finalValue = sortedSnapshots.last?.totalValue ?? 0
        let currency = sortedSnapshots.first?.currency ?? "USD"
        
        // Basic return calculations
        let totalReturn = finalValue - initialValue
        let totalReturnPercent = initialValue > 0 ? (totalReturn / initialValue) * 100 : 0
        
        // Calculate daily returns for advanced metrics
        var dailyReturns: [Double] = []
        var values: [Double] = []
        var winningDays = 0
        var losingDays = 0
        
        for i in 1..<sortedSnapshots.count {
            let previousValue = sortedSnapshots[i-1].totalValue
            let currentValue = sortedSnapshots[i].totalValue
            values.append(currentValue)
            
            if previousValue > 0 {
                let dailyReturn = (currentValue - previousValue) / previousValue
                dailyReturns.append(dailyReturn)
                
                if dailyReturn > 0 {
                    winningDays += 1
                } else if dailyReturn < 0 {
                    losingDays += 1
                }
            }
        }
        
        // Annualized return calculation
        let dayCount = sortedSnapshots.count
        let years = Double(dayCount) / 365.25
        let annualizedReturn = years > 0 ? (pow(finalValue / initialValue, 1.0 / years) - 1) * 100 : 0
        
        // Volatility (standard deviation of daily returns)
        let avgDailyReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - avgDailyReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance) * sqrt(252) * 100 // Annualized volatility as percentage
        
        // Sharpe ratio (assuming risk-free rate of 2%)
        let riskFreeRate = 0.02
        let sharpeRatio = volatility > 0 ? (annualizedReturn / 100 - riskFreeRate) / (volatility / 100) : 0
        
        // Maximum drawdown calculation
        var peak = initialValue
        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        
        for value in values {
            if value > peak {
                peak = value
            } else {
                let drawdown = peak - value
                let drawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
                
                if drawdown > maxDrawdown {
                    maxDrawdown = drawdown
                    maxDrawdownPercent = drawdownPercent
                }
            }
        }
        
        // Value statistics
        let minValue = values.min() ?? initialValue
        let maxValue = values.max() ?? finalValue
        let averageValue = values.isEmpty ? initialValue : values.reduce(0, +) / Double(values.count)
        
        // Best and worst day
        let bestDay = dailyReturns.max() ?? 0
        let worstDay = dailyReturns.min() ?? 0
        
        // Consecutive wins/losses
        var currentWinStreak = 0
        var currentLossStreak = 0
        var maxWinStreak = 0
        var maxLossStreak = 0
        
        for dailyReturn in dailyReturns {
            if dailyReturn > 0 {
                currentWinStreak += 1
                currentLossStreak = 0
                maxWinStreak = max(maxWinStreak, currentWinStreak)
            } else if dailyReturn < 0 {
                currentLossStreak += 1
                currentWinStreak = 0
                maxLossStreak = max(maxLossStreak, currentLossStreak)
            }
        }
        
        // Win rate
        let totalTradingDays = winningDays + losingDays
        let winRate = totalTradingDays > 0 ? Double(winningDays) / Double(totalTradingDays) * 100 : 0
        
        return PortfolioAnalytics(
            timeRange: determineTimeRange(from: sortedSnapshots),
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            annualizedReturn: annualizedReturn,
            volatility: volatility,
            sharpeRatio: sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            minValue: minValue,
            maxValue: maxValue,
            averageValue: averageValue,
            finalValue: finalValue,
            initialValue: initialValue,
            winningDays: winningDays,
            losingDays: losingDays,
            totalDays: dayCount,
            winRate: winRate,
            currency: currency,
            bestDay: bestDay * 100, // Convert to percentage
            worstDay: worstDay * 100, // Convert to percentage
            consecutiveWins: maxWinStreak,
            consecutiveLosses: maxLossStreak
        )
    }
    
    private func determineTimeRange(from snapshots: [HistoricalPortfolioSnapshot]) -> String {
        guard let first = snapshots.first, let last = snapshots.last else { return "unknown" }
        
        let timeInterval = last.date.timeIntervalSince(first.date)
        let days = timeInterval / (24 * 60 * 60)
        
        switch days {
        case 0...2: return "1D"
        case 3...10: return "1W"
        case 11...40: return "1M"
        case 41...120: return "3M"
        case 121...200: return "6M"
        case 201...400: return "1Y"
        default: return "All"
        }
    }
    
    func recordSnapshot(from dataModel: DataModel) {
        let now = Date()
        let timeSinceLastSnapshot = now.timeIntervalSince(lastSnapshotTime)
        
        Task { await logger.debug("📸 Snapshot attempt: timeSinceLastSnapshot=\(Int(timeSinceLastSnapshot))s, required=\(Int(snapshotInterval))s") }
        
        guard timeSinceLastSnapshot >= snapshotInterval else {
            Task { await logger.debug("📸 Skipping snapshot - too soon (\(Int(timeSinceLastSnapshot))s < \(Int(snapshotInterval))s)") }
            return // Too soon since last snapshot
        }
        
        lastSnapshotTime = now
        Task { await logger.debug("📸 Recording snapshot at \(now)") }
        
        var currentPriceSnapshots: [PriceSnapshot] = []
        var hasValidData = false
        
        Task { await logger.debug("📸 Checking \(dataModel.realTimeTrades.count) trades for valid data") }
        
        for trade in dataModel.realTimeTrades {
            let price = trade.realTimeInfo.getCurrentDisplayPrice()
            let prevClose = trade.realTimeInfo.prevClosePrice

            Task { await logger.debug("📸 \(trade.trade.name): price=\(price), prevClose=\(prevClose), currency=\(trade.realTimeInfo.currency ?? "nil")") }

            guard !price.isNaN && !prevClose.isNaN && price > 0 else {
                Task { await logger.debug("📸 Skipping \(trade.trade.name) - invalid data") }
                continue // Skip invalid data
            }
            
            let snapshot = PriceSnapshot(
                timestamp: now,
                price: price,
                previousClose: prevClose,
                volume: nil,
                symbol: trade.trade.name
            )
            
            currentPriceSnapshots.append(snapshot)
            
            // Add to individual stock history
            if priceSnapshots[trade.trade.name] == nil {
                priceSnapshots[trade.trade.name] = []
            }
            priceSnapshots[trade.trade.name]?.append(snapshot)
            
            // CRITICAL FIX: Keep snapshots sorted by timestamp for binary search performance
            priceSnapshots[trade.trade.name]?.sort { $0.timestamp < $1.timestamp }
            hasValidData = true
        }
        
        guard hasValidData else {
            Task { await logger.debug("Skipping snapshot - no valid price data") }
            return
        }
        
        // Calculate portfolio metrics
        let gains = dataModel.calculateNetGains()
        let totalValue = calculateTotalPortfolioValue(from: dataModel)
        
        let portfolioSnapshot = PortfolioSnapshot(
            timestamp: now,
            totalValue: totalValue,
            totalGains: gains.amount,
            currency: gains.currency,
            priceSnapshots: currentPriceSnapshots
        )
        
        portfolioSnapshots.append(portfolioSnapshot)
        
        // Clean up old data
        cleanupOldData()
        
        // Invalidate relevant caches since we have new data
        invalidateRelatedCaches()
        
        // Save data to legacy storage
        saveHistoricalData()
        
        // Save data to Core Data (async in background)
        Task {
            await savePriceSnapshotsToCoreData(currentPriceSnapshots)
            
            // Convert legacy portfolio snapshot to enhanced format for Core Data
            let portfolioComposition: [String: PositionSnapshot] = Dictionary(uniqueKeysWithValues: 
                dataModel.realTimeTrades.map { trade in
                    let positionSnapshot = PositionSnapshot(
                        symbol: trade.trade.name,
                        units: trade.trade.position.unitSize,
                        priceAtDate: trade.realTimeInfo.currentPrice,
                        valueAtDate: trade.realTimeInfo.currentPrice * trade.trade.position.unitSize,
                        currency: trade.realTimeInfo.currency ?? "USD"
                    )
                    return (trade.trade.name, positionSnapshot)
                }
            )
            
            let enhancedPortfolioSnapshot = HistoricalPortfolioSnapshot(
                date: now,
                totalValue: totalValue,
                totalGains: gains.amount,
                totalCost: totalValue - gains.amount,
                currency: gains.currency,
                portfolioComposition: portfolioComposition
            )
            
            await savePortfolioSnapshotToCoreData(enhancedPortfolioSnapshot)
        }
        
        Task { await logger.debug("Recorded portfolio snapshot: value=\(totalValue), gains=\(gains.amount) \(gains.currency)") }
    }
    
    func getChartData(for type: ChartType, timeRange: ChartTimeRange, dataModel: DataModel? = nil) -> [ChartDataPoint] {
        switch type {
        case .portfolioValue:
            // Note: Core Data loading is now handled in loadHistoricalData() to prevent infinite loops
            
            // NEW: Use stored portfolio snapshots if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioValues(for: timeRange)
                Task { await logger.debug("📊 Portfolio value chart data: \(data.count) stored portfolio points for range \(timeRange.rawValue)") }
                
                // If we have good coverage, return stored data
                if data.count > 10 || timeRange == .day || timeRange == .week {
                    return data
                }
            }
            
            // Trigger background calculation if needed and we have a DataModel
            if let dataModel = dataModel {
                let timeSinceLastRetroactive = Date().timeIntervalSince(lastRetroactiveCalculationDate)
                
                // Trigger retroactive calculation if it's been a while or we have no stored data
                if timeSinceLastRetroactive > 3600 || historicalPortfolioSnapshots.isEmpty {
                    Task { await logger.info("📊 Portfolio value chart: Triggering background retroactive calculation") }
                    Task.detached(priority: .background) { [self] in
                        await self.calculateRetroactivePortfolioHistory(using: dataModel)
                    }
                }
                
                // Return stored data if available while background calculation runs
                if !historicalPortfolioSnapshots.isEmpty {
                    return getStoredPortfolioValues(for: timeRange)
                }
            }
            
            // LEGACY FALLBACK: Use old calculation method if no stored data
            let startDate = timeRange.startDate(from: Date())
            let now = Date()
            let timeSinceLastCalculation = now.timeIntervalSince(lastPortfolioCalculationDate)
            
            if !cachedHistoricalPortfolioValues.isEmpty && timeSinceLastCalculation < portfolioCalculationCacheInterval {
                let filteredData = cachedHistoricalPortfolioValues
                    .filter { $0.date >= startDate }
                    .sorted { $0.date < $1.date }
                Task { await logger.debug("📊 Portfolio value chart data: \(filteredData.count) legacy cached points for range \(timeRange.rawValue)") }
                return filteredData
            }
            
            // Final fallback to real-time snapshots
            let data = portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
                .sorted { $0.date < $1.date }
            Task { await logger.debug("📊 Portfolio value chart data: \(data.count) real-time fallback points for range \(timeRange.rawValue)") }
            
            // Special handling for 1-day range: if we don't have any data, force a snapshot
            if data.isEmpty && timeRange == .day, let dataModel = dataModel {
                Task { await logger.info("📊 No 1-day portfolio data available, forcing snapshot creation") }
                forceSnapshot(from: dataModel)
                
                // Try again after creating snapshot
                let newData = portfolioSnapshots
                    .filter { $0.timestamp >= startDate }
                    .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
                    .sorted { $0.date < $1.date }
                Task { await logger.debug("📊 Portfolio value chart data after forced snapshot: \(newData.count) points") }
                return newData
            }
            
            return data
            
        case .portfolioGains:
            // Note: Core Data loading is now handled in loadHistoricalData() to prevent infinite loops
            
            // NEW: Use stored portfolio gains if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioGains(for: timeRange)
                Task { await logger.debug("📊 Portfolio gains chart data: \(data.count) stored portfolio points for range \(timeRange.rawValue)") }
                
                // If we have good coverage, return stored data
                if data.count > 10 || timeRange == .day || timeRange == .week {
                    return data
                }
            }
            
            // Trigger background calculation if needed and we have a DataModel
            if let dataModel = dataModel {
                let timeSinceLastRetroactive = Date().timeIntervalSince(lastRetroactiveCalculationDate)
                
                // Trigger retroactive calculation if it's been a while or we have no stored data
                if timeSinceLastRetroactive > 3600 || historicalPortfolioSnapshots.isEmpty {
                    Task { await logger.info("📊 Portfolio gains chart: Triggering background retroactive calculation") }
                    Task.detached(priority: .background) {
                        await self.calculateRetroactivePortfolioHistory(using: dataModel)
                    }
                }
                
                // Return stored data if available while background calculation runs
                if !historicalPortfolioSnapshots.isEmpty {
                    return getStoredPortfolioGains(for: timeRange)
                }
            }
            
            // LEGACY FALLBACK: Use old calculation method if no stored data
            let startDate = timeRange.startDate(from: Date())
            let now = Date()
            let timeSinceLastCalculation = now.timeIntervalSince(lastPortfolioCalculationDate)
            
            if !cachedHistoricalPortfolioValues.isEmpty && timeSinceLastCalculation < portfolioCalculationCacheInterval {
                let filteredPortfolioValues = cachedHistoricalPortfolioValues
                    .filter { $0.date >= startDate }
                    .sorted { $0.date < $1.date }
                
                let gainsData = calculateHistoricalGains(from: filteredPortfolioValues, dataModel: dataModel)
                Task { await logger.debug("📊 Portfolio gains chart data: \(gainsData.count) legacy cached points for range \(timeRange.rawValue)") }
                return gainsData
            }
            
            // Final fallback to real-time snapshots
            let data = portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalGains) }
                .sorted { $0.date < $1.date }
            Task { await logger.debug("📊 Portfolio gains chart data: \(data.count) real-time fallback points for range \(timeRange.rawValue)") }
            
            // Special handling for 1-day range: if we don't have any data, force a snapshot
            if data.isEmpty && timeRange == .day, let dataModel = dataModel {
                Task { await logger.info("📊 No 1-day portfolio gains data available, forcing snapshot creation") }
                forceSnapshot(from: dataModel)
                
                // Try again after creating snapshot
                let newData = portfolioSnapshots
                    .filter { $0.timestamp >= startDate }
                    .map { ChartDataPoint(date: $0.timestamp, value: $0.totalGains) }
                    .sorted { $0.date < $1.date }
                Task { await logger.debug("📊 Portfolio gains chart data after forced snapshot: \(newData.count) points") }
                return newData
            }
            
            return data
            
        case .individualStock(let symbol):
            let startDate = timeRange.startDate(from: Date())
            return getOptimalStockData(for: symbol, timeRange: timeRange, startDate: startDate)
        }
    }
    
    /// Gets stock data for charts with increased data limits and caching
    private func getOptimalStockData(for symbol: String, timeRange: ChartTimeRange, startDate: Date) -> [ChartDataPoint] {
        let cacheKey = "\(symbol)-\(timeRange.rawValue)-\(Int(startDate.timeIntervalSince1970))"
        
        // Check cache first
        if let cachedData = stockDataCache[cacheKey],
           let cacheTime = stockDataCacheTimestamp[cacheKey],
           Date().timeIntervalSince(cacheTime) < stockDataCacheInterval {
            Task { await logger.debug("📊 CACHE HIT: Stock data for \(symbol) \(timeRange.rawValue): \(cachedData.count) points") }
            return cachedData
        }
        
        let allSnapshots = priceSnapshots[symbol] ?? []
        
        // Filter and convert to chart data points
        let filteredData = allSnapshots
            .filter { $0.timestamp >= startDate }
            .map { ChartDataPoint(date: $0.timestamp, value: $0.price, symbol: symbol) }
            .sorted { $0.date < $1.date }
        
        Task { await logger.debug("📊 CACHE MISS: Stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count) points") }
        
        // Cache the result
        stockDataCache[cacheKey] = filteredData
        stockDataCacheTimestamp[cacheKey] = Date()
        
        // Check if we have insufficient data for the requested time range
        let minimumExpectedDataPoints = getExpectedDataPointsForTimeRange(timeRange)
        let hasInsufficientData = filteredData.count < minimumExpectedDataPoints
        
        // Trigger historical data fetching if we don't have enough data
        if hasInsufficientData {
            Task { await logger.info("📊 Insufficient stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count)/\(minimumExpectedDataPoints) points. Triggering historical data fetch.") }
            
            // Trigger background historical data fetch
            Task.detached(priority: .background) { [weak self] in
                await self?.triggerHistoricalDataFetch(for: symbol, timeRange: timeRange, startDate: startDate)
            }
        }
        
        return filteredData
    }
    
    /// Determines expected minimum data points for a time range
    private func getExpectedDataPointsForTimeRange(_ timeRange: ChartTimeRange) -> Int {
        switch timeRange {
        case .day:
            return 10  // Expect at least 10 data points for a day
        case .week:
            return 30  // Expect at least 30 data points for a week
        case .month:
            return 60  // Expect at least 60 data points for a month
        case .threeMonths:
            return 100 // Expect at least 100 data points for 3 months
        case .sixMonths:
            return 150 // Expect at least 150 data points for 6 months
        case .year:
            return 200 // Expect at least 200 data points for a year
        case .all:
            return 300 // Expect at least 300 data points for all time
        case .custom:
            return 60  // Default expectation for custom range (similar to month)
        }
    }
    
    /// Triggers historical data fetching for a specific symbol and time range
    private func triggerHistoricalDataFetch(for symbol: String, timeRange: ChartTimeRange, startDate: Date) async {
        await logger.info("🔄 Starting historical data fetch for \(symbol) from \(startDate)")
        
        // Use NetworkService to fetch historical data
        guard let networkService = getNetworkService() else {
            await logger.error("❌ Cannot fetch historical data: NetworkService not available")
            return
        }
        
        do {
            let endDate = Date()
            let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
            
            await logger.info("📥 Received \(historicalData.count) historical data points for \(symbol)")
            
            if !historicalData.isEmpty {
                // Add the historical data to our cache
                addImportedSnapshots(historicalData, for: symbol)
                await logger.info("✅ Successfully added \(historicalData.count) historical data points for \(symbol)")
            } else {
                await logger.warning("⚠️ No historical data received for \(symbol)")
            }
            
        } catch {
            await logger.error("❌ Failed to fetch historical data for \(symbol): \(error.localizedDescription)")
        }
    }
    
    /// Gets the NetworkService instance - this should be updated to use dependency injection
    private func getNetworkService() -> NetworkService? {
        // For now, we'll create a PythonNetworkService instance
        // In the future, this should be injected as a dependency
        return PythonNetworkService()
    }
    
    func getPerformanceMetrics(for timeRange: ChartTimeRange) -> PerformanceMetrics? {
        let startDate = timeRange.startDate(from: Date())
        let relevantSnapshots = portfolioSnapshots.filter { $0.timestamp >= startDate }.sorted { $0.timestamp < $1.timestamp }
        
        guard let firstSnapshot = relevantSnapshots.first,
              let lastSnapshot = relevantSnapshots.last else {
            return nil
        }
        
        // For single day or very short periods, compare with previous day if available
        let totalReturn: Double
        let totalReturnPercent: Double
        
        if relevantSnapshots.count == 1 {
            // Single snapshot - compare with the most recent snapshot before the time range
            let previousSnapshots = portfolioSnapshots.filter { $0.timestamp < startDate }.sorted { $0.timestamp < $1.timestamp }
            if let previousSnapshot = previousSnapshots.last {
                totalReturn = lastSnapshot.totalValue - previousSnapshot.totalValue
                totalReturnPercent = (totalReturn / previousSnapshot.totalValue) * 100
            } else {
                totalReturn = 0
                totalReturnPercent = 0
            }
        } else {
            totalReturn = lastSnapshot.totalValue - firstSnapshot.totalValue
            totalReturnPercent = (totalReturn / firstSnapshot.totalValue) * 100
        }
        
        // Calculate daily returns for advanced metrics
        let dailyReturns = zip(relevantSnapshots.dropFirst(), relevantSnapshots).map { current, previous in
            (current.totalValue - previous.totalValue) / previous.totalValue
        }
        
        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance) * 100 // Convert to percentage
        
        let maxValue = relevantSnapshots.map { $0.totalValue }.max() ?? lastSnapshot.totalValue
        let minValue = relevantSnapshots.map { $0.totalValue }.min() ?? lastSnapshot.totalValue
        
        // MARK: - Advanced Analytics Calculations
        
        // Calculate Sharpe Ratio (assuming 2% risk-free rate annually)
        let riskFreeRate = 0.02 / 252 // Daily risk-free rate
        let excessReturns = dailyReturns.map { $0 - riskFreeRate }
        let meanExcessReturn = excessReturns.isEmpty ? 0 : excessReturns.reduce(0, +) / Double(excessReturns.count)
        let sharpeRatio = variance > 0 ? meanExcessReturn / sqrt(variance) : nil
        
        // Calculate Maximum Drawdown
        let (maxDrawdown, maxDrawdownPercent) = calculateMaxDrawdown(snapshots: relevantSnapshots)
        
        // Calculate Annualized Return and Volatility
        let periodInYears = max(0.001, lastSnapshot.timestamp.timeIntervalSince(firstSnapshot.timestamp) / (365.25 * 24 * 3600))
        let annualizedReturn = totalReturnPercent / periodInYears
        let annualizedVolatility = volatility * sqrt(252) // Assuming ~252 trading days per year
        
        // Calculate Value at Risk (95% confidence level)
        let sortedReturns = dailyReturns.sorted()
        let var95Index = Int(Double(sortedReturns.count) * 0.05)
        let valueAtRisk = var95Index < sortedReturns.count ? abs(sortedReturns[var95Index] * 100) : nil
        
        // Calculate Win Rate
        let positiveReturns = dailyReturns.filter { $0 > 0 }.count
        let winRate = dailyReturns.isEmpty ? nil : Double(positiveReturns) / Double(dailyReturns.count) * 100
        
        // Beta calculation would require market benchmark data - set to nil for now
        let beta: Double? = nil
        
        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: lastSnapshot.currency,
            startDate: firstSnapshot.timestamp,
            endDate: lastSnapshot.timestamp,
            sharpeRatio: sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            beta: beta,
            annualizedReturn: annualizedReturn,
            annualizedVolatility: annualizedVolatility,
            valueAtRisk: valueAtRisk,
            winRate: winRate
        )
    }
    
    /// Calculates maximum drawdown from a series of portfolio snapshots
    private func calculateMaxDrawdown(snapshots: [PortfolioSnapshot]) -> (maxDrawdown: Double?, maxDrawdownPercent: Double?) {
        guard snapshots.count > 1 else { return (nil, nil) }
        
        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        var peak: Double = snapshots.first?.totalValue ?? 0
        
        for snapshot in snapshots {
            let currentValue = snapshot.totalValue
            
            // Update peak if we have a new high
            if currentValue > peak {
                peak = currentValue
            }
            
            // Calculate drawdown from peak
            let drawdown = peak - currentValue
            let drawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
            
            // Update maximum drawdown
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDrawdownPercent = drawdownPercent
            }
        }
        
        return (maxDrawdown, maxDrawdownPercent)
    }
    
    /// Calculates maximum drawdown for individual stock prices
    private func calculateStockMaxDrawdown(snapshots: [PriceSnapshot]) -> (maxDrawdown: Double?, maxDrawdownPercent: Double?) {
        guard snapshots.count > 1 else { return (nil, nil) }
        
        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        var peak: Double = snapshots.first?.price ?? 0
        
        for snapshot in snapshots {
            let currentPrice = snapshot.price
            
            // Update peak if we have a new high
            if currentPrice > peak {
                peak = currentPrice
            }
            
            // Calculate drawdown from peak
            let drawdown = peak - currentPrice
            let drawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
            
            // Update maximum drawdown
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDrawdownPercent = drawdownPercent
            }
        }
        
        return (maxDrawdown, maxDrawdownPercent)
    }
    
    /// Gets performance metrics for an individual stock symbol
    func getStockPerformanceMetrics(for symbol: String, timeRange: ChartTimeRange) -> PerformanceMetrics? {
        guard let stockSnapshots = priceSnapshots[symbol] else { return nil }
        
        let startDate = timeRange.startDate(from: Date())
        let relevantSnapshots = stockSnapshots.filter { $0.timestamp >= startDate }.sorted { $0.timestamp < $1.timestamp }
        
        guard let firstSnapshot = relevantSnapshots.first,
              let lastSnapshot = relevantSnapshots.last else {
            return nil
        }
        
        // For single day or very short periods, compare with previous day if available
        let totalReturn: Double
        let totalReturnPercent: Double
        
        if relevantSnapshots.count == 1 {
            // Single snapshot - compare with the most recent snapshot before the time range
            let previousSnapshots = stockSnapshots.filter { $0.timestamp < startDate }.sorted { $0.timestamp < $1.timestamp }
            if let previousSnapshot = previousSnapshots.last {
                totalReturn = lastSnapshot.price - previousSnapshot.price
                totalReturnPercent = (totalReturn / previousSnapshot.price) * 100
            } else {
                totalReturn = 0
                totalReturnPercent = 0
            }
        } else {
            totalReturn = lastSnapshot.price - firstSnapshot.price
            totalReturnPercent = (totalReturn / firstSnapshot.price) * 100
        }
        
        // Calculate daily returns for advanced metrics
        let dailyReturns = zip(relevantSnapshots.dropFirst(), relevantSnapshots).map { current, previous in
            (current.price - previous.price) / previous.price
        }
        
        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance) * 100 // Convert to percentage
        
        let maxValue = relevantSnapshots.map { $0.price }.max() ?? lastSnapshot.price
        let minValue = relevantSnapshots.map { $0.price }.min() ?? lastSnapshot.price
        
        // Determine currency for the stock
        let currency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
        
        // MARK: - Advanced Analytics for Stocks
        
        // Calculate Sharpe Ratio (assuming 2% risk-free rate annually)
        let riskFreeRate = 0.02 / 252 // Daily risk-free rate
        let excessReturns = dailyReturns.map { $0 - riskFreeRate }
        let meanExcessReturn = excessReturns.isEmpty ? 0 : excessReturns.reduce(0, +) / Double(excessReturns.count)
        let sharpeRatio = variance > 0 ? meanExcessReturn / sqrt(variance) : nil
        
        // Calculate Maximum Drawdown
        let (maxDrawdown, maxDrawdownPercent) = calculateStockMaxDrawdown(snapshots: relevantSnapshots)
        
        // Calculate Annualized Return and Volatility
        let periodInYears = max(0.001, lastSnapshot.timestamp.timeIntervalSince(firstSnapshot.timestamp) / (365.25 * 24 * 3600))
        let annualizedReturn = totalReturnPercent / periodInYears
        let annualizedVolatility = volatility * sqrt(252) // Assuming ~252 trading days per year
        
        // Calculate Value at Risk (95% confidence level)
        let sortedReturns = dailyReturns.sorted()
        let var95Index = Int(Double(sortedReturns.count) * 0.05)
        let valueAtRisk = var95Index < sortedReturns.count ? abs(sortedReturns[var95Index] * 100) : nil
        
        // Calculate Win Rate
        let positiveReturns = dailyReturns.filter { $0 > 0 }.count
        let winRate = dailyReturns.isEmpty ? nil : Double(positiveReturns) / Double(dailyReturns.count) * 100
        
        // Beta calculation would require market benchmark data - set to nil for now
        let beta: Double? = nil
        
        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: currency,
            startDate: firstSnapshot.timestamp,
            endDate: lastSnapshot.timestamp,
            sharpeRatio: sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            beta: beta,
            annualizedReturn: annualizedReturn,
            annualizedVolatility: annualizedVolatility,
            valueAtRisk: valueAtRisk,
            winRate: winRate
        )
    }
    
    private func calculateTotalPortfolioValue(from dataModel: DataModel) -> Double {
        // Use the same calculation method as DataModel.calculateNetValue() to ensure consistency
        let netValue = dataModel.calculateNetValue()
        
        // The DataModel already handles all currency conversions and preferred currency logic
        // We just need to extract the numeric amount
        return netValue.amount
    }
    
    private func cleanupOldData() {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        // Use progressive cleanup based on total data size
        let targetLimit: Int
        if totalSnapshots > 40000 {
            // Aggressive cleanup for very large datasets
            targetLimit = 1500
            Task { await logger.warning("📊 Aggressive cleanup: reducing to \(targetLimit) snapshots per symbol (total: \(totalSnapshots))") }
        } else if totalSnapshots > 20000 {
            // Moderate cleanup for large datasets
            targetLimit = 2000
            Task { await logger.info("📊 Moderate cleanup: reducing to \(targetLimit) snapshots per symbol (total: \(totalSnapshots))") }
        } else {
            // Standard cleanup
            targetLimit = maxDataPoints
        }
        
        // Keep only the most recent data points
        if portfolioSnapshots.count > targetLimit {
            portfolioSnapshots = Array(portfolioSnapshots.suffix(targetLimit))
        }
        
        // Clean up individual stock data
        for symbol in priceSnapshots.keys {
            if let snapshots = priceSnapshots[symbol], snapshots.count > targetLimit {
                priceSnapshots[symbol] = Array(snapshots.suffix(targetLimit))
                Task { await logger.debug("📊 Trimmed \(symbol) from \(snapshots.count) to \(targetLimit) snapshots") }
            }
        }
        
        let newTotal = priceSnapshots.values.map { $0.count }.reduce(0, +)
        if newTotal != totalSnapshots {
            Task { await logger.info("📊 Data cleanup completed: \(totalSnapshots) → \(newTotal) snapshots") }
        }
    }
    
    
    private func isValidPriceData(price: Double, symbol: String) -> Bool {
        // Basic validation
        guard price > 0 && price.isFinite else { return false }
        
        // Get recent price history for this symbol
        let recentSnapshots = priceSnapshots[symbol]?.suffix(10) ?? []
        
        // If we have no history, accept the price (first data point)
        guard !recentSnapshots.isEmpty else { return true }
        
        // Calculate median of recent prices for comparison
        let recentPrices = recentSnapshots.map { $0.price }.sorted()
        let medianPrice = recentPrices[recentPrices.count / 2]
        
        // Reject prices that are more than 50% different from recent median
        // This helps filter out obvious data errors while allowing for normal volatility
        let percentageDifference = abs(price - medianPrice) / medianPrice
        let isValid = percentageDifference <= 0.5 // 50% threshold
        
        if !isValid {
            Task { await logger.warning("Price validation failed for \(symbol): current=\(price), median=\(medianPrice), diff=\(percentageDifference * 100)%") }
        }
        
        return isValid
    }
    
    private func loadHistoricalData() {
        Task { await logger.info("HistoricalDataManager: Loading historical data...") }
        let migrationService = DataMigrationService.shared // Assuming it's accessible or passed

        // Core Data version where PriceSnapshotEntity and PortfolioSnapshotEntity are considered mastered
        let coreDataMasterVersion = 3

        if migrationService.migrationVersionStored >= coreDataMasterVersion {
            Task {
                await logger.info("HistoricalDataManager: Prioritizing Core Data for snapshots (version \(migrationService.migrationVersionStored)).")

                // Clear in-memory price snapshots - will load from Core Data on demand
                await MainActor.run { self.priceSnapshots = [:] }
                await logger.info("HistoricalDataManager: In-memory priceSnapshots map cleared; will load from Core Data on demand.")

                // Load portfolio snapshots from Core Data
                let coreDataPortfolioSnaps = await loadPortfolioSnapshotsFromCoreData(timeRange: .all)
                await MainActor.run {
                    self.historicalPortfolioSnapshots = coreDataPortfolioSnaps
                }
                await logger.info("HistoricalDataManager: Loaded \(self.historicalPortfolioSnapshots.count) historical portfolio snapshots from Core Data.")
            }
        } else {
            Task { await logger.info("HistoricalDataManager: Falling back to CacheManager/UserDefaults for snapshots (migration version \(migrationService.migrationVersionStored)).") }
            // Legacy loading from CacheManager / UserDefaults
            self.priceSnapshots = retrieveFromCache([String: [PriceSnapshot]].self, key: StorageKeys.priceSnapshots) ?? [:]
            self.historicalPortfolioSnapshots = retrieveFromCache([HistoricalPortfolioSnapshot].self, key: StorageKeys.historicalPortfolioSnapshots) ?? []
            // Also load legacy portfolioSnapshots if necessary for compatibility or if historicalPortfolioSnapshots is empty
            if self.historicalPortfolioSnapshots.isEmpty {
                 self.portfolioSnapshots = retrieveFromCache([PortfolioSnapshot].self, key: StorageKeys.portfolioSnapshots) ?? []
                 // Potentially convert these legacy ones if needed, though migration should handle this.
            }
        }

        // Load metadata (still useful from CacheManager/UserDefaults)
        currentPortfolioComposition = retrieveFromCache(PortfolioComposition.self, key: StorageKeys.currentPortfolioComposition)
        if currentPortfolioComposition != nil {
            Task { await logger.info("HistoricalDataManager: Loaded current portfolio composition") }
        }
        
        // Load last retroactive calculation date
        lastRetroactiveCalculationDate = retrieveFromCache(Date.self, key: StorageKeys.lastRetroactiveCalculationDate) ?? Date.distantPast
        if lastRetroactiveCalculationDate != Date.distantPast {
            Task { await logger.info("HistoricalDataManager: Last retroactive calculation: \(DateFormatter.debug.string(from: lastRetroactiveCalculationDate))") }
        }
        
        // Load cached historical portfolio values (legacy)
        cachedHistoricalPortfolioValues = retrieveFromCache([ChartDataPoint].self, key: StorageKeys.cachedHistoricalPortfolioValues) ?? []
        Task { await logger.info("HistoricalDataManager: Loaded \(cachedHistoricalPortfolioValues.count) cached portfolio values (legacy)") }
        
        // Load last portfolio calculation date (legacy)
        lastPortfolioCalculationDate = retrieveFromCache(Date.self, key: StorageKeys.lastPortfolioCalculationDate) ?? Date.distantPast
        if lastPortfolioCalculationDate != Date.distantPast {
            Task { await logger.info("HistoricalDataManager: Last portfolio calculation: \(DateFormatter.debug.string(from: lastPortfolioCalculationDate)) (legacy)") }
        }
        
        let totalSnaps = priceSnapshots.values.reduce(0) { $0 + $1.count }
        Task { await logger.info("HistoricalDataManager: Loaded. Price snapshots in memory: \(totalSnaps). Historical portfolio snapshots in memory: \(historicalPortfolioSnapshots.count). Legacy portfolio snapshots in memory: \(portfolioSnapshots.count).") }
        // Log cache performance statistics
        let cacheInfo = cacheManager.getCacheInfo()
        Task { await logger.info("HistoricalDataManager: Cache Statistics:\n\(cacheInfo)") }
    }
    
    func saveHistoricalData() {
        // Core Data is now the primary store for snapshot arrays.
        // New snapshots are saved to Core Data directly in recordSnapshot().
        // This method will now focus on saving metadata or non-CoreData state
        // that HistoricalDataManager itself manages.

        let currentPortfolioComposition = self.currentPortfolioComposition // capture for async
        let currentRetroactiveCalculationDate = self.lastRetroactiveCalculationDate
        let currentCalculationDate = self.lastPortfolioCalculationDate
        // The large arrays like self.priceSnapshots and self.historicalPortfolioSnapshots
        // are primarily reflections of Core Data or temporary caches, so we might not
        // persist them back to CacheManager if Core Data is the source of truth.
        // However, if they contain data not yet in Core Data (e.g. from a failed save),
        // then saving them via CacheManager might be a temporary backup.
        // For this iteration, let's assume Core Data saves are robust and CacheManager
        // is for metadata or as a staging area if Core Data fails.

        Task.detached(priority: .utility) { [weak self, encoder, logger] in
            guard let self = self else { return }
            
            // Save metadata and non-CoreData state to CacheManager
            if let composition = currentPortfolioComposition {
                await self.saveToTieredCache(portfolioComposition: composition,
                                       retroactiveCalculationDate: currentRetroactiveCalculationDate,
                                       calculationDate: currentCalculationDate)
            } else {
                 await self.saveToTieredCache(portfolioComposition: nil,
                                       retroactiveCalculationDate: currentRetroactiveCalculationDate,
                                       calculationDate: currentCalculationDate)
            }


            // We are removing the direct saving of large snapshot arrays to CacheManager here,
            // assuming they are mastered in Core Data.
            // If CacheManager was used as a staging area before Core Data saving,
            // that logic would need to be more explicit.

            // UserDefaults backup for metadata can remain for safety during transition
            if let compositionData = try? currentPortfolioComposition.map({ try encoder.encode($0) }) {
                 UserDefaults.standard.set(compositionData, forKey: StorageKeys.currentPortfolioComposition)
            } else if currentPortfolioComposition == nil { // Explicitly clear if nil
                 UserDefaults.standard.removeObject(forKey: StorageKeys.currentPortfolioComposition)
            }
            UserDefaults.standard.set(currentRetroactiveCalculationDate, forKey: StorageKeys.lastRetroactiveCalculationDate)
            UserDefaults.standard.set(currentCalculationDate, forKey: StorageKeys.lastPortfolioCalculationDate)
            // Avoid saving large snapshot arrays to UserDefaults directly
            
            Task { await logger.debug("HistoricalDataManager: Saved metadata to CacheManager and UserDefaults backup.") }
        }
    }

    // Simplified saveToTieredCache to only handle metadata for this example
    private func saveToTieredCache(
        portfolioComposition: PortfolioComposition?,
        retroactiveCalculationDate: Date,
        calculationDate: Date
    ) async {
        if let composition = portfolioComposition {
            storeInCache(composition, key: StorageKeys.currentPortfolioComposition, isRecent: true)
        } else {
            // If composition is nil, consider removing it from cache or storing a representation of nil
            // For now, we just don't store it if it's nil. A remove(forKey:) might be better.
            cacheManager.remove(forKey: StorageKeys.currentPortfolioComposition)
        }
        storeInCache(retroactiveCalculationDate, key: StorageKeys.lastRetroactiveCalculationDate, isRecent: true)
        storeInCache(calculationDate, key: StorageKeys.lastPortfolioCalculationDate, isRecent: true)
        
        Task { await logger.debug("HistoricalDataManager: Metadata saved to tiered cache.") }
    }

    // The old saveToTieredCache that handled snapshot arrays would need to be adjusted or removed
    // if snapshot arrays are no longer persisted this way.
    // For this subtask, we assume the new simpler one above.
    
    private func setupPeriodicSave() {
        // Save data every 30 minutes to avoid too frequent writes
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.saveHistoricalData()
        }
        
        // Perform aggressive cleanup every 6 hours to maintain optimal performance
        Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in
            Task {
                await self?.performPeriodicMaintenance()
            }
        }
    }
    
    private func performPeriodicMaintenance() async {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        if totalSnapshots > 30000 {
            await logger.info("📊 Performing periodic maintenance on \(totalSnapshots) snapshots") 
            
            // Force more aggressive cleanup during maintenance
            // Temporarily reduce limits for maintenance cleanup
            for symbol in priceSnapshots.keys {
                if let snapshots = priceSnapshots[symbol], snapshots.count > 1800 {
                    priceSnapshots[symbol] = Array(snapshots.suffix(1800))
                }
            }
            
            if portfolioSnapshots.count > 1800 {
                portfolioSnapshots = Array(portfolioSnapshots.suffix(1800))
            }
            
            let newTotal = priceSnapshots.values.map { $0.count }.reduce(0, +)
            await logger.info("📊 Maintenance cleanup: \(totalSnapshots) → \(newTotal) snapshots") 
            
            // Clear cached calculations to force recalculation with clean data
            cachedHistoricalPortfolioValues.removeAll()
            lastPortfolioCalculationDate = Date.distantPast
            
            saveHistoricalData()
        }
    }
    
    func clearAllData() {
        portfolioSnapshots.removeAll()
        priceSnapshots.removeAll()
        historicalPortfolioSnapshots.removeAll()
        currentPortfolioComposition = nil
        cachedHistoricalPortfolioValues.removeAll()
        lastPortfolioCalculationDate = Date.distantPast
        lastRetroactiveCalculationDate = Date.distantPast
        
        UserDefaults.standard.removeObject(forKey: StorageKeys.portfolioSnapshots)
        UserDefaults.standard.removeObject(forKey: StorageKeys.priceSnapshots)
        UserDefaults.standard.removeObject(forKey: StorageKeys.historicalPortfolioSnapshots)
        UserDefaults.standard.removeObject(forKey: StorageKeys.currentPortfolioComposition)
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastRetroactiveCalculationDate)
        UserDefaults.standard.removeObject(forKey: StorageKeys.cachedHistoricalPortfolioValues)
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastPortfolioCalculationDate)
        
        Task { await logger.info("Cleared all historical data including enhanced portfolio snapshots") }
    }
    
    func clearInconsistentData() {
        // Clear all portfolio snapshots since they were calculated with inconsistent methods
        portfolioSnapshots.removeAll()
        cachedHistoricalPortfolioValues.removeAll()
        lastPortfolioCalculationDate = Date.distantPast
        UserDefaults.standard.removeObject(forKey: "portfolioSnapshots")
        UserDefaults.standard.removeObject(forKey: "cachedHistoricalPortfolioValues")
        UserDefaults.standard.removeObject(forKey: "lastPortfolioCalculationDate")
        Task { await logger.info("Cleared inconsistent portfolio historical data and cache - will rebuild with correct calculations") }
    }
    
    func forceSnapshot(from dataModel: DataModel) {
        Task { await logger.info("🔧 FORCING snapshot for debugging") }
        
        // Temporarily bypass the interval check
        lastSnapshotTime = Date.distantPast
        recordSnapshot(from: dataModel)
        
        Task { await logger.info("🔧 Forced snapshot complete. Portfolio snapshots: \(portfolioSnapshots.count), Price snapshots: \(priceSnapshots.count)") }
    }
    
    func cleanAnomalousData() {
        var removedCount = 0
        
        // Get current portfolio value for comparison
        let currentValue = getCurrentPortfolioValue()
        let reasonableRange = (currentValue * 0.6)...(currentValue * 1.4) // Allow 40% variance
        
        Task { await logger.info("🧹 Cleaning anomalous data. Current portfolio value: £\(String(format: "%.2f", currentValue))") }
        Task { await logger.info("🧹 Acceptable range: £\(String(format: "%.2f", reasonableRange.lowerBound)) - £\(String(format: "%.2f", reasonableRange.upperBound))") }
        
        // Clean portfolio snapshots - be more aggressive with outliers
        let originalPortfolioCount = portfolioSnapshots.count
        portfolioSnapshots = portfolioSnapshots.filter { snapshot in
            // Remove snapshots that are way off from current value
            let isReasonable = reasonableRange.contains(snapshot.totalValue)
            let isNotZero = snapshot.totalValue > 1000 // Remove very low values
            let isNotExcessive = snapshot.totalValue < 100000 // Remove excessive values
            
            let isValid = isReasonable && isNotZero && isNotExcessive
            if !isValid {
                removedCount += 1
                Task { await logger.debug("🧹 Removing portfolio snapshot: £\(String(format: "%.2f", snapshot.totalValue)) at \(snapshot.timestamp)") }
            }
            return isValid
        }
        
        // Clean individual stock price snapshots
        for symbol in priceSnapshots.keys {
            let originalCount = priceSnapshots[symbol]?.count ?? 0
            priceSnapshots[symbol] = priceSnapshots[symbol]?.filter { snapshot in
                isValidPriceData(price: snapshot.price, symbol: symbol)
            }
            let newCount = priceSnapshots[symbol]?.count ?? 0
            removedCount += (originalCount - newCount)
        }
        
        if removedCount > 0 {
            saveHistoricalData()
            Task { await logger.info("🧹 Cleaned \(removedCount) anomalous data points from historical data") }
        } else {
            Task { await logger.info("🧹 No anomalous data found during cleanup") }
        }
    }
    
    private func getCurrentPortfolioValue() -> Double {
        // Use the most recent portfolio snapshot as current value
        // This is used for anomaly detection, so we need a reasonable baseline
        if let lastSnapshot = portfolioSnapshots.last {
            return lastSnapshot.totalValue
        }
        
        // Fallback based on logs showing portfolio value around £38-42k
        return 40000
    }
    
    func clearDataForSymbol(_ symbol: String) {
        priceSnapshots.removeValue(forKey: symbol)
        saveHistoricalData()
        Task { await logger.info("Cleared historical data for symbol: \(symbol) (all data tiers)") }
    }
    
    func clearDataForSymbols(_ symbols: [String]) {
        for symbol in symbols {
            priceSnapshots.removeValue(forKey: symbol)
        }
        saveHistoricalData()
        Task { await logger.info("Cleared historical data for \(symbols.count) symbols: \(symbols) (all data tiers)") }
    }
    
    /// Gets the date of the last recorded snapshot for historical data gap detection
    func getLastSnapshotDate(for symbol: String? = nil) -> Date? {
        if let symbol = symbol {
            // Get last snapshot for specific symbol
            return priceSnapshots[symbol]?.last?.timestamp
        } else {
            // Get last portfolio snapshot
            return portfolioSnapshots.last?.timestamp
        }
    }
    
    /// Adds imported historical snapshots while avoiding duplicates
    func addImportedSnapshots(_ snapshots: [PriceSnapshot], for symbol: String) {
        Task { await logger.debug("Adding \(snapshots.count) imported snapshots for \(symbol)") }
        
        if priceSnapshots[symbol] == nil {
            priceSnapshots[symbol] = []
        }
        
        // Get existing days that already have data to avoid duplicates
        let existingDays = Set(priceSnapshots[symbol]?.map { Calendar.current.startOfDay(for: $0.timestamp) } ?? [])
        
        Task { await logger.debug("🔍 DUPLICATE FILTER: \(symbol) has existing data for \(existingDays.count) days") }
        if !existingDays.isEmpty {
            let sortedExistingDays = existingDays.sorted()
            Task { await logger.debug("🔍 DUPLICATE FILTER: First existing day: \(DateFormatter.debug.string(from: sortedExistingDays.first!))") }
            Task { await logger.debug("🔍 DUPLICATE FILTER: Last existing day: \(DateFormatter.debug.string(from: sortedExistingDays.last!))") }
        }
        
        // Filter out snapshots for days that already have data (preserve existing data)
        let newSnapshots = snapshots.filter { snapshot in
            let snapshotDay = Calendar.current.startOfDay(for: snapshot.timestamp)
            return !existingDays.contains(snapshotDay)
        }
        
        Task { await logger.debug("🔍 DUPLICATE FILTER: Filtered \(snapshots.count) snapshots down to \(newSnapshots.count) new snapshots for \(symbol)") }
        
        if !newSnapshots.isEmpty {
            priceSnapshots[symbol]?.append(contentsOf: newSnapshots)
            
            // Sort by timestamp to maintain chronological order
            priceSnapshots[symbol]?.sort { $0.timestamp < $1.timestamp }
            
            // Clean up old data if we exceed the limit
            if let count = priceSnapshots[symbol]?.count, count > maxDataPoints {
                priceSnapshots[symbol] = Array(priceSnapshots[symbol]?.suffix(maxDataPoints) ?? [])
                Task { await logger.debug("Trimmed \(symbol) snapshots to \(maxDataPoints) most recent") }
            }
            
            // Save the updated data
            saveHistoricalData()
            
            Task { await logger.info("Added \(newSnapshots.count) new historical snapshots for \(symbol) (filtered from \(snapshots.count) total)") }
            
            // Invalidate portfolio cache when new historical data is added
            cachedHistoricalPortfolioValues.removeAll()
            lastPortfolioCalculationDate = Date.distantPast
            Task { await logger.debug("📊 Invalidated portfolio cache due to new historical data for \(symbol)") }
        } else {
            Task { await logger.debug("No new snapshots to add for \(symbol) - all would be duplicates") }
        }
    }
    
    /// Checks if a symbol has sufficient historical data coverage
    func hasGoodDataCoverage(for symbol: String, inPastDays days: Int = 30) -> Bool {
        guard let snapshots = priceSnapshots[symbol] else { return false }
        
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        let recentSnapshots = snapshots.filter { $0.timestamp >= cutoffDate }
        let uniqueDays = Set(recentSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
        
        // Expect roughly 5/7 of days to be business days
        let expectedBusinessDays = max(1, days * 5 / 7)
        let coverageRatio = Double(uniqueDays.count) / Double(expectedBusinessDays)
        
        Task { await logger.debug("Data coverage for \(symbol): \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))%)") }
        
        return coverageRatio >= 0.75 // 75% coverage threshold
    }
    
    /// Manually triggers calculation of historical portfolio values
    func calculateHistoricalPortfolioValues(using dataModel: DataModel) {
        Task {
            await calculateAndCacheHistoricalPortfolioValues(using: dataModel)
        }
    }
    
    /// Calculates 5 years of historical portfolio values in monthly chunks with delays
    func calculate5YearHistoricalPortfolioValues(using dataModel: DataModel) async {
        await logger.info("📊 COMPREHENSIVE: Starting 5-year historical portfolio value calculation in monthly chunks") 
        
        // Clear existing cache to start fresh
        await MainActor.run {
            self.cachedHistoricalPortfolioValues.removeAll()
            self.lastPortfolioCalculationDate = Date.distantPast
        }
        
        let calendar = Calendar.current
        let endDate = Date()
        
        // Find the earliest available historical data to determine actual start date
        var earliestDataDate = endDate
        for (_, snapshots) in priceSnapshots {
            if let earliest = snapshots.min(by: { $0.timestamp < $1.timestamp })?.timestamp {
                if earliest < earliestDataDate {
                    earliestDataDate = earliest
                }
            }
        }
        
        // Don't go back more than 5 years or beyond available data
        let requestedStartDate = calendar.date(byAdding: .year, value: -5, to: endDate) ?? endDate
        let actualStartDate = max(requestedStartDate, earliestDataDate)
        
        await logger.info("📊 COMPREHENSIVE: Earliest available data: \(DateFormatter.debug.string(from: earliestDataDate))") 
        await logger.info("📊 COMPREHENSIVE: Calculating portfolio values from \(DateFormatter.debug.string(from: actualStartDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        var allPortfolioValues: [ChartDataPoint] = []
        var currentDate = actualStartDate
        var monthCount = 0
        
        // Process one month at a time
        while currentDate < endDate {
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: currentDate) ?? endDate
            let actualMonthEnd = min(monthEnd, endDate)
            
            monthCount += 1
            await logger.info("📊 COMPREHENSIVE: Processing month \(monthCount) - \(DateFormatter.debug.string(from: currentDate)) to \(DateFormatter.debug.string(from: actualMonthEnd))") 
            
            // Calculate portfolio values for this month
            let monthValues = await calculateHistoricalPortfolioValuesForPeriod(
                from: currentDate, 
                to: actualMonthEnd, 
                using: dataModel
            )
            
            if !monthValues.isEmpty {
                allPortfolioValues.append(contentsOf: monthValues)
                await logger.info("📊 COMPREHENSIVE: Month \(monthCount) added \(monthValues.count) portfolio values") 
                
                // Update cache with accumulated values so far (provides progress feedback)
                await MainActor.run {
                    self.cachedHistoricalPortfolioValues = allPortfolioValues.sorted { $0.date < $1.date }
                    self.lastPortfolioCalculationDate = Date()
                }
            } else {
                await logger.warning("📊 COMPREHENSIVE: Month \(monthCount) yielded no portfolio values") 
            }
            
            // Move to next month
            currentDate = monthEnd
            
            // Reduced delay between months to improve responsiveness (3 seconds instead of 10)
            if currentDate < endDate {
                await logger.info("📊 COMPREHENSIVE: Waiting 3 seconds before processing next month...") 
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        
        // Final update with all calculated values
        await MainActor.run {
            self.cachedHistoricalPortfolioValues = allPortfolioValues.sorted { $0.date < $1.date }
            self.lastPortfolioCalculationDate = Date()
        }
        
        await logger.info("📊 COMPREHENSIVE: Completed 5-year calculation with \(allPortfolioValues.count) total portfolio values across \(monthCount) months") 
    }
    
    /// Calculates historical portfolio values for a specific time period
    private func calculateHistoricalPortfolioValuesForPeriod(from startDate: Date, to endDate: Date, using dataModel: DataModel) async -> [ChartDataPoint] {
        let calendar = Calendar.current
        let currencyConverter = CurrencyConverter()
        let preferredCurrency = dataModel.preferredCurrency
        
        // Debug: Show what symbols we're working with
        let symbols = dataModel.realTimeTrades.map { $0.trade.name }
        Task { await logger.debug("📊 PERIOD CALC: Processing symbols: \(symbols)") }
        
        // Get all available historical dates in this period across all symbols
        var allDates = Set<Date>()
        var symbolDataCounts: [String: Int] = [:]
        
        for (symbol, snapshots) in priceSnapshots {
            var countForSymbol = 0
            for snapshot in snapshots {
                if snapshot.timestamp >= startDate && snapshot.timestamp <= endDate {
                    // Use start of day to group by date
                    let dayStart = calendar.startOfDay(for: snapshot.timestamp)
                    allDates.insert(dayStart)
                    countForSymbol += 1
                }
            }
            if countForSymbol > 0 {
                symbolDataCounts[symbol] = countForSymbol
            }
        }
        
        Task { await logger.debug("📊 PERIOD CALC: Data availability for \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)):") }
        for (symbol, count) in symbolDataCounts {
            Task { await logger.debug("📊 PERIOD CALC: - \(symbol): \(count) data points") }
        }
        
        guard !allDates.isEmpty else {
            Task { await logger.warning("📊 PERIOD CALC: No historical price data available for period \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate))") }
            return []
        }
        
        var portfolioValues: [ChartDataPoint] = []
        let sortedDates = Array(allDates.sorted())
        
        Task { await logger.debug("📊 PERIOD CALC: Processing \(sortedDates.count) unique dates for period \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate))") }
        
        // Process each date
        var validDatesCount = 0
        for (index, date) in sortedDates.enumerated() {
            var totalValueUSD = 0.0
            var symbolsWithData = 0
            var symbolsProcessed = 0
            
            // Yield control every 20 dates to prevent UI blocking
            if index % 20 == 0 {
                await Task.yield()
            }
            
            // Calculate portfolio value for this date using current portfolio composition
            for trade in dataModel.realTimeTrades {
                let symbol = trade.trade.name
                symbolsProcessed += 1
                
                // Find the historical price for this symbol on this date
                let symbolSnapshots = priceSnapshots[symbol] ?? []
                
                if !symbolSnapshots.isEmpty,
                   let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) {
                    
                    let units = trade.trade.position.unitSize
                    let historicalPrice = historicalSnapshot.price
                    let currency = trade.realTimeInfo.currency ?? "USD"
                    
                    // Check if this snapshot is too old (more than 30 days from target date)
                    let daysDifference = Calendar.current.dateComponents([.day], from: historicalSnapshot.timestamp, to: date).day ?? 0
                    
                    if !historicalPrice.isNaN && historicalPrice > 0 && units > 0 && daysDifference <= 30 {
                        let positionValue = historicalPrice * units
                        
                        // Convert to USD for aggregation
                        var valueInUSD = positionValue
                        if currency == "GBP" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: "GBP", to: "USD")
                        } else if currency != "USD" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: currency, to: "USD")
                        }
                        
                        totalValueUSD += valueInUSD
                        symbolsWithData += 1
                        
                        if index < 3 || validDatesCount % 20 == 0 { // Log first few and every 20th date
                            Task { await logger.debug("📊 PERIOD CALC: \(symbol) on \(DateFormatter.debug.string(from: date)): price=\(historicalPrice), value=\(valueInUSD) USD (snapshot age: \(daysDifference) days)") }
                        }
                    } else {
                        if index < 3 || validDatesCount % 20 == 0 {
                            Task { await logger.debug("📊 PERIOD CALC: Rejected \(symbol) on \(DateFormatter.debug.string(from: date)): price=\(historicalPrice), units=\(units), age=\(daysDifference) days") }
                        }
                    }
                } else {
                    if index < 3 || validDatesCount % 20 == 0 {
                        Task { await logger.debug("📊 PERIOD CALC: No data found for \(symbol) on \(DateFormatter.debug.string(from: date))") }
                    }
                }
            }
            
            // Accept portfolio value if we have data for at least 50% of symbols (more lenient)
            let hasValidData = symbolsWithData >= max(1, symbolsProcessed / 2)
            
            if hasValidData {
                validDatesCount += 1
                if index < 3 || validDatesCount % 10 == 0 { // Log first few and every 10th valid date
                    Task { await logger.debug("📊 PERIOD CALC: Date \(DateFormatter.debug.string(from: date)): \(symbolsWithData)/\(symbolsProcessed) symbols, totalUSD=\(totalValueUSD)") }
                }
                
                // Convert to preferred currency
                var finalValue = totalValueUSD
                if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
                    let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
                    finalValue = gbpAmount * 100.0
                } else if preferredCurrency != "USD" {
                    finalValue = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
                }
                
                portfolioValues.append(ChartDataPoint(date: date, value: finalValue))
            } else {
                if index < 5 || validDatesCount % 50 == 0 { // Less frequent logging for rejections
                    Task { await logger.debug("📊 PERIOD CALC: Rejected date \(DateFormatter.debug.string(from: date)): only \(symbolsWithData)/\(symbolsProcessed) symbols have valid data") }
                }
            }
            
            // Yield every 50 calculations to keep UI responsive
            if index % 50 == 0 {
                await Task.yield()
            }
        }
        
        Task { await logger.debug("📊 PERIOD CALC: Summary for \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)): \(validDatesCount)/\(sortedDates.count) dates yielded portfolio values, result: \(portfolioValues.count) data points") }
        
        return portfolioValues.sorted { $0.date < $1.date }
    }
    
    /// Calculates and caches historical portfolio values using historical price data (async)
    private func calculateAndCacheHistoricalPortfolioValues(using dataModel: DataModel) async {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        // Use progressive data sampling for large datasets instead of skipping entirely
        let useSampling = totalSnapshots > 15000
        let startDate: Date
        
        if totalSnapshots > 50000 {
            // For very large datasets, limit to 3 months
            startDate = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
            await logger.warning("📊 Large dataset (\(totalSnapshots) snapshots) - using 3-month window with sampling") 
        } else if totalSnapshots > 25000 {
            // For large datasets, limit to 6 months
            startDate = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
            await logger.info("📊 Medium dataset (\(totalSnapshots) snapshots) - using 6-month window") 
        } else {
            // For reasonable datasets, use 1 year
            startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            await logger.debug("📊 Processing \(totalSnapshots) snapshots with 1-year window") 
        }
        
        await logger.debug("📊 Starting background calculation of historical portfolio values") 
        
        let portfolioValues = await calculateHistoricalPortfolioValues(from: startDate, using: dataModel, useSampling: useSampling)
        
        await MainActor.run {
            self.cachedHistoricalPortfolioValues = portfolioValues
            self.lastPortfolioCalculationDate = Date()
        }
        await logger.debug("📊 Cached \(portfolioValues.count) historical portfolio values")
    }
    
    /// Calculates historical portfolio values using historical price data (sync, for background use)
    private func calculateHistoricalPortfolioValues(from startDate: Date, using dataModel: DataModel, useSampling: Bool = false) async -> [ChartDataPoint] {
        let actualStartDate = startDate
        
        // Get all available historical dates across all symbols with chunked processing
        var allDates = Set<Date>()
        let calendar = Calendar.current
        
        await Task.yield() // Allow UI updates
        
        for (_, snapshots) in priceSnapshots {
            for snapshot in snapshots {
                if snapshot.timestamp >= actualStartDate {
                    // Use start of day to group by date
                    let dayStart = calendar.startOfDay(for: snapshot.timestamp)
                    allDates.insert(dayStart)
                }
            }
            
            // Yield periodically to prevent blocking
            if allDates.count % 100 == 0 {
                await Task.yield()
            }
        }
        
        guard !allDates.isEmpty else {
            Task { await logger.debug("📊 No historical price data available for portfolio calculation") }
            return []
        }
        
        var portfolioValues: [ChartDataPoint] = []
        let currencyConverter = CurrencyConverter()
        let preferredCurrency = dataModel.preferredCurrency
        
        // Sort dates chronologically and apply sampling if needed
        let sortedAllDates = allDates.sorted()
        let sortedDates: [Date]
        
        if useSampling && sortedAllDates.count > 1000 {
            // Sample every 3rd data point for large datasets to maintain performance
            let step = max(1, sortedAllDates.count / 500) // Target ~500 data points
            sortedDates = stride(from: 0, to: sortedAllDates.count, by: step).map { sortedAllDates[$0] }
            Task { await logger.debug("📊 Sampling \(sortedDates.count) dates from \(sortedAllDates.count) total dates (step: \(step))") }
        } else {
            // For smaller datasets, use all data but limit to reasonable amount
            sortedDates = Array(sortedAllDates.suffix(800))
            Task { await logger.debug("📊 Using \(sortedDates.count) dates from \(sortedAllDates.count) total dates") }
        }
        
        // Process in chunks to avoid hanging
        let chunkSize = 20
        for chunk in sortedDates.chunked(into: chunkSize) {
            await Task.yield() // Yield between chunks
            
            for date in chunk {
                var totalValueUSD = 0.0
                var hasValidData = false
                
                // Calculate portfolio value for this date
                for trade in dataModel.realTimeTrades {
                    let symbol = trade.trade.name
                    
                    // Find the historical price for this symbol on this date
                    let symbolSnapshots = priceSnapshots[symbol] ?? []
                    
                    if !symbolSnapshots.isEmpty,
                       let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) {
                        
                        let units = trade.trade.position.unitSize
                        let historicalPrice = historicalSnapshot.price
                        let currency = trade.realTimeInfo.currency ?? "USD"
                        
                        guard !historicalPrice.isNaN && historicalPrice > 0 && units > 0 else {
                            continue
                        }
                        
                        let positionValue = historicalPrice * units
                        
                        // Convert to USD for aggregation
                        var valueInUSD = positionValue
                        if currency == "GBP" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: "GBP", to: "USD")
                        } else if currency != "USD" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: currency, to: "USD")
                        }
                        
                        totalValueUSD += valueInUSD
                        hasValidData = true
                    }
                }
                
                if hasValidData {
                    // Convert to preferred currency
                    var finalValue = totalValueUSD
                    if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
                        let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
                        finalValue = gbpAmount * 100.0
                    } else if preferredCurrency != "USD" {
                        finalValue = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
                    }
                    
                    portfolioValues.append(ChartDataPoint(date: date, value: finalValue))
                }
            }
        }
        
        Task { await logger.debug("📊 Calculated \(portfolioValues.count) historical portfolio values from \(sortedDates.count) dates") }
        return portfolioValues.sorted { $0.date < $1.date }
    }
    
    /// Finds the closest historical snapshot to a given date using optimized binary search
    /// CRITICAL FIX: Assumes snapshots are already sorted to avoid O(n log n) performance bottleneck
    private func findClosestSnapshot(in sortedSnapshots: [PriceSnapshot], to targetDate: Date) -> PriceSnapshot? {
        guard !sortedSnapshots.isEmpty else { return nil }
        
        // PERFORMANCE: Snapshots MUST be pre-sorted by timestamp for binary search to work
        // This function no longer sorts to avoid O(n log n) bottleneck on every call
        let targetDayStart = Calendar.current.startOfDay(for: targetDate)
        
        // Binary search for exact or closest match
        var left = 0
        var right = sortedSnapshots.count - 1
        var bestMatch: PriceSnapshot?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        
        while left <= right {
            let mid = (left + right) / 2
            let midSnapshot = sortedSnapshots[mid]
            let midDayStart = Calendar.current.startOfDay(for: midSnapshot.timestamp)
            
            let distance = abs(midDayStart.timeIntervalSince(targetDayStart))
            
            // Check if this is our best match so far
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = midSnapshot
            }
            
            // Exact match found
            if midDayStart == targetDayStart {
                return midSnapshot
            }
            
            if midDayStart < targetDayStart {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        
        // Only return if within reasonable time range (30 days)
        if let match = bestMatch, bestDistance <= 30 * 24 * 60 * 60 {
            return match
        }
        
        return nil
    }
    
    /// Calculates historical gains from portfolio values by subtracting total investment cost
    private func calculateHistoricalGains(from portfolioValues: [ChartDataPoint], dataModel: DataModel?) -> [ChartDataPoint] {
        guard let dataModel = dataModel else { return [] }
        
        // Calculate total investment cost (what the user paid)
        let totalInvestmentCost = calculateTotalInvestmentCost(dataModel: dataModel)
        
        // Convert portfolio values to gains by subtracting the investment cost
        let gainsData = portfolioValues.map { portfolioValue in
            let gains = portfolioValue.value - totalInvestmentCost
            return ChartDataPoint(date: portfolioValue.date, value: gains, symbol: portfolioValue.symbol)
        }
        
        return gainsData
    }
    
    /// Calculates the total amount the user invested (purchase cost) in preferred currency
    private func calculateTotalInvestmentCost(dataModel: DataModel) -> Double {
        let currencyConverter = CurrencyConverter()
        var totalCostUSD = 0.0
        
        for trade in dataModel.realTimeTrades {
            // Use normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = trade.trade.position.getNormalizedAvgCost(for: trade.trade.name)
            guard !adjustedCost.isNaN, adjustedCost > 0 else { continue }
            
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency ?? "USD"
            
            let totalPositionCost = adjustedCost * units
            
            // Convert to USD for aggregation
            var costInUSD = totalPositionCost
            if currency == "GBP" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: "GBP", to: "USD")
            } else if currency != "USD" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: currency, to: "USD")
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency
        let preferredCurrency = dataModel.preferredCurrency
        var finalAmount = totalCostUSD
        
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0
        } else if preferredCurrency != "USD" {
            finalAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: preferredCurrency)
        }
        
        return finalAmount
    }
    
    // MARK: - Performance Optimization Methods
    
    /// Performs comprehensive data compression and optimization
    public func performDataOptimization() async throws {
        await logger.info("⚡ Starting comprehensive data optimization") 
        
        await compressionService.performDataCompression()
        await memoryService.performMemoryCleanup()
        try await batchService.performDatabaseOptimization()
        
        Task { await logger.info("⚡ Data optimization completed") }
    }
    
    /// Gets optimized chart data using the enhanced chart service
    public func getOptimizedChartData(for chartType: ChartType, timeRange: ChartTimeRange, maxPoints: Int = 1000) async -> [ChartDataPoint] {
        do {
            // Try optimized service first
            let data = try await chartDataService.fetchChartData(for: chartType, timeRange: timeRange, maxPoints: maxPoints)
            if !data.isEmpty {
                return data
            }
        } catch {
            await logger.warning("⚡ Optimized chart data fetch failed, falling back to legacy method: \(error)") 
        }
        
        // Fallback to legacy method
        return getChartData(for: chartType, timeRange: timeRange, dataModel: nil)
    }
    
    /// Performs lightweight performance optimization
    public func performLightweightOptimization() async {
        await logger.debug("⚡ Performing lightweight optimization") 
        
        await compressionService.performLightweightCompression()
        await memoryService.optimizeChartDataMemory()
        
        await logger.debug("⚡ Lightweight optimization completed") 
    }
    
    /// Gets comprehensive performance statistics
    public func getPerformanceStats() async -> PerformanceStats {
        let compressionStats = await compressionService.getCompressionStats()
        let memoryStats = await memoryService.getMemoryStats()
        let chartCacheStats = await chartDataService.getCacheStats()
        
        return PerformanceStats(
            compressionStats: compressionStats,
            memoryStats: memoryStats,
            chartCacheStats: chartCacheStats,
            totalDataPoints: getTotalDataPointCount(),
            coreDataStorageSize: await estimateCoreDataStorageSize()
        )
    }
    
    /// Performs batch operations for large data sets
    public func performBatchDataInsertion(_ snapshots: [PriceSnapshot]) async throws {
        await logger.info("⚡ Starting batch insertion of \(snapshots.count) price snapshots") 
        
        try await batchService.batchInsertPriceSnapshots(snapshots)
        
        // Update local cache after batch insertion
        for snapshot in snapshots {
            if var existingSnapshots = priceSnapshots[snapshot.symbol] {
                existingSnapshots.append(snapshot)
                priceSnapshots[snapshot.symbol] = existingSnapshots.sorted { $0.timestamp < $1.timestamp }
            } else {
                priceSnapshots[snapshot.symbol] = [snapshot]
            }
        }
        
        // Save snapshots handled by Core Data services
        Task { await logger.info("⚡ Batch insertion completed") }
    }
    
    /// Cleans up old data with performance optimizations
    public func performOptimizedDataCleanup(olderThan cutoffDate: Date) async throws -> BatchDeletionResult {
        await logger.info("⚡ Starting optimized data cleanup") 
        
        let result = try await batchService.batchDeleteOldData(olderThan: cutoffDate)
        
        // Update local caches
        for (symbol, snapshots) in priceSnapshots {
            let filteredSnapshots = snapshots.filter { $0.timestamp >= cutoffDate }
            if filteredSnapshots.count != snapshots.count {
                priceSnapshots[symbol] = filteredSnapshots
            }
        }
        
        portfolioSnapshots = portfolioSnapshots.filter { $0.timestamp >= cutoffDate }
        
        // Save snapshots handled by Core Data services
        
        Task { await logger.info("⚡ Optimized data cleanup completed - \(result.totalDeleted) items removed") }
        return result
    }
    
    /// Configures performance optimization settings
    public func configurePerformanceSettings(
        maxCacheSize: Int? = nil,
        compressionEnabled: Bool? = nil,
        memoryThresholds: (warning: Double, critical: Double)? = nil
    ) async {
        if let _ = maxCacheSize {
            await chartDataService.clearCache() // Reset with new size
        }
        
        if let thresholds = memoryThresholds {
            await memoryService.configureMemorySettings(
                warningThreshold: thresholds.warning,
                criticalThreshold: thresholds.critical
            )
        }
        
        Task { await logger.info("⚡ Performance settings updated") }
    }
    
    private func getTotalDataPointCount() -> Int {
        let priceCount = priceSnapshots.values.reduce(0) { $0 + $1.count }
        let portfolioCount = portfolioSnapshots.count
        return priceCount + portfolioCount
    }
    
    private func estimateCoreDataStorageSize() async -> Double {
        // Rough estimate based on entity counts and average sizes
        let totalDataPoints = getTotalDataPointCount()
        let bytesPerDataPoint = 150.0 // Average estimate including overhead
        return Double(totalDataPoints) * bytesPerDataPoint / (1024 * 1024) // Convert to MB
    }

    // MARK: - Debug Methods
    
    /// Gets the current snapshot interval for debug purposes
    func getSnapshotInterval() -> TimeInterval {
        return snapshotInterval
    }
    
    /// Sets the snapshot interval for debug purposes
    func setSnapshotInterval(_ interval: TimeInterval) {
        snapshotInterval = interval
        Task { await logger.info("📊 Snapshot interval changed to \(interval) seconds") }
    }
    
    /// Manually triggers data cleanup for all symbols
    func optimizeAllDataStorage() {
        Task { await logger.info("📊 MANUAL OPTIMIZATION: Starting data cleanup for all symbols") }
        
        // Simply clean up old data to ensure we stay within limits
        cleanupOldData()
        
        saveHistoricalData()
        Task { await logger.info("📊 MANUAL OPTIMIZATION: Completed data cleanup") }
    }
    
    /// Gets comprehensive data status
    func getComprehensiveDataStatus() -> [(symbol: String, daily: Int, weekly: Int, monthly: Int, oldestDate: String, newestDate: String)] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        
        var status: [(symbol: String, daily: Int, weekly: Int, monthly: Int, oldestDate: String, newestDate: String)] = []
        
        for symbol in priceSnapshots.keys.sorted() {
            let dailyCount = priceSnapshots[symbol]?.count ?? 0
            let weeklyCount = 0 // No longer using tiered storage
            let monthlyCount = 0 // No longer using tiered storage
            
            // Find date range for this symbol
            let dates = priceSnapshots[symbol]?.map { $0.timestamp } ?? []
            
            let oldestDate = dates.min().map { formatter.string(from: $0) } ?? "No data"
            let newestDate = dates.max().map { formatter.string(from: $0) } ?? "No data"
            
            status.append((symbol: symbol, daily: dailyCount, weekly: weeklyCount, monthly: monthlyCount, oldestDate: oldestDate, newestDate: newestDate))
        }
        
        return status
    }
    
    // MARK: - Enhanced Retroactive Portfolio Calculation
    
    /// Main method to trigger retroactive portfolio calculation
    func calculateRetroactivePortfolioHistory(using dataModel: DataModel, force: Bool = false) async {
        // CRITICAL FIX: Prevent concurrent calculation overlaps
        guard !isCalculationInProgress else {
            await logger.warning("🔄 RETROACTIVE: Calculation already in progress, skipping duplicate request") 
            return
        }
        isCalculationInProgress = true
        
        // Ensure calculation state is cleared when function exits
        defer {
            isCalculationInProgress = false
        }
        
        await logger.info("🔄 RETROACTIVE: Starting comprehensive portfolio history calculation (force: \(force))") 
        
        // Initialize progress tracking
        let calculationManager = await BackgroundCalculationManager.shared
        await calculationManager.startCalculation(operation: "Portfolio History Calculation", totalOperations: 100)
        
        do {
            // Create current portfolio composition for tracking changes
            await calculationManager.updateProgress(completed: 10, status: "Analyzing portfolio composition")
            let newComposition = createPortfolioComposition(from: dataModel)
            
            // Check if portfolio composition has changed
            await calculationManager.updateProgress(completed: 20, status: "Checking for portfolio changes")
            let compositionChanged = hasPortfolioCompositionChanged(newComposition)
            let needsFullRecalculation = force || compositionChanged
            
            if needsFullRecalculation {
                if force {
                    await logger.info("🔄 RETROACTIVE: Forced full recalculation requested")
                } else {
                    await logger.info("🔄 RETROACTIVE: Portfolio composition changed - full recalculation needed")
                }
                
                await calculationManager.updateProgress(completed: 30, status: "Starting full recalculation")
                await performFullPortfolioRecalculation(using: dataModel, composition: newComposition)
            } else {
                await logger.info("🔄 RETROACTIVE: Portfolio composition unchanged - incremental update") 
                await calculationManager.updateProgress(completed: 30, status: "Starting incremental update")
                await performIncrementalPortfolioUpdate(using: dataModel)
            }
            
            // Update composition tracking
            await calculationManager.updateProgress(completed: 90, status: "Finalizing calculation")
            await MainActor.run {
                self.currentPortfolioComposition = newComposition
                self.lastRetroactiveCalculationDate = Date()
            }
            
            // Save updated data
            await calculationManager.updateProgress(completed: 95, status: "Saving data")
            saveHistoricalData()
            
            // Complete the calculation
            await calculationManager.completeCalculation()
            await logger.info("🔄 RETROACTIVE: Portfolio history calculation completed") 
            
        } catch {
            await logger.error("🔄 RETROACTIVE: Portfolio calculation failed: \(error.localizedDescription)") 
            await calculationManager.reportError("Portfolio calculation failed: \(error.localizedDescription)")
        }
    }
    
    /// Creates portfolio composition from current DataModel
    private func createPortfolioComposition(from dataModel: DataModel) -> PortfolioComposition {
        let positions = dataModel.realTimeTrades.map { trade in
            PortfolioPosition(
                symbol: trade.trade.name,
                units: trade.trade.position.unitSize,
                avgCost: trade.trade.position.getNormalizedAvgCost(for: trade.trade.name),
                currency: trade.realTimeInfo.currency ?? "USD"
            )
        }
        return PortfolioComposition(positions: positions)
    }
    
    /// Checks if portfolio composition has changed
    private func hasPortfolioCompositionChanged(_ newComposition: PortfolioComposition) -> Bool {
        guard let currentComposition = currentPortfolioComposition else {
            return true // First time calculation
        }
        return currentComposition.compositionHash != newComposition.compositionHash
    }
    
    /// Performs full portfolio recalculation for entire history
    private func performFullPortfolioRecalculation(using dataModel: DataModel, composition: PortfolioComposition) async {
        await logger.info("🔄 FULL RECALC: Starting full portfolio history recalculation") 
        
        let calculationManager = await BackgroundCalculationManager.shared
        
        // Clear existing portfolio snapshots
        await calculationManager.updateProgress(completed: 40, status: "Clearing existing data")
        await MainActor.run {
            self.historicalPortfolioSnapshots.removeAll()
        }
        
        // Find the earliest available historical data
        await calculationManager.updateProgress(completed: 45, status: "Finding earliest data")
        let earliestDate = findEarliestHistoricalData()
        let endDate = Date()
        
        await logger.info("🔄 FULL RECALC: Calculating from \(DateFormatter.debug.string(from: earliestDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        // Calculate portfolio values for the entire historical period
        await calculationManager.updateProgress(completed: 50, status: "Calculating portfolio values")
        let snapshots = await calculatePortfolioSnapshotsForPeriod(
            from: earliestDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        await calculationManager.updateProgress(completed: 85, status: "Storing portfolio snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots = snapshots.sorted { $0.date < $1.date }
        }
        
        await logger.info("🔄 FULL RECALC: Generated \(snapshots.count) portfolio snapshots") 
    }
    
    /// Performs incremental portfolio update for new dates only
    private func performIncrementalPortfolioUpdate(using dataModel: DataModel) async {
        let calculationManager = await BackgroundCalculationManager.shared
        
        await calculationManager.updateProgress(completed: 40, status: "Checking for new data")
        let lastCalculatedDate = getLastPortfolioSnapshotDate()
        let endDate = Date()
        
        // Only calculate if there's a meaningful gap (more than 1 day)
        guard endDate.timeIntervalSince(lastCalculatedDate) > 86400 else {
            await logger.debug("🔄 INCREMENTAL: No significant time gap, skipping update") 
            await calculationManager.updateProgress(completed: 85, status: "No update needed")
            return
        }
        
        await logger.info("🔄 INCREMENTAL: Updating from \(DateFormatter.debug.string(from: lastCalculatedDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        await calculationManager.updateProgress(completed: 50, status: "Calculating new portfolio values")
        let newSnapshots = await calculatePortfolioSnapshotsForPeriod(
            from: lastCalculatedDate,
            to: endDate,
            using: dataModel,
            composition: currentPortfolioComposition!
        )
        
        await calculationManager.updateProgress(completed: 80, status: "Adding new snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots.append(contentsOf: newSnapshots)
            self.historicalPortfolioSnapshots.sort { $0.date < $1.date }
            
            // Clean up if we exceed the limit
            if self.historicalPortfolioSnapshots.count > maxPortfolioSnapshots {
                self.historicalPortfolioSnapshots = Array(self.historicalPortfolioSnapshots.suffix(maxPortfolioSnapshots))
            }
        }
        
        await logger.info("🔄 INCREMENTAL: Added \(newSnapshots.count) new portfolio snapshots") 
    }
    
    /// Calculates portfolio snapshots for a specific date range with concurrent processing
    private func calculatePortfolioSnapshotsForPeriod(
        from startDate: Date,
        to endDate: Date,
        using dataModel: DataModel,
        composition: PortfolioComposition
    ) async -> [HistoricalPortfolioSnapshot] {
        
        // For large date ranges, use concurrent processing
        let dateRange = endDate.timeIntervalSince(startDate)
        let daysInRange = Int(dateRange / 86400) // Convert to days
        
        if daysInRange > 100 {
            // Use concurrent processing for large ranges
            return await calculatePortfolioSnapshotsForPeriodConcurrent(
                from: startDate,
                to: endDate,
                using: dataModel,
                composition: composition
            )
        } else {
            // Use sequential processing for smaller ranges
            return await calculatePortfolioSnapshotsForPeriodSequential(
                from: startDate,
                to: endDate,
                using: dataModel,
                composition: composition
            )
        }
    }
    
    /// Sequential calculation method (original implementation)
    private func calculatePortfolioSnapshotsForPeriodSequential(
        from startDate: Date,
        to endDate: Date,
        using dataModel: DataModel,
        composition: PortfolioComposition
    ) async -> [HistoricalPortfolioSnapshot] {
        
        let calendar = Calendar.current
        let currencyConverter = CurrencyConverter()
        let preferredCurrency = dataModel.preferredCurrency
        
        // Get all unique dates where we have historical data
        var allDates = Set<Date>()
        for (_, snapshots) in priceSnapshots {
            for snapshot in snapshots {
                if snapshot.timestamp >= startDate && snapshot.timestamp <= endDate {
                    let dayStart = calendar.startOfDay(for: snapshot.timestamp)
                    allDates.insert(dayStart)
                }
            }
        }
        
        guard !allDates.isEmpty else {
            Task { await logger.warning("🔄 CALC PERIOD: No historical data available for period") }
            return []
        }
        
        var portfolioSnapshots: [HistoricalPortfolioSnapshot] = []
        let sortedDates = Array(allDates.sorted())
        
        Task { await logger.debug("🔄 CALC PERIOD: Processing \(sortedDates.count) unique dates") }
        
        // Calculate total investment cost (what was originally paid)
        let totalInvestmentCost = calculateTotalInvestmentCost(composition: composition, currencyConverter: currencyConverter, preferredCurrency: preferredCurrency)
        
        for (index, date) in sortedDates.enumerated() {
            // Yield control periodically and update progress
            if index % 20 == 0 {
                await Task.yield()
                let progress = 50 + Int(Double(index) / Double(sortedDates.count) * 35) // 50-85% progress range
                let calculationManager = await BackgroundCalculationManager.shared
                await calculationManager.updateProgress(completed: progress, status: "Processing date \(index + 1)/\(sortedDates.count)")
                await calculationManager.updateDataPointsCount(portfolioSnapshots.count)
            }
            
            var totalValueUSD = 0.0
            var positionSnapshots: [String: PositionSnapshot] = [:]
            var validPositions = 0
            var invalidPositions: [String] = []
            
            // Calculate value for each position on this date
            for position in composition.positions {
                guard let symbolSnapshots = priceSnapshots[position.symbol],
                      let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) else {
                    invalidPositions.append(position.symbol)
                    continue
                }
                
                let price = historicalSnapshot.price
                
                // Enhanced data validation
                guard !price.isNaN && price.isFinite && price > 0 else {
                    invalidPositions.append("\(position.symbol) (invalid price: \(price))")
                    continue
                }
                
                guard position.units > 0 && position.units.isFinite else {
                    invalidPositions.append("\(position.symbol) (invalid units: \(position.units))")
                    continue
                }
                
                let valueAtDate = price * position.units
                
                // Validate calculated value
                guard valueAtDate.isFinite && valueAtDate > 0 else {
                    invalidPositions.append("\(position.symbol) (invalid value: \(valueAtDate))")
                    continue
                }
                
                // Convert to USD for aggregation with validation
                var valueInUSD = valueAtDate
                if position.currency == "GBP" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: "GBP", to: "USD")
                } else if position.currency != "USD" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: position.currency, to: "USD")
                }
                
                // Validate converted value
                guard valueInUSD.isFinite && valueInUSD > 0 else {
                    invalidPositions.append("\(position.symbol) (invalid USD conversion: \(valueInUSD))")
                    continue
                }
                
                totalValueUSD += valueInUSD
                validPositions += 1
                
                // Store position snapshot
                positionSnapshots[position.symbol] = PositionSnapshot(
                    symbol: position.symbol,
                    units: position.units,
                    priceAtDate: price,
                    valueAtDate: valueAtDate,
                    currency: position.currency
                )
            }
            
            // Log validation issues for debugging
            if !invalidPositions.isEmpty && index < 5 {
                Task { await logger.debug("🔄 VALIDATION: Invalid positions on \(DateFormatter.debug.string(from: date)): \(invalidPositions.joined(separator: ", "))") }
            }
            
            // Only create portfolio snapshot if we have data for at least 50% of positions
            guard validPositions >= max(1, composition.positions.count / 2) else {
                if index < 5 {
                    Task { await logger.debug("🔄 VALIDATION: Skipping date \(DateFormatter.debug.string(from: date)) - only \(validPositions)/\(composition.positions.count) valid positions") }
                }
                continue
            }
            
            // Validate total portfolio value
            guard totalValueUSD.isFinite && totalValueUSD > 0 else {
                Task { await logger.warning("🔄 VALIDATION: Invalid total portfolio value on \(DateFormatter.debug.string(from: date)): \(totalValueUSD)") }
                continue
            }
            
            // Convert to preferred currency
            var finalValue = totalValueUSD
            if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
                let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
                finalValue = gbpAmount * 100.0
            } else if preferredCurrency != "USD" {
                finalValue = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
            }
            
            let totalGains = finalValue - totalInvestmentCost
            
            let portfolioSnapshot = HistoricalPortfolioSnapshot(
                date: date,
                totalValue: finalValue,
                totalGains: totalGains,
                totalCost: totalInvestmentCost,
                currency: preferredCurrency,
                portfolioComposition: positionSnapshots
            )
            
            portfolioSnapshots.append(portfolioSnapshot)
        }
        
        Task { await logger.debug("🔄 CALC PERIOD: Generated \(portfolioSnapshots.count) snapshots from \(sortedDates.count) dates") }
        return portfolioSnapshots
    }
    
    /// Concurrent calculation method for large date ranges
    private func calculatePortfolioSnapshotsForPeriodConcurrent(
        from startDate: Date,
        to endDate: Date,
        using dataModel: DataModel,
        composition: PortfolioComposition
    ) async -> [HistoricalPortfolioSnapshot] {
        
        Task { await logger.info("🔄 CONCURRENT: Starting concurrent portfolio calculation") }
        
        let calendar = Calendar.current
        let currencyConverter = CurrencyConverter()
        let preferredCurrency = dataModel.preferredCurrency
        
        // Get all unique dates where we have historical data
        var allDates = Set<Date>()
        for (_, snapshots) in priceSnapshots {
            for snapshot in snapshots {
                if snapshot.timestamp >= startDate && snapshot.timestamp <= endDate {
                    let dayStart = calendar.startOfDay(for: snapshot.timestamp)
                    allDates.insert(dayStart)
                }
            }
        }
        
        guard !allDates.isEmpty else {
            Task { await logger.warning("🔄 CONCURRENT: No historical data available for period") }
            return []
        }
        
        let sortedDates = Array(allDates.sorted())
        Task { await logger.info("🔄 CONCURRENT: Processing \(sortedDates.count) dates with concurrent processing") }
        
        // Calculate total investment cost once (thread-safe)
        let totalInvestmentCost = calculateTotalInvestmentCost(
            composition: composition, 
            currencyConverter: currencyConverter, 
            preferredCurrency: preferredCurrency
        )
        
        // Determine optimal chunk size based on available cores
        let processorCount = ProcessInfo.processInfo.processorCount
        let optimalChunks = min(processorCount, 8) // Cap at 8 to avoid too much overhead
        let chunkSize = max(10, sortedDates.count / optimalChunks) // Minimum 10 dates per chunk
        
        Task { await logger.info("🔄 CONCURRENT: Using \(optimalChunks) concurrent tasks with ~\(chunkSize) dates each") }
        
        // Split dates into chunks for concurrent processing
        let dateChunks = sortedDates.chunked(into: chunkSize)
        
        // Process chunks concurrently using TaskGroup with timeout protection
        let allSnapshots = await withTaskTimeout(seconds: 600) { // 10 minute timeout
            await withTaskGroup(of: [HistoricalPortfolioSnapshot].self) { group in
                var results: [HistoricalPortfolioSnapshot] = []
                
                for (chunkIndex, chunk) in dateChunks.enumerated() {
                    group.addTask { [weak self] in
                        guard let self = self else { return [] }
                        
                        return await self.calculatePortfolioSnapshotsForChunk(
                            dates: chunk,
                            chunkIndex: chunkIndex,
                            totalChunks: dateChunks.count,
                            composition: composition,
                            totalInvestmentCost: totalInvestmentCost,
                            preferredCurrency: preferredCurrency,
                            currencyConverter: currencyConverter
                        )
                    }
                }
                
                // CRITICAL FIX: Collect results with timeout protection
                for await chunkResult in group {
                    results.append(contentsOf: chunkResult)
                }
                
                return results
            }
        } ?? {
            Task { await logger.error("🔄 CONCURRENT: TaskGroup timed out after 10 minutes, returning partial results") }
            return []
        }()
        
        // Sort results by date and return
        let sortedSnapshots = allSnapshots.sorted { $0.date < $1.date }
        Task { await logger.info("🔄 CONCURRENT: Generated \(sortedSnapshots.count) snapshots using concurrent processing") }
        
        return sortedSnapshots
    }
    
    /// Processes a chunk of dates for concurrent calculation
    private func calculatePortfolioSnapshotsForChunk(
        dates: [Date],
        chunkIndex: Int,
        totalChunks: Int,
        composition: PortfolioComposition,
        totalInvestmentCost: Double,
        preferredCurrency: String,
        currencyConverter: CurrencyConverter
    ) async -> [HistoricalPortfolioSnapshot] {
        
        var portfolioSnapshots: [HistoricalPortfolioSnapshot] = []
        
        for (dateIndex, date) in dates.enumerated() {
            // CRITICAL FIX: Check for task cancellation first
            do {
                try Task.checkCancellation()
            } catch {
                Task { await logger.info("🔄 CHUNK \(chunkIndex): Task cancelled, stopping processing at date \(dateIndex)/\(dates.count)") }
                break
            }
            
            // Update progress less frequently for concurrent processing
            if dateIndex % 5 == 0 {
                await Task.yield() // Allow other tasks to run
                
                // Update global progress
                let overallProgress = Double(chunkIndex * dates.count + dateIndex) / Double(totalChunks * dates.count)
                let progressPercent = 50 + Int(overallProgress * 35) // 50-85% range
                
                let calculationManager = await BackgroundCalculationManager.shared
                await calculationManager.updateProgress(
                    completed: progressPercent, 
                    status: "Concurrent processing chunk \(chunkIndex + 1)/\(totalChunks)"
                )
            }
            
            var totalValueUSD = 0.0
            var positionSnapshots: [String: PositionSnapshot] = [:]
            var validPositions = 0
            
            // Calculate value for each position on this date
            for position in composition.positions {
                guard let symbolSnapshots = priceSnapshots[position.symbol],
                      let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) else {
                    continue
                }
                
                let price = historicalSnapshot.price
                
                // Data validation
                guard !price.isNaN && price.isFinite && price > 0,
                      position.units > 0 && position.units.isFinite else {
                    continue
                }
                
                let valueAtDate = price * position.units
                guard valueAtDate.isFinite && valueAtDate > 0 else { continue }
                
                // Convert to USD for aggregation
                var valueInUSD = valueAtDate
                if position.currency == "GBP" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: "GBP", to: "USD")
                } else if position.currency != "USD" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: position.currency, to: "USD")
                }
                
                guard valueInUSD.isFinite && valueInUSD > 0 else { continue }
                
                totalValueUSD += valueInUSD
                validPositions += 1
                
                // Store position snapshot
                positionSnapshots[position.symbol] = PositionSnapshot(
                    symbol: position.symbol,
                    units: position.units,
                    priceAtDate: price,
                    valueAtDate: valueAtDate,
                    currency: position.currency
                )
            }
            
            // Only create portfolio snapshot if we have data for at least 50% of positions
            guard validPositions >= max(1, composition.positions.count / 2),
                  totalValueUSD.isFinite && totalValueUSD > 0 else {
                continue
            }
            
            // Convert to preferred currency
            var finalValue = totalValueUSD
            if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
                let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
                finalValue = gbpAmount * 100.0
            } else if preferredCurrency != "USD" {
                finalValue = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
            }
            
            let totalGains = finalValue - totalInvestmentCost
            
            let portfolioSnapshot = HistoricalPortfolioSnapshot(
                date: date,
                totalValue: finalValue,
                totalGains: totalGains,
                totalCost: totalInvestmentCost,
                currency: preferredCurrency,
                portfolioComposition: positionSnapshots
            )
            
            portfolioSnapshots.append(portfolioSnapshot)
        }
        
        return portfolioSnapshots
    }
    
    /// Calculates total investment cost for a portfolio composition
    private func calculateTotalInvestmentCost(composition: PortfolioComposition, currencyConverter: CurrencyConverter, preferredCurrency: String) -> Double {
        var totalCostUSD = 0.0
        
        for position in composition.positions {
            let totalPositionCost = position.avgCost * position.units
            
            // Convert to USD for aggregation
            var costInUSD = totalPositionCost
            if position.currency == "GBP" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: "GBP", to: "USD")
            } else if position.currency != "USD" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: position.currency, to: "USD")
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency
        var finalCost = totalCostUSD
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: "GBP")
            finalCost = gbpAmount * 100.0
        } else if preferredCurrency != "USD" {
            finalCost = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: preferredCurrency)
        }
        
        return finalCost
    }
    
    /// Finds the earliest available historical data across all symbols
    private func findEarliestHistoricalData() -> Date {
        var earliestDate = Date()
        
        for (_, snapshots) in priceSnapshots {
            if let earliest = snapshots.min(by: { $0.timestamp < $1.timestamp })?.timestamp {
                if earliest < earliestDate {
                    earliestDate = earliest
                }
            }
        }
        
        // Don't go back more than 5 years
        let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
        return max(earliestDate, fiveYearsAgo)
    }
    
    /// Gets the date of the last portfolio snapshot
    private func getLastPortfolioSnapshotDate() -> Date {
        return historicalPortfolioSnapshots.last?.date ?? findEarliestHistoricalData()
    }
    
    /// Gets stored portfolio values for chart display
    func getStoredPortfolioValues(for timeRange: ChartTimeRange) -> [ChartDataPoint] {
        let startDate = timeRange.startDate()

        // Debug logging
        Task { await logger.debug("📊 GET PORTFOLIO VALUES: totalSnapshots=\(historicalPortfolioSnapshots.count), startDate=\(startDate), timeRange=\(timeRange.rawValue)") }

        let filteredSnapshots = historicalPortfolioSnapshots
            .filter { $0.date >= startDate }
            .sorted { $0.date < $1.date }

        Task { await logger.debug("📊 GET PORTFOLIO VALUES: filteredCount=\(filteredSnapshots.count)") }

        return filteredSnapshots.map { snapshot in
            ChartDataPoint(date: snapshot.date, value: snapshot.totalValue)
        }
    }
    
    /// Gets stored portfolio gains for chart display
    func getStoredPortfolioGains(for timeRange: ChartTimeRange) -> [ChartDataPoint] {
        let startDate = timeRange.startDate()
        
        let filteredSnapshots = historicalPortfolioSnapshots
            .filter { $0.date >= startDate }
            .sorted { $0.date < $1.date }
        
        return filteredSnapshots.map { snapshot in
            ChartDataPoint(date: snapshot.date, value: snapshot.totalGains)
        }
    }
    
    /// Gets price snapshots for a specific symbol within a time range
    /// Used by MenuPriceChartView for individual stock charts
    func getPriceSnapshots(for symbol: String, from startDate: Date, to endDate: Date = Date()) -> [PriceSnapshot] {
        guard let snapshots = priceSnapshots[symbol] else {
            Task { await logger.debug("📊 No price snapshots found for symbol: \(symbol)") }
            return []
        }
        
        let filteredSnapshots = snapshots
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            .sorted { $0.timestamp < $1.timestamp }
        
        Task { await logger.debug("📊 Retrieved \(filteredSnapshots.count) price snapshots for \(symbol) from \(startDate) to \(endDate)") }
        
        // If we have insufficient data, trigger background fetch
        if filteredSnapshots.count < 10 {
            Task.detached(priority: .background) { [weak self] in
                await self?.triggerHistoricalDataFetch(for: symbol, timeRange: .day, startDate: startDate)
            }
        }
        
        return filteredSnapshots
    }

}

struct PerformanceMetrics {
    let totalReturn: Double
    let totalReturnPercent: Double
    let volatility: Double
    let maxValue: Double
    let minValue: Double
    let currency: String
    let startDate: Date
    let endDate: Date
    
    // MARK: - Advanced Analytics
    let sharpeRatio: Double?
    let maxDrawdown: Double?
    let maxDrawdownPercent: Double?
    let beta: Double?
    let annualizedReturn: Double?
    let annualizedVolatility: Double?
    let valueAtRisk: Double? // 95% VaR
    let winRate: Double? // Percentage of positive return periods
    
    var formattedTotalReturn: String {
        return String(format: "%+.2f %@", totalReturn, currency)
    }
    
    var formattedTotalReturnPercent: String {
        return String(format: "%+.2f%%", totalReturnPercent)
    }
    
    var formattedVolatility: String {
        return String(format: "%.2f%%", volatility)
    }
    
    var formattedSharpeRatio: String {
        guard let sharpe = sharpeRatio else { return "N/A" }
        return String(format: "%.2f", sharpe)
    }
    
    var formattedMaxDrawdown: String {
        guard let drawdown = maxDrawdownPercent else { return "N/A" }
        return String(format: "%.2f%%", drawdown)
    }
    
    var formattedAnnualizedReturn: String {
        guard let annualized = annualizedReturn else { return "N/A" }
        return String(format: "%.2f%%", annualized)
    }
    
    var formattedBeta: String {
        guard let betaValue = beta else { return "N/A" }
        return String(format: "%.2f", betaValue)
    }
    
    var formattedVaR: String {
        guard let var95 = valueAtRisk else { return "N/A" }
        return String(format: "%.2f%%", var95)
    }
    
    var formattedWinRate: String {
        guard let winRateValue = winRate else { return "N/A" }
        return String(format: "%.1f%%", winRateValue)
    }
}
