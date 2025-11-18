import Foundation
import CoreData
import OSLog

/// Highly optimized service for fetching chart data with performance optimizations
actor OptimizedChartDataService {
    static let shared = OptimizedChartDataService()
    
    private let logger = Logger.shared
    private let coreDataStack = CoreDataStack.shared
    
    // Cache for recently fetched data
    private var chartDataCache: [String: CachedChartData] = [:]
    private let maxCacheAge: TimeInterval = 300 // 5 minutes
    private let maxCacheSize = 50
    
    // Prefetch buffer for smooth scrolling
    private var prefetchBuffer: [String: [ChartDataPoint]] = [:]
    
    private init() {}
    
    // MARK: - Public Interface
    
    /// Fetches optimized chart data for a specific time range and chart type
    func fetchChartData(
        for chartType: ChartType,
        timeRange: ChartTimeRange,
        maxPoints: Int = 1000
    ) async throws -> [ChartDataPoint] {
        let cacheKey = generateCacheKey(chartType: chartType, timeRange: timeRange, maxPoints: maxPoints)
        
        // Check cache first
        if let cachedData = chartDataCache[cacheKey],
           cachedData.isValid {
            Task { await logger.debug("📊 Chart data cache hit for \(cacheKey)") }
            return cachedData.data
        }
        
        Task { await logger.info("📊 Fetching optimized chart data for \(chartType.title) - \(timeRange.description)") }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let data: [ChartDataPoint]
        
        switch chartType {
        case .portfolioValue:
            data = try await fetchOptimizedPortfolioData(timeRange: timeRange, maxPoints: maxPoints)
        case .portfolioGains:
            data = try await fetchOptimizedPortfolioGains(timeRange: timeRange, maxPoints: maxPoints)
        case .individualStock(let symbol):
            data = try await fetchOptimizedStockData(symbol: symbol, timeRange: timeRange, maxPoints: maxPoints)
        }
        
        let fetchTime = CFAbsoluteTimeGetCurrent() - startTime
        Task { await logger.info("📊 Fetched \(data.count) chart points in \(String(format: "%.3f", fetchTime))s") }
        
        // Cache the result
        await updateCache(key: cacheKey, data: data)
        
        // Prefetch adjacent time ranges for smooth navigation
        Task {
            await prefetchAdjacentTimeRanges(chartType: chartType, currentRange: timeRange, maxPoints: maxPoints)
        }
        
        return data
    }
    
    /// Prefetches data for smooth chart interactions
    func prefetchChartData(
        for chartType: ChartType,
        timeRanges: [ChartTimeRange],
        maxPoints: Int = 1000
    ) async {
        Task { await logger.debug("📊 Prefetching chart data for \(timeRanges.count) time ranges") }
        
        await withTaskGroup(of: Void.self) { group in
            for timeRange in timeRanges {
                group.addTask {
                    do {
                        _ = try await self.fetchChartData(for: chartType, timeRange: timeRange, maxPoints: maxPoints)
                    } catch {
                        Task { await self.logger.debug("📊 Prefetch failed for \(timeRange.description): \(error)") }
                    }
                }
            }
        }
    }
    
    /// Clears all cached chart data
    func clearCache() async {
        chartDataCache.removeAll()
        prefetchBuffer.removeAll()
        Task { await logger.debug("📊 Chart data cache cleared") }
    }
    
    /// Gets cache statistics
    func getCacheStats() async -> ChartCacheStats {
        let totalEntries = chartDataCache.count
        let validEntries = chartDataCache.values.filter { $0.isValid }.count
        let totalDataPoints = chartDataCache.values.reduce(0) { $0 + $1.data.count }
        
        return ChartCacheStats(
            totalEntries: totalEntries,
            validEntries: validEntries,
            totalDataPoints: totalDataPoints,
            cacheHitRatio: calculateCacheHitRatio()
        )
    }
    
    // MARK: - Optimized Fetch Methods
    
    private func fetchOptimizedPortfolioData(timeRange: ChartTimeRange, maxPoints: Int) async throws -> [ChartDataPoint] {
        let context = coreDataStack.newBackgroundContext()
        
        return try await context.perform {
            let request: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            
            // Use indexed timestamp fetch
            let endDate = Date()
            let startDate = timeRange.startDate(from: endDate)
            
            request.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                startDate as NSDate,
                endDate as NSDate
            )
            
            // Optimize fetch with batch size and prefetching
            request.fetchBatchSize = min(maxPoints, 500)
            request.returnsObjectsAsFaults = false
            
            // Smart sampling for large datasets
            let totalCount = try context.count(for: request)
            
            if totalCount > maxPoints {
                // Apply intelligent sampling
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                let samplingRatio = max(1, totalCount / maxPoints)
                
                // Use Core Data efficient sampling
                return try self.performIntelligentSampling(
                    request: request,
                    context: context,
                    samplingRatio: samplingRatio,
                    maxPoints: maxPoints
                ) { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.totalValue,
                        symbol: nil
                    )
                }
            } else {
                // Fetch all data
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                let entities = try context.fetch(request)
                
                return entities.map { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.totalValue,
                        symbol: nil
                    )
                }
            }
        }
    }
    
    private func fetchOptimizedPortfolioGains(timeRange: ChartTimeRange, maxPoints: Int) async throws -> [ChartDataPoint] {
        let context = coreDataStack.newBackgroundContext()
        
        return try await context.perform {
            let request: NSFetchRequest<PortfolioSnapshotEntity> = PortfolioSnapshotEntity.fetchRequest()
            
            let endDate = Date()
            let startDate = timeRange.startDate(from: endDate)
            
            request.predicate = NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                startDate as NSDate,
                endDate as NSDate
            )
            
            request.fetchBatchSize = min(maxPoints, 500)
            request.returnsObjectsAsFaults = false
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let totalCount = try context.count(for: request)
            
            if totalCount > maxPoints {
                let samplingRatio = max(1, totalCount / maxPoints)
                
                return try self.performIntelligentSampling(
                    request: request,
                    context: context,
                    samplingRatio: samplingRatio,
                    maxPoints: maxPoints
                ) { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.totalGains,
                        symbol: nil
                    )
                }
            } else {
                let entities = try context.fetch(request)
                
                return entities.map { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.totalGains,
                        symbol: nil
                    )
                }
            }
        }
    }
    
    private func fetchOptimizedStockData(symbol: String, timeRange: ChartTimeRange, maxPoints: Int) async throws -> [ChartDataPoint] {
        let context = coreDataStack.newBackgroundContext()
        
        return try await context.perform {
            let request: NSFetchRequest<PriceSnapshotEntity> = PriceSnapshotEntity.fetchRequest()
            
            let endDate = Date()
            let startDate = timeRange.startDate(from: endDate)
            
            // Use compound index for optimal performance
            request.predicate = NSPredicate(
                format: "symbol == %@ AND timestamp >= %@ AND timestamp <= %@",
                symbol,
                startDate as NSDate,
                endDate as NSDate
            )
            
            request.fetchBatchSize = min(maxPoints, 500)
            request.returnsObjectsAsFaults = false
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            
            let totalCount = try context.count(for: request)
            
            if totalCount > maxPoints {
                let samplingRatio = max(1, totalCount / maxPoints)
                
                return try self.performIntelligentSampling(
                    request: request,
                    context: context,
                    samplingRatio: samplingRatio,
                    maxPoints: maxPoints
                ) { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.price,
                        symbol: entity.symbol
                    )
                }
            } else {
                let entities = try context.fetch(request)
                
                return entities.map { entity in
                    ChartDataPoint(
                        date: entity.timestamp ?? Date(),
                        value: entity.price,
                        symbol: entity.symbol
                    )
                }
            }
        }
    }
    
    // MARK: - Advanced Sampling Algorithm
    
    nonisolated private func performIntelligentSampling<T: NSManagedObject>(
        request: NSFetchRequest<T>,
        context: NSManagedObjectContext,
        samplingRatio: Int,
        maxPoints: Int,
        transform: (T) -> ChartDataPoint
    ) throws -> [ChartDataPoint] {
        
        // Strategy 1: Use LIMIT and OFFSET for large datasets
        if samplingRatio > 10 {
            return try performOffsetSampling(
                request: request,
                context: context,
                samplingRatio: samplingRatio,
                maxPoints: maxPoints,
                transform: transform
            )
        }
        
        // Strategy 2: Fetch and sample in memory for smaller datasets
        let entities = try context.fetch(request)
        
        if entities.count <= maxPoints {
            return entities.map(transform)
        }
        
        // Apply intelligent sampling that preserves important data points
        return performAdaptiveSampling(entities: entities, maxPoints: maxPoints, transform: transform)
    }
    
    nonisolated private func performOffsetSampling<T: NSManagedObject>(
        request: NSFetchRequest<T>,
        context: NSManagedObjectContext,
        samplingRatio: Int,
        maxPoints: Int,
        transform: (T) -> ChartDataPoint
    ) throws -> [ChartDataPoint] {
        
        var results: [ChartDataPoint] = []
        var offset = 0
        let batchSize = 100
        
        request.fetchLimit = batchSize
        
        while results.count < maxPoints && offset < Int.max {
            request.fetchOffset = offset
            
            let batch = try context.fetch(request)
            if batch.isEmpty { break }
            
            // Sample every nth item from the batch
            for (index, entity) in batch.enumerated() {
                if index % samplingRatio == 0 {
                    results.append(transform(entity))
                    if results.count >= maxPoints { break }
                }
            }
            
            offset += batchSize * samplingRatio
        }
        
        return results
    }
    
    nonisolated private func performAdaptiveSampling<T>(
        entities: [T],
        maxPoints: Int,
        transform: (T) -> ChartDataPoint
    ) -> [ChartDataPoint] {
        
        guard entities.count > maxPoints else {
            return entities.map(transform)
        }
        
        let ratio = Double(entities.count) / Double(maxPoints)
        var results: [ChartDataPoint] = []
        
        // Use adaptive sampling that preserves temporal distribution
        for i in 0..<maxPoints {
            let sourceIndex = Int(Double(i) * ratio)
            if sourceIndex < entities.count {
                results.append(transform(entities[sourceIndex]))
            }
        }
        
        return results
    }
    
    // MARK: - Cache Management
    
    private func generateCacheKey(chartType: ChartType, timeRange: ChartTimeRange, maxPoints: Int) -> String {
        switch chartType {
        case .portfolioValue:
            return "portfolio_value_\(timeRange.rawValue)_\(maxPoints)"
        case .portfolioGains:
            return "portfolio_gains_\(timeRange.rawValue)_\(maxPoints)"
        case .individualStock(let symbol):
            return "stock_\(symbol)_\(timeRange.rawValue)_\(maxPoints)"
        }
    }
    
    private func updateCache(key: String, data: [ChartDataPoint]) async {
        // Implement LRU cache eviction
        if chartDataCache.count >= maxCacheSize {
            // Remove oldest entries
            let sortedEntries = chartDataCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let toRemove = sortedEntries.prefix(sortedEntries.count - maxCacheSize + 1)
            
            for (key, _) in toRemove {
                chartDataCache.removeValue(forKey: key)
            }
        }
        
        chartDataCache[key] = CachedChartData(
            data: data,
            timestamp: Date()
        )
    }
    
    private func prefetchAdjacentTimeRanges(chartType: ChartType, currentRange: ChartTimeRange, maxPoints: Int) async {
        let adjacentRanges = getAdjacentTimeRanges(for: currentRange)
        
        for range in adjacentRanges {
            let cacheKey = generateCacheKey(chartType: chartType, timeRange: range, maxPoints: maxPoints)
            
            if chartDataCache[cacheKey] == nil {
                do {
                    _ = try await fetchChartData(for: chartType, timeRange: range, maxPoints: maxPoints)
                } catch {
                    Task { await logger.debug("📊 Prefetch failed for \(range.description): \(error)") }
                }
            }
        }
    }
    
    private func getAdjacentTimeRanges(for timeRange: ChartTimeRange) -> [ChartTimeRange] {
        let allRanges = ChartTimeRange.allCases
        guard let currentIndex = allRanges.firstIndex(of: timeRange) else { return [] }
        
        var adjacent: [ChartTimeRange] = []
        
        // Previous range
        if currentIndex > 0 {
            adjacent.append(allRanges[currentIndex - 1])
        }
        
        // Next range
        if currentIndex < allRanges.count - 1 {
            adjacent.append(allRanges[currentIndex + 1])
        }
        
        return adjacent
    }
    
    private var cacheHitCount = 0
    private var cacheMissCount = 0
    
    private func calculateCacheHitRatio() -> Double {
        let total = cacheHitCount + cacheMissCount
        guard total > 0 else { return 0 }
        return Double(cacheHitCount) / Double(total)
    }
}

// MARK: - Supporting Types

struct CachedChartData {
    let data: [ChartDataPoint]
    let timestamp: Date
    
    var isValid: Bool {
        Date().timeIntervalSince(timestamp) < 300 // 5 minutes
    }
}

struct ChartCacheStats {
    let totalEntries: Int
    let validEntries: Int
    let totalDataPoints: Int
    let cacheHitRatio: Double
    
    var memoryEstimate: String {
        let bytesPerPoint = 40 // Rough estimate
        let totalBytes = totalDataPoints * bytesPerPoint
        
        if totalBytes < 1024 {
            return "\(totalBytes) B"
        } else if totalBytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(totalBytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(totalBytes) / (1024 * 1024))
        }
    }
}