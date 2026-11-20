import Foundation

// Models, queries and results for Folync's three ledger routes (dividends,
// trade analysis, transactions). The coordinator routes are in
// `FolyncSupplementalData.swift`; the fetch policy in
// `FolyncLedgerFetchPolicy.swift`.
//
// Decoding is lenient: unknown keys are ignored, every field Folync may leave
// out or send as null is optional, and an enum value this build does not know
// is kept as `.unknown(raw)` instead of failing the decode. A null figure stays
// nil and is never read as zero. Stockbar shows these figures as given.

/// A string enum that keeps a value this build does not know.
enum FolyncOpenEnum<Known>: Codable, Equatable, Hashable, Sendable
where Known: RawRepresentable & Hashable & Sendable, Known.RawValue == String {
    case known(Known)
    case unknown(String)

    init(_ known: Known) {
        self = .known(known)
    }

    init(rawValue: String) {
        self = Known(rawValue: rawValue).map(Self.known) ?? .unknown(rawValue)
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .known(let value): value.rawValue
        case .unknown(let raw): raw
        }
    }

    var knownValue: Known? {
        if case .known(let value) = self { return value }
        return nil
    }
}

/// A page of a ledger collection. `collectionRevision` changes when the
/// collection does; the ETag changes far more often and is not that signal.
struct FolyncReadPage: Codable, Equatable, Sendable {
    let limit: Int
    let hasMore: Bool
    let nextCursor: String?
    let collectionRevision: String

    /// Where the next page starts, or nil when this is the last page.
    var continuation: FolyncLedgerContinuation? {
        guard hasMore, let nextCursor, !nextCursor.isEmpty else { return nil }
        return FolyncLedgerContinuation(cursor: nextCursor, collectionRevision: collectionRevision)
    }
}

/// What "load more" needs: the cursor from the last page and the collection
/// revision of the pages gathered so far.
struct FolyncLedgerContinuation: Equatable, Hashable, Sendable {
    let cursor: String
    let collectionRevision: String
}

/// The parts every ledger response shares.
protocol FolyncLedgerResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int { get }
    var scope: FolyncPortfolio { get }
    var quality: FolyncFinancialQuality { get }
    var page: FolyncReadPage { get }
}

// MARK: - Dividends

enum FolyncDividendStatus: String, Hashable, Sendable {
    case received
    case upcoming
}

enum FolyncDividendCertainty: String, Hashable, Sendable {
    case published
    case estimated
    case unknown
}

enum FolyncDividendEntitlementBasis: String, Hashable, Sendable {
    case currentHoldings = "current_holdings"
    case exDividendHoldings = "ex_dividend_holdings"
    case unknown
}

enum FolyncDividendReceiptStatus: String, Hashable, Sendable {
    case upcoming
    case awaitingReceipt = "awaiting_receipt"
    case received
}

enum FolyncWithholdingProvenance: String, Hashable, Sendable {
    case actual
    case configured
    case mixed
    case none
}

/// How Folync found and dated an event. Present only where Folync includes it.
struct FolyncDividendEventDiscovery: Codable, Equatable, Sendable {
    let eventId: String
    let exDate: String?
    let declarationDate: String?
    let recordDate: String?
    let amountCertainty: FolyncOpenEnum<FolyncDividendCertainty>
    let dateCertainty: FolyncOpenEnum<FolyncDividendCertainty>
    let source: String?
    let lastCheckedAt: String?
    let entitlementBasis: FolyncOpenEnum<FolyncDividendEntitlementBasis>?
    let quantity: Double?
    let originalCurrency: String?
    let perShare: Double?
    let fxAsOfDate: String?
    let fxEstimated: Bool?
    let receiptStatus: FolyncOpenEnum<FolyncDividendReceiptStatus>?
    let issues: [String]?
}

struct FolyncDividendEvent: Codable, Equatable, Sendable {
    let eventId: String
    let portfolioId: String
    let portfolioName: String
    let assetId: String
    let identity: FolyncInstrumentIdentity
    let transactionId: String?
    let exDate: String?
    let payDate: String
    let status: FolyncOpenEnum<FolyncDividendStatus>
    /// In `currency`; nil when Folync does not know it.
    let amount: Double?
    let currency: String
    let portfolioAmount: FolyncFinancialMetric
    let discovery: FolyncDividendEventDiscovery?
}

