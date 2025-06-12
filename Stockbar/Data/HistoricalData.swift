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
    
    var description: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .year: return "1 Year"
        case .all: return "All Time"
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
        }
    }
    
    func startDate(from endDate: Date = Date()) -> Date {
        switch self {
        case .all:
            // Use a reasonable past date instead of distantPast to ensure all historical data is included
            // Go back 10 years which should cover any reasonable historical data
            return endDate.addingTimeInterval(-10 * 365 * 24 * 60 * 60)
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