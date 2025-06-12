// Stockbar/Stockbar/Networking/NetworkService.swift
// --- FIXED FILE ---

import Foundation
// Removed OSLog import to avoid conflict with custom Logger

// Keep the original protocol for compatibility
protocol NetworkService {
    func fetchQuote(for symbol: String) async throws -> StockFetchResult
    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult]
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot]
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
        }
    }
}

// MARK: - Python Script Service
class PythonNetworkService: NetworkService {
    private let logger = Logger.shared // Assumes Logger.swift (or similar) provides this
    // Default interpreter path; adjust if necessary
    private let pythonInterpreterPath = "/usr/bin/python3"
    private let scriptName = "get_stock_data.py"

    func fetchQuote(for symbol: String) async throws -> StockFetchResult {
        logger.debug("Attempting to fetch quote for \(symbol) using Python script.")

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        logger.debug("Found script at path: \(scriptPath)")

        guard FileManager.default.fileExists(atPath: pythonInterpreterPath) else {
            logger.error("Python interpreter not found at \(pythonInterpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(pythonInterpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonInterpreterPath)
        process.arguments = [scriptPath, symbol]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.error("Python script stderr for \(symbol): \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                logger.warning("Python script stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty output from script for \(symbol)")
            }
            logger.debug("Python script stdout for \(symbol): \(output)")

            // Check for multi-line output which indicates an error from the new script format
            let outputLines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            
            if outputLines.count > 1 && outputLines.last == "FETCH_FAILED" {
                logger.warning("Script explicitly reported FETCH_FAILED for \(symbol). Error: \(outputLines.first ?? "Unknown error")")
                throw NetworkError.noData("Script reported FETCH_FAILED for \(symbol): \(outputLines.first ?? "")")
            }
            
            // Try to parse the single line success output (legacy format)
            // Example: "AAPL @ 2023-10-27 15:55:00-04:00 | 5m Low: 167.01, High: 167.09, Close: 167.02, PrevClose: 165.50"
            let regex = try! NSRegularExpression(pattern: "Close: (\\d+\\.\\d+), PrevClose: (\\d+\\.\\d+)")
            if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
                if let closeRange = Range(match.range(at: 1), in: output),
                   let prevCloseRange = Range(match.range(at: 2), in: output) {
                    if let closePrice = Double(output[closeRange]),
                       let prevClosePrice = Double(output[prevCloseRange]) {
                        // Detect currency based on symbol - Python script already converts pence to pounds for .L stocks
                        let detectedCurrency = symbol.uppercased().hasSuffix(".L") ? "GBP" : "USD"
                        logger.info("Successfully fetched Close=\(closePrice), PrevClose=\(prevClosePrice) for \(symbol) via Python. Detected currency: \(detectedCurrency)")
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
            logger.error("Failed to parse script output for \(symbol): '\(output)'")
            throw NetworkError.invalidResponse("Could not parse expected data from script output: \(output)")
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            logger.error("Failed to run Python script for \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
    
    /// Enhanced fetch quote with pre/post market data support
    func fetchEnhancedQuote(for symbol: String) async throws -> StockFetchResult {
        logger.debug("Attempting to fetch enhanced quote for \(symbol) using Python script.")

        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }

        guard FileManager.default.fileExists(atPath: pythonInterpreterPath) else {
            logger.error("Python interpreter not found at \(pythonInterpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(pythonInterpreterPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonInterpreterPath)
        // Use multiple symbols to trigger JSON output format
        process.arguments = [scriptPath, symbol, symbol] // Duplicate symbol to trigger batch mode

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.error("Python script stderr for enhanced \(symbol): \(err)")
            }

            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                logger.warning("Python script stdout for enhanced \(symbol) is empty.")
                throw NetworkError.noData("Empty output from script for \(symbol)")
            }
            logger.debug("Python script stdout for enhanced \(symbol): \(output)")

            // Check for FETCH_FAILED
            if output.contains("FETCH_FAILED") {
                logger.warning("Script explicitly reported FETCH_FAILED for enhanced \(symbol).")
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
                logger.error("Failed to parse JSON from enhanced script output: \(error.localizedDescription)")
                throw NetworkError.invalidResponse("Could not parse JSON from script output: \(error.localizedDescription)")
            }
            
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            logger.error("Failed to run Python script for enhanced \(symbol): \(error.localizedDescription)")
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
        
        logger.info("Successfully fetched enhanced data for \(symbol): displayPrice=\(displayPrice), regularMarketPrice=\(regularMarketPrice), preMarket=\(preMarketPrice?.description ?? "nil"), postMarket=\(postMarketPrice?.description ?? "nil"), state=\(marketStateString ?? "nil")")
        
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
            preMarketTime: preMarketPrice != nil ? Int(timestamp) : nil,
            postMarketPrice: postMarketPrice,
            postMarketChange: postMarketChange,
            postMarketChangePercent: postMarketChangePercent,
            postMarketTime: postMarketPrice != nil ? Int(timestamp) : nil,
            marketState: marketState
        )
    }

    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        logger.info("Starting batch fetch for \(symbols.count) symbols using Python script.")

        guard !symbols.isEmpty else { return [] }

        var results: [StockFetchResult] = []
        var errors: [Error] = [] // Optional: Collect errors if needed

        for symbol in symbols {
            do {
                let result = try await fetchEnhancedQuote(for: symbol)
                results.append(result)
            } catch {
                logger.error("Failed to fetch quote for \(symbol) in batch: \(error.localizedDescription)")
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
                    logger.warning("Task.sleep failed: \(error.localizedDescription)")
                }
            }
        }

        // If all symbols failed and you want to throw a general error:
        // if results.isEmpty && !symbols.isEmpty && !errors.isEmpty {
        //     throw NetworkError.scriptExecutionError("All symbols in batch failed to fetch. Last error: \(errors.last?.localizedDescription ?? "Unknown error")")
        // }

        return results
    }
    
    func fetchHistoricalData(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] {
        logger.info("🐍 PYTHON SCRIPT: Starting historical data fetch for \(symbol)")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        logger.info("🐍 PYTHON SCRIPT: Date range: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        
        guard let scriptPath = Bundle.main.path(forResource: scriptName.replacingOccurrences(of: ".py", with: ""), ofType: "py") else {
            logger.error("Script '\(scriptName)' not found in bundle.")
            throw NetworkError.scriptNotFound(scriptName)
        }
        
        guard FileManager.default.fileExists(atPath: pythonInterpreterPath) else {
            logger.error("Python interpreter not found at \(pythonInterpreterPath)")
            throw NetworkError.pythonInterpreterNotFound(pythonInterpreterPath)
        }
        
        // Format dates for Python script (YYYY-MM-DD)
        let scriptDateFormatter = DateFormatter()
        scriptDateFormatter.dateFormat = "yyyy-MM-dd"
        let startDateString = scriptDateFormatter.string(from: startDate)
        let endDateString = scriptDateFormatter.string(from: endDate)
        
        logger.info("🐍 PYTHON SCRIPT: Formatted dates - start: \(startDateString), end: \(endDateString)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonInterpreterPath)
        process.arguments = [scriptPath, "--historical", symbol, "--start-date", startDateString, "--end-date", endDateString]
        
        logger.info("🐍 PYTHON SCRIPT: Command: \(pythonInterpreterPath) \(process.arguments?.joined(separator: " ") ?? "")")
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            logger.info("🐍 PYTHON SCRIPT: Executing process for \(symbol)")
            try process.run()
            process.waitUntilExit()
            
            let exitCode = process.terminationStatus
            logger.info("🐍 PYTHON SCRIPT: Process completed with exit code \(exitCode) for \(symbol)")
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.error("🐍 PYTHON SCRIPT: stderr for \(symbol): \(err)")
            }
            
            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
                logger.warning("🐍 PYTHON SCRIPT: stdout for \(symbol) is empty.")
                throw NetworkError.noData("Empty output from historical script for \(symbol)")
            }
            
            logger.info("🐍 PYTHON SCRIPT: Raw output for \(symbol) (\(output.count) chars): \(String(output.prefix(200)))...")
            
            // Check for FETCH_FAILED
            if output.contains("FETCH_FAILED") {
                logger.warning("Script explicitly reported FETCH_FAILED for historical \(symbol).")
                throw NetworkError.noData("Script reported FETCH_FAILED for historical \(symbol)")
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
                        logger.warning("Skipping invalid historical data item: \(item)")
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
                
                logger.info("🐍 PYTHON SCRIPT: Successfully parsed \(priceSnapshots.count) historical data points for \(symbol)")
                
                // Show sample of parsed data for debugging
                if !priceSnapshots.isEmpty {
                    let sortedSnapshots = priceSnapshots.sorted { $0.timestamp < $1.timestamp }
                    if let first = sortedSnapshots.first, let last = sortedSnapshots.last {
                        logger.info("🐍 PYTHON SCRIPT: \(symbol) parsed data range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                }
                
                return priceSnapshots
                
            } catch {
                logger.error("Failed to parse JSON from historical script output: \(error.localizedDescription)")
                throw NetworkError.invalidResponse("Could not parse JSON from script output: \(error.localizedDescription)")
            }
            
        } catch let netErr as NetworkError {
            throw netErr
        } catch {
            logger.error("Failed to run Python script for historical \(symbol): \(error.localizedDescription)")
            throw NetworkError.scriptExecutionError(error.localizedDescription)
        }
    }
}

// Removed placeholder StockFetchResult struct from here.
// It should be defined in its own file (e.g., StockFetchResult.swift).

// Removed placeholder Logger class and extension from here.
// Your project should have a central Logger definition (e.g., Logger.swift)
// that provides Logger.shared.