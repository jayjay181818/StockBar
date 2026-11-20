import CryptoKit
import Foundation

enum FolyncSupplementalRoute: String, CaseIterable, Codable, Hashable, Sendable {
    case historicalLineCharts
    case candlestickCharts
    case benchmarkMarketData
    case exchangeRates
}

/// Folync's ledger routes. Kept apart from `FolyncSupplementalRoute`, which
/// the Settings screen and the acceptance preflight iterate: these have no
/// legacy fallback, are fetched only when their page opens, and go through
/// `FolyncLedgerFetchPolicy`.
enum FolyncLedgerRoute: String, CaseIterable, Codable, Hashable, Sendable {
    case dividends
    case tradeAnalysis
    case transactions
}

struct FolyncSupplementalSettings: Codable, Equatable, Sendable {
    var historicalLineCharts: Bool
    var candlestickCharts: Bool
    var benchmarkMarketData: Bool
    var exchangeRates: Bool
    var allowLegacyFallback: Bool
    /// The ledger routes (`FolyncLedgerRoute`). They are fetched only when
    /// their page is opened, so they default to on: settings stored before
    /// they existed decode with them on, and an existing connection does not
    /// have to switch on each new page by hand.
    var dividends: Bool = true
    var tradeAnalysis: Bool = true
    var transactions: Bool = true

    static let disabled = FolyncSupplementalSettings(
        historicalLineCharts: false,
        candlestickCharts: false,
        benchmarkMarketData: false,
        exchangeRates: false,
        allowLegacyFallback: false,
        dividends: false,
        tradeAnalysis: false,
        transactions: false
    )

    static func newConnectionDefaults(capabilities: FolyncCapabilities?) -> FolyncSupplementalSettings {
        guard let capabilities else { return .disabled }
        return FolyncSupplementalSettings(
            historicalLineCharts: capabilities.resources.lineHistory.isUsable,
            candlestickCharts: capabilities.resources.candlesticks.isUsable,
            benchmarkMarketData: capabilities.resources.benchmarks.isUsable,
            exchangeRates: capabilities.resources.exchangeRates.isUsable,
            allowLegacyFallback: false,
            dividends: capabilities.resources.dividends?.isUsable ?? false,
            tradeAnalysis: capabilities.resources.tradeAnalysis?.isUsable ?? false,
            transactions: capabilities.resources.transactions?.isUsable ?? false
        )
    }

    func isEnabled(_ route: FolyncSupplementalRoute) -> Bool {
        switch route {
        case .historicalLineCharts: historicalLineCharts
        case .candlestickCharts: candlestickCharts
        case .benchmarkMarketData: benchmarkMarketData
        case .exchangeRates: exchangeRates
        }
    }

    func isEnabled(_ route: FolyncLedgerRoute) -> Bool {
        switch route {
        case .dividends: dividends
        case .tradeAnalysis: tradeAnalysis
        case .transactions: transactions
        }
    }
}

extension FolyncSupplementalSettings {
    private enum CodingKeys: String, CodingKey {
        case historicalLineCharts, candlestickCharts, benchmarkMarketData, exchangeRates, allowLegacyFallback
        case dividends, tradeAnalysis, transactions
    }

    /// Every field is optional in stored data, so settings saved by a build
    /// with fewer fields still decode. With the synthesized decoder a missing
    /// field failed the whole stored configuration, and Folync fell back to
    /// `.disabled`. A missing chart or fallback field is off; a missing ledger
    /// field is on (see `dividends`). In an extension so the memberwise
    /// initializer stays.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            historicalLineCharts: try container.decodeIfPresent(Bool.self, forKey: .historicalLineCharts) ?? false,
            candlestickCharts: try container.decodeIfPresent(Bool.self, forKey: .candlestickCharts) ?? false,
            benchmarkMarketData: try container.decodeIfPresent(Bool.self, forKey: .benchmarkMarketData) ?? false,
            exchangeRates: try container.decodeIfPresent(Bool.self, forKey: .exchangeRates) ?? false,
            allowLegacyFallback: try container.decodeIfPresent(Bool.self, forKey: .allowLegacyFallback) ?? false,
            dividends: try container.decodeIfPresent(Bool.self, forKey: .dividends) ?? true,
            tradeAnalysis: try container.decodeIfPresent(Bool.self, forKey: .tradeAnalysis) ?? true,
            transactions: try container.decodeIfPresent(Bool.self, forKey: .transactions) ?? true
        )
    }
}

struct FolyncCapability: Codable, Equatable, Sendable {
    let supported: Bool
    let ready: Bool
    let reasonCodes: [String]

    var isUsable: Bool { supported && ready }
}

struct FolyncInstrumentIdentity: Codable, Equatable, Sendable {
    let assetId: String?
    let canonicalTicker: String
    let displayTicker: String
    let quoteSymbol: String
    let aliases: [String]
    let isin: String?

    var normalizedAliases: Set<String> {
        Set((aliases + [canonicalTicker, displayTicker, quoteSymbol]).map(Self.normalize))
    }

    func matches(_ symbol: String) -> Bool {
        normalizedAliases.contains(Self.normalize(symbol))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

struct FolyncBenchmarkDefinition: Codable, Equatable, Sendable {
    let id: String
    let symbol: String
    let name: String
    let currency: String
    let provider: String
}

struct FolyncCapabilities: Codable, Equatable, Sendable {
    struct Resources: Codable, Equatable, Sendable {
        let lineHistory: FolyncCapability
        let candlesticks: FolyncCapability
        let benchmarks: FolyncCapability
        let exchangeRates: FolyncCapability
        /// The ledger resources. Optional: older servers, and capabilities
        /// documents saved by older builds, do not have them.
        let transactions: FolyncCapability?
        let dividends: FolyncCapability?
        let tradeAnalysis: FolyncCapability?

        init(
            lineHistory: FolyncCapability,
            candlesticks: FolyncCapability,
            benchmarks: FolyncCapability,
            exchangeRates: FolyncCapability,
            transactions: FolyncCapability? = nil,
            dividends: FolyncCapability? = nil,
            tradeAnalysis: FolyncCapability? = nil
        ) {
            self.lineHistory = lineHistory
            self.candlesticks = candlesticks
            self.benchmarks = benchmarks
            self.exchangeRates = exchangeRates
            self.transactions = transactions
            self.dividends = dividends
            self.tradeAnalysis = tradeAnalysis
        }

        /// Nil when the server does not list the resource.
        func capability(for route: FolyncLedgerRoute) -> FolyncCapability? {
            switch route {
            case .dividends: dividends
            case .tradeAnalysis: tradeAnalysis
            case .transactions: transactions
            }
        }
    }

    struct FX: Codable, Equatable, Sendable {
        let base: String
        let quotes: [String]
    }

    struct MarketIdentityCapability: Codable, Equatable, Sendable {
        struct Resources: Codable, Equatable, Sendable {
            let lineHistory: FolyncCapability
            let candlesticks: FolyncCapability
        }

        struct IntervalCoverage: Codable, Equatable, Sendable {
            let availableFrom: String?
            let availableTo: String?
            let pointCount: Int
        }

        let identity: FolyncInstrumentIdentity
        let resources: Resources
        let intervals: [String: IntervalCoverage]
    }

    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let resources: Resources
    let ranges: [String]
    let intervals: [String]
    let retentionDays: [String: Int]
    let benchmarks: [FolyncBenchmarkDefinition]
    let fx: FX
    let trackedAssets: [FolyncInstrumentIdentity]
    let trackedSymbols: [String]
    let marketIdentities: [MarketIdentityCapability]?

    func identity(for symbol: String) -> FolyncInstrumentIdentity? {
        trackedAssets.first { $0.matches(symbol) }
    }

    func isTrackedOrAllowlisted(_ symbol: String) -> Bool {
        if identity(for: symbol) != nil { return true }
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trackedSymbols.contains { $0.uppercased() == normalized }
            || benchmarks.contains { $0.symbol.uppercased() == normalized }
    }

    static func fixture(
        lineHistory: Bool,
        candlesticks: Bool,
        benchmarks: Bool,
        exchangeRates: Bool
    ) -> FolyncCapabilities {
        func capability(_ ready: Bool) -> FolyncCapability {
            FolyncCapability(supported: true, ready: ready, reasonCodes: ready ? [] : ["not_ready"])
        }
        return FolyncCapabilities(
            schemaVersion: 2,
            sourceRevision: "fixture",
            generatedAt: "2026-07-13T00:00:00.000Z",
            resources: Resources(
                lineHistory: capability(lineHistory),
                candlesticks: capability(candlesticks),
                benchmarks: capability(benchmarks),
                exchangeRates: capability(exchangeRates)
            ),
            ranges: ["1d", "1w", "1m", "3m", "6m", "1y", "all", "custom"],
            intervals: ["5m", "15m", "1h", "1d"],
            retentionDays: ["5m": 7, "15m": 31, "1h": 365, "1d": 3653],
            benchmarks: [],
            fx: FX(base: "USD", quotes: ["GBP", "EUR", "JPY", "CAD", "AUD"]),
            trackedAssets: [],
            trackedSymbols: [],
            marketIdentities: []
        )
    }
}

struct FolyncMarketBar: Codable, Equatable, Sendable {
    let timestamp: String
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double
    let volume: Double?
}

struct FolyncMarketCoverage: Codable, Equatable, Sendable {
    let requestedFrom: String
    let requestedTo: String
    let availableFrom: String?
    let availableTo: String?
    let pointCount: Int
    let complete: Bool
}

struct FolyncMarketHistory: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let resource: String
    let identity: FolyncInstrumentIdentity
    let range: String
    let interval: String
    let currency: String?
    let adjustment: String
    let quality: FolyncFinancialQuality
    let stale: Bool
    let reasonCodes: [String]
    let coverage: FolyncMarketCoverage
    let bars: [FolyncMarketBar]
}

struct FolyncBenchmark: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        let last: Double?
        let previousClose: Double?
        let change: Double?
        let changePct: Double?
        let asOf: String?
    }

    let id: String
    let symbol: String
    let name: String
    let currency: String
    let provider: String
    let current: Current
    let quality: FolyncFinancialQuality
    let stale: Bool
    let reasonCodes: [String]
    let coverage: FolyncMarketCoverage
    let bars: [FolyncMarketBar]
}

