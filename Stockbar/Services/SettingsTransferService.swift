import Foundation

struct SettingsTransferAppInfo: Equatable, Sendable {
    let version: String
    let build: String
    let macOSVersion: String

    static var current: SettingsTransferAppInfo {
        let info = Bundle.main.infoDictionary
        return SettingsTransferAppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "Unknown",
            build: info?["CFBundleVersion"] as? String ?? "Unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

/// Everything the transfer reads and writes. `live` resolves each location
/// through `StockbarRuntimeStorage` and the existing credential stores, so an
/// acceptance or XCTest run never touches production data or Keychain items.
struct SettingsTransferDependencies: Sendable {
    /// Returns the defaults domain to use (UserDefaults itself is not Sendable).
    var defaults: @Sendable () -> UserDefaults
    var configuration: ConfigurationManager
    var trading212Credentials: Trading212CredentialStore
    var folyncCredentials: FolyncCredentialStore
    var brokerLinksURL: URL
    /// Private working directory for database copies; emptied after each use.
    var stagingRoot: URL
    /// `StoreRecovery`, where pre-import safety copies of the store are kept.
    var recoveryRoot: URL
    var storeHost: (any SettingsTransferStoreHost)?
    var appInfo: SettingsTransferAppInfo
    var now: @Sendable () -> Date = { Date() }

    static var live: SettingsTransferDependencies {
        SettingsTransferDependencies(
            defaults: { StockbarRuntimeStorage.userDefaults },
            configuration: .shared,
            trading212Credentials: .shared,
            folyncCredentials: .shared,
            brokerLinksURL: BrokerLinkStore.defaultFileURL(),
            stagingRoot: StockbarRuntimeStorage.stockbarApplicationSupportDirectory()
                .appendingPathComponent("TransferStaging", isDirectory: true),
            recoveryRoot: StockbarRuntimeStorage.bundleApplicationSupportDirectory()
                .appendingPathComponent("StoreRecovery", isDirectory: true),
            storeHost: CoreDataStack.shared,
            appInfo: .current
        )
    }
}

/// A decrypted, fully validated import waiting for confirmation. A database
/// is already staged and checked against this app's model.
final class PreparedSettingsImport: Sendable {
    let preview: SettingsTransferPreview
    let settings: [String: SettingsTransferValue]
    let dataSourcePriority: [String]?
    let credentials: SettingsTransferCredentials
    let databaseState: [String: SettingsTransferValue]
    let brokerLinks: Data?
    let stagedStoreURL: URL?
    private let stagingDirectory: URL?

    init(
        preview: SettingsTransferPreview,
        settings: [String: SettingsTransferValue],
        dataSourcePriority: [String]?,
        credentials: SettingsTransferCredentials,
        databaseState: [String: SettingsTransferValue],
        brokerLinks: Data?,
        stagedStoreURL: URL?,
        stagingDirectory: URL?
    ) {
        self.preview = preview
        self.settings = settings
        self.dataSourcePriority = dataSourcePriority
        self.credentials = credentials
        self.databaseState = databaseState
        self.brokerLinks = brokerLinks
        self.stagedStoreURL = stagedStoreURL
        self.stagingDirectory = stagingDirectory
    }

    var includesDatabase: Bool { stagedStoreURL != nil }

    /// Removes the staged database copy.
    func discard() {
        guard let stagingDirectory else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    deinit {
        discard()
    }
}

/// Exports and imports Stockbar's settings, credentials and (for Everything)
/// its portfolio database as one encrypted file. Work runs off the main actor;
/// nothing secret or decrypted is logged or written to disk unencrypted, apart
/// from the database copy Core Data needs as a file, which stays in a private
/// staging directory beside the live store and is removed straight after.
final class SettingsTransferService: Sendable {
    let dependencies: SettingsTransferDependencies

    init(dependencies: SettingsTransferDependencies = .live) {
        self.dependencies = dependencies
    }

    private var defaults: UserDefaults { dependencies.defaults() }

    /// Size the database adds to an Everything export, or nil when there is no SQLite store.
    func estimatedDatabaseBytes() -> Int64? {
        guard let storeURL = dependencies.storeHost?.transferStoreURL else { return nil }
        return CoreDataStoreTransfer.totalFileSize(of: storeURL) + Self.fileSize(of: dependencies.brokerLinksURL)
    }

    // MARK: - Export

    @concurrent
    func export(
        _ type: SettingsTransferExportType,
        password: String,
        to destination: URL
    ) async throws -> SettingsTransferManifest {
        guard password.count >= SettingsTransferContainer.minimumPasswordLength else {
            throw SettingsTransferError.passwordTooShort
        }
        let settings = readDefaults(SettingsTransferKeys.settingsKeys)
        let configuration: ConfigurationTransferValues
        do {
            configuration = try dependencies.configuration.exportableValues()
        } catch is MarketDataKeyStoreError {
            throw SettingsTransferError.credentialUnreadable("market-data API keys")
        } catch {
            throw SettingsTransferError.backupFailed("Stockbar couldn't read its market-data settings file.")
        }
        let credentials = try readCredentials(fmp: configuration.fmpAPIKey, twelveData: configuration.twelveDataAPIKey)
        let database = type == .everything ? try readDatabase() : nil

        let manifest = SettingsTransferManifest(
            exportType: type,
            createdAt: dependencies.now(),
            appVersion: dependencies.appInfo.version,
            appBuild: dependencies.appInfo.build,
            macOSVersion: dependencies.appInfo.macOSVersion,
            settingsCount: settings.count,
            credentialCount: credentials.names.count,
            databaseBytes: database?.byteCount
        )
        let payload = SettingsTransferPayload(
            manifest: manifest,
            settings: settings,
            dataSourcePriority: configuration.dataSourcePriority,
            credentials: credentials,
            database: database
        )
        var plaintext = try payload.encoded()
        defer { plaintext.zeroBytes() }
        let sealed = try SettingsTransferContainer.seal(plaintext, password: password)
        try sealed.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        await Logger.shared.info(
            "Settings export written: type=\(type.rawValue) settings=\(settings.count) "
            + "credentials=\(credentials.names.count) database=\(database != nil)"
        )
        return manifest
    }

    private func readDefaults(_ keys: [String: SettingsTransferValueKind]) -> [String: SettingsTransferValue] {
        var values: [String: SettingsTransferValue] = [:]
        for (key, kind) in keys {
            guard let raw = defaults.object(forKey: key),
                  let value = SettingsTransferValue(defaultsValue: raw),
                  kind.accepts(value) else { continue }
            values[key] = value
        }
        return values
    }

    private func readCredentials(fmp: String?, twelveData: String?) throws -> SettingsTransferCredentials {
        var credentials = SettingsTransferCredentials(fmpAPIKey: fmp, twelveDataAPIKey: twelveData)
        let trading212 = dependencies.trading212Credentials
        for environment in Trading212Environment.allCases where trading212.hasCredentials(environment: environment) {
            do {
                let stored = try trading212.load(environment: environment)
                credentials.trading212[environment.rawValue] = SettingsTransferTrading212Credential(
                    apiKey: stored.apiKey,
                    apiSecret: stored.apiSecret
                )
            } catch {
                throw SettingsTransferError.credentialUnreadable("Trading 212 credentials (\(environment.displayName))")
            }
        }
        let folync = dependencies.folyncCredentials
        if folync.hasToken() {
            let baseURL = currentFolyncBaseURL()
            folync.recordServerIfMissing(baseURL)
            do {
                credentials.folyncClientToken = try folync.load(for: baseURL)
            } catch FolyncCredentialStoreError.savedForAnotherServer {
                // Left out: an import pairs the token with the exported
                // address, and this token belongs to a different server.
            } catch {
                throw SettingsTransferError.credentialUnreadable("Folync client token")
            }
        }
        return credentials
    }

    private func currentFolyncBaseURL() -> String {
        FolyncSettingsStore(defaults: defaults).load().baseURL
    }

    private func readDatabase() throws -> SettingsTransferDatabase {
        guard let host = dependencies.storeHost, let storeURL = host.transferStoreURL else {
            throw SettingsTransferError.databaseUnavailable
        }
        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let copyURL = staging.appendingPathComponent(storeURL.lastPathComponent)
        try CoreDataStoreTransfer.copyStore(from: storeURL, to: copyURL, model: host.transferModel)
        let files = try CoreDataStoreTransfer.readStoreFiles(at: copyURL)
        let brokerLinksURL = dependencies.brokerLinksURL
        let brokerLinks = FileManager.default.fileExists(atPath: brokerLinksURL.path)
            ? try Data(contentsOf: brokerLinksURL)
            : nil
        return SettingsTransferDatabase(
            storeFiles: files,
            brokerLinks: brokerLinks,
            state: readDefaults(SettingsTransferKeys.databaseStateKeys)
        )
    }

    // MARK: - Import: read and validate

    /// Checks the file is a Stockbar export this version can read, before
    /// asking for a password.
    @concurrent
    func checkImportFile(at source: URL) async throws {
        try SettingsTransferContainer.validateHeader(try Data(contentsOf: source))
    }

    /// Decrypts and validates everything without changing anything.
    @concurrent
    func prepareImport(from source: URL, password: String) async throws -> PreparedSettingsImport {
        let data = try Data(contentsOf: source)
        var plaintext = try SettingsTransferContainer.open(data, password: password)
        defer { plaintext.zeroBytes() }
        let payload = try SettingsTransferPayload.decode(plaintext)

        guard (payload.manifest.exportType == .everything) == (payload.database != nil) else {
            throw SettingsTransferError.unsupportedContents("its contents don't match its type.")
        }
        var settings = try Self.validated(payload.settings, allowed: SettingsTransferKeys.settingsKeys)
        var keepsDestructiveOptionsOff = false
        for key in SettingsTransferKeys.destructiveOptionKeys
        where settings.values[key]?.readsAsTrue == true && !defaults.bool(forKey: key) {
            settings.values[key] = .bool(false)
            keepsDestructiveOptionsOff = true
        }
        let credentials = try Self.validated(payload.credentials)
        let priority = Self.validated(priority: payload.dataSourcePriority)

        var databaseState: [String: SettingsTransferValue] = [:]
        var summary: SettingsTransferPreview.DatabaseSummary?
        var stagedStoreURL: URL?
        var stagingDirectory: URL?
        if let database = payload.database {
            databaseState = try Self.validated(database.state, allowed: SettingsTransferKeys.databaseStateKeys).values
            if let brokerLinks = database.brokerLinks {
                try Self.validateBrokerLinks(brokerLinks)
            }
            guard let host = dependencies.storeHost, let liveURL = host.transferStoreURL else {
                throw SettingsTransferError.databaseUnavailable
            }
            let staging = try makeStagingDirectory()
            do {
                let stagedURL = staging.appendingPathComponent(liveURL.lastPathComponent)
                try CoreDataStoreTransfer.writeStoreFiles(database.storeFiles, to: stagedURL)
                let counts = try CoreDataStoreTransfer.validateStore(at: stagedURL, model: host.transferModel)
                summary = SettingsTransferPreview.DatabaseSummary(
                    byteCount: database.byteCount,
                    tradeCount: counts.tradeCount,
                    portfolioSnapshotCount: counts.portfolioSnapshotCount,
                    priceSnapshotCount: counts.priceSnapshotCount,
                    includesBrokerLinks: database.brokerLinks != nil
                )
                stagedStoreURL = stagedURL
                stagingDirectory = staging
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }

        let preview = SettingsTransferPreview(
            manifest: payload.manifest,
            settingsCount: settings.values.count,
            ignoredSettingsCount: settings.ignored,
            keepsDestructiveOptionsOff: keepsDestructiveOptionsOff,
            includesDataSourcePriority: priority != nil,
            credentialNames: credentials.names,
            database: summary
        )
        return PreparedSettingsImport(
            preview: preview,
            settings: settings.values,
            dataSourcePriority: priority,
            credentials: credentials,
            databaseState: databaseState,
            brokerLinks: payload.database?.brokerLinks,
            stagedStoreURL: stagedStoreURL,
            stagingDirectory: stagingDirectory
        )
    }

    /// Keeps allowlisted keys with the expected kind. Unknown keys (from a
    /// newer Stockbar) are ignored and counted; a known key with the wrong
    /// kind rejects the file.
    private static func validated(
        _ values: [String: SettingsTransferValue],
        allowed: [String: SettingsTransferValueKind]
    ) throws -> (values: [String: SettingsTransferValue], ignored: Int) {
        var kept: [String: SettingsTransferValue] = [:]
        var ignored = 0
        for (key, value) in values {
            guard let kind = allowed[key] else {
                ignored += 1
                continue
            }
            guard kind.accepts(value) else {
                throw SettingsTransferError.unsupportedContents("a setting has an unexpected type.")
            }
            guard let range = SettingsTransferKeys.numberRanges[key] else {
                kept[key] = value
                continue
            }
            guard let limited = value.limited(to: range) else {
                throw SettingsTransferError.unsupportedContents("a setting is not a usable number.")
            }
            kept[key] = limited
        }
        return (kept, ignored)
    }

    private static func validated(_ credentials: SettingsTransferCredentials) throws -> SettingsTransferCredentials {
        func isBlank(_ value: String?) -> Bool {
            value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
        guard !isBlank(credentials.fmpAPIKey),
              !isBlank(credentials.twelveDataAPIKey),
              !isBlank(credentials.folyncClientToken) else {
            throw SettingsTransferError.unsupportedContents("a stored key is empty.")
        }
        for (environment, credential) in credentials.trading212 {
            guard Trading212Environment(rawValue: environment) != nil else {
                throw SettingsTransferError.unsupportedContents("it has Trading 212 credentials for an unknown environment.")
            }
            let auth = Trading212AuthConfiguration(apiKey: credential.apiKey, apiSecret: credential.apiSecret)
            guard (try? Trading212AuthHeaderBuilder().authorizationHeader(for: auth.normalized)) != nil else {
                throw SettingsTransferError.unsupportedContents("its Trading 212 credentials are incomplete.")
            }
        }
        return credentials
    }

    /// Drops unknown or repeated provider names; nil when nothing usable is left.
    private static func validated(priority: [String]?) -> [String]? {
        guard let priority else { return nil }
        var seen = Set<String>()
        let kept = priority.filter { SettingsTransferKeys.allowedDataSources.contains($0) && seen.insert($0).inserted }
        return kept.isEmpty ? nil : kept
    }

    private static func validateBrokerLinks(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(BrokerLinkStoreSnapshot.self, from: data)) != nil else {
            throw SettingsTransferError.damagedDatabase
        }
    }

    // MARK: - Import: apply

    /// Applies a prepared import, all or nothing. Before an Everything import
    /// replaces the database, `backUpPortfolio` runs the existing portfolio
    /// backup and a Core Data safety copy of the current store is made. On
    /// success, a replaced store stays read-only until Stockbar relaunches.
    @concurrent
    func apply(
        _ prepared: PreparedSettingsImport,
        backUpPortfolio: @escaping @Sendable () async -> Bool
    ) async throws {
        var rollback = try captureRollbackState(for: prepared)
        var liveStoreURL: URL?
        var safetyCopyURL: URL?
        let host = dependencies.storeHost

        if prepared.stagedStoreURL != nil {
            guard let host, let storeURL = host.transferStoreURL else {
                throw SettingsTransferError.databaseUnavailable
            }
            guard await backUpPortfolio() else {
                throw SettingsTransferError.backupFailed("The portfolio backup failed. See Diagnostics for details.")
            }
            host.setTransferWritesSuspended(true)
            do {
                safetyCopyURL = try CoreDataStoreRecovery(recoveryRoot: dependencies.recoveryRoot)
                    .createPreImportSafetyCopy(of: storeURL, model: host.transferModel)
            } catch {
                host.setTransferWritesSuspended(false)
                throw SettingsTransferError.backupFailed("The safety copy of the portfolio database failed.")
            }
            liveStoreURL = storeURL
        }

        do {
            writeDefaults(prepared.settings, allowed: SettingsTransferKeys.settingsKeys)
            try writeKeychainCredentials(prepared.credentials)
            try dependencies.configuration.applyImportedValues(
                fmpAPIKey: prepared.credentials.fmpAPIKey,
                twelveDataAPIKey: prepared.credentials.twelveDataAPIKey,
                dataSourcePriority: prepared.dataSourcePriority
            )
            if let stagedStoreURL = prepared.stagedStoreURL, let liveStoreURL, let host {
                writeDefaults(prepared.databaseState, allowed: SettingsTransferKeys.databaseStateKeys)
                // Set first: a replacement that fails halfway must also be undone.
                rollback.restoreStoreFrom = safetyCopyURL
                try CoreDataStoreTransfer.copyStore(from: stagedStoreURL, to: liveStoreURL, model: host.transferModel)
                try Self.writeFile(prepared.brokerLinks, to: dependencies.brokerLinksURL)
            }
        } catch {
            let restoredEverything = restore(rollback, liveStoreURL: liveStoreURL)
            // If the rollback was incomplete the store stays read-only until
            // relaunch, so nothing builds on a half-restored database.
            if liveStoreURL != nil, restoredEverything { host?.setTransferWritesSuspended(false) }
            await Logger.shared.error(
                "Settings import failed and was rolled back (complete=\(restoredEverything)): \(type(of: error))"
            )
            throw restoredEverything
                ? SettingsTransferError.applyFailed
                : SettingsTransferError.applyFailedPartlyRestored(includesDatabase: liveStoreURL != nil)
        }

        prepared.discard()
        await Logger.shared.info(
            "Settings import applied: settings=\(prepared.settings.count) "
            + "credentials=\(prepared.credentials.names.count) database=\(prepared.includesDatabase)"
        )
    }

    private func writeDefaults(_ values: [String: SettingsTransferValue], allowed: [String: SettingsTransferValueKind]) {
        for key in allowed.keys {
            if let value = values[key] {
                defaults.set(value.defaultsValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Replaces only the Keychain credentials present in the file.
    private func writeKeychainCredentials(_ credentials: SettingsTransferCredentials) throws {
        for environment in Trading212Environment.allCases {
            guard let credential = credentials.trading212[environment.rawValue] else { continue }
            try dependencies.trading212Credentials.save(
                Trading212AuthConfiguration(apiKey: credential.apiKey, apiSecret: credential.apiSecret),
                environment: environment
            )
        }
        // Runs after the settings are written, so the token is stored for the
        // imported Folync address. A file that changes the address without
        // bringing a token leaves the existing token tied to its old server.
        if let token = credentials.folyncClientToken {
            try dependencies.folyncCredentials.save(token: token, for: currentFolyncBaseURL())
        }
    }

    // MARK: - Rollback

    private struct RollbackState {
        var defaults: [String: Any] = [:]
        var defaultsKeys: [String] = []
        /// Previous credentials for each environment in the file; nil was absent.
        var trading212: [Trading212Environment: Trading212AuthConfiguration?] = [:]
        /// Outer nil: not in the file. Inner nil: no token before.
        var folyncToken: String??
        var folyncTokenServer: String?
        var configuration: ConfigurationRollbackState?
        var brokerLinks: Data?
        var includesDatabase = false
        var restoreStoreFrom: URL?
    }

    /// Reads the current value of everything the import may change. Fails
    /// before anything changes if a current credential cannot be read.
    private func captureRollbackState(for prepared: PreparedSettingsImport) throws -> RollbackState {
        var state = RollbackState()
        var keys = Array(SettingsTransferKeys.settingsKeys.keys)
        if prepared.includesDatabase {
            keys += SettingsTransferKeys.databaseStateKeys.keys
        }
        state.defaultsKeys = keys
        for key in keys {
            if let value = defaults.object(forKey: key) { state.defaults[key] = value }
        }
        try captureCredentials(for: prepared.credentials, into: &state)
        do {
            state.configuration = try dependencies.configuration.rollbackState()
        } catch is MarketDataKeyStoreError {
            throw SettingsTransferError.credentialUnreadable("current market-data API keys")
        } catch {
            throw SettingsTransferError.backupFailed("Stockbar couldn't read the current settings files.")
        }
        do {
            if prepared.includesDatabase {
                state.includesDatabase = true
                let url = dependencies.brokerLinksURL
                state.brokerLinks = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            }
        } catch {
            throw SettingsTransferError.backupFailed("Stockbar couldn't read the current settings files.")
        }
        return state
    }

    /// Current values of the Keychain credentials the file will replace.
    private func captureCredentials(for imported: SettingsTransferCredentials, into state: inout RollbackState) throws {
        // A token from an earlier version has no server recorded. Record the
        // address in use now, before the import can replace it.
        dependencies.folyncCredentials.recordServerIfMissing(currentFolyncBaseURL())
        let trading212 = dependencies.trading212Credentials
        for environment in Trading212Environment.allCases where imported.trading212[environment.rawValue] != nil {
            guard trading212.hasCredentials(environment: environment) else {
                state.trading212[environment] = .some(nil)
                continue
            }
            do {
                state.trading212[environment] = try trading212.load(environment: environment)
            } catch {
                throw SettingsTransferError.credentialUnreadable("current Trading 212 credentials (\(environment.displayName))")
            }
        }
        guard imported.folyncClientToken != nil else { return }
        guard dependencies.folyncCredentials.hasToken() else {
            state.folyncToken = .some(nil)
            return
        }
        do {
            state.folyncToken = .some(try dependencies.folyncCredentials.load())
            state.folyncTokenServer = try dependencies.folyncCredentials.savedServer()
        } catch {
            throw SettingsTransferError.credentialUnreadable("current Folync client token")
        }
    }

    /// Puts back the captured state. Returns false if any part failed.
    private func restore(_ state: RollbackState, liveStoreURL: URL?) -> Bool {
        var complete = true
        for key in state.defaultsKeys {
            if let value = state.defaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        complete = restoreCredentials(state) && complete
        if let configuration = state.configuration {
            do {
                try dependencies.configuration.restore(configuration)
            } catch {
                complete = false
            }
        }
        if state.includesDatabase {
            do {
                try Self.writeFile(state.brokerLinks, to: dependencies.brokerLinksURL)
            } catch {
                complete = false
            }
        }
        if let safetyCopy = state.restoreStoreFrom, let liveStoreURL, let host = dependencies.storeHost {
            do {
                try CoreDataStoreTransfer.copyStore(from: safetyCopy, to: liveStoreURL, model: host.transferModel)
            } catch {
                complete = false
            }
        }
        return complete
    }

    private func restoreCredentials(_ state: RollbackState) -> Bool {
        var complete = true
        for (environment, previous) in state.trading212 {
            do {
                if let previous {
                    try dependencies.trading212Credentials.save(previous, environment: environment)
                } else {
                    try dependencies.trading212Credentials.delete(environment: environment)
                }
            } catch {
                complete = false
            }
        }
        if let previous = state.folyncToken {
            do {
                if let previous {
                    try dependencies.folyncCredentials.save(token: previous, server: state.folyncTokenServer)
                } else {
                    try dependencies.folyncCredentials.delete()
                }
            } catch {
                complete = false
            }
        }
        return complete
    }

    // MARK: - Files

    /// Removes database copies left behind when Stockbar quit or crashed in
    /// the middle of an export or import. Called once at launch, before either
    /// can start.
    func removeLeftoverStagedFiles() {
        let fileManager = FileManager.default
        guard let leftovers = try? fileManager.contentsOfDirectory(
            at: dependencies.stagingRoot, includingPropertiesForKeys: nil
        ) else { return }
        for url in leftovers {
            try? fileManager.removeItem(at: url)
        }
    }

    private func makeStagingDirectory() throws -> URL {
        let directory = dependencies.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// Writes `data` atomically, or removes the file for nil.
    private static func writeFile(_ data: Data?, to url: URL) throws {
        guard let data else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func fileSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
