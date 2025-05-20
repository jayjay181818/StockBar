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

            if output == "FETCH_FAILED" {
                logger.warning("Script explicitly reported FETCH_FAILED for \(symbol).")
                throw NetworkError.noData("Script reported FETCH_FAILED for \(symbol)")
            }

            let parts = output.split(separator: ",")
            guard parts.count == 2, let price = Double(parts[0]), let prev = Double(parts[1]) else {
                logger.error("Failed to parse script output for \(symbol): '\(output)'")
                throw NetworkError.invalidResponse("Could not parse price,prev_close: \(output)")
            }

            logger.info("Successfully fetched price=\(price), prevClose=\(prev) for \(symbol) via Python.")
            // This now relies on StockFetchResult.swift for the struct definition
            return StockFetchResult(
                currency: nil,
                symbol: symbol,
                shortName: symbol,
                regularMarketTime: Int(Date().timeIntervalSince1970),
                exchangeTimezoneName: nil,
                regularMarketPrice: price,
                regularMarketPreviousClose: prev
            )
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
        process.arguments = [scriptPath, symbols.joined(separator: ",")]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if let err = String(data: errorData, encoding: .utf8), !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.error("Python script stderr (batch): \(err)")
        }

        guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            logger.warning("Python script stdout for batch is empty.")
            if !symbols.isEmpty { // Only throw if symbols were expected
                throw NetworkError.noData("Empty output from batch script")
            }
            return [] // No symbols requested, or script output genuinely empty.
        }

        logger.debug("Python script batch stdout: \(output)")

        var results: [StockFetchResult] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let parts = trimmedLine.split(separator: ",")
            
            guard parts.count >= 2 else {
                logger.warning("Invalid line structure in batch output (not enough parts): \(trimmedLine)")
                continue
            }
            
            let sym = String(parts[0])

            if parts.count == 2 && parts[1] == "FETCH_FAILED" {
                logger.warning("Batch fetch explicitly failed for symbol \(sym).")
                continue
            }

            guard parts.count == 3 else {
                logger.warning("Invalid line in batch output (expected 3 parts or FETCH_FAILED for \(sym)): \(trimmedLine)")
                continue
            }

            guard let price = Double(parts[1]), let prev = Double(parts[2]) else {
                logger.warning("Could not parse numbers in batch line for \(sym): \(trimmedLine)")
                continue
            }

            // This now relies on StockFetchResult.swift for the struct definition
            let result = StockFetchResult(
                currency: nil,
                symbol: sym,
                shortName: sym,
                regularMarketTime: Int(Date().timeIntervalSince1970),
                exchangeTimezoneName: nil,
                regularMarketPrice: price,
                regularMarketPreviousClose: prev
            )
            results.append(result)
        }

        if results.isEmpty && !symbols.isEmpty {
            logger.error("Batch fetch produced no parsable results for the requested symbols.")
            // Consider if this should throw only if all symbols failed,
            // or if the input 'symbols' array was non-empty and we received fewer lines than expected.
            // The current Python script aims to output a line for every symbol, even if "FETCH_FAILED".
            // So if results is empty here, and symbols were requested, it's a genuine "no data" scenario.
            throw NetworkError.noData("No valid batch results parsed")
        }
        
        if results.count < symbols.count {
            logger.warning("Batch fetch successfully parsed \(results.count) symbols, but \(symbols.count) were initially requested. Some may have failed (FETCH_FAILED) or were invalid and skipped.")
        }

        logger.info("Finished batch fetch. Successfully parsed \(results.count) of \(symbols.count) initially requested symbols (others may have been marked FETCH_FAILED by script and skipped here).")
        return results
    }
}

// Removed placeholder StockFetchResult struct from here.
// It should be defined in its own file (e.g., StockFetchResult.swift).

// Removed placeholder Logger class and extension from here.
// Your project should have a central Logger definition (e.g., Logger.swift)
// that provides Logger.shared.