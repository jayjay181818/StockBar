//
//  OHLCFetchService.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Fetches OHLC data from yfinance via Python backend
//

import Foundation

// MARK: - OHLC Fetch Service

@MainActor
class OHLCFetchService {
    static let shared = OHLCFetchService()

    private let pythonScriptPath: String
    private let ohlcDataService = OHLCDataService()

    private init() {
        // Get path to Python script
        if let scriptPath = Bundle.main.path(forResource: "get_ohlc_data", ofType: "py") {
            self.pythonScriptPath = scriptPath
        } else {
            // Fallback to main get_stock_data.py location
            self.pythonScriptPath = Bundle.main.resourcePath?.appending("/get_ohlc_data.py") ?? ""
        }
    }

    // MARK: - Public Methods

    /// Fetch OHLC data for a symbol
    /// - Parameters:
    ///   - symbol: Stock symbol
    ///   - period: Time period (1d, 5d, 1mo, 3mo, 6mo, 1y, 5y, max)
    ///   - interval: Data interval (1m, 5m, 15m, 30m, 1h, 1d, 1wk, 1mo)
    /// - Returns: Array of OHLC snapshots
    func fetchOHLCData(
        symbol: String,
        period: String = "1mo",
        interval: String = "1d"
    ) async throws -> [OHLCSnapshot] {
        await Logger.shared.debug("Fetching OHLC data for \(symbol) - period: \(period), interval: \(interval)")

        // Execute Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [pythonScriptPath, symbol, period, interval]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Set timeout
        let timeoutSeconds: TimeInterval = 30
        var timedOut = false

        let timeoutTimer = DispatchSource.makeTimerSource(queue: .global())
        timeoutTimer.schedule(deadline: .now() + timeoutSeconds)
        timeoutTimer.setEventHandler {
            if process.isRunning {
                Task { await Logger.shared.warning("OHLC fetch timeout for \(symbol), terminating process") }
                process.terminate()
                timedOut = true
            }
        }
        timeoutTimer.resume()

        do {
            try process.run()
            process.waitUntilExit()
            timeoutTimer.cancel()

            if timedOut {
                throw OHLCFetchError.timeout
            }

            // Read output
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                await Logger.shared.debug("Python stderr: \(errorOutput)")
            }

            guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
                await Logger.shared.error("Empty output from OHLC fetch for \(symbol)")
                throw OHLCFetchError.emptyResponse
            }

            // Parse JSON output
            let snapshots = try parseOHLCOutput(output, symbol: symbol)

            // Save to Core Data
            try await ohlcDataService.saveSnapshots(snapshots)

            await Logger.shared.info("Successfully fetched \(snapshots.count) OHLC data points for \(symbol)")
            return snapshots

        } catch {
            await Logger.shared.error("Failed to fetch OHLC data for \(symbol): \(error)")
            throw OHLCFetchError.fetchFailed(error.localizedDescription)
        }
    }

    /// Fetch OHLC data from Core Data cache
    func getCachedOHLCData(
        symbol: String,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [OHLCDataPoint] {
        let snapshots = try await ohlcDataService.fetchSnapshots(
            symbol: symbol,
            startDate: startDate,
            endDate: endDate
        )

        return snapshots.map { snapshot in
            OHLCDataPoint(
                timestamp: snapshot.timestamp,
                open: snapshot.open,
                high: snapshot.high,
                low: snapshot.low,
                close: snapshot.close,
                volume: snapshot.volume
            )
        }
    }

    // MARK: - Private Methods

    private func parseOHLCOutput(_ output: String, symbol: String) throws -> [OHLCSnapshot] {
        guard let jsonData = output.data(using: .utf8) else {
            throw OHLCFetchError.invalidData
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let response = try decoder.decode(OHLCResponse.self, from: jsonData)

            guard response.success else {
                throw OHLCFetchError.fetchFailed(response.error ?? "Unknown error")
            }

            return response.data.map { item in
                OHLCSnapshot(
                    symbol: symbol,
                    timestamp: item.timestamp,
                    open: item.open,
                    high: item.high,
                    low: item.low,
                    close: item.close,
                    volume: item.volume
                )
            }
        } catch {
            Task { await Logger.shared.error("Failed to parse OHLC JSON: \(error)") }
            throw OHLCFetchError.invalidData
        }
    }
}

// MARK: - Response Models

private struct OHLCResponse: Codable {
    let success: Bool
    let symbol: String
    let period: String
    let interval: String
    let data: [OHLCResponseItem]
    let error: String?
}

private struct OHLCResponseItem: Codable {
    let timestamp: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int64
}

// MARK: - Errors

enum OHLCFetchError: LocalizedError {
    case timeout
    case emptyResponse
    case invalidData
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Request timed out"
        case .emptyResponse:
            return "Empty response from server"
        case .invalidData:
            return "Invalid data format"
        case .fetchFailed(let message):
            return "Fetch failed: \(message)"
        }
    }
}

