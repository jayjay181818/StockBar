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
    func fetchSnapshots(symbol: String, interval: String?, startDate: Date?, endDate: Date?) async throws -> [OHLCSnapshot]
}

extension OHLCDataService: OHLCDataStoring {}

struct OHLCFetchResult: Sendable {
    let snapshots: [OHLCSnapshot]
    let sourceStatus: FolyncSupplementalSourceStatus
    let coverageLabel: String
}

final class OHLCFetchService: Sendable {
    static let shared = OHLCFetchService()

    private let pythonScriptPath: String
    private let processRunner: any PythonProcessRunning
    private let ohlcDataStore: any OHLCDataStoring
    private let supplementalProvider: any FolyncSupplementalOHLCProviding

    init(
        pythonScriptPath: String? = nil,
        processRunner: (any PythonProcessRunning)? = nil,
        ohlcDataStore: (any OHLCDataStoring)? = nil,
        supplementalProvider: (any FolyncSupplementalOHLCProviding)? = nil
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
        self.processRunner = processRunner ?? PythonProcessRunner()
        self.ohlcDataStore = ohlcDataStore ?? OHLCDataService()
        self.supplementalProvider = supplementalProvider ?? FolyncSupplementalCoordinator.shared
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
        interval: String = "1d",
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> [OHLCSnapshot] {
        try await fetchOHLCDataWithSource(
            symbol: symbol,
            period: period,
            interval: interval,
            from: from,
            to: to
        ).snapshots
    }

    func fetchOHLCDataWithSource(
        symbol: String,
        period: String = "1mo",
        interval: String = "1d",
        from: Date? = nil,
        to: Date? = nil
    ) async throws -> OHLCFetchResult {
        await Logger.shared.debug("Fetching OHLC data for \(symbol) - period: \(period), interval: \(interval)")

        switch try await supplementalProvider.routeOHLC(
            symbol: symbol,
            period: period,
            interval: interval,
            from: from,
            to: to
        ) {
        case .folync(let snapshots, let status, let metadata):
            await Logger.shared.info(
                "Using \(snapshots.count) non-persisted \(status.label) OHLC points for \(symbol)"
            )
            return OHLCFetchResult(
                snapshots: snapshots,
                sourceStatus: status,
                coverageLabel: metadata.coverageLabel
            )
        case .unavailable:
            throw OHLCFetchError.fetchFailed("Folync candlestick history is unavailable and local fallback is disabled")
        case .legacy:
            break
        }

        guard !pythonScriptPath.isEmpty else {
            await Logger.shared.error("OHLC Python script not found in bundle")
            throw OHLCFetchError.fetchFailed("Python script not found")
        }

        // Symbol, period and interval all become argv entries.
        guard PythonConfiguration.validateSymbol(symbol) else {
            await Logger.shared.warning("Rejecting invalid symbol for OHLC fetch: \(symbol)")
            throw OHLCFetchError.fetchFailed("Invalid symbol: \(symbol)")
        }
        guard Self.isValidPeriod(period), Self.isValidInterval(interval) else {
            await Logger.shared.warning("Rejecting invalid OHLC period/interval: \(period)/\(interval)")
            throw OHLCFetchError.fetchFailed("Invalid period or interval")
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
            let snapshots = try parseOHLCOutput(output, symbol: symbol, interval: interval)

            // Save to Core Data
            try await ohlcDataStore.saveSnapshots(snapshots)

            await Logger.shared.info("Successfully fetched \(snapshots.count) OHLC data points for \(symbol)")
            return OHLCFetchResult(
                snapshots: snapshots,
                sourceStatus: .legacy,
                coverageLabel: "\(snapshots.count) points · \(interval) · local provider"
            )
        } catch NetworkError.timeout {
            await Logger.shared.error("OHLC fetch timed out for \(symbol)")
            throw OHLCFetchError.timeout
        } catch {
            await Logger.shared.error("Failed to fetch OHLC data for \(symbol): \(error)")
            throw OHLCFetchError.fetchFailed(error.localizedDescription)
        }
    }

    /// Cached candles for the requested range and interval, or an empty array
    /// when the caller should refetch: nothing stored at that interval, the
    /// cache does not reach back over the range, or the newest candle is older
    /// than about one interval. With `allowStale`, any cached candles at the
    /// interval are returned (used as an offline fallback).
    func getCachedOHLCData(
        symbol: String,
        period: String,
        interval: String,
        now: Date = Date(),
        allowStale: Bool = false
    ) async throws -> [OHLCDataPoint] {
        let rangeStart = OHLCCachePolicy.periodSeconds(period).map { now.addingTimeInterval(-$0) }
        let snapshots = try await ohlcDataStore.fetchSnapshots(
            symbol: symbol,
            interval: interval,
            startDate: rangeStart,
            endDate: nil
        )

        guard allowStale || OHLCCachePolicy.isUsable(
            snapshots: snapshots,
            period: period,
            interval: interval,
            now: now
        ) else {
            return []
        }

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

    /// yfinance accepts a fixed vocabulary for these; anything else is either a
    /// caller bug or an attempt to smuggle an argparse flag into argv.
    static func isValidPeriod(_ period: String) -> Bool {
        ["1d", "5d", "1mo", "3mo", "6mo", "1y", "2y", "5y", "10y", "ytd", "max"].contains(period)
    }

    static func isValidInterval(_ interval: String) -> Bool {
        ["1m", "2m", "5m", "15m", "30m", "60m", "90m", "1h", "1d", "5d", "1wk", "1mo", "3mo"].contains(interval)
    }

    private func parseOHLCOutput(_ output: String, symbol: String, interval: String) throws -> [OHLCSnapshot] {
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
                    volume: item.volume,
                    interval: interval
                )
            }
        } catch {
            Task { await Logger.shared.error("Failed to parse OHLC JSON: \(error)") }
            throw OHLCFetchError.invalidData
        }
    }
}

