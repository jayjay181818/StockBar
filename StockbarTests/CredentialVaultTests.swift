import Security
import XCTest
@testable import Stockbar

/// Every credential lives in one Keychain item, and the items earlier
/// versions wrote are brought into it without losing any of them.
///
/// Each test uses a Keychain service of its own. Stores given the same
/// service share one vault, the way the app's stores share the real one.
final class CredentialVaultTests: XCTestCase {
    private var service = ""
    private var vault: CredentialVault { .named("\(service).combined") }

    override func setUp() {
        super.setUp()
        service = "com.stockbar.tests.vault.\(UUID().uuidString)"
    }

    override func tearDown() {
        removeEveryItem(service: service)
        removeEveryItem(service: "\(service).combined")
        super.tearDown()
    }

    // MARK: One item

    func testTheAppsOwnStoresShareOneKeychainItem() throws {
        // The stores as the app makes them, on this test run's own services.
        let runtime = StockbarRuntimeStorage.acceptance
        XCTAssertNotEqual(
            runtime.credentialsKeychainService,
            StockbarAcceptanceRuntime.productionCredentialsKeychainService
        )
        let folync = FolyncCredentialStore()
        let marketData = MarketDataKeyStore()
        let trading212 = Trading212CredentialStore()
        let hadToken = folync.hasToken()
        let hadKey = try marketData.load(.fmp)
        let hadPair = trading212.hasCredentials(environment: .demo)
        try XCTSkipIf(hadToken || hadKey != nil || hadPair, "Another test left credentials in the shared stores.")
        defer {
            try? folync.delete()
            try? marketData.delete(.fmp)
            try? trading212.delete(environment: .demo)
        }

        try folync.save(token: "token", for: "https://folync.example")
        try marketData.save("fmp-key", for: .fmp)
        try trading212.save(Trading212AuthConfiguration(apiKey: "key", apiSecret: "secret"), environment: .demo)

        XCTAssertEqual(itemCount(service: runtime.credentialsKeychainService), 1)
        XCTAssertEqual(itemCount(service: runtime.folyncKeychainService), 0)
        XCTAssertEqual(itemCount(service: runtime.marketDataKeychainService), 0)
        XCTAssertEqual(itemCount(service: runtime.trading212KeychainService), 0)
    }

    func testRemovingTheLastCredentialRemovesTheItem() throws {
        let store = MarketDataKeyStore(service: service)

        try store.save("fmp-key", for: .fmp)
        XCTAssertEqual(itemCount(service: "\(service).combined"), 1)

        try store.delete(.fmp)
        XCTAssertEqual(itemCount(service: "\(service).combined"), 0)
        XCTAssertNil(try store.load(.fmp))
    }

    func testStoredNamesAreReadWithoutReadingTheValues() throws {
        let store = FolyncCredentialStore(service: service)
        try store.save(token: "token", for: "https://folync.example")

        // As after a restart: nothing in memory, only the item's attribute.
        vault.forgetCachedContents()

        XCTAssertEqual(vault.storedKeys(), ["folync.token", "folync.server"])
        XCTAssertTrue(store.hasToken())
    }

    func testAChangeStartsFromTheKeychainNotFromMemory() throws {
        let marketData = MarketDataKeyStore(service: service)
        try marketData.save("fmp-key", for: .fmp)
        XCTAssertEqual(try marketData.load(.fmp), "fmp-key")

        // Another copy of the app replaces the item while this one holds the
        // earlier contents in memory.
        try writeVaultItem(["marketdata.fmp": "newer-key", "folync.token": "other-token"])
        try marketData.save("twelve-key", for: .twelveData)

        vault.forgetCachedContents()
        XCTAssertEqual(
            try vault.values(),
            ["marketdata.fmp": "newer-key", "folync.token": "other-token", "marketdata.twelveData": "twelve-key"]
        )
    }

