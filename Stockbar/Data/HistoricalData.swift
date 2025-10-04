import Foundation

struct PriceSnapshot: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let price: Double
    let previousClose: Double
    let volume: Double?
    let symbol: String
    
    init(timestamp: Date, price: Double, previousClose: Double, volume: Double? = nil, symbol: String) {
        self.timestamp = timestamp
        self.price = price
        self.previousClose = previousClose
        self.volume = volume
        self.symbol = symbol
    }
    
    var dayChange: Double {
        return price - previousClose
    }
    
    var dayChangePercent: Double {
        guard previousClose > 0 else { return 0 }
        return (dayChange / previousClose) * 100
    }
}

struct PortfolioSnapshot: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let totalValue: Double
    let totalGains: Double
    let currency: String
    let priceSnapshots: [PriceSnapshot]
    
    init(timestamp: Date, totalValue: Double, totalGains: Double, currency: String, priceSnapshots: [PriceSnapshot]) {
        self.timestamp = timestamp
        self.totalValue = totalValue
        self.totalGains = totalGains
        self.currency = currency
        self.priceSnapshots = priceSnapshots
    }
}

enum ChartTimeRange: String, CaseIterable {
    case day = "1D"
    case week = "1W"
    case month = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case year = "1Y"
    case all = "All"
    case custom = "Custom"

    var description: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .year: return "1 Year"
        case .all: return "All Time"
        case .custom: return "Custom"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .threeMonths: return 90 * 24 * 60 * 60
        case .sixMonths: return 180 * 24 * 60 * 60
        case .year: return 365 * 24 * 60 * 60
        case .all: return TimeInterval.greatestFiniteMagnitude
        case .custom: return 0 // Custom range handled separately
        }
    }

    /// yfinance period parameter
    var yfinancePeriod: String {
        switch self {
        case .day: return "1d"
        case .week: return "5d"
        case .month: return "1mo"
        case .threeMonths: return "3mo"
        case .sixMonths: return "6mo"
        case .year: return "1y"
        case .all: return "max"
        case .custom: return "1mo" // Default for custom
        }
    }

    /// Suggested interval for this time range
    var suggestedInterval: String {
        switch self {
        case .day: return "5m"
        case .week: return "15m"
        case .month: return "1h"
        case .threeMonths: return "1d"
        case .sixMonths: return "1d"
        case .year: return "1wk"
        case .all: return "1wk"
        case .custom: return "1d"
        }
    }

    func startDate(from endDate: Date = Date()) -> Date {
        switch self {
        case .all:
            // Use a reasonable past date instead of distantPast to ensure all historical data is included
            // Go back 10 years which should cover any reasonable historical data
            return endDate.addingTimeInterval(-10 * 365 * 24 * 60 * 60)
        case .custom:
            // Custom range will be handled by customStartDate in PerformanceChartView
            return endDate.addingTimeInterval(-30 * 24 * 60 * 60) // Default to 30 days
        default:
            return endDate.addingTimeInterval(-timeInterval)
        }
    }
}

struct ChartDataPoint: Identifiable, Codable {
    let id = UUID()
    let date: Date
    let value: Double
    let symbol: String?
    
    init(date: Date, value: Double, symbol: String? = nil) {
        self.date = date
        self.value = value
        self.symbol = symbol
    }
}

// MARK: - Enhanced Portfolio Snapshot Structures

struct HistoricalPortfolioSnapshot: Codable, Identifiable {
    let id = UUID()
    let date: Date
    let totalValue: Double
    let totalGains: Double
    let totalCost: Double // Initial investment amount
    let currency: String
    let portfolioComposition: [String: PositionSnapshot] // Track individual positions
    
    init(date: Date, totalValue: Double, totalGains: Double, totalCost: Double, currency: String, portfolioComposition: [String: PositionSnapshot]) {
        self.date = date
        self.totalValue = totalValue
        self.totalGains = totalGains
        self.totalCost = totalCost
        self.currency = currency
        self.portfolioComposition = portfolioComposition
    }
}

struct PositionSnapshot: Codable {
    let symbol: String
    let units: Double
    let priceAtDate: Double
    let valueAtDate: Double
    let currency: String
    
    init(symbol: String, units: Double, priceAtDate: Double, valueAtDate: Double, currency: String) {
        self.symbol = symbol
        self.units = units
        self.priceAtDate = priceAtDate
        self.valueAtDate = valueAtDate
        self.currency = currency
    }
}

// MARK: - Portfolio Composition Tracking

struct PortfolioComposition: Codable, Hashable {
    let positions: [PortfolioPosition]
    let compositionHash: String
    
    init(positions: [PortfolioPosition]) {
        self.positions = positions
        self.compositionHash = Self.generateHash(from: positions)
    }
    
    private static func generateHash(from positions: [PortfolioPosition]) -> String {
        let combined = positions.sorted { $0.symbol < $1.symbol }
            .map { "\($0.symbol):\($0.units):\($0.avgCost)" }
            .joined(separator: "|")
        return String(combined.hashValue)
    }
}

struct PortfolioPosition: Codable, Hashable {
    let symbol: String
    let units: Double
    let avgCost: Double
    let currency: String
    
    init(symbol: String, units: Double, avgCost: Double, currency: String) {
        self.symbol = symbol
        self.units = units
        self.avgCost = avgCost
        self.currency = currency
    }
}

enum ChartType {
    case portfolioValue
    case portfolioGains
    case individualStock(String)
    