struct FolyncBenchmarksResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let range: String
    let interval: String
    let benchmarks: [FolyncBenchmark]
}

struct FolyncFXResponse: Codable, Equatable, Sendable {
    struct Coverage: Codable, Equatable, Sendable {
        let requestedFrom: String
        let requestedTo: String
        let availableFrom: String?
        let availableTo: String?
    }

    struct Rate: Codable, Equatable, Sendable {
        let quote: String
        let rate: Double?
        let asOf: String?
        let quality: FolyncFinancialQuality
        let reasonCodes: [String]
    }

    struct SeriesPoint: Codable, Equatable, Sendable {
        let date: String
        let rate: Double
        let source: String
    }

    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let base: String
    let quality: FolyncFinancialQuality
    let stale: Bool
    let reasonCodes: [String]
    let coverage: Coverage
    let rates: [Rate]
    let series: [String: [SeriesPoint]]
}

struct FolyncPortfolioHistory: Codable, Equatable, Sendable {
    struct SeriesPoint: Codable, Equatable, Sendable {
        let date: String
        let value: Double
    }

    struct Coverage: Codable, Equatable, Sendable {
        let requestedFrom: String?
        let requestedTo: String?
        let availableFrom: String?
        let availableTo: String?
        let pointCount: Int
        let complete: Bool?
    }

    let schemaVersion: Int
    let sourceRevision: String
    let scope: FolyncPortfolio
    let range: String
    let interval: String
    let generatedAt: String
    let currency: String?
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let coverage: Coverage
    let portfolioSeries: [SeriesPoint]
    let cashSeries: [SeriesPoint]
    let holdingsSeries: [SeriesPoint]
    let netContributionSeries: [SeriesPoint]
    let gainSeries: [SeriesPoint]
    let twrSeries: [SeriesPoint]
}

/// The money paid into a Folync scope less the money taken out: Folync's
/// "What if not investing" figure. Folync counts only deposits and
/// withdrawals, each at its own exchange rate; dividends, interest, fees and
/// trades are part of the gain instead. The client API gives it only as the
/// last point of a portfolio history's net contribution series.
struct FolyncNetDeposits: Equatable, Sendable {
    /// The history range read for it: the cheapest one, served from Folync's
    /// stored daily snapshots. Folync rebuilds those a minute or two after
    /// importing a deposit, and every five minutes regardless.
    static let historyRange = "3m"
    /// How often it is read again while Folync answers.
    static let refreshInterval: TimeInterval = 300
    /// How long a figure is kept while Folync's history cannot be read.
    /// After that, P&L is measured against the cost of the holdings.
    static let maximumAge: TimeInterval = 900

    let scopeID: String
    let currency: String?
    let amount: Double
    let asOf: String

    /// Nil when the history cannot give a figure to trust: it is unavailable;
    /// a deposit or withdrawal has no exchange rate, which stops the series
    /// early; the series ends before the value series does; or every point is
    /// zero against a value that is not, as for a broker account imported
    /// without its cash history.
    init?(history: FolyncPortfolioHistory) {
        guard history.quality != .unavailable,
              !history.reasonCodes.contains("missing_transaction_fx"),
              let last = history.netContributionSeries.max(by: { $0.date < $1.date }),
              last.value.isFinite,
              let lastValue = history.portfolioSeries.max(by: { $0.date < $1.date }),
              last.date == lastValue.date else { return nil }
        if lastValue.value != 0, history.netContributionSeries.allSatisfy({ $0.value == 0 }) {
            return nil
        }
        scopeID = history.scope.id
        currency = history.currency ?? history.scope.currency
        amount = last.value
        asOf = last.date
    }

    /// The amount, when it describes the snapshot's scope in the currency of
    /// its total value.
    func amount(for snapshot: FolyncPortfolioSnapshot) -> Double? {
        guard scopeID == snapshot.scope.id else { return nil }
        let valueCurrency = snapshot.totalValue.currency ?? snapshot.scope.currency
        if let currency, let valueCurrency, currency.uppercased() != valueCurrency.uppercased() {
            return nil
        }
        return amount
    }
}

enum FolyncSupplementalSourceStatus: String, Codable, Equatable, Sendable {
    case current
    case partial
    case stale
    case unavailable
    case legacy

    var label: String {
        switch self {
        case .current: "Folync"
        case .partial: "Folync · partial"
        case .stale: "Folync · stale cache"
        case .unavailable: "Unavailable"
        case .legacy: "Local provider"
        }
    }
}

struct FolyncSeriesMetadata: Equatable, Sendable {
    let interval: String
    let availableFrom: String?
    let availableTo: String?
    let pointCount: Int
    let coverageComplete: Bool
    let generatedAt: String
    let reasonCodes: [String]

    var coverageLabel: String {
        let completeness = coverageComplete ? "complete" : "partial coverage"
        return "\(pointCount) points · \(interval) · \(completeness)"
    }
}

enum FolyncRoutedOHLCResult: Sendable {
    case folync([OHLCSnapshot], status: FolyncSupplementalSourceStatus, metadata: FolyncSeriesMetadata)
    case legacy
    case unavailable
}

enum FolyncRoutedLineResult: Sendable {
    case folync(
        [PriceSnapshot],
        status: FolyncSupplementalSourceStatus,
        identity: FolyncInstrumentIdentity,
        metadata: FolyncSeriesMetadata
    )
    case legacy
    case unavailable
}

enum FolyncRoutedPortfolioResult: Sendable {
    case folync(FolyncPortfolioHistory, status: FolyncSupplementalSourceStatus)
    case legacy
    case unavailable
    /// Folync did not answer (no HTTP response at all, or a 502/503/504 from
    /// the server in front of it) and nothing usable is saved for the range.
    case unreachable
}

