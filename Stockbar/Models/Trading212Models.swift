import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum Trading212Environment: String, CaseIterable, Codable, Equatable {
    case demo
    case live

    var displayName: String {
        switch self {
        case .demo: return "Demo / Paper"
        case .live: return "Live / Real Money"
        }
    }

    var baseURL: URL {
        switch self {
        case .demo: return URL(string: "https://demo.trading212.com/api/v0")!
        case .live: return URL(string: "https://live.trading212.com/api/v0")!
        }
    }
}

enum Trading212AccountType: String, CaseIterable, Codable, Equatable {
    case stocksAndSharesISA
    case invest
    case cfdUnsupported
    case unknownCustom

    var displayName: String {
        switch self {
        case .stocksAndSharesISA: return "Stocks & Shares ISA"
        case .invest: return "Invest / General"
        case .cfdUnsupported: return "CFD (unsupported by API)"
        case .unknownCustom: return "Unknown / Custom"
        }
    }

    var taxWrapper: String {
        switch self {
        case .stocksAndSharesISA: return "ISA"
        case .invest, .cfdUnsupported: return "None"
        case .unknownCustom: return "Unknown"
        }
    }

    var isSupportedByPublicAPI: Bool {
        self != .cfdUnsupported
    }
}

struct Trading212AuthConfiguration: Equatable {
    let apiKey: String
    let apiSecret: String

    var normalized: Trading212AuthConfiguration {
        Trading212AuthConfiguration(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            apiSecret: apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var credentialFingerprint: String {
        Trading212Hashing.sha256Hex(normalized.apiKey)
    }
}

struct Trading212AuthHeader: Equatable {
    let name: String
    let value: String
}

enum Trading212AuthError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case missingAPISecret

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Trading 212 API key is required."
        case .missingAPISecret: return "Trading 212 API secret is required."
        }
    }
}

struct Trading212AuthHeaderBuilder {
    func authorizationHeader(for configuration: Trading212AuthConfiguration) throws -> Trading212AuthHeader {
        let normalized = configuration.normalized
        guard !normalized.apiKey.isEmpty else { throw Trading212AuthError.missingAPIKey }
        guard !normalized.apiSecret.isEmpty else { throw Trading212AuthError.missingAPISecret }

        let credentials = "\(normalized.apiKey):\(normalized.apiSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return Trading212AuthHeader(name: "Authorization", value: "Basic \(encoded)")
    }
}

enum Trading212PermissionArea: String, CaseIterable, Codable, Equatable {
    case accountData
    case metadata
    case historyDividends
    case historyTransactions
    case historyOrders
    case ordersExecute

    var displayName: String {
        switch self {
        case .accountData: return "Account data"
        case .metadata: return "Metadata"
        case .historyDividends: return "History - Dividends"
        case .historyTransactions: return "History - Transactions"
        case .historyOrders: return "History - Orders"
        case .ordersExecute: return "Orders - Execute"
        }
    }
}

enum Trading212PermissionRequirement: String, Codable, Equatable {
    case required
    case recommended
    case optionalFuture
    case neverRequired

    var displayName: String {
        switch self {
        case .required: return "Required"
        case .recommended: return "Recommended"
        case .optionalFuture: return "Optional future"
        case .neverRequired: return "Never required"
        }
    }
}

struct Trading212PermissionRow: Identifiable, Equatable {
    var id: Trading212PermissionArea { area }
    let area: Trading212PermissionArea
    let requirement: Trading212PermissionRequirement
    let stockBarUse: String
    let notes: String
}

enum Trading212PermissionPolicy {
    static let mvpRows: [Trading212PermissionRow] = [
        Trading212PermissionRow(
            area: .accountData,
            requirement: .required,
            stockBarUse: "Account summary, cash, total value, P/L, positions",
            notes: "Required for test connection and preview."
        ),
        Trading212PermissionRow(
            area: .metadata,
            requirement: .recommended,
            stockBarUse: "Reliable instrument mapping",
            notes: "Preview still works with lower confidence if account-position fields are usable."
        ),
        Trading212PermissionRow(
            area: .historyDividends,
            requirement: .optionalFuture,
            stockBarUse: "Dividend history",
            notes: "Not required for this preview release."
        ),
        Trading212PermissionRow(
            area: .historyTransactions,
            requirement: .optionalFuture,
            stockBarUse: "Transaction/import audit history",
            notes: "Not required for this preview release."
        ),
        Trading212PermissionRow(
            area: .historyOrders,
            requirement: .optionalFuture,
            stockBarUse: "Read-only order audit history",
            notes: "Not required for this preview release."
        ),
        Trading212PermissionRow(
            area: .ordersExecute,
            requirement: .neverRequired,
            stockBarUse: "None",
            notes: "StockBar must not request trading permission."
        )
    ]
}

