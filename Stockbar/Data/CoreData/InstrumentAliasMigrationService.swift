@preconcurrency import CoreData
import Foundation

struct AliasMigrationAlert: Codable, Equatable, Sendable {
    let id: UUID
    let symbol: String?
    let alertType: String
    let condition: String
    let threshold: Double
    let isEnabled: Bool
    let createdAt: Date
    let lastTriggered: Date?
}

struct AliasIdentityRepairResult {
    let repairedTrades: [Trade]
    let tradingInfoBySymbol: [String: TradingInfo]
    let repairedLinks: BrokerLinkStoreSnapshot
    let displayOrder: [String]
    let alerts: [AliasMigrationAlert]
    let aliases: [String: String]
    let quarantinedProviderKeys: Set<String>

    var didChange: Bool { !aliases.isEmpty }
}

struct InstrumentAliasRepairPlanner {
    func plan(
        trades: [Trade],
        tradingInfoBySymbol: [String: TradingInfo],
        links: BrokerLinkStoreSnapshot,
        displayOrder: [String],
        alerts: [AliasMigrationAlert],
        preferredAliases: [String: String] = [:]
    ) -> AliasIdentityRepairResult {
        let tradesBySymbol = Dictionary(firstValuesFor: trades.map { ($0.name.uppercased(), $0) })
        let duplicateGroups = Dictionary(grouping: links.positions, by: \.id).values.filter { $0.count > 1 }
        var aliases: [String: String] = [:]
        var quarantined = Set<String>()

        for group in duplicateGroups {
            let ordered = group.sorted { $0.linkedAt < $1.linkedAt }
            guard let survivor = ordered.first else { continue }
            let symbols = ordered.map { $0.manualSymbol.uppercased() }
            let linkedTrades = symbols.compactMap { tradesBySymbol[$0] }
            guard linkedTrades.count == Set(symbols).count,
                  economicallyEquivalent(linkedTrades) else {
                quarantined.insert(survivor.id)
                continue
            }
            let survivorSymbol = symbols
                .compactMap { preferredAliases[$0]?.uppercased() }
                .first(where: { symbols.contains($0) })
                ?? survivor.manualSymbol.uppercased()
            for symbol in symbols where symbol != survivorSymbol {
                aliases[symbol] = survivorSymbol
            }
        }

        guard !aliases.isEmpty else {
            return AliasIdentityRepairResult(
                repairedTrades: trades,
                tradingInfoBySymbol: tradingInfoBySymbol,
                repairedLinks: links,
                displayOrder: displayOrder,
                alerts: alerts,
                aliases: [:],
                quarantinedProviderKeys: quarantined
            )
        }

        let repairedTrades = trades.filter { aliases[$0.name.uppercased()] == nil }
        let repairedInfo = remapTradingInfo(tradingInfoBySymbol, aliases: aliases)
        let repairedOrder = deduplicated(displayOrder.map { aliases[$0.uppercased()] ?? $0.uppercased() })
        let repairedAlerts = remapAlerts(alerts, aliases: aliases)
        let repairedLinks = normalizedLinks(links, aliases: aliases, quarantined: quarantined)

        return AliasIdentityRepairResult(
            repairedTrades: repairedTrades,
            tradingInfoBySymbol: repairedInfo,
            repairedLinks: repairedLinks,
            displayOrder: repairedOrder,
            alerts: repairedAlerts,
            aliases: aliases,
            quarantinedProviderKeys: quarantined
        )
    }

    private func economicallyEquivalent(_ trades: [Trade]) -> Bool {
        guard let first = trades.first else { return false }
        return trades.dropFirst().allSatisfy { trade in
            approximatelyEqual(trade.position.unitSize, first.position.unitSize)
                && approximatelyEqual(trade.position.positionAvgCost, first.position.positionAvgCost)
                && normalizedCurrency(trade.position.currency) == normalizedCurrency(first.position.currency)
                && normalizedCurrency(trade.position.costCurrency) == normalizedCurrency(first.position.costCurrency)
                && trade.isWatchlistOnly == first.isWatchlistOnly
        }
    }

    private func approximatelyEqual(_ left: Double, _ right: Double) -> Bool {
        left.isFinite && right.isFinite && abs(left - right) <= 0.00000001
    }

