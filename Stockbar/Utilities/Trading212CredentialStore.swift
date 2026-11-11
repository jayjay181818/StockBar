import Foundation
import Security

enum Trading212CredentialStoreError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case missingCredentials
    case invalidStoredCredentials

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .missingCredentials:
            return "Trading 212 credentials are not stored in Keychain."
        case .invalidStoredCredentials:
            return "Trading 212 credentials stored in Keychain could not be decoded."
        }
    }
}

enum Trading212CredentialStorageState: Equatable {
    case notStored
    case currentSingleItem
    case legacySplitItems

    var hasCredentials: Bool {
        self != .notStored
    }

    var isReadyForBackgroundAccess: Bool {
        self == .currentSingleItem
    }
}

/// Keeps the Trading 212 API key and secret in the Keychain, in the item all
/// credentials share (`CredentialVault`).
///
/// `load` can wait on a Keychain prompt; call it off the main actor.
/// `storageState` never does.
final class Trading212CredentialStore: Sendable {
    static let shared = Trading212CredentialStore()

    private let service: String
    private let vault: CredentialVault

    init(service: String = StockbarRuntimeStorage.acceptance.trading212KeychainService) {
        self.service = service
        self.vault = .backing(storeService: service)
    }

    func save(_ credentials: Trading212AuthConfiguration, environment: Trading212Environment) throws {
        let normalized = credentials.normalized
        _ = try Trading212AuthHeaderBuilder().authorizationHeader(for: normalized)
        try keychain {
            try vault.update { values in
                values[apiKeyName(environment)] = normalized.apiKey
                values[apiSecretName(environment)] = normalized.apiSecret
            }
        }
        // The vault now holds the newer pair; the old items are never read again.
        for item in legacyItems(environment) { try? item.delete() }
    }

