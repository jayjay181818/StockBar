import Foundation

enum SettingsTransferExportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case settingsAndKeys
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settingsAndKeys: "Settings & Keys"
        case .everything: "Everything"
        }
    }
}

/// Stored kind of an exported defaults value. Numbers keep their UserDefaults
/// kind so a Bool never comes back as an Int.
enum SettingsTransferValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case stringArray([String])
    case stringDictionary([String: String])

    init?(defaultsValue value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let number as NSNumber where CFNumberIsFloatType(number):
            self = .double(number.doubleValue)
        case let number as NSNumber:
            self = .integer(number.intValue)
        case let string as String:
            self = .string(string)
        case let data as Data:
            self = .data(data)
        case let array as [String]:
            self = .stringArray(array)
        case let dictionary as [String: String]:
            self = .stringDictionary(dictionary)
        default:
            return nil
        }
    }

    var defaultsValue: Any {
        switch self {
        case .bool(let value): value
        case .integer(let value): value
        case .double(let value): value
        case .string(let value): value
        case .data(let value): value
        case .stringArray(let value): value
        case .stringDictionary(let value): value
        }
    }

    var kind: SettingsTransferValueKind {
        switch self {
        case .bool: .bool
        case .integer, .double: .number
        case .string: .string
        case .data: .data
        case .stringArray: .stringArray
        case .stringDictionary: .stringDictionary
        }
    }
}

enum SettingsTransferValueKind: Sendable {
    case bool
    case number
    case string
    case data
    case stringArray
    case stringDictionary

    func accepts(_ value: SettingsTransferValue) -> Bool {
        let actual = value.kind
        // UserDefaults reports an integer-valued Double as either kind.
        return actual == self || (self == .number && actual == .bool) || (self == .bool && actual == .number)
    }
}

/// Explicit allowlists of the UserDefaults keys an export may carry. Nothing
/// outside these lists is read for export or written on import.
///
/// Included settings (`settingsKeys`): user preferences and configuration.
///
/// Excluded on purpose, and never exported or overwritten:
/// - machine-specific or Stockbar's own Python environment: `pythonInterpreterPath`,
///   `pythonDependencyCheck.interpreterPath`, `pythonDependencyCheck.requirements`;
/// - window and selection state: `mainWindow.selectedSection`, `settings.selectedTab`,
///   `menuChartTimeRange.<SYMBOL>`;
/// - caches and runtime state: `cacheCoordinator.state.v1`, `cacheStatistics`,
///   `currencyRateHistory`, `historicalBackfillAttemptState.v1`, `lastBackfillDate`,
///   `lastBackfillTimestamp`, `lastBackupDate`, `portfolioSnapshots`, `priceSnapshots`,
///   `historicalPortfolioSnapshots`, `currentPortfolioComposition`,
///   `lastRetroactiveCalculationDate`, `cachedHistoricalPortfolioValues`,
///   `lastPortfolioCalculationDate`, `earliestAvailableDates`;
/// - one-off migration markers that describe this Mac, not the data:
///   `trading212.syncIntervalDefaultMigration.v1`, `legacyLocationReportV2`,
///   and legacy keys `trading212.syncIntervalMinutes`, `folync.portfolio-source.settings.v1`;
/// - legacy portfolio copies superseded by Core Data: `usertrades`, `tradingInfoData`,
///   `userData`, `priceAlerts`;
/// - paths: `instrumentAliasIdentity.v1.recoveryManifest`.
///
/// Database state (`databaseStateKeys`) travels only with an Everything export,
/// because these markers describe the contents of the Core Data store they were
/// written for. Importing a store without them would re-run data migrations on
/// already-migrated data (for example the pre-v3 snapshot deletion or the pence
/// rescale).
enum SettingsTransferKeys {
    static let settingsKeys: [String: SettingsTransferValueKind] = [
        // General
        "preferredCurrency": .string,
        "showColorCoding": .bool,
        "showMarketIndicators": .bool,
        // Menu bar
        "hideAllMenuBarItems": .bool,
        MenuBarDisplaySettings.UserDefaultsKey.displayMode: .string,
        MenuBarDisplaySettings.UserDefaultsKey.changeFormat: .string,
        MenuBarDisplaySettings.UserDefaultsKey.customTemplate: .string,
        MenuBarDisplaySettings.UserDefaultsKey.showCurrency: .bool,
        MenuBarDisplaySettings.UserDefaultsKey.decimalPlaces: .number,
        MenuBarDisplaySettings.UserDefaultsKey.arrowStyle: .string,
        MenuBarDisplaySettings.UserDefaultsKey.showArrowBeforeSymbol: .bool,
        MenuBarVisibilityPolicy.requireExternalDisplayKey: .bool,
        PortfolioMenuBarDisplaySettings.UserDefaultsKey.isEnabled: .bool,
        PortfolioMenuBarDisplaySettings.UserDefaultsKey.currencyCode: .string,
        PortfolioMenuBarDisplaySettings.UserDefaultsKey.dayGainFormat: .string,
        PortfolioMenuBarDisplaySettings.UserDefaultsKey.decimalPlaces: .number,
        "menu.benchmarkComparisonEnabled": .bool,
        // Appearance and charts
        "appearanceMode": .string,
        "candlestickChartSettings": .data,
        // Refresh and history
        "refreshInterval": .number,
        "portfolioSnapshotIntervalSeconds": .number,
        "backfillCooldownHours": .number,
        "backfillSchedule": .string,
        "backfillNotifications": .bool,
        // Backups and diagnostics (none of these are paths)
        "backupRetentionDays": .number,
        "debugLogAutoRefresh": .bool,
        "debugLogMaxLines": .number,
        "debugLogTailMode": .bool,
        "stockbar.debugLoggingEnabled": .bool,
        // Trading 212 configuration (credentials travel separately)
        "trading212.enabled": .bool,
        "trading212.environment": .string,
        "trading212.accountType": .string,
        "trading212.accountLabel": .string,
        "trading212.autoSyncEnabled": .bool,
        "trading212.syncIntervalSeconds": .number,
        "trading212.deleteMissingLinkedHoldings": .bool,
        "trading212.autoReconcileHoldingsEnabled": .bool,
        "trading212.autoImportBrokerOnlyHoldings": .bool,
        "trading212.holdingReconciliationIntervalSeconds": .number,
        // Folync configuration (the client token travels separately)
        "folync.portfolio-source.settings.v2": .data,
        "folync.holding-overlays.v1": .data
    ]

