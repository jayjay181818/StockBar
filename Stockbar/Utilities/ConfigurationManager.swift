import Foundation

/// Manages storage of configuration data like API keys
/// Uses local app support JSON storage for non-broker market-data settings.
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()

    private init() {}

    /// Gets the configuration file URL in Stockbar's Application Support directory.
    private func getConfigFileURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let directory = StockbarRuntimeStorage.bundleApplicationSupportDirectory(fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let canonicalURL = directory.appendingPathComponent(".stockbar_config.json")
            migrateLegacyConfigIfNeeded(to: canonicalURL)
            return canonicalURL
        } catch {
            Task { await Logger.shared.error("Failed to create configuration directory: \(error.localizedDescription)") }
        }

        if StockbarRuntimeStorage.acceptance.isEnabled { return nil }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".stockbar_config.json")
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
        var config = getConfig()
        config["FMP_API_KEY"] = apiKey
        saveConfig(config)
    }

    /// Removes the FMP API key from configuration file
    public func removeFMPAPIKey() {
        var config = getConfig()
        config.removeValue(forKey: "FMP_API_KEY")
        saveConfig(config)
    }
    
    // MARK: - Twelve Data API Key
    
    /// Gets the Twelve Data API key from configuration file
    public func getTwelveDataAPIKey() -> String? {
        return getConfig()["TWELVE_DATA_API_KEY"] as? String
    }

    /// Sets the Twelve Data API key in configuration file
    public func setTwelveDataAPIKey(_ apiKey: String) {
        var config = getConfig()
        config["TWELVE_DATA_API_KEY"] = apiKey
        saveConfig(config)
    }
    
    /// Removes the Twelve Data API key from configuration file
    public func removeTwelveDataAPIKey() {
        var config = getConfig()
        config.removeValue(forKey: "TWELVE_DATA_API_KEY")
        saveConfig(config)
    }
    
    // MARK: - Data Source Priority
    
    /// Gets the data source priority list
    public func getDataSourcePriority() -> [String]? {
        return getConfig()["DATA_SOURCE_PRIORITY"] as? [String]
    }
    
    /// Sets the data source priority list
    public func setDataSourcePriority(_ priority: [String]) {
        var config = getConfig()
        config["DATA_SOURCE_PRIORITY"] = priority
        saveConfig(config)
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
            "DATA_SOURCE_PRIORITY": ["yfinance", "fmp", "twelvedata", "stooq"],
            "_comment": "Replace 'your_api_key_here' with your actual API keys. DATA_SOURCE_PRIORITY determines the order of fetch attempts."
        ]

        saveConfig(sampleConfig)
        Task { await Logger.shared.info("Sample configuration file created at: \(configFileURL.path)") }
    }
}
