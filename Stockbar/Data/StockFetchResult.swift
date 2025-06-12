import Foundation

/// Struct to represent the fetched stock data in a common format
struct StockFetchResult {
    let currency: String?
    let symbol: String
    let shortName: String?
    let regularMarketTime: Int?
    let exchangeTimezoneName: String?
    let regularMarketPrice: Double
    let regularMarketPreviousClose: Double
    let displayPrice: Double  // Current display price (includes pre/post market adjustments)
    
    // Pre-market and post-market data
    let preMarketPrice: Double?
    let preMarketChange: Double?
    let preMarketChangePercent: Double?
    let preMarketTime: Int?
    let postMarketPrice: Double?
    let postMarketChange: Double?
    let postMarketChangePercent: Double?
    let postMarketTime: Int?
    
    // Market state indicator
    let marketState: MarketState?
    
    init(currency: String?, symbol: String, shortName: String?, regularMarketTime: Int?, exchangeTimezoneName: String?, regularMarketPrice: Double, regularMarketPreviousClose: Double, displayPrice: Double, preMarketPrice: Double? = nil, preMarketChange: Double? = nil, preMarketChangePercent: Double? = nil, preMarketTime: Int? = nil, postMarketPrice: Double? = nil, postMarketChange: Double? = nil, postMarketChangePercent: Double? = nil, postMarketTime: Int? = nil, marketState: MarketState? = nil) {
        self.currency = currency
        self.symbol = symbol
        self.shortName = shortName
        self.regularMarketTime = regularMarketTime
        self.exchangeTimezoneName = exchangeTimezoneName
        self.regularMarketPrice = regularMarketPrice
        self.regularMarketPreviousClose = regularMarketPreviousClose
        self.displayPrice = displayPrice
        self.preMarketPrice = preMarketPrice
        self.preMarketChange = preMarketChange
        self.preMarketChangePercent = preMarketChangePercent
        self.preMarketTime = preMarketTime
        self.postMarketPrice = postMarketPrice
        self.postMarketChange = postMarketChange
        self.postMarketChangePercent = postMarketChangePercent
        self.postMarketTime = postMarketTime
        self.marketState = marketState
    }
}

enum MarketState: String, CaseIterable {
    case preMarket = "PRE"
    case regular = "REGULAR"
    case postMarket = "POST"
    case closed = "CLOSED"
    
    var displayName: String {
        switch self {
        case .preMarket: return "Pre-Market"
        case .regular: return "Regular Hours"
        case .postMarket: return "After Hours"
        case .closed: return "Market Closed"
        }
    }
    
    var indicator: String {
        switch self {
        case .preMarket: return "PRE"
        case .regular: return ""
        case .postMarket: return "AH"
        case .closed: return "CLOSED"
        }
    }
}