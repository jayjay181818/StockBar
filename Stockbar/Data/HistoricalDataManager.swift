import Foundation
import Combine

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

class HistoricalDataManager: ObservableObject {
    static let shared = HistoricalDataManager()
    
    private let logger = Logger.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    @Published var portfolioSnapshots: [PortfolioSnapshot] = []
    @Published var priceSnapshots: [String: [PriceSnapshot]] = [:]
    
    // MARK: - Enhanced Portfolio Storage
    
    // New persistent portfolio snapshots storage
    @Published var historicalPortfolioSnapshots: [HistoricalPortfolioSnapshot] = []
    private var currentPortfolioComposition: PortfolioComposition?
    private var lastRetroactiveCalculationDate: Date = Date.distantPast
    
    // Cache for calculated historical portfolio values (legacy - being phased out)
    public private(set) var cachedHistoricalPortfolioValues: [ChartDataPoint] = []
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
    
    // Increased limits to handle 5+ years of daily data
    private let maxDataPoints = 2500 // Increased from 1000 to accommodate 5+ years
    private let maxPortfolioSnapshots = 2000 // Limit for portfolio snapshots
    
    private var snapshotInterval: TimeInterval = 300 // 5 minutes (restored from 30 seconds)
    private var lastSnapshotTime: Date = Date.distantPast
    
    private init() {
        loadHistoricalData()
        setupPeriodicSave()
    }
    
    func recordSnapshot(from dataModel: DataModel) {
        let now = Date()
        let timeSinceLastSnapshot = now.timeIntervalSince(lastSnapshotTime)
        
        logger.debug("📸 Snapshot attempt: timeSinceLastSnapshot=\(Int(timeSinceLastSnapshot))s, required=\(Int(snapshotInterval))s")
        
        guard timeSinceLastSnapshot >= snapshotInterval else {
            logger.debug("📸 Skipping snapshot - too soon (\(Int(timeSinceLastSnapshot))s < \(Int(snapshotInterval))s)")
            return // Too soon since last snapshot
        }
        
        lastSnapshotTime = now
        logger.debug("📸 Recording snapshot at \(now)")
        
        var currentPriceSnapshots: [PriceSnapshot] = []
        var hasValidData = false
        
        logger.debug("📸 Checking \(dataModel.realTimeTrades.count) trades for valid data")
        
        for trade in dataModel.realTimeTrades {
            let price = trade.realTimeInfo.currentPrice
            let prevClose = trade.realTimeInfo.prevClosePrice
            
            logger.debug("📸 \(trade.trade.name): price=\(price), prevClose=\(prevClose), currency=\(trade.realTimeInfo.currency ?? "nil")")
            
            guard !price.isNaN && !prevClose.isNaN && price > 0 else {
                logger.debug("📸 Skipping \(trade.trade.name) - invalid data")
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
            hasValidData = true
        }
        
        guard hasValidData else {
            logger.debug("Skipping snapshot - no valid price data")
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
        
        // Save data
        saveHistoricalData()
        
        logger.debug("Recorded portfolio snapshot: value=\(totalValue), gains=\(gains.amount) \(gains.currency)")
    }
    
    func getChartData(for type: ChartType, timeRange: ChartTimeRange, dataModel: DataModel? = nil) -> [ChartDataPoint] {
        switch type {
        case .portfolioValue:
            // NEW: Use stored portfolio snapshots if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioValues(for: timeRange)
                logger.debug("📊 Portfolio value chart data: \(data.count) stored portfolio points for range \(timeRange.rawValue)")
                
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
                    logger.info("📊 Portfolio value chart: Triggering background retroactive calculation")
                    Task.detached(priority: .background) {
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
                logger.debug("📊 Portfolio value chart data: \(filteredData.count) legacy cached points for range \(timeRange.rawValue)")
                return filteredData
            }
            
            // Final fallback to real-time snapshots
            let data = portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
                .sorted { $0.date < $1.date }
            logger.debug("📊 Portfolio value chart data: \(data.count) real-time fallback points for range \(timeRange.rawValue)")
            return data
            
        case .portfolioGains:
            // NEW: Use stored portfolio gains if available
            if !historicalPortfolioSnapshots.isEmpty {
                let data = getStoredPortfolioGains(for: timeRange)
                logger.debug("📊 Portfolio gains chart data: \(data.count) stored portfolio points for range \(timeRange.rawValue)")
                
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
                    logger.info("📊 Portfolio gains chart: Triggering background retroactive calculation")
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
                logger.debug("📊 Portfolio gains chart data: \(gainsData.count) legacy cached points for range \(timeRange.rawValue)")
                return gainsData
            }
            
            // Final fallback to real-time snapshots
            let data = portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalGains) }
                .sorted { $0.date < $1.date }
            logger.debug("📊 Portfolio gains chart data: \(data.count) real-time fallback points for range \(timeRange.rawValue)")
            return data
            
        case .individualStock(let symbol):
            let startDate = timeRange.startDate(from: Date())
            return getOptimalStockData(for: symbol, timeRange: timeRange, startDate: startDate)
        }
    }
    
