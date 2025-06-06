import Foundation
import Combine

class HistoricalDataManager: ObservableObject {
    static let shared = HistoricalDataManager()
    
    private let logger = Logger.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    @Published private(set) var portfolioSnapshots: [PortfolioSnapshot] = []
    @Published private(set) var priceSnapshots: [String: [PriceSnapshot]] = [:]
    
    private let maxDataPoints = 1000 // Limit stored data points
    private let snapshotInterval: TimeInterval = 300 // 5 minutes
    private var lastSnapshotTime: Date = Date.distantPast
    
    private init() {
        loadHistoricalData()
        setupPeriodicSave()
    }
    
    func recordSnapshot(from dataModel: DataModel) {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotTime) >= snapshotInterval else {
            return // Too soon since last snapshot
        }
        
        lastSnapshotTime = now
        
        var currentPriceSnapshots: [PriceSnapshot] = []
        var hasValidData = false
        
        for trade in dataModel.realTimeTrades {
            let price = trade.realTimeInfo.currentPrice
            let prevClose = trade.realTimeInfo.prevClosePrice
            
            guard !price.isNaN && !prevClose.isNaN && price > 0 else {
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
    
    func getChartData(for type: ChartType, timeRange: ChartTimeRange) -> [ChartDataPoint] {
        let startDate = timeRange.startDate()
        
        switch type {
        case .portfolioValue:
            return portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
                .sorted { $0.date < $1.date }
            
        case .portfolioGains:
            return portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalGains) }
                .sorted { $0.date < $1.date }
            
        case .individualStock(let symbol):
            return priceSnapshots[symbol]?
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.price, symbol: symbol) }
                .sorted { $0.date < $1.date } ?? []
        }
    }
    
    func getPerformanceMetrics(for timeRange: ChartTimeRange) -> PerformanceMetrics? {
        let startDate = timeRange.startDate()
        let relevantSnapshots = portfolioSnapshots.filter { $0.timestamp >= startDate }.sorted { $0.timestamp < $1.timestamp }
        
        guard let firstSnapshot = relevantSnapshots.first,
              let lastSnapshot = relevantSnapshots.last,
              relevantSnapshots.count > 1 else {
            return nil
        }
        
        let totalReturn = lastSnapshot.totalValue - firstSnapshot.totalValue
        let totalReturnPercent = (totalReturn / firstSnapshot.totalValue) * 100
        
        // Calculate volatility (standard deviation of daily returns)
        let dailyReturns = zip(relevantSnapshots.dropFirst(), relevantSnapshots).map { current, previous in
            (current.totalValue - previous.totalValue) / previous.totalValue * 100
        }
        
        let meanReturn = dailyReturns.reduce(0, +) / Double(dailyReturns.count)
        let variance = dailyReturns.map { pow($0 - meanReturn, 2) }.reduce(0, +) / Double(dailyReturns.count)
        let volatility = sqrt(variance)
        
        let maxValue = relevantSnapshots.map { $0.totalValue }.max() ?? 0
        let minValue = relevantSnapshots.map { $0.totalValue }.min() ?? 0
        
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
    
    private func calculateTotalPortfolioValue(from dataModel: DataModel) -> Double {
        var totalValue = 0.0
        
        for trade in dataModel.realTimeTrades {
            let price = trade.realTimeInfo.currentPrice
            let units = trade.trade.position.unitSize
            
            guard !price.isNaN && price > 0 else { continue }
            
            var adjustedPrice = price
            // Convert GBX to GBP for UK stocks
            if trade.trade.name.uppercased().hasSuffix(".L") && trade.realTimeInfo.currency == "GBP" {
                // Price is already in GBP from the conversion in updateWithResult
                adjustedPrice = price
            }
            
            let valueInStockCurrency = adjustedPrice * units
            
            // Convert to preferred currency (USD for now, can be made configurable)
            var valueInUSD = valueInStockCurrency
            if let currency = trade.realTimeInfo.currency, currency != "USD" {
                // Use currency converter if available
                valueInUSD = valueInStockCurrency // For now, assume USD
            }
            
            totalValue += valueInUSD
        }
        
        return totalValue
    }
    
    private func cleanupOldData() {
        // Keep only the most recent data points
        if portfolioSnapshots.count > maxDataPoints {
            portfolioSnapshots = Array(portfolioSnapshots.suffix(maxDataPoints))
        }
        
        // Clean up individual stock data
        for symbol in priceSnapshots.keys {
            if let snapshots = priceSnapshots[symbol], snapshots.count > maxDataPoints {
                priceSnapshots[symbol] = Array(snapshots.suffix(maxDataPoints))
            }
        }
    }
    
    private func loadHistoricalData() {
        // Load portfolio snapshots
        if let data = UserDefaults.standard.object(forKey: "portfolioSnapshots") as? Data {
            do {
                portfolioSnapshots = try decoder.decode([PortfolioSnapshot].self, from: data)
                logger.info("Loaded \(portfolioSnapshots.count) portfolio snapshots")
            } catch {
                logger.error("Failed to load portfolio snapshots: \(error.localizedDescription)")
            }
        }
        
        // Load price snapshots
        if let data = UserDefaults.standard.object(forKey: "priceSnapshots") as? Data {
            do {
                priceSnapshots = try decoder.decode([String: [PriceSnapshot]].self, from: data)
                let totalSnapshots = priceSnapshots.values.reduce(0) { $0 + $1.count }
                logger.info("Loaded price snapshots for \(priceSnapshots.count) symbols (\(totalSnapshots) total)")
            } catch {
                logger.error("Failed to load price snapshots: \(error.localizedDescription)")
            }
        }
    }
    
    private func saveHistoricalData() {
        do {
            // Save portfolio snapshots
            let portfolioData = try encoder.encode(portfolioSnapshots)
            UserDefaults.standard.set(portfolioData, forKey: "portfolioSnapshots")
            
            // Save price snapshots
            let priceData = try encoder.encode(priceSnapshots)
            UserDefaults.standard.set(priceData, forKey: "priceSnapshots")
            
            logger.debug("Saved historical data")
        } catch {
            logger.error("Failed to save historical data: \(error.localizedDescription)")
        }
    }
    
    private func setupPeriodicSave() {
        // Save data every 30 minutes to avoid too frequent writes
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.saveHistoricalData()
        }
    }
    
    func clearAllData() {
        portfolioSnapshots.removeAll()
        priceSnapshots.removeAll()
        UserDefaults.standard.removeObject(forKey: "portfolioSnapshots")
        UserDefaults.standard.removeObject(forKey: "priceSnapshots")
        logger.info("Cleared all historical data")
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