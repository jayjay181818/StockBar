import CryptoKit
import Foundation
import Security

struct FolyncStoredSettings: Codable, Equatable {
    let schemaVersion: Int
    var isEnabled: Bool
    var baseURL: String
    var scopeID: String
    var pollingIntervalSeconds: Int
    var supplemental: FolyncSupplementalSettings

    init(
        isEnabled: Bool,
        baseURL: String,
        scopeID: String,
        pollingIntervalSeconds: Int,
        supplemental: FolyncSupplementalSettings = .disabled
    ) {
        self.schemaVersion = 2
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.scopeID = scopeID
        self.pollingIntervalSeconds = pollingIntervalSeconds
        self.supplemental = supplemental
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, isEnabled, baseURL, scopeID, pollingIntervalSeconds, supplemental
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = 2
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        scopeID = try container.decode(String.self, forKey: .scopeID)
        pollingIntervalSeconds = try container.decode(Int.self, forKey: .pollingIntervalSeconds)
        supplemental = try container.decodeIfPresent(FolyncSupplementalSettings.self, forKey: .supplemental) ?? .disabled
    }

    func isSupplementalRouteActive(_ route: FolyncSupplementalRoute) -> Bool {
        isEnabled && supplemental.isEnabled(route)
    }

    static let defaults = FolyncStoredSettings(
        isEnabled: false,
        baseURL: "",
        scopeID: "all",
        pollingIntervalSeconds: 60
    )
}

final class FolyncSettingsStore: @unchecked Sendable {
    static let shared = FolyncSettingsStore()
    private let defaults: UserDefaults
    private let key = "folync.portfolio-source.settings.v2"
    private let legacyKey = "folync.portfolio-source.settings.v1"

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
    }

    func load() -> FolyncStoredSettings {
        if let data = defaults.data(forKey: key),
           let settings = try? JSONDecoder().decode(FolyncStoredSettings.self, from: data) {
            return settings
        }
        if let data = defaults.data(forKey: legacyKey),
           let migrated = try? JSONDecoder().decode(FolyncStoredSettings.self, from: data) {
            save(migrated)
            return migrated
        }
        return .defaults
    }

    func save(_ settings: FolyncStoredSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func setEnabled(_ enabled: Bool) {
        var settings = load()
        settings.isEnabled = enabled
        save(settings)
    }

    func setSupplemental(_ supplemental: FolyncSupplementalSettings) {
        var settings = load()
        settings.supplemental = supplemental
        save(settings)
    }
}

enum FolyncCredentialStoreError: Error, LocalizedError, Equatable {
    case keychainStatus(OSStatus)
    case missingToken
    /// The stored token was saved for a different server than the one asked for.
    case savedForAnotherServer

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): return "Folync Keychain operation failed with status \(status)."
        case .missingToken: return "Folync client token is not stored in Keychain."
        case .savedForAnotherServer: return "The stored Folync client token was saved for a different server."
        }
    }
}

/// Keeps the Folync client token in the Keychain together with the server it
/// was saved for, in the item all credentials share (`CredentialVault`). The
/// token is only handed out for that server, so changing the endpoint (in
/// Settings or through an imported settings file) can never send an existing
/// token to a new host.
///
/// Calls other than `hasToken()` can wait on a Keychain prompt; make them off
/// the main actor.
final class FolyncCredentialStore: Sendable {
    static let shared = FolyncCredentialStore()
    private static let tokenKey = "folync.token"
    private static let serverKey = "folync.server"
    private let vault: CredentialVault
    /// Where versions before the shared item kept the token and its server.
    private let legacyToken: LegacyKeychainItem
    private let legacyServer: LegacyKeychainItem

    init(service: String = StockbarRuntimeStorage.acceptance.folyncKeychainService) {
        vault = .backing(storeService: service)
        legacyToken = LegacyKeychainItem(service: service, account: "client-api-token.v1", setsAccessible: true)
        legacyServer = LegacyKeychainItem(service: service, account: "client-api-token-server.v1", setsAccessible: true)
    }

