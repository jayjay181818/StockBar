import Foundation

/// Manages secure local storage of configuration data like API keys
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
    
    /// Loads configuration from the local file
    private func loadConfiguration() -> [String: String] {
        guard let configFileURL = getConfigFileURL(),
              fileManager.fileExists(atPath: configFileURL.path) else {
            return [:]
        }
        
        do {
            let data = try Data(contentsOf: configFileURL)
            let config = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] ?? [:]
            return config
        } catch {
            Task { await Logger.shared.error("Failed to load configuration: \(error.localizedDescription)") }
            return [:]
        }
    }
    
    /// Saves configuration to the local file
    private func saveConfiguration(_ config: [String: String]) {
        guard let configFileURL = getConfigFileURL() else {
            Task { await Logger.shared.error("Could not get configuration file URL") }
            return
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try data.write(to: configFileURL)
            Task { await Logger.shared.debug("Configuration saved to \(configFileURL.path)") }
        } catch {
            Task { await Logger.shared.error("Failed to save configuration: \(error.localizedDescription)") }
        }
    }
    
    /// Gets the FMP API key from local storage
    public func getFMPAPIKey() -> String? {
        let config = loadConfiguration()
        return config["FMP_API_KEY"]
    }
    
    /// Sets the FMP API key in local storage
    public func setFMPAPIKey(_ apiKey: String) {
        var config = loadConfiguration()
        config["FMP_API_KEY"] = apiKey
        saveConfiguration(config)
        Task { await Logger.shared.info("FMP API key updated") }
    }
    
    /// Removes the FMP API key from local storage
    public func removeFMPAPIKey() {
        var config = loadConfiguration()
        config.removeValue(forKey: "FMP_API_KEY")
        saveConfiguration(config)
        Task { await Logger.shared.info("FMP API key removed") }
    }
    
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
        guard let configFileURL = getConfigFileURL() else { return }
        
        let sampleConfig = [
            "FMP_API_KEY": "your_api_key_here",
            "_README": "This file stores your API keys securely. Get your free FMP API key from https://financialmodelingprep.com/"
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: sampleConfig, options: .prettyPrinted)
            try data.write(to: configFileURL)
            Task { await Logger.shared.info("Sample configuration file created at \(configFileURL.path)") }
        } catch {
            Task { await Logger.shared.error("Failed to create sample configuration file: \(error.localizedDescription)") }
        }
    }
}