import Foundation
import Combine

/// Memory-optimized data model that reduces memory footprint through intelligent caching
class MemoryOptimizedDataModel: ObservableObject {
    
    // MARK: - Memory Management Configuration
    
    private struct MemoryLimits {
        static let maxRealTimeTradesInMemory = 50
        static let maxCachedSymbolsData = 20
        static let cacheCleanupInterval: TimeInterval = 300 // 5 minutes
        static let memoryWarningThreshold = 100_000_000 // 100MB
    }
    
    // MARK: - Properties
    
    private let logger = Logger.shared
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var cacheCleanupTimer: Timer?
    private var lastMemoryWarning = Date.distantPast
    
    // Cache tracking
    private var symbolAccessTimes: [String: Date] = [:]
    private var cacheSize: [String: Int] = [:]
    private var totalCacheSize = 0
    
    // MARK: - Initialization
    
    init() {
        setupMemoryPressureMonitoring()
        setupPeriodicCacheCleanup()
    }
    
    deinit {
        memoryPressureSource?.cancel()
        cacheCleanupTimer?.invalidate()
    }
    
    // MARK: - Memory Pressure Monitoring
    
    private func setupMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        memoryPressureSource?.setEventHandler { [weak self] in
            Task {
                await self?.handleMemoryPressure()
            }
        }
        