struct FolyncDividendSummary: Codable, Equatable, Sendable {
    /// Net income received over the last twelve months.
    let receivedIncome: Double?
    let grossIncome: Double?
    let withholdingTax: Double?
    let fees: Double?
    let netIncome: Double?
    let withholdingProvenance: FolyncOpenEnum<FolyncWithholdingProvenance>?
    let declaredIncome: Double?
    let estimatedIncome: Double?
    let knownProjectedIncome: Double?
    let incomplete: Bool
    /// Projected income over the next twelve months.
    let projectedAnnualIncome: Double?
    let yoyChangePct: Double?
    let portfolioYieldTTMPct: Double?
    let yieldOnCostTTMPct: Double?
    let avgMonthlyIncome: Double?
    let avgDailyIncome: Double?
    let dividendPayingAssets: Int
}

struct FolyncDividendHoldingCoverage: Codable, Equatable, Sendable {
    let totalHoldings: Int
    let valuedHoldings: Int
    let missingHoldings: Int
    let marketValue: FolyncFinancialMetric
}

/// Whole-scope discovery totals, independent of paging and date filters.
/// The undated announcements and per-source coverage are not decoded.
struct FolyncDividendDiscoverySummary: Codable, Equatable, Sendable {
    let knownDeclaredIncome: Double?
    let knownEstimatedIncome: Double?
    let incomplete: Bool
    let issues: [String]?
}

/// `GET v2/scopes/{scope}/dividends`. The liability coverage and corporate
/// cash-flow outlook are not decoded: no planned screen uses them.
struct FolyncDividendsResponse: FolyncLedgerResponse {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let scope: FolyncPortfolio
    let currency: String?
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let freshness: FolyncFreshness
    let valuation: FolyncFinancialMetric
    let holdingCoverage: FolyncDividendHoldingCoverage
    let summary: FolyncDividendSummary
    let discovery: FolyncDividendDiscoverySummary?
    let events: [FolyncDividendEvent]
    let page: FolyncReadPage
}

// MARK: - Trade analysis

enum FolyncTradeLotStatus: String, Hashable, Sendable {
    case open = "Open"
    case partial = "Partial"
    case closed = "Closed"
}

enum FolyncTradeSide: String, Hashable, Sendable {
    case long = "Long"
    case short = "Short"
}

enum FolyncCostBasisMethod: String, Hashable, Sendable {
    case fifo
    case lifo
    case average
}

struct FolyncTradeBenchmarkBreakdown: Codable, Equatable, Sendable {
    let benchmarkId: String
    let benchmarkName: String
    let wins: Int
    let losses: Int
    let unavailable: Int
    let winRatePct: Double?
}

struct FolyncTradeStats: Codable, Equatable, Sendable {
    let attributionLots: Int
    let closedAttributionLots: Int
    let winRatePct: Double?
    let wins: Int
    let losses: Int
    let winRateVsSp500Pct: Double?
    let winsVsSp500: Int
    let lossesVsSp500: Int
    let comparisonScope: String?
    let benchmarkWinRatePct: Double?
    let benchmarkWins: Int
    let benchmarkLosses: Int
    let unavailableBenchmarkComparisons: Int
    let openLotComparisonDate: String?
    let benchmarkBreakdown: [FolyncTradeBenchmarkBreakdown]
    /// Over all lots, open and closed.
    let totalTradeGain: Double?
    let unavailableAttributionLots: Int
}

/// Trading activity for one period (a calendar year).
struct FolyncActivityPeriod: Codable, Equatable, Sendable {
    let period: String
    let fees: Double?
    let feesPctOfAvgValue: Double?
    let buyCount: Int
    let sellCount: Int
    let tradeCount: Int
    let buyValue: Double?
    let sellValue: Double?
    let tradeValue: Double?
    let turnoverPct: Double?
}

struct FolyncTradeBenchmarkComparison: Codable, Equatable, Sendable {
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let requestedStartDate: String
    let requestedEndDate: String?
    let startPriceDate: String?
    let endPriceDate: String?
    let holdingPriceDate: String?
    let awaitingHoldingClose: Bool
    let awaitedHoldingCloseDate: String?
    let holdingPriceFinal: Bool
}

struct FolyncTradeLot: Codable, Equatable, Sendable {
    let id: String
    let ticker: String
    let side: FolyncOpenEnum<FolyncTradeSide>
    let openDate: String
    /// Per share, in the portfolio currency (`currency`), charges included.
    let price: Double
    let currency: String
    let shares: Double
    let openedShares: Double
    let costBasis: Double
    let totalGain: Double?
    let totalReturnPct: Double?
    let comparisonReturnPct: Double?
    let alphaPct: Double?
    let benchmarkId: String
    let benchmarkName: String
    let benchmarkReturnPct: Double?
    let benchmarkComparison: FolyncTradeBenchmarkComparison?
    let holdingDays: Int
    let status: FolyncOpenEnum<FolyncTradeLotStatus>
    let valuation: FolyncFinancialMetric
    let portfolioId: String
    let assetId: String
    let identity: FolyncInstrumentIdentity
}

