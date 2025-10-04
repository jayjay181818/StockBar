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

    // MARK: - Public API

    /// Gets the FMP API key from configuration file
    public func getFMPAPIKey() -> String? {
        guard let configFileURL = getConfigFileURL(),
              fileManager.fileExists(atPath: configFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: configFileURL)
            let config = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] ?? [:]
            return config["FMP_API_KEY"]
        } catch {
            Task { await Logger.shared.error("Failed to load configuration: \(error.localizedDescription)") }
            return nil
        }
    }

    /// Sets the FMP API key in configuration file
    public func setFMPAPIKey(_ apiKey: String) {
        guard let configFileURL = getConfigFileURL() else {
            Task { await Logger.shared.error("Failed to get configuration file URL") }
            return
        }

        // Load existing config or create new one
        var config: [String: String] = [:]
        if fileManager.fileExists(atPath: configFileURL.path) {
            do {
                let data = try Data(contentsOf: configFileURL)
                config = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] ?? [:]
            } catch {
                Task { await Logger.shared.warning("Failed to load existing config, creating new: \(error.localizedDescription)") }
            }
        }

        // Update API key
        config["FMP_API_KEY"] = apiKey

        // Save config
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try data.write(to: configFileURL, options: .atomic)
            Task { await Logger.shared.info("FMP API key updated successfully") }
        } catch {
            Task { await Logger.shared.error("Failed to save configuration: \(error.localizedDescription)") }
        }
    }

    /// Removes the FMP API key from configuration file
    public func removeFMPAPIKey() {
        guard let configFileURL = getConfigFileURL(),
              fileManager.fileExists(atPath: configFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: configFileURL)
            var config = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] ?? [:]
            config.removeValue(forKey: "FMP_API_KEY")

            if config.isEmpty {
                // Remove file if empty
                try fileManager.removeItem(at: configFileURL)
                Task { await Logger.shared.info("Configuration file removed (was empty)") }
            } else {
                // Save updated config
                let newData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
                try newData.write(to: configFileURL, options: .atomic)
                Task { await Logger.shared.info("FMP API key removed") }
            }
        } catch {
            Task { await Logger.shared.error("Failed to remove API key: \(error.localizedDescription)") }
        }
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
        guard let configFileURL = getConfigFileURL() else {
            Task { await Logger.shared.error("Failed to get configuration file URL") }
            return
        }

        let sampleConfig: [String: String] = [
            "FMP_API_KEY": "your_api_key_here",
            "_comment": "Replace 'your_api_key_here' with your actual Financial Modeling Prep API key"
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: sampleConfig, options: .prettyPrinted)
            try data.write(to: configFileURL, options: .atomic)
            Task { await Logger.shared.info("Sample configuration file created at: \(configFileURL.path)") }
        } catch {
            Task { await Logger.shared.error("Failed to create sample configuration file: \(error.localizedDescription)") }
        }
    }
}
