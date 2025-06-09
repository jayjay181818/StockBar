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