// Stockbar/Stockbar/Networking/NetworkService.swift
// --- FIXED FILE ---

import Foundation
// Removed OSLog import to avoid conflict with custom Logger

// Keep the original protocol for compatibility
protocol NetworkService {
    func fetchQuote(for symbol: String) async throws -> StockFetchResult
    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult]
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
            
            // Try to parse the single line success output
            // Example: "AAPL @ 2023-10-27 15:55:00-04:00 | 5m Low: 167.01, High: 167.09, Close: 167.02, PrevClose: 165.50"
            let regex = try! NSRegularExpression(pattern: "Close: (\\d+\\.\\d+), PrevClose: (\\d+\\.\\d+)")
            if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
                if let closeRange = Range(match.range(at: 1), in: output),
                   let prevCloseRange = Range(match.range(at: 2), in: output) {
                    if let closePrice = Double(output[closeRange]),
                       let prevClosePrice = Double(output[prevCloseRange]) {
                        // Detect currency for UK stocks
                        let detectedCurrency = symbol.uppercased().hasSuffix(".L") ? "GBX" : nil
                        logger.info("Successfully fetched Close=\(closePrice), PrevClose=\(prevClosePrice) for \(symbol) via Python. Detected currency: \(detectedCurrency ?? "nil")")
                        // Determine timezone based on symbol
                        let timezone = symbol.uppercased().hasSuffix(".L") ? "Europe/London" : "America/New_York"
                        return StockFetchResult(
                            currency: detectedCurrency,
                            symbol: symbol,
                            shortName: symbol, // Placeholder
                            regularMarketTime: Int(Date().timeIntervalSince1970),
                            exchangeTimezoneName: timezone,
                            regularMarketPrice: closePrice,
                            regularMarketPreviousClose: prevClosePrice
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

    func fetchBatchQuotes(for symbols: [String]) async throws -> [StockFetchResult] {
        logger.info("Starting batch fetch for \(symbols.count) symbols using Python script.")

        guard !symbols.isEmpty else { return [] }

        var results: [StockFetchResult] = []
        var errors: [Error] = [] // Optional: Collect errors if needed

        for symbol in symbols {
            do {
                let result = try await fetchQuote(for: symbol)
                results.append(result)
            } catch {
                logger.error("Failed to fetch quote for \(symbol) in batch: \(error.localizedDescription)")
                // Create a placeholder result for failed fetches to maintain currency info
                let timezone = symbol.uppercased().hasSuffix(".L") ? "Europe/London" : "America/New_York"
                let placeholderResult = StockFetchResult(
                    currency: symbol.uppercased().hasSuffix(".L") ? "GBX" : nil,
                    symbol: symbol,
                    shortName: symbol,
                    regularMarketTime: Int(Date().timeIntervalSince1970),
                    exchangeTimezoneName: timezone,
                    regularMarketPrice: Double.nan,
                    regularMarketPreviousClose: Double.nan
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
}

// Removed placeholder StockFetchResult struct from here.
// It should be defined in its own file (e.g., StockFetchResult.swift).

// Removed placeholder Logger class and extension from here.
// Your project should have a central Logger definition (e.g., Logger.swift)
// that provides Logger.shared.