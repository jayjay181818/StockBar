import Foundation

/// Struct to represent the fetched stock data in a common format
struct StockFetchResult: Sendable {
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

    /// Why this quote has no usable price. Nil for a successful quote.
    var failure: QuoteFailure?

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

/// The cause the quote script reported for one symbol.
enum QuoteFailure: String, Sendable {
    case rateLimited = "RATE_LIMIT"
    case timedOut = "TIMEOUT"
    case network = "NETWORK_ERROR"
    case noData = "NO_DATA"

    /// Anything the script did not classify is a symbol with no data.
    init(errorCode: String?) {
        self = errorCode.flatMap(QuoteFailure.init(rawValue:)) ?? .noData
    }

    /// True when the provider or connection failed, which says nothing about the symbol.
    var isProviderWide: Bool { self != .noData }
}

extension QuoteFailure {
    /// A few words for the user.
    var userDescription: String {
        switch self {
        case .rateLimited: "the provider is limiting requests"
        case .timedOut: "the provider did not answer in time"
        case .network: "the provider could not be reached"
        case .noData: "the provider returned no price"
        }
    }
}

/// What happened the last time Stockbar asked the provider for quotes.
///
/// A failed refresh keeps the old prices and their "updated" times, so without
/// this the only sign of trouble is prices quietly ageing.
struct QuoteRefreshStatus: Equatable, Sendable {
    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    private(set) var attemptedCount = 0
    private(set) var failedCount = 0
    private(set) var failure: QuoteFailure?
    /// Set when quotes cannot be fetched at all until the user fixes something.
    private(set) var setupProblem: String?

    /// True when the last pass asked for quotes and got none.
    var lastAttemptFailed: Bool { attemptedCount > 0 && failedCount >= attemptedCount }

    mutating func record(attempted: Int, failures: [QuoteFailure], at time: Date) {
        guard attempted > 0 else { return }
        setupProblem = nil
        lastAttempt = time
        attemptedCount = attempted
        failedCount = min(failures.count, attempted)
        // The commonest cause speaks for the pass; provider-wide causes win ties.
        let counts = Dictionary(grouping: failures, by: { $0 }).mapValues(\.count)
        failure = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : !lhs.key.isProviderWide && rhs.key.isProviderWide
        }?.key
        if failedCount < attempted { lastSuccess = time }
    }

    /// Returns true the first time the problem is seen, so it is logged once
    /// rather than on every refresh.
    mutating func recordSetupProblem(_ problem: String, attempted: Int, at time: Date) -> Bool {
        let isNew = setupProblem != problem
        lastAttempt = time
        attemptedCount = attempted
        failedCount = attempted
        failure = nil
        setupProblem = problem
        return isNew
    }

    /// Nil when the last pass got every quote it asked for.
    var problemSummary: String? {
        if let setupProblem { return setupProblem }
        guard failedCount > 0 else { return nil }
        let reason = failure?.userDescription ?? "no prices came back"
        if lastAttemptFailed { return "Last refresh failed: \(reason)" }
        return "\(failedCount) of \(attemptedCount) not refreshed: \(reason)"
    }
}

enum MarketState: String, CaseIterable, Sendable {
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
