import Foundation
import LocalAuthentication
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

final class Trading212CredentialStore: @unchecked Sendable {
    static let shared = Trading212CredentialStore()

    private let service: String
    private let cacheLock = NSLock()
    private var sessionCredentials: [String: Trading212AuthConfiguration] = [:]

    init(service: String = "com.fhl43211.Stockbar.trading212") {
        self.service = service
    }

    func save(_ credentials: Trading212AuthConfiguration, environment: Trading212Environment) throws {
        let normalized = credentials.normalized
        _ = try Trading212AuthHeaderBuilder().authorizationHeader(for: normalized)
        let account = currentAccountName(environment: environment)
        let data = try JSONEncoder().encode(StoredCredentialPayload(credentials: normalized))
        try saveData(data, account: account)
        try deleteLegacyValues(environment: environment)
        cache(normalized, account: account)
    }

    func load(
        environment: Trading212Environment,
        allowUserInteraction: Bool = true
    ) throws -> Trading212AuthConfiguration {
        let account = currentAccountName(environment: environment)
        if let cached = cachedCredential(account: account) {
            return cached
        }

        if let data = try loadData(account: account, allowUserInteraction: allowUserInteraction) {
            guard let payload = try? JSONDecoder().decode(StoredCredentialPayload.self, from: data) else {
                throw Trading212CredentialStoreError.invalidStoredCredentials
            }
            let credentials = payload.credentials.normalized
            cache(credentials, account: account)
            return credentials
        }

        guard storageState(environment: environment) == .legacySplitItems else {
            throw Trading212CredentialStoreError.missingCredentials
        }

        guard let apiKey = try loadValue(
            account: legacyAccountName("apiKey", environment: environment),
            allowUserInteraction: allowUserInteraction
        ),
              let apiSecret = try loadValue(
                account: legacyAccountName("apiSecret", environment: environment),
                allowUserInteraction: allowUserInteraction
              ) else {
            throw Trading212CredentialStoreError.missingCredentials
        }

        let credentials = Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret).normalized
        try save(credentials, environment: environment)
        return credentials
    }

    func hasCredentials(environment: Trading212Environment) -> Bool {
        storageState(environment: environment).hasCredentials
    }

    func storageState(environment: Trading212Environment) -> Trading212CredentialStorageState {
        if credentialExists(account: currentAccountName(environment: environment)) {
            return .currentSingleItem
        }

        if credentialExists(account: legacyAccountName("apiKey", environment: environment)),
           credentialExists(account: legacyAccountName("apiSecret", environment: environment)) {
            return .legacySplitItems
        }

        return .notStored
    }

    func delete(environment: Trading212Environment) throws {
        removeCachedCredential(account: currentAccountName(environment: environment))
        try deleteValue(account: currentAccountName(environment: environment))
        try deleteLegacyValues(environment: environment)
    }

    func clearSessionCache(environment: Trading212Environment? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let environment {
            sessionCredentials.removeValue(forKey: currentAccountName(environment: environment))
        } else {
            sessionCredentials.removeAll()
        }
    }

    private func currentAccountName(environment: Trading212Environment) -> String {
        "\(environment.rawValue).credentials.v2"
    }

    private func legacyAccountName(_ name: String, environment: Trading212Environment) -> String {
        "\(environment.rawValue).\(name)"
    }

    private func cachedCredential(account: String) -> Trading212AuthConfiguration? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return sessionCredentials[account]
    }

    private func cache(_ credentials: Trading212AuthConfiguration, account: String) {
        cacheLock.lock()
        sessionCredentials[account] = credentials
        cacheLock.unlock()
    }

    private func removeCachedCredential(account: String) {
        cacheLock.lock()
        sessionCredentials.removeValue(forKey: account)
        cacheLock.unlock()
    }

    private func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw Trading212CredentialStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw Trading212CredentialStoreError.keychainStatus(addStatus)
        }
    }

    private func loadData(account: String, allowUserInteraction: Bool = true) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Trading212CredentialStoreError.keychainStatus(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return data
    }

    private func loadValue(account: String, allowUserInteraction: Bool = true) throws -> String? {
        guard let data = try loadData(account: account, allowUserInteraction: allowUserInteraction) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func deleteValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Trading212CredentialStoreError.keychainStatus(status)
        }
    }

    private func deleteLegacyValues(environment: Trading212Environment) throws {
        try deleteValue(account: legacyAccountName("apiKey", environment: environment))
        try deleteValue(account: legacyAccountName("apiSecret", environment: environment))
    }

    private func credentialExists(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private struct StoredCredentialPayload: Codable {
        let apiKey: String
        let apiSecret: String

        init(credentials: Trading212AuthConfiguration) {
            self.apiKey = credentials.apiKey
            self.apiSecret = credentials.apiSecret
        }

        var credentials: Trading212AuthConfiguration {
            Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret)
        }
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
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
