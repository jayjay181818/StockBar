import Foundation

enum FolyncPortfolioSourceError: Error, LocalizedError, Equatable {
    case insecureTransport
    case unsupportedSchema(Int)
    case invalidPayload(String)
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(Int)

    /// Maps a non-success Folync status. Folync answers 429 with `Retry-After`
    /// (whole seconds) after repeated failed token attempts from one address.
    static func forStatus(_ status: Int, retryAfter: String?) -> FolyncPortfolioSourceError {
        switch status {
        case 401:
            return .unauthorized
        case 429:
            let seconds = retryAfter
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { TimeInterval(min(max($0, 1), 3600)) }
            return .rateLimited(retryAfter: seconds)
        default:
            return .unavailable(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .insecureTransport:
            return "Folync requires HTTPS except for localhost development."
        case .unsupportedSchema(let version):
            return "Folync client API schema version \(version) is not supported."
        case .invalidPayload:
            return "Folync returned invalid financial data."
        case .invalidResponse:
            return "Folync returned an invalid response."
        case .unauthorized:
            return "Folync rejected the client access token."
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { " Retrying after \(Int($0)) seconds." } ?? ""
            return "Folync is refusing requests after too many failed token attempts.\(wait)"
        case .unavailable(let status):
            return "Folync request failed with HTTP \(status)."
        }
    }
}

enum FolyncEndpointPolicy {
    static func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw FolyncPortfolioSourceError.invalidPayload("Endpoint URL is incomplete")
        }
        if scheme == "https" { return }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" { return }
        throw FolyncPortfolioSourceError.insecureTransport
    }
}

enum FolyncPortfolioKind: String, Codable, Equatable {
    case portfolio
    case aggregate
}

struct FolyncPortfolio: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let kind: FolyncPortfolioKind
    let currency: String?
}

struct FolyncPortfoliosResponse: Codable, Equatable {
    let schemaVersion: Int
    let portfolios: [FolyncPortfolio]
}

enum FolyncFinancialQuality: String, Codable, Equatable {
    case complete
    case partial
    case unavailable
}

struct FolyncFinancialMetric: Codable, Equatable {
    let value: Double?
    let currency: String?
    let quality: FolyncFinancialQuality
    let reasonCodes: [String]
    let asOfDate: String?
}

struct FolyncFreshness: Codable, Equatable {
    let responseGeneratedAt: String
    let asOf: String?
    let status: String
    let reasonCodes: [String]
    let sources: Sources

    struct Sources: Codable, Equatable {
        let snapshots: Snapshots
        let prices: TimedSource
        let fx: TimedSource
        let provider: ProviderSource
    }

    struct Snapshots: Codable, Equatable {
        let asOfDate: String?
        let status: String
        let generation: Int?
        let dirtySince: String?
        let rebuildStartedAt: String?
        let failedAt: String?
        let completedAt: String?
    }

    struct TimedSource: Codable, Equatable {
        let asOfDate: String?
        let ageSeconds: Double?
        let missingCount: Int
    }

    struct ProviderSource: Codable, Equatable {
        let lastSuccessfulSyncAt: String?
        let ageSeconds: Double?
    }
}

struct FolyncHolding: Codable, Equatable {
    static let minimumDisplayedUnits = 0.0001

    let portfolioId: String
    let portfolioName: String?
    let assetId: String
    let ticker: String
    let canonicalTicker: String?
    let displayTicker: String?
    let quoteSymbol: String?
    let aliases: [String]?
    let isin: String?
    let name: String
    let currency: String
    let shares: Double
    let averageCostCurrency: String?
    let averageCostSource: String?
    let valueCurrency: String?
    let averageCost: Double
    let currentPrice: Double?
    let previousClose: Double?
    let marketValue: Double?
    let costValue: Double
    let dayGain: Double?
    let dayGainPct: Double?
    let totalGain: Double?
    let totalGainPct: Double?
    let allocationPct: Double?
    let valuation: FolyncFinancialMetric

    var resolvedCanonicalTicker: String {
        normalized(canonicalTicker) ?? normalized(ticker) ?? ticker
    }

    var resolvedDisplayTicker: String {
        normalized(displayTicker) ?? normalized(quoteSymbol) ?? normalized(ticker) ?? ticker
    }

    var resolvedAliases: [String] {
        var seen = Set<String>()
        return ([resolvedCanonicalTicker, resolvedDisplayTicker] + (aliases ?? []))
            .compactMap(normalized)
            .filter { seen.insert($0).inserted }
    }

    var holdingIdentity: String {
        "\(portfolioId)|\(assetId)"
    }

    var shouldDisplayInStockbar: Bool {
        shares >= Self.minimumDisplayedUnits
    }

    var resolvedAverageCostCurrency: String {
        normalized(averageCostCurrency) ?? normalized(currency) ?? currency
    }

    var resolvedValueCurrency: String {
        normalized(valueCurrency) ?? normalized(valuation.currency) ?? normalized(currency) ?? currency
    }