    private func normalizedCurrency(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    private func remapTradingInfo(
        _ values: [String: TradingInfo],
        aliases: [String: String]
    ) -> [String: TradingInfo] {
        var result: [String: TradingInfo] = [:]
        for (symbol, info) in values {
            let target = aliases[symbol.uppercased()] ?? symbol.uppercased()
            if let existing = result[target] {
                let existingTime = existing.lastUpdateTime ?? 0
                let proposedTime = info.lastUpdateTime ?? 0
                if proposedTime > existingTime { result[target] = info }
            } else {
                result[target] = info
            }
        }
        return result
    }

    private func remapAlerts(
        _ values: [AliasMigrationAlert],
        aliases: [String: String]
    ) -> [AliasMigrationAlert] {
        var result: [String: AliasMigrationAlert] = [:]
        for alert in values {
            let symbol = alert.symbol.map { aliases[$0.uppercased()] ?? $0.uppercased() }
            let remapped = AliasMigrationAlert(
                id: alert.id,
                symbol: symbol,
                alertType: alert.alertType,
                condition: alert.condition,
                threshold: alert.threshold,
                isEnabled: alert.isEnabled,
                createdAt: alert.createdAt,
                lastTriggered: alert.lastTriggered
            )
            let key = [symbol ?? "portfolio", alert.alertType, alert.condition, String(alert.threshold), String(alert.isEnabled)].joined(separator: "|")
            if let existing = result[key] {
                let earliest = existing.createdAt <= remapped.createdAt ? existing : remapped
                result[key] = AliasMigrationAlert(
                    id: earliest.id,
                    symbol: earliest.symbol,
                    alertType: earliest.alertType,
                    condition: earliest.condition,
                    threshold: earliest.threshold,
                    isEnabled: earliest.isEnabled,
                    createdAt: earliest.createdAt,
                    lastTriggered: [existing.lastTriggered, remapped.lastTriggered].compactMap { $0 }.max()
                )
            } else {
                result[key] = remapped
            }
        }
        return result.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func normalizedLinks(
        _ snapshot: BrokerLinkStoreSnapshot,
        aliases: [String: String],
        quarantined: Set<String>
    ) -> BrokerLinkStoreSnapshot {
        let positions = Dictionary(grouping: snapshot.positions, by: \.id).values.flatMap { group -> [BrokerLinkedPosition] in
            guard let first = group.first, !quarantined.contains(first.id), group.count > 1 else { return group }
            let earliest = group.min { $0.linkedAt < $1.linkedAt }!
            let latest = group.max { $0.updatedAt < $1.updatedAt }!
            return [BrokerLinkedPosition(
                brokerAccountKey: latest.brokerAccountKey,
                instrumentId: latest.instrumentId,
                displaySymbol: aliases[earliest.manualSymbol.uppercased()] ?? earliest.manualSymbol.uppercased(),
                displayName: latest.displayName,
                providerTicker: latest.providerTicker,
                manualSymbol: aliases[earliest.manualSymbol.uppercased()] ?? earliest.manualSymbol.uppercased(),
                manualQuantityAtLink: earliest.manualQuantityAtLink,
                brokerQuantityAtLink: latest.brokerQuantityAtLink,
                manualAverageCostAtLink: earliest.manualAverageCostAtLink,
                manualCurrency: earliest.manualCurrency,
                linkedAt: earliest.linkedAt,
                updatedAt: latest.updatedAt,
                isin: latest.isin ?? earliest.isin
            )]
        }.sorted { $0.id < $1.id }
        return BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: snapshot.updatedAt,
            accounts: snapshot.accounts,
            positions: positions
        )
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct AliasIdentityRecoveryBundle: Codable {
    let migrationVersion: Int
    let createdAt: Date
    let trades: [Trade]
    let tradingInfoBySymbol: [String: TradingInfo]
    let brokerLinks: BrokerLinkStoreSnapshot
    let displayOrder: [String]
    let alerts: [AliasMigrationAlert]
    let previousAliases: [String: String]
    let previousISINDisplaySymbols: [String: String]
    let previousQuarantinedProviderKeys: [String]
    let previousCompletionMarker: Bool
    let previousRecoveryManifest: String?

    init(
        migrationVersion: Int,
        createdAt: Date,
        trades: [Trade],
        tradingInfoBySymbol: [String: TradingInfo],
        brokerLinks: BrokerLinkStoreSnapshot,
        displayOrder: [String],
        alerts: [AliasMigrationAlert],
        previousAliases: [String: String] = [:],
        previousISINDisplaySymbols: [String: String] = [:],
        previousQuarantinedProviderKeys: [String] = [],
        previousCompletionMarker: Bool = false,
        previousRecoveryManifest: String? = nil
    ) {
        self.migrationVersion = migrationVersion
        self.createdAt = createdAt
        self.trades = trades
        self.tradingInfoBySymbol = tradingInfoBySymbol
        self.brokerLinks = brokerLinks
        self.displayOrder = displayOrder
        self.alerts = alerts
        self.previousAliases = previousAliases
        self.previousISINDisplaySymbols = previousISINDisplaySymbols
        self.previousQuarantinedProviderKeys = previousQuarantinedProviderKeys
        self.previousCompletionMarker = previousCompletionMarker
        self.previousRecoveryManifest = previousRecoveryManifest
    }
}

struct AliasIdentityRecoveryStore {
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? StockbarRuntimeStorage
            .stockbarApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("AliasIdentityMigration", isDirectory: true)
    }

    func writeAndValidate(_ bundle: AliasIdentityRecoveryBundle) throws -> URL {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: bundle.createdAt).replacingOccurrences(of: ":", with: "-")
        let url = rootDirectory.appendingPathComponent("alias-identity-v\(bundle.migrationVersion)-\(timestamp)-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(bundle)
        try encoded.write(to: url, options: .atomic)
        let decoded = try load(from: url)
        guard try encoder.encode(decoded) == encoded else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    func load(from url: URL) throws -> AliasIdentityRecoveryBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return try decoder.decode(AliasIdentityRecoveryBundle.self, from: Data(contentsOf: url))
    }

    func markPending(recoveryURL: URL) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data(recoveryURL.path.utf8).write(to: pendingManifestURL, options: .atomic)
    }

    func pendingRecoveryURL() throws -> URL? {
        guard fileManager.fileExists(atPath: pendingManifestURL.path) else { return nil }
        let path = String(decoding: try Data(contentsOf: pendingManifestURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return URL(fileURLWithPath: path)
    }

    func clearPending() throws {
        guard fileManager.fileExists(atPath: pendingManifestURL.path) else { return }
        try fileManager.removeItem(at: pendingManifestURL)
    }

    /// The bundle an interrupted repair left behind, or nil when there is none.
    /// A manifest or bundle that cannot be read is reported with its path, so
    /// the failure names the file instead of a bare decoding error.
    func pendingBundle() throws -> AliasIdentityRecoveryBundle? {
        var path = pendingManifestURL.path
        do {
            guard let recoveryURL = try pendingRecoveryURL() else { return nil }
            path = recoveryURL.path
            return try load(from: recoveryURL)
        } catch {
            throw AliasIdentityMigrationError.pendingRecoveryUnreadable(path: path, reason: error.localizedDescription)
        }
    }

    /// Moves an unreadable pending manifest aside, keeping it for inspection; it
    /// would otherwise fail every later launch. A readable one is left to be applied.
    func setAsideUnreadablePending() {
        guard (try? pendingBundle()) == nil, fileManager.fileExists(atPath: pendingManifestURL.path) else { return }
        let aside = rootDirectory.appendingPathComponent("pending-recovery-manifest.unreadable-\(UUID().uuidString.prefix(8))")
        try? fileManager.moveItem(at: pendingManifestURL, to: aside)
    }

    private var pendingManifestURL: URL {
        rootDirectory.appendingPathComponent("pending-recovery-manifest")
    }
}

struct InstrumentAliasStore {
    static let aliasesKey = "instrumentAliasIdentity.v1.aliases"
    static let isinKey = "instrumentAliasIdentity.v1.isinDisplaySymbols"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
    }

    func load() -> [String: String] {
        guard let value = defaults.dictionary(forKey: Self.aliasesKey) as? [String: String] else {
            return [:]
        }
        return Dictionary(firstValuesFor: value.compactMap { key, value in
            let alias = normalize(key)
            let survivor = normalize(value)
            return alias.isEmpty || survivor.isEmpty ? nil : (alias, survivor)
        })
    }

    func merge(_ aliases: [String: String]) {
        var merged = load()
        for (alias, survivor) in aliases {
            let normalizedAlias = normalize(alias)
            let normalizedSurvivor = normalize(survivor)
            guard !normalizedAlias.isEmpty, !normalizedSurvivor.isEmpty,
                  normalizedAlias != normalizedSurvivor else { continue }
            merged[normalizedAlias] = normalizedSurvivor
        }
        defaults.set(merged, forKey: Self.aliasesKey)
    }

    func mergeISIN(_ isin: String?, displaySymbol: String) {
        let normalizedISIN = normalize(isin ?? "")
        let normalizedDisplay = normalize(displaySymbol)
        guard !normalizedISIN.isEmpty, !normalizedDisplay.isEmpty else { return }
        var values = loadISINDisplaySymbols()
        values[normalizedISIN] = normalizedDisplay
        defaults.set(values, forKey: Self.isinKey)
    }

    func preferredSymbol(forISIN isin: String?) -> String? {
        let normalizedISIN = normalize(isin ?? "")
        guard !normalizedISIN.isEmpty else { return nil }
        let values = loadISINDisplaySymbols()
        return values[normalizedISIN].map(normalize)
    }

    func loadISINDisplaySymbols() -> [String: String] {
        defaults.dictionary(forKey: Self.isinKey) as? [String: String] ?? [:]
    }

    func replaceISINDisplaySymbols(_ values: [String: String]) {
        if values.isEmpty {
            defaults.removeObject(forKey: Self.isinKey)
        } else {
            defaults.set(values, forKey: Self.isinKey)
        }
    }

    func replace(_ aliases: [String: String]) {
        if aliases.isEmpty {
            defaults.removeObject(forKey: Self.aliasesKey)
        } else {
            defaults.set(aliases, forKey: Self.aliasesKey)
        }
    }

    func aliases(for symbol: String) -> [String] {
        let mapping = load()
        let requested = normalize(symbol)
        guard !requested.isEmpty else { return [] }
        let target = resolved(requested, mapping: mapping)
        var values = [requested, target]
        values.append(contentsOf: mapping.keys.filter { resolved($0, mapping: mapping) == target })
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func resolved(_ symbol: String, mapping: [String: String]) -> String {
        var current = symbol
        var visited = Set<String>()
        while let next = mapping[current], visited.insert(current).inserted {
            current = next
        }
        return current
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

enum AliasIdentityMigrationError: Error, LocalizedError {
    case validationFailed(String)
    case migrationAndRestoreFailed(migration: String, restore: String)
    /// An interrupted repair left a recovery file that cannot be read back.
    case pendingRecoveryUnreadable(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .pendingRecoveryUnreadable(let path, let reason):
            return "An earlier repair of your holdings was interrupted and its recovery file cannot be read (\(path): \(reason)). Restore a backup to continue."
        case .validationFailed(let reason):
            return "Alias identity migration validation failed: \(reason)"
        case .migrationAndRestoreFailed(let migration, let restore):
            return "Alias identity migration failed (\(migration)) and recovery also failed (\(restore))."
        }
    }
}

final class AliasIdentityMigrationService: @unchecked Sendable {
    static let migrationVersion = 1
    static let completionKey = "instrumentAliasIdentity.v1.completed"
    static let quarantineKey = "instrumentAliasIdentity.v1.quarantinedProviderKeys"
    static let recoveryManifestKey = "instrumentAliasIdentity.v1.recoveryManifest"

    private let tradeDataService: TradeDataService
    private let brokerLinkStore: BrokerLinkStore
    private let coreDataStack: CoreDataStack
    private let defaults: UserDefaults
    private let recoveryStore: AliasIdentityRecoveryStore
    private let aliasStore: InstrumentAliasStore
    private let cachedPreferredAliases: @Sendable () async -> [String: String]

    init(
        tradeDataService: TradeDataService = TradeDataService(),
        brokerLinkStore: BrokerLinkStore = .shared,
        coreDataStack: CoreDataStack = .shared,
        defaults: UserDefaults = StockbarRuntimeStorage.userDefaults,
        recoveryStore: AliasIdentityRecoveryStore = AliasIdentityRecoveryStore(),
        cachedPreferredAliases: @escaping @Sendable () async -> [String: String] = {
            let settings = FolyncSettingsStore.shared.load()
            guard settings.isEnabled,
                  let cached = try? FolyncSnapshotCache.shared.load(
                      endpoint: settings.baseURL,
                      scopeID: settings.scopeID
                  ) else { return [:] }
            return cached.snapshot.preferredAliasMap
        }
    ) {
        self.tradeDataService = tradeDataService
        self.brokerLinkStore = brokerLinkStore
        self.coreDataStack = coreDataStack
        self.defaults = defaults
        self.recoveryStore = recoveryStore
        self.aliasStore = InstrumentAliasStore(defaults: defaults)
        self.cachedPreferredAliases = cachedPreferredAliases
    }

    private struct PersistedState: @unchecked Sendable {
        let trades: [Trade]
        let tradingInfoBySymbol: [String: TradingInfo]
        let alerts: [AliasMigrationAlert]
    }

    func migrateIfNeeded() async throws -> AliasIdentityRepairResult {
        try await restorePendingMigrationIfNeeded()
        let persistedState = try await loadPersistedState()
        let trades = persistedState.trades
        let tradingInfoBySymbol = persistedState.tradingInfoBySymbol
        let rawLinks = try await brokerLinkStore.loadSnapshotPreservingDuplicates()
        let displayOrder = defaults.stringArray(forKey: "stockDisplayOrder") ?? []
        let alerts = persistedState.alerts

        if defaults.bool(forKey: Self.completionKey) {
            return unchangedResult(
                trades: trades,
                tradingInfoBySymbol: tradingInfoBySymbol,
                links: rawLinks,
                displayOrder: displayOrder,
                alerts: alerts
            )
        }

        var preferredAliases = aliasStore.load()
        for (alias, displaySymbol) in await cachedPreferredAliases() {
            preferredAliases[alias] = displaySymbol
        }
        let result = InstrumentAliasRepairPlanner().plan(
            trades: trades,
            tradingInfoBySymbol: tradingInfoBySymbol,
            links: rawLinks,
            displayOrder: displayOrder,
            alerts: alerts,
            preferredAliases: preferredAliases
        )
        let needsSchemaUpgrade = rawLinks.schemaVersion < 2

        if !result.didChange && !needsSchemaUpgrade {
            aliasStore.merge(preferredAliases)
            persistQuarantine(result.quarantinedProviderKeys)
            if result.quarantinedProviderKeys.isEmpty {
                defaults.set(true, forKey: Self.completionKey)
            }
            return result
        }

        let recoveryBundle = AliasIdentityRecoveryBundle(
            migrationVersion: Self.migrationVersion,
            createdAt: Date(),
            trades: trades,
            tradingInfoBySymbol: tradingInfoBySymbol,
            brokerLinks: rawLinks,
            displayOrder: displayOrder,
            alerts: alerts,
            previousAliases: aliasStore.load(),
            previousISINDisplaySymbols: aliasStore.loadISINDisplaySymbols(),
            previousQuarantinedProviderKeys: defaults.stringArray(forKey: Self.quarantineKey) ?? [],
            previousCompletionMarker: defaults.bool(forKey: Self.completionKey),
            previousRecoveryManifest: defaults.string(forKey: Self.recoveryManifestKey)
        )
        let recoveryURL = try recoveryStore.writeAndValidate(recoveryBundle)
        try recoveryStore.markPending(recoveryURL: recoveryURL)

        do {
            try await persist(result)
            try await validate(result)
            aliasStore.merge(result.aliases)
            persistQuarantine(result.quarantinedProviderKeys)
            defaults.set(recoveryURL.path, forKey: Self.recoveryManifestKey)
            if result.quarantinedProviderKeys.isEmpty {
                defaults.set(true, forKey: Self.completionKey)
            }
            defaults.synchronize()
            try recoveryStore.clearPending()
            return result
        } catch {
            do {
                try await restore(recoveryBundle)
                defaults.synchronize()
                try recoveryStore.clearPending()
            } catch let restoreError {
                throw AliasIdentityMigrationError.migrationAndRestoreFailed(
                    migration: error.localizedDescription,
                    restore: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    static func quarantinedProviderKeys(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: quarantineKey) ?? [])
    }

    private func restorePendingMigrationIfNeeded() async throws {
        guard let bundle = try recoveryStore.pendingBundle() else { return }
        try await restore(bundle)
        defaults.synchronize()
        try recoveryStore.clearPending()
    }

    /// Called after the user has deliberately replaced the portfolio (restore or import).
    func setAsideUnreadablePendingRecovery() {
        recoveryStore.setAsideUnreadablePending()
    }

    private func persist(_ result: AliasIdentityRepairResult) async throws {
        try await tradeDataService.saveAllTrades(result.repairedTrades)
        try await tradeDataService.saveAllTradingInfo(result.tradingInfoBySymbol)
        try await brokerLinkStore.replaceSnapshot(result.repairedLinks)
        try await replaceAlerts(result.alerts)
        defaults.set(result.displayOrder, forKey: "stockDisplayOrder")
    }

    private func restore(_ bundle: AliasIdentityRecoveryBundle) async throws {
        try await tradeDataService.saveAllTrades(bundle.trades)
        try await tradeDataService.saveAllTradingInfo(bundle.tradingInfoBySymbol)
        try await brokerLinkStore.restoreSnapshot(bundle.brokerLinks)
        try await replaceAlerts(bundle.alerts)
        defaults.set(bundle.displayOrder, forKey: "stockDisplayOrder")
        aliasStore.replace(bundle.previousAliases)
        aliasStore.replaceISINDisplaySymbols(bundle.previousISINDisplaySymbols)
        defaults.set(bundle.previousQuarantinedProviderKeys, forKey: Self.quarantineKey)
        defaults.set(bundle.previousCompletionMarker, forKey: Self.completionKey)
        if let manifest = bundle.previousRecoveryManifest {
            defaults.set(manifest, forKey: Self.recoveryManifestKey)
        } else {
            defaults.removeObject(forKey: Self.recoveryManifestKey)
        }
    }

    private func validate(_ expected: AliasIdentityRepairResult) async throws {
        let trades = try await tradeDataService.loadAllTrades()
        let tradingInfo = try await tradeDataService.loadAllTradingInfo()
        let links = try await brokerLinkStore.loadSnapshotPreservingDuplicates()
        let alerts = try await loadAlerts()
        let order = defaults.stringArray(forKey: "stockDisplayOrder") ?? []

        guard tradeSignatures(trades) == tradeSignatures(expected.repairedTrades) else {
            throw AliasIdentityMigrationError.validationFailed("trade count or economic values differ")
        }
        guard try tradingInfoSignature(tradingInfo) == tradingInfoSignature(expected.tradingInfoBySymbol) else {
            throw AliasIdentityMigrationError.validationFailed("trading-info quote values or metadata differ")
        }
        guard linkSignatures(links) == linkSignatures(expected.repairedLinks) else {
            throw AliasIdentityMigrationError.validationFailed("broker links differ")
        }
        guard alerts == expected.alerts, order == expected.displayOrder else {
            throw AliasIdentityMigrationError.validationFailed("alerts or display order differ")
        }
        guard portfolioTotals(trades: trades, tradingInfo: tradingInfo)
                == portfolioTotals(trades: expected.repairedTrades, tradingInfo: expected.tradingInfoBySymbol) else {
            throw AliasIdentityMigrationError.validationFailed("portfolio totals differ")
        }
    }

    private func loadAlerts() async throws -> [AliasMigrationAlert] {
        (try await loadPersistedState()).alerts
    }

    private func loadPersistedState() async throws -> PersistedState {
        try await coreDataStack.performBackgroundTask { context in
            let tradeRequest: NSFetchRequest<TradeEntity> = TradeEntity.fetchRequest()
            tradeRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TradeEntity.name, ascending: true)]
            var seenSymbols = Set<String>()
            let trades = try context.fetch(tradeRequest).compactMap { entity -> Trade? in
                let trade = entity.toTrade()
                let symbol = trade.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !symbol.isEmpty, seenSymbols.insert(symbol).inserted else { return nil }
                return trade
            }

            let infoRequest: NSFetchRequest<TradingInfoEntity> = TradingInfoEntity.fetchRequest()
            var tradingInfo: [String: TradingInfo] = [:]
            for entity in try context.fetch(infoRequest) {
                if let symbol = entity.symbol {
                    tradingInfo[symbol] = entity.toTradingInfo()
                }
            }

            let request: NSFetchRequest<AlertEntity> = AlertEntity.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(keyPath: \AlertEntity.createdAt, ascending: true)]
            let alerts = try context.fetch(request).compactMap { entity -> AliasMigrationAlert? in
                guard let id = entity.id,
                      let alertType = entity.alertType,
                      let condition = entity.condition,
                      let createdAt = entity.createdAt else { return nil }
                return AliasMigrationAlert(
                    id: id,
                    symbol: entity.symbol,
                    alertType: alertType,
                    condition: condition,
                    threshold: entity.threshold,
                    isEnabled: entity.isEnabled,
                    createdAt: createdAt,
                    lastTriggered: entity.lastTriggered
                )
            }
            return PersistedState(trades: trades, tradingInfoBySymbol: tradingInfo, alerts: alerts)
        }
    }

    private func replaceAlerts(_ alerts: [AliasMigrationAlert]) async throws {
        try await coreDataStack.performBackgroundTask { context in
            let request: NSFetchRequest<AlertEntity> = AlertEntity.fetchRequest()
            for entity in try context.fetch(request) {
                context.delete(entity)
            }
            for alert in alerts {
                let entity = AlertEntity(context: context)
                entity.id = alert.id
                entity.symbol = alert.symbol
                entity.alertType = alert.alertType
                entity.condition = alert.condition
                entity.threshold = alert.threshold
                entity.isEnabled = alert.isEnabled
                entity.createdAt = alert.createdAt
                entity.lastTriggered = alert.lastTriggered
            }
        }
    }

    private func persistQuarantine(_ providerKeys: Set<String>) {
        defaults.set(providerKeys.sorted(), forKey: Self.quarantineKey)
    }

    private func unchangedResult(
        trades: [Trade],
        tradingInfoBySymbol: [String: TradingInfo],
        links: BrokerLinkStoreSnapshot,
        displayOrder: [String],
        alerts: [AliasMigrationAlert]
    ) -> AliasIdentityRepairResult {
        AliasIdentityRepairResult(
            repairedTrades: trades,
            tradingInfoBySymbol: tradingInfoBySymbol,
            repairedLinks: links,
            displayOrder: displayOrder,
            alerts: alerts,
            aliases: [:],
            quarantinedProviderKeys: Set(defaults.stringArray(forKey: Self.quarantineKey) ?? [])
        )
    }

    private func tradeSignatures(_ trades: [Trade]) -> [String] {
        trades.map { trade in
            [
                trade.name.uppercased(), String(trade.position.unitSize),
                String(trade.position.positionAvgCost),
                (trade.position.currency ?? "").uppercased(),
                (trade.position.costCurrency ?? "").uppercased(),
                String(trade.isWatchlistOnly), String(trade.showInMenuBar)
            ].joined(separator: "|")
        }.sorted()
    }

    private func linkSignatures(_ snapshot: BrokerLinkStoreSnapshot) -> [String] {
        snapshot.positions.map { position in
            [
                position.id, position.instrumentId, position.manualSymbol.uppercased(),
                String(position.manualQuantityAtLink), String(position.brokerQuantityAtLink),
                String(position.manualAverageCostAtLink ?? .nan),
                (position.manualCurrency ?? "").uppercased()
            ].joined(separator: "|")
        }.sorted()
    }

    private func tradingInfoSignature(_ values: [String: TradingInfo]) throws -> Data {
        let normalized = Dictionary(firstValuesFor: values.map { ($0.key.uppercased(), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return try encoder.encode(normalized)
    }

    private struct FinancialTotals: Equatable {
        var positionCount = 0
        var units = 0.0
        var cost = 0.0
        var marketValue = 0.0
    }

    private func portfolioTotals(
        trades: [Trade],
        tradingInfo: [String: TradingInfo]
    ) -> [String: FinancialTotals] {
        var result: [String: FinancialTotals] = [:]
        for trade in trades where !trade.isWatchlistOnly {
            let symbol = trade.name.uppercased()
            let info = tradingInfo[symbol]
            let currency = (info?.currency ?? trade.position.currency ?? trade.position.costCurrency ?? "UNKNOWN").uppercased()
            var totals = result[currency] ?? FinancialTotals()
            let units = trade.position.unitSize
            let averageCost = trade.position.positionAvgCost
            totals.positionCount += 1
            if units.isFinite { totals.units += units }
            if units.isFinite, averageCost.isFinite { totals.cost += units * averageCost }
            if units.isFinite, let price = info?.currentPrice, price.isFinite {
                totals.marketValue += units * price
            }
            result[currency] = totals
        }
        return result
    }
}
