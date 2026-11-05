// Stockbar/Stockbar/Networking/NetworkService.swift
// --- FIXED FILE ---

import Foundation
// Removed OSLog import to avoid conflict with custom Logger

// Keep the original protocol for compatibility
protocol NetworkService: Sendable {
    func fetchQuote(for symbol: String) async throws -> StockFetchResult
    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult]
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot]
    func fetchOHLCData(for symbol: String, period: String, interval: String) async throws -> [OHLCSnapshot]
    func fetchBatchOHLCData(for symbols: [String], period: String, interval: String) async throws -> [String: [OHLCSnapshot]]
    func verifyAPIKey(service: String) async throws -> Bool
}

// MARK: - Network Error Enum (Extended for script execution)
enum NetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse(String? = nil)
    case httpError(Int)
    case noData(String? = nil)
    case scriptExecutionError(String)
    case pythonInterpreterNotFound(String)
    case scriptNotFound(String)
    case rateLimit(retryAfter: Int?)
    case invalidSymbol(String)
    case networkError(String)
    case apiKeyInvalid
    case apiKeyRestricted
    case timeout(String)
    case unknownError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse(let details):
            return "Invalid response from script: \(details ?? "Could not parse")"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .noData(let details):
            return "No data received: \(details ?? "Script returned empty or failed")"
        case .scriptExecutionError(let details):
            return "Python script execution failed: \(details)"
        case .pythonInterpreterNotFound(let path):
            if path == PythonConfiguration.managedInterpreterPath() {
                return "Stockbar's own Python is not set up. Open Settings > Advanced > Python and choose Set Up."
            }
            return "Python interpreter not found at \(path). Install Python 3.10 or later there, or change the pythonInterpreterPath setting."
        case .scriptNotFound(let name):
            return "Python script '\(name)' not found in the app bundle."
        case .rateLimit(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limit exceeded. Please try again in \(seconds) seconds."
            }
            return "Rate limit exceeded. Please try again later."
        case .invalidSymbol(let symbol):
            return "Invalid or unknown symbol: \(symbol)"
        case .networkError(let details):
            return "Network error: \(details)"
        case .apiKeyInvalid:
            return "API key is invalid or unauthorized. Please check your configuration."
        case .apiKeyRestricted:
            return "API key valid but plan restricted. This data requires a higher tier FMP plan (e.g. for international exchanges)."
        case .timeout(let details):
            return "Request timed out: \(details)"
        case .unknownError(let details):
            return "Unexpected error: \(details)"
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .invalidURL:
            return "Configuration error. Please contact support."
        case .invalidResponse:
            return "Unable to parse market data. Please try again."
        case .httpError:
            return "Server error. Please try again later."
        case .noData:
            return "No market data available. Check symbol or try again."
        case .scriptExecutionError:
            return "Data fetch failed. Please try again."
        case .pythonInterpreterNotFound:
            return "Python not found. Please reinstall the app."
        case .scriptNotFound:
            return "Data script missing. Please reinstall the app."
        case .rateLimit(let retryAfter):
            if let seconds = retryAfter, seconds < 120 {
                return "Rate limit reached. Retry in \(seconds)s."
            }
            return "Rate limit reached. Please wait a few minutes."
        case .invalidSymbol(let symbol):
            return "Unknown symbol '\(symbol)'. Check spelling and try again."
        case .networkError:
            return "Network connection error. Check your internet connection."
        case .apiKeyInvalid:
            return "API key invalid. Please update in Preferences."
        case .apiKeyRestricted:
            return "Plan restriction. Upgrade FMP plan for this data."
        case .timeout:
            return "Request timed out. Try again or check your connection."
        case .unknownError:
            return "Unexpected error occurred. Please try again."
        }
    }
}

