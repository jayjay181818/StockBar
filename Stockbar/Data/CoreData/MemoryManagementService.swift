import Foundation
import CoreData
import OSLog

/// Advanced memory management service for chart data and Core Data operations
actor MemoryManagementService {
    static let shared = MemoryManagementService()
    
    private let logger = Logger.shared
    private let coreDataStack = CoreDataStack.shared
    
    // Memory thresholds (in MB)
    private var memoryWarningThreshold: Double = 150
    private var memoryCriticalThreshold: Double = 200
    private let memoryEmergencyThreshold: Double = 250
    
    // Cache management
    private var chartDataMemoryCache: [String: MemoryCachedData] = [:]
    private var maxCacheSize: Int = 50
    private var lastMemoryWarning: Date?
    
    // Memory monitoring
    private var memoryPressureObserver: NSObjectProtocol?
    private var memoryUsageHistory: [MemoryUsageSnapshot] = []
    private let maxHistorySize = 100
    
    private init() {
        setupMemoryPressureMonitoring()
    }
    
    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Public Interface
    
    /// Gets current memory usage statistics
    func getMemoryStats() -> MemoryStats {
        let usage = getCurrentMemoryUsage()
        let cacheMemory = calculateCacheMemoryUsage()
        
        return MemoryStats(
            currentUsage: usage,
            cacheUsage: cacheMemory,
            warningThreshold: memoryWarningThreshold,
            criticalThreshold: memoryCriticalThreshold,
            emergencyThreshold: memoryEmergencyThreshold,
            cacheSize: chartDataMemoryCache.count,
            maxCacheSize: maxCacheSize
        )
    }
    
    /// Performs intelligent memory cleanup based on current usage
    func performMemoryCleanup(forced: Bool = false) async {
        let currentUsage = getCurrentMemoryUsage()
        
        logger.info("🧹 Memory cleanup - Current usage: \(String(format: "%.1f", currentUsage))MB")
        
        if forced || currentUsage > memoryWarningThreshold {
            await performCacheCleanup()
            await performCoreDataCleanup()
            await performLowMemoryOptimizations()
            
            let newUsage = getCurrentMemoryUsage()
            let saved = currentUsage - newUsage
            logger.info("🧹 Memory cleanup completed - Freed \(String(format: "%.1f", saved))MB")
        }
    }
    
    /// Optimizes memory usage for chart data
    func optimizeChartDataMemory() async {
        logger.debug("📊 Optimizing chart data memory usage")
        
        // Remove expired cache entries
        let now = Date()
        let expiredKeys = chartDataMemoryCache.compactMap { key, value in
            value.isExpired(at: now) ? key : nil
        }
        
        for key in expiredKeys {
            chartDataMemoryCache.removeValue(forKey: key)
        }
        
        // Implement LRU eviction if cache is too large
        if chartDataMemoryCache.count > maxCacheSize {
            let sortedEntries = chartDataMemoryCache.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            let toRemove = sortedEntries.prefix(chartDataMemoryCache.count - maxCacheSize)
            
            for (key, _) in toRemove {
                chartDataMemoryCache.removeValue(forKey: key)
            }
        }
        
        logger.debug("📊 Chart data memory optimization completed - \(chartDataMemoryCache.count) items cached")
    }
    
    /// Caches chart data with intelligent memory management
    func cacheChartData(_ data: [ChartDataPoint], forKey key: String, priority: CachePriority = .normal) async {
        // Check if we should cache based on memory pressure
        let currentUsage = getCurrentMemoryUsage()
        
        if currentUsage > memoryCriticalThreshold && priority != .high {
            logger.debug("📊 Skipping cache due to memory pressure")
            return
        }
        
        // Estimate memory usage for this data
        let estimatedSize = estimateDataSize(data)
        
        // Make room if necessary
        await makeRoomForData(estimatedSize: estimatedSize)
        
        // Cache the data
        chartDataMemoryCache[key] = MemoryCachedData(
            data: data,
            timestamp: Date(),
            lastAccessed: Date(),
            estimatedSize: estimatedSize,
            priority: priority
        )
        
        logger.debug("📊 Cached \(data.count) chart points (\(String(format: "%.1f", estimatedSize))KB) for key: \(key)")
    }
    
    /// Retrieves cached chart data with access tracking
    func getCachedChartData(forKey key: String) -> [ChartDataPoint]? {
        guard var cachedData = chartDataMemoryCache[key] else {
            return nil
        }
        
        if cachedData.isExpired() {
            chartDataMemoryCache.removeValue(forKey: key)
            return nil
        }
        
        // Update access time for LRU
        cachedData.lastAccessed = Date()
        chartDataMemoryCache[key] = cachedData
        
        return cachedData.data
    }
    
    /// Configures memory management settings
    func configureMemorySettings(
        maxCacheSize: Int? = nil,
        warningThreshold: Double? = nil,
        criticalThreshold: Double? = nil
    ) {
        if let maxSize = maxCacheSize {
            self.maxCacheSize = max(10, min(maxSize, 200))
        }
        
        if let warning = warningThreshold {
            self.memoryWarningThreshold = max(50, min(warning, 300))
        }
        
        if let critical = criticalThreshold {
            self.memoryCriticalThreshold = max(100, min(critical, 400))
        }
        
        logger.info("🧹 Memory settings updated - Cache: \(self.maxCacheSize), Warning: \(String(format: "%.0f", self.memoryWarningThreshold))MB")
    }
    
    /// Gets memory usage history for analysis
    func getMemoryUsageHistory() -> [MemoryUsageSnapshot] {
        return memoryUsageHistory
    }
    
    // MARK: - Private Implementation
    
    private func setupMemoryPressureMonitoring() {
        // macOS doesn't have a direct memory warning notification like iOS
        // Instead, we'll rely on periodic monitoring and manual triggers
        
        // Start periodic memory monitoring
        Task {
            await startMemoryMonitoring()
        }
    }
    
    private func startMemoryMonitoring() async {
        while true {
            let usage = getCurrentMemoryUsage()
            
            // Record usage history
            let snapshot = MemoryUsageSnapshot(
                timestamp: Date(),
                memoryUsage: usage,
                cacheSize: chartDataMemoryCache.count,
                cacheMemory: calculateCacheMemoryUsage()
            )
            
            memoryUsageHistory.append(snapshot)
            
            // Maintain history size
            if memoryUsageHistory.count > maxHistorySize {
                memoryUsageHistory.removeFirst()
            }
            
            // Check for memory pressure
            if usage > memoryCriticalThreshold {
                logger.warning("🚨 Critical memory usage: \(String(format: "%.1f", usage))MB")
                await performMemoryCleanup()
            } else if usage > memoryWarningThreshold {
                logger.info("⚠️ High memory usage: \(String(format: "%.1f", usage))MB")
                await optimizeChartDataMemory()
            }
            
            // Wait before next check
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
        }
    }
    
    private func handleMemoryWarning() async {
        logger.warning("🚨 Memory warning received")
        lastMemoryWarning = Date()
        
        await performMemoryCleanup(forced: true)
        
        // Reduce cache size temporarily
        let originalMaxSize = maxCacheSize
        maxCacheSize = max(10, maxCacheSize / 2)
        
        // Restore cache size after a delay
        try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
        maxCacheSize = originalMaxSize
    }
    
    private func performCacheCleanup() async {
        logger.debug("🧹 Performing cache cleanup")
        
        let currentUsage = getCurrentMemoryUsage()
        
        // More aggressive cleanup under memory pressure
        if currentUsage > memoryCriticalThreshold {
            // Remove all but high priority cache entries
            chartDataMemoryCache = chartDataMemoryCache.filter { $0.value.priority == .high }
        } else if currentUsage > memoryWarningThreshold {
            // Remove normal and low priority entries
            chartDataMemoryCache = chartDataMemoryCache.filter { $0.value.priority != .low }
        }
        
        // Remove expired entries
        let now = Date()
        chartDataMemoryCache = chartDataMemoryCache.filter { !$0.value.isExpired(at: now) }
    }
    
    private func performCoreDataCleanup() async {
        logger.debug("🧹 Performing Core Data cleanup")
        
        let context = coreDataStack.newBackgroundContext()
        
        await context.perform {
            // Clear the row cache
            context.refreshAllObjects()
            
            // Reset context to clear persistent store cache
            context.reset()
        }
    }
    
    private func performLowMemoryOptimizations() async {
        logger.debug("🧹 Performing low memory optimizations")
        
        // Trigger garbage collection
        // Note: In Swift, there's no explicit garbage collection, but we can help by clearing references
        
        // Clear any temporary data structures
        if memoryUsageHistory.count > 50 {
            memoryUsageHistory = Array(memoryUsageHistory.suffix(50))
        }
        
        // Request system memory optimization
        Task.detached(priority: .utility) {
            // Perform any CPU-intensive cleanup on a background thread
            autoreleasepool {
                // This helps release any autorelease objects
            }
        }
    }
    
    private func makeRoomForData(estimatedSize: Double) async {
        let currentUsage = getCurrentMemoryUsage()
        let availableMemory = memoryCriticalThreshold - currentUsage
        
        if estimatedSize > availableMemory * 1024 { // Convert MB to KB
            // Need to free up space
            let targetToRemove = estimatedSize - (availableMemory * 1024)
            var removedSize: Double = 0
            
            // Sort by priority and access time
            let sortedEntries = chartDataMemoryCache.sorted { entry1, entry2 in
                if entry1.value.priority != entry2.value.priority {
                    return entry1.value.priority.rawValue < entry2.value.priority.rawValue
                }
                return entry1.value.lastAccessed < entry2.value.lastAccessed
            }
            
            for (key, value) in sortedEntries {
                if removedSize >= targetToRemove { break }
                
                chartDataMemoryCache.removeValue(forKey: key)
                removedSize += value.estimatedSize
            }
            
            logger.debug("📊 Freed \(String(format: "%.1f", removedSize))KB to make room for new data")
        }
    }
    
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1024.0 / 1024.0 // Convert to MB
        } else {
            return 0
        }
    }
    
    private func calculateCacheMemoryUsage() -> Double {
        return chartDataMemoryCache.values.reduce(0) { $0 + $1.estimatedSize } / 1024.0 // Convert to MB
    }
    
    private func estimateDataSize(_ data: [ChartDataPoint]) -> Double {
        // Rough estimate: 
        // - Date: 8 bytes
        // - Double (value): 8 bytes  
        // - Optional String (symbol): ~20 bytes average
        // - Object overhead: ~16 bytes
        let bytesPerPoint = 52.0
        return Double(data.count) * bytesPerPoint / 1024.0 // Convert to KB
    }
}

