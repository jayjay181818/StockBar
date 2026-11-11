import Foundation
import Security

/// The market-data API keys Stockbar keeps for the Python helper.
enum MarketDataAPIKey: String, CaseIterable, Sendable {
    case fmp
    case twelveData

    /// Name in the configuration file (where earlier versions kept the key)
    /// and of the environment variable the Python helper reads.
    var configName: String {
        switch self {
        case .fmp: return "FMP_API_KEY"
        case .twelveData: return "TWELVE_DATA_API_KEY"
        }
    }

    /// The sample value earlier set-up instructions put in the file.
    var placeholder: String {
        switch self {
        case .fmp: return "your_fmp_api_key_here"
        case .twelveData: return "your_twelve_data_api_key_here"
        }
    }

    fileprivate var account: String {
        switch self {
        case .fmp: return "fmp-api-key.v1"
        case .twelveData: return "twelve-data-api-key.v1"
        }
    }
}

enum MarketDataKeyStoreError: Error, Equatable, LocalizedError {
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "Market-data API key Keychain operation failed with status \(status)."
        }
    }
}

/// Keeps the FMP and Twelve Data API keys in the Keychain. The Python helper
/// gets them through its environment for each run, so they are no longer
/// written to the configuration file.
///
/// Calls can wait on a Keychain prompt; make them off the main actor.
final class MarketDataKeyStore: Sendable {
    static let shared = MarketDataKeyStore()
    private let service: String

    init(service: String = StockbarRuntimeStorage.acceptance.marketDataKeychainService) {
        self.service = service
    }

    func load(_ key: MarketDataAPIKey) throws -> String? {
        var query = baseQuery(account: key.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MarketDataKeyStoreError.keychainStatus(status)
        }
        return value
    }

    func save(_ value: String, for key: MarketDataAPIKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key.account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MarketDataKeyStoreError.keychainStatus(status) }
        var add = query
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw MarketDataKeyStoreError.keychainStatus(addStatus) }
    }

    func delete(_ key: MarketDataAPIKey) throws {
        let status = SecItemDelete(baseQuery(account: key.account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MarketDataKeyStoreError.keychainStatus(status)
        }
    }

    func deleteAll() throws {
        for key in MarketDataAPIKey.allCases { try delete(key) }
    }

    /// Same predicate as `FolyncCredentialStore`: `kSecAttrAccessible` stays on
    /// every query so lookups use the data-protection keychain rather than the
    /// legacy file-based one (see the note there).
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}
