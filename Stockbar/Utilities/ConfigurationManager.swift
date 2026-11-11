import Foundation

/// Market-data settings: the FMP and Twelve Data API keys, kept in the
/// Keychain, and the provider order, kept in a JSON file in Application
/// Support that the Python helper also reads.
///
/// Key calls can wait on a Keychain prompt, so make them off the main actor.
/// They use their own lock, never taken while the file lock is held, so a
/// pending prompt does not hold up the file settings.
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()
    private let fileManager = FileManager.default
    /// Guards the configuration file.
    private let lock = NSRecursiveLock()
    /// Guards Keychain access, the key cache and the move out of the file.
    private let keyLock = NSRecursiveLock()
    /// Set only for isolated tests; production uses Application Support.
    private let directoryOverride: URL?
    private let keyStore: MarketDataKeyStore
    /// Keys read this session, so each Python run does not ask the Keychain.
    /// A missing entry has not been read; a nil value means none is stored.
    private var cachedKeys: [MarketDataAPIKey: String?] = [:]
    private var fileKeysMoved = false
    private var fileMoveFailureLogged = false

    private init() {
        directoryOverride = nil
        keyStore = .shared
    }

    /// A manager whose file lives in `directory` and whose keys use `keyStore`. For isolated tests.
    init(directory: URL, keyStore: MarketDataKeyStore) {
        directoryOverride = directory
        self.keyStore = keyStore
    }

    /// Gets the configuration file URL in Stockbar's Application Support directory.
    private func getConfigFileURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let directory = directoryOverride
            ?? StockbarRuntimeStorage.bundleApplicationSupportDirectory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let canonicalURL = directory.appendingPathComponent(".stockbar_config.json")
            if directoryOverride == nil {
                migrateLegacyConfigIfNeeded(to: canonicalURL)
            }
            return canonicalURL
        } catch {
            Task { await Logger.shared.error("Failed to create configuration directory: \(error.localizedDescription)") }
        }

        // No fallback to a dot-file in the home folder: settings would be split
        // between two places and the second is never backed up or cleaned.
        return nil
    }

    // MARK: - Generic Helper

    private func getConfig() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let configFileURL = getConfigFileURL(),
              fileManager.fileExists(atPath: configFileURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: configFileURL)
            return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
        } catch {
            Task { await Logger.shared.error("Failed to load configuration: \(error.localizedDescription)") }
            return [:]
        }
    }

    /// Reads, changes and saves the config under one lock. A file that exists
    /// but cannot be parsed is copied aside first, so saving one key never
    /// silently discards the others.
    private func updateConfig(_ change: (inout [String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let configFileURL = getConfigFileURL(),
           fileManager.fileExists(atPath: configFileURL.path),
           !configFileIsReadable(configFileURL) {
            let backupURL = configFileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            do {
                try fileManager.copyItem(at: configFileURL, to: backupURL)
                restrictPermissions(of: backupURL)
                Task { await Logger.shared.error("Configuration file could not be read; kept a copy at \(backupURL.lastPathComponent)") }
            } catch {
                Task { await Logger.shared.error("Configuration file could not be read or backed up; not saving: \(error.localizedDescription)") }
                return
            }
        }
        var config = getConfig()
        change(&config)
        saveConfig(config)
    }

    private func configFileIsReadable(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) is [String: Any]
    }

    private func saveConfig(_ config: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard let configFileURL = getConfigFileURL() else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFileURL, options: .atomic)
            restrictPermissions(of: configFileURL)
            Task { await Logger.shared.info("Configuration updated successfully") }
        } catch {
            Task { await Logger.shared.error("Failed to save configuration: \(error.localizedDescription)") }
        }
    }

    /// The file holds no keys now, but earlier versions wrote them here and a
    /// file not yet moved may still have them. Either way it should not
    /// inherit a world-readable umask.
    private func restrictPermissions(of url: URL) {
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Task {
                await Logger.shared.warning(
                    "Could not restrict permissions on the configuration file: \(error.localizedDescription)"
                )
            }
        }
    }

    private func migrateLegacyConfigIfNeeded(to canonicalURL: URL) {
        guard !StockbarRuntimeStorage.acceptance.isEnabled,
              !fileManager.fileExists(atPath: canonicalURL.path) else {
            return
        }
        let legacyURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.fhl43211.Stockbar", isDirectory: true)
            .appendingPathComponent(".stockbar_config.json")
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }

        do {
            let data = try Data(contentsOf: legacyURL)
            guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try data.write(to: canonicalURL, options: .atomic)
            restrictPermissions(of: canonicalURL)
            Task {
                await Logger.shared.info(
                    "Copied validated legacy configuration to com.stockbar; original preserved at \(legacyURL.path)"
                )
            }
        } catch {
            Task {
                await Logger.shared.warning(
                    "Legacy configuration was preserved but not copied because validation failed: \(error.localizedDescription)"
                )
            }
        }
    }
    
    // MARK: - API Keys

    /// Gets the FMP API key, or nil when none is stored or the Keychain can't be read.
    public func getFMPAPIKey() -> String? { apiKey(.fmp) }

    public func setFMPAPIKey(_ apiKey: String) throws { try setAPIKey(apiKey, for: .fmp) }

    public func removeFMPAPIKey() throws { try removeAPIKey(.fmp) }

    /// Gets the Twelve Data API key, or nil when none is stored or the Keychain can't be read.
    public func getTwelveDataAPIKey() -> String? { apiKey(.twelveData) }

    public func setTwelveDataAPIKey(_ apiKey: String) throws { try setAPIKey(apiKey, for: .twelveData) }

    public func removeTwelveDataAPIKey() throws { try removeAPIKey(.twelveData) }

    func apiKey(_ key: MarketDataAPIKey) -> String? {
        do {
            return try storedAPIKey(key)
        } catch {
            Task { await Logger.shared.error("Could not read the \(key.configName) from the Keychain: \(error.localizedDescription)") }
            return nil
        }
    }

    func setAPIKey(_ value: String, for key: MarketDataAPIKey) throws {
        keyLock.lock()
        defer { keyLock.unlock() }
        moveFileKeysToKeychainIfNeeded()
        try keyStore.save(value, for: key)
        cachedKeys[key] = .some(value)
        dropUnmovedFileKey(key)
    }

    func removeAPIKey(_ key: MarketDataAPIKey) throws {
        keyLock.lock()
        defer { keyLock.unlock() }
        moveFileKeysToKeychainIfNeeded()
        try keyStore.delete(key)
        cachedKeys[key] = .some(nil)
        dropUnmovedFileKey(key)
    }

    /// The stored key, after moving any key earlier versions left in the file.
    /// While that move keeps failing, the key still in the file is the one in use.
    func storedAPIKey(_ key: MarketDataAPIKey) throws -> String? {
        keyLock.lock()
        defer { keyLock.unlock() }
        moveFileKeysToKeychainIfNeeded()
        if let cached = cachedKeys[key] { return cached }
        if !fileKeysMoved, let fileValue = fileKeyValue(key, in: getConfig()) { return fileValue }
        let value = try keyStore.load(key)
        cachedKeys[key] = .some(value)
        return value
    }

    private func fileKeyValue(_ key: MarketDataAPIKey, in config: [String: Any]) -> String? {
        guard let value = (config[key.configName] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != key.placeholder else { return nil }
        return value
    }

    /// After a key was saved or removed while the move out of the file is
    /// still failing, the file's old copy must not come back on the next try.
    /// Caller holds `keyLock`.
    private func dropUnmovedFileKey(_ key: MarketDataAPIKey) {
        guard !fileKeysMoved, getConfig()[key.configName] != nil else { return }
        updateConfig { $0.removeValue(forKey: key.configName) }
    }

    /// Environment variables carrying the stored keys to the Python helper.
    /// A key that can't be read is left out, so the helper skips that provider.
    func scriptEnvironmentKeys() -> [String: String] {
        var environment: [String: String] = [:]
        for key in MarketDataAPIKey.allCases {
            if let value = apiKey(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                environment[key.configName] = value
            }
        }
        return environment
    }

    /// Earlier versions kept the keys in the configuration file. Moves them
    /// to the Keychain and then removes them from the file. A key in the file
    /// replaces one in the Keychain: it can only have been written by an
    /// earlier version or by hand since. Nothing is removed from the file
    /// unless every key in it was stored. Caller holds `keyLock`.
    private func moveFileKeysToKeychainIfNeeded() {
        guard !fileKeysMoved else { return }
        let config = getConfig()
        let namesInFile = MarketDataAPIKey.allCases.filter { config[$0.configName] != nil }
        guard !namesInFile.isEmpty else {
            fileKeysMoved = true
            return
        }
        do {
            for key in namesInFile {
                guard let value = fileKeyValue(key, in: config) else { continue }
                try keyStore.save(value, for: key)
                cachedKeys[key] = .some(value)
            }
        } catch {
            if !fileMoveFailureLogged {
                fileMoveFailureLogged = true
                Task { await Logger.shared.error("Could not move the market-data API keys to the Keychain; they stay in the configuration file for now: \(error.localizedDescription)") }
            }
            return
        }
        updateConfig { config in
            for key in namesInFile { config.removeValue(forKey: key.configName) }
        }
        fileKeysMoved = true
        Task { await Logger.shared.info("Moved the market-data API keys from the configuration file to the Keychain") }
    }

    // MARK: - Data Source Priority
    
    /// Gets the data source priority list
    public func getDataSourcePriority() -> [String]? {
        return getConfig()["DATA_SOURCE_PRIORITY"] as? [String]
    }
    
    /// Sets the data source priority list
    public func setDataSourcePriority(_ priority: [String]) {
        updateConfig { config in
            config["DATA_SOURCE_PRIORITY"] = priority
        }
    }

    // MARK: - Settings Transfer

    /// Values a settings export carries. Throws when the file exists but
    /// cannot be read, or a key can't be read from the Keychain, rather than
    /// exporting nothing. Placeholder sample keys are left out.
    func exportableValues() throws -> ConfigurationTransferValues {
        func key(_ key: MarketDataAPIKey) throws -> String? {
            guard let value = try storedAPIKey(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != key.placeholder else { return nil }
            return value
        }
        let fmp = try key(.fmp)
        let twelveData = try key(.twelveData)
        lock.lock()
        defer { lock.unlock() }
        let config = try readConfigForTransfer()
        return ConfigurationTransferValues(
            fmpAPIKey: fmp,
            twelveDataAPIKey: twelveData,
            dataSourcePriority: config?["DATA_SOURCE_PRIORITY"] as? [String]
        )
    }

    /// Everything an import may change, so it can be put back unchanged:
    /// the file's exact bytes (nil when there is none) and the stored keys.
    func rollbackState() throws -> ConfigurationRollbackState {
        var keys: [MarketDataAPIKey: String] = [:]
        for key in MarketDataAPIKey.allCases {
            if let value = try storedAPIKey(key) { keys[key] = value }
        }
        lock.lock()
        defer { lock.unlock() }
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        let file = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        return ConfigurationRollbackState(file: file, keys: keys)
    }

    /// Puts back a `rollbackState()`. Tries every part and throws the first failure.
    func restore(_ state: ConfigurationRollbackState) throws {
        var firstError: Error?
        keyLock.lock()
        for key in MarketDataAPIKey.allCases {
            do {
                if let value = state.keys[key] {
                    try keyStore.save(value, for: key)
                } else {
                    try keyStore.delete(key)
                }
                cachedKeys[key] = .some(state.keys[key])
            } catch {
                cachedKeys.removeValue(forKey: key)
                firstError = firstError ?? error
            }
        }
        keyLock.unlock()
        do {
            lock.lock()
            defer { lock.unlock() }
            guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
            if let contents = state.file {
                try contents.write(to: url, options: .atomic)
                restrictPermissions(of: url)
            } else if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
    }

    /// Applies imported values and throws instead of logging, so an import
    /// can roll back. Nil API keys are left as they are; a nil priority
    /// removes the setting so the default order applies.
    func applyImportedValues(fmpAPIKey: String?, twelveDataAPIKey: String?, dataSourcePriority: [String]?) throws {
        if let fmpAPIKey { try setAPIKey(fmpAPIKey, for: .fmp) }
        if let twelveDataAPIKey { try setAPIKey(twelveDataAPIKey, for: .twelveData) }
        lock.lock()
        defer { lock.unlock() }
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        let existing = try readConfigForTransfer()
        guard existing != nil || dataSourcePriority != nil else { return }
        var config = existing ?? [:]
        if let dataSourcePriority {
            config["DATA_SOURCE_PRIORITY"] = dataSourcePriority
        } else {
            config.removeValue(forKey: "DATA_SOURCE_PRIORITY")
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        restrictPermissions(of: url)
    }

    private func readConfigForTransfer() throws -> [String: Any]? {
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return config
    }

    // MARK: - File Management

    /// Gets the configuration file path for display
    public func getConfigFilePath() -> String? {
        return getConfigFileURL()?.path
    }
}

/// Market-data values carried by a settings export.
struct ConfigurationTransferValues: Equatable, Sendable {
    let fmpAPIKey: String?
    let twelveDataAPIKey: String?
    let dataSourcePriority: [String]?
}

/// What `ConfigurationManager.restore(_:)` puts back after a failed import.
struct ConfigurationRollbackState: Sendable {
    let file: Data?
    let keys: [MarketDataAPIKey: String]
}