/// `GET v2/scopes/{scope}/trade-analysis`. `stats` and `activity` cover the
/// whole scope; `lots` is paged.
struct FolyncTradeAnalysisResponse: FolyncLedgerResponse {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let scope: FolyncPortfolio
    let currency: String?
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let freshness: FolyncFreshness
    let costBasisMethod: FolyncOpenEnum<FolyncCostBasisMethod>?
    let stats: FolyncTradeStats
    let activity: [FolyncActivityPeriod]
    let lots: [FolyncTradeLot]
    let page: FolyncReadPage
}

// MARK: - Transactions

enum FolyncTransactionAction: String, CaseIterable, Hashable, Sendable {
    case buy
    case sell
    case deposit
    case withdraw
    case fee
    case dividend
    case stockDividend = "stock_dividend"
    case tax
    case interest
    case split
    case transfer
    case corporateAction = "corporate_action"
    case note
}

enum FolyncTransactionsMode: String, Hashable, Sendable {
    case input
    case adjusted
}

enum FolyncFXRateSource: String, Hashable, Sendable {
    case sameCurrency = "same_currency"
    case provider
    case manual
    case historical
    case unresolved
}

struct FolyncTransaction: Codable, Equatable, Sendable {
    let id: String
    let portfolioId: String
    let portfolioName: String
    let assetId: String?
    let identity: FolyncInstrumentIdentity?
    let date: String
    let action: FolyncOpenEnum<FolyncTransactionAction>
    let quantity: Double
    let price: Double
    let priceCurrency: String?
    let grossAmount: Double
    let commission: Double
    let tax: Double
    /// Settlement currency of `grossAmount`, `commission` and `tax`.
    let currency: String
    let portfolioCurrency: String
    let fxRateToPortfolioCurrency: Double?
    let fxRateSource: FolyncOpenEnum<FolyncFXRateSource>?
    /// The gross amount in the portfolio currency; commission and tax are not deducted.
    let portfolioAmount: FolyncFinancialMetric
    let source: String
    let importOwned: Bool
    let adjusted: Bool?
    let adjustedReason: String?
}

/// `GET v2/scopes/{scope}/transactions`. Provider provenance is not decoded.
struct FolyncTransactionsResponse: FolyncLedgerResponse {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let scope: FolyncPortfolio
    let currency: String?
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let freshness: FolyncFreshness
    let mode: FolyncOpenEnum<FolyncTransactionsMode>
    let transactions: [FolyncTransaction]
    let page: FolyncReadPage
}

// MARK: - Queries

/// Query parameters for one ledger route, without the cursor. Two queries that
/// are equal ask for the same rows; `cacheKey` is their canonical form, used
/// to keep saved copies and reused answers apart.
protocol FolyncLedgerQuery: Hashable, Sendable {
    static var route: FolyncLedgerRoute { get }
    var queryItems: [URLQueryItem] { get }
}

