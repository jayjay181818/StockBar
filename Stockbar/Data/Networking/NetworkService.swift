// Stockbar/Stockbar/Networking/NetworkService.swift
// --- FIXED FILE ---

import Foundation
// Removed OSLog import to avoid conflict with custom Logger

// Keep the original protocol for compatibility
protocol NetworkService {
    func fetchQuote(for symbol: String) async throws -> StockFetchResult
    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult]
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot]
    func fetchOHLCData(for symbol: String, period: String, interval: String) async throws -> [OHLCSnapshot]
    func fetchBatchOHLCData(for symbols: [String], period: String, interval: String) async throws -> [String: [OHLCSnapshot]]
    func verifyAPIKey(service: String) async throws -> Bool
}

// MARK: - Network Error Enum (Extended for script execution)
enum NetworkError: LocalizedError {
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
            return "Python 3 interpreter not found at \(path). Please ensure Python 3 is installed and accessible."
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
class PythonNetworkService: NetworkService {
    private let logger = Logger.shared // Assumes Logger.swift (or similar) provides this
    private let scriptName = "get_stock_data.py"
    private let config = PythonConfiguration.load()

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

    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        await logger.debug("Attempting to fetch quote for \(symbol) using Python script.")

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        await logger.debug("Found script at path: \(scriptPath)")

        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        process.arguments = [scriptPath, symbol]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            
            // CRITICAL FIX: Add timeout protection to prevent indefinite hangs
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(30)) // 30 second timeout
                if process.isRunning {
                    await logger.warning("Process timeout reached for \(symbol), terminating process")
                    process.terminate()
                }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel() // Cancel timeout if process finishes normally

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logger.error("Python script stderr for \(symbol): \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("Python script stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty output from script for \(symbol)")
            }
            await logger.debug("Python script stdout for \(symbol): \(output)")

            // Try to parse as JSON error first
            do {
                try parseError(from: output)
            } catch let error as NetworkError {
                throw error
            } catch {
                // Not a JSON error, continue with normal parsing
            }

            // Check for multi-line output which indicates an error from the legacy script format
            let outputLines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            if outputLines.count > 1 && outputLines.last == "FETCH_FAILED" {
                await logger.warning("Script explicitly reported FETCH_FAILED for \(symbol). Error: \(outputLines.first ?? "Unknown error")")
                throw NetworkError.noData("Script reported FETCH_FAILED for \(symbol): \(outputLines.first ?? "")")
            }
            
