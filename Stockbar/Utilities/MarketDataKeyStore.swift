import Foundation

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

    /// Name of the value in `CredentialVault`.
    fileprivate var vaultKey: String { "marketdata.\(rawValue)" }

    /// Keychain account of the item earlier versions kept the key in.
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

/// Keeps the FMP and Twelve Data API keys in the Keychain, in the item all
/// credentials share (`CredentialVault`). The Python helper gets them through
/// its environment for each run, so they are no longer written to the
/// configuration file.
///
/// Calls can wait on a Keychain prompt; make them off the main actor.
final class MarketDataKeyStore: Sendable {
    static let shared = MarketDataKeyStore()
    private let service: String
    private let vault: CredentialVault

    init(service: String = StockbarRuntimeStorage.acceptance.marketDataKeychainService) {
        self.service = service
        self.vault = .backing(storeService: service)
    }

    func load(_ key: MarketDataAPIKey) throws -> String? {
        try keychain {
            try vault.importLegacy(into: [key.vaultKey]) { [.text(legacyItem(key), key: key.vaultKey)] }
            return try vault.values()[key.vaultKey]
        }
    }

    func save(_ value: String, for key: MarketDataAPIKey) throws {
        try keychain {
            try vault.update { $0[key.vaultKey] = value }
        }
        // The vault now holds the newer value; the old item is never read again.
        try? legacyItem(key).delete()
    }

    func delete(_ key: MarketDataAPIKey) throws {
        try keychain {
            // First, so a key that was never imported cannot come back.
            try legacyItem(key).delete()
            guard vault.storedKeys()?.contains(key.vaultKey) != false else { return }
            try vault.update { $0[key.vaultKey] = nil }
        }
    }

    func deleteAll() throws {
        for key in MarketDataAPIKey.allCases { try delete(key) }
    }

    /// Where versions before the shared item kept the key.
    private func legacyItem(_ key: MarketDataAPIKey) -> LegacyKeychainItem {
        LegacyKeychainItem(service: service, account: key.account, setsAccessible: true)
    }

    private func keychain<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CredentialVaultError {
            throw MarketDataKeyStoreError.keychainStatus(error.status)
        }
    }
}