    var resolvedPortfolioDisplayName: String {
        let name = (portfolioName ?? portfolioId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.caseInsensitiveCompare("Trading 212 Live Full History") == .orderedSame {
            return "T212 Folync"
        }
        return name
    }

    private func normalized(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

struct FolyncPortfolioSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let sourceRevision: String
    let generatedAt: String
    let scope: FolyncPortfolio
    let freshness: FolyncFreshness
    let totalValue: FolyncFinancialMetric
    let cash: FolyncFinancialMetric
    let profitLoss: ProfitLoss
    let holdings: [FolyncHolding]

    struct ProfitLoss: Codable, Equatable {
        let unrealized: FolyncFinancialMetric
        let realized: FolyncFinancialMetric
        let day: FolyncFinancialMetric
    }

    var displayHoldings: [FolyncHolding] {
        holdings.filter(\.shouldDisplayInStockbar)
    }

    func makeDisplayTrades(overlays: [String: FolyncHoldingOverlay]) -> [RealTimeTrade] {
        displayHoldings.map { holding in
            let overlay = overlays[holding.overlayKey(scopeID: scope.id)] ?? FolyncHoldingOverlay()
            let trade = Trade(
                name: holding.resolvedDisplayTicker,
                position: Position(
                    unitSize: String(holding.shares),
                    positionAvgCost: String(holding.averageCost),
                    currency: holding.currency,
                    costCurrency: holding.resolvedAverageCostCurrency
                ),
                isWatchlistOnly: false,
                showInMenuBar: overlay.showInMenuBar
            )
            var info = TradingInfo()
            info.currentPrice = holding.currentPrice ?? .nan
            info.previousClose = holding.previousClose
            info.prevClosePrice = holding.previousClose ?? .nan
            info.currency = holding.currency
            info.shortName = scope.kind == .aggregate
                ? "\(holding.name) · \(holding.resolvedPortfolioDisplayName)"
                : holding.name
            info.lastUpdateTime = FolyncSupplementalDateParser.instant(generatedAt).map { Int($0.timeIntervalSince1970) }
            info.errorMessage = holding.valuation.quality == .unavailable
                ? "Folync valuation unavailable: \(holding.valuation.reasonCodes.joined(separator: ", "))"
                : nil
            return RealTimeTrade(
                trade: trade,
                realTimeInfo: info,
                sourceIdentity: holding.overlayKey(scopeID: scope.id),
                displayLabel: scope.kind == .aggregate
                    ? "\(holding.resolvedDisplayTicker) · \(holding.resolvedPortfolioDisplayName)"
                    : holding.resolvedDisplayTicker
            )
        }
    }

    var preferredAliasMap: [String: String] {
        guard schemaVersion == 2 else { return [:] }
        return holdings.reduce(into: [String: String]()) { mapping, holding in
            for alias in holding.resolvedAliases where alias != holding.resolvedDisplayTicker {
                mapping[alias] = holding.resolvedDisplayTicker
            }
        }
    }
}

struct FolyncHoldingOverlay: Codable, Equatable {
    var showInMenuBar: Bool = true
}

extension FolyncHolding {
    func overlayKey(scopeID: String) -> String {
        "\(scopeID)|\(portfolioId)|\(assetId)"
    }
}

struct FolyncPortfolioDecoder {
    private let decoder = JSONDecoder()

    func decodePortfolios(_ data: Data) throws -> FolyncPortfoliosResponse {
        let response = try decoder.decode(FolyncPortfoliosResponse.self, from: data)
        try validateSchema(response.schemaVersion)
        guard !response.portfolios.isEmpty,
              response.portfolios.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else {
            throw FolyncPortfolioSourceError.invalidPayload("Portfolio identity is missing")
        }
        return response
    }

    func decodeSnapshot(_ data: Data) throws -> FolyncPortfolioSnapshot {
        let snapshot = try decoder.decode(FolyncPortfolioSnapshot.self, from: data)
        try validateSchema(snapshot.schemaVersion)
        try validate(snapshot)
        return snapshot
    }

    private func validateSchema(_ version: Int) throws {
        guard version == 1 || version == 2 else { throw FolyncPortfolioSourceError.unsupportedSchema(version) }
    }

    private func validate(_ snapshot: FolyncPortfolioSnapshot) throws {
        guard !snapshot.sourceRevision.isEmpty,
              !snapshot.scope.id.isEmpty,
              snapshot.holdings.allSatisfy({ holding in
                  !holding.portfolioId.isEmpty && !holding.assetId.isEmpty && !holding.ticker.isEmpty
                      && validIdentity(holding, schemaVersion: snapshot.schemaVersion)
                      && holding.shares.isFinite && holding.shares >= 0
                      && holding.averageCost.isFinite && holding.averageCost >= 0
                      && finite(holding.currentPrice) && finite(holding.previousClose)
                      && finite(holding.marketValue) && holding.costValue.isFinite
                      && finite(holding.dayGain) && finite(holding.dayGainPct)
                      && finite(holding.totalGain) && finite(holding.totalGainPct)
                      && finite(holding.allocationPct) && finite(holding.valuation.value)
              }),
              finite(snapshot.totalValue.value), finite(snapshot.cash.value),
              finite(snapshot.profitLoss.unrealized.value), finite(snapshot.profitLoss.realized.value),
              finite(snapshot.profitLoss.day.value) else {
            throw FolyncPortfolioSourceError.invalidPayload("Financial values must be finite")
        }
    }

    private func finite(_ value: Double?) -> Bool {
        value == nil || value!.isFinite
    }

    private func validIdentity(_ holding: FolyncHolding, schemaVersion: Int) -> Bool {
        guard schemaVersion == 2 else { return true }
        guard let portfolioName = holding.portfolioName, !portfolioName.isEmpty,
              let canonicalTicker = holding.canonicalTicker, !canonicalTicker.isEmpty,
              let displayTicker = holding.displayTicker, !displayTicker.isEmpty,
              let aliases = holding.aliases, !aliases.isEmpty else { return false }
        let normalizedAliases = Set(aliases.map { $0.uppercased() })
        return normalizedAliases.contains(canonicalTicker.uppercased())
            && normalizedAliases.contains(displayTicker.uppercased())
    }
}

enum FolyncSnapshotFetchResult: Equatable {
    case changed(snapshot: FolyncPortfolioSnapshot, etag: String?)
    case unchanged
}

protocol PortfolioSource: Sendable {
    func listPortfolios() async throws -> [FolyncPortfolio]
    func fetchSnapshot(scopeID: String, etag: String?) async throws -> FolyncSnapshotFetchResult
}

actor FolyncPortfolioSource: PortfolioSource {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let providerPolicy: StockbarProviderAccessPolicy
    private let decoder = FolyncPortfolioDecoder()
    private var apiVersion = 2

    init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        providerPolicy: StockbarProviderAccessPolicy = .current
    ) throws {
        try FolyncEndpointPolicy.validate(baseURL)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FolyncPortfolioSourceError.invalidPayload("Client token is required")
        }
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.providerPolicy = providerPolicy
    }

