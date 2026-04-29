//
//  OHLCFetchService.swift
//  Stockbar
//
//  Created for Phase 2: Chart Enhancements
//  Fetches OHLC data from yfinance via Python backend
//

import Foundation

// MARK: - OHLC Fetch Service

protocol OHLCDataStoring: Sendable {
    func saveSnapshots(_ snapshots: [OHLCSnapshot]) async throws
    func fetchSnapshots(symbol: String, startDate: Date?, endDate: Date?) async throws -> [OHLCSnapshot]
}

extension OHLCDataService: OHLCDataStoring {}

final class OHLCFetchService: @unchecked Sendable {
    static let shared = OHLCFetchService()

    private let pythonScriptPath: String
    private let processRunner: any PythonProcessRunning
    private let ohlcDataStore: any OHLCDataStoring

    init(
        pythonScriptPath: String? = nil,
        processRunner: (any PythonProcessRunning)? = nil,
        ohlcDataStore: (any OHLCDataStoring)? = nil
    ) {
        // Get path to Python script
        if let pythonScriptPath {
            self.pythonScriptPath = pythonScriptPath
        } else if let scriptPath = Bundle.main.path(forResource: "get_ohlc_data", ofType: "py") {
            self.pythonScriptPath = scriptPath
        } else {
            // Fallback to main get_stock_data.py location
            self.pythonScriptPath = Bundle.main.resourcePath?.appending("/get_ohlc_data.py") ?? ""
        }
        self.processRunner = processRunner ?? PythonProcessRunner(config: .load())
        self.ohlcDataStore = ohlcDataStore ?? OHLCDataService()
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

        guard !pythonScriptPath.isEmpty else {
            await Logger.shared.error("OHLC Python script not found in bundle")
            throw OHLCFetchError.fetchFailed("Python script not found")
        }

        do {
            let result = try await processRunner.run(
                arguments: [pythonScriptPath, symbol, period, interval],
                timeoutSeconds: 30,
                logContext: "OHLC fetch for \(symbol)"
            )

            if let errorOutput = String(data: result.stderr, encoding: .utf8), !errorOutput.isEmpty {
                await Logger.shared.debug("Python stderr: \(errorOutput)")
            }

            guard let output = String(data: result.stdout, encoding: .utf8), !output.isEmpty else {
                await Logger.shared.error("Empty output from OHLC fetch for \(symbol)")
                throw OHLCFetchError.emptyResponse
            }

            // Parse JSON output
            let snapshots = try parseOHLCOutput(output, symbol: symbol)

            // Save to Core Data
            try await ohlcDataStore.saveSnapshots(snapshots)

            await Logger.shared.info("Successfully fetched \(snapshots.count) OHLC data points for \(symbol)")
            return snapshots

        } catch NetworkError.timeout {
            await Logger.shared.error("OHLC fetch timed out for \(symbol)")
            throw OHLCFetchError.timeout
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
        let snapshots = try await ohlcDataStore.fetchSnapshots(
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