// MARK: - Supporting Types

struct MemoryCachedData {
    let data: [ChartDataPoint]
    let timestamp: Date
    var lastAccessed: Date
    let estimatedSize: Double // in KB
    let priority: CachePriority
    
    private let maxAge: TimeInterval = 600 // 10 minutes
    
    func isExpired(at currentTime: Date = Date()) -> Bool {
        return currentTime.timeIntervalSince(timestamp) > maxAge
    }
}

enum CachePriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    
    static func < (lhs: CachePriority, rhs: CachePriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

struct MemoryStats {
    let currentUsage: Double // MB
    let cacheUsage: Double // MB
    let warningThreshold: Double
    let criticalThreshold: Double
    let emergencyThreshold: Double
    let cacheSize: Int
    let maxCacheSize: Int
    
    var usagePercentage: Double {
        return (currentUsage / criticalThreshold) * 100
    }
    
    var memoryStatus: MemoryStatus {
        if currentUsage > emergencyThreshold {
            return .emergency
        } else if currentUsage > criticalThreshold {
            return .critical
        } else if currentUsage > warningThreshold {
            return .warning
        } else {
            return .normal
        }
    }
    
    var formattedUsage: String {
        return String(format: "%.1f MB (%.1f%%)", currentUsage, usagePercentage)
    }
    
    var formattedCacheUsage: String {
        return String(format: "%.1f MB (%d/%d items)", cacheUsage, cacheSize, maxCacheSize)
    }
}

enum MemoryStatus {
    case normal
    case warning
    case critical
    case emergency
    
    var description: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .emergency: return "Emergency"
        }
    }
    
    var color: String {
        switch self {
        case .normal: return "green"
        case .warning: return "yellow"
        case .critical: return "orange"
        case .emergency: return "red"
        }
    }
}

struct MemoryUsageSnapshot {
    let timestamp: Date
    let memoryUsage: Double // MB
    let cacheSize: Int
    let cacheMemory: Double // MB
}