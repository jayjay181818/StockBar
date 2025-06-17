import Foundation
import CoreData
import OSLog

/// Performance monitoring system for tracking Core Data and memory optimizations
actor PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private let logger = Logger.shared
    private var metrics: [String: PerformanceMetric] = [:]
    private var startTimes: [String: Date] = [:]
    
    // MARK: - Performance Metric Types
    
    struct PerformanceMetric {
        let name: String
        var totalTime: TimeInterval = 0
        var count: Int = 0
        var averageTime: TimeInterval { count > 0 ? totalTime / Double(count) : 0 }
        var minTime: TimeInterval = Double.greatestFiniteMagnitude
        var maxTime: TimeInterval = 0
        var lastExecuted: Date = Date()
        
        mutating func addExecution(duration: TimeInterval) {
            totalTime += duration
            count += 1
            minTime = min(minTime, duration)
            maxTime = max(maxTime, duration)
            lastExecuted = Date()
        }
    }
    
    struct MemoryMetric {
        let timestamp: Date
        let memoryUsage: Int // in bytes
        let cacheSize: Int
        let activeObjects: Int
    }
    
    // MARK: - Tracking Methods
    
    func startTracking(_ operationName: String) {
        startTimes[operationName] = Date()
    }
    
    func endTracking(_ operationName: String) {
        guard let startTime = startTimes.removeValue(forKey: operationName) else {
            Task { await logger.warning("No start time found for operation: \(operationName)") }
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        if var metric = metrics[operationName] {
            metric.addExecution(duration: duration)
            metrics[operationName] = metric
        } else {
            var metric = PerformanceMetric(name: operationName)
            metric.addExecution(duration: duration)
            metrics[operationName] = metric
        }
        
        // Log slow operations
        if duration > 1.0 {
            Task { await logger.warning("⚠️ Slow operation detected: \(operationName) took \(String(format: "%.3f", duration))s") }
        }
    }
    
    func trackMemoryUsage(cacheSize: Int, activeObjects: Int) {
        let memoryUsage = getCurrentMemoryUsage()
        _ = MemoryMetric(
            timestamp: Date(),
            memoryUsage: memoryUsage,
            cacheSize: cacheSize,
            activeObjects: activeObjects
        )
        
        // Log if memory usage is high
        let memoryMB = Double(memoryUsage) / 1024 / 1024
        if memoryMB > 200 { // 200MB threshold
            Task { await logger.warning("⚠️ High memory usage: \(String(format: "%.1f", memoryMB))MB") }
        }
    }
    
    // MARK: - Reporting
    
    func getPerformanceReport() -> String {
        var report = "📊 Performance Report\n"
        report += "=" * 50 + "\n\n"
        
        // Sort metrics by average time (slowest first)
        let sortedMetrics = metrics.values.sorted { $0.averageTime > $1.averageTime }
        
        for metric in sortedMetrics {
            report += "Operation: \(metric.name)\n"
            report += "  Count: \(metric.count)\n"
            report += "  Total Time: \(String(format: "%.3f", metric.totalTime))s\n"
            report += "  Average: \(String(format: "%.3f", metric.averageTime))s\n"
            report += "  Min: \(String(format: "%.3f", metric.minTime))s\n"
            report += "  Max: \(String(format: "%.3f", metric.maxTime))s\n"
            report += "  Last: \(DateFormatter.shortDateTime.string(from: metric.lastExecuted))\n\n"
        }
        
        // Memory info
        let currentMemory = getCurrentMemoryUsage()
        report += "Current Memory: \(String(format: "%.1f", Double(currentMemory) / 1024 / 1024))MB\n"
        
        return report
    }
    
    func getSlowOperations(threshold: TimeInterval = 0.5) -> [PerformanceMetric] {
        return metrics.values.filter { $0.averageTime > threshold }
    }
    
    func resetMetrics() {
        metrics.removeAll()
        startTimes.removeAll()
        Task { await logger.info("🔄 Performance metrics reset") }
    }
    
    // MARK: - Helper Methods
    
    private func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    
    // MARK: - Automated Monitoring
    
    private var monitoringTimer: Timer?
    
    func startAutomaticMonitoring(interval: TimeInterval = 60) {
        stopAutomaticMonitoring()
        
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.performPeriodicCheck()
            }
        }
        
        Task { await logger.info("🎯 Started automatic performance monitoring (interval: \(interval)s)") }
    }
    
    func stopAutomaticMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    private func performPeriodicCheck() async {
        // Track memory usage
        trackMemoryUsage(cacheSize: 0, activeObjects: 0)
        
        // Check for performance issues
        let slowOps = getSlowOperations()
        if !slowOps.isEmpty {
            await logger.warning("🐌 Found \(slowOps.count) slow operations")
        }
        
        // Log summary every 10 minutes
        if Int(Date().timeIntervalSince1970) % 600 == 0 {
            await logger.info(getPerformanceReport())
        }
    }
}

// MARK: - Performance Tracking Wrapper

/// Convenience wrapper for performance tracking
func withPerformanceTracking<T>(_ operationName: String, operation: () async throws -> T) async rethrows -> T {
    await PerformanceMonitor.shared.startTracking(operationName)
    defer {
        Task {
            await PerformanceMonitor.shared.endTracking(operationName)
        }
    }
    
    return try await operation()
}

// MARK: - Core Data Performance Extensions

extension CoreDataStack {
    
    func performTrackedBackgroundTask<T>(_ operationName: String, _ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withPerformanceTracking("CoreData_\(operationName)") {
            return try await performBackgroundTask(block)
        }
    }
    
    func performTrackedBatchOperation<T>(_ operationName: String, _ block: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        return try await withPerformanceTracking("CoreDataBatch_\(operationName)") {
            return try await performOptimizedBatchTask(block)
        }
    }
}

// MARK: - String Extension for Formatting

extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}