import Combine
import CoreData
import Foundation
import Observation

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

struct InstrumentAliasHistoryLookup {
    static func combinedSnapshots(
        for symbol: String,
        aliases: [String],
        storedBySymbol: [String: [PriceSnapshot]],
        liveBySymbol: [String: [PriceSnapshot]]
    ) -> [PriceSnapshot] {
        let requested = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var seenAliases = Set<String>()
        var orderedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != requested && seenAliases.insert($0).inserted }
        orderedAliases.append(requested)

        var latestByTimestamp: [Int64: PriceSnapshot] = [:]
        for alias in orderedAliases {
            for snapshot in values(for: alias, in: storedBySymbol) + values(for: alias, in: liveBySymbol)
                where snapshot.price.isFinite && snapshot.price > 0 {
                let key = Int64((snapshot.timestamp.timeIntervalSince1970 * 1_000).rounded())
                latestByTimestamp[key] = snapshot
            }
        }
        return latestByTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private static func values(
        for symbol: String,
        in valuesBySymbol: [String: [PriceSnapshot]]
    ) -> [PriceSnapshot] {
        valuesBySymbol[symbol]
            ?? valuesBySymbol.first { $0.key.uppercased() == symbol }?.value
            ?? []
    }
}

struct ComprehensiveDataStatus: Sendable {
    let symbol: String
    let daily: Int
    let weekly: Int
    let monthly: Int
    let oldestDate: String
    let newestDate: String
}

struct FolyncLineSeriesKey: Hashable, Sendable {
    let symbol: String
    let range: String
    let customFromMilliseconds: Int64?
    let customToMilliseconds: Int64?

    init(
        symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.range = timeRange.folyncRange
        if timeRange == .custom {
            self.customFromMilliseconds = customFrom.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
            self.customToMilliseconds = customTo.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
        } else {
            self.customFromMilliseconds = nil
            self.customToMilliseconds = nil
        }
    }

    var storageKey: String {
        "line|\(symbol)|\(range)|\(customFromMilliseconds.map(String.init) ?? "-")|\(customToMilliseconds.map(String.init) ?? "-")"
    }
}

