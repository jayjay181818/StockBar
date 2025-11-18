import Foundation

/// Manages storage of configuration data like API keys
/// Uses plain-text JSON file storage in user's Documents directory
public class ConfigurationManager {
    public static let shared = ConfigurationManager()
    private let fileManager = FileManager.default

    private init() {}

    /// Gets the configuration file URL in the user's Documents directory
    private func getConfigFileURL() -> URL? {
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsPath.appendingPathComponent(".stockbar_config.json")
    }

    // MARK: - Generic Helper

    private func getConfig() -> [String: Any] {
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
        guard let configFileURL = getConfigFileURL() else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFileURL, options: .atomic)
            Task { await Logger.shared.info("Configuration updated successfully") }
        } catch {
            Task { await Logger.shared.error("Failed to save configuration: \(error.localizedDescription)") }
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