// MARK: - Python Script Service
actor PythonNetworkService: NetworkService {
    private let logger = Logger.shared // Assumes Logger.swift (or similar) provides this
    private let scriptName = "get_stock_data.py"
    private let scriptPathOverride: String?
    /// Pinned configuration (tests); nil means settings are reloaded when needed so
    /// interpreter changes made after launch are honoured.
    private let pinnedConfig: PythonConfiguration?
    private var config: PythonConfiguration { pinnedConfig ?? .load() }
    private let processRunner: any PythonProcessRunning
    private var didLogNotOpenSSLWarning = false

    init(
        config: PythonConfiguration? = nil,
        processRunner: (any PythonProcessRunning)? = nil,
        scriptPath: String? = nil
    ) {
        self.pinnedConfig = config
        self.processRunner = processRunner ?? PythonProcessRunner(config: config)
        self.scriptPathOverride = scriptPath
    }

    /// Parse JSON error from Python script output
    private func parseError(from output: String) throws {
        guard let jsonData = output.data(using: .utf8) else {
            throw NetworkError.invalidResponse("Could not convert output to data")
        }

        do {
            if let errorObj = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
               let isError = errorObj["error"] as? Bool,
               isError,
               let errorCode = errorObj["error_code"] as? String,
               let message = errorObj["message"] as? String {

                Task { await logger.warning("Python script returned error: \(errorCode) - \(message)") }

                switch errorCode {
                case "RATE_LIMIT":
                    let retryAfter = errorObj["retry_after"] as? Int
                    throw NetworkError.rateLimit(retryAfter: retryAfter)
                case "INVALID_SYMBOL":
                    let symbol = errorObj["symbol"] as? String ?? "unknown"
                    throw NetworkError.invalidSymbol(symbol)
                case "NETWORK_ERROR":
                    throw NetworkError.networkError(message)
                case "API_KEY_INVALID":
                    throw NetworkError.apiKeyInvalid
                case "API_KEY_RESTRICTED":
                    throw NetworkError.apiKeyRestricted
                case "TIMEOUT":
                    throw NetworkError.timeout(message)
                case "NO_DATA":
                    throw NetworkError.noData(message)
                default:
                    throw NetworkError.unknownError(message)
                }
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            // Not a JSON error, continue with normal parsing
        }
    }

    private func runPythonProcess(
        arguments: [String],
        timeoutSeconds: TimeInterval,
        logContext: String
    ) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let result = try await processRunner.run(
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            logContext: logContext
        )
        await logProcessDiagnostics(result, context: logContext)
        return (result.stdout, result.stderr, result.exitCode)
    }

    private func logProcessDiagnostics(_ result: PythonProcessResult, context: String) async {
        let diagnostics = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !diagnostics.isEmpty else { return }

        if diagnostics.contains("NotOpenSSLWarning"), !didLogNotOpenSSLWarning {
            didLogNotOpenSSLWarning = true
            await logger.debug("Python LibreSSL compatibility warning observed once this launch")
        }

        let lines = diagnostics
            .components(separatedBy: .newlines)
            .filter { !$0.contains("NotOpenSSLWarning") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else { return }

        if result.exitCode != 0 {
            await logger.error("\(context) exited \(result.exitCode): \(lines)")
        } else if Self.containsProviderWarning(lines) {
            await logger.warning("\(context): \(lines)")
        } else {
            await logger.debug("\(context): \(lines)")
        }
    }

    private static func containsProviderWarning(_ diagnostics: String) -> Bool {
        let value = diagnostics.lowercased()
        return value.contains("rate limit")
            || value.contains("http error")
            || value.contains("forbidden")
            || value.contains("api key invalid")
            || value.contains("unauthorized")
    }

    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        guard let result = try await fetchBatchQuotes(for: [symbol]).first,
              result.regularMarketPrice.isFinite,
              result.regularMarketPreviousClose.isFinite else {
            throw NetworkError.noData("No valid quote returned for \(symbol)")
        }
        return result
    }
    
    /// Enhanced fetch quote with pre/post market data support
    func fetchEnhancedQuote(for symbol: String) async throws -> StockFetchResult {
        try await fetchQuote(for: symbol)
    }
    
    private func parseEnhancedQuoteData(_ data: [String: Any], symbol: String) throws -> StockFetchResult {
        guard let displayPrice = data["price"] as? Double,
              let previousClose = data["previousClose"] as? Double,
              let timestamp = data["timestamp"] as? TimeInterval,
              displayPrice.isFinite,
              displayPrice > 0,
              previousClose.isFinite,
              previousClose > 0,
              timestamp.isFinite,
              timestamp > 0 else {
            throw NetworkError.invalidResponse("Missing required fields in enhanced quote data")
        }
        
        // If regularMarketPrice is not available (e.g., FMP fallback), use displayPrice
        let regularMarketPrice = data["regularMarketPrice"] as? Double ?? displayPrice
        guard regularMarketPrice.isFinite, regularMarketPrice > 0 else {
            throw NetworkError.invalidResponse("Invalid regular market price in enhanced quote data")
        }
        
        let preMarketPrice = data["preMarketPrice"] as? Double
        let postMarketPrice = data["postMarketPrice"] as? Double
        let preMarketTime = data["preMarketTime"] as? Int
        let postMarketTime = data["postMarketTime"] as? Int
        let marketStateString = data["marketState"] as? String

        // Parse market state
        let marketState: MarketState?
        if let stateString = marketStateString {
            marketState = MarketState(rawValue: stateString)
        } else {
            marketState = nil
        }

        // Calculate pre/post market changes if we have the data
        var preMarketChange: Double?
        var preMarketChangePercent: Double?
        var postMarketChange: Double?
        var postMarketChangePercent: Double?

        if let prePrice = preMarketPrice {
            preMarketChange = prePrice - previousClose
            preMarketChangePercent = previousClose > 0 ? (preMarketChange! / previousClose) * 100 : 0
        }

        if let postPrice = postMarketPrice {
            postMarketChange = postPrice - previousClose
            postMarketChangePercent = previousClose > 0 ? (postMarketChange! / previousClose) * 100 : 0
        }

        // Detect currency and timezone
        let rawCurrency = data["currency"] as? String
        let detectedCurrency = SymbolMetadata.normalizeCurrency(rawCurrency) ?? SymbolMetadata.defaultCurrency(for: symbol)
        let timezone = SymbolMetadata.defaultTimezone(for: symbol)

        Task { await logger.debug("Fetched quote for \(symbol): state=\(marketStateString ?? "nil")") }

        return StockFetchResult(
            currency: detectedCurrency,
            symbol: symbol,
            shortName: symbol,
            regularMarketTime: Int(timestamp),
            exchangeTimezoneName: timezone,
            regularMarketPrice: regularMarketPrice,
            regularMarketPreviousClose: previousClose,
            displayPrice: displayPrice,
            preMarketPrice: preMarketPrice,
            preMarketChange: preMarketChange,
            preMarketChangePercent: preMarketChangePercent,
            preMarketTime: preMarketTime,  // Use specific pre-market timestamp
            postMarketPrice: postMarketPrice,
            postMarketChange: postMarketChange,
            postMarketChangePercent: postMarketChangePercent,
            postMarketTime: postMarketTime,  // Use specific post-market timestamp
            marketState: marketState
        )
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        guard !symbols.isEmpty else { return [] }
        guard let scriptPath = scriptPathOverride ?? Bundle.main.path(
            forResource: scriptName.replacingOccurrences(of: ".py", with: ""),
            ofType: "py"
        ) else {
            throw NetworkError.scriptNotFound(scriptName)
        }
        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }

        // Drop anything argparse could misread as a flag. One bad ticker would
        // otherwise fail the whole batch, not just itself.
        let safeSymbols = symbols.filter { PythonConfiguration.validateSymbol($0) }
        if safeSymbols.count != symbols.count {
            let rejected = symbols.filter { !PythonConfiguration.validateSymbol($0) }
            await logger.warning("Skipping \(rejected.count) invalid symbol(s) in quote batch: \(rejected)")
        }
        guard !safeSymbols.isEmpty else { return [] }

        let timeout = min(300, max(30, 20 + (Double(safeSymbols.count) * 5)))
        let (stdout, _, _) = try await runPythonProcess(
            arguments: [scriptPath, "--json"] + safeSymbols,
            timeoutSeconds: timeout,
            logContext: "Quote batch (\(safeSymbols.count) symbols)"
        )
        let output = String(decoding: stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw NetworkError.noData("Quote process returned no structured output")
        }

        try parseError(from: output)
        guard let data = output.data(using: .utf8),
              let envelopes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NetworkError.invalidResponse("Quote response was not a JSON array")
        }

        let envelopeBySymbol = Dictionary(
            envelopes.map { envelope in
                ((envelope["symbol"] as? String ?? "").uppercased(), envelope)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return symbols.map { symbol in
            let envelope = envelopeBySymbol[symbol.uppercased()]
            guard envelope?["success"] as? Bool == true,
                  let quote = envelope?["quote"] as? [String: Any],
                  let parsed = try? parseEnhancedQuoteData(quote, symbol: symbol) else {
                return placeholderQuote(for: symbol)
            }
            return parsed
        }
    }

    private func placeholderQuote(for symbol: String) -> StockFetchResult {
        StockFetchResult(
            currency: SymbolMetadata.defaultCurrency(for: symbol),
            symbol: symbol,
            shortName: symbol,
            regularMarketTime: Int(Date().timeIntervalSince1970),
            exchangeTimezoneName: SymbolMetadata.defaultTimezone(for: symbol),
            regularMarketPrice: .nan,
            regularMarketPreviousClose: .nan,
            displayPrice: .nan,
            preMarketPrice: nil,
            preMarketChange: nil,
            preMarketChangePercent: nil,
            preMarketTime: nil,
            postMarketPrice: nil,
            postMarketChange: nil,
            postMarketChangePercent: nil,
            postMarketTime: nil,
            marketState: nil
        )
    }
    
    /// `YYYY-MM-DD` for the Python `--start-date`/`--end-date` arguments. Pinned to the
    /// POSIX locale and Gregorian calendar so the user's calendar (Buddhist, Japanese,
    /// Hijri...) or locale numerals can never change what the script receives.
    static func scriptDateString(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        await logger.debug("Python historical fetch starting for \(symbol)")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        await logger.debug("Python historical range: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        
        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        
        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            let error = NetworkError.pythonInterpreterNotFound(config.interpreterPath)
            await logger.error(error.localizedDescription)
            throw error
        }

        guard PythonConfiguration.validateSymbol(symbol) else {
            await logger.warning("Rejecting invalid symbol for historical fetch: \(symbol)")
            throw NetworkError.invalidResponse("Invalid symbol: \(symbol)")
        }

        // Format dates for Python script (YYYY-MM-DD)
        let startDateString = Self.scriptDateString(from: startDate)
        let endDateString = Self.scriptDateString(from: endDate)
        
        await logger.debug("Python historical dates: \(startDateString) to \(endDateString)")
        
        let arguments = [scriptPath, "--historical", symbol, "--start-date", startDateString, "--end-date", endDateString]
        await logger.debug("Python historical command prepared for \(symbol)")
        
        do {
            let (outputData, _, exitCode) = try await runPythonProcess(
                arguments: arguments,
                timeoutSeconds: 300,
                logContext: "Historical fetch for \(symbol)"
            )

            await logger.debug("Python historical process exited \(exitCode) for \(symbol)")

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("🐍 PYTHON SCRIPT: stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty output from historical script for \(symbol)")
            }
            
            await logger.debug("Python historical output received for \(symbol) (\(output.count) chars)")

            // Try to parse as JSON error first
            do {
                try parseError(from: output)
            } catch let error as NetworkError {
                throw error
            } catch {
                // Not a JSON error, continue with normal parsing
            }

            // Check for FETCH_FAILED
            if output.contains("FETCH_FAILED") {
                await logger.warning("Script explicitly reported FETCH_FAILED for historical \(symbol).")
                throw NetworkError.noData("Script reported FETCH_FAILED for historical \(symbol)")
            }
            
            // Validate JSON structure before parsing
            guard output.hasPrefix("[") && output.hasSuffix("]") else {
                await logger.error("🐍 PYTHON SCRIPT: Invalid JSON structure for \(symbol). Output should start with '[' and end with ']'. First 100 chars: \(String(output.prefix(100)))")
                throw NetworkError.invalidResponse("Invalid JSON structure from script output")
            }
            
            // Parse JSON array response
            guard let jsonData = output.data(using: .utf8) else {
                throw NetworkError.invalidResponse("Could not convert output to data")
            }
            
            do {
                let historicalArray = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] ?? []
                
                var priceSnapshots: [PriceSnapshot] = []
                
                for item in historicalArray {
                    guard let timestamp = item["timestamp"] as? TimeInterval,
                          let price = item["price"] as? Double,
                          let previousClose = item["previousClose"] as? Double,
                          let symbolValue = item["symbol"] as? String else {
                        await logger.warning("Skipping invalid historical data item: \(item)")
                        continue
                    }
                    
                    let snapshot = PriceSnapshot(
                        timestamp: Date(timeIntervalSince1970: timestamp),
                        price: price,
                        previousClose: previousClose,
                        volume: nil,
                        symbol: symbolValue
                    )
                    priceSnapshots.append(snapshot)
                }
                
                await logger.info("Historical fetch completed for \(symbol): \(priceSnapshots.count) points")
                
                // Show sample of parsed data for debugging
                if !priceSnapshots.isEmpty {
                    let sortedSnapshots = priceSnapshots.sorted { $0.timestamp < $1.timestamp }
                    if let first = sortedSnapshots.first, let last = sortedSnapshots.last {
                        await logger.debug("Historical range for \(symbol): \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                }
                
                return priceSnapshots
            } catch {
                await logger.error("Failed to parse JSON from historical script output: \(error.localizedDescription)")
                await logger.debug("Python historical parse failure output length for \(symbol): \(output.count)")
                throw NetworkError.invalidResponse("Could not parse JSON from script output: \(error.localizedDescription)")
            }
        } catch let accessError as ProviderAccessError {
            throw accessError
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            await logger.error("Failed to run Python script for historical \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }

    // MARK: - OHLC Data Fetching (v2.3.0 UI Enhancement)

    /// Fetch OHLC (candlestick) data for a single symbol
    /// - Parameters:
    ///   - symbol: Stock symbol (e.g., "AAPL", "TSLA")
    ///   - period: Time period (1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max)
    ///   - interval: Data interval (1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo)
    /// - Returns: Array of OHLC snapshots
    func fetchOHLCData(for symbol: String, period: String = "1mo", interval: String = "1d") async throws -> [OHLCSnapshot] {
        await logger.info("📊 OHLC: Starting fetch for \(symbol) (period: \(period), interval: \(interval))")

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }

        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            let error = NetworkError.pythonInterpreterNotFound(config.interpreterPath)
            await logger.error(error.localizedDescription)
            throw error
        }

        let arguments = [scriptPath, "--ohlc", symbol, "--period", period, "--interval", interval]
        await logger.info("📊 OHLC: Command: \(config.interpreterPath) \(arguments.joined(separator: " "))")

        do {
            let (outputData, errorData, _) = try await runPythonProcess(
                arguments: arguments,
                timeoutSeconds: 120,
                logContext: "OHLC fetch for \(symbol)"
            )

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logger.info("📊 OHLC: Debug output for \(symbol): \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("📊 OHLC: stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty OHLC output from script for \(symbol)")
            }

            await logger.info("📊 OHLC: Raw output for \(symbol) (\(output.count) chars)")

            // Try to parse as JSON error first
            do {
                try parseError(from: output)
            } catch let error as NetworkError {
                throw error
            } catch {
                // Not a JSON error, continue with normal parsing
            }

            // Parse JSON array response
            guard let jsonData = output.data(using: .utf8) else {
                throw NetworkError.invalidResponse("Could not convert OHLC output to data")
            }

            do {
                let ohlcArray = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] ?? []

                var snapshots: [OHLCSnapshot] = []

                for item in ohlcArray {
                    guard let timestamp = item["timestamp"] as? TimeInterval,
                          let symbolValue = item["symbol"] as? String,
                          let open = item["open"] as? Double,
                          let high = item["high"] as? Double,
                          let low = item["low"] as? Double,
                          let close = item["close"] as? Double,
                          let volume = item["volume"] as? Int64 else {
                        await logger.warning("📊 OHLC: Skipping invalid OHLC data item: \(item)")
                        continue
                    }

                    let snapshot = OHLCSnapshot(
                        symbol: symbolValue,
                        timestamp: Date(timeIntervalSince1970: timestamp),
                        open: open,
                        high: high,
                        low: low,
                        close: close,
                        volume: volume
                    )
                    snapshots.append(snapshot)
                }

                await logger.info("📊 OHLC: Successfully parsed \(snapshots.count) candlesticks for \(symbol)")
                return snapshots
            } catch {
                await logger.error("📊 OHLC: Failed to parse JSON: \(error.localizedDescription)")
                throw NetworkError.invalidResponse("Could not parse OHLC JSON: \(error.localizedDescription)")
            }
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            await logger.error("📊 OHLC: Failed to run Python script for \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }

    /// Fetch OHLC data for multiple symbols (batch operation)
    /// - Parameters:
    ///   - symbols: Array of stock symbols
    ///   - period: Time period (1d, 5d, 1mo, 3mo, 6mo, 1y, 2y, 5y, 10y, ytd, max)
    ///   - interval: Data interval (1m, 2m, 5m, 15m, 30m, 60m, 90m, 1h, 1d, 5d, 1wk, 1mo, 3mo)
    /// - Returns: Dictionary mapping symbol to array of OHLC snapshots
    func fetchBatchOHLCData(for symbols: [String], period: String = "1mo", interval: String = "1d") async throws -> [String: [OHLCSnapshot]] {
        await logger.info("📊 OHLC BATCH: Starting fetch for \(symbols.count) symbols (period: \(period), interval: \(interval))")

        guard !symbols.isEmpty else { return [:] }

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }

        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            let error = NetworkError.pythonInterpreterNotFound(config.interpreterPath)
            await logger.error(error.localizedDescription)
            throw error
        }

        let safeSymbols = symbols.filter { PythonConfiguration.validateSymbol($0) }
        guard !safeSymbols.isEmpty else { return [:] }

        var args = [scriptPath, "--batch-ohlc", "--period", period, "--interval", interval]
        args.append(contentsOf: safeSymbols)
        await logger.info("📊 OHLC BATCH: Command: \(config.interpreterPath) \(args.joined(separator: " "))")

        do {
            let (outputData, errorData, _) = try await runPythonProcess(
                arguments: args,
                timeoutSeconds: 300,
                logContext: "OHLC batch fetch"
            )

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logger.info("📊 OHLC BATCH: Debug output: \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("📊 OHLC BATCH: stdout is empty.")
                throw NetworkError.noData("Empty OHLC batch output from script")
            }

            await logger.info("📊 OHLC BATCH: Raw output (\(output.count) chars)")

            // Try to parse as JSON error first
            do {
                try parseError(from: output)
            } catch let error as NetworkError {
                throw error
            } catch {
                // Not a JSON error, continue with normal parsing
            }

            // Parse JSON dictionary response
            guard let jsonData = output.data(using: .utf8) else {
                throw NetworkError.invalidResponse("Could not convert OHLC batch output to data")
            }

            do {
                let batchData = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: [[String: Any]]] ?? [:]

                var result: [String: [OHLCSnapshot]] = [:]

                for (symbol, ohlcArray) in batchData {
                    var snapshots: [OHLCSnapshot] = []

                    for item in ohlcArray {
                        guard let timestamp = item["timestamp"] as? TimeInterval,
                              let symbolValue = item["symbol"] as? String,
                              let open = item["open"] as? Double,
                              let high = item["high"] as? Double,
                              let low = item["low"] as? Double,
                              let close = item["close"] as? Double,
                              let volume = item["volume"] as? Int64 else {
                            await logger.warning("📊 OHLC BATCH: Skipping invalid OHLC data item for \(symbol): \(item)")
                            continue
                        }

                        let snapshot = OHLCSnapshot(
                            symbol: symbolValue,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            open: open,
                            high: high,
                            low: low,
                            close: close,
                            volume: volume
                        )
                        snapshots.append(snapshot)
                    }

                    result[symbol] = snapshots
                    await logger.info("📊 OHLC BATCH: Successfully parsed \(snapshots.count) candlesticks for \(symbol)")
                }

                await logger.info("📊 OHLC BATCH: Successfully parsed data for \(result.count) symbols")
                return result
            } catch {
                await logger.error("📊 OHLC BATCH: Failed to parse JSON: \(error.localizedDescription)")
                throw NetworkError.invalidResponse("Could not parse OHLC batch JSON: \(error.localizedDescription)")
            }
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            await logger.error("📊 OHLC BATCH: Failed to run Python script: \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
    
    /// Verifies the API key for a specific service by running a test fetch
    /// - Parameter service: Service identifier (e.g., "fmp", "twelvedata")
    /// - Returns: Boolean indicating if the key is valid
    func verifyAPIKey(service: String) async throws -> Bool {
        await logger.info("🔑 VERIFY: Starting verification for \(service)")
        
        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        
        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            let error = NetworkError.pythonInterpreterNotFound(config.interpreterPath)
            await logger.error(error.localizedDescription)
            throw error
        }
        
        do {
            let (outputData, _, _) = try await runPythonProcess(
                arguments: [scriptPath, "--test-key", service],
                timeoutSeconds: 30,
                logContext: "Verify API key for \(service)"
            )
            
            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("🔑 VERIFY: stdout is empty.")
                throw NetworkError.noData("Empty output from verification script")
            }
            
            await logger.info("🔑 VERIFY: Output: \(output)")
            
            // Parse JSON result
            guard let jsonData = output.data(using: .utf8) else {
                throw NetworkError.invalidResponse("Could not convert verification output to data")
            }
            
            if let result = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
               let success = result["success"] as? Bool {
                if let message = result["message"] as? String {
                    await logger.info("🔑 VERIFY: Result message: \(message)")
                }
                return success
            }
            
            return false
        } catch {
            await logger.error("🔑 VERIFY: Failed to run script: \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
}

// Removed placeholder StockFetchResult struct from here.
// It should be defined in its own file (e.g., StockFetchResult.swift).

// Removed placeholder Logger class and extension from here.
// Your project should have a central Logger definition (e.g., Logger.swift)
// that provides Logger.shared.
