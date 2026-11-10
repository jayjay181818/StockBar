import Foundation

/// Manages storage of configuration data like API keys
/// Uses local app support JSON storage for non-broker market-data settings.
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    /// Set only for isolated tests; production uses Application Support.
    private let directoryOverride: URL?

    private init() {
        directoryOverride = nil
    }

    /// A manager whose file lives in `directory`. For isolated tests.
    init(directory: URL) {
        directoryOverride = directory
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

    /// This file holds FMP and Twelve Data API keys in plaintext — it has to stay
    /// readable by the Python subprocess, so the Keychain is not an option — but
    /// it should not inherit a world-readable umask.
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
    
    // MARK: - FMP API Key

    /// Gets the FMP API key from configuration file
    public func getFMPAPIKey() -> String? {
        return getConfig()["FMP_API_KEY"] as? String
    }

    /// Sets the FMP API key in configuration file
    public func setFMPAPIKey(_ apiKey: String) {
        updateConfig { config in
            config["FMP_API_KEY"] = apiKey
        }
    }

    /// Removes the FMP API key from configuration file
    public func removeFMPAPIKey() {
        updateConfig { config in
            config.removeValue(forKey: "FMP_API_KEY")
        }
    }
    
    // MARK: - Twelve Data API Key
    
    /// Gets the Twelve Data API key from configuration file
    public func getTwelveDataAPIKey() -> String? {
        return getConfig()["TWELVE_DATA_API_KEY"] as? String
    }

    /// Sets the Twelve Data API key in configuration file
    public func setTwelveDataAPIKey(_ apiKey: String) {
        updateConfig { config in
            config["TWELVE_DATA_API_KEY"] = apiKey
        }
    }
    
    /// Removes the Twelve Data API key from configuration file
    public func removeTwelveDataAPIKey() {
        updateConfig { config in
            config.removeValue(forKey: "TWELVE_DATA_API_KEY")
        }
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
    /// cannot be read, rather than exporting nothing. Placeholder sample keys
    /// are left out.
    func exportableValues() throws -> ConfigurationTransferValues {
        lock.lock()
        defer { lock.unlock() }
        guard let config = try readConfigForTransfer() else {
            return ConfigurationTransferValues(fmpAPIKey: nil, twelveDataAPIKey: nil, dataSourcePriority: nil)
        }
        func key(_ name: String, placeholder: String) -> String? {
            guard let value = (config[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != placeholder else { return nil }
            return value
        }
        return ConfigurationTransferValues(
            fmpAPIKey: key("FMP_API_KEY", placeholder: "your_fmp_api_key_here"),
            twelveDataAPIKey: key("TWELVE_DATA_API_KEY", placeholder: "your_twelve_data_api_key_here"),
            dataSourcePriority: config["DATA_SOURCE_PRIORITY"] as? [String]
        )
    }

    /// The file's exact bytes, or nil when there is none, so an import can put it back unchanged.
    func configurationFileContents() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Restores bytes from `configurationFileContents()`; nil removes the file.
    func restoreConfigurationFile(_ contents: Data?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        guard let contents else {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            return
        }
        try contents.write(to: url, options: .atomic)
        restrictPermissions(of: url)
    }

    /// Applies imported values in one write and throws instead of logging, so
    /// an import can roll back. Nil API keys are left as they are; a nil
    /// priority removes the setting so the default order applies.
    func applyImportedValues(fmpAPIKey: String?, twelveDataAPIKey: String?, dataSourcePriority: [String]?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let url = getConfigFileURL() else { throw CocoaError(.fileNoSuchFile) }
        let existing = try readConfigForTransfer()
        guard existing != nil || fmpAPIKey != nil || twelveDataAPIKey != nil || dataSourcePriority != nil else {
            return
        }
        var config = existing ?? [:]
        if let fmpAPIKey { config["FMP_API_KEY"] = fmpAPIKey }
        if let twelveDataAPIKey { config["TWELVE_DATA_API_KEY"] = twelveDataAPIKey }
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

    /// Checks if the configuration file exists
    public func configFileExists() -> Bool {
        guard let configFileURL = getConfigFileURL() else { return false }
        return fileManager.fileExists(atPath: configFileURL.path)
    }

    /// Creates a sample configuration file with instructions
    public func createSampleConfigFile() {
        guard let configFileURL = getConfigFileURL() else {
            Task { await Logger.shared.error("Failed to get configuration file URL") }
            return
        }

        let sampleConfig: [String: Any] = [
            "FMP_API_KEY": "your_fmp_api_key_here",
            "TWELVE_DATA_API_KEY": "your_twelve_data_api_key_here",
            "DATA_SOURCE_PRIORITY": ["yfinance", "fmp", "twelvedata"],
            "_comment": "Replace 'your_api_key_here' with your actual API keys. DATA_SOURCE_PRIORITY determines the order of fetch attempts."
        ]

        saveConfig(sampleConfig)
        Task { await Logger.shared.info("Sample configuration file created at: \(configFileURL.path)") }
    }
}

/// Market-data values carried by a settings export.
struct ConfigurationTransferValues: Equatable, Sendable {
    let fmpAPIKey: String?
    let twelveDataAPIKey: String?
    let dataSourcePriority: [String]?
}