// MARK: - Cache Policy

/// Decides whether cached candles can stand in for a fresh fetch.
enum OHLCCachePolicy {
    /// Length of a yfinance period, or nil when open-ended (ytd, max).
    static func periodSeconds(_ period: String) -> TimeInterval? {
        let day: TimeInterval = 86_400
        switch period {
        case "1d": return day
        case "5d": return 5 * day
        case "1mo": return 30 * day
        case "3mo": return 90 * day
        case "6mo": return 180 * day
        case "1y": return 365 * day
        case "2y": return 730 * day
        case "5y": return 1_825 * day
        case "10y": return 3_650 * day
        default: return nil
        }
    }

    /// Length of one yfinance interval; unknown values are never trusted.
    static func intervalSeconds(_ interval: String) -> TimeInterval? {
        switch interval {
        case "1m": return 60
        case "2m": return 120
        case "5m": return 300
        case "15m": return 900
        case "30m": return 1_800
        case "60m", "1h": return 3_600
        case "90m": return 5_400
        case "1d": return 86_400
        case "5d": return 5 * 86_400
        case "1wk": return 7 * 86_400
        case "1mo": return 30 * 86_400
        case "3mo": return 90 * 86_400
        default: return nil
        }
    }

    /// `snapshots` must already be limited to the requested interval (and range
    /// start). Usable means non-empty, reaching back over the range (allowing
    /// for weekends, holidays and late listings) and with a newest candle no
    /// older than one interval.
    static func isUsable(
        snapshots: [OHLCSnapshot],
        period: String,
        interval: String,
        now: Date
    ) -> Bool {
        guard let intervalLength = intervalSeconds(interval),
              let oldest = snapshots.map(\.timestamp).min(),
              let newest = snapshots.map(\.timestamp).max() else {
            return false
        }

        if now.timeIntervalSince(newest) > intervalLength {
            return false
        }

        if let length = periodSeconds(period) {
            let slack = max(length * 0.4, 3 * 86_400, 2 * intervalLength)
            if oldest > now.addingTimeInterval(-length + slack) {
                return false
            }
        }
        return true
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