            // Try to parse the single line success output (legacy format)
            // Example: "AAPL @ 2023-10-27 15:55:00-04:00 | 5m Low: 167.01, High: 167.09, Close: 167.02, PrevClose: 165.50"
            // CRITICAL FIX: Replace force unwrap with safe optional binding
            guard let regex = try? NSRegularExpression(pattern: "Close: (\\d+\\.\\d+), PrevClose: (\\d+\\.\\d+)") else {
                await logger.error("Failed to create regex pattern for parsing script output for \(symbol)")
                throw NetworkError.invalidResponse("Unable to create regex pattern for parsing")
            }
            if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
                if let closeRange = Range(match.range(at: 1), in: output),
                   let prevCloseRange = Range(match.range(at: 2), in: output) {
                    if let closePrice = Double(output[closeRange]),
                       let prevClosePrice = Double(output[prevCloseRange]) {
                        // Detect currency based on symbol - Python script already converts pence to pounds for .L stocks
                        let detectedCurrency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
                        await logger.info("Successfully fetched Close=\(closePrice), PrevClose=\(prevClosePrice) for \(symbol) via Python. Detected currency: \(detectedCurrency)")
                        // Determine timezone based on symbol
                        let timezone = symbol.uppercased().hasSuffix(".L") ? "Europe/London" : "America/New_York"
                        return StockFetchResult(
                            currency: detectedCurrency,
                            symbol: symbol,
                            shortName: symbol, // Placeholder
                            regularMarketTime: Int(Date().timeIntervalSince1970),
                            exchangeTimezoneName: timezone,
                            regularMarketPrice: closePrice,
                            regularMarketPreviousClose: prevClosePrice,
                            displayPrice: closePrice  // For legacy method, display price = regular price
                        )
                    }
                }
            }
            
            // If parsing fails, it's an invalid response
            await logger.error("Failed to parse script output for \(symbol): '\(output)'")
            throw NetworkError.invalidResponse("Could not parse expected data from script output: \(output)")
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            await logger.error("Failed to run Python script for \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
    
    /// Enhanced fetch quote with pre/post market data support
    func fetchEnhancedQuote(for symbol: String) async throws -> StockFetchResult {
        await logger.debug("Attempting to fetch enhanced quote for \(symbol) using Python script.")

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }

        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        // Use multiple symbols to trigger JSON output format
        process.arguments = [scriptPath, symbol, symbol] // Duplicate symbol to trigger batch mode

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            
            // CRITICAL FIX: Add timeout protection to prevent indefinite hangs
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(30)) // 30 second timeout
                if process.isRunning {
                    await logger.warning("Enhanced process timeout reached for \(symbol), terminating process")
                    process.terminate()
                }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel() // Cancel timeout if process finishes normally

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logger.error("Python script stderr for enhanced \(symbol): \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("Python script stdout for enhanced \(symbol) is empty.")
                throw NetworkError.noData("Empty output from script for \(symbol)")
            }
            await logger.debug("Python script stdout for enhanced \(symbol): \(output)")

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
                await logger.warning("Script explicitly reported FETCH_FAILED for enhanced \(symbol).")
                throw NetworkError.noData("Script reported FETCH_FAILED for \(symbol)")
            }
            
            // Parse JSON array response
            guard let jsonData = output.data(using: .utf8) else {
                throw NetworkError.invalidResponse("Could not convert output to data")
            }
            
            do {
                let quotesArray = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] ?? []
                
                // Find our symbol in the results (should be the first one)
                guard let quoteData = quotesArray.first(where: { quote in
                    (quote["symbol"] as? String) == symbol
                }) else {
                    throw NetworkError.noData("Symbol \(symbol) not found in enhanced response")
                }
                
                return try parseEnhancedQuoteData(quoteData, symbol: symbol)
                
            } catch {
                await logger.error("Failed to parse JSON from enhanced script output: \(error.localizedDescription)")
                throw NetworkError.invalidResponse("Could not parse JSON from script output: \(error.localizedDescription)")
            }
            
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            await logger.error("Failed to run Python script for enhanced \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
    
    private func parseEnhancedQuoteData(_ data: [String: Any], symbol: String) throws -> StockFetchResult {
        guard let displayPrice = data["price"] as? Double,
              let previousClose = data["previousClose"] as? Double,
              let timestamp = data["timestamp"] as? TimeInterval else {
            throw NetworkError.invalidResponse("Missing required fields in enhanced quote data")
        }
        
        // If regularMarketPrice is not available (e.g., FMP fallback), use displayPrice
        let regularMarketPrice = data["regularMarketPrice"] as? Double ?? displayPrice
        
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
        let detectedCurrency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
        let timezone = symbol.uppercased().hasSuffix(".L") ? "Europe/London" : "America/New_York"

        Task { await logger.info("Successfully fetched enhanced data for \(symbol): displayPrice=\(displayPrice), regularMarketPrice=\(regularMarketPrice), preMarket=\(preMarketPrice?.description ?? "nil"), postMarket=\(postMarketPrice?.description ?? "nil"), state=\(marketStateString ?? "nil"), preMarketTime=\(preMarketTime?.description ?? "nil"), postMarketTime=\(postMarketTime?.description ?? "nil")") }

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
        await logger.info("Starting batch fetch for \(symbols.count) symbols using Python script.")

        guard !symbols.isEmpty else { return [] }

        var results: [StockFetchResult] = []
        var errors: [Error] = [] // Optional: Collect errors if needed

        for symbol in symbols {
            do {
                let result = try await fetchEnhancedQuote(for: symbol)
                results.append(result)
            } catch {
                await logger.error("Failed to fetch quote for \(symbol) in batch: \(error.localizedDescription)")
                // Create a placeholder result for failed fetches to maintain currency info
                let timezone = symbol.uppercased().hasSuffix(".L") ? "Europe/London" : "America/New_York"
                let placeholderResult = StockFetchResult(
                    currency: symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD",
                    symbol: symbol,
                    shortName: symbol,
                    regularMarketTime: Int(Date().timeIntervalSince1970),
                    exchangeTimezoneName: timezone,
                    regularMarketPrice: Double.nan,
                    regularMarketPreviousClose: Double.nan,
                    displayPrice: Double.nan,
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
                results.append(placeholderResult)
                errors.append(error) // Example: collecting errors
            }
            
            // Add a delay before the next symbol to avoid rate limiting
            // Only delay if there are more symbols to process
            if symbol != symbols.last {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                } catch {
                    await logger.warning("Task.sleep failed: \(error.localizedDescription)")
                }
            }
        }

        // If all symbols failed and you want to throw a general error:
        // if results.isEmpty && !symbols.isEmpty && !errors.isEmpty {
        //     throw NetworkError.scriptExecutionError("All symbols in batch failed to fetch. Last error: \(errors.last?.localizedDescription ?? "Unknown error")")
        // }

        return results
    }
    
    // MARK: - Helper Classes
    
    /// Thread-safe buffer for capturing process output
    final class SafeDataBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        
        func append(_ newData: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(newData)
        }
        
        var contents: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        await logger.info("🐍 PYTHON SCRIPT: Starting historical data fetch for \(symbol)")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        await logger.info("🐍 PYTHON SCRIPT: Date range: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        
        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            await logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        
        guard FileManager.default.fileExists(atPath: config.interpreterPath) else {
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }
        
        // Format dates for Python script (YYYY-MM-DD)
        let scriptDateFormatter = DateFormatter()
        scriptDateFormatter.dateFormat = "yyyy-MM-dd"
        let startDateString = scriptDateFormatter.string(from: startDate)
        let endDateString = scriptDateFormatter.string(from: endDate)
        
        await logger.info("🐍 PYTHON SCRIPT: Formatted dates - start: \(startDateString), end: \(endDateString)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        process.arguments = [scriptPath, "--historical", symbol, "--start-date", startDateString, "--end-date", endDateString]
        
        await logger.info("🐍 PYTHON SCRIPT: Command: \(config.interpreterPath) \(process.arguments?.joined(separator: " ") ?? "")")
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            await logger.info("🐍 PYTHON SCRIPT: Executing process for \(symbol)")
            try process.run()
            
            // Add timeout protection for historical data fetching (5 minutes max)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                if process.isRunning {
                    await logger.warning("🐍 PYTHON SCRIPT: Timeout reached for \(symbol), terminating process")
                    process.terminate()
                }
            }
            
            // Read data incrementally to avoid pipe buffer overflow (65KB limit)
            // Use readability handler approach for reliable streaming
            let outputBuffer = SafeDataBuffer()
            let errorBuffer = SafeDataBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    outputBuffer.append(chunk)
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    errorBuffer.append(chunk)
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel() // Cancel timeout if process finishes normally

            // Clear handlers and read any final data
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            // Read any remaining buffered data
            let remainingOutput = outputPipe.fileHandleForReading.availableData
            if !remainingOutput.isEmpty {
                outputBuffer.append(remainingOutput)
            }
            let remainingError = errorPipe.fileHandleForReading.availableData
            if !remainingError.isEmpty {
                errorBuffer.append(remainingError)
            }
            
            let exitCode = process.terminationStatus
            await logger.info("🐍 PYTHON SCRIPT: Process completed with exit code \(exitCode) for \(symbol)")
            
            let errorData = errorBuffer.contents
            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await logger.info("🐍 PYTHON SCRIPT: Debug output for \(symbol): \(err)")
            }
            
            let outputData = outputBuffer.contents
            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                await logger.warning("🐍 PYTHON SCRIPT: stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty output from historical script for \(symbol)")
            }
            
            await logger.info("🐍 PYTHON SCRIPT: Raw output for \(symbol) (\(output.count) chars): \(String(output.prefix(200)))...")

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
                
                await logger.info("🐍 PYTHON SCRIPT: Successfully parsed \(priceSnapshots.count) historical data points for \(symbol)")
                
                // Show sample of parsed data for debugging
                if !priceSnapshots.isEmpty {
                    let sortedSnapshots = priceSnapshots.sorted { $0.timestamp < $1.timestamp }
                    if let first = sortedSnapshots.first, let last = sortedSnapshots.last {
                        await logger.info("🐍 PYTHON SCRIPT: \(symbol) parsed data range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                }
                
                return priceSnapshots
                
            } catch {
                await logger.error("Failed to parse JSON from historical script output: \(error.localizedDescription)")
                await logger.error("🐍 PYTHON SCRIPT: Problematic output for \(symbol) (first 500 chars): \(String(output.prefix(500)))")
                throw NetworkError.invalidResponse("Could not parse JSON from script output: \(error.localizedDescription)")
            }
            
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
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        process.arguments = [scriptPath, "--ohlc", symbol, "--period", period, "--interval", interval]

        await logger.info("📊 OHLC: Command: \(config.interpreterPath) \(process.arguments?.joined(separator: " ") ?? "")")

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Add timeout protection (2 minutes for OHLC data)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 120_000_000_000) // 2 minutes
                if process.isRunning {
                    await logger.warning("📊 OHLC: Timeout reached for \(symbol), terminating process")
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

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
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        var args = [scriptPath, "--batch-ohlc", "--period", period, "--interval", interval]
        args.append(contentsOf: symbols)
        process.arguments = args

        await logger.info("📊 OHLC BATCH: Command: \(config.interpreterPath) \(args.joined(separator: " "))")

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Add timeout protection (5 minutes for batch OHLC data)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                if process.isRunning {
                    await logger.warning("📊 OHLC BATCH: Timeout reached, terminating process")
                    process.terminate()
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

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
            await logger.error("Python interpreter not found at \(config.interpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(config.interpreterPath)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.interpreterPath)
        process.arguments = [scriptPath, "--test-key", service]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            
            // Timeout protection (30 seconds)
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(30))
                if process.isRunning {
                    await logger.warning("🔑 VERIFY: Timeout reached, terminating process")
                    process.terminate()
                }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            
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