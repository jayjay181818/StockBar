import AppKit
import Charts
import SwiftUI

extension PerformanceChartView {
    func loadOHLCData() async {
        ohlcRequestGeneration &+= 1
        let requestGeneration = ohlcRequestGeneration
        let configurationRevision = historicalDataManager.folyncSupplementalConfigurationRevision
        guard case .individualStock(let symbol) = selectedChartType else {
            ohlcData = []
            ohlcSourceStatus = nil
            ohlcCoverageLabel = nil
            isLoadingOHLC = false
            return
        }

        isLoadingOHLC = true

        do {
            // Map time range to yfinance period
            let period = selectedTimeRange.yfinancePeriod
            let interval = selectedTimeRange.suggestedInterval

            let useFolyncRoute = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts)
            // A custom range has no fixed period to validate the cache against, so it always refetches.
            if !useFolyncRoute, selectedTimeRange != .custom {
                // Existing local OHLC remains untouched and is used whenever the Folync route is off.
                let cachedData = try await ohlcFetchService.getCachedOHLCData(
                    symbol: symbol,
                    period: period,
                    interval: interval
                )

                if !cachedData.isEmpty {
                    await MainActor.run {
                        guard requestGeneration == ohlcRequestGeneration,
                              configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                        ohlcData = ChartSeriesProcessing.aggregatedCandles(cachedData)
                        ohlcSourceStatus = .legacy
                        ohlcCoverageLabel = "\(cachedData.count) points · \(interval) · local cache"
                        isLoadingOHLC = false
                    }
                    await Logger.shared.info("Loaded \(cachedData.count) cached OHLC data points for \(symbol)")
                    return
                }
            }

            // Fetch fresh data from yfinance
            let result = try await ohlcFetchService.fetchOHLCDataWithSource(
                symbol: symbol,
                period: period,
                interval: interval,
                from: queryCustomFrom,
                to: queryCustomTo
            )

            // Convert to OHLCDataPoint
            let dataPoints = result.snapshots.map { snapshot in
                OHLCDataPoint(
                    timestamp: snapshot.timestamp,
                    open: snapshot.open,
                    high: snapshot.high,
                    low: snapshot.low,
                    close: snapshot.close,
                    volume: snapshot.volume
                )
            }

            await MainActor.run {
                guard requestGeneration == ohlcRequestGeneration,
                      configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                ohlcData = ChartSeriesProcessing.aggregatedCandles(dataPoints)
                ohlcSourceStatus = result.sourceStatus
                ohlcCoverageLabel = result.coverageLabel
                isLoadingOHLC = false
            }

            await Logger.shared.info("Loaded \(dataPoints.count) OHLC data points for \(symbol)")
        } catch {
            // Offline or provider failure: older local candles beat an empty chart.
            let staleData: [OHLCDataPoint]
            if !FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts),
               selectedTimeRange != .custom {
                staleData = (try? await ohlcFetchService.getCachedOHLCData(
                    symbol: symbol,
                    period: selectedTimeRange.yfinancePeriod,
                    interval: selectedTimeRange.suggestedInterval,
                    allowStale: true
                )) ?? []
            } else {
                staleData = []
            }
            await MainActor.run {
                guard requestGeneration == ohlcRequestGeneration,
                      configurationRevision == historicalDataManager.folyncSupplementalConfigurationRevision else { return }
                isLoadingOHLC = false
                if !staleData.isEmpty {
                    ohlcData = ChartSeriesProcessing.aggregatedCandles(staleData)
                    ohlcSourceStatus = .legacy
                    ohlcCoverageLabel = "\(staleData.count) points · \(selectedTimeRange.suggestedInterval) · stale local cache"
                    return
                }
                ohlcData = []
                if FolyncSettingsStore.shared.load().isSupplementalRouteActive(.candlestickCharts) {
                    ohlcSourceStatus = .unavailable
                    ohlcCoverageLabel = nil
                }
            }
            if error is CancellationError {
                await Logger.shared.debug("OHLC load cancelled for \(symbol)")
            } else {
                await Logger.shared.warning("Failed to load OHLC data for \(symbol): \(error)")
            }
        }
    }

    /// Discards loaded candles and invalidates any load still in flight.
    func resetOHLCState() {
        ohlcRequestGeneration &+= 1
        ohlcData = []
        ohlcSourceStatus = nil
        ohlcCoverageLabel = nil
        isLoadingOHLC = false
    }

    var candlestickChartPlaceholder: some View {
        Group {
            if isLoadingOHLC {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading OHLC data...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(height: 300)
            } else if ohlcData.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar")
                        .accessibilityHidden(true)
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)

                    Text("Candlestick Chart")
                        .font(.headline)

                    Text("No candlestick data is available for this selection.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await loadOHLCData()
                        }
                    }) {
                        Label("Load Candlestick Data", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)

                    Button(action: {
                        chartVisualizationStyle = .line
                    }) {
                        Label("Switch to Line Chart", systemImage: "chart.xyaxis.line")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(height: 300)
            } else {
                    CandlestickChartView(
                    data: ohlcData,
                    currency: getDisplayCurrency(),
                    settings: candlestickSettings,
                    symbol: {
                        if case .individualStock(let symbol) = selectedChartType {
                            return symbol
                        }
                        return nil
                    }()
                )
                .frame(height: 400)
            }
        }
        .onChange(of: selectedChartType) {
            if isCandlestickActive {
                Task {
                    await loadOHLCData()
                }
            }
        }
        .onChange(of: selectedTimeRange) {
            if isCandlestickActive {
                Task {
                    await loadOHLCData()
                }
            }
        }
    }
}