    var title: String {
        switch self {
        case .portfolioValue:
            return "Portfolio Value"
        case .portfolioGains:
            return "Portfolio Gains"
        case .individualStock(let symbol):
            return "\(symbol) Price"
        }
    }
}

// MARK: - Portfolio Analytics

struct PortfolioAnalytics: Codable {
    let timeRange: String
    let calculatedAt: Date
    
    // Performance Metrics
    let totalReturn: Double          // Absolute return amount
    let totalReturnPercent: Double   // Return percentage
    let annualizedReturn: Double     // Annualized return percentage
    
    // Risk Metrics
    let volatility: Double           // Standard deviation of daily returns
    let sharpeRatio: Double          // Risk-adjusted return
    let maxDrawdown: Double          // Maximum peak-to-trough decline
    let maxDrawdownPercent: Double   // Maximum decline percentage
    
    // Value Statistics
    let minValue: Double             // Minimum portfolio value in period
    let maxValue: Double             // Maximum portfolio value in period
    let averageValue: Double         // Average portfolio value
    let finalValue: Double           // Current/final portfolio value
    let initialValue: Double         // Starting portfolio value
    
    // Trading Performance
    let winningDays: Int             // Days with positive returns
    let losingDays: Int              // Days with negative returns
    let totalDays: Int               // Total days analyzed
    let winRate: Double              // Percentage of winning days
    
    // Additional Metrics
    let currency: String             // Portfolio currency
    let bestDay: Double              // Best single day return
    let worstDay: Double             // Worst single day return
    let consecutiveWins: Int         // Longest winning streak
    let consecutiveLosses: Int       // Longest losing streak
    
    init(
        timeRange: String,
        calculatedAt: Date = Date(),
        totalReturn: Double,
        totalReturnPercent: Double,
        annualizedReturn: Double,
        volatility: Double,
        sharpeRatio: Double,
        maxDrawdown: Double,
        maxDrawdownPercent: Double,
        minValue: Double,
        maxValue: Double,
        averageValue: Double,
        finalValue: Double,
        initialValue: Double,
        winningDays: Int,
        losingDays: Int,
        totalDays: Int,
        winRate: Double,
        currency: String,
        bestDay: Double,
        worstDay: Double,
        consecutiveWins: Int,
        consecutiveLosses: Int
    ) {
        self.timeRange = timeRange
        self.calculatedAt = calculatedAt
        self.totalReturn = totalReturn
        self.totalReturnPercent = totalReturnPercent
        self.annualizedReturn = annualizedReturn
        self.volatility = volatility
        self.sharpeRatio = sharpeRatio
        self.maxDrawdown = maxDrawdown
        self.maxDrawdownPercent = maxDrawdownPercent
        self.minValue = minValue
        self.maxValue = maxValue
        self.averageValue = averageValue
        self.finalValue = finalValue
        self.initialValue = initialValue
        self.winningDays = winningDays
        self.losingDays = losingDays
        self.totalDays = totalDays
        self.winRate = winRate
        self.currency = currency
        self.bestDay = bestDay
        self.worstDay = worstDay
        self.consecutiveWins = consecutiveWins
        self.consecutiveLosses = consecutiveLosses
    }
}

// MARK: - Performance Optimization Types

struct PerformanceStats {
    let compressionStats: CompressionStats
    let memoryStats: MemoryStats
    let chartCacheStats: ChartCacheStats
    let totalDataPoints: Int
    let coreDataStorageSize: Double // MB
    
    var overallHealthScore: Double {
        var score = 100.0
        
        // Memory usage impact (0-30 points)
        let memoryImpact = min(30, (memoryStats.usagePercentage / 100.0) * 30)
        score -= memoryImpact
        
        // Cache efficiency impact (0-20 points)
        let cacheEfficiency = chartCacheStats.cacheHitRatio * 20
        score = score - 20 + cacheEfficiency
        
        // Compression benefit (0-20 points)
        let compressionBenefit = compressionStats.compressionRatio * 20
        score += compressionBenefit
        
        // Data density impact (0-30 points)
        let dataDensity = min(30, Double(totalDataPoints) / 100000.0 * 30)
        score -= dataDensity
        
        return max(0, min(100, score))
    }
    
    var performanceLevel: PerformanceLevel {
        let score = overallHealthScore
        if score >= 80 {
            return .excellent
        } else if score >= 60 {
            return .good
        } else if score >= 40 {
            return .fair
        } else {
            return .poor
        }
    }
    
    var recommendations: [String] {
        var suggestions: [String] = []
        
        if memoryStats.memoryStatus != .normal {
            suggestions.append("Consider reducing chart cache size or enabling compression")
        }
        
        if chartCacheStats.cacheHitRatio < 0.5 {
            suggestions.append("Chart cache hit ratio is low - consider prefetching common time ranges")
        }
        
        if compressionStats.compressionRatio > 0.3 {
            suggestions.append("Large amount of compressible data detected - run data compression")
        }
        
        if totalDataPoints > 50000 {
            suggestions.append("Consider archiving very old data to improve performance")
        }
        
        if coreDataStorageSize > 100 {
            suggestions.append("Database size is large - consider running optimization")
        }
        
        return suggestions
    }
}

enum PerformanceLevel {
    case excellent
    case good
    case fair
    case poor
    
    var description: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        }
    }
    
    var color: String {
        switch self {
        case .excellent: return "green"
        case .good: return "blue"
        case .fair: return "orange"
        case .poor: return "red"
        }
    }
}