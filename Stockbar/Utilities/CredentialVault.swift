import Foundation
import LocalAuthentication
import Security

/// A Keychain failure, as the status the Keychain reported.
struct CredentialVaultError: Error, Equatable {
    let status: OSStatus

    /// The stored data is not something this version wrote.
    static let unreadableContents = CredentialVaultError(status: errSecDecode)
    /// The item did not read back as it was written.
    static let writeNotVerified = CredentialVaultError(status: errSecDataNotAvailable)
}

/// One Keychain item written by a version that kept every credential in an
/// item of its own. Only read to bring the value into `CredentialVault`.
struct LegacyKeychainItem: Sendable {
    let service: String
    let account: String
    /// Whether that version's queries carried `kSecAttrAccessible`. The query
    /// here must match the one that wrote the item, or it may not be found.
    let setsAccessible: Bool

    /// Whether the item is there. Does not read its data, so never prompts.
    func exists() -> Bool {
        var query = KeychainQuery.item(service: service, account: account, setsAccessible: setsAccessible)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = KeychainQuery.silentContext()
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func read(allowUserInteraction: Bool) throws -> Data? {
        try KeychainQuery.data(
            KeychainQuery.item(service: service, account: account, setsAccessible: setsAccessible),
            allowUserInteraction: allowUserInteraction
        )
    }

    func delete() throws {
        try KeychainQuery.delete(KeychainQuery.item(service: service, account: account, setsAccessible: setsAccessible))
    }
}

/// A legacy item and the vault values its data stands for.
struct LegacyCredentialSource {
    let item: LegacyKeychainItem
    let values: (Data) throws -> [String: String]

    /// An item whose data is the value itself.
    static func text(_ item: LegacyKeychainItem, key: String) -> LegacyCredentialSource {
        LegacyCredentialSource(item: item) { data in
            guard let value = String(data: data, encoding: .utf8) else { throw CredentialVaultError.unreadableContents }
            return [key: value]
        }
    }
}

/// Every credential Stockbar keeps, in one Keychain item.
///
/// A build that is not signed by an Apple-issued certificate has to be let
/// into each Keychain item again after every update. With one item, macOS
/// asks once. The credential stores keep their own interfaces and read and
/// write through here.
///
/// The item's data is a JSON dictionary of named values. The names (never the
/// values) are also kept in an attribute of the item, so "is there a token?"
/// can be answered without reading the data and so without a prompt.
///
/// Calls that read data can wait on a Keychain prompt; make them off the main
/// actor. `storedKeys()` never waits.
///
/// `@unchecked Sendable`: `cached` and `finishedImports` are only touched
/// under `stateLock`, and Keychain reads and writes are serialised by `ioLock`.
final class CredentialVault: @unchecked Sendable {
    static let shared = named(StockbarRuntimeStorage.acceptance.credentialsKeychainService)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: CredentialVault] = [:]

    /// The vault for a Keychain service. One object per service, so every
    /// reader shares one cache.
    static func named(_ service: String) -> CredentialVault {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let vault = registry[service] { return vault }
        let vault = CredentialVault(service: service)
        registry[service] = vault
        return vault
    }

    /// The vault behind a credential store. Stores on the services of this run
    /// share one item. A store given another service (a test, or an acceptance
    /// run being prepared) gets an item of its own beside it.
    static func backing(storeService: String) -> CredentialVault {
        let runtime = StockbarRuntimeStorage.acceptance
        let runServices = [
            runtime.folyncKeychainService, runtime.trading212KeychainService, runtime.marketDataKeychainService
        ]
        return runServices.contains(storeService) ? shared : named("\(storeService).combined")
    }

    private let service: String
    private let account = "credentials.v1"
    /// Held across Keychain calls, so that when several readers start at once
    /// only one of them raises a prompt and the rest get its result.
    private let ioLock = NSLock()
    private let stateLock = NSLock()
    private var cached: [String: String]?
    private var finishedImports: Set<String> = []

    private init(service: String) {
        self.service = service
    }

    // MARK: Reading

    /// Every stored value. Reads the Keychain once, then answers from memory.
    func values(allowUserInteraction: Bool = true) throws -> [String: String] {
        if let cached = cachedValues() { return cached }
        ioLock.lock()
        defer { ioLock.unlock() }
        if let cached = cachedValues() { return cached }
        let values = try readItem(allowUserInteraction: allowUserInteraction) ?? [:]
        setCached(values)
        return values
    }

    /// The names of the stored values, without reading the values. `nil` when
    /// the Keychain will not say without the user (it is locked).
    func storedKeys() -> Set<String>? {
        if let cached = cachedValues() { return Set(cached.keys) }
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = KeychainQuery.silentContext()
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let index = attributes[kSecAttrGeneric as String] as? Data,
              let keys = try? JSONDecoder().decode([String].self, from: index) else { return [] }
        return Set(keys)
    }