enum Trading212SyncPolicy {
    static let minimumIntervalSeconds = 30
    static let defaultIntervalSeconds = 30
    static let intervalOptionsSeconds = [30, 60, 300, 900, 1_800]

    static func clampedIntervalSeconds(_ seconds: Int) -> Int {
        max(minimumIntervalSeconds, seconds)
    }

    static func displayName(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) sec"
        }
        let minutes = seconds / 60
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

struct Trading212StoredSettings: Equatable {
    var isEnabled: Bool
    var environment: Trading212Environment
    var accountType: Trading212AccountType
    var accountLabel: String
    var autoSyncEnabled: Bool
    var syncIntervalSeconds: Int
    var deleteMissingLinkedHoldings: Bool

    static let defaults = Trading212StoredSettings(
        isEnabled: false,
        environment: .demo,
        accountType: .stocksAndSharesISA,
        accountLabel: "Trading 212 ISA",
        autoSyncEnabled: true,
        syncIntervalSeconds: Trading212SyncPolicy.defaultIntervalSeconds,
        deleteMissingLinkedHoldings: false
    )
}

struct Trading212AccountSummary: Codable, Equatable {
    let cash: Trading212Cash?
    let currency: String?
    let id: Int64?
    let investments: Trading212Investments?
    let totalValue: Double?
}

struct Trading212Cash: Codable, Equatable {
    let availableToTrade: Double?
    let inPies: Double?
    let reservedForOrders: Double?
}

struct Trading212Investments: Codable, Equatable {
    let currentValue: Double?
    let realizedProfitLoss: Double?
    let totalCost: Double?
    let unrealizedProfitLoss: Double?
}

struct Trading212Position: Codable, Equatable {
    let averagePricePaid: Double?
    let currentPrice: Double?
    let instrument: Trading212Instrument
    let quantity: Double?
    let quantityAvailableForTrading: Double?
    let quantityInPies: Double?
    let walletImpact: Trading212PositionWalletImpact?
}

struct Trading212Instrument: Codable, Equatable {
    let currency: String?
    let isin: String?
    let name: String?
    let ticker: String
}

struct Trading212PositionWalletImpact: Codable, Equatable {
    let currency: String?
    let currentValue: Double?
    let fxImpact: Double?
    let totalCost: Double?
    let unrealizedProfitLoss: Double?
}

struct Trading212InstrumentMetadata: Codable, Equatable {
    let currencyCode: String?
    let isin: String?
    let name: String?
    let shortName: String?
    let ticker: String
    let type: String?
    let workingScheduleId: Int64?
}

struct Trading212ExchangeMetadata: Codable, Equatable {
    let id: Int64?
    let name: String?
}

struct InstrumentIdentity: Equatable {
    let instrumentId: String
    let displaySymbol: String
    let displayName: String?
    let exchange: String?
    let currency: String?
    let isin: String?
    let providerSymbols: [String: String]
    let legacySymbols: [String]
}

enum InstrumentResolutionConfidence: Equatable {
    case high
    case medium
    case low
    case unresolved
}

struct InstrumentResolutionResult: Equatable {
    let identity: InstrumentIdentity?
    let confidence: InstrumentResolutionConfidence
    let warnings: [String]
}

struct BrokerAccountIdentity: Equatable {
    let broker: String
    let brokerAccountKey: String
    let apiAccountIdHash: String?
    let accountLabel: String
    let accountType: Trading212AccountType
    let taxWrapper: String
    let environment: Trading212Environment
    let credentialFingerprint: String