    /// Scheme, host and port of an endpoint, for example `https://folync.example:443`.
    /// The path is left out: one server may be reached through several paths.
    static func server(of baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort: Int? = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        guard let port = components.port ?? defaultPort else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    /// Stores the token for the server at `baseURL`.
    func save(token: String, for baseURL: String) throws {
        try save(token: token, server: Self.server(of: baseURL))
    }

    /// Stores the token for `server` (as returned by `server(of:)`). With no
    /// server the token is kept but is not handed out by `load(for:)`.
    func save(token: String, server: String?) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw FolyncCredentialStoreError.missingToken }
        try keychain {
            // One write, so a new token is never paired with the previous server.
            try vault.update { values in
                values[Self.tokenKey] = normalized
                values[Self.serverKey] = server
            }
        }
        // The vault now holds the newer pair; the old items are never read again.
        try? legacyToken.delete()
        try? legacyServer.delete()
    }

    /// The stored token, whichever server it belongs to. For export and
    /// rollback only; requests use `load(for:)`.
    func load() throws -> String {
        guard let token = try value(Self.tokenKey) else { throw FolyncCredentialStoreError.missingToken }
        return token
    }

    /// The stored token, if it was saved for the server at `baseURL`.
    func load(for baseURL: String) throws -> String {
        let token = try load()
        guard let wanted = Self.server(of: baseURL), try savedServer() == wanted else {
            throw FolyncCredentialStoreError.savedForAnotherServer
        }
        return token
    }

    func savedServer() throws -> String? {
        try value(Self.serverKey)
    }

    /// Tokens stored by earlier versions have no server recorded. Records the
    /// endpoint that was in use with them; does nothing once a server is set.
    func recordServerIfMissing(_ baseURL: String) {
        guard hasToken(), let server = Self.server(of: baseURL) else { return }
        do {
            guard try savedServer() == nil else { return }
            try vault.update { values in
                if values[Self.tokenKey] != nil, values[Self.serverKey] == nil {
                    values[Self.serverKey] = server
                }
            }
        } catch {
            // Left unrecorded: the token is then not sent until it is entered again.
        }
    }

    func delete() throws {
        try keychain {
            // First, so a token that was never imported cannot come back.
            try legacyToken.delete()
            try legacyServer.delete()
            guard vault.storedKeys()?.isDisjoint(with: Self.keys) != true else { return }
            try vault.update { values in
                for key in Self.keys { values[key] = nil }
            }
        }
    }

    /// Whether a token is stored. Does not read it, so never prompts.
    func hasToken() -> Bool {
        let stored = vault.storedKeys() ?? []
        if stored.contains(Self.tokenKey) { return true }
        return stored.isDisjoint(with: Self.keys) && legacyToken.exists()
    }

    private static let keys = [tokenKey, serverKey]

    private func value(_ key: String) throws -> String? {
        try keychain {
            try vault.importLegacy(into: Self.keys) {
                [.text(legacyToken, key: Self.tokenKey), .text(legacyServer, key: Self.serverKey)]
            }
            return try vault.values()[key]
        }
    }

    private func keychain<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CredentialVaultError {
            throw FolyncCredentialStoreError.keychainStatus(error.status)
        }
    }
}

struct FolyncCachedSnapshot: Codable, Equatable {
    let endpoint: String
    let scopeID: String
    let etag: String?
    let snapshot: FolyncPortfolioSnapshot
}

actor FolyncSnapshotCache {
    static let shared = FolyncSnapshotCache()
    private let fileManager: FileManager
    private let directory: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? StockbarRuntimeStorage
            .stockbarApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("Folync", isDirectory: true)
    }

    func load(endpoint: String, scopeID: String) throws -> FolyncCachedSnapshot? {
        let url = fileURL(endpoint: endpoint, scopeID: scopeID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let cached = try JSONDecoder().decode(FolyncCachedSnapshot.self, from: Data(contentsOf: url))
            guard cached.endpoint == endpoint, cached.scopeID == scopeID else { return nil }
            _ = try FolyncPortfolioDecoder().decodeSnapshot(JSONEncoder().encode(cached.snapshot))
            return cached
        } catch {
            try? fileManager.removeItem(at: url)
            let redacted = LogRedactor.redact(error.localizedDescription)
            Task {
                await Logger.shared.warning("Removed unreadable Folync snapshot cache: \(redacted)")
            }
            throw error
        }
    }

    func save(_ cached: FolyncCachedSnapshot) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: fileURL(endpoint: cached.endpoint, scopeID: cached.scopeID), options: .atomic)
    }

    private func fileURL(endpoint: String, scopeID: String) -> URL {
        let digest = SHA256.hash(data: Data("\(endpoint)|\(scopeID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("snapshot-\(digest).json")
    }
}

final class FolyncOverlayStore: @unchecked Sendable {
    static let shared = FolyncOverlayStore()
    private let defaults: UserDefaults
    private let key = "folync.holding-overlays.v1"

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
    }

    func load() -> [String: FolyncHoldingOverlay] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: FolyncHoldingOverlay].self, from: data)) ?? [:]
    }

    func set(_ overlay: FolyncHoldingOverlay, for identity: String) {
        var overlays = load()
        overlays[identity] = overlay
        if let data = try? JSONEncoder().encode(overlays) {
            defaults.set(data, forKey: key)
        }
    }
}