enum FolyncRoutedBenchmarkResult: Sendable {
    case folync([FolyncBenchmark], status: FolyncSupplementalSourceStatus)
    case legacy
    case unavailable
}

enum FolyncRoutedFXResult: Sendable {
    case folync(rates: [String: Double], asOf: Date?, status: FolyncSupplementalSourceStatus)
    case legacy
    case unavailable
}

protocol FolyncSupplementalOHLCProviding: Sendable {
    func routeOHLC(
        symbol: String,
        period: String,
        interval: String,
        from: Date?,
        to: Date?
    ) async throws -> FolyncRoutedOHLCResult
}

protocol FolyncSupplementalFXRouting: Sendable {
    func routeFX() async -> FolyncRoutedFXResult
}

enum FolyncSupplementalDateParser {
    static func instant(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        return ISO8601DateFormatter().date(from: value)
    }

    static func day(_ value: String) -> Date? {
        formatter.date(from: value)
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

private struct FolyncSupplementalCacheEnvelope: Codable, Sendable {
    let endpointFingerprint: String
    let scopeID: String
    let resource: String
    let identity: String
    let range: String
    let etag: String?
    let receiptTime: Date
    let payload: Data
}

actor FolyncSupplementalCache {
    static let shared = FolyncSupplementalCache()
    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? StockbarRuntimeStorage
            .stockbarApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("FolyncSupplemental", isDirectory: true)
    }

    func load<T: Decodable>(
        endpoint: String,
        scopeID: String,
        resource: String,
        identity: String,
        range: String,
        as type: T.Type
    ) throws -> (payload: T, etag: String?, receiptTime: Date)? {
        let key = cacheKey(endpoint: endpoint, scopeID: scopeID, resource: resource, identity: identity, range: range)
        let url = directory.appendingPathComponent("response-\(key.digest).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let envelope = try JSONDecoder().decode(FolyncSupplementalCacheEnvelope.self, from: Data(contentsOf: url))
        guard envelope.endpointFingerprint == key.endpointFingerprint,
              envelope.scopeID == scopeID,
              envelope.resource == resource,
              envelope.identity == identity,
              envelope.range == range else { return nil }
        return (try JSONDecoder().decode(T.self, from: envelope.payload), envelope.etag, envelope.receiptTime)
    }

    func save<T: Encodable>(
        _ payload: T,
        endpoint: String,
        scopeID: String,
        resource: String,
        identity: String,
        range: String,
        etag: String?,
        receiptTime: Date = Date()
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !hasRemovedOldEntries {
            hasRemovedOldEntries = true
            removeEntries()
        }
        let key = cacheKey(endpoint: endpoint, scopeID: scopeID, resource: resource, identity: identity, range: range)
        let envelope = FolyncSupplementalCacheEnvelope(
            endpointFingerprint: key.endpointFingerprint,
            scopeID: scopeID,
            resource: resource,
            identity: identity,
            range: range,
            etag: etag,
            receiptTime: receiptTime,
            payload: try JSONEncoder().encode(payload)
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: directory.appendingPathComponent("response-\(key.digest).json"), options: .atomic)
    }

    /// Responses for holdings since sold, or for a server no longer used, are
    /// never asked for again, so nothing else would remove them.
    static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60
    private var hasRemovedOldEntries = false

    @discardableResult
    func removeEntries(olderThan age: TimeInterval = FolyncSupplementalCache.maximumEntryAge, now: Date = Date()) -> Int {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        var removed = 0
        for file in files
        where file.lastPathComponent.hasPrefix("response-") && file.pathExtension == "json" {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    private func cacheKey(
        endpoint: String,
        scopeID: String,
        resource: String,
        identity: String,
        range: String
    ) -> (endpointFingerprint: String, digest: String) {
        let endpointFingerprint = digest(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return (endpointFingerprint, digest([endpointFingerprint, scopeID, resource, identity, range].joined(separator: "|")))
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

actor FolyncSupplementalCoordinator: FolyncSupplementalOHLCProviding, FolyncSupplementalFXRouting {
    static let shared = FolyncSupplementalCoordinator(backoff: .shared)

    private let settingsStore: FolyncSettingsStore
    private let tokenProvider: @Sendable () throws -> String
    private let cache: FolyncSupplementalCache
    private let session: URLSession
    private let providerPolicy: StockbarProviderAccessPolicy
    private let backoff: FolyncBackoffCoordinator
    private var memoryCapabilities: [String: FolyncCapabilities] = [:]
    /// When Folync last confirmed each saved portfolio history, by a full
    /// answer or a 304. The file is not rewritten on a 304, so its receipt time
    /// alone would make an unchanged history look old.
    private var portfolioHistoryConfirmedAt: [String: Date] = [:]
    /// Ranges whose last portfolio-history request failed, so the log gets one
    /// line when a range starts failing and one when it works again.
    private var portfolioHistoryFailing: Set<String> = []
    /// The single policy in front of the three ledger routes.
    private let ledgerPolicy: FolyncLedgerFetchPolicy
    /// Ledger route, scope and query combinations whose last request failed,
    /// for one log line when one starts failing and one when it recovers.
    private var ledgerFailing: Set<String> = []

    init(
        settingsStore: FolyncSettingsStore = .shared,
        credentialStore: FolyncCredentialStore = .shared,
        cache: FolyncSupplementalCache = .shared,
        session: URLSession = .shared,
        providerPolicy: StockbarProviderAccessPolicy = .current,
        backoff: FolyncBackoffCoordinator = FolyncBackoffCoordinator(),
        ledgerPolicy: FolyncLedgerFetchPolicy = FolyncLedgerFetchPolicy(),
        tokenProvider: (@Sendable () throws -> String)? = nil
    ) {
        self.ledgerPolicy = ledgerPolicy
        self.settingsStore = settingsStore
        self.tokenProvider = tokenProvider ?? {
            let baseURL = settingsStore.load().baseURL
            credentialStore.recordServerIfMissing(baseURL)
            return try credentialStore.load(for: baseURL)
        }
        self.cache = cache
        self.session = session
        self.providerPolicy = providerPolicy
        self.backoff = backoff
    }

    /// Where capabilities documents are saved. Documents saved before the
    /// ledger resources existed are under `legacyCapabilitiesRange`: their
    /// ETag is never sent, because a 304 would confirm a document that drops
    /// those resources and hide them for good. They are still shown while
    /// Folync does not answer.
    private static let capabilitiesRange = "ledger-v1"
    private static let legacyCapabilitiesRange = "-"

    private func savedCapabilities(
        endpoint: String,
        includingLegacy: Bool
    ) async -> (payload: FolyncCapabilities, etag: String?)? {
        let ranges = includingLegacy ? [Self.capabilitiesRange, Self.legacyCapabilitiesRange] : [Self.capabilitiesRange]
        for range in ranges {
            if let saved = try? await cache.load(
                endpoint: endpoint, scopeID: "-", resource: "capabilities", identity: "-", range: range,
                as: FolyncCapabilities.self
            ) {
                return (saved.payload, saved.etag)
            }
        }
        return nil
    }

    func fetchCapabilities(baseURL: URL, token: String) async throws -> FolyncCapabilities? {
        let endpoint = baseURL.absoluteString
        let resource = "capabilities"
        let cached = await savedCapabilities(endpoint: endpoint, includingLegacy: false)
        let response = try await request(
            baseURL: baseURL,
            token: token,
            path: ["api", "client", "v2", "capabilities"],
            query: [],
            etag: cached?.etag
        )
        if response.statusCode == 404 {
            memoryCapabilities.removeValue(forKey: endpoint)
            return nil
        }
        if response.statusCode == 304, let cached {
            memoryCapabilities[endpoint] = cached.payload
            return cached.payload
        }
        try await validate(response)
        let capabilities = try decode(FolyncCapabilities.self, data: response.data)
        try validateSchema(capabilities.schemaVersion)
        memoryCapabilities[endpoint] = capabilities
        try await cache.save(
            capabilities,
            endpoint: endpoint,
            scopeID: "-",
            resource: resource,
            identity: "-",
            range: Self.capabilitiesRange,
            etag: response.etag
        )
        return capabilities
    }

    func capabilitiesForCurrentSettings(refresh: Bool = false) async -> FolyncCapabilities? {
        guard let configuration = await currentConfiguration() else { return nil }
        if !refresh, let capabilities = memoryCapabilities[configuration.endpoint] { return capabilities }
        do {
            return try await fetchCapabilities(baseURL: configuration.baseURL, token: configuration.token)
        } catch {
            if let cached = await savedCapabilities(endpoint: configuration.endpoint, includingLegacy: true) {
                memoryCapabilities[configuration.endpoint] = cached.payload
                return cached.payload
            }
            return nil
        }
    }

    func routeOHLC(
        symbol: String,
        period: String,
        interval: String,
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> FolyncRoutedOHLCResult {
        guard let context = await routingContext(route: .candlestickCharts, symbol: symbol) else {
            return .legacy
        }
        guard let resolved = context.resolvedSymbol else { return .legacy }
        let requestedRange = from != nil && to != nil ? "custom" : range(forPeriod: period)
        switch await marketHistory(
            context: context.configuration,
            symbol: resolved,
            range: requestedRange,
            from: from,
            to: to,
            allowNetwork: context.routeAvailable,
            requireOHLC: true
        ) {
        case .response(let response, let status):
            let snapshots = response.bars.compactMap { bar -> OHLCSnapshot? in
                guard let date = FolyncSupplementalDateParser.instant(bar.timestamp),
                      let open = bar.open, let high = bar.high, let low = bar.low,
                      [open, high, low, bar.close].allSatisfy({ $0.isFinite }),
                      high >= low else { return nil }
                return OHLCSnapshot(
                    symbol: response.identity.displayTicker,
                    timestamp: date,
                    open: open,
                    high: high,
                    low: low,
                    close: bar.close,
                    volume: bar.volume.map { Int64($0.rounded(.towardZero)) }
                )
            }
            guard !snapshots.isEmpty else {
                return context.configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
            }
            return .folync(snapshots, status: status, metadata: seriesMetadata(response))
        case .unavailable:
            return context.configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
    }

    func routeLineHistory(
        symbol: String,
        range: String,
        from: Date? = nil,
        to: Date? = nil
    ) async -> FolyncRoutedLineResult {
        guard let context = await routingContext(route: .historicalLineCharts, symbol: symbol) else {
            return .legacy
        }
        guard let resolved = context.resolvedSymbol else { return .legacy }
        switch await marketHistory(
            context: context.configuration,
            symbol: resolved,
            range: range,
            from: from,
            to: to,
            allowNetwork: context.routeAvailable,
            requireOHLC: false
        ) {
        case .response(let response, let status):
            let firstClose = response.bars.first?.close ?? 0
            let points = response.bars.compactMap { bar -> PriceSnapshot? in
                guard let date = FolyncSupplementalDateParser.instant(bar.timestamp), bar.close.isFinite else { return nil }
                return PriceSnapshot(
                    timestamp: date,
                    price: bar.close,
                    previousClose: firstClose,
                    volume: bar.volume,
                    symbol: response.identity.displayTicker
                )
            }
            guard !points.isEmpty else {
                return context.configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
            }
            return .folync(
                points,
                status: status,
                identity: response.identity,
                metadata: seriesMetadata(response)
            )
        case .unavailable:
            return context.configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
    }

    func routePortfolioHistory(
        range: String,
        from: Date? = nil,
        to: Date? = nil
    ) async -> FolyncRoutedPortfolioResult {
        // Portfolio valuations are part of the authoritative portfolio source.
        // The optional line-history capability describes individual market prices.
        guard let configuration = await currentConfiguration() else { return .legacy }
        let identity = configuration.settings.scopeID
        let resource = Self.portfolioHistoryResource
        let query = marketQuery(range: range, from: from, to: to)
        let cacheRange = query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let cached: (payload: FolyncPortfolioHistory, etag: String?, receiptTime: Date)? = try? await cache.load(
            endpoint: configuration.endpoint,
            scopeID: configuration.settings.scopeID,
            resource: resource,
            identity: identity,
            range: cacheRange,
            as: FolyncPortfolioHistory.self
        )
        do {
            let response = try await request(
                baseURL: configuration.baseURL,
                token: configuration.token,
                path: ["api", "client", "v2", "scopes", configuration.settings.scopeID, "history"],
                query: query,
                etag: cached?.etag
            )
            let confirmationKey = portfolioHistoryKey(endpoint: configuration.endpoint, scopeID: identity, range: cacheRange)
            if response.statusCode == 304, let cached, isUsablePortfolioHistory(cached.payload) {
                portfolioHistoryConfirmedAt[confirmationKey] = Date()
                await notePortfolioHistoryRecovered(key: confirmationKey, range: range)
                return .folync(cached.payload, status: sourceStatus(quality: cached.payload.quality, stale: false))
            }
            try await validate(response)
            let payload = try decode(FolyncPortfolioHistory.self, data: response.data)
            try validateSchema(payload.schemaVersion)
            guard isUsablePortfolioHistory(payload) else {
                throw FolyncPortfolioSourceError.invalidPayload("Portfolio history is unavailable or incomplete")
            }
            try await cache.save(
                payload,
                endpoint: configuration.endpoint,
                scopeID: configuration.settings.scopeID,
                resource: resource,
                identity: identity,
                range: cacheRange,
                etag: response.etag
            )
            portfolioHistoryConfirmedAt[confirmationKey] = Date()
            await notePortfolioHistoryRecovered(key: confirmationKey, range: range)
            return .folync(payload, status: sourceStatus(quality: payload.quality, stale: false))
        } catch {
            let category = FolyncRefreshSchedule.failureCategory(error)
            let usableCache = cached.flatMap { isUsablePortfolioHistory($0.payload) ? $0.payload : nil }
            if category != "cancelled" {
                await notePortfolioHistoryFailed(
                    key: portfolioHistoryKey(endpoint: configuration.endpoint, scopeID: identity, range: cacheRange),
                    range: range, category: category, showingSaved: usableCache != nil
                )
            }
            if let usableCache {
                return .folync(usableCache, status: .stale)
            }
            if configuration.settings.supplemental.allowLegacyFallback { return .legacy }
            return Self.isUnreachable(category: category) ? .unreachable : .unavailable
        }
    }

    /// True when a failure means Folync did not answer at all: no HTTP
    /// response (any connection error, see `FolyncRefreshSchedule.failureCategory`)
    /// or a gateway saying it could not reach Folync. An error status or data
    /// Stockbar cannot use is an answer.
    static func isUnreachable(category: String) -> Bool {
        ["timeout", "offline", "unreachable", "http-502", "http-503", "http-504"].contains(category)
            || category.hasPrefix("network-")
    }

    private func notePortfolioHistoryFailed(key: String, range: String, category: String, showingSaved: Bool) async {
        let fallback = showingSaved ? "showing the saved copy" : "nothing saved to show"
        if portfolioHistoryFailing.insert(key).inserted {
            await Logger.shared.warning("Folync portfolio history (\(range)) failed (\(category)); \(fallback)")
        } else {
            await Logger.shared.debug("Folync portfolio history (\(range)) failed again (\(category)); \(fallback)")
        }
    }

    private func notePortfolioHistoryRecovered(key: String, range: String) async {
        guard portfolioHistoryFailing.remove(key) != nil else { return }
        await Logger.shared.info("Folync portfolio history (\(range)) answered again")
    }

    private static let portfolioHistoryResource = "portfolio-history"

    private func portfolioHistoryKey(endpoint: String, scopeID: String, range: String) -> String {
        "\(endpoint)\n\(scopeID)\n\(range)"
    }

    /// The portfolio history saved from Folync's last full answer for `range`,
    /// read from disk: no request and no Keychain read, so it is quick. A chart
    /// shows it while `routePortfolioHistory` asks Folync whether there is a
    /// newer one. Nil when Folync is off, nothing usable is saved, or Folync
    /// last confirmed it, by a full answer or a 304, more than `maximumAge` ago.
    func savedPortfolioHistory(
        range: String,
        maximumAge: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) async -> FolyncPortfolioHistory? {
        let settings = settingsStore.load()
        guard settings.isEnabled, URL(string: settings.baseURL) != nil else { return nil }
        let cacheRange = marketQuery(range: range, from: nil, to: nil)
            .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        guard let saved = try? await cache.load(
            endpoint: settings.baseURL,
            scopeID: settings.scopeID,
            resource: Self.portfolioHistoryResource,
            identity: settings.scopeID,
            range: cacheRange,
            as: FolyncPortfolioHistory.self
        ) else { return nil }
        let confirmed = portfolioHistoryConfirmedAt[
            portfolioHistoryKey(endpoint: settings.baseURL, scopeID: settings.scopeID, range: cacheRange)
        ]
        let age = now.timeIntervalSince(max(saved.receiptTime, confirmed ?? .distantPast))
        guard age >= 0, age <= maximumAge, isUsablePortfolioHistory(saved.payload) else { return nil }
        return saved.payload
    }

    func routeBenchmarks() async -> FolyncRoutedBenchmarkResult {
        guard let configuration = await currentConfiguration(),
              configuration.settings.isSupplementalRouteActive(.benchmarkMarketData) else { return .legacy }
        let resource = "benchmarks"
        let cached: (payload: FolyncBenchmarksResponse, etag: String?, receiptTime: Date)? = try? await cache.load(
            endpoint: configuration.endpoint,
            scopeID: configuration.settings.scopeID,
            resource: resource,
            identity: "configured",
            range: "1d",
            as: FolyncBenchmarksResponse.self
        )
        guard let capabilities = await capabilitiesForCurrentSettings(),
              capabilities.resources.benchmarks.isUsable else {
            if let cached, isUsableBenchmarks(cached.payload.benchmarks) {
                return .folync(cached.payload.benchmarks, status: .stale)
            }
            return configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
        do {
            let response = try await request(
                baseURL: configuration.baseURL,
                token: configuration.token,
                path: ["api", "client", "v2", "market", "benchmarks"],
                query: [URLQueryItem(name: "range", value: "1d")],
                etag: cached?.etag
            )
            if response.statusCode == 304, let cached, isUsableBenchmarks(cached.payload.benchmarks) {
                return .folync(cached.payload.benchmarks, status: benchmarkStatus(cached.payload.benchmarks))
            }
            try await validate(response)
            let payload = try decode(FolyncBenchmarksResponse.self, data: response.data)
            try validateSchema(payload.schemaVersion)
            guard isUsableBenchmarks(payload.benchmarks) else {
                throw FolyncPortfolioSourceError.invalidPayload("Benchmark response has no complete usable series")
            }
            try await cache.save(
                payload,
                endpoint: configuration.endpoint,
                scopeID: configuration.settings.scopeID,
                resource: resource,
                identity: "configured",
                range: "1d",
                etag: response.etag
            )
            return .folync(payload.benchmarks, status: benchmarkStatus(payload.benchmarks))
        } catch {
            if let cached, isUsableBenchmarks(cached.payload.benchmarks) {
                return .folync(cached.payload.benchmarks, status: .stale)
            }
            return configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
    }

    func routeFX() async -> FolyncRoutedFXResult {
        guard let configuration = await currentConfiguration(),
              configuration.settings.isSupplementalRouteActive(.exchangeRates) else { return .legacy }
        let capabilities = await capabilitiesForCurrentSettings()
        let requiredQuotes = Set(Self.requiredFXQuotes).union(
            capabilities?.fx.quotes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty } ?? []
        )
        let quotesValue = Self.orderedFXQuotes(from: requiredQuotes).joined(separator: ",")
        let calendar = Calendar(identifier: .gregorian)
        let to = Date()
        let from = calendar.date(byAdding: .day, value: -31, to: to) ?? to
        let formatter = Self.dayFormatter
        let query = [
            URLQueryItem(name: "base", value: "USD"),
            URLQueryItem(name: "quotes", value: quotesValue),
            URLQueryItem(name: "from", value: formatter.string(from: from)),
            URLQueryItem(name: "to", value: formatter.string(from: to))
        ]
        let resource = "fx"
        // Keep one rolling cache identity so yesterday's last valid response is
        // still usable as an explicitly stale Folync result after midnight.
        let cacheRange = "rolling-31d|USD|\(quotesValue)"
        let cached: (payload: FolyncFXResponse, etag: String?, receiptTime: Date)? = try? await cache.load(
            endpoint: configuration.endpoint,
            scopeID: configuration.settings.scopeID,
            resource: resource,
            identity: "USD",
            range: cacheRange,
            as: FolyncFXResponse.self
        )
        guard capabilities?.resources.exchangeRates.isUsable == true else {
            if let cached, let parsed = usableFX(cached.payload, requiredQuotes: requiredQuotes) {
                return .folync(rates: parsed.rates, asOf: parsed.asOf, status: .stale)
            }
            return configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
        do {
            let response = try await request(
                baseURL: configuration.baseURL,
                token: configuration.token,
                path: ["api", "client", "v2", "market", "fx"],
                query: query,
                etag: cached?.etag
            )
            if response.statusCode == 304, let cached,
               let parsed = usableFX(cached.payload, requiredQuotes: requiredQuotes) {
                return .folync(
                    rates: parsed.rates,
                    asOf: parsed.asOf,
                    status: sourceStatus(quality: cached.payload.quality, stale: cached.payload.stale)
                )
            }
            try await validate(response)
            let payload = try decode(FolyncFXResponse.self, data: response.data)
            try validateSchema(payload.schemaVersion)
            guard let parsed = usableFX(payload, requiredQuotes: requiredQuotes) else {
                throw FolyncPortfolioSourceError.invalidPayload("FX response does not contain every required currency")
            }
            try await cache.save(
                payload,
                endpoint: configuration.endpoint,
                scopeID: configuration.settings.scopeID,
                resource: resource,
                identity: "USD",
                range: cacheRange,
                etag: response.etag
            )
            return .folync(
                rates: parsed.rates,
                asOf: parsed.asOf,
                status: sourceStatus(quality: payload.quality, stale: payload.stale)
            )
        } catch {
            if let cached, let parsed = usableFX(cached.payload, requiredQuotes: requiredQuotes) {
                return .folync(rates: parsed.rates, asOf: parsed.asOf, status: .stale)
            }
            return configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
    }

    func clearInMemoryState() async {
        memoryCapabilities.removeAll()
        await ledgerPolicy.removeAll()
        await backoff.clear()
    }

    // MARK: Ledger routes

    /// Page one of the scope's dividends. Reused for five minutes unless
    /// `forceRefresh`; see `FolyncLedgerFetchPolicy`.
    func routeDividends(
        _ query: FolyncDividendsQuery = FolyncDividendsQuery(),
        forceRefresh: Bool = false
    ) async -> FolyncRoutedDividendsResult {
        await routeLedger(query, continuation: nil, forceRefresh: forceRefresh)
    }

    /// The page after `continuation`, taken from the last page loaded.
    func loadMoreDividends(
        _ query: FolyncDividendsQuery,
        after continuation: FolyncLedgerContinuation
    ) async -> FolyncRoutedDividendsResult {
        await routeLedger(query, continuation: continuation, forceRefresh: true)
    }

    func routeTradeAnalysis(
        _ query: FolyncTradeAnalysisQuery = FolyncTradeAnalysisQuery(),
        forceRefresh: Bool = false
    ) async -> FolyncRoutedTradeAnalysisResult {
        await routeLedger(query, continuation: nil, forceRefresh: forceRefresh)
    }

    func loadMoreTradeAnalysis(
        _ query: FolyncTradeAnalysisQuery,
        after continuation: FolyncLedgerContinuation
    ) async -> FolyncRoutedTradeAnalysisResult {
        await routeLedger(query, continuation: continuation, forceRefresh: true)
    }

    func routeTransactions(
        _ query: FolyncTransactionsQuery = FolyncTransactionsQuery(),
        forceRefresh: Bool = false
    ) async -> FolyncRoutedTransactionsResult {
        await routeLedger(query, continuation: nil, forceRefresh: forceRefresh)
    }

    func loadMoreTransactions(
        _ query: FolyncTransactionsQuery,
        after continuation: FolyncLedgerContinuation
    ) async -> FolyncRoutedTransactionsResult {
        await routeLedger(query, continuation: continuation, forceRefresh: true)
    }

    /// The gates run before the fetch policy, so a route switched off, a bad
    /// scope or a missing capability never gets an answer from the reuse window.
    private func routeLedger<Query: FolyncLedgerQuery, Response: FolyncLedgerResponse>(
        _ query: Query,
        continuation: FolyncLedgerContinuation?,
        forceRefresh: Bool
    ) async -> FolyncRoutedLedgerResult<Response> {
        let route = Query.route
        // Settings first: a route switched off needs no Keychain read.
        guard settingsStore.load().isLedgerRouteActive(route),
              let configuration = await currentConfiguration(),
              configuration.settings.isLedgerRouteActive(route) else { return .disabled }
        let scopeID = configuration.settings.scopeID
        guard (try? FolyncPortfolioSource.validateScopeComponent(scopeID)) != nil else { return .unavailable }
        guard let capabilities = await capabilitiesForCurrentSettings(),
              capabilities.resources.capability(for: route)?.isUsable == true else { return .unavailable }
        let key = FolyncLedgerFetchPolicy.Key(
            route: route,
            endpoint: configuration.endpoint,
            scopeID: scopeID,
            query: query.cacheKey,
            cursor: continuation?.cursor
        )
        let result: FolyncRoutedLedgerResult<Response>? = await ledgerPolicy.perform(
            key, forceRefresh: forceRefresh
        ) { [self] in
            if let continuation {
                return await self.fetchLedgerLaterPage(query, after: continuation, configuration: configuration)
            }
            let first: LedgerFirstPage<Response> = await self.fetchLedgerFirstPage(query, configuration: configuration)
            return .init(result: first.result, firstPageToKeep: first.isFresh ? first.result : nil)
        }
        // Nil only for a cancelled caller, which has stopped listening: no
        // request was made for it.
        return result ?? .unavailable
    }

    private struct LedgerFirstPage<Response: FolyncLedgerResponse>: Sendable {
        let result: FolyncRoutedLedgerResult<Response>
        /// Folync confirmed it just now, by a full answer or a 304.
        let isFresh: Bool
    }

    /// Asks for page one, with the saved copy's ETag. Runs inside the policy's turn.
    private func fetchLedgerFirstPage<Query: FolyncLedgerQuery, Response: FolyncLedgerResponse>(
        _ query: Query,
        configuration: Configuration
    ) async -> LedgerFirstPage<Response> {
        let route = Query.route
        let scopeID = configuration.settings.scopeID
        let saved = try? await cache.load(
            endpoint: configuration.endpoint,
            scopeID: scopeID,
            resource: route.cacheResource,
            identity: scopeID,
            range: query.cacheKey,
            as: Response.self
        )
        let usableSaved = saved.flatMap { isUsableLedger($0.payload, scopeID: scopeID) ? $0 : nil }
        let failureKey = ledgerFailureKey(route: route, configuration: configuration, query: query)
        do {
            let response = try await request(
                baseURL: configuration.baseURL,
                token: configuration.token,
                path: ledgerPath(route, scopeID: scopeID),
                query: query.queryItems(cursor: nil),
                etag: usableSaved?.etag
            )
            if response.statusCode == 304, let usableSaved {
                await noteLedgerRecovered(key: failureKey, route: route)
                let status = sourceStatus(quality: usableSaved.payload.quality, stale: false)
                return LedgerFirstPage(result: .folync(usableSaved.payload, status: status, paging: .firstPage), isFresh: true)
            }
            let payload: Response = try await decodeLedger(response, scopeID: scopeID)
            // A copy that cannot be written is still a good answer.
            try? await cache.save(
                payload,
                endpoint: configuration.endpoint,
                scopeID: scopeID,
                resource: route.cacheResource,
                identity: scopeID,
                range: query.cacheKey,
                etag: response.etag
            )
            await noteLedgerRecovered(key: failureKey, route: route)
            let status = sourceStatus(quality: payload.quality, stale: false)
            return LedgerFirstPage(result: .folync(payload, status: status, paging: .firstPage), isFresh: true)
        } catch {
            let result = await ledgerFailure(
                error, route: route, failureKey: failureKey, saved: usableSaved?.payload, paging: .firstPage
            )
            return LedgerFirstPage(result: result, isFresh: false)
        }
    }

    /// Asks for the page after `continuation`. A later page is never saved,
    /// never reused and never replaced by a saved copy. On a 409, a refused
    /// cursor or a changed collection revision, paging restarts from page one.
    private func fetchLedgerLaterPage<Query: FolyncLedgerQuery, Response: FolyncLedgerResponse>(
        _ query: Query,
        after continuation: FolyncLedgerContinuation,
        configuration: Configuration
    ) async -> FolyncLedgerFetchPolicy.Outcome<FolyncRoutedLedgerResult<Response>> {
        let route = Query.route
        let scopeID = configuration.settings.scopeID
        let failureKey = ledgerFailureKey(route: route, configuration: configuration, query: query)
        do {
            let response = try await request(
                baseURL: configuration.baseURL,
                token: configuration.token,
                path: ledgerPath(route, scopeID: scopeID),
                query: query.queryItems(cursor: continuation.cursor),
                etag: nil
            )
            if response.statusCode == 409
                || (response.statusCode == 400 && FolyncClientAPIErrorBody.refusesCursor(response.data)) {
                return await restartLedgerPaging(query, configuration: configuration)
            }
            let payload: Response = try await decodeLedger(response, scopeID: scopeID)
            guard payload.page.collectionRevision == continuation.collectionRevision else {
                return await restartLedgerPaging(query, configuration: configuration)
            }
            await noteLedgerRecovered(key: failureKey, route: route)
            let status = sourceStatus(quality: payload.quality, stale: false)
            return .init(result: .folync(payload, status: status, paging: .nextPage), firstPageToKeep: nil)
        } catch {
            // The caller keeps the rows it has; page one's saved copy is not swapped in.
            let result: FolyncRoutedLedgerResult<Response> = await ledgerFailure(
                error, route: route, failureKey: failureKey, saved: nil, paging: .nextPage
            )
            return .init(result: result, firstPageToKeep: nil)
        }
    }

    /// Page one again, asked for afresh in the same turn (asking the policy
    /// again from inside its turn would wait for ever). Saved and kept like
    /// any page one; the caller is told to drop what it gathered.
    private func restartLedgerPaging<Query: FolyncLedgerQuery, Response: FolyncLedgerResponse>(
        _ query: Query,
        configuration: Configuration
    ) async -> FolyncLedgerFetchPolicy.Outcome<FolyncRoutedLedgerResult<Response>> {
        await Logger.shared.info("Folync \(Query.route.rawValue) paging restarted from the first page")
        let first: LedgerFirstPage<Response> = await fetchLedgerFirstPage(query, configuration: configuration)
        let restarted: FolyncRoutedLedgerResult<Response> = switch first.result {
        case .folync(let payload, let status, _): .folync(payload, status: status, paging: .restarted)
        case .disabled, .unavailable, .unreachable: first.result
        }
        return .init(result: restarted, firstPageToKeep: first.isFresh ? first.result : nil)
    }

    private func decodeLedger<Response: FolyncLedgerResponse>(
        _ response: HTTPResult,
        scopeID: String
    ) async throws -> Response {
        try await validate(response)
        let payload = try decode(Response.self, data: response.data)
        try validateSchema(payload.schemaVersion)
        guard isUsableLedger(payload, scopeID: scopeID) else {
            throw FolyncPortfolioSourceError.invalidPayload("Ledger page is for another scope or is inconsistent")
        }
        return payload
    }

    /// A 404 means the server has no such route or scope: unavailable, with no
    /// saved copy (there is nothing to refresh it from). Otherwise a usable
    /// saved copy is shown as stale; failing that, unreachable when Folync did
    /// not answer and unavailable when it answered with an error.
    private func ledgerFailure<Response: FolyncLedgerResponse>(
        _ error: Error,
        route: FolyncLedgerRoute,
        failureKey: String,
        saved: Response?,
        paging: FolyncLedgerPaging
    ) async -> FolyncRoutedLedgerResult<Response> {
        let category = FolyncRefreshSchedule.failureCategory(error)
        let routeMissing = category == "http-404"
        if category != "cancelled" {
            await noteLedgerFailed(
                key: failureKey, route: route, category: category, showingSaved: saved != nil && !routeMissing
            )
        }
        if routeMissing { return .unavailable }
        if let saved { return .folync(saved, status: .stale, paging: paging) }
        return Self.isUnreachable(category: category) ? .unreachable : .unavailable
    }

    /// Light on purpose: figures carry their own quality and nulls, and an
    /// unavailable valuation is still an answer to show. Rejects only a page
    /// for another scope or one whose paging fields do not fit together.
    private func isUsableLedger<Response: FolyncLedgerResponse>(_ payload: Response, scopeID: String) -> Bool {
        payload.scope.id == scopeID
            && payload.page.limit >= 1
            && !payload.page.collectionRevision.isEmpty
            && (!payload.page.hasMore || payload.page.continuation != nil)
    }

    private func ledgerPath(_ route: FolyncLedgerRoute, scopeID: String) -> [String] {
        ["api", "client", "v2", "scopes", scopeID, route.pathComponent]
    }

    private func ledgerFailureKey<Query: FolyncLedgerQuery>(
        route: FolyncLedgerRoute,
        configuration: Configuration,
        query: Query
    ) -> String {
        [route.rawValue, configuration.endpoint, configuration.settings.scopeID, query.cacheKey].joined(separator: "\n")
    }

    private func noteLedgerFailed(key: String, route: FolyncLedgerRoute, category: String, showingSaved: Bool) async {
        let fallback = showingSaved ? "showing the saved copy" : "nothing saved to show"
        if ledgerFailing.insert(key).inserted {
            await Logger.shared.warning("Folync \(route.rawValue) failed (\(category)); \(fallback)")
        } else {
            await Logger.shared.debug("Folync \(route.rawValue) failed again (\(category)); \(fallback)")
        }
    }

    private func noteLedgerRecovered(key: String, route: FolyncLedgerRoute) async {
        guard ledgerFailing.remove(key) != nil else { return }
        await Logger.shared.info("Folync \(route.rawValue) answered again")
    }

    func backoffUntil() async -> Date? {
        await backoff.until()
    }

    func isBackingOff(at now: Date = Date()) async -> Bool {
        await backoff.isBackingOff(at: now)
    }

    @discardableResult
    func recordBackoff(after error: Error, at now: Date = Date()) async -> Date? {
        await backoff.recordFailure(error, at: now)
    }

    func clearBackoff() async {
        await backoff.clear()
    }

    private struct Configuration: Sendable {
        let settings: FolyncStoredSettings
        let endpoint: String
        let baseURL: URL
        let token: String
    }

    private struct RoutingContext: Sendable {
        let configuration: Configuration
        let routeAvailable: Bool
        let resolvedSymbol: String?
    }

    private enum CachedMarketResult: Sendable {
        case response(FolyncMarketHistory, FolyncSupplementalSourceStatus)
        case unavailable
    }

    private func currentConfiguration() async -> Configuration? {
        let settings = settingsStore.load()
        guard settings.isEnabled,
              let baseURL = URL(string: settings.baseURL) else { return nil }
        // A Keychain read can wait on a macOS access prompt. Reading off the
        // actor keeps clearBackoff() and other coordinator calls responsive
        // while the prompt is open.
        let tokenProvider = self.tokenProvider
        guard let token = try? await Task.detached(priority: .utility, operation: {
            try tokenProvider()
        }).value else { return nil }
        return Configuration(settings: settings, endpoint: settings.baseURL, baseURL: baseURL, token: token)
    }

    private func routingContext(route: FolyncSupplementalRoute, symbol: String) async -> RoutingContext? {
        guard let configuration = await currentConfiguration(),
              configuration.settings.isSupplementalRouteActive(route) else { return nil }
        guard let capabilities = await capabilitiesForCurrentSettings() else {
            // Older v2 servers have no capabilities route. Keep the requested identity
            // so a last-valid Folync cache can still be considered, but disable network
            // history requests and apply the user's fallback policy if no cache exists.
            return RoutingContext(configuration: configuration, routeAvailable: false, resolvedSymbol: symbol)
        }
        let capability: FolyncCapability = switch route {
        case .historicalLineCharts: capabilities.resources.lineHistory
        case .candlestickCharts: capabilities.resources.candlesticks
        case .benchmarkMarketData: capabilities.resources.benchmarks
        case .exchangeRates: capabilities.resources.exchangeRates
        }
        let identityCapability = capabilities.marketIdentities?.first {
            $0.identity.matches(symbol)
        }
        let identityReady: Bool = switch route {
        case .historicalLineCharts:
            capabilities.marketIdentities == nil
                ? true
                : identityCapability?.resources.lineHistory.isUsable == true
        case .candlestickCharts:
            capabilities.marketIdentities == nil
                ? true
                : identityCapability?.resources.candlesticks.isUsable == true
        case .benchmarkMarketData, .exchangeRates:
            true
        }
        let routeAvailable = capability.isUsable && identityReady
        if let identity = capabilities.identity(for: symbol) {
            return RoutingContext(
                configuration: configuration,
                routeAvailable: routeAvailable,
                resolvedSymbol: identity.quoteSymbol
            )
        }
        if let identityCapability {
            return RoutingContext(
                configuration: configuration,
                routeAvailable: routeAvailable,
                resolvedSymbol: identityCapability.identity.quoteSymbol
            )
        }
        if capabilities.isTrackedOrAllowlisted(symbol) {
            return RoutingContext(
                configuration: configuration,
                routeAvailable: routeAvailable,
                resolvedSymbol: symbol
            )
        }
        return RoutingContext(configuration: configuration, routeAvailable: routeAvailable, resolvedSymbol: nil)
    }

    private func marketHistory(
        context: Configuration,
        symbol: String,
        range: String,
        from: Date? = nil,
        to: Date? = nil,
        allowNetwork: Bool = true,
        requireOHLC: Bool
    ) async -> CachedMarketResult {
        let query = marketQuery(range: range, from: from, to: to)
        let cacheRange = query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cached: (payload: FolyncMarketHistory, etag: String?, receiptTime: Date)? = try? await cache.load(
            endpoint: context.endpoint,
            scopeID: context.settings.scopeID,
            resource: "market-history",
            identity: normalized,
            range: cacheRange,
            as: FolyncMarketHistory.self
        )
        if !allowNetwork {
            if let cached, isUsableMarketHistory(cached.payload, requireOHLC: requireOHLC) {
                return .response(cached.payload, .stale)
            }
            return .unavailable
        }
        do {
            let response = try await request(
                baseURL: context.baseURL,
                token: context.token,
                path: ["api", "client", "v2", "market", "symbols", normalized, "history"],
                query: query,
                etag: cached?.etag
            )
            if response.statusCode == 304, let cached,
               isUsableMarketHistory(cached.payload, requireOHLC: requireOHLC) {
                return .response(cached.payload, sourceStatus(quality: cached.payload.quality, stale: cached.payload.stale))
            }
            try await validate(response)
            let payload = try decode(FolyncMarketHistory.self, data: response.data)
            try validateSchema(payload.schemaVersion)
            guard isUsableMarketHistory(payload, requireOHLC: requireOHLC) else {
                throw FolyncPortfolioSourceError.invalidPayload("Market history is unavailable, empty, or non-finite")
            }
            try await cache.save(
                payload,
                endpoint: context.endpoint,
                scopeID: context.settings.scopeID,
                resource: "market-history",
                identity: normalized,
                range: cacheRange,
                etag: response.etag
            )
            return .response(payload, sourceStatus(quality: payload.quality, stale: payload.stale))
        } catch {
            if let cached, isUsableMarketHistory(cached.payload, requireOHLC: requireOHLC) {
                return .response(cached.payload, .stale)
            }
            return .unavailable
        }
    }

    private func marketQuery(range: String, from: Date?, to: Date?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "range", value: range)]
        if range == "custom", let from, let to {
            query.append(URLQueryItem(name: "from", value: Self.dayFormatter.string(from: from)))
            query.append(URLQueryItem(name: "to", value: Self.dayFormatter.string(from: to)))
        }
        return query
    }

    private func range(forPeriod period: String) -> String {
        switch period {
        case "1d": "1d"
        case "5d": "1w"
        case "1mo": "1m"
        case "3mo": "3m"
        case "6mo": "6m"
        case "1y": "1y"
        default: "all"
        }
    }

    private struct HTTPResult: Sendable {
        let data: Data
        let statusCode: Int
        let etag: String?
        let retryAfter: String?
    }

    private func request(
        baseURL: URL,
        token: String,
        path: [String],
        query: [URLQueryItem],
        etag: String?
    ) async throws -> HTTPResult {
        try providerPolicy.authorize(.folync, endpoint: baseURL)
        try FolyncEndpointPolicy.validate(baseURL)
        if await backoff.isBackingOff() {
            throw FolyncPortfolioSourceError.rateLimited(retryAfter: nil)
        }
        var url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        if !query.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw FolyncPortfolioSourceError.invalidResponse
            }
            components.queryItems = query
            guard let queryURL = components.url else { throw FolyncPortfolioSourceError.invalidResponse }
            url = queryURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FolyncPortfolioSourceError.invalidResponse }
        return HTTPResult(
            data: data,
            statusCode: http.statusCode,
            etag: http.value(forHTTPHeaderField: "ETag"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        )
    }

    private func validate(_ response: HTTPResult) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let error = FolyncPortfolioSourceError.forStatus(response.statusCode, retryAfter: response.retryAfter)
        await backoff.recordFailure(error)
        throw error
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FolyncPortfolioSourceError.invalidPayload("Supplemental response could not be decoded")
        }
    }

    private func validateSchema(_ version: Int) throws {
        guard version == 2 else { throw FolyncPortfolioSourceError.unsupportedSchema(version) }
    }

    private func isUsableMarketHistory(_ payload: FolyncMarketHistory, requireOHLC: Bool) -> Bool {
        payload.quality != .unavailable
            && !payload.bars.isEmpty
            && payload.bars.allSatisfy {
                guard FolyncSupplementalDateParser.instant($0.timestamp) != nil,
                      $0.close.isFinite,
                      $0.volume == nil || ($0.volume!.isFinite && $0.volume! >= 0 && $0.volume! < Double(Int64.max))
                else { return false }
                if requireOHLC {
                    guard let open = $0.open, let high = $0.high, let low = $0.low else { return false }
                    return open.isFinite && high.isFinite && low.isFinite && high >= low
                }
                return ($0.open == nil || $0.open!.isFinite)
                    && ($0.high == nil || $0.high!.isFinite)
                    && ($0.low == nil || $0.low!.isFinite)
            }
    }

    private func isUsablePortfolioHistory(_ payload: FolyncPortfolioHistory) -> Bool {
        payload.quality != .unavailable
            && isUsableSeries(payload.portfolioSeries)
            && isUsableSeries(payload.cashSeries)
            && isUsableSeries(payload.holdingsSeries)
            && isUsableSeries(payload.netContributionSeries)
            && isUsableSeries(payload.gainSeries)
            && isUsableSeries(payload.twrSeries)
    }

    private func isUsableSeries(_ series: [FolyncPortfolioHistory.SeriesPoint]) -> Bool {
        !series.isEmpty && series.allSatisfy {
            $0.value.isFinite && (
                FolyncSupplementalDateParser.instant($0.date) != nil
                    || FolyncSupplementalDateParser.day($0.date) != nil
            )
        }
    }

    private func isUsableBenchmark(_ benchmark: FolyncBenchmark) -> Bool {
        benchmark.quality != .unavailable
            && benchmark.current.last?.isFinite == true
    }

    private func isUsableBenchmarks(_ benchmarks: [FolyncBenchmark]) -> Bool {
        benchmarks.contains(where: isUsableBenchmark)
    }

    /// Rates dated further apart than a long weekend are not used as one set.
    static let maximumFXDaySpread: TimeInterval = 4 * 24 * 60 * 60

    private func usableFX(
        _ payload: FolyncFXResponse,
        requiredQuotes: Set<String>
    ) -> (rates: [String: Double], asOf: Date?)? {
        guard payload.base.uppercased() == "USD", payload.quality != .unavailable else { return nil }
        let usableRows = payload.rates.filter { row in
            row.quality != .unavailable
                && row.rate?.isFinite == true
                && (row.rate ?? 0) > 0
                && row.asOf != nil
        }
        let rates = Dictionary(firstValuesFor: usableRows.compactMap { row -> (String, Double)? in
            guard row.quality != .unavailable,
                  let rate = row.rate,
                  rate.isFinite,
                  rate > 0 else { return nil }
            return (row.quote.uppercased(), rate)
        })
        guard requiredQuotes.isSubset(of: Set(rates.keys)) else { return nil }
        // Currencies publish on different calendars, so one rate can be a day or
        // two behind the others around a holiday. The set is then as old as its
        // oldest rate; only a wider gap means the rates do not belong together.
        let asOfDays = Set(usableRows.compactMap(\.asOf)).map(Self.parseDay)
        guard !asOfDays.isEmpty, !asOfDays.contains(nil),
              let oldest = asOfDays.compactMap({ $0 }).min(),
              let newest = asOfDays.compactMap({ $0 }).max(),
              newest.timeIntervalSince(oldest) <= Self.maximumFXDaySpread else { return nil }
        return (["USD": 1].merging(rates) { _, new in new }, oldest)
    }

    private func sourceStatus(quality: FolyncFinancialQuality, stale: Bool) -> FolyncSupplementalSourceStatus {
        if stale { return .stale }
        switch quality {
        case .complete: return .current
        case .partial: return .partial
        case .unavailable: return .unavailable
        }
    }

    private func benchmarkStatus(_ benchmarks: [FolyncBenchmark]) -> FolyncSupplementalSourceStatus {
        guard isUsableBenchmarks(benchmarks) else { return .unavailable }
        if benchmarks.contains(where: { $0.stale }) { return .stale }
        if benchmarks.contains(where: { $0.quality == .partial || !isUsableBenchmark($0) }) { return .partial }
        return .current
    }

    private func seriesMetadata(_ response: FolyncMarketHistory) -> FolyncSeriesMetadata {
        FolyncSeriesMetadata(
            interval: response.interval,
            availableFrom: response.coverage.availableFrom,
            availableTo: response.coverage.availableTo,
            pointCount: response.coverage.pointCount,
            coverageComplete: response.coverage.complete,
            generatedAt: response.generatedAt,
            reasonCodes: response.reasonCodes
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let requiredFXQuotes = ["GBP", "EUR", "JPY", "CAD", "AUD"]

    private static func orderedFXQuotes(from requiredQuotes: Set<String>) -> [String] {
        let baseOrder = requiredFXQuotes.filter { requiredQuotes.contains($0) }
        let extraQuotes = requiredQuotes.subtracting(requiredFXQuotes).sorted()
        return baseOrder + extraQuotes
    }

    private static func parseDay(_ value: String) -> Date? {
        dayFormatter.date(from: value)
    }
}
