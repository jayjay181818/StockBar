//
//  PythonConfiguration.swift
//  Stockbar
//
//  Manages configuration for the Python runtime environment,
//  including interpreter path discovery and validation.
//

import Foundation

struct PythonConfiguration: Sendable {
    // MARK: - Properties
    
    /// Path to the Python interpreter: Stockbar's own environment unless the
    /// `pythonInterpreterPath` setting names another one.
    let interpreterPath: String
    
    /// Environment variables to pass to the process
    let environment: [String: String]
    
    /// Stockbar's own Python environment, created by `script/setup_python_env.sh`
    /// with a current Python and the pinned requirements.
    static func managedInterpreterPath() -> String {
        StockbarRuntimeStorage.stockbarApplicationSupportDirectory()
            .appendingPathComponent("python-env/bin/python3").path
    }

    /// An explicit `pythonInterpreterPath` setting wins; otherwise Stockbar's own
    /// environment, even before it is set up. There is no system-Python
    /// fallback: Apple's /usr/bin/python3 3.9 cannot run the pinned packages.
    static func resolveInterpreterPath(configured: String?, managedInterpreter: String) -> String {
        if let configured, !configured.isEmpty { return configured }
        return managedInterpreter
    }
    
    // MARK: - Initialization
    
    init(interpreterPath: String = PythonConfiguration.managedInterpreterPath(),
         environment: [String: String] = [:]) {
        self.interpreterPath = interpreterPath
        self.environment = environment
    }
    
    /// Loads configuration from UserDefaults or environment, falling back to defaults
    static func load() -> PythonConfiguration {
        let defaults = StockbarRuntimeStorage.userDefaults
        let path = resolveInterpreterPath(
            configured: defaults.string(forKey: "pythonInterpreterPath"),
            managedInterpreter: managedInterpreterPath()
        )
        var environment: [String: String] = [:]
        if let configPath = ConfigurationManager.shared.getConfigFilePath() {
            environment["STOCKBAR_CONFIG_FILE"] = configPath
        }
        // Quote cache lives in the (acceptance-aware) app cache folder rather
        // than the home directory; the script migrates a legacy file once.
        environment["STOCKBAR_CACHE_FILE"] = StockbarRuntimeStorage.cacheDirectory()
            .appendingPathComponent("quote_cache.json").path
        let refreshInterval = RefreshService.clampedRefreshInterval(
            defaults.object(forKey: "refreshInterval") as? TimeInterval
        )
        environment["STOCKBAR_QUOTE_CACHE_SECONDS"] = String(Int(quoteCacheSeconds(forRefreshInterval: refreshInterval)))
        
        return PythonConfiguration(interpreterPath: path, environment: environment)
    }
    
    /// Variables of the app's own environment that the scripts may see: enough
    /// to find files, resolve names and reach the network through a proxy.
    /// Everything else, notably `PYTHONPATH`, `PYTHONHOME` and `PYTHONSTARTUP`,
    /// stays out so nothing in the user's shell set-up can change what runs.
    static let inheritedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "TZ", "LANG", "LC_ALL", "LC_CTYPE",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        "FMP_API_KEY", "TWELVE_DATA_API_KEY", "STOCKBAR_DEBUG_LOGGING"
    ]

    /// The complete environment for a script process.
    static func childEnvironment(
        adding extra: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base.filter { inheritedEnvironmentKeys.contains($0.key) }
        // Packages installed with `pip install --user` must not shadow the pinned ones.
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        extra.forEach { environment[$0.key] = $0.value }
        return environment
    }

    /// The script's quote cache must not outlive the user's refresh interval,
    /// otherwise a shorter interval only re-reads cached quotes.
    static func quoteCacheSeconds(forRefreshInterval interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 300 }
        return min(300, max(15, (interval * 0.9).rounded(.down)))
    }

    /// Saves the configuration to UserDefaults
    func save() {
        StockbarRuntimeStorage.userDefaults.set(interpreterPath, forKey: "pythonInterpreterPath")
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
        do {
            try StockbarProviderAccessPolicy.current.authorize(.python)
        } catch {
            await Logger.shared.warning("Python validation blocked: \(error.localizedDescription)")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreterPath)
        process.arguments = ["--version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe // Some pythons output version to stderr
        
        do {
            // Waits on the exit callback, not `waitUntilExit`, which would hold a
            // thread of the shared pool for as long as the interpreter takes.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }

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
    
    private static let allowedSymbolCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.^=-"

    /// Validates a stock symbol before it is passed to the Python bridge.
    ///
    /// Symbols become `argv` entries, so no shell is involved — but they are
    /// parsed by `argparse`, which treats a leading `-` as a flag. A symbol like
    /// `--start-date` would consume the next symbol as its value, and an
    /// unrecognised flag makes argparse exit(2), failing the whole batch rather
    /// than one ticker. Empty strings are rejected for the same reason.
    ///
    /// Allows A-Z, 0-9, dots, carets, equals, hyphens (e.g. ^GSPC, BRK.B, USD=X).
    static func validateSymbol(_ symbol: String) -> Bool {
        guard !symbol.isEmpty, !symbol.hasPrefix("-") else { return false }
        let allowedCharacters = CharacterSet(charactersIn: allowedSymbolCharacters)
        return symbol.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    /// Sanitizes a symbol for safe command line usage.
    /// Returns nil when nothing usable survives, so callers must decide what to
    /// do rather than silently passing an empty argument.
    static func sanitizeSymbol(_ symbol: String) -> String? {
        var sanitized = symbol.uppercased().filter { allowedSymbolCharacters.contains($0) }
        // Strip leading hyphens so the result can never look like a flag.
        while sanitized.hasPrefix("-") {
            sanitized.removeFirst()
        }
        return sanitized.isEmpty ? nil : sanitized
    }
}