    func testReadersStartingTogetherAllGetTheStoredValue() throws {
        let store = MarketDataKeyStore(service: service)
        try saveLegacy("fmp-key", account: "fmp-api-key.v1", accessible: true)

        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            results.add((try? store.load(.fmp)) ?? nil)
        }

        XCTAssertEqual(results.values, Array(repeating: "fmp-key", count: 12))
    }

    // MARK: Credentials from earlier versions

    /// The four items a Mac with Folync and both market-data keys had, plus
    /// Trading 212 credentials, become one item with nothing lost.
    func testItemsOfEarlierVersionsAreImportedIntoOneItem() throws {
        try saveLegacy("folync-token", account: "client-api-token.v1", accessible: true)
        try saveLegacy("https://folync.example:443", account: "client-api-token-server.v1", accessible: true)
        try saveLegacy("fmp-key", account: "fmp-api-key.v1", accessible: true)
        try saveLegacy("twelve-key", account: "twelve-data-api-key.v1", accessible: true)
        try saveLegacy(#"{"apiKey":"t212-key","apiSecret":"t212-secret"}"#, account: "live.credentials.v2", accessible: false)
        XCTAssertEqual(itemCount(service: service), 5)

        let folync = FolyncCredentialStore(service: service)
        let marketData = MarketDataKeyStore(service: service)
        let trading212 = Trading212CredentialStore(service: service)

        // Before anything is read, the stores already report what is stored.
        XCTAssertTrue(folync.hasToken())
        XCTAssertEqual(trading212.storageState(environment: .live), .currentSingleItem)
        XCTAssertEqual(trading212.storageState(environment: .demo), .notStored)

        XCTAssertEqual(try folync.load(for: "https://folync.example/api"), "folync-token")
        XCTAssertEqual(try folync.savedServer(), "https://folync.example:443")
        XCTAssertEqual(try marketData.load(.fmp), "fmp-key")
        XCTAssertEqual(try marketData.load(.twelveData), "twelve-key")
        XCTAssertEqual(
            try trading212.load(environment: .live),
            Trading212AuthConfiguration(apiKey: "t212-key", apiSecret: "t212-secret")
        )

        XCTAssertEqual(itemCount(service: service), 0, "The old items are removed once imported.")
        XCTAssertEqual(itemCount(service: "\(service).combined"), 1)

        // What a later launch reads from the Keychain.
        vault.forgetCachedContents()
        XCTAssertEqual(try vault.values(), [
            "folync.token": "folync-token",
            "folync.server": "https://folync.example:443",
            "marketdata.fmp": "fmp-key",
            "marketdata.twelveData": "twelve-key",
            "trading212.live.apiKey": "t212-key",
            "trading212.live.apiSecret": "t212-secret"
        ])
        XCTAssertTrue(folync.hasToken())
        XCTAssertEqual(trading212.storageState(environment: .live), .currentSingleItem)
    }

    func testATokenStoredWithoutItsServerIsImportedWithoutOne() throws {
        try saveLegacy("folync-token", account: "client-api-token.v1", accessible: true)
        let store = FolyncCredentialStore(service: service)

        XCTAssertEqual(try store.load(), "folync-token")
        XCTAssertNil(try store.savedServer())
        XCTAssertThrowsError(try store.load(for: "https://folync.example")) { error in
            XCTAssertEqual(error as? FolyncCredentialStoreError, .savedForAnotherServer)
        }

        store.recordServerIfMissing("https://folync.example")
        XCTAssertEqual(try store.load(for: "https://folync.example"), "folync-token")
    }

    /// If an old item cannot be turned into values, nothing is written and
    /// every old item of the group stays where it was.
    func testNothingIsRemovedWhenAnImportFails() throws {
        try saveLegacy("folync-token", account: "client-api-token.v1", accessible: true)
        try saveLegacy("https://folync.example:443", account: "client-api-token-server.v1", accessible: true)
        let token = LegacyKeychainItem(service: service, account: "client-api-token.v1", setsAccessible: true)
        let server = LegacyKeychainItem(service: service, account: "client-api-token-server.v1", setsAccessible: true)
        struct Refused: Error {}

        XCTAssertThrowsError(
            try vault.importLegacy(into: ["folync.token", "folync.server"]) {
                [.text(token, key: "folync.token"), LegacyCredentialSource(item: server) { _ in throw Refused() }]
            }
        ) { XCTAssertTrue($0 is Refused) }

        XCTAssertEqual(itemCount(service: service), 2)
        XCTAssertEqual(itemCount(service: "\(service).combined"), 0)

        // The next attempt, with nothing in the way, imports both.
        let store = FolyncCredentialStore(service: service)
        XCTAssertEqual(try store.load(for: "https://folync.example"), "folync-token")
        XCTAssertEqual(itemCount(service: service), 0)
    }

    func testUnreadableTrading212ItemIsReportedAndKept() throws {
        try saveLegacy("not json", account: "demo.credentials.v2", accessible: false)
        let store = Trading212CredentialStore(service: service)

        XCTAssertThrowsError(try store.load(environment: .demo)) { error in
            guard case Trading212CredentialStoreError.invalidStoredCredentials = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(itemCount(service: service), 1)
    }

    /// A value saved by this version is newer than an old item that was left
    /// behind; the old item is removed without replacing it.
    func testAnOldItemNeverReplacesWhatTheVaultHolds() throws {
        try writeVaultItem(["folync.token": "current-token"])
        try saveLegacy("old-token", account: "client-api-token.v1", accessible: true)
        try saveLegacy("https://old.example:443", account: "client-api-token-server.v1", accessible: true)
        let store = FolyncCredentialStore(service: service)

        XCTAssertEqual(try store.load(), "current-token")
        XCTAssertNil(try store.savedServer(), "The old server must not be paired with the newer token.")
        XCTAssertEqual(itemCount(service: service), 0)
    }

    func testSavingReplacesAnOldItemThatWasNeverImported() throws {
        try saveLegacy("old-key", account: "fmp-api-key.v1", accessible: true)
        let store = MarketDataKeyStore(service: service)

        try store.save("new-key", for: .fmp)

        XCTAssertEqual(try store.load(.fmp), "new-key")
        XCTAssertEqual(itemCount(service: service), 0)
    }

    func testDeletingRemovesAnOldItemThatWasNeverImported() throws {
        try saveLegacy("folync-token", account: "client-api-token.v1", accessible: true)
        try saveLegacy("https://folync.example:443", account: "client-api-token-server.v1", accessible: true)
        let store = FolyncCredentialStore(service: service)

        try store.delete()

        XCTAssertFalse(store.hasToken())
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? FolyncCredentialStoreError, .missingToken)
        }
        XCTAssertEqual(itemCount(service: service), 0)
        XCTAssertEqual(itemCount(service: "\(service).combined"), 0)
    }

    // MARK: Keychain helpers

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?] = []

        var values: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func add(_ value: String?) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }
    }

    /// Writes an item the way an earlier version did.
    private func saveLegacy(_ value: String, account: String, accessible: Bool) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        if accessible {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
    }

    /// Replaces the vault's item behind its back, as another process would.
    private func writeVaultItem(_ values: [String: String]) throws {
        removeEveryItem(service: "\(service).combined")
        let contents: [String: Any] = ["version": 1, "values": values]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).combined",
            kSecAttrAccount as String: "credentials.v1",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONSerialization.data(withJSONObject: contents),
            kSecAttrGeneric as String: try JSONEncoder().encode(values.keys.sorted())
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        vault.forgetCachedContents()
    }

    private func itemCount(service: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess else { return 0 }
        return (items as? [[String: Any]])?.count ?? 0
    }

    private func removeEveryItem(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        while SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }
}