    static let databaseStateKeys: [String: SettingsTransferValueKind] = [
        "coreDataMigrationVersion": .number,
        "priceSnapshotsMigratedToCoreData": .bool,
        "portfolioSnapshotsMigratedToCoreData": .bool,
        "tradesMigratedToCoreData": .bool,
        "tradingInfoMigratedToCoreData": .bool,
        "needsRetroactiveCalculationAfterMigration": .bool,
        "preV3PortfolioSnapshotsDeleted": .bool,
        "TradeDataMigrationCompleted": .bool,
        "ohlc.pence-rescale.version": .number,
        "priceSnapshots.uk-scale-repair.version": .number,
        AliasIdentityMigrationService.completionKey: .bool,
        AliasIdentityMigrationService.quarantineKey: .stringArray,
        InstrumentAliasStore.aliasesKey: .stringDictionary,
        InstrumentAliasStore.isinKey: .stringDictionary,
        DataModel.coreDataPortfolioEstablishedKey: .bool,
        "stockDisplayOrder": .stringArray
    ]

    /// `DATA_SOURCE_PRIORITY` lives in ConfigurationManager's file, not defaults.
    static let allowedDataSources: Set<String> = ["yfinance", "fmp", "twelvedata"]
}

struct SettingsTransferManifest: Codable, Equatable, Sendable {
    let exportType: SettingsTransferExportType
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let settingsCount: Int
    let credentialCount: Int
    let databaseBytes: Int64?
}

struct SettingsTransferTrading212Credential: Codable, Equatable, Sendable {
    let apiKey: String
    let apiSecret: String
}

struct SettingsTransferCredentials: Codable, Equatable, Sendable {
    var fmpAPIKey: String?
    var twelveDataAPIKey: String?
    /// Keyed by `Trading212Environment.rawValue`; every stored environment.
    var trading212: [String: SettingsTransferTrading212Credential] = [:]
    var folyncClientToken: String?

    /// Display names only, never values.
    var names: [String] {
        var names: [String] = []
        if fmpAPIKey != nil { names.append("Financial Modeling Prep API key") }
        if twelveDataAPIKey != nil { names.append("Twelve Data API key") }
        for environment in Trading212Environment.allCases where trading212[environment.rawValue] != nil {
            names.append("Trading 212 API key and secret (\(environment.displayName))")
        }
        if folyncClientToken != nil { names.append("Folync client token") }
        return names
    }
}

struct SettingsTransferDatabase: Codable, Equatable, Sendable {
    /// Store files keyed by suffix: "" for the SQLite file, "-wal", "-shm".
    let storeFiles: [String: Data]
    /// `BrokerLinks/broker_links.json`, which ties local holdings to Trading 212 positions.
    let brokerLinks: Data?
    let state: [String: SettingsTransferValue]

    var byteCount: Int64 {
        Int64(storeFiles.values.reduce(0) { $0 + $1.count } + (brokerLinks?.count ?? 0))
    }
}

struct SettingsTransferPayload: Codable, Equatable, Sendable {
    let manifest: SettingsTransferManifest
    let settings: [String: SettingsTransferValue]
    let dataSourcePriority: [String]?
    let credentials: SettingsTransferCredentials
    let database: SettingsTransferDatabase?

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SettingsTransferPayload {
        do {
            return try PropertyListDecoder().decode(SettingsTransferPayload.self, from: data)
        } catch {
            throw SettingsTransferError.damagedFile
        }
    }
}

/// What an export contains, shown before anything is applied.
struct SettingsTransferPreview: Equatable, Sendable {
    let manifest: SettingsTransferManifest
    let settingsCount: Int
    let ignoredSettingsCount: Int
    let includesDataSourcePriority: Bool
    let credentialNames: [String]
    let database: DatabaseSummary?

    struct DatabaseSummary: Equatable, Sendable {
        let byteCount: Int64
        let tradeCount: Int
        let portfolioSnapshotCount: Int
        let priceSnapshotCount: Int
        let includesBrokerLinks: Bool
    }
}