    /// The stored credentials. After the first read they come from memory.
    /// With `allowUserInteraction` off, a read that would need the user fails
    /// with `errSecInteractionNotAllowed` instead of asking.
    func load(
        environment: Trading212Environment,
        allowUserInteraction: Bool = true
    ) throws -> Trading212AuthConfiguration {
        let values = try keychain {
            try vault.importLegacy(into: names(environment), allowUserInteraction: allowUserInteraction) {
                legacySources(environment)
            }
            return try vault.values(allowUserInteraction: allowUserInteraction)
        }
        guard let apiKey = values[apiKeyName(environment)],
              let apiSecret = values[apiSecretName(environment)] else {
            throw Trading212CredentialStoreError.missingCredentials
        }
        return Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret).normalized
    }

    func hasCredentials(environment: Trading212Environment) -> Bool {
        storageState(environment: environment).hasCredentials
    }

    /// Whether credentials are stored and in which form, without reading them.
    func storageState(environment: Trading212Environment) -> Trading212CredentialStorageState {
        // A locked Keychain will not say; as before, that counts as stored.
        guard let stored = vault.storedKeys() else { return .currentSingleItem }
        let names = names(environment)
        if names.allSatisfy(stored.contains) { return .currentSingleItem }
        guard stored.isDisjoint(with: names) else { return .notStored }

        // Not in the shared item yet: an earlier version's items are imported
        // by the next `load`.
        if legacyPair(environment).exists() { return .currentSingleItem }
        if legacySplitKey(environment).exists(), legacySplitSecret(environment).exists() {
            return .legacySplitItems
        }
        return .notStored
    }

    func delete(environment: Trading212Environment) throws {
        try keychain {
            // First, so credentials that were never imported cannot come back.
            for item in legacyItems(environment) { try item.delete() }
            guard vault.storedKeys()?.isDisjoint(with: names(environment)) != true else { return }
            try vault.update { values in
                for name in names(environment) { values[name] = nil }
            }
        }
    }

    /// Forgets the copy in memory; the next `load` reads the Keychain.
    func clearSessionCache() {
        vault.forgetCachedContents()
    }

    // MARK: Names in the vault

    private func apiKeyName(_ environment: Trading212Environment) -> String {
        "trading212.\(environment.rawValue).apiKey"
    }

    private func apiSecretName(_ environment: Trading212Environment) -> String {
        "trading212.\(environment.rawValue).apiSecret"
    }

    private func names(_ environment: Trading212Environment) -> [String] {
        [apiKeyName(environment), apiSecretName(environment)]
    }

    // MARK: Items of earlier versions

    /// One item holding the pair as JSON: the form before the shared item.
    private func legacyPair(_ environment: Trading212Environment) -> LegacyKeychainItem {
        legacyItem("\(environment.rawValue).credentials.v2")
    }

    /// The first form: the key and the secret in an item each.
    private func legacySplitKey(_ environment: Trading212Environment) -> LegacyKeychainItem {
        legacyItem("\(environment.rawValue).apiKey")
    }

    private func legacySplitSecret(_ environment: Trading212Environment) -> LegacyKeychainItem {
        legacyItem("\(environment.rawValue).apiSecret")
    }

    private func legacyItems(_ environment: Trading212Environment) -> [LegacyKeychainItem] {
        [legacyPair(environment), legacySplitKey(environment), legacySplitSecret(environment)]
    }

    /// This store's queries never carried `kSecAttrAccessible`; the items are
    /// only found by a query without it.
    private func legacyItem(_ account: String) -> LegacyKeychainItem {
        LegacyKeychainItem(service: service, account: account, setsAccessible: false)
    }

    /// Newest form first. The split items count only as a pair.
    private func legacySources(_ environment: Trading212Environment) -> [LegacyCredentialSource] {
        let apiKeyName = apiKeyName(environment)
        let apiSecretName = apiSecretName(environment)
        var sources = [
            LegacyCredentialSource(item: legacyPair(environment)) { data in
                guard let payload = try? JSONDecoder().decode(StoredCredentialPayload.self, from: data) else {
                    throw Trading212CredentialStoreError.invalidStoredCredentials
                }
                let credentials = Trading212AuthConfiguration(apiKey: payload.apiKey, apiSecret: payload.apiSecret)
                    .normalized
                return [apiKeyName: credentials.apiKey, apiSecretName: credentials.apiSecret]
            }
        ]
        let splitKey = legacySplitKey(environment)
        let splitSecret = legacySplitSecret(environment)
        if splitKey.exists(), splitSecret.exists() {
            sources.append(.text(splitKey, key: apiKeyName))
            sources.append(.text(splitSecret, key: apiSecretName))
        }
        return sources
    }

    private func keychain<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CredentialVaultError {
            throw Trading212CredentialStoreError.keychainStatus(error.status)
        }
    }

    private struct StoredCredentialPayload: Codable {
        let apiKey: String
        let apiSecret: String
    }
}

final class Trading212SettingsStore: @unchecked Sendable {
    static let shared = Trading212SettingsStore()

    private enum Key {
        static let enabled = "trading212.enabled"
        static let environment = "trading212.environment"
        static let accountType = "trading212.accountType"
        static let accountLabel = "trading212.accountLabel"
        static let autoSyncEnabled = "trading212.autoSyncEnabled"
        static let syncIntervalMinutes = "trading212.syncIntervalMinutes"
        static let syncIntervalSeconds = "trading212.syncIntervalSeconds"
        static let deleteMissingLinkedHoldings = "trading212.deleteMissingLinkedHoldings"
        static let autoReconcileHoldingsEnabled = "trading212.autoReconcileHoldingsEnabled"
        static let autoImportBrokerOnlyHoldings = "trading212.autoImportBrokerOnlyHoldings"
        static let holdingReconciliationIntervalSeconds = "trading212.holdingReconciliationIntervalSeconds"
        static let syncIntervalDefaultMigration = "trading212.syncIntervalDefaultMigration.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
        migrateLegacySyncIntervalDefaultIfNeeded()
    }