    func listPortfolios() async throws -> [FolyncPortfolio] {
        var (data, response) = try await request(path: ["api", "client", "v2", "portfolios"])
        if response.statusCode == 404 {
            (data, response) = try await request(path: ["api", "client", "v1", "portfolios"])
            apiVersion = 1
        } else {
            apiVersion = 2
        }
        try validate(response)
        return try decoder.decodePortfolios(data).portfolios
    }

    func fetchSnapshot(scopeID: String, etag: String?) async throws -> FolyncSnapshotFetchResult {
        // The scope is a single raw path component. `request` percent-encodes
        // it, so it must not be pre-encoded and must not smuggle in separators.
        try Self.validateScopeComponent(scopeID)
        var (data, response) = try await request(
            path: ["api", "client", "v\(apiVersion)", "scopes", scopeID, "snapshot"],
            etag: etag
        )
        if response.statusCode == 404, apiVersion == 2 {
            (data, response) = try await request(
                path: ["api", "client", "v1", "scopes", scopeID, "snapshot"],
                etag: etag
            )
            if response.statusCode != 404 { apiVersion = 1 }
        }
        if response.statusCode == 304 { return .unchanged }
        try validate(response)
        let snapshot = try decoder.decodeSnapshot(data)
        guard snapshot.scope.id == scopeID else {
            throw FolyncPortfolioSourceError.invalidPayload("Snapshot scope does not match request")
        }
        return .changed(snapshot: snapshot, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    func fetchCapabilities() async throws -> FolyncCapabilities? {
        guard apiVersion == 2 else { return nil }
        let (data, response) = try await request(path: ["api", "client", "v2", "capabilities"])
        if response.statusCode == 404 { return nil }
        try validate(response)
        do {
            let capabilities = try JSONDecoder().decode(FolyncCapabilities.self, from: data)
            guard capabilities.schemaVersion == 2 else {
                throw FolyncPortfolioSourceError.unsupportedSchema(capabilities.schemaVersion)
            }
            return capabilities
        } catch let error as FolyncPortfolioSourceError {
            throw error
        } catch {
            throw FolyncPortfolioSourceError.invalidPayload("Capabilities response could not be decoded")
        }
    }

    /// Rejects scope identifiers that would escape their path segment.
    static func validateScopeComponent(_ scopeID: String) throws {
        guard !scopeID.isEmpty,
              scopeID != ".",
              scopeID != "..",
              !scopeID.contains("/"),
              !scopeID.contains("\\") else {
            throw FolyncPortfolioSourceError.invalidPayload("Scope identifier is not a valid path component")
        }
    }

    private func request(path: [String], etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try providerPolicy.authorize(.folync)
        // `appendingPathComponent` percent-encodes each component, so callers
        // pass raw components — pre-encoding here would double-encode.
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FolyncPortfolioSourceError.invalidResponse }
        return (data, http)
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        throw FolyncPortfolioSourceError.forStatus(
            response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )
    }
}
