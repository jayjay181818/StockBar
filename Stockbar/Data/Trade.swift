//
//  Trade.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-01.

import Foundation

// Helper function to format price with currency
public func formatPrice(price: Double, currency: String?) -> String {
    guard let currency = currency else { return String(format: "%.2f", price) }
    return "\(currency) \(String(format: "%.2f", price))"
}

struct Trade: Codable, Equatable {
    var name: String
    var position: Position
}

struct Position: Codable, Equatable {
    var unitSizeString: String {
        get {
            return self._unitSize
        }
        set(newUnitSize) {
            if Double(newUnitSize) != nil {
                _unitSize = newUnitSize
            } else {
                _unitSize = "1"
            }
        }
    }
    var unitSize: Double {
        get {
            return Double(unitSizeString) ?? 1
        }
    }
    var positionAvgCostString: String
    var positionAvgCost: Double {
        get {
            return Double(positionAvgCostString) ?? .nan
        }
    }
    private var _unitSize: String
    var currency: String?
    var costCurrency: String? // The currency unit the user entered the cost in (GBX, GBP, USD, etc.)

    init(unitSize: String, positionAvgCost: String, currency: String? = nil, costCurrency: String? = nil) {
        self._unitSize = "1"
        self.positionAvgCostString = positionAvgCost
        self.unitSizeString = unitSize
        self.currency = currency
        self.costCurrency = costCurrency
    }
    
    /// Returns the average cost normalized to GBP for UK stocks, or the original value for other stocks
    func getNormalizedAvgCost(for symbol: String) -> Double {
        let rawCost = positionAvgCost
        guard !rawCost.isNaN, rawCost > 0 else { return rawCost }
        
        // Auto-detect currency unit if not set
        let detectedCostCurrency = costCurrency ?? autoDetectCostCurrency(for: symbol)
        
        // Convert GBX to GBP for UK stocks if needed
        if symbol.uppercased().hasSuffix(".L") && detectedCostCurrency == "GBX" {
            return rawCost / 100.0
        }
        
        return rawCost
    }
    
    /// Auto-detects the likely currency unit based on the symbol
    private func autoDetectCostCurrency(for symbol: String) -> String {
        if symbol.uppercased().hasSuffix(".L") {
            return "GBX" // UK stocks are typically quoted in pence
        }
        return "USD" // Default to USD for other stocks
    }
    
    /// Returns a user-friendly display of the cost with currency unit
    func getDisplayCost(for symbol: String) -> String {
        let detectedCurrency = costCurrency ?? autoDetectCostCurrency(for: symbol)
        return "\(positionAvgCostString) \(detectedCurrency)"
    }
}

struct TradingInfo: Codable {
    var currentPrice: Double = .nan
    var previousClose: Double?
    var lastUpdateTime: Int?
    var prevClosePrice: Double = .nan
    var currency: String?
    var regularMarketTime: Int = 0
    var exchangeTimezoneName: String = ""
    var shortName: String = ""
    
    // Pre-market and post-market data
    var preMarketPrice: Double?
    var preMarketChange: Double?
    var preMarketChangePercent: Double?
    var preMarketTime: Int?
    var postMarketPrice: Double?
    var postMarketChange: Double?
    var postMarketChangePercent: Double?
    var postMarketTime: Int?
    var marketState: String? // PRE, REGULAR, POST, CLOSED

    func getPrice() -> String {
        return formatPrice(price: currentPrice, currency: currency)
    }

    func getChange() -> String {
        let change = currentPrice - prevClosePrice
        return String(format: "%+.2f", change)
    }

    func getLongChange() -> String {
        let change = currentPrice - prevClosePrice
        return String(format: "%+.4f", change)
    }

    func getChangePct() -> String {
        let pctChange = 100 * (currentPrice - prevClosePrice) / prevClosePrice
        return String(format: "%+.4f", pctChange) + "%"
    }

    func getTimeInfo() -> String {
        // Handle case where regularMarketTime is 0 or invalid
        guard regularMarketTime > 0 else {
            return "–"
        }
        
        let date = Date(timeIntervalSince1970: TimeInterval(regularMarketTime))
        let tradeTimeZone = TimeZone(identifier: exchangeTimezoneName) ?? TimeZone.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        dateFormatter.timeZone = tradeTimeZone
        return dateFormatter.string(from: date)
    }
    
    // MARK: - Pre/Post Market Helper Functions
    
    func hasPreMarketData() -> Bool {
        return preMarketPrice != nil && !(preMarketPrice?.isNaN ?? true)
    }
    
    func hasPostMarketData() -> Bool {
        return postMarketPrice != nil && !(postMarketPrice?.isNaN ?? true)
    }
    
    func getPreMarketPrice() -> String {
        guard let price = preMarketPrice, !price.isNaN else { return "–" }
        return formatPrice(price: price, currency: currency)
    }
    
    func getPostMarketPrice() -> String {
        guard let price = postMarketPrice, !price.isNaN else { return "–" }
        return formatPrice(price: price, currency: currency)
    }
    
    func getPreMarketChange() -> String {
        guard let change = preMarketChange, !change.isNaN else { return "–" }
        return String(format: "%+.2f", change)
    }
    
    func getPostMarketChange() -> String {
        guard let change = postMarketChange, !change.isNaN else { return "–" }
        return String(format: "%+.2f", change)
    }
    
    func getPreMarketChangePercent() -> String {
        guard let percent = preMarketChangePercent, !percent.isNaN else { return "–" }
        return String(format: "%+.2f%%", percent)
    }
    
    func getPostMarketChangePercent() -> String {
        guard let percent = postMarketChangePercent, !percent.isNaN else { return "–" }
        return String(format: "%+.2f%%", percent)
    }
    
    func getMarketStateIndicator() -> String {
        switch marketState {
        case "PRE": return "PRE"
        case "POST": return "AH"
        case "CLOSED": return "CLOSED"
        default: return ""
        }
    }
    
    func getMarketStateEmoji() -> String {
        switch marketState {
        case "PRE": return "🔆"      // Bright sun for pre-market
        case "POST": return "🌙"     // Moon for after-hours
        case "CLOSED": return "🔒"   // Lock for closed
        default: return ""
        }
    }
    
    func getCurrentDisplayPrice() -> Double {
        // Return the most relevant price based on market state
        switch marketState {
        case "PRE":
            return preMarketPrice ?? currentPrice
        case "POST":
            return postMarketPrice ?? currentPrice
        default:
            return currentPrice
        }
    }
    
    func getCurrentDisplayPriceString() -> String {
        let price = getCurrentDisplayPrice()
        let indicator = getMarketStateIndicator()
        let priceStr = formatPrice(price: price, currency: currency)
        return indicator.isEmpty ? priceStr : "\(priceStr) \(indicator)"
    }
}
