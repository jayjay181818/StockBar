import CryptoKit
import Foundation

enum FolyncSupplementalRoute: String, CaseIterable, Codable, Hashable, Sendable {
    case historicalLineCharts
    case candlestickCharts
    case benchmarkMarketData
    case exchangeRates
}

struct FolyncSupplementalSettings: Codable, Equatable, Sendable {
    var historicalLineCharts: Bool
    var candlestickCharts: Bool
    var benchmarkMarketData: Bool
    var exchangeRates: Bool
    var allowLegacyFallback: Bool

    static let disabled = FolyncSupplementalSettings(
        historicalLineCharts: false,
        candlestickCharts: false,
        benchmarkMarketData: false,
        exchangeRates: false,
        allowLegacyFallback: false
    )

    static func newConnectionDefaults(capabilities: FolyncCapabilities?) -> FolyncSupplementalSettings {
        guard let capabilities else { return .disabled }
        return FolyncSupplementalSettings(
            historicalLineCharts: capabilities.resources.lineHistory.isUsable,
            candlestickCharts: capabilities.resources.candlesticks.isUsable,
            benchmarkMarketData: capabilities.resources.benchmarks.isUsable,
            exchangeRates: capabilities.resources.exchangeRates.isUsable,
            allowLegacyFallback: false
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

    init(
        settingsStore: FolyncSettingsStore = .shared,
        credentialStore: FolyncCredentialStore = .shared,
        cache: FolyncSupplementalCache = .shared,
        session: URLSession = .shared,
        providerPolicy: StockbarProviderAccessPolicy = .current,
        backoff: FolyncBackoffCoordinator = FolyncBackoffCoordinator(),
        tokenProvider: (@Sendable () throws -> String)? = nil
    ) {
        self.settingsStore = settingsStore
        self.tokenProvider = tokenProvider ?? { try credentialStore.load() }
        self.cache = cache
        self.session = session
        self.providerPolicy = providerPolicy
        self.backoff = backoff
    }

    func fetchCapabilities(baseURL: URL, token: String) async throws -> FolyncCapabilities? {
        let endpoint = baseURL.absoluteString
        let resource = "capabilities"
        let cached: (payload: FolyncCapabilities, etag: String?, receiptTime: Date)? = try? await cache.load(
            endpoint: endpoint,
            scopeID: "-",
            resource: resource,
            identity: "-",
            range: "-",
            as: FolyncCapabilities.self
        )
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
            range: "-",
            etag: response.etag
        )
        return capabilities
    }

    func capabilitiesForCurrentSettings(refresh: Bool = false) async -> FolyncCapabilities? {
        guard let configuration = currentConfiguration() else { return nil }
        if !refresh, let capabilities = memoryCapabilities[configuration.endpoint] { return capabilities }
        do {
            return try await fetchCapabilities(baseURL: configuration.baseURL, token: configuration.token)
        } catch {
            let cached: (payload: FolyncCapabilities, etag: String?, receiptTime: Date)? = try? await cache.load(
                endpoint: configuration.endpoint,
                scopeID: "-",
                resource: "capabilities",
                identity: "-",
                range: "-",
                as: FolyncCapabilities.self
            )
            if let cached {
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
        guard let configuration = currentConfiguration() else { return .legacy }
        let identity = configuration.settings.scopeID
        let resource = "portfolio-history"
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
            if response.statusCode == 304, let cached, isUsablePortfolioHistory(cached.payload) {
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
            return .folync(payload, status: sourceStatus(quality: payload.quality, stale: false))
        } catch {
            if let cached, isUsablePortfolioHistory(cached.payload) {
                return .folync(cached.payload, status: .stale)
            }
            return configuration.settings.supplemental.allowLegacyFallback ? .legacy : .unavailable
        }
    }

    func routeBenchmarks() async -> FolyncRoutedBenchmarkResult {
        guard let configuration = currentConfiguration(),
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
        guard let configuration = currentConfiguration(),
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
        await backoff.clear()
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

    private func currentConfiguration() -> Configuration? {
        let settings = settingsStore.load()
        guard settings.isEnabled,
              let baseURL = URL(string: settings.baseURL),
              let token = try? tokenProvider() else { return nil }
        return Configuration(settings: settings, endpoint: settings.baseURL, baseURL: baseURL, token: token)
    }

    private func routingContext(route: FolyncSupplementalRoute, symbol: String) async -> RoutingContext? {
        guard let configuration = currentConfiguration(),
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
        try providerPolicy.authorize(.folync)
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
        let asOfValues = Set(usableRows.compactMap(\.asOf))
        guard asOfValues.count == 1,
              let asOfValue = asOfValues.first,
              let asOf = Self.parseDay(asOfValue) else { return nil }
        return (["USD": 1].merging(rates) { _, new in new }, asOf)
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
