import CryptoKit
import Foundation

struct PriceSnapshot: Codable, Identifiable, Sendable {
    /// Session-only identity for SwiftUI lists. Deliberately excluded from
    /// coding: it was never restored on decode, so persisting it was noise.
    let id = UUID()
    let timestamp: Date
    let price: Double
    let previousClose: Double
    let volume: Double?
    let symbol: String

    private enum CodingKeys: String, CodingKey {
        case timestamp, price, previousClose, volume, symbol
    }
    
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

struct PortfolioSnapshot: Codable, Identifiable, Sendable {
    /// Session-only identity for SwiftUI lists. Deliberately excluded from
    /// coding: it was never restored on decode, so persisting it was noise.
    let id = UUID()
    let timestamp: Date
    let totalValue: Double
    let totalGains: Double
    let currency: String
    let priceSnapshots: [PriceSnapshot]

    private enum CodingKeys: String, CodingKey {
        case timestamp, totalValue, totalGains, currency, priceSnapshots
    }
    
    init(timestamp: Date, totalValue: Double, totalGains: Double, currency: String, priceSnapshots: [PriceSnapshot]) {
        self.timestamp = timestamp
        self.totalValue = totalValue
        self.totalGains = totalGains
        self.currency = currency
        self.priceSnapshots = priceSnapshots
    }
}

enum ChartTimeRange: String, CaseIterable, Sendable {
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
        case .year: return "1d"
        case .all: return "1d"
        case .custom: return "1d"
        }
    }

    var folyncRange: String {
        switch self {
        case .day: "1d"
        case .week: "1w"
        case .month: "1m"
        case .threeMonths: "3m"
        case .sixMonths: "6m"
        case .year: "1y"
        case .all: "all"
        case .custom: "custom"
        }
    }

    /// The one definition of where a range starts: calendar units back from
    /// `endDate`, so "1M" from 31 March is 28 February, not 30 days earlier.
    func startDate(from endDate: Date = Date(), calendar: Calendar = .current) -> Date {
        let step: (component: Calendar.Component, value: Int)
        switch self {
        case .day: step = (.day, -1)
        case .week: step = (.weekOfYear, -1)
        case .month: step = (.month, -1)
        case .threeMonths: step = (.month, -3)
        case .sixMonths: step = (.month, -6)
        case .year: step = (.year, -1)
        // Ten years covers any stored history without using distantPast.
        case .all: step = (.year, -10)
        // A custom range carries its own start; this is only the default.
        case .custom: step = (.month, -1)
        }
        return calendar.date(byAdding: step.component, value: step.value, to: endDate) ?? endDate
    }
}

struct ChartDataPoint: Identifiable, Codable, Sendable {
    /// Session-only identity for SwiftUI lists. Deliberately excluded from
    /// coding: it was never restored on decode, so persisting it was noise.
    let id = UUID()
    let date: Date
    let value: Double
    let symbol: String?

    private enum CodingKeys: String, CodingKey {
        case date, value, symbol
    }
    
    init(date: Date, value: Double, symbol: String? = nil) {
        self.date = date
        self.value = value
        self.symbol = symbol
    }
}

// MARK: - Enhanced Portfolio Snapshot Structures

struct HistoricalPortfolioSnapshot: Codable, Identifiable, Sendable {
    /// Session-only identity for SwiftUI lists. Deliberately excluded from
    /// coding: it was never restored on decode, so persisting it was noise.
    let id = UUID()
    let date: Date
    let totalValue: Double
    let totalGains: Double
    let totalCost: Double // Initial investment amount
    let currency: String
    let portfolioComposition: [String: PositionSnapshot] // Track individual positions

    private enum CodingKeys: String, CodingKey {
        case date, totalValue, totalGains, totalCost, currency, portfolioComposition
    }
    
    init(date: Date, totalValue: Double, totalGains: Double, totalCost: Double, currency: String, portfolioComposition: [String: PositionSnapshot]) {
        self.date = date
        self.totalValue = totalValue
        self.totalGains = totalGains
        self.totalCost = totalCost
        self.currency = currency
        self.portfolioComposition = portfolioComposition
    }
}

/// One stored portfolio snapshot without its positions: all a chart of the
/// portfolio's value reads.
struct StoredPortfolioValue: Sendable, Equatable {
    let date: Date
    let totalValue: Double
    let currency: String
}

struct PositionSnapshot: Codable, Sendable {
    let symbol: String
    let units: Double
    let priceAtDate: Double
    let valueAtDate: Double
    let currency: String
}

// MARK: - Portfolio Composition Tracking

struct PortfolioComposition: Codable, Hashable, Sendable {
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
        // A stable digest: String.hashValue is seeded per process, so a stored
        // hash never matched after relaunch and forced a full recalculation.
        return SHA256.hash(data: Data(combined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PortfolioPosition: Codable, Hashable, Sendable {
    let symbol: String
    let units: Double
    let avgCost: Double
    let currency: String
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