    /// Drops the copy in memory; the next read goes to the Keychain.
    func forgetCachedContents() {
        stateLock.lock()
        cached = nil
        stateLock.unlock()
    }

    // MARK: Writing

    /// Changes the stored values in one write. Starts from what the Keychain
    /// holds now, not from memory, so a change made by another copy of the app
    /// is not written over.
    func update(_ change: (inout [String: String]) -> Void) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        var values = try readItem(allowUserInteraction: true) ?? [:]
        let before = values
        change(&values)
        if values != before { try writeItem(values) }
        setCached(values)
    }

    /// Removes the item itself.
    func deleteItem() throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        try KeychainQuery.delete(baseQuery())
        setCached([:])
    }

    // MARK: Credentials from earlier versions

    /// Brings credentials an earlier version kept in items of their own into
    /// the vault, then removes those items.
    ///
    /// Nothing is lost on the way: all the items are read first, the vault is
    /// written and read back from the Keychain, and only when it reads back
    /// with the imported values are the old items removed. If a read is
    /// refused or anything else fails, the old items stay as they are and the
    /// next call tries again.
    ///
    /// `keys` are the vault names the items can fill. Once the vault holds any
    /// of them it is the newer copy: nothing is imported and the old items are
    /// only removed. `sources` is asked once per run of the app.
    func importLegacy(
        into keys: [String],
        allowUserInteraction: Bool = true,
        from sources: () -> [LegacyCredentialSource]
    ) throws {
        let importID = keys.joined(separator: "\n")
        if hasFinished(importID) { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        if hasFinished(importID) { return }

        let present = sources().filter { $0.item.exists() }
        guard !present.isEmpty else {
            markFinished(importID)
            return
        }

        var values = try readItem(allowUserInteraction: allowUserInteraction) ?? [:]
        if !keys.contains(where: { values[$0] != nil }) {
            var imported: [String: String] = [:]
            for source in present {
                guard let data = try source.item.read(allowUserInteraction: allowUserInteraction) else { continue }
                // Sources are listed newest format first; the first value wins.
                imported.merge(try source.values(data)) { first, _ in first }
            }
            if !imported.isEmpty {
                values.merge(imported) { stored, _ in stored }
                try writeItem(values)
                guard try readItem(allowUserInteraction: allowUserInteraction) == values else {
                    throw CredentialVaultError.writeNotVerified
                }
            }
        }
        setCached(values)
        // A removal that fails is tried again on the next launch.
        for source in present { try? source.item.delete() }
        markFinished(importID)
    }

    // MARK: Keychain

    private struct Contents: Codable {
        var version = 1
        var values: [String: String]
    }

    private func readItem(allowUserInteraction: Bool) throws -> [String: String]? {
        guard let data = try KeychainQuery.data(baseQuery(), allowUserInteraction: allowUserInteraction) else {
            return nil
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            throw CredentialVaultError.unreadableContents
        }
        return contents.values
    }

    /// Writes the values and their names together. An empty vault has no item.
    private func writeItem(_ values: [String: String]) throws {
        guard !values.isEmpty else {
            try KeychainQuery.delete(baseQuery())
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attributes: [String: Any] = [
            kSecValueData as String: try encoder.encode(Contents(values: values)),
            kSecAttrGeneric as String: try encoder.encode(values.keys.sorted())
        ]
        let query = baseQuery()
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CredentialVaultError(status: status) }

        var add = query.merging(attributes) { _, new in new }
        add[kSecAttrLabel as String] = "Stockbar credentials"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialVaultError(status: addStatus) }
    }

    private func baseQuery() -> [String: Any] {
        KeychainQuery.item(service: service, account: account, setsAccessible: true)
    }

    // MARK: State

    private func cachedValues() -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cached
    }

    private func setCached(_ values: [String: String]) {
        stateLock.lock()
        cached = values
        stateLock.unlock()
    }

    private func hasFinished(_ importID: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finishedImports.contains(importID)
    }

    private func markFinished(_ importID: String) {
        stateLock.lock()
        finishedImports.insert(importID)
        stateLock.unlock()
    }
}

/// The Keychain calls the vault and the legacy items share.
private enum KeychainQuery {
    /// Lookup, insert and delete predicate of a generic-password item.
    /// `setsAccessible` follows the store that wrote the item: the Folync and
    /// market-data stores put `kSecAttrAccessible` on every query, the Trading
    /// 212 store on none.
    static func item(service: String, account: String, setsAccessible: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if setsAccessible {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return query
    }

    /// Makes a query fail rather than ask the user.
    static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func data(_ item: [String: Any], allowUserInteraction: Bool) throws -> Data? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = silentContext()
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError(status: status) }
        guard let data = result as? Data else { throw CredentialVaultError.unreadableContents }
        return data
    }

    static func delete(_ item: [String: Any]) throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError(status: status)
        }
    }
}