extension FolyncLedgerQuery {
    var cacheKey: String {
        queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    func queryItems(cursor: String?) -> [URLQueryItem] {
        queryItems + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    static func clamped(_ limit: Int?, maximum: Int) -> URLQueryItem? {
        limit.map { URLQueryItem(name: "limit", value: String(min(max($0, 1), maximum))) }
    }

    static func day(_ name: String, _ date: Date?) -> URLQueryItem? {
        date.map { URLQueryItem(name: name, value: FolyncLedgerDay.string(from: $0)) }
    }
}

enum FolyncLedgerDay {
    /// `yyyy-MM-dd` in UTC, as Folync's date parameters expect.
    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct FolyncDividendsQuery: FolyncLedgerQuery {
    enum Status: String, Hashable, Sendable {
        case all
        case received
        case upcoming
    }

    static let route = FolyncLedgerRoute.dividends
    static let maximumLimit = 200

    var status: Status?
    /// On the pay date.
    var from: Date?
    var to: Date?
    /// Clamped to 1...200.
    var limit: Int?

    init(status: Status? = nil, from: Date? = nil, to: Date? = nil, limit: Int? = nil) {
        self.status = status
        self.from = from
        self.to = to
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        [
            status.map { URLQueryItem(name: "status", value: $0.rawValue) },
            Self.day("from", from),
            Self.day("to", to),
            Self.clamped(limit, maximum: Self.maximumLimit)
        ].compactMap { $0 }
    }
}

struct FolyncTradeAnalysisQuery: FolyncLedgerQuery {
    enum Status: String, Hashable, Sendable {
        case all
        case open
        case partial
        case closed
    }

    static let route = FolyncLedgerRoute.tradeAnalysis
    static let maximumLimit = 200

    var status: Status?
    var assetId: String?
    /// Clamped to 1...200.
    var limit: Int?

    init(status: Status? = nil, assetId: String? = nil, limit: Int? = nil) {
        self.status = status
        self.assetId = assetId
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        [
            status.map { URLQueryItem(name: "status", value: $0.rawValue) },
            assetId.map { URLQueryItem(name: "assetId", value: $0) },
            Self.clamped(limit, maximum: Self.maximumLimit)
        ].compactMap { $0 }
    }
}

struct FolyncTransactionsQuery: FolyncLedgerQuery {
    /// Folync takes an asset ID or a ticker, never both.
    enum Instrument: Hashable, Sendable {
        case assetId(String)
        case ticker(String)
    }

    static let route = FolyncLedgerRoute.transactions
    static let maximumLimit = 500

    var mode: FolyncTransactionsMode?
    var from: Date?
    var to: Date?
    var instrument: Instrument?
    /// Sent once each, in declaration order, so the same set is always the same query.
    var actions: Set<FolyncTransactionAction>
    /// Clamped to 1...500.
    var limit: Int?

    init(
        mode: FolyncTransactionsMode? = nil,
        from: Date? = nil,
        to: Date? = nil,
        instrument: Instrument? = nil,
        actions: Set<FolyncTransactionAction> = [],
        limit: Int? = nil
    ) {
        self.mode = mode
        self.from = from
        self.to = to
        self.instrument = instrument
        self.actions = actions
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        let instrumentItem: URLQueryItem? = switch instrument {
        case .assetId(let id): URLQueryItem(name: "assetId", value: id)
        case .ticker(let ticker): URLQueryItem(name: "ticker", value: ticker)
        case nil: nil
        }
        let actionList = FolyncTransactionAction.allCases.filter(actions.contains).map(\.rawValue)
        return [
            mode.map { URLQueryItem(name: "mode", value: $0.rawValue) },
            Self.day("from", from),
            Self.day("to", to),
            instrumentItem,
            actionList.isEmpty ? nil : URLQueryItem(name: "actions", value: actionList.joined(separator: ",")),
            Self.clamped(limit, maximum: Self.maximumLimit)
        ].compactMap { $0 }
    }
}

// MARK: - Routes

extension FolyncLedgerRoute {
    /// The last path component after `api/client/v2/scopes/{scope}`.
    var pathComponent: String {
        switch self {
        case .dividends: "dividends"
        case .tradeAnalysis: "trade-analysis"
        case .transactions: "transactions"
        }
    }

    /// The resource name of its saved first pages in `FolyncSupplementalCache`.
    var cacheResource: String {
        "ledger-\(pathComponent)"
    }
}

/// The parts of Folync's error body that paging needs.
struct FolyncClientAPIErrorBody: Decodable, Sendable {
    struct Details: Decodable, Sendable {
        let code: String?
        let fieldErrors: [String: [String]]?
    }

    let data: Details?

    /// A 400 that refuses the cursor: code `invalid_cursor`, or a field error
    /// on `cursor`.
    static func refusesCursor(_ body: Data) -> Bool {
        guard let details = (try? JSONDecoder().decode(Self.self, from: body))?.data else { return false }
        return details.code == "invalid_cursor" || details.fieldErrors?["cursor"] != nil
    }
}

// MARK: - Results

/// Which page a ledger result is.
enum FolyncLedgerPaging: Equatable, Sendable {
    /// Page one.
    case firstPage
    /// The page after the continuation passed to "load more"; append its rows.
    case nextPage
    /// Paging had to start again (the collection changed, or Folync refused
    /// the cursor). This is page one: drop the rows gathered so far.
    case restarted
}

enum FolyncRoutedLedgerResult<Response: FolyncLedgerResponse>: Sendable {
    case folync(Response, status: FolyncSupplementalSourceStatus, paging: FolyncLedgerPaging)
    /// Folync is not connected, or this route is switched off in Settings.
    case disabled
    /// Folync answered but cannot provide this: the route or scope is missing,
    /// the capability is absent, unsupported or not ready, or the answer could
    /// not be used. Nothing usable is saved.
    case unavailable
    /// Folync did not answer (no HTTP response, or a 502/503/504) and nothing
    /// usable is saved.
    case unreachable
}

typealias FolyncRoutedDividendsResult = FolyncRoutedLedgerResult<FolyncDividendsResponse>
typealias FolyncRoutedTradeAnalysisResult = FolyncRoutedLedgerResult<FolyncTradeAnalysisResponse>
typealias FolyncRoutedTransactionsResult = FolyncRoutedLedgerResult<FolyncTransactionsResponse>
