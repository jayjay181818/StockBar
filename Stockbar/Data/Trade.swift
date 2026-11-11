//
//  Trade.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-01.

import Foundation

struct Trade: Codable, Equatable {
    var name: String
    var position: Position
    var isWatchlistOnly: Bool = false  // If true, this is a watch-only stock (no position calculations)
    var showInMenuBar: Bool = true     // If false, hide from menu bar but keep in portfolio

    init(
        name: String,
        position: Position,
        isWatchlistOnly: Bool = false,
        showInMenuBar: Bool = true
    ) {
        self.name = name
        self.position = position
        self.isWatchlistOnly = isWatchlistOnly
        self.showInMenuBar = showInMenuBar
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case position
        case isWatchlistOnly
        case showInMenuBar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        position = try container.decode(Position.self, forKey: .position)
        isWatchlistOnly = try container.decodeIfPresent(Bool.self, forKey: .isWatchlistOnly) ?? false
        showInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
    }
}

struct Position: Codable, Equatable {
    var unitSizeString: String {
        get {
            return self._unitSize
        }
        set(newUnitSize) {
            _unitSize = newUnitSize
        }
    }
    var unitSize: Double {
        get {
            return Self.parseAmount(unitSizeString) ?? 0
        }
    }
    var positionAvgCostString: String
    var positionAvgCost: Double {
        get {
            return Self.parseAmount(positionAvgCostString) ?? .nan
        }
    }

    /// Parses a typed units or cost value. A plain "1234.5" works in any locale;
    /// otherwise the user's locale applies, so "1,000" (grouping) and "12,50"
    /// (decimal comma) are read as entered instead of becoming 0 or NaN.
    /// Returns nil for empty, non-numeric, non-finite or negative input.
    /// Blank is fine (watchlist rows); anything else must parse.
    static func isReadableAmount(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parseAmount(text) != nil
    }

    static func parseAmount(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let plain = Double(trimmed) {
            return plain.isFinite && plain >= 0 ? plain : nil
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        guard let value = formatter.number(from: trimmed)?.doubleValue, value.isFinite, value >= 0 else {
            return nil
        }
        return value
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
        if SymbolMetadata.isUKSymbol(symbol) && Self.isPence(detectedCostCurrency) {
            return rawCost / 100.0
        }
        
        return rawCost
    }

    /// "GBX" in any case, or "GBp" exactly; "gbp" is taken to mean pounds.
    static func isPence(_ currency: String) -> Bool {
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "GBp" || trimmed.uppercased() == "GBX"
    }

    /// The average cost per unit in the currency the holding is quoted in.
    /// A cost entered in another currency (a US share costed in pounds) is
    /// converted at the current rate, so gains do not subtract pounds from
    /// dollars. With no stated cost currency, or no rate, the cost is used as
    /// entered, as before.
    func averageCost(
        for symbol: String,
        inQuoteCurrency quoteCurrency: String?,
        converter: CurrencyConverter = .shared
    ) -> Double {
        let normalized = getNormalizedAvgCost(for: symbol)
        guard normalized.isFinite, normalized > 0,
              let quote = quoteCurrency?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty,
              let stated = costCurrency?.trimmingCharacters(in: .whitespacesAndNewlines), !stated.isEmpty else {
            return normalized
        }
        // `normalized` is already in pounds for a UK symbol costed in pence.
        let pence = Self.isPence(stated)
        let costMajor = pence ? "GBP" : stated.uppercased()
        let costInMajor = pence && !SymbolMetadata.isUKSymbol(symbol) ? normalized / 100.0 : normalized
        let quoteMajor = Self.isPence(quote) ? "GBP" : quote.uppercased()
        guard costMajor != quoteMajor else { return normalized }
        let converted = converter.convert(amount: costInMajor, from: costMajor, to: quote)
        return converted.isFinite && converted > 0 ? converted : normalized
    }
    
    /// Auto-detects the likely currency unit based on the symbol
    private func autoDetectCostCurrency(for symbol: String) -> String {
        if SymbolMetadata.isUKSymbol(symbol) {
            return "GBX" // UK stocks are typically quoted in pence
        }
        return "USD" // Default to USD for other stocks
    }
    
    /// The currency the average cost is entered in.
    func displayCostCurrency(for symbol: String) -> String {
        costCurrency ?? autoDetectCostCurrency(for: symbol)
    }

    /// Returns a user-friendly display of the cost with currency unit
    func getDisplayCost(for symbol: String) -> String {
        let detectedCurrency = displayCostCurrency(for: symbol)
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

    // Error information
    var errorMessage: String?

    func getTimeInfo() -> String {
        // During pre/post market hours, use those specific timestamps
        // During regular hours, use regularMarketTime

        // Determine which timestamp to use based on market state
        var displayTimestamp: Int = regularMarketTime

        // Use pre/post market times when in those states and available
        if let state = marketState {
            switch state {
            case "PRE":
                if let preTime = preMarketTime, preTime > 0 {
                    displayTimestamp = preTime
                }
            case "POST":
                if let postTime = postMarketTime, postTime > 0 {
                    displayTimestamp = postTime
                }
            default:
                // Use regularMarketTime for REGULAR and CLOSED states
                break
            }
        }

        guard displayTimestamp > 0 else { return "–" }

        // UI timestamp: exchange-reported time for the current quote (pre/post/regular)
        let exchangeDate = Date(timeIntervalSince1970: TimeInterval(displayTimestamp))

        // Time-ago: when we actually refreshed locally
        let refreshDate: Date
        if let lastUpdateTime, lastUpdateTime > 0 {
            refreshDate = Date(timeIntervalSince1970: TimeInterval(lastUpdateTime))
        } else {
            refreshDate = exchangeDate
        }

        // Format in user's local timezone
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        dateFormatter.timeZone = TimeZone.current

        let timeAgo = formatTimeAgo(from: refreshDate)
        return "\(dateFormatter.string(from: exchangeDate)) (\(timeAgo))"
    }
    
    private func formatTimeAgo(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
    
    // MARK: - Pre/Post Market Helper Functions
    
    
    
    
    
    
    
    
    
    
    
    func getCurrentDisplayPrice() -> Double {
        // Return the most relevant price based on market state
        switch marketState {
        case "PRE":
            return validExtendedSessionPrice(preMarketPrice) ?? currentPrice
        case "POST":
            return validExtendedSessionPrice(postMarketPrice) ?? currentPrice
        default:
            return currentPrice
        }
    }

    private func validExtendedSessionPrice(_ price: Double?) -> Double? {
        guard let price, price.isFinite, price > 0 else { return nil }
        return price
    }
    
}