    /// Moves installs that are still on the old 30s cadence up to the new 300s
    /// default, once.
    ///
    /// `save()` persists every field, so anyone who has ever opened the Trading
    /// 212 settings has 30 written to disk whether they chose it or not — which
    /// means raising `defaultIntervalSeconds` alone would leave existing users
    /// on the old cadence forever.
    ///
    /// This only rewrites the exact legacy default. Any other stored value is a
    /// deliberate choice and is left alone, and 30s remains selectable in the
    /// UI for anyone who wants it back.
    private func migrateLegacySyncIntervalDefaultIfNeeded() {
        guard !defaults.bool(forKey: Key.syncIntervalDefaultMigration) else { return }
        defer { defaults.set(true, forKey: Key.syncIntervalDefaultMigration) }

        guard let stored = defaults.object(forKey: Key.syncIntervalSeconds) as? Int,
              stored == Trading212SyncPolicy.legacyDefaultIntervalSeconds else {
            return
        }

        defaults.set(Trading212SyncPolicy.defaultIntervalSeconds, forKey: Key.syncIntervalSeconds)
        Task {
            await Logger.shared.info(
                "Trading 212 sync interval moved from the legacy \(Trading212SyncPolicy.legacyDefaultIntervalSeconds)s "
                + "default to \(Trading212SyncPolicy.defaultIntervalSeconds)s. It remains configurable in Settings."
            )
        }
    }

    func load() -> Trading212StoredSettings {
        let fallback = Trading212StoredSettings.defaults
        let storedIntervalSeconds = defaults.object(forKey: Key.syncIntervalSeconds) as? Int
        return Trading212StoredSettings(
            isEnabled: defaults.object(forKey: Key.enabled) as? Bool ?? fallback.isEnabled,
            environment: Trading212Environment(rawValue: defaults.string(forKey: Key.environment) ?? "") ?? fallback.environment,
            accountType: Trading212AccountType(rawValue: defaults.string(forKey: Key.accountType) ?? "") ?? fallback.accountType,
            accountLabel: defaults.string(forKey: Key.accountLabel) ?? fallback.accountLabel,
            autoSyncEnabled: defaults.object(forKey: Key.autoSyncEnabled) as? Bool ?? fallback.autoSyncEnabled,
            syncIntervalSeconds: Trading212SyncPolicy.clampedIntervalSeconds(
                storedIntervalSeconds ?? fallback.syncIntervalSeconds
            ),
            deleteMissingLinkedHoldings: defaults.object(forKey: Key.deleteMissingLinkedHoldings) as? Bool
                ?? fallback.deleteMissingLinkedHoldings,
            autoReconcileHoldingsEnabled: defaults.object(forKey: Key.autoReconcileHoldingsEnabled) as? Bool
                ?? fallback.autoReconcileHoldingsEnabled,
            autoImportBrokerOnlyHoldings: defaults.object(forKey: Key.autoImportBrokerOnlyHoldings) as? Bool
                ?? fallback.autoImportBrokerOnlyHoldings,
            holdingReconciliationIntervalSeconds: max(
                Trading212SyncPolicy.defaultHoldingReconciliationIntervalSeconds,
                defaults.object(forKey: Key.holdingReconciliationIntervalSeconds) as? Int
                    ?? fallback.holdingReconciliationIntervalSeconds
            )
        )
    }

    func save(_ settings: Trading212StoredSettings) {
        defaults.set(settings.isEnabled, forKey: Key.enabled)
        defaults.set(settings.environment.rawValue, forKey: Key.environment)
        defaults.set(settings.accountType.rawValue, forKey: Key.accountType)
        defaults.set(settings.accountLabel, forKey: Key.accountLabel)
        defaults.set(settings.autoSyncEnabled, forKey: Key.autoSyncEnabled)
        defaults.set(Trading212SyncPolicy.clampedIntervalSeconds(settings.syncIntervalSeconds), forKey: Key.syncIntervalSeconds)
        defaults.removeObject(forKey: Key.syncIntervalMinutes)
        defaults.set(settings.deleteMissingLinkedHoldings, forKey: Key.deleteMissingLinkedHoldings)
        defaults.set(settings.autoReconcileHoldingsEnabled, forKey: Key.autoReconcileHoldingsEnabled)
        defaults.set(settings.autoImportBrokerOnlyHoldings, forKey: Key.autoImportBrokerOnlyHoldings)
        defaults.set(
            max(Trading212SyncPolicy.defaultHoldingReconciliationIntervalSeconds, settings.holdingReconciliationIntervalSeconds),
            forKey: Key.holdingReconciliationIntervalSeconds
        )
    }
}
