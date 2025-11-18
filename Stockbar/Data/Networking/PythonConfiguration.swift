//
//  PythonConfiguration.swift
//  Stockbar
//
//  Manages configuration for the Python runtime environment,
//  including interpreter path discovery and validation.
//

import Foundation

struct PythonConfiguration {
    // MARK: - Properties
    
    /// Path to the Python interpreter (e.g. /usr/bin/python3, /opt/homebrew/bin/python3)
    let interpreterPath: String
    
    /// Environment variables to pass to the process
    let environment: [String: String]
    
    /// The default interpreter path if none is configured
    static let defaultInterpreterPath = "/usr/bin/python3"
    
    // MARK: - Initialization
    
    init(interpreterPath: String = PythonConfiguration.defaultInterpreterPath,
         environment: [String: String] = [:]) {
        self.interpreterPath = interpreterPath
        self.environment = environment
    }
    
    /// Loads configuration from UserDefaults or environment, falling back to defaults
    static func load() -> PythonConfiguration {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "pythonInterpreterPath") ?? defaultInterpreterPath
        
        // We could also load environment overrides here if needed
        return PythonConfiguration(interpreterPath: path)
    }
    
    /// Saves the configuration to UserDefaults
    func save() {
        UserDefaults.standard.set(interpreterPath, forKey: "pythonInterpreterPath")
    }
    
    // MARK: - Validation
    
    /// Checks if the interpreter exists and is executable
    func validate() async -> Bool {
        let fileManager = FileManager.default
        
        // Check file existence
        guard fileManager.fileExists(atPath: interpreterPath) else {
            await Logger.shared.error("Python interpreter not found at \(interpreterPath)")
            return false
        }
        
        // Check executability
        guard fileManager.isExecutableFile(atPath: interpreterPath) else {
            await Logger.shared.error("Python interpreter at \(interpreterPath) is not executable")
            return false
        }
        
        // Optional: Try running a version check
        return await testExecution()
    }
    
    /// Runs a simple execution test (python3 --version)
    private func testExecution() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreterPath)
        process.arguments = ["--version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // Some pythons output version to stderr
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if process.terminationStatus == 0 && output.lowercased().contains("python") {
                await Logger.shared.info("Python environment verified: \(output)")
                return true
            } else {
                await Logger.shared.warning("Python version check failed. Status: \(process.terminationStatus), Output: \(output)")
                return false
            }
        } catch {
            await Logger.shared.error("Failed to launch Python for verification: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Validates a stock symbol to prevent command injection
    /// Allows A-Z, 0-9, dots, carets, equals, hyphens.
    static func validateSymbol(_ symbol: String) -> Bool {
        // Allow basic alphanumeric, plus common ticker symbols (e.g. ^GSPC, BRK.B, USD=X)
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.^=-")
        return symbol.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }
    
    /// Sanitizes a symbol for safe command line usage
    static func sanitizeSymbol(_ symbol: String) -> String {
        // Uppercase and filter only allowed characters
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.^=-"
        return symbol.uppercased().filter { allowed.contains($0) }
    }
}