// CRITICAL FIX: Task timeout utility to prevent infinite processing
func withTaskTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async -> T? {
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

struct HistoricalFetchRequestGate {
    private(set) var lastRequestByKey: [String: Date] = [:]
    private(set) var inFlightKeys: Set<String> = []
    private var emptyResponseCounts: [String: Int] = [:]
    private var emptyRetryAfter: [String: Date] = [:]

    mutating func reserve(key: String, now: Date, cooldown: TimeInterval, force: Bool = false) -> Bool {
        guard !inFlightKeys.contains(key) else { return false }
        let expiredKeys = lastRequestByKey.compactMap { key, date in
            !inFlightKeys.contains(key) && now.timeIntervalSince(date) > 24 * 60 * 60 ? key : nil
        }
        for expiredKey in expiredKeys {
            lastRequestByKey.removeValue(forKey: expiredKey)
            emptyResponseCounts.removeValue(forKey: expiredKey)
            emptyRetryAfter.removeValue(forKey: expiredKey)
        }
        if !force, let retryAfter = emptyRetryAfter[key], now < retryAfter { return false }
        if !force, let lastRequest = lastRequestByKey[key],
           now.timeIntervalSince(lastRequest) < cooldown {
            return false
        }

        lastRequestByKey[key] = now
        inFlightKeys.insert(key)
        return true
    }

    mutating func complete(
        key: String,
        outcome: HistoricalPriceFetchOutcome = .success,
        now: Date = Date(),
        cooldown: TimeInterval = 600
    ) {
        inFlightKeys.remove(key)
        switch outcome {
        case .empty:
            let count = min((emptyResponseCounts[key] ?? 0) + 1, 5)
            emptyResponseCounts[key] = count
            let delay = min(6 * 60 * 60, cooldown * 3 * pow(2, Double(count - 1)))
            emptyRetryAfter[key] = now.addingTimeInterval(delay)
        case .success, .cancelled:
            emptyResponseCounts.removeValue(forKey: key)
            emptyRetryAfter.removeValue(forKey: key)
            if outcome == .cancelled { lastRequestByKey.removeValue(forKey: key) }
        case .failed:
            break
        }
    }
}

@MainActor
@Observable
class HistoricalDataManager {
    static let shared = HistoricalDataManager()
    
    private let logger = Logger.shared
    private let encoder = JSONEncoder()
    
    // Performance optimization services
    private let chartDataService = OptimizedChartDataService.shared
    private let batchService = BatchProcessingService.shared
    private let memoryService = MemoryManagementService.shared
    private let decoder = JSONDecoder()
    private let cacheManager = CacheManager.shared
    private let coreDataService: HistoricalDataServiceProtocol
    private let migrationService = DataMigrationService.shared
    private let instrumentAliasStore = InstrumentAliasStore()
    
    var portfolioSnapshots: [PortfolioSnapshot] = []
    var priceSnapshots: [String: [PriceSnapshot]] = [:] {
        didSet { aliasHistoryCache.removeAll() }
    }
    private(set) var priceDataRevision: Int = 0
    /// Which series changed with each `priceDataRevision` bump: upper-cased
    /// symbol and alias keys, or nil when every series may have changed.
    let priceDataChanges = PassthroughSubject<Set<String>?, Never>()
    private(set) var portfolioHistoryRevision: Int = 0
    private(set) var folyncSupplementalConfigurationRevision: Int = 0
    private(set) var folyncSourceStatusBySeries: [String: FolyncSupplementalSourceStatus] = [:]
    private(set) var folyncCoverageBySeries: [String: String] = [:]
    
    // MARK: - Enhanced Portfolio Storage
    
    // New persistent portfolio snapshots storage
    var historicalPortfolioSnapshots: [HistoricalPortfolioSnapshot] = []
    @ObservationIgnored private var currentPortfolioComposition: PortfolioComposition?
    @ObservationIgnored private var lastRetroactiveCalculationDate: Date = Date.distantPast
    
    // Cache for calculated historical portfolio values (legacy - being phased out)
    @ObservationIgnored public private(set) var cachedHistoricalPortfolioValues: [ChartDataPoint] = []
    
    // CRITICAL FIX: Prevent concurrent calculation overlaps
    @ObservationIgnored private var isCalculationInProgress = false
    private let calculationLock = NSLock()
    @ObservationIgnored private var lastPortfolioCalculationDate: Date = Date.distantPast
    private let portfolioCalculationCacheInterval: TimeInterval = 1800 // 30 minutes cache (increased from 5 minutes)
    @ObservationIgnored private var earliestAvailableDates: [String: Date] = [:]
    
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
        static let earliestAvailableDates = "earliestAvailableDates"
    }
    
    // MARK: - Performance Caching
    
    // Cache for getOptimalStockData results to prevent repeated expensive calculations
    @ObservationIgnored private var stockDataCache: [String: [ChartDataPoint]] = [:]
    @ObservationIgnored private var stockDataCacheTimestamp: [String: Date] = [:]
    private let stockDataCacheInterval: TimeInterval = 30 // 30 seconds cache
    
    // Full history stays in Core Data; only the active working set is retained.
    private let maxDataPoints = 1_800
    
    private static let snapshotIntervalDefaultsKey = "portfolioSnapshotIntervalSeconds"
    /// Seconds between recorded portfolio snapshots (default 5 minutes), kept across launches.
    @ObservationIgnored private var snapshotInterval: TimeInterval = {
        let stored = StockbarRuntimeStorage.userDefaults.double(forKey: HistoricalDataManager.snapshotIntervalDefaultsKey)
        return stored >= 30 ? stored : 300
    }()
    @ObservationIgnored private var lastSnapshotTime: Date = Date.distantPast
    @ObservationIgnored private var livePriceSamples: [String: [PriceSnapshot]] = [:] {
        didSet { aliasHistoryCache.removeAll() }
    }
    @ObservationIgnored private var aliasHistoryCache = AliasPriceSnapshotCache()
    @ObservationIgnored private var livePortfolioValueSamples: [ChartDataPoint] = []
    @ObservationIgnored private var livePortfolioGainSamples: [ChartDataPoint] = []
    /// Currency of the live portfolio samples (the menu-bar currency), which
    /// can differ from the main currency the stored snapshots use.
    @ObservationIgnored private var livePortfolioSampleCurrency: String?
    private let priceHistoryScheduler = HistoricalPriceFetchScheduler()
    @ObservationIgnored private var folyncPortfolioHistoryContexts: [String: String] = [:]
    @ObservationIgnored private var folyncPortfolioHistoryFetchRequestTimes: [String: Date] = [:]
    @ObservationIgnored private var folyncPriceOverlays: [String: [PriceSnapshot]] = [:]
    @ObservationIgnored private var folyncUnavailableSeries: Set<String> = []
    @ObservationIgnored private var folyncPortfolioValueOverlays: [String: [ChartDataPoint]] = [:]
    @ObservationIgnored private var folyncPortfolioGainOverlays: [String: [ChartDataPoint]] = [:]
    private let livePriceSampleRetention: TimeInterval = 7 * 24 * 60 * 60
    private let maxLivePriceSamplesPerSymbol = 1_000
    private let maxLivePortfolioSamples = 1_000
    private let menuPriceHistoryFetchCooldown: TimeInterval = 10 * 60
    
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
        let snapshots = Self.thinnedPortfolioHistory(await loadPortfolioSnapshotsFromCoreData(timeRange: .all))
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
    private func performOptimizedBackgroundOperation<T: Sendable>(
        _ operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await logger.debug("🔄 Starting optimized background operation: \(operationName)")
        
        // Use task with specific priority for background work
        return try await Task.detached(priority: .utility) {
            let result = try await operation()
            await Logger.shared.debug("✅ Completed optimized background operation: \(operationName)")
            return result
        }.value
    }
    
    /// Batch process large datasets in chunks to prevent memory spikes
    private func processBatchOperation<T: Sendable, R: Sendable>(
        items: [T],
        batchSize: Int = 100,
        operationName: String,
        operation: @escaping @Sendable ([T]) async throws -> R
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
    private func storeInCache<T: Codable & Sendable>(_ data: T, key: String, isRecent: Bool = false) {
        let cacheLevel: CacheManager.CacheLevel = isRecent ? .memory : 
                        (key.contains("historical") ? .archived : .disk)
        cacheManager.store(data, forKey: key, level: cacheLevel)
    }
    
    /// Retrieve data from cache with fallback to UserDefaults for migration
    private func retrieveFromCache<T: Codable & Sendable>(_ type: T.Type, key: String) -> T? {
        // Try cache first
        if let cachedData = cacheManager.retrieve(type, forKey: key) {
            return cachedData
        }
        
        // Fallback to UserDefaults for backward compatibility during migration
        if let data = StockbarRuntimeStorage.userDefaults.data(forKey: key),
           let decoded = try? decoder.decode(type, from: data) {
            // Migrate to cache for future access
            storeInCache(decoded, key: key)
                            Task { await logger.debug("🔄 Migrated \(key) from UserDefaults to cache") }
            return decoded
        }
        
        return nil
    }
    
    /// Historical portfolio snapshots for a range. Filtering the in-memory
    /// array is cheap, and a cache here went stale (or stayed empty) whenever
    /// snapshots were loaded or merged without a new recording.
    func getHistoricalPortfolioSnapshots(timeRange: ChartTimeRange) -> [HistoricalPortfolioSnapshot] {
        let cutoffDate = timeRange.startDate()
        return historicalPortfolioSnapshots.filter { $0.date >= cutoffDate }
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
        }
        
        Task { await logger.debug("🗑️ Invalidated caches for symbol: \(symbol ?? "all")") }
    }
    
    // MARK: - Performance Enhancement Methods
    
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
            let portfolioComposition: [String: PositionSnapshot] = Dictionary(firstValuesFor: 
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

    /// Records a memory-only price point from live refresh/broker sync paths.
    /// This improves intraday menu charts without changing persistent snapshot cadence.
    func recordLivePriceSample(
        symbol: String,
        price: Double,
        previousClose: Double?,
        timestamp: Date = Date()
    ) {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbolKey.isEmpty, price.isFinite, price > 0 else {
            Task { await logger.debug("📈 Skipping live price sample for \(symbol) - invalid price \(price)") }
            return
        }

        let previousCloseValue: Double
        if let previousClose, previousClose.isFinite, previousClose > 0 {
            previousCloseValue = previousClose
        } else {
            previousCloseValue = price
        }

        let sample = PriceSnapshot(
            timestamp: timestamp,
            price: price,
            previousClose: previousCloseValue,
            volume: nil,
            symbol: symbolKey
        )

        var samples = livePriceSamples[symbolKey] ?? []
        if let last = samples.last, abs(last.timestamp.timeIntervalSince(timestamp)) < 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }

        let cutoff = timestamp.addingTimeInterval(-livePriceSampleRetention)
        samples = samples
            .filter { $0.timestamp >= cutoff && $0.price.isFinite && $0.price > 0 }
            .sorted { $0.timestamp < $1.timestamp }

        if samples.count > maxLivePriceSamplesPerSymbol {
            samples = Array(samples.suffix(maxLivePriceSamplesPerSymbol))
        }

        livePriceSamples[symbolKey] = samples
        notePriceDataChanged(for: symbolKey)
    }

    /// Records a memory-only portfolio value/gain point from live refresh paths.
    /// This keeps portfolio menu charts responsive without changing persistent snapshot cadence.
    func recordLivePortfolioSample(
        totalValue: Double,
        totalGains: Double,
        currency: String? = nil,
        timestamp: Date = Date()
    ) {
        guard totalValue.isFinite, totalValue > 0 else {
            Task { await logger.debug("📈 Skipping live portfolio sample - invalid value \(totalValue)") }
            return
        }

        if let currency, currency.uppercased() != livePortfolioSampleCurrency?.uppercased() {
            // Samples in different currencies cannot share one series.
            if livePortfolioSampleCurrency != nil {
                livePortfolioValueSamples.removeAll()
                livePortfolioGainSamples.removeAll()
            }
            livePortfolioSampleCurrency = currency
        }

        livePortfolioValueSamples = appendLivePortfolioPoint(
            ChartDataPoint(date: timestamp, value: totalValue),
            to: livePortfolioValueSamples,
            timestamp: timestamp
        )

        if totalGains.isFinite {
            livePortfolioGainSamples = appendLivePortfolioPoint(
                ChartDataPoint(date: timestamp, value: totalGains),
                to: livePortfolioGainSamples,
                timestamp: timestamp
            )
        }
    }

    /// Returns display-only portfolio menu values. For 1D, this reconstructs the
    /// current portfolio over the last day from available symbol snapshots.
    func getPortfolioMenuValues(
        for timeRange: ChartTimeRange,
        currentTrades: [RealTimeTrade],
        preferredCurrency: String,
        now: Date = Date(),
        scheduleMissingHistoryFetches: Bool = true,
        allowSyntheticPositionHistory: Bool = true
    ) -> [ChartDataPoint] {
        let startDate = timeRange.startDate(from: now)
        let storedAndLiveValues = storedAndLivePortfolioValues(from: startDate, to: now, currency: preferredCurrency)

        guard timeRange == .day, allowSyntheticPositionHistory else {
            return storedAndLiveValues
        }

        let positions = portfolioMenuPositions(
            from: currentTrades,
            preferredCurrency: preferredCurrency
        )
        guard !positions.isEmpty else {
            return storedAndLiveValues
        }

        let syntheticValues = syntheticPortfolioMenuValues(
            positions: positions,
            preferredCurrency: preferredCurrency,
            startDate: startDate,
            endDate: now
        )

        if scheduleMissingHistoryFetches {
            schedulePortfolioMenuHistoryFetchesIfNeeded(
                currentTrades: currentTrades,
                startDate: startDate,
                endDate: now,
                syntheticPointCount: syntheticValues.count
            )
        }

        guard syntheticValues.count >= 3 else {
            return storedAndLiveValues
        }

        return deduplicatedSortedChartPoints(storedAndLiveValues + syntheticValues)
    }

    func portfolioMenuHistoryFetchCandidates(
        currentTrades: [RealTimeTrade],
        startDate: Date,
        endDate: Date,
        minimumPoints: Int = 3
    ) -> [String] {
        currentTrades
            .filter { !$0.trade.isWatchlistOnly && $0.trade.position.unitSize > 0 }
            .compactMap { realTimeTrade -> String? in
                let symbol = realTimeTrade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !symbol.isEmpty else { return nil }

                let snapshotCount = allPortfolioMenuPriceSnapshots(for: symbol)
                    .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
                    .count
                return snapshotCount < minimumPoints ? symbol : nil
            }
    }
    
    func getChartData(
        for type: ChartType,
        timeRange: ChartTimeRange,
        dataModel: DataModel? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        switch type {
        case .portfolioValue:
            if let routed = folyncPortfolioOverlay(
                kind: "portfolio-value",
                timeRange: timeRange,
                dataModel: dataModel,
                customFrom: customFrom,
                customTo: customTo
            ) {
                return routed
            }
            // Note: Core Data loading is now handled in loadHistoricalData() to prevent infinite loops
            
            // NEW: Use stored portfolio snapshots if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioValues(
                    for: timeRange, currency: dataModel?.preferredCurrency, customFrom: customFrom, customTo: customTo
                )
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
                    return getStoredPortfolioValues(
                    for: timeRange, currency: dataModel.preferredCurrency, customFrom: customFrom, customTo: customTo
                )
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
            if let routed = folyncPortfolioOverlay(
                kind: "portfolio-gain",
                timeRange: timeRange,
                dataModel: dataModel,
                customFrom: customFrom,
                customTo: customTo
            ) {
                return routed
            }
            // Note: Core Data loading is now handled in loadHistoricalData() to prevent infinite loops
            
            // NEW: Use stored portfolio gains if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioGains(
                    for: timeRange, currency: dataModel?.preferredCurrency, customFrom: customFrom, customTo: customTo
                )
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
                    return getStoredPortfolioGains(
                    for: timeRange, currency: dataModel.preferredCurrency, customFrom: customFrom, customTo: customTo
                )
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
            let endDate = timeRange == .custom ? (customTo ?? Date()) : Date()
            let startDate = timeRange == .custom
                ? (customFrom ?? timeRange.startDate(from: endDate))
                : timeRange.startDate(from: endDate)
            return getOptimalStockData(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate,
                dataModel: dataModel
            )
        }
    }
    
    /// Gets stock data for charts with increased data limits and caching
    private func getOptimalStockData(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date,
        dataModel: DataModel?
    ) -> [ChartDataPoint] {
        // Rolling ranges end "now", so their dates must not be part of the key
        // (it changed every second and the cache grew without bound).
        let cacheKey = timeRange == .custom
            ? "\(symbol)-\(timeRange.rawValue)-\(Int(startDate.timeIntervalSince1970))-\(Int(endDate.timeIntervalSince1970))"
            : "\(symbol)-\(timeRange.rawValue)"
        let folyncEnabled = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        let folyncRouteApplies = folyncEnabled
            && dataModel?.folyncCapabilities?.isTrackedOrAllowlisted(symbol) == true
        let folyncSeriesKeys = folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: timeRange == .custom ? startDate : nil,
            customTo: timeRange == .custom ? endDate : nil
        )
        let folyncStatus = folyncSeriesKeys.compactMap { folyncSourceStatusBySeries[$0] }.first

        if folyncEnabled {
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate
            )
        }
        
        // Check cache first
        if !folyncRouteApplies || folyncStatus != nil,
           let cachedData = stockDataCache[cacheKey],
           let cacheTime = stockDataCacheTimestamp[cacheKey],
           Date().timeIntervalSince(cacheTime) < stockDataCacheInterval {
            Task { await logger.debug("📊 CACHE HIT: Stock data for \(symbol) \(timeRange.rawValue): \(cachedData.count) points") }
            return cachedData
        }
        
        let allSnapshots = folyncRouteApplies && folyncStatus == nil
            ? []
            : aliasAwarePriceSnapshots(for: symbol, folyncSeriesKeys: folyncSeriesKeys)
        
        // Filter and convert to chart data points
        let filteredData = allSnapshots
            .filter { $0.timestamp >= startDate && (timeRange != .custom || $0.timestamp <= endDate) }
            .map { ChartDataPoint(date: $0.timestamp, value: $0.price, symbol: symbol) }
            .sorted { $0.date < $1.date }
        
        Task { await logger.debug("📊 CACHE MISS: Stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count) points") }
        
        // Cache the result, dropping expired entries first.
        let now = Date()
        for (key, cachedAt) in stockDataCacheTimestamp where now.timeIntervalSince(cachedAt) >= stockDataCacheInterval {
            stockDataCache.removeValue(forKey: key)
            stockDataCacheTimestamp.removeValue(forKey: key)
        }
        stockDataCache[cacheKey] = filteredData
        stockDataCacheTimestamp[cacheKey] = now
        
        // Check if we have insufficient data for the requested time range
        let minimumExpectedDataPoints = getExpectedDataPointsForTimeRange(timeRange)
        let hasInsufficientData = filteredData.count < minimumExpectedDataPoints
        
        // Trigger historical data fetching if we don't have enough data
        if hasInsufficientData {
            Task { await logger.info("📊 Insufficient stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count)/\(minimumExpectedDataPoints) points. Triggering historical data fetch.") }
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate
            )
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
    func triggerHistoricalDataFetch(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date = Date(),
        folyncConfigurationRevision: Int? = nil
    ) async -> HistoricalPriceFetchOutcome {
        guard !Task.isCancelled,
              folyncConfigurationRevision == nil || folyncConfigurationRevision == self.folyncSupplementalConfigurationRevision
        else { return .cancelled }
        await logger.info("🔄 Starting historical data fetch for \(symbol) from \(startDate)")

        if FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts) {
            let result = await FolyncSupplementalCoordinator.shared.routeLineHistory(
                symbol: symbol,
                range: timeRange.folyncRange,
                from: timeRange == .custom ? startDate : nil,
                to: timeRange == .custom ? endDate : nil
            )
            if let folyncConfigurationRevision,
               folyncConfigurationRevision != self.folyncSupplementalConfigurationRevision {
                await logger.info("Discarding superseded Folync history response for \(symbol)")
                return .cancelled
            }
            switch result {
            case .folync(let snapshots, let status, let identity, let metadata):
                setFolyncPriceOverlay(
                    snapshots,
                    identity: identity,
                    requestedSymbol: symbol,
                    status: status,
                    metadata: metadata,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
                await logger.info("Using \(snapshots.count) non-persisted \(status.label) line-chart points for \(symbol)")
                return .success
            case .unavailable:
                markFolyncSeriesUnavailable(
                    symbol,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
                await logger.warning("Folync line history is unavailable for \(symbol); local fallback is disabled")
                return .failed
            case .legacy:
                clearFolyncPriceOverlayForLegacy(
                    symbol,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
            }
        }
        
        // Use NetworkService to fetch historical data
        guard let networkService = getNetworkService() else {
            await logger.error("❌ Cannot fetch historical data: NetworkService not available")
            return .failed
        }
        
        do {
            let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
            guard !Task.isCancelled,
                  folyncConfigurationRevision == nil || folyncConfigurationRevision == self.folyncSupplementalConfigurationRevision
            else { return .cancelled }
            
            await logger.info("📥 Received \(historicalData.count) historical data points for \(symbol)")
            
            if !historicalData.isEmpty {
                // Add the historical data to our cache
                addImportedSnapshots(historicalData, for: symbol)
                await logger.info("✅ Successfully added \(historicalData.count) historical data points for \(symbol)")
            } else {
                await logger.warning("⚠️ No historical data received for \(symbol)")
            }
            return historicalData.isEmpty ? .empty : .success
        } catch NetworkError.noData {
            await logger.info("No history available for \(symbol) in the requested interval; delaying automatic retry")
            return .empty
        } catch is CancellationError {
            return .cancelled
        } catch {
            await logger.error("❌ Failed to fetch historical data for \(symbol): \(error.localizedDescription)")
            return .failed
        }
    }
    
    /// Gets the NetworkService instance - this should be updated to use dependency injection
    private func getNetworkService() -> NetworkService? {
        // For now, we'll create a PythonNetworkService instance
        // In the future, this should be injected as a dependency
        return PythonNetworkService()
    }
    
    /// Start and end of a portfolio chart range; `.custom` uses the user's dates.
    func portfolioRangeBounds(
        for timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        guard timeRange == .custom, let customFrom else {
            return (timeRange.startDate(from: now), now)
        }
        return (customFrom, min(customTo ?? now, now))
    }

    /// Metrics for the series the portfolio chart draws: recorded snapshots
    /// plus this session's live samples, falling back to session snapshots.
    func getPerformanceMetrics(
        for timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil,
        currency: String? = nil,
        now: Date = Date()
    ) -> PerformanceMetrics? {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo, now: now)
        let seriesCurrency = currency ?? historicalPortfolioSnapshots.last?.currency
        var points = storedAndLivePortfolioValues(from: bounds.start, to: bounds.end, currency: seriesCurrency)
            .filter { $0.value.isFinite && $0.value > 0 }
        var previousPoint = storedAndLivePortfolioValues(from: .distantPast, to: bounds.start, currency: seriesCurrency)
            .last { $0.value.isFinite && $0.value > 0 && $0.date < bounds.start }
        var metricsCurrency = seriesCurrency
        if points.isEmpty {
            let session = portfolioSnapshots.sorted { $0.timestamp < $1.timestamp }
            points = session
                .filter { $0.timestamp >= bounds.start && $0.timestamp <= bounds.end && $0.totalValue.isFinite && $0.totalValue > 0 }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
            previousPoint = session
                .last { $0.timestamp < bounds.start && $0.totalValue.isFinite && $0.totalValue > 0 }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
            metricsCurrency = metricsCurrency ?? session.last?.currency
        }
        return Self.performanceMetrics(points: points, previousPoint: previousPoint, currency: metricsCurrency ?? "USD")
    }

    /// Pure metrics over a sorted value series. Per-period statistics use one
    /// close per day, and annualised figures need at least 30 days of data.
    nonisolated static func performanceMetrics(
        points: [ChartDataPoint],
        previousPoint: ChartDataPoint?,
        currency: String,
        calendar: Calendar = .current
    ) -> PerformanceMetrics? {
        guard let firstPoint = points.first, let lastPoint = points.last else { return nil }

        // A single point is compared with the last value before the range.
        let basePoint = points.count == 1 ? previousPoint : firstPoint
        let totalReturn: Double
        let totalReturnPercent: Double
        if let basePoint, basePoint.value > 0 {
            totalReturn = lastPoint.value - basePoint.value
            totalReturnPercent = (totalReturn / basePoint.value) * 100
        } else {
            totalReturn = 0
            totalReturnPercent = 0
        }

        var dailyCloses: [Double] = []
        var lastDay: Date?
        for point in points {
            let day = calendar.startOfDay(for: point.date)
            if day == lastDay {
                dailyCloses[dailyCloses.count - 1] = point.value
            } else {
                dailyCloses.append(point.value)
                lastDay = day
            }
        }
        let dailyReturns = zip(dailyCloses.dropFirst(), dailyCloses).map { current, previous in
            (current - previous) / previous
        }

        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance) * 100

        let values = points.map(\.value)
        let maxValue = values.max() ?? lastPoint.value
        let minValue = values.min() ?? lastPoint.value

        // Sharpe ratio, assuming a 2% annual risk-free rate.
        let riskFreeRate = 0.02 / 252
        let meanExcessReturn = meanReturn - riskFreeRate
        let sharpeRatio = variance > 0 ? meanExcessReturn / sqrt(variance) : nil

        let (maxDrawdown, maxDrawdownPercent) = calculateMaxDrawdown(values: values)

        let span = lastPoint.date.timeIntervalSince(basePoint?.date ?? firstPoint.date)
        let periodInYears = span / (365.25 * 24 * 3600)
        let annualizedReturn: Double? = span >= 30 * 86_400 && basePoint != nil
            ? (pow(1 + totalReturnPercent / 100, 1 / periodInYears) - 1) * 100
            : nil
        let annualizedVolatility: Double? = dailyReturns.count >= 2 ? volatility * sqrt(252) : nil

        let sortedReturns = dailyReturns.sorted()
        let var95Index = Int(Double(sortedReturns.count) * 0.05)
        let valueAtRisk = var95Index < sortedReturns.count ? abs(sortedReturns[var95Index] * 100) : nil

        let positiveReturns = dailyReturns.filter { $0 > 0 }.count
        let winRate = dailyReturns.isEmpty ? nil : Double(positiveReturns) / Double(dailyReturns.count) * 100

        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: currency,
            startDate: basePoint?.date ?? firstPoint.date,
            endDate: lastPoint.date,
            sharpeRatio: sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            beta: nil,
            annualizedReturn: annualizedReturn.flatMap { $0.isFinite ? $0 : nil },
            annualizedVolatility: annualizedVolatility,
            valueAtRisk: valueAtRisk,
            winRate: winRate
        )
    }

    /// Calculates maximum drawdown from a series of portfolio values
    private nonisolated static func calculateMaxDrawdown(values: [Double]) -> (maxDrawdown: Double?, maxDrawdownPercent: Double?) {
        guard values.count > 1, var peak = values.first else { return (nil, nil) }

        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        for currentValue in values {
            peak = max(peak, currentValue)
            let drawdown = peak - currentValue
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDrawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
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
        let stockSnapshots = aliasAwarePriceSnapshots(
            for: symbol,
            folyncSeriesKeys: folyncLineSeriesKeys(for: symbol, timeRange: timeRange, customFrom: nil, customTo: nil)
        )
        guard !stockSnapshots.isEmpty else { return nil }
        
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
        let currency = SymbolMetadata.defaultCurrency(for: symbol)
        
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
        
        // Stock history is bounded by resolution below, so a large total is
        // expected after long backfills. The total only sets how many session
        // portfolio snapshots (the fallback chart series) are kept.
        let targetLimit: Int
        if totalSnapshots > 40000 {
            targetLimit = 1500
        } else if totalSnapshots > 20000 {
            targetLimit = 2000
        } else {
            targetLimit = maxDataPoints
        }

        if portfolioSnapshots.count > targetLimit {
            let previousCount = portfolioSnapshots.count
            portfolioSnapshots = Array(portfolioSnapshots.suffix(targetLimit))
            Task {
                await logger.debug(
                    "📊 Trimmed session portfolio snapshots from \(previousCount) to \(targetLimit) (stock history total: \(totalSnapshots))"
                )
            }
        }

        // Bound stock history by resolution, not count, so long backfills survive.
        for symbol in priceSnapshots.keys {
            if let snapshots = priceSnapshots[symbol] {
                let thinned = Self.thinnedPriceHistory(snapshots)
                if thinned.count != snapshots.count {
                    priceSnapshots[symbol] = thinned
                    Task { await logger.debug("📊 Thinned \(symbol) from \(snapshots.count) to \(thinned.count) snapshots") }
                }
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
        let recentSnapshots = aliasAwarePriceSnapshots(for: symbol).suffix(10)
        
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

                // Core Data is the store of record; load each symbol's history.
                await self.reloadStoredPriceHistory()

                // Load portfolio snapshots from Core Data
                let coreDataPortfolioSnaps = Self.thinnedPortfolioHistory(
                    await loadPortfolioSnapshotsFromCoreData(timeRange: .all)
                )
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

        earliestAvailableDates = retrieveFromCache([String: Date].self, key: StorageKeys.earliestAvailableDates) ?? [:]
        if !earliestAvailableDates.isEmpty {
            Task { await logger.info("HistoricalDataManager: Loaded earliest available dates for \(earliestAvailableDates.count) symbols") }
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
                 StockbarRuntimeStorage.userDefaults.set(compositionData, forKey: StorageKeys.currentPortfolioComposition)
            } else if currentPortfolioComposition == nil { // Explicitly clear if nil
                 StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.currentPortfolioComposition)
            }
            StockbarRuntimeStorage.userDefaults.set(currentRetroactiveCalculationDate, forKey: StorageKeys.lastRetroactiveCalculationDate)
            StockbarRuntimeStorage.userDefaults.set(currentCalculationDate, forKey: StorageKeys.lastPortfolioCalculationDate)
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
        if !earliestAvailableDates.isEmpty {
            storeInCache(earliestAvailableDates, key: StorageKeys.earliestAvailableDates, isRecent: false)
        }
        
        Task { await logger.debug("HistoricalDataManager: Metadata saved to tiered cache.") }
    }

    // The old saveToTieredCache that handled snapshot arrays would need to be adjusted or removed
    // if snapshot arrays are no longer persisted this way.
    // For this subtask, we assume the new simpler one above.
    
    private func setupPeriodicSave() {
        // Save data every 30 minutes to avoid too frequent writes
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveHistoricalData()
            }
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
                if let snapshots = priceSnapshots[symbol] {
                    priceSnapshots[symbol] = Self.thinnedPriceHistory(snapshots)
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
        earliestAvailableDates.removeAll()
        
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.portfolioSnapshots)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.priceSnapshots)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.historicalPortfolioSnapshots)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.currentPortfolioComposition)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.lastRetroactiveCalculationDate)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.cachedHistoricalPortfolioValues)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.lastPortfolioCalculationDate)
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: StorageKeys.earliestAvailableDates)
        
        Task { await logger.info("Cleared all historical data including enhanced portfolio snapshots") }
    }
    
    func clearInconsistentData() {
        // Clear all portfolio snapshots since they were calculated with inconsistent methods
        portfolioSnapshots.removeAll()
        cachedHistoricalPortfolioValues.removeAll()
        lastPortfolioCalculationDate = Date.distantPast
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: "portfolioSnapshots")
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: "cachedHistoricalPortfolioValues")
        StockbarRuntimeStorage.userDefaults.removeObject(forKey: "lastPortfolioCalculationDate")
        Task { await logger.info("Cleared inconsistent portfolio historical data and cache - will rebuild with correct calculations") }
    }

    func earliestAvailableDate(for symbol: String) -> Date? {
        earliestAvailableDates[symbol.uppercased()]
    }

    func recordEarliestAvailableDate(_ date: Date, for symbol: String) {
        let key = symbol.uppercased()
        if let existing = earliestAvailableDates[key], existing >= date {
            return
        }
        earliestAvailableDates[key] = date
        storeInCache(earliestAvailableDates, key: StorageKeys.earliestAvailableDates, isRecent: false)
        Task { await logger.info("HistoricalDataManager: Recorded earliest available date for \(symbol): \(DateFormatter.debug.string(from: date))") }
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
        
        // Filter exact timestamp duplicates while preserving same-day backfills.
        let existingTimestampKeys = Set(
            priceSnapshots[symbol]?.map { snapshotTimestampKey($0.timestamp) } ?? []
        )

        Task { await logger.debug("🔍 DUPLICATE FILTER: \(symbol) has \(existingTimestampKeys.count) existing timestamps") }

        let newSnapshots = snapshots.filter { snapshot in
            !existingTimestampKeys.contains(snapshotTimestampKey(snapshot.timestamp))
        }
        
        Task { await logger.debug("🔍 DUPLICATE FILTER: Filtered \(snapshots.count) snapshots down to \(newSnapshots.count) new snapshots for \(symbol)") }
        
        if !newSnapshots.isEmpty {
            priceSnapshots[symbol]?.append(contentsOf: newSnapshots)
            
            // Sort by timestamp to maintain chronological order
            priceSnapshots[symbol]?.sort { $0.timestamp < $1.timestamp }
            
            if let current = priceSnapshots[symbol] {
                priceSnapshots[symbol] = Self.thinnedPriceHistory(current)
            }

            // Persist the imported history; saveHistoricalData stores metadata only.
            // The Core Data save skips timestamps it already has.
            let toPersist = newSnapshots
            Task { await self.savePriceSnapshotsToCoreData(toPersist) }
            saveHistoricalData()
            notePriceDataChanged(for: symbol)
            
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
        let input = HistoricalPortfolioCalculationInput(
            startDate: startDate,
            endDate: endDate,
            priceSnapshots: priceSnapshots,
            composition: createPortfolioComposition(from: dataModel),
            preferredCurrency: dataModel.preferredCurrency
        )
        let startTime = Date()
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)
        await logger.debug(
            "📊 PERIOD CALC: Generated \(snapshots.count) values from " +
            "\(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)) " +
            "off the main actor in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s"
        )
        return snapshots.map { ChartDataPoint(date: $0.date, value: $0.totalValue) }
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
        let currencyConverter = CurrencyConverter.shared
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
                    let symbolSnapshots = aliasAwarePriceSnapshots(for: symbol)
                    
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
        let currencyConverter = CurrencyConverter.shared
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
    
    func evictMemoryCachesForPressure(critical: Bool) {
        aliasHistoryCache.removeAll()
        stockDataCache.removeAll(keepingCapacity: false)
        stockDataCacheTimestamp.removeAll(keepingCapacity: false)
        cachedHistoricalPortfolioValues.removeAll(keepingCapacity: false)

        let retainedPoints = critical ? 450 : 900
        for symbol in Array(livePriceSamples.keys) {
            if let samples = livePriceSamples[symbol], samples.count > retainedPoints {
                livePriceSamples[symbol] = Array(samples.suffix(retainedPoints))
            }
        }
        if livePortfolioValueSamples.count > retainedPoints {
            livePortfolioValueSamples = Array(livePortfolioValueSamples.suffix(retainedPoints))
        }
        if livePortfolioGainSamples.count > retainedPoints {
            livePortfolioGainSamples = Array(livePortfolioGainSamples.suffix(retainedPoints))
        }
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
        StockbarRuntimeStorage.userDefaults.set(interval, forKey: Self.snapshotIntervalDefaultsKey)
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
    func getComprehensiveDataStatus() -> [ComprehensiveDataStatus] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        
        var status: [ComprehensiveDataStatus] = []
        
        for symbol in priceSnapshots.keys.sorted() {
            let dailyCount = priceSnapshots[symbol]?.count ?? 0
            let weeklyCount = 0 // No longer using tiered storage
            let monthlyCount = 0 // No longer using tiered storage
            
            // Find date range for this symbol
            let dates = priceSnapshots[symbol]?.map { $0.timestamp } ?? []
            
            let oldestDate = dates.min().map { formatter.string(from: $0) } ?? "No data"
            let newestDate = dates.max().map { formatter.string(from: $0) } ?? "No data"
            
            status.append(ComprehensiveDataStatus(
                symbol: symbol,
                daily: dailyCount,
                weekly: weeklyCount,
                monthly: monthlyCount,
                oldestDate: oldestDate,
                newestDate: newestDate
            ))
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
        let calculationManager = BackgroundCalculationManager.shared
        calculationManager.startCalculation(operation: "Portfolio History Calculation", totalOperations: 100)
        
        // Create current portfolio composition for tracking changes
        calculationManager.updateProgress(completed: 10, status: "Analyzing portfolio composition")
        let newComposition = createPortfolioComposition(from: dataModel)

        // Check if portfolio composition has changed
        calculationManager.updateProgress(completed: 20, status: "Checking for portfolio changes")
        let compositionChanged = hasPortfolioCompositionChanged(newComposition)
        let needsFullRecalculation = force || compositionChanged

        if needsFullRecalculation {
            if force {
                await logger.info("🔄 RETROACTIVE: Forced full recalculation requested")
            } else {
                await logger.info("🔄 RETROACTIVE: Portfolio composition changed - full recalculation needed")
            }
            
            calculationManager.updateProgress(completed: 30, status: "Starting full recalculation")
            await performFullPortfolioRecalculation(using: dataModel, composition: newComposition)
        } else {
            await logger.info("🔄 RETROACTIVE: Portfolio composition unchanged - incremental update")
            calculationManager.updateProgress(completed: 30, status: "Starting incremental update")
            await performIncrementalPortfolioUpdate(using: dataModel)
        }

        // Update composition tracking
        calculationManager.updateProgress(completed: 90, status: "Finalizing calculation")
        await MainActor.run {
            self.currentPortfolioComposition = newComposition
            self.lastRetroactiveCalculationDate = Date()
        }

        // Save updated data
        calculationManager.updateProgress(completed: 95, status: "Saving data")
        saveHistoricalData()

        // Complete the calculation
        calculationManager.completeCalculation()
        await logger.info("🔄 RETROACTIVE: Portfolio history calculation completed")
    }
    
    /// Creates portfolio composition from current DataModel
    private func createPortfolioComposition(from dataModel: DataModel) -> PortfolioComposition {
        let positions = dataModel.realTimeTrades.filter { !$0.trade.isWatchlistOnly }.map { trade in
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
        
        let calculationManager = BackgroundCalculationManager.shared
        
        // Find the earliest available historical data
        calculationManager.updateProgress(completed: 45, status: "Finding earliest data")
        let earliestDate = findEarliestHistoricalData()
        let endDate = Date()
        
        await logger.info("🔄 FULL RECALC: Calculating from \(DateFormatter.debug.string(from: earliestDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        // Calculate portfolio values for the entire historical period
        calculationManager.updateProgress(completed: 50, status: "Calculating portfolio values")
        let snapshots = await calculatePortfolioSnapshotsForPeriod(
            from: earliestDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        calculationManager.updateProgress(completed: 85, status: "Storing portfolio snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots = Self.mergePortfolioHistory(
                existing: self.historicalPortfolioSnapshots,
                recalculated: snapshots
            )
        }
        
        await logger.info("🔄 FULL RECALC: Generated \(snapshots.count) portfolio snapshots; history now holds \(historicalPortfolioSnapshots.count) (recorded days kept, gaps filled)")
    }
    
    /// Bounds in-memory price history by resolution instead of count: every
    /// point from the last `intradayDays` (enough for the 1M charts), then the last point of each earlier
    /// day. A newest-N cap let dense intraday samples push a multi-year daily
    /// backfill out of memory.
    nonisolated static func thinnedPriceHistory(
        _ snapshots: [PriceSnapshot],
        now: Date = Date(),
        intradayDays: Int = 31,
        calendar: Calendar = .current
    ) -> [PriceSnapshot] {
        let cutoff = now.addingTimeInterval(-Double(intradayDays) * 86_400)
        var result: [PriceSnapshot] = []
        var lastDay: Date?
        for snapshot in snapshots.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard snapshot.timestamp < cutoff else {
                result.append(snapshot)
                continue
            }
            let day = calendar.startOfDay(for: snapshot.timestamp)
            if day == lastDay {
                result[result.count - 1] = snapshot
            } else {
                result.append(snapshot)
                lastDay = day
            }
        }
        return result
    }

    /// Loads stored price history from Core Data for the given symbols (all
    /// stored symbols when nil), merging with anything recorded in memory since.
    func reloadStoredPriceHistory(for symbols: Set<String>? = nil) async {
        let targets: [String]
        if let symbols {
            targets = Array(symbols)
        } else {
            do {
                targets = try await coreDataService.fetchStoredPriceSymbols()
            } catch {
                await logger.error("❌ Could not list stored price history: \(error)")
                return
            }
        }
        var loadedCount = 0
        for symbol in targets {
            guard let stored = try? await coreDataService.fetchAllPriceSnapshots(for: symbol), !stored.isEmpty else { continue }
            let inMemory = priceSnapshots[symbol] ?? []
            let storedKeys = Set(stored.map { snapshotTimestampKey($0.timestamp) })
            let merged = stored + inMemory.filter { !storedKeys.contains(snapshotTimestampKey($0.timestamp)) }
            priceSnapshots[symbol] = Self.thinnedPriceHistory(merged)
            loadedCount += priceSnapshots[symbol]?.count ?? 0
            notePriceDataChanged(for: symbol)
        }
        await logger.info("HistoricalDataManager: Loaded stored price history for \(targets.count) symbols (\(loadedCount) points in memory)")
    }

    /// Recorded snapshots are the record of what the portfolio was actually
    /// worth, so a recalculation only fills calendar days that have none. It
    /// must never replace them: it is limited by the price history available
    /// and works from today's holdings, and replacing recorded days with it
    /// threw away intraday history and real past values.
    /// Days of portfolio history kept in memory at full resolution.
    nonisolated static let fullResolutionPortfolioDays = 90

    /// In-memory portfolio history: full resolution for the recent window, and
    /// the last snapshot of each day before it (about 40k snapshots a year are
    /// recorded). Core Data keeps every snapshot; this only bounds memory.
    nonisolated static func thinnedPortfolioHistory(
        _ snapshots: [HistoricalPortfolioSnapshot],
        fullResolutionDays: Int = fullResolutionPortfolioDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistoricalPortfolioSnapshot] {
        guard let cutoff = calendar.date(byAdding: .day, value: -fullResolutionDays, to: calendar.startOfDay(for: now)) else {
            return snapshots
        }
        let sorted = snapshots.sorted { $0.date < $1.date }
        var result: [HistoricalPortfolioSnapshot] = []
        result.reserveCapacity(sorted.count)
        for snapshot in sorted {
            if snapshot.date < cutoff, let last = result.last,
               calendar.isDate(last.date, inSameDayAs: snapshot.date),
               last.currency == snapshot.currency {
                result[result.count - 1] = snapshot
            } else {
                result.append(snapshot)
            }
        }
        return result
    }

    nonisolated static func mergePortfolioHistory(
        existing: [HistoricalPortfolioSnapshot],
        recalculated: [HistoricalPortfolioSnapshot],
        calendar: Calendar = .current
    ) -> [HistoricalPortfolioSnapshot] {
        let recordedDays = Set(existing.map { calendar.startOfDay(for: $0.date) })
        let fills = recalculated.filter { !recordedDays.contains(calendar.startOfDay(for: $0.date)) }
        return (existing + fills).sorted { $0.date < $1.date }
    }

    /// Performs incremental portfolio update for new dates only
    private func performIncrementalPortfolioUpdate(using dataModel: DataModel) async {
        let calculationManager = BackgroundCalculationManager.shared
        
        calculationManager.updateProgress(completed: 40, status: "Checking for new data")
        let lastCalculatedDate = getLastPortfolioSnapshotDate()
        let endDate = Date()
        
        // Only calculate if there's a meaningful gap (more than 1 day)
        guard endDate.timeIntervalSince(lastCalculatedDate) > 86400 else {
            await logger.debug("🔄 INCREMENTAL: No significant time gap, skipping update") 
            calculationManager.updateProgress(completed: 85, status: "No update needed")
            return
        }
        
        await logger.info("🔄 INCREMENTAL: Updating from \(DateFormatter.debug.string(from: lastCalculatedDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        guard let composition = currentPortfolioComposition else {
            await logger.warning("🔄 INCREMENTAL: Missing portfolio composition, skipping incremental update")
            calculationManager.updateProgress(completed: 85, status: "No portfolio composition")
            return
        }

        calculationManager.updateProgress(completed: 50, status: "Calculating new portfolio values")
        let newSnapshots = await calculatePortfolioSnapshotsForPeriod(
            from: lastCalculatedDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        calculationManager.updateProgress(completed: 80, status: "Adding new snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots.append(contentsOf: newSnapshots)
            self.historicalPortfolioSnapshots.sort { $0.date < $1.date }
            // No count cap here: trimming to the newest points threw away the
            // long-range history the 1M/1Y/All charts and risk metrics read.
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
        let input = HistoricalPortfolioCalculationInput(
            startDate: startDate,
            endDate: endDate,
            priceSnapshots: priceSnapshots,
            composition: composition,
            preferredCurrency: dataModel.preferredCurrency
        )
        let startTime = Date()
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)
        await logger.info(
            "🔄 CALC PERIOD: Generated \(snapshots.count) portfolio snapshots off the main actor in " +
            "\(String(format: "%.2f", Date().timeIntervalSince(startTime)))s"
        )
        return snapshots
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
    func getStoredPortfolioValues(
        for timeRange: ChartTimeRange,
        currency: String? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo)
        let startDate = bounds.start

        // Debug logging
        Task { await logger.debug("📊 GET PORTFOLIO VALUES: totalSnapshots=\(historicalPortfolioSnapshots.count), startDate=\(startDate), timeRange=\(timeRange.rawValue)") }

        let values = storedAndLivePortfolioValues(from: startDate, to: bounds.end, currency: currency)

        Task { await logger.debug("📊 GET PORTFOLIO VALUES: filteredCount=\(values.count)") }

        return values
    }
    
    /// Gets stored portfolio gains for chart display
    func getStoredPortfolioGains(
        for timeRange: ChartTimeRange,
        currency: String? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo)

        let storedGains = portfolioSnapshots(in: currency)
            .filter { $0.date >= bounds.start && $0.date <= bounds.end }
            .map { snapshot in
                ChartDataPoint(date: snapshot.date, value: snapshot.totalGains)
            }
        let liveGains = liveSamplesMatch(currency)
            ? livePortfolioGainSamples.filter { $0.date >= bounds.start && $0.date <= bounds.end }
            : []

        return deduplicatedSortedChartPoints(storedGains + liveGains)
    }
    
    /// Pure read of sorted history. Display formatting must never start provider work.
    /// Pass `timeRange` to read the Folync overlay for that range when one
    /// exists; without it only local history is returned.
    func getPriceSnapshots(
        for symbol: String,
        from startDate: Date,
        to endDate: Date = Date(),
        timeRange: ChartTimeRange? = nil
    ) -> [PriceSnapshot] {
        let seriesKeys = timeRange.map {
            folyncLineSeriesKeys(for: symbol, timeRange: $0, customFrom: nil, customTo: nil)
        }
        return aliasAwarePriceSnapshots(for: symbol, folyncSeriesKeys: seriesKeys)
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Chart consumers explicitly request missing history after reading their current slice.
    func requestPriceHistoryIfNeeded(
        for symbol: String,
        timeRange: ChartTimeRange,
        from startDate: Date,
        to endDate: Date,
        availablePointCount: Int,
        coversRange: Bool = true,
        force: Bool = false
    ) {
        let folyncEnabled = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        guard force || folyncEnabled || availablePointCount < 10 || !coversRange else { return }
        schedulePriceHistoryFetchIfNeeded(
            for: symbol, timeRange: timeRange, startDate: startDate, endDate: endDate, force: force
        )
    }

    /// Whether sorted snapshots start near the beginning of the range (within
    /// a fifth of its length), so plenty of recent points cannot hide a gap.
    nonisolated static func snapshotsReachRangeStart(_ snapshots: [PriceSnapshot], from startDate: Date, to endDate: Date) -> Bool {
        guard let first = snapshots.first else { return false }
        let slack = endDate.timeIntervalSince(startDate) * 0.2
        return first.timestamp <= startDate.addingTimeInterval(slack)
    }

    func folyncSourceStatus(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> FolyncSupplementalSourceStatus? {
        folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        ).compactMap { folyncSourceStatusBySeries[$0] }.first
    }

    func folyncCoverage(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> String? {
        folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        ).compactMap { folyncCoverageBySeries[$0] }.first
    }

    func folyncPortfolioSourceStatus(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> FolyncSupplementalSourceStatus? {
        folyncSourceStatusBySeries[folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )]
    }

    func folyncPortfolioCoverage(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> String? {
        folyncCoverageBySeries[folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )]
    }

    func clearFolyncSupplementalOverlays() {
        folyncPriceOverlays.removeAll()
        folyncUnavailableSeries.removeAll()
        folyncPortfolioHistoryContexts.removeAll()
        folyncPortfolioHistoryFetchRequestTimes.removeAll()
        folyncPortfolioValueOverlays.removeAll()
        folyncPortfolioGainOverlays.removeAll()
        folyncSourceStatusBySeries.removeAll()
        folyncCoverageBySeries.removeAll()
        stockDataCache.removeAll()
        stockDataCacheTimestamp.removeAll()
        folyncSupplementalConfigurationRevision &+= 1
        notePriceDataRevision(changed: nil)
    }

    func noteFolyncSupplementalConfigurationChanged() {
        folyncSupplementalConfigurationRevision &+= 1
        notePriceDataRevision(changed: nil)
    }

    func shouldFetchMenuPriceHistory(
        for symbol: String,
        from startDate: Date,
        to endDate: Date = Date(),
        minimumPoints: Int = 10
    ) -> Bool {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbolKey.isEmpty, minimumPoints > 0 else { return false }

        let snapshotCount = getPriceSnapshots(for: symbolKey, from: startDate, to: endDate).count

        return snapshotCount < minimumPoints
    }

    private struct PortfolioMenuPosition {
        let symbol: String
        let units: Double
        let currency: String
        let currentPrice: Double
        let currentValueInPreferredCurrency: Double
    }

    private func storedAndLivePortfolioValues(from startDate: Date, to endDate: Date, currency: String?) -> [ChartDataPoint] {
        let storedValues = portfolioSnapshots(in: currency)
            .filter { $0.date >= startDate && $0.date <= endDate }
            .map { snapshot in
                ChartDataPoint(date: snapshot.date, value: snapshot.totalValue)
            }
        let liveValues = liveSamplesMatch(currency)
            ? livePortfolioValueSamples.filter { $0.date >= startDate && $0.date <= endDate }
            : []
        return deduplicatedSortedChartPoints(storedValues + liveValues)
    }

    /// Stored snapshots in `currency`, or all of them when no currency is given.
    private func portfolioSnapshots(in currency: String?) -> [HistoricalPortfolioSnapshot] {
        guard let currency else { return historicalPortfolioSnapshots }
        return historicalPortfolioSnapshots.filter { $0.currency.uppercased() == currency.uppercased() }
    }

    /// Whether the live samples can join a series in `currency`. With no
    /// currency given, the stored snapshots' latest currency decides.
    private func liveSamplesMatch(_ currency: String?) -> Bool {
        guard let sampleCurrency = livePortfolioSampleCurrency,
              let seriesCurrency = currency ?? historicalPortfolioSnapshots.last?.currency else {
            return true
        }
        return sampleCurrency.uppercased() == seriesCurrency.uppercased()
    }

    private func portfolioMenuPositions(
        from currentTrades: [RealTimeTrade],
        preferredCurrency: String
    ) -> [PortfolioMenuPosition] {
        let converter = CurrencyConverter.shared

        return currentTrades.compactMap { realTimeTrade -> PortfolioMenuPosition? in
            let trade = realTimeTrade.trade
            guard !trade.isWatchlistOnly else { return nil }

            let symbol = trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let units = trade.position.unitSize
            let currentPrice = realTimeTrade.realTimeInfo.getCurrentDisplayPrice()
            guard !symbol.isEmpty,
                  units.isFinite,
                  units > 0,
                  currentPrice.isFinite,
                  currentPrice > 0 else {
                return nil
            }

            let currency = portfolioMenuDisplayCurrency(for: realTimeTrade)
            let currentValue = convertPortfolioMenuValue(
                amount: currentPrice * units,
                from: currency,
                to: preferredCurrency,
                converter: converter
            )
            guard currentValue.isFinite, currentValue > 0 else {
                return nil
            }

            return PortfolioMenuPosition(
                symbol: symbol,
                units: units,
                currency: currency,
                currentPrice: currentPrice,
                currentValueInPreferredCurrency: currentValue
            )
        }
    }

    private func syntheticPortfolioMenuValues(
        positions: [PortfolioMenuPosition],
        preferredCurrency: String,
        startDate: Date,
        endDate: Date
    ) -> [ChartDataPoint] {
        let snapshotsBySymbol = Dictionary(firstValuesFor: positions.map { position in
            (
                position.symbol,
                allPortfolioMenuPriceSnapshots(for: position.symbol)
                    .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            )
        })

        let candidateDates = latestDatesPerBucket(
            snapshotsBySymbol.values.flatMap { snapshots in snapshots.map(\.timestamp) },
            bucketSize: 120
        )
        guard !candidateDates.isEmpty else { return [] }

        let converter = CurrencyConverter.shared
        let totalCurrentValue = positions
            .map(\.currentValueInPreferredCurrency)
            .reduce(0, +)
        guard totalCurrentValue.isFinite, totalCurrentValue > 0 else { return [] }

        let minimumCoveredPositionCount = max(1, Int(ceil(Double(positions.count) * 0.5)))
        let tolerance: TimeInterval = 10 * 60

        return candidateDates.compactMap { candidateDate in
            var coveredPositionCount = 0
            var coveredCurrentValue = 0.0
            var syntheticValue = 0.0

            for position in positions {
                guard let snapshots = snapshotsBySymbol[position.symbol],
                      let snapshot = latestSnapshot(in: snapshots, atOrBefore: candidateDate, tolerance: tolerance) else {
                    continue
                }

                let price = normalizedPortfolioMenuPrice(
                    snapshot.price,
                    currentPrice: position.currentPrice,
                    symbol: position.symbol
                )
                guard price.isFinite, price > 0 else {
                    continue
                }

                let positionValue = convertPortfolioMenuValue(
                    amount: price * position.units,
                    from: position.currency,
                    to: preferredCurrency,
                    converter: converter
                )
                guard positionValue.isFinite, positionValue > 0 else {
                    continue
                }

                coveredPositionCount += 1
                coveredCurrentValue += position.currentValueInPreferredCurrency
                syntheticValue += positionValue
            }

            guard coveredPositionCount >= minimumCoveredPositionCount,
                  coveredCurrentValue / totalCurrentValue >= 0.7,
                  syntheticValue.isFinite,
                  syntheticValue > 0 else {
                return nil
            }

            return ChartDataPoint(date: candidateDate, value: syntheticValue)
        }
    }

    private func schedulePortfolioMenuHistoryFetchesIfNeeded(
        currentTrades: [RealTimeTrade],
        startDate: Date,
        endDate: Date,
        syntheticPointCount: Int
    ) {
        guard syntheticPointCount < 6 else { return }

        let candidates = portfolioMenuHistoryFetchCandidates(
            currentTrades: currentTrades,
            startDate: startDate,
            endDate: endDate
        )

        for symbol in candidates {
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: .day,
                startDate: startDate,
                endDate: endDate
            )
        }
    }

    private func schedulePriceHistoryFetchIfNeeded(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date = Date(),
        force: Bool = false
    ) {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbolKey.isEmpty else { return }
        let configurationRevision = folyncSupplementalConfigurationRevision
        let customKey = timeRange == .custom
            ? "|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"
            : ""
        let requestKey = "price|\(symbolKey)|\(timeRange.rawValue)\(customKey)|revision:\(configurationRevision)"

        priceHistoryScheduler.schedule(key: requestKey, force: force) { [weak self] in
            guard let self else { return .cancelled }
            return await self.triggerHistoricalDataFetch(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate,
                folyncConfigurationRevision: configurationRevision
            )
        }
    }

    private func allPortfolioMenuPriceSnapshots(for symbol: String) -> [PriceSnapshot] {
        aliasAwarePriceSnapshots(for: symbol)
    }

    private func latestSnapshot(
        in snapshots: [PriceSnapshot],
        atOrBefore date: Date,
        tolerance: TimeInterval
    ) -> PriceSnapshot? {
        guard !snapshots.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = snapshots.count - 1
        var candidate: PriceSnapshot?

        while lowerBound <= upperBound {
            let middle = (lowerBound + upperBound) / 2
            let snapshot = snapshots[middle]

            if snapshot.timestamp <= date {
                candidate = snapshot
                lowerBound = middle + 1
            } else {
                upperBound = middle - 1
            }
        }

        guard let candidate,
              date.timeIntervalSince(candidate.timestamp) <= tolerance else {
            return nil
        }
        return candidate
    }

    private func latestDatesPerBucket(_ dates: [Date], bucketSize: TimeInterval) -> [Date] {
        guard bucketSize > 0, !dates.isEmpty else { return dates.sorted() }

        var latestByBucket: [Int: Date] = [:]
        for date in dates {
            let bucket = Int(floor(date.timeIntervalSince1970 / bucketSize))
            if let existing = latestByBucket[bucket], existing > date {
                continue
            }
            latestByBucket[bucket] = date
        }

        return latestByBucket.keys.sorted().compactMap { latestByBucket[$0] }
    }

    private func normalizedPortfolioMenuPrice(
        _ price: Double,
        currentPrice: Double,
        symbol: String
    ) -> Double {
        UKPriceScale.normalized(price, reference: currentPrice, symbol: symbol)
    }

    private func portfolioMenuDisplayCurrency(for realTimeTrade: RealTimeTrade) -> String {
        let symbol = realTimeTrade.trade.name
        let currency = realTimeTrade.realTimeInfo.currency
            ?? realTimeTrade.trade.position.currency
            ?? realTimeTrade.trade.position.costCurrency
            ?? "USD"

        if SymbolMetadata.isUKSymbol(symbol),
           ["GBX", "GBPENCE", "GBPENNY", "GBPEN"].contains(currency.uppercased()) || currency == "GBp" {
            return "GBP"
        }

        return currency
    }

    private func convertPortfolioMenuValue(
        amount: Double,
        from currency: String,
        to preferredCurrency: String,
        converter: CurrencyConverter
    ) -> Double {
        let normalizedCurrency = currency.uppercased()
        let normalizedPreferredCurrency = preferredCurrency.uppercased()

        let amountInUSD: Double
        if normalizedCurrency == "USD" {
            amountInUSD = amount
        } else if normalizedCurrency == "GBX" || normalizedCurrency == "GBPENCE" || currency == "GBp" {
            amountInUSD = converter.convert(amount: amount / 100.0, from: "GBP", to: "USD")
        } else {
            amountInUSD = converter.convert(amount: amount, from: currency, to: "USD")
        }

        if normalizedPreferredCurrency == "USD" {
            return amountInUSD
        }
        if normalizedPreferredCurrency == "GBX" || normalizedPreferredCurrency == "GBPENCE" || preferredCurrency == "GBp" {
            return converter.convert(amount: amountInUSD, from: "USD", to: "GBP") * 100.0
        }
        return converter.convert(amount: amountInUSD, from: "USD", to: preferredCurrency)
    }

    private func storedPriceSnapshots(for symbol: String) -> [PriceSnapshot] {
        if let snapshots = priceSnapshots[symbol] {
            return snapshots
        }

        let normalizedSymbol = symbol.uppercased()
        return priceSnapshots.first { $0.key.uppercased() == normalizedSymbol }?.value ?? []
    }

    private func livePriceSamples(for symbol: String) -> [PriceSnapshot] {
        if let samples = livePriceSamples[symbol] {
            return samples
        }

        let normalizedSymbol = symbol.uppercased()
        return livePriceSamples.first { $0.key.uppercased() == normalizedSymbol }?.value ?? []
    }

    private func aliasAwarePriceSnapshots(
        for symbol: String,
        folyncSeriesKeys requestedSeriesKeys: Set<String>? = nil
    ) -> [PriceSnapshot] {
        let aliases = instrumentAliasStore.aliases(for: symbol)
        // Folync overlays are per range. Without the caller's range there is no
        // way to know which overlay applies, so range-less reads use local data
        // (the most recently fetched overlay could be any range).
        let seriesKeys = requestedSeriesKeys ?? []
        if let overlay = seriesKeys.compactMap({ folyncPriceOverlays[$0] }).first {
            return overlay
        }
        if !seriesKeys.isDisjoint(with: folyncUnavailableSeries) {
            return []
        }
        let stored = priceSnapshots
        let live = livePriceSamples
        return aliasHistoryCache.snapshots(for: normalizedSeriesKey(symbol), aliases: aliases) {
            InstrumentAliasHistoryLookup.combinedSnapshots(
                for: symbol, aliases: aliases, storedBySymbol: stored, liveBySymbol: live
            )
        }
    }

    private func setFolyncPriceOverlay(
        _ snapshots: [PriceSnapshot],
        identity: FolyncInstrumentIdentity,
        requestedSymbol: String,
        status: FolyncSupplementalSourceStatus,
        metadata: FolyncSeriesMetadata,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set((identity.aliases + [
            identity.canonicalTicker,
            identity.displayTicker,
            identity.quoteSymbol,
            requestedSymbol
        ]).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays[key] = snapshots
            folyncUnavailableSeries.remove(key)
            folyncSourceStatusBySeries[key] = status
            folyncCoverageBySeries[key] = metadata.coverageLabel
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    private func markFolyncSeriesUnavailable(
        _ symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays.removeValue(forKey: key)
            folyncUnavailableSeries.insert(key)
            folyncSourceStatusBySeries[key] = .unavailable
            folyncCoverageBySeries.removeValue(forKey: key)
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    private func clearFolyncPriceOverlayForLegacy(
        _ symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let aliases = Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map(normalizedSeriesKey))
        for alias in aliases {
            let key = FolyncLineSeriesKey(
                symbol: alias,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
            folyncPriceOverlays.removeValue(forKey: key)
            folyncUnavailableSeries.remove(key)
            folyncSourceStatusBySeries[key] = .legacy
            folyncCoverageBySeries.removeValue(forKey: key)
            invalidateStockDataCache(for: alias)
        }
        notePriceDataRevision(changed: aliases)
    }

    private func folyncLineSeriesKeys(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) -> Set<String> {
        Set(([symbol] + instrumentAliasStore.aliases(for: symbol)).map {
            FolyncLineSeriesKey(
                symbol: $0,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            ).storageKey
        })
    }

    private func normalizedSeriesKey(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func folyncPortfolioOverlay(
        kind: String,
        timeRange: ChartTimeRange,
        dataModel: DataModel?,
        customFrom: Date?,
        customTo: Date?
    ) -> [ChartDataPoint]? {
        guard dataModel?.isFolyncPortfolioActive == true else { return nil }
        let key = folyncPortfolioSeriesKey(
            kind: kind,
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        let expectedScope = dataModel?.folyncPortfolioSnapshot?.scope.id ?? FolyncSettingsStore.shared.load().scopeID
        let expectedCurrency = dataModel?.preferredCurrency ?? "USD"
        let context = "\(expectedScope)|\(expectedCurrency)|\(timeRange.folyncRange)"
        if folyncPortfolioHistoryContexts[key] != context {
            folyncPortfolioValueOverlays.removeValue(forKey: key)
            folyncPortfolioGainOverlays.removeValue(forKey: key)
        }
        scheduleFolyncPortfolioHistoryIfNeeded(
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo, expectedScope: expectedScope, expectedCurrency: expectedCurrency
        )
        if let overlay = kind == "portfolio-value"
            ? folyncPortfolioValueOverlays[key]
            : folyncPortfolioGainOverlays[key] {
            return overlay
        }
        if folyncUnavailableSeries.contains(key) { return [] }
        if folyncSourceStatusBySeries[key] == .legacy { return [] }
        // An enabled Folync route owns the whole series while its first request
        // is pending; do not flash or splice the pre-existing local series.
        return []
    }

    private func scheduleFolyncPortfolioHistoryIfNeeded(
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?, expectedScope: String, expectedCurrency: String
    ) {
        let customKey = timeRange == .custom
            ? "|\(customFrom?.timeIntervalSince1970 ?? 0)|\(customTo?.timeIntervalSince1970 ?? 0)"
            : ""
        let key = "portfolio|\(expectedScope)|\(expectedCurrency)|\(timeRange.folyncRange)\(customKey)"
        let now = Date()
        if let lastRequest = folyncPortfolioHistoryFetchRequestTimes[key],
           now.timeIntervalSince(lastRequest) < menuPriceHistoryFetchCooldown {
            return
        }
        folyncPortfolioHistoryFetchRequestTimes[key] = now
        let configurationRevision = folyncSupplementalConfigurationRevision
        Task { [weak self] in
            guard let self else { return }
            let result = await FolyncSupplementalCoordinator.shared.routePortfolioHistory(
                range: timeRange.folyncRange,
                from: timeRange == .custom ? customFrom : nil,
                to: timeRange == .custom ? customTo : nil
            )
            guard configurationRevision == self.folyncSupplementalConfigurationRevision else { return }
            let validated: FolyncRoutedPortfolioResult
            if case .folync(let history, _) = result,
               (history.scope.id != expectedScope || history.currency?.uppercased() != expectedCurrency.uppercased()
                || history.range != (timeRange == .custom ? "custom" : timeRange.folyncRange)) {
                validated = .unavailable
            } else { validated = result }
            self.applyFolyncPortfolioHistory(
                validated,
                timeRange: timeRange,
                customFrom: customFrom,
                customTo: customTo
            )
        }
    }

    private func applyFolyncPortfolioHistory(
        _ result: FolyncRoutedPortfolioResult,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) {
        let valueKey = folyncPortfolioSeriesKey(
            kind: "portfolio-value",
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        let gainKey = folyncPortfolioSeriesKey(
            kind: "portfolio-gain",
            timeRange: timeRange,
            customFrom: customFrom,
            customTo: customTo
        )
        switch result {
        case .folync(let history, let status):
            let context = "\(history.scope.id)|\(history.currency ?? "")|\(timeRange.folyncRange)"
            folyncPortfolioHistoryContexts[valueKey] = context
            folyncPortfolioHistoryContexts[gainKey] = context
            let values = history.portfolioSeries.compactMap(Self.chartPoint).sorted { $0.date < $1.date }
            let gains = history.gainSeries.compactMap(Self.chartPoint).sorted { $0.date < $1.date }
            folyncPortfolioValueOverlays[valueKey] = values
            folyncPortfolioGainOverlays[gainKey] = gains
            folyncUnavailableSeries.remove(valueKey)
            folyncUnavailableSeries.remove(gainKey)
            folyncSourceStatusBySeries[valueKey] = status
            folyncSourceStatusBySeries[gainKey] = status
            let completeness = history.coverage.complete.map { $0 ? "complete coverage" : "partial coverage" } ?? "coverage unavailable"
            let coverage = "\(history.coverage.pointCount) points · \(history.interval) · \(completeness)"
            folyncCoverageBySeries[valueKey] = coverage
            folyncCoverageBySeries[gainKey] = coverage
        case .unavailable:
            folyncPortfolioValueOverlays.removeValue(forKey: valueKey)
            folyncPortfolioGainOverlays.removeValue(forKey: gainKey)
            folyncUnavailableSeries.insert(valueKey)
            folyncUnavailableSeries.insert(gainKey)
            folyncSourceStatusBySeries[valueKey] = .unavailable
            folyncSourceStatusBySeries[gainKey] = .unavailable
            folyncCoverageBySeries.removeValue(forKey: valueKey)
            folyncCoverageBySeries.removeValue(forKey: gainKey)
        case .legacy:
            folyncPortfolioValueOverlays.removeValue(forKey: valueKey)
            folyncPortfolioGainOverlays.removeValue(forKey: gainKey)
            folyncUnavailableSeries.remove(valueKey)
            folyncUnavailableSeries.remove(gainKey)
            folyncSourceStatusBySeries[valueKey] = .legacy
            folyncSourceStatusBySeries[gainKey] = .legacy
            folyncCoverageBySeries.removeValue(forKey: valueKey)
            folyncCoverageBySeries.removeValue(forKey: gainKey)
        }
        portfolioHistoryRevision &+= 1
    }

    private func folyncPortfolioSeriesKey(
        kind: String,
        timeRange: ChartTimeRange,
        customFrom: Date?,
        customTo: Date?
    ) -> String {
        let bounds = timeRange == .custom
            ? "|\(customFrom.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0)|\(customTo.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0)"
            : ""
        return "\(kind)|\(timeRange.folyncRange)\(bounds)"
    }

    private static func chartPoint(_ point: FolyncPortfolioHistory.SeriesPoint) -> ChartDataPoint? {
        let date = FolyncSupplementalDateParser.instant(point.date)
            ?? FolyncSupplementalDateParser.day(point.date)
        guard let date, point.value.isFinite else { return nil }
        return ChartDataPoint(date: date, value: point.value)
    }

    private func notePriceDataChanged(for symbol: String) {
        invalidateStockDataCache(for: symbol)
        notePriceDataRevision(changed: [symbol])
    }

    private func notePriceDataRevision(changed symbols: Set<String>?) {
        let keys = symbols.map { symbols in
            Set(symbols.flatMap { [$0] + instrumentAliasStore.aliases(for: $0) }.map(normalizedSeriesKey))
        }
        priceDataRevision &+= 1
        priceDataChanges.send(keys)
    }

    /// Count and latest timestamp of the in-memory price series for `symbols`
    /// and their aliases. Changes when any of those series gains or loses points.
    func priceSeriesFingerprint(for symbols: [String]) -> [String] {
        let wanted = Set(symbols.flatMap { [$0] + instrumentAliasStore.aliases(for: $0) }.map(normalizedSeriesKey))
        return priceSnapshots
            .filter { wanted.contains(normalizedSeriesKey($0.key)) }
            .map { key, snapshots in
                "\(key)|\(snapshots.count)|\(snapshots.last?.timestamp.timeIntervalSince1970 ?? 0)"
            }
            .sorted()
    }

    /// True when a `priceDataChanges` value can affect any of `symbols` (or
    /// their aliases). A nil change affects everything.
    func priceDataChange(_ changed: Set<String>?, affects symbols: [String]) -> Bool {
        guard let changed else { return true }
        return symbols.contains { symbol in
            ([symbol] + instrumentAliasStore.aliases(for: symbol))
                .contains { changed.contains(normalizedSeriesKey($0)) }
        }
    }

    /// Drops in-memory price data for symbols whose stored snapshots changed
    /// underneath (e.g. after a data migration) so every view reloads them.
    func invalidatePriceData(for symbols: Set<String>) {
        guard !symbols.isEmpty else { return }
        let keys = Set(symbols.map { $0.uppercased() })
        for key in priceSnapshots.keys where keys.contains(key.uppercased()) {
            priceSnapshots.removeValue(forKey: key)
        }
        symbols.forEach { invalidateStockDataCache(for: $0) }
        notePriceDataRevision(changed: symbols)
    }

    private func invalidateStockDataCache(for symbol: String) {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedSymbol.isEmpty else { return }

        let matchingKeys = stockDataCache.keys.filter { cacheKey in
            cacheKey.uppercased().hasPrefix("\(normalizedSymbol)-")
        }

        for cacheKey in matchingKeys {
            stockDataCache.removeValue(forKey: cacheKey)
            stockDataCacheTimestamp.removeValue(forKey: cacheKey)
        }
    }

    private func snapshotTimestampKey(_ timestamp: Date) -> Int64 {
        Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
    }

    private func appendLivePortfolioPoint(
        _ point: ChartDataPoint,
        to points: [ChartDataPoint],
        timestamp: Date
    ) -> [ChartDataPoint] {
        var updatedPoints = points
        if let last = updatedPoints.last, abs(last.date.timeIntervalSince(timestamp)) < 1 {
            updatedPoints[updatedPoints.count - 1] = point
        } else {
            updatedPoints.append(point)
        }

        let cutoff = timestamp.addingTimeInterval(-livePriceSampleRetention)
        updatedPoints = updatedPoints
            .filter { $0.date >= cutoff && $0.value.isFinite }
            .sorted { $0.date < $1.date }

        if updatedPoints.count > maxLivePortfolioSamples {
            updatedPoints = Array(updatedPoints.suffix(maxLivePortfolioSamples))
        }

        return updatedPoints
    }

    private func deduplicatedSortedChartPoints(_ points: [ChartDataPoint]) -> [ChartDataPoint] {
        var latestByTimestamp: [Int64: ChartDataPoint] = [:]
        for point in points where point.value.isFinite {
            let key = Int64((point.date.timeIntervalSince1970 * 1_000).rounded())
            latestByTimestamp[key] = point
        }
        return latestByTimestamp.values.sorted { $0.date < $1.date }
    }

    private func deduplicatedSortedSnapshots(_ snapshots: [PriceSnapshot]) -> [PriceSnapshot] {
        var latestByTimestamp: [Int64: PriceSnapshot] = [:]
        for snapshot in snapshots where snapshot.price.isFinite && snapshot.price > 0 {
            let key = Int64((snapshot.timestamp.timeIntervalSince1970 * 1_000).rounded())
            latestByTimestamp[key] = snapshot
        }
        return latestByTimestamp.values.sorted { $0.timestamp < $1.timestamp }
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
