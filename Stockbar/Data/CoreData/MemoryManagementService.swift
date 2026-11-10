@preconcurrency import CoreData
@preconcurrency import Foundation
import OSLog

private enum MemoryPressureLevel {
    case normal
    case warning
    case critical
}

/// Advanced memory management service for chart data and Core Data operations
actor MemoryManagementService {
    static let shared = MemoryManagementService()
    
    private let logger = Logger.shared
    
    // Memory thresholds (in MB)
    private var memoryWarningThreshold: Double = 150
    private var memoryCriticalThreshold: Double = 200
    private let memoryEmergencyThreshold: Double = 250
    
    // Cache management
    private var chartDataMemoryCache: [String: MemoryCachedData] = [:]
    private var maxCacheSize: Int = 50
    
    // Memory monitoring
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastSystemPressureLevel: MemoryPressureLevel = .normal
    private var lastUsagePressureLevel: MemoryPressureLevel = .normal
    private var memoryUsageHistory: [MemoryUsageSnapshot] = []
    private let maxHistorySize = 100
    private var memoryMonitoringTask: Task<Void, Never>?

    /// Poll cadence for the memory history/threshold sweep.
    ///
    /// Actual pressure detection is kernel-pushed via `DispatchSourceMemoryPressure`
    /// below, so this loop only maintains the usage history and does proactive
    /// threshold cleanup — it does not need 30s granularity. At 120s it costs a
    /// quarter of the wakeups (720/day rather than 2,880).
    private let memoryMonitoringInterval: UInt64 = 120_000_000_000
    
    private init() {}
    
    deinit {
        memoryMonitoringTask?.cancel()
        memoryPressureSource?.cancel()
    }
    
    // MARK: - Public Interface

    func startMonitoring() {
        guard memoryPressureSource == nil else { return }
        setupMemoryPressureMonitoring()
    }

    func stopMonitoring() {
        memoryMonitoringTask?.cancel()
        memoryMonitoringTask = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        lastSystemPressureLevel = .normal
        lastUsagePressureLevel = .normal
    }
    
    
    /// Performs intelligent memory cleanup based on current usage
    func performMemoryCleanup(forced: Bool = false) async {
        let currentUsage = getCurrentMemoryUsage()
        
        if forced || currentUsage > memoryWarningThreshold {
            await performCacheCleanup(dropAll: forced || currentUsage > memoryCriticalThreshold)

            let newUsage = getCurrentMemoryUsage()
            let saved = max(0, currentUsage - newUsage)
            // Worth an info line only when it freed something to speak of.
            let summary = "🧹 Memory cleanup: \(String(format: "%.1f", currentUsage))MB before, freed \(String(format: "%.1f", saved))MB"
            if saved >= 1 {
                Task { await logger.info(summary) }
            } else {
                Task { await logger.debug(summary) }
            }
        }
    }
    
    /// Optimizes memory usage for chart data
    func optimizeChartDataMemory() async {
        Task { await logger.debug("📊 Optimizing chart data memory usage") }
        
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
        
        Task { await logger.debug("📊 Chart data memory optimization completed - \(chartDataMemoryCache.count) items cached") }
    }
    
    
    
    
    
    // MARK: - Private Implementation
    
    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.stockbar.memory-pressure", qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            Task {
                await self?.handleSystemMemoryPressure(
                    normal: event.contains(.normal),
                    critical: event.contains(.critical)
                )
            }
        }
        source.resume()
        memoryPressureSource = source
        
        // Start periodic memory monitoring
        memoryMonitoringTask = Task { [weak self] in
            await self?.startMemoryMonitoring()
        }
    }
    
    private func startMemoryMonitoring() async {
        while !Task.isCancelled {
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
                if lastUsagePressureLevel != .critical {
                    await logger.warning("🚨 Critical memory usage: \(String(format: "%.1f", usage))MB")
                    lastUsagePressureLevel = .critical
                }
                await performMemoryCleanup()
            } else if usage > memoryWarningThreshold {
                if lastUsagePressureLevel == .normal {
                    await logger.info("⚠️ High memory usage: \(String(format: "%.1f", usage))MB")
                    lastUsagePressureLevel = .warning
                }
                await optimizeChartDataMemory()
            } else if lastUsagePressureLevel != .normal {
                lastUsagePressureLevel = .normal
                await logger.info("Memory usage returned to normal: \(String(format: "%.1f", usage))MB")
            }
            
            // Wait before next check. Task.sleep throws on cancellation, which
            // the loop condition then observes.
            do {
                try await Task.sleep(nanoseconds: memoryMonitoringInterval)
            } catch {
                return
            }
        }
    }
    
    private func handleSystemMemoryPressure(normal: Bool, critical: Bool) async {
        if normal {
            if lastSystemPressureLevel != .normal {
                await logger.info("System memory pressure returned to normal")
                lastSystemPressureLevel = .normal
            }
            return
        }

        let level: MemoryPressureLevel = critical ? .critical : .warning
        if lastSystemPressureLevel != level {
            await logger.warning(critical ? "System memory pressure is critical" : "System memory pressure warning")
            lastSystemPressureLevel = level
        }

        // The system raises a warning when any app is short of memory. Most
        // of the time that is not Stockbar, and emptying its small caches
        // freed nothing while making the next chart slower. Act on a warning
        // only when Stockbar itself is large; always act when it is critical.
        guard Self.shouldEvictCaches(
            systemPressureIsCritical: critical,
            ownUsageMB: getCurrentMemoryUsage(),
            ownUsageLimitMB: memoryWarningThreshold
        ) else { return }

        await performMemoryCleanup(forced: true)
        CacheManager.shared.clearMemoryCache()
        await HistoricalDataManager.shared.evictMemoryCachesForPressure(critical: critical)
    }
    
    nonisolated static func shouldEvictCaches(
        systemPressureIsCritical: Bool,
        ownUsageMB: Double,
        ownUsageLimitMB: Double
    ) -> Bool {
        systemPressureIsCritical || ownUsageMB > ownUsageLimitMB
    }

    private func performCacheCleanup(dropAll: Bool = false) async {
        let currentUsage = getCurrentMemoryUsage()
        
        // More aggressive cleanup under memory pressure
        if dropAll {
            chartDataMemoryCache.removeAll(keepingCapacity: false)
        } else if currentUsage > memoryCriticalThreshold {
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