        memoryPressureSource?.resume()
    }
    
    private func handleMemoryPressure() async {
        await logger.warning("⚠️ Memory pressure detected - performing cleanup")
        
        let now = Date()
        guard now.timeIntervalSince(lastMemoryWarning) > 30 else {
            await logger.debug("Skipping memory cleanup - too recent")
            return
        }
        
        lastMemoryWarning = now
        
        // Perform aggressive cache cleanup
        await performMemoryCleanup(aggressive: true)
    }
    
    // MARK: - Cache Management
    
    private func setupPeriodicCacheCleanup() {
        cacheCleanupTimer = Timer.scheduledTimer(withTimeInterval: MemoryLimits.cacheCleanupInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.performPeriodicCleanup()
            }
        }
    }
    
    private func performPeriodicCleanup() async {
        await performMemoryCleanup(aggressive: false)
    }
    
    private func performMemoryCleanup(aggressive: Bool) async {
        let threshold = aggressive ? 0.5 : 0.8 // Clean more aggressively under pressure
        
        await logger.debug("🧹 Starting cache cleanup (aggressive: \(aggressive))")
        
        // Sort symbols by last access time (least recently used first)
        let sortedSymbols = symbolAccessTimes.sorted { $0.value < $1.value }
        
        // Calculate how many symbols to evict
        let maxSymbols = aggressive ? MemoryLimits.maxCachedSymbolsData / 2 : MemoryLimits.maxCachedSymbolsData
        let symbolsToEvict = max(0, sortedSymbols.count - maxSymbols)
        
        if symbolsToEvict > 0 {
            let evictedSymbols = Array(sortedSymbols.prefix(symbolsToEvict))
            
            for (symbol, _) in evictedSymbols {
                evictSymbolFromCache(symbol)
            }
            
            await logger.info("Evicted \(symbolsToEvict) symbols from cache")
        }
        
        // Clean up other caches
        await cleanupHistoricalDataCache(aggressive: aggressive)
        
        // Log memory usage
        await logMemoryUsage()
    }
    
    private func evictSymbolFromCache(_ symbol: String) {
        symbolAccessTimes.removeValue(forKey: symbol)
        if let size = cacheSize.removeValue(forKey: symbol) {
            totalCacheSize -= size
        }
        
        // Notify other components to clean up this symbol's data
        NotificationCenter.default.post(
            name: .symbolEvictedFromCache,
            object: nil,
            userInfo: ["symbol": symbol]
        )
    }
    
    private func cleanupHistoricalDataCache(aggressive: Bool) async {
        // Use CacheManager to clean up historical data caches
        if aggressive {
            CacheManager.shared.clearMemoryCache()
        } else {
            CacheManager.shared.performMaintenance()
        }
    }
    
    // MARK: - Memory Usage Tracking
    
    func trackSymbolAccess(_ symbol: String, dataSize: Int = 0) {
        symbolAccessTimes[symbol] = Date()
        
        if dataSize > 0 {
            let oldSize = cacheSize[symbol] ?? 0
            cacheSize[symbol] = dataSize
            totalCacheSize = totalCacheSize - oldSize + dataSize
        }
        
        // Check if we need to cleanup
        if totalCacheSize > MemoryLimits.memoryWarningThreshold {
            Task {
                await performMemoryCleanup(aggressive: false)
            }
        }
    }
    
    private func logMemoryUsage() async {
        let memoryInfo = mach_task_basic_info()
        
        let memoryUsage = Double(memoryInfo.resident_size) / 1024 / 1024 // MB
        await logger.debug("📊 Memory usage: \(String(format: "%.1f", memoryUsage)) MB, Cache symbols: \(symbolAccessTimes.count), Cache size: \(totalCacheSize / 1024 / 1024) MB")
    }
    
    // MARK: - Smart Data Loading
    
    func loadDataIntelligently(for symbols: [String], timeRange: ChartTimeRange) async -> [String: [PriceSnapshot]] {
        let maxSymbolsToLoad = min(symbols.count, MemoryLimits.maxCachedSymbolsData)
        let symbolsToLoad = Array(symbols.prefix(maxSymbolsToLoad))
        
        await logger.info("Loading data for \(symbolsToLoad.count) symbols (limited from \(symbols.count))")
        
        var results: [String: [PriceSnapshot]] = [:]
        
        // Load data in batches to prevent memory spikes
        let batchSize = 5
        let batches = symbolsToLoad.chunked(into: batchSize)
        
        for batch in batches {
            await withTaskGroup(of: (String, [PriceSnapshot]).self) { group in
                for symbol in batch {
                    group.addTask {
                        await self.loadSymbolData(symbol: symbol, timeRange: timeRange)
                    }
                }
                
                for await (symbol, snapshots) in group {
                    results[symbol] = snapshots
                    self.trackSymbolAccess(symbol, dataSize: snapshots.count * 100) // Rough size estimate
                }
            }
            
            // Small delay between batches to prevent overwhelming the system
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        return results
    }
    
    private func loadSymbolData(symbol: String, timeRange: ChartTimeRange) async -> (String, [PriceSnapshot]) {
        do {
            let service = CoreDataHistoricalDataService()
            let snapshots = try await service.fetchPriceSnapshots(
                for: symbol,
                from: timeRange.startDate(),
                to: Date()
            )
            return (symbol, snapshots)
        } catch {
            await logger.error("Failed to load data for \(symbol): \(error)")
            return (symbol, [])
        }
    }
    
    // MARK: - Memory Efficient Operations
    
    func calculatePortfolioMetricsEfficiently(trades: [RealTimeTrade]) -> (totalValue: Double, totalGains: Double) {
        // Use streaming calculations to avoid large intermediate arrays
        var totalValue = 0.0
        var totalGains = 0.0
        
        for trade in trades {
            guard !trade.realTimeInfo.currentPrice.isNaN,
                  trade.realTimeInfo.currentPrice > 0 else { continue }
            
            let currentPrice = trade.realTimeInfo.currentPrice
            let units = trade.trade.position.unitSize
            let adjustedCost = trade.trade.position.getNormalizedAvgCost(for: trade.trade.name)
            
            guard !adjustedCost.isNaN, adjustedCost > 0 else { continue }
            
            let marketValue = currentPrice * units
            let gains = (currentPrice - adjustedCost) * units
            
            totalValue += marketValue
            totalGains += gains
        }
        
        return (totalValue, totalGains)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let symbolEvictedFromCache = Notification.Name("symbolEvictedFromCache")
    static let memoryPressureDetected = Notification.Name("memoryPressureDetected")
}

// MARK: - CacheManager Extensions

extension CacheManager {
    func clearMemoryCache() {
        Task { await Logger.shared.info("🧹 Clearing memory cache due to memory pressure") }

        memoryCacheQueue.async { [weak self] in
            guard let self = self else { return }

            let removedSize = self.memoryCache.values.reduce(0) { $0 + $1.size }
            let removedCount = self.memoryCache.count
            self.memoryCache.removeAll(keepingCapacity: false)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cacheStats.memorySize = max(0, self.cacheStats.memorySize - removedSize)
                self.cacheStats.totalEntries = max(0, self.cacheStats.totalEntries - removedCount)
                self.cacheStats.lastCleanup = Date()
            }
        }
    }
    
    func performMaintenance() {
        Task { await Logger.shared.debug("🔧 Performing cache maintenance") }
        self.performCleanup()
    }
}

// MARK: - Memory Helper Functions

private func mach_task_basic_info() -> mach_task_basic_info_data_t {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    
    return info
}
