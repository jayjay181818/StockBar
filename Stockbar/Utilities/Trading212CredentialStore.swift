import Foundation
import Security

enum Trading212CredentialStoreError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .missingCredentials:
            return "Trading 212 credentials are not stored in Keychain."
        }
    }
}

final class Trading212CredentialStore: @unchecked Sendable {
    static let shared = Trading212CredentialStore()

    private let service: String

    init(service: String = "com.fhl43211.Stockbar.trading212") {
        self.service = service
    }

    func save(_ credentials: Trading212AuthConfiguration, environment: Trading212Environment) throws {
        let normalized = credentials.normalized
        _ = try Trading212AuthHeaderBuilder().authorizationHeader(for: normalized)
        try saveValue(normalized.apiKey, account: accountName("apiKey", environment: environment))
        try saveValue(normalized.apiSecret, account: accountName("apiSecret", environment: environment))
    }

    func load(environment: Trading212Environment) throws -> Trading212AuthConfiguration {
        guard let apiKey = try loadValue(account: accountName("apiKey", environment: environment)),
              let apiSecret = try loadValue(account: accountName("apiSecret", environment: environment)) else {
            throw Trading212CredentialStoreError.missingCredentials
        }
        return Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret)
    }

    func hasCredentials(environment: Trading212Environment) -> Bool {
        guard let credentials = try? load(environment: environment) else {
            return false
        }
        return (try? Trading212AuthHeaderBuilder().authorizationHeader(for: credentials)) != nil
    }

    func delete(environment: Trading212Environment) throws {
        try deleteValue(account: accountName("apiKey", environment: environment))
        try deleteValue(account: accountName("apiSecret", environment: environment))
    }

    private func accountName(_ name: String, environment: Trading212Environment) -> String {
        "\(environment.rawValue).\(name)"
    }

    private func saveValue(_ value: String, account: String) throws {
        let data = Data(value.utf8)
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

    private func loadValue(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

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
        return String(data: data, encoding: .utf8)
    }

    private func deleteValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Trading212CredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
                ?? fallback.deleteMissingLinkedHoldings
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
    }
}