    static func preview(
        broker: String,
        environment: Trading212Environment,
        accountType: Trading212AccountType,
        accountLabel: String,
        credentialFingerprint: String,
        apiAccountId: Int64?
    ) -> BrokerAccountIdentity {
        let normalizedLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = normalizedLabel.isEmpty ? accountType.displayName : normalizedLabel
        let accountHash = apiAccountId.map { Trading212Hashing.sha256Hex(String($0)) }
        let keyParts = [
            broker,
            environment.rawValue,
            accountType.rawValue,
            Trading212Hashing.sha256Hex(label),
            credentialFingerprint,
            accountHash ?? "no-account-id"
        ]
        return BrokerAccountIdentity(
            broker: broker,
            brokerAccountKey: keyParts.joined(separator: "|"),
            apiAccountIdHash: accountHash,
            accountLabel: label,
            accountType: accountType,
            taxWrapper: accountType.taxWrapper,
            environment: environment,
            credentialFingerprint: credentialFingerprint
        )
    }
}

enum Trading212PreviewValueSource: Equatable {
    case brokerProvidedLivePositionData
    case unavailable
}

enum Trading212PreviewConflictStatus: Equatable {
    case none
    case manualHoldingMatch
    case manualQuantityMismatch
    case manualWatchlistMatch
    case duplicateManualMatches
    case unresolvedInstrument
}

struct Trading212ManualHoldingSnapshot: Equatable {
    let symbol: String
    let displayName: String?
    let quantity: Double
    let averageCost: Double?
    let currency: String?
    let isWatchlistOnly: Bool
}

struct Trading212ManualHoldingMatch: Equatable {
    let symbol: String
    let instrumentId: String
    let displayName: String?
    let quantity: Double
    let averageCost: Double?
    let currency: String?
    let isWatchlistOnly: Bool
    let resolutionConfidence: InstrumentResolutionConfidence
}

struct Trading212ImportPreviewRow: Identifiable, Equatable {
    let id: String
    let account: BrokerAccountIdentity
    let providerTicker: String
    let instrumentId: String?
    let displaySymbol: String
    let displayName: String?
    let quantity: Double?
    let averagePrice: Double?
    let brokerProvidedPrice: Double?
    let currentValue: Double?
    let unrealizedProfitLoss: Double?
    let fxImpact: Double?
    let mappingConfidence: InstrumentResolutionConfidence
    let manualMatch: Trading212ManualHoldingMatch?
    let additionalManualMatchCount: Int
    let conflictStatus: Trading212PreviewConflictStatus
    let valueSource: Trading212PreviewValueSource
    let warnings: [String]

    var quantityDelta: Double? {
        guard let quantity, let manualQuantity = manualMatch?.quantity else {
            return nil
        }
        return quantity - manualQuantity
    }

    var hasManualQuantityMismatch: Bool {
        guard let quantityDelta else {
            return false
        }
        return abs(quantityDelta) > 0.01
    }
}

struct Trading212ImportPreview: Equatable {
    let account: BrokerAccountIdentity
    let accountSummary: Trading212AccountSummary?
    let rows: [Trading212ImportPreviewRow]
    let metadataAvailable: Bool
    let generatedAt: Date
    let warnings: [String]

    var manualMatchCount: Int {
        rows.filter { $0.manualMatch != nil }.count
    }

    var brokerOnlyCount: Int {
        rows.filter { $0.conflictStatus == .none }.count
    }

    var quantityMismatchCount: Int {
        rows.filter(\.hasManualQuantityMismatch).count
    }

    var needsReviewCount: Int {
        rows.filter { row in
            switch row.conflictStatus {
            case .manualQuantityMismatch, .manualWatchlistMatch, .duplicateManualMatches, .unresolvedInstrument:
                return true
            case .none, .manualHoldingMatch:
                return false
            }
        }.count
    }
}

struct Trading212PreviewSnapshot: Equatable {
    let account: BrokerAccountIdentity
    let accountSummary: Trading212AccountSummary?
    let positions: [Trading212Position]
    let instruments: [Trading212InstrumentMetadata]
    let metadataAvailable: Bool

    init(
        account: BrokerAccountIdentity,
        accountSummary: Trading212AccountSummary?,
        positions: [Trading212Position],
        instruments: [Trading212InstrumentMetadata] = [],
        metadataAvailable: Bool
    ) {
        self.account = account
        self.accountSummary = accountSummary
        self.positions = positions
        self.instruments = instruments
        self.metadataAvailable = metadataAvailable
    }
}

enum Trading212Hashing {
    static func sha256Hex(_ value: String) -> String {
        let data = Data(value.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return data.base64EncodedString()
        #endif
    }
}