    /// Gets stock data for charts with increased data limits
    private func getOptimalStockData(for symbol: String, timeRange: ChartTimeRange, startDate: Date) -> [ChartDataPoint] {
        let allSnapshots = priceSnapshots[symbol] ?? []
        
        // Filter and convert to chart data points
        let filteredData = allSnapshots
            .filter { $0.timestamp >= startDate }
            .map { ChartDataPoint(date: $0.timestamp, value: $0.price, symbol: symbol) }
            .sorted { $0.date < $1.date }
        
        logger.debug("📊 Stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count) points")
        
        return filteredData
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
        
        // Calculate volatility (standard deviation of daily returns)
        let dailyReturns = zip(relevantSnapshots.dropFirst(), relevantSnapshots).map { current, previous in
            (current.totalValue - previous.totalValue) / previous.totalValue * 100
        }
        
        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance)
        
        let maxValue = relevantSnapshots.map { $0.totalValue }.max() ?? lastSnapshot.totalValue
        let minValue = relevantSnapshots.map { $0.totalValue }.min() ?? lastSnapshot.totalValue
        
        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: lastSnapshot.currency,
            startDate: firstSnapshot.timestamp,
            endDate: lastSnapshot.timestamp
        )
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
        
        // Calculate volatility (standard deviation of daily returns)
        let dailyReturns = zip(relevantSnapshots.dropFirst(), relevantSnapshots).map { current, previous in
            (current.price - previous.price) / previous.price * 100
        }
        
        let meanReturn = dailyReturns.isEmpty ? 0 : dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.isEmpty ? 0 : dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance)
        
        let maxValue = relevantSnapshots.map { $0.price }.max() ?? lastSnapshot.price
        let minValue = relevantSnapshots.map { $0.price }.min() ?? lastSnapshot.price
        
        // Determine currency for the stock
        let currency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
        
        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: currency,
            startDate: firstSnapshot.timestamp,
            endDate: lastSnapshot.timestamp
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
            logger.warning("📊 Aggressive cleanup: reducing to \(targetLimit) snapshots per symbol (total: \(totalSnapshots))")
        } else if totalSnapshots > 20000 {
            // Moderate cleanup for large datasets
            targetLimit = 2000
            logger.info("📊 Moderate cleanup: reducing to \(targetLimit) snapshots per symbol (total: \(totalSnapshots))")
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
                logger.debug("📊 Trimmed \(symbol) from \(snapshots.count) to \(targetLimit) snapshots")
            }
        }
        
        let newTotal = priceSnapshots.values.map { $0.count }.reduce(0, +)
        if newTotal != totalSnapshots {
            logger.info("📊 Data cleanup completed: \(totalSnapshots) → \(newTotal) snapshots")
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
            logger.warning("Price validation failed for \(symbol): current=\(price), median=\(medianPrice), diff=\(percentageDifference * 100)%")
        }
        
        return isValid
    }
    
    private func loadHistoricalData() {
        // Load legacy portfolio snapshots
        if let data = UserDefaults.standard.object(forKey: StorageKeys.portfolioSnapshots) as? Data {
            do {
                portfolioSnapshots = try decoder.decode([PortfolioSnapshot].self, from: data)
                logger.info("Loaded \(portfolioSnapshots.count) legacy portfolio snapshots")
            } catch {
                logger.error("Failed to load legacy portfolio snapshots: \(error.localizedDescription)")
            }
        }
        
        // Load price snapshots (daily data)
        if let data = UserDefaults.standard.object(forKey: StorageKeys.priceSnapshots) as? Data {
            do {
                priceSnapshots = try decoder.decode([String: [PriceSnapshot]].self, from: data)
                let totalSnapshots = priceSnapshots.values.reduce(0) { $0 + $1.count }
                logger.info("Loaded daily price snapshots for \(priceSnapshots.count) symbols (\(totalSnapshots) total)")
            } catch {
                logger.error("Failed to load daily price snapshots: \(error.localizedDescription)")
            }
        }
        
        // Load new historical portfolio snapshots
        if let data = UserDefaults.standard.object(forKey: StorageKeys.historicalPortfolioSnapshots) as? Data {
            do {
                historicalPortfolioSnapshots = try decoder.decode([HistoricalPortfolioSnapshot].self, from: data)
                logger.info("Loaded \(historicalPortfolioSnapshots.count) historical portfolio snapshots")
            } catch {
                logger.error("Failed to load historical portfolio snapshots: \(error.localizedDescription)")
                historicalPortfolioSnapshots = []
            }
        }
        
        // Load current portfolio composition
        if let data = UserDefaults.standard.object(forKey: StorageKeys.currentPortfolioComposition) as? Data {
            do {
                currentPortfolioComposition = try decoder.decode(PortfolioComposition.self, from: data)
                logger.info("Loaded current portfolio composition")
            } catch {
                logger.error("Failed to load portfolio composition: \(error.localizedDescription)")
            }
        }
        
        // Load last retroactive calculation date
        if let date = UserDefaults.standard.object(forKey: StorageKeys.lastRetroactiveCalculationDate) as? Date {
            lastRetroactiveCalculationDate = date
            logger.info("Loaded last retroactive calculation date: \(DateFormatter.debug.string(from: date))")
        }
        
        // Load cached historical portfolio values to avoid recalculation (legacy)
        if let data = UserDefaults.standard.object(forKey: StorageKeys.cachedHistoricalPortfolioValues) as? Data {
            do {
                cachedHistoricalPortfolioValues = try decoder.decode([ChartDataPoint].self, from: data)
                logger.info("Loaded \(cachedHistoricalPortfolioValues.count) cached portfolio values - avoiding recalculation")
            } catch {
                logger.error("Failed to load cached portfolio values: \(error.localizedDescription)")
                cachedHistoricalPortfolioValues = []
            }
        }
        
        // Load last portfolio calculation date (legacy)
        if let date = UserDefaults.standard.object(forKey: StorageKeys.lastPortfolioCalculationDate) as? Date {
            lastPortfolioCalculationDate = date
            logger.info("Loaded last portfolio calculation date: \(DateFormatter.debug.string(from: date))")
        }
        
    }
    
    func saveHistoricalData() {
        // Capture current state for background processing
        let currentPortfolioSnapshots = portfolioSnapshots
        let currentPriceSnapshots = priceSnapshots
        let currentHistoricalPortfolioSnapshots = historicalPortfolioSnapshots
        let currentPortfolioComposition = currentPortfolioComposition
        let currentRetroactiveCalculationDate = lastRetroactiveCalculationDate
        let currentCachedPortfolioValues = cachedHistoricalPortfolioValues
        let currentCalculationDate = lastPortfolioCalculationDate
        
        // Move heavy encoding operations to background queue
        Task.detached(priority: .utility) { [encoder, logger] in
            do {
                // Encode all data in background
                let portfolioData = try encoder.encode(currentPortfolioSnapshots)
                let priceData = try encoder.encode(currentPriceSnapshots)
                let historicalPortfolioData = try encoder.encode(currentHistoricalPortfolioSnapshots)
                let compositionData = try currentPortfolioComposition.map { try encoder.encode($0) }
                let cachedPortfolioData = try encoder.encode(currentCachedPortfolioValues)
                
                // Update UserDefaults on main actor
                await MainActor.run {
                    UserDefaults.standard.set(portfolioData, forKey: StorageKeys.portfolioSnapshots)
                    UserDefaults.standard.set(priceData, forKey: StorageKeys.priceSnapshots)
                    UserDefaults.standard.set(historicalPortfolioData, forKey: StorageKeys.historicalPortfolioSnapshots)
                    if let compositionData = compositionData {
                        UserDefaults.standard.set(compositionData, forKey: StorageKeys.currentPortfolioComposition)
                    }
                    UserDefaults.standard.set(currentRetroactiveCalculationDate, forKey: StorageKeys.lastRetroactiveCalculationDate)
                    UserDefaults.standard.set(cachedPortfolioData, forKey: StorageKeys.cachedHistoricalPortfolioValues)
                    UserDefaults.standard.set(currentCalculationDate, forKey: StorageKeys.lastPortfolioCalculationDate)
                }
                
                logger.debug("Saved historical data (including enhanced portfolio snapshots)")
            } catch {
                logger.error("Failed to save historical data: \(error.localizedDescription)")
            }
        }
    }
    
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
            logger.info("📊 Performing periodic maintenance on \(totalSnapshots) snapshots")
            
            // Force more aggressive cleanup during maintenance
            let originalMaxDataPoints = maxDataPoints
            
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
            logger.info("📊 Maintenance cleanup: \(totalSnapshots) → \(newTotal) snapshots")
            
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
        
        logger.info("Cleared all historical data including enhanced portfolio snapshots")
    }
    
    func clearInconsistentData() {
        // Clear all portfolio snapshots since they were calculated with inconsistent methods
        portfolioSnapshots.removeAll()
        cachedHistoricalPortfolioValues.removeAll()
        lastPortfolioCalculationDate = Date.distantPast
        UserDefaults.standard.removeObject(forKey: "portfolioSnapshots")
        UserDefaults.standard.removeObject(forKey: "cachedHistoricalPortfolioValues")
        UserDefaults.standard.removeObject(forKey: "lastPortfolioCalculationDate")
        logger.info("Cleared inconsistent portfolio historical data and cache - will rebuild with correct calculations")
    }
    
    func forceSnapshot(from dataModel: DataModel) {
        logger.info("🔧 FORCING snapshot for debugging")
        let originalInterval = snapshotInterval
        let originalLastTime = lastSnapshotTime
        
        // Temporarily bypass the interval check
        lastSnapshotTime = Date.distantPast
        recordSnapshot(from: dataModel)
        
        logger.info("🔧 Forced snapshot complete. Portfolio snapshots: \(portfolioSnapshots.count), Price snapshots: \(priceSnapshots.count)")
    }
    
    func cleanAnomalousData() {
        var removedCount = 0
        
        // Get current portfolio value for comparison
        let currentValue = getCurrentPortfolioValue()
        let reasonableRange = (currentValue * 0.6)...(currentValue * 1.4) // Allow 40% variance
        
        logger.info("🧹 Cleaning anomalous data. Current portfolio value: £\(String(format: "%.2f", currentValue))")
        logger.info("🧹 Acceptable range: £\(String(format: "%.2f", reasonableRange.lowerBound)) - £\(String(format: "%.2f", reasonableRange.upperBound))")
        
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
                logger.debug("🧹 Removing portfolio snapshot: £\(String(format: "%.2f", snapshot.totalValue)) at \(snapshot.timestamp)")
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
            logger.info("🧹 Cleaned \(removedCount) anomalous data points from historical data")
        } else {
            logger.info("🧹 No anomalous data found during cleanup")
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
        logger.info("Cleared historical data for symbol: \(symbol) (all data tiers)")
    }
    
    func clearDataForSymbols(_ symbols: [String]) {
        for symbol in symbols {
            priceSnapshots.removeValue(forKey: symbol)
        }
        saveHistoricalData()
        logger.info("Cleared historical data for \(symbols.count) symbols: \(symbols) (all data tiers)")
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
        logger.debug("Adding \(snapshots.count) imported snapshots for \(symbol)")
        
        if priceSnapshots[symbol] == nil {
            priceSnapshots[symbol] = []
        }
        
        // Get existing days that already have data to avoid duplicates
        let existingDays = Set(priceSnapshots[symbol]?.map { Calendar.current.startOfDay(for: $0.timestamp) } ?? [])
        
        logger.debug("🔍 DUPLICATE FILTER: \(symbol) has existing data for \(existingDays.count) days")
        if !existingDays.isEmpty {
            let sortedExistingDays = existingDays.sorted()
            logger.debug("🔍 DUPLICATE FILTER: First existing day: \(DateFormatter.debug.string(from: sortedExistingDays.first!))")
            logger.debug("🔍 DUPLICATE FILTER: Last existing day: \(DateFormatter.debug.string(from: sortedExistingDays.last!))")
        }
        
        // Filter out snapshots for days that already have data (preserve existing data)
        let newSnapshots = snapshots.filter { snapshot in
            let snapshotDay = Calendar.current.startOfDay(for: snapshot.timestamp)
            return !existingDays.contains(snapshotDay)
        }
        
        logger.debug("🔍 DUPLICATE FILTER: Filtered \(snapshots.count) snapshots down to \(newSnapshots.count) new snapshots for \(symbol)")
        
        if !newSnapshots.isEmpty {
            priceSnapshots[symbol]?.append(contentsOf: newSnapshots)
            
            // Sort by timestamp to maintain chronological order
            priceSnapshots[symbol]?.sort { $0.timestamp < $1.timestamp }
            
            // Clean up old data if we exceed the limit
            if let count = priceSnapshots[symbol]?.count, count > maxDataPoints {
                priceSnapshots[symbol] = Array(priceSnapshots[symbol]?.suffix(maxDataPoints) ?? [])
                logger.debug("Trimmed \(symbol) snapshots to \(maxDataPoints) most recent")
            }
            
            // Save the updated data
            saveHistoricalData()
            
            logger.info("Added \(newSnapshots.count) new historical snapshots for \(symbol) (filtered from \(snapshots.count) total)")
            
            // Invalidate portfolio cache when new historical data is added
            cachedHistoricalPortfolioValues.removeAll()
            lastPortfolioCalculationDate = Date.distantPast
            logger.debug("📊 Invalidated portfolio cache due to new historical data for \(symbol)")
        } else {
            logger.debug("No new snapshots to add for \(symbol) - all would be duplicates")
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
        
        logger.debug("Data coverage for \(symbol): \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))%)")
        
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
        logger.info("📊 COMPREHENSIVE: Starting 5-year historical portfolio value calculation in monthly chunks")
        
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
        
        logger.info("📊 COMPREHENSIVE: Earliest available data: \(DateFormatter.debug.string(from: earliestDataDate))")
        logger.info("📊 COMPREHENSIVE: Calculating portfolio values from \(DateFormatter.debug.string(from: actualStartDate)) to \(DateFormatter.debug.string(from: endDate))")
        
        var allPortfolioValues: [ChartDataPoint] = []
        var currentDate = actualStartDate
        var monthCount = 0
        
        // Process one month at a time
        while currentDate < endDate {
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: currentDate) ?? endDate
            let actualMonthEnd = min(monthEnd, endDate)
            
            monthCount += 1
            logger.info("📊 COMPREHENSIVE: Processing month \(monthCount) - \(DateFormatter.debug.string(from: currentDate)) to \(DateFormatter.debug.string(from: actualMonthEnd))")
            
            // Calculate portfolio values for this month
            let monthValues = await calculateHistoricalPortfolioValuesForPeriod(
                from: currentDate, 
                to: actualMonthEnd, 
                using: dataModel
            )
            
            if !monthValues.isEmpty {
                allPortfolioValues.append(contentsOf: monthValues)
                logger.info("📊 COMPREHENSIVE: Month \(monthCount) added \(monthValues.count) portfolio values")
                
                // Update cache with accumulated values so far (provides progress feedback)
                await MainActor.run {
                    self.cachedHistoricalPortfolioValues = allPortfolioValues.sorted { $0.date < $1.date }
                    self.lastPortfolioCalculationDate = Date()
                }
            } else {
                logger.warning("📊 COMPREHENSIVE: Month \(monthCount) yielded no portfolio values")
            }
            
            // Move to next month
            currentDate = monthEnd
            
            // Reduced delay between months to improve responsiveness (3 seconds instead of 10)
            if currentDate < endDate {
                logger.info("📊 COMPREHENSIVE: Waiting 3 seconds before processing next month...")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        
        // Final update with all calculated values
        await MainActor.run {
            self.cachedHistoricalPortfolioValues = allPortfolioValues.sorted { $0.date < $1.date }
            self.lastPortfolioCalculationDate = Date()
        }
        
        logger.info("📊 COMPREHENSIVE: Completed 5-year calculation with \(allPortfolioValues.count) total portfolio values across \(monthCount) months")
    }
    
    /// Calculates historical portfolio values for a specific time period
    private func calculateHistoricalPortfolioValuesForPeriod(from startDate: Date, to endDate: Date, using dataModel: DataModel) async -> [ChartDataPoint] {
        let calendar = Calendar.current
        let currencyConverter = CurrencyConverter()
        let preferredCurrency = dataModel.preferredCurrency
        
        // Debug: Show what symbols we're working with
        let symbols = dataModel.realTimeTrades.map { $0.trade.name }
        logger.debug("📊 PERIOD CALC: Processing symbols: \(symbols)")
        
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
        
        logger.debug("📊 PERIOD CALC: Data availability for \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)):")
        for (symbol, count) in symbolDataCounts {
            logger.debug("📊 PERIOD CALC: - \(symbol): \(count) data points")
        }
        
        guard !allDates.isEmpty else {
            logger.warning("📊 PERIOD CALC: No historical price data available for period \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate))")
            return []
        }
        
        var portfolioValues: [ChartDataPoint] = []
        let sortedDates = Array(allDates.sorted())
        
        logger.debug("📊 PERIOD CALC: Processing \(sortedDates.count) unique dates for period \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate))")
        
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
                            logger.debug("📊 PERIOD CALC: \(symbol) on \(DateFormatter.debug.string(from: date)): price=\(historicalPrice), value=\(valueInUSD) USD (snapshot age: \(daysDifference) days)")
                        }
                    } else {
                        if index < 3 || validDatesCount % 20 == 0 {
                            logger.debug("📊 PERIOD CALC: Rejected \(symbol) on \(DateFormatter.debug.string(from: date)): price=\(historicalPrice), units=\(units), age=\(daysDifference) days")
                        }
                    }
                } else {
                    if index < 3 || validDatesCount % 20 == 0 {
                        logger.debug("📊 PERIOD CALC: No data found for \(symbol) on \(DateFormatter.debug.string(from: date))")
                    }
                }
            }
            
            // Accept portfolio value if we have data for at least 50% of symbols (more lenient)
            let hasValidData = symbolsWithData >= max(1, symbolsProcessed / 2)
            
            if hasValidData {
                validDatesCount += 1
                if index < 3 || validDatesCount % 10 == 0 { // Log first few and every 10th valid date
                    logger.debug("📊 PERIOD CALC: Date \(DateFormatter.debug.string(from: date)): \(symbolsWithData)/\(symbolsProcessed) symbols, totalUSD=\(totalValueUSD)")
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
                    logger.debug("📊 PERIOD CALC: Rejected date \(DateFormatter.debug.string(from: date)): only \(symbolsWithData)/\(symbolsProcessed) symbols have valid data")
                }
            }
            
            // Yield every 50 calculations to keep UI responsive
            if index % 50 == 0 {
                await Task.yield()
            }
        }
        
        logger.debug("📊 PERIOD CALC: Summary for \(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)): \(validDatesCount)/\(sortedDates.count) dates yielded portfolio values, result: \(portfolioValues.count) data points")
        
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
            logger.warning("📊 Large dataset (\(totalSnapshots) snapshots) - using 3-month window with sampling")
        } else if totalSnapshots > 25000 {
            // For large datasets, limit to 6 months
            startDate = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
            logger.info("📊 Medium dataset (\(totalSnapshots) snapshots) - using 6-month window")
        } else {
            // For reasonable datasets, use 1 year
            startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            logger.debug("📊 Processing \(totalSnapshots) snapshots with 1-year window")
        }
        
        logger.debug("📊 Starting background calculation of historical portfolio values")
        
        let portfolioValues = await calculateHistoricalPortfolioValues(from: startDate, using: dataModel, useSampling: useSampling)
        
        await MainActor.run {
            self.cachedHistoricalPortfolioValues = portfolioValues
            self.lastPortfolioCalculationDate = Date()
            logger.debug("📊 Cached \(portfolioValues.count) historical portfolio values")
        }
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
            logger.debug("📊 No historical price data available for portfolio calculation")
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
            logger.debug("📊 Sampling \(sortedDates.count) dates from \(sortedAllDates.count) total dates (step: \(step))")
        } else {
            // For smaller datasets, use all data but limit to reasonable amount
            sortedDates = Array(sortedAllDates.suffix(800))
            logger.debug("📊 Using \(sortedDates.count) dates from \(sortedAllDates.count) total dates")
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
        
        logger.debug("📊 Calculated \(portfolioValues.count) historical portfolio values from \(sortedDates.count) dates")
        return portfolioValues.sorted { $0.date < $1.date }
    }
    
    /// Finds the closest historical snapshot to a given date using optimized binary search
    private func findClosestSnapshot(in snapshots: [PriceSnapshot], to targetDate: Date) -> PriceSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        
        // Ensure snapshots are sorted by timestamp for binary search
        let sortedSnapshots = snapshots.sorted { $0.timestamp < $1.timestamp }
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
    
    // MARK: - Debug Methods
    
    /// Gets the current snapshot interval for debug purposes
    func getSnapshotInterval() -> TimeInterval {
        return snapshotInterval
    }
    
    /// Sets the snapshot interval for debug purposes
    func setSnapshotInterval(_ interval: TimeInterval) {
        snapshotInterval = interval
        logger.info("📊 Snapshot interval changed to \(interval) seconds")
    }
    
    /// Manually triggers data cleanup for all symbols
    func optimizeAllDataStorage() {
        logger.info("📊 MANUAL OPTIMIZATION: Starting data cleanup for all symbols")
        
        // Simply clean up old data to ensure we stay within limits
        cleanupOldData()
        
        saveHistoricalData()
        logger.info("📊 MANUAL OPTIMIZATION: Completed data cleanup")
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
    func calculateRetroactivePortfolioHistory(using dataModel: DataModel) async {
        logger.info("🔄 RETROACTIVE: Starting comprehensive portfolio history calculation")
        
        // Create current portfolio composition for tracking changes
        let newComposition = createPortfolioComposition(from: dataModel)
        
        // Check if portfolio composition has changed
        let needsFullRecalculation = hasPortfolioCompositionChanged(newComposition)
        
        if needsFullRecalculation {
            logger.info("🔄 RETROACTIVE: Portfolio composition changed - full recalculation needed")
            await performFullPortfolioRecalculation(using: dataModel, composition: newComposition)
        } else {
            logger.info("🔄 RETROACTIVE: Portfolio composition unchanged - incremental update")
            await performIncrementalPortfolioUpdate(using: dataModel)
        }
        
        // Update composition tracking
        await MainActor.run {
            self.currentPortfolioComposition = newComposition
            self.lastRetroactiveCalculationDate = Date()
        }
        
        // Save updated data
        saveHistoricalData()
        
        logger.info("🔄 RETROACTIVE: Portfolio history calculation completed")
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
        logger.info("🔄 FULL RECALC: Starting full portfolio history recalculation")
        
        // Clear existing portfolio snapshots
        await MainActor.run {
            self.historicalPortfolioSnapshots.removeAll()
        }
        
        // Find the earliest available historical data
        let earliestDate = findEarliestHistoricalData()
        let endDate = Date()
        
        logger.info("🔄 FULL RECALC: Calculating from \(DateFormatter.debug.string(from: earliestDate)) to \(DateFormatter.debug.string(from: endDate))")
        
        // Calculate portfolio values for the entire historical period
        let snapshots = await calculatePortfolioSnapshotsForPeriod(
            from: earliestDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        await MainActor.run {
            self.historicalPortfolioSnapshots = snapshots.sorted { $0.date < $1.date }
        }
        
        logger.info("🔄 FULL RECALC: Generated \(snapshots.count) portfolio snapshots")
    }
    
    /// Performs incremental portfolio update for new dates only
    private func performIncrementalPortfolioUpdate(using dataModel: DataModel) async {
        let lastCalculatedDate = getLastPortfolioSnapshotDate()
        let endDate = Date()
        
        // Only calculate if there's a meaningful gap (more than 1 day)
        guard endDate.timeIntervalSince(lastCalculatedDate) > 86400 else {
            logger.debug("🔄 INCREMENTAL: No significant time gap, skipping update")
            return
        }
        
        logger.info("🔄 INCREMENTAL: Updating from \(DateFormatter.debug.string(from: lastCalculatedDate)) to \(DateFormatter.debug.string(from: endDate))")
        
        let newSnapshots = await calculatePortfolioSnapshotsForPeriod(
            from: lastCalculatedDate,
            to: endDate,
            using: dataModel,
            composition: currentPortfolioComposition!
        )
        
        await MainActor.run {
            self.historicalPortfolioSnapshots.append(contentsOf: newSnapshots)
            self.historicalPortfolioSnapshots.sort { $0.date < $1.date }
            
            // Clean up if we exceed the limit
            if self.historicalPortfolioSnapshots.count > maxPortfolioSnapshots {
                self.historicalPortfolioSnapshots = Array(self.historicalPortfolioSnapshots.suffix(maxPortfolioSnapshots))
            }
        }
        
        logger.info("🔄 INCREMENTAL: Added \(newSnapshots.count) new portfolio snapshots")
    }
    
    /// Calculates portfolio snapshots for a specific date range
    private func calculatePortfolioSnapshotsForPeriod(
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
            logger.warning("🔄 CALC PERIOD: No historical data available for period")
            return []
        }
        
        var portfolioSnapshots: [HistoricalPortfolioSnapshot] = []
        let sortedDates = Array(allDates.sorted())
        
        logger.debug("🔄 CALC PERIOD: Processing \(sortedDates.count) unique dates")
        
        // Calculate total investment cost (what was originally paid)
        let totalInvestmentCost = calculateTotalInvestmentCost(composition: composition, currencyConverter: currencyConverter, preferredCurrency: preferredCurrency)
        
        for (index, date) in sortedDates.enumerated() {
            // Yield control periodically
            if index % 20 == 0 {
                await Task.yield()
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
                guard !price.isNaN && price > 0 else { continue }
                
                let valueAtDate = price * position.units
                
                // Convert to USD for aggregation
                var valueInUSD = valueAtDate
                if position.currency == "GBP" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: "GBP", to: "USD")
                } else if position.currency != "USD" {
                    valueInUSD = currencyConverter.convert(amount: valueAtDate, from: position.currency, to: "USD")
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
            
            // Only create portfolio snapshot if we have data for at least 50% of positions
            guard validPositions >= max(1, composition.positions.count / 2) else {
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
        
        logger.debug("🔄 CALC PERIOD: Generated \(portfolioSnapshots.count) snapshots from \(sortedDates.count) dates")
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
        
        let filteredSnapshots = historicalPortfolioSnapshots
            .filter { $0.date >= startDate }
            .sorted { $0.date < $1.date }
        
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
    
    var formattedTotalReturn: String {
        return String(format: "%+.2f %@", totalReturn, currency)
    }
    
    var formattedTotalReturnPercent: String {
        return String(format: "%+.2f%%", totalReturnPercent)
    }
    
    var formattedVolatility: String {
        return String(format: "%.2f%%", volatility)
    }
}