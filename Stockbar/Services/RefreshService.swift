//
//  RefreshService.swift
//  Stockbar
//
//  Service responsible for managing stock price refresh operations
//  Handles both batch and staggered refresh strategies
//

import Foundation

/// Service managing stock price refresh operations
@MainActor
class RefreshService {
    // MARK: - Dependencies
    private let networkService: NetworkService
    private let cacheCoordinator: CacheCoordinator
    private let refreshCoordinator: RefreshCoordinator
    private weak var dataModel: DataModel?

    // MARK: - State
    private var refreshTimer: Timer?
    private var currentSymbolIndex = 0

    // MARK: - Configuration
    var refreshInterval: TimeInterval

    // MARK: - Initialization
    init(networkService: NetworkService,
         cacheCoordinator: CacheCoordinator,
         refreshCoordinator: RefreshCoordinator,
         refreshInterval: TimeInterval = 300) {
        self.networkService = networkService
        self.cacheCoordinator = cacheCoordinator
        self.refreshCoordinator = refreshCoordinator
        self.refreshInterval = refreshInterval
    }

    func setDataModel(_ dataModel: DataModel) {
        self.dataModel = dataModel
    }

    // MARK: - Batch Refresh

    /// Performs a refresh of trades. When `limitedTo` is provided, only those
    /// symbols are evaluated and fetched. Otherwise the entire portfolio is
    /// considered.
    ///
    /// - Parameter limitedTo: Optional list of symbols to refresh immediately.
    func performRefreshAllTrades(limitedTo targetSymbols: [String]? = nil) async {
        guard let dataModel = dataModel else { return }

        // Capture main-actor isolated properties before entering sendable closure
        let localCacheCoordinator = self.cacheCoordinator

        await refreshCoordinator.withLock {
            let now = Date()
            var symbolsToRefresh: [String] = []
            var symbolsToForceRefresh: [String] = []

            let allSymbols = dataModel.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
            let candidateSymbols: [String]

            if let targetSymbols, !targetSymbols.isEmpty {
                let targetSet = Set(targetSymbols.map { $0.uppercased() })
                candidateSymbols = allSymbols.filter { targetSet.contains($0.uppercased()) }
            } else {
                candidateSymbols = allSymbols
            }

            if candidateSymbols.isEmpty {
                Task { await Logger.shared.debug("refreshAllTrades(limitedTo:) called with no matching symbols – skipping fetch") }
                return
            }

            for symbol in candidateSymbols {
                if localCacheCoordinator.shouldRefresh(symbol: symbol, at: now) {
                    symbolsToRefresh.append(symbol)
                } else if localCacheCoordinator.shouldRetry(symbol: symbol, at: now) {
                    symbolsToForceRefresh.append(symbol)
                }
            }

            let finalSymbolsToRefresh = Array(Set(symbolsToRefresh + symbolsToForceRefresh))

            if finalSymbolsToRefresh.isEmpty {
                await Logger.shared.info("All \(candidateSymbols.count) targeted symbols are cached or in retry cooldown, skipping network refresh")
                return
            }

            await Logger.shared.info(
                "About to refresh \(finalSymbolsToRefresh.count) of \(candidateSymbols.count) targeted trades: \(finalSymbolsToRefresh)"
            )

            do {
                let results = try await networkService.fetchBatchQuotes(for: finalSymbolsToRefresh)

                guard !results.isEmpty else {
                    await Logger.shared.warning("Refresh completed but received no results from network service.")
                    return
                }

                var anySuccessfulUpdate = false
                let resultDict = Dictionary(uniqueKeysWithValues: results.map { ($0.symbol.uppercased(), $0) })

                let targetedSet = Set(finalSymbolsToRefresh.map { $0.uppercased() })

                for idx in dataModel.realTimeTrades.indices {
                    let symbol = dataModel.realTimeTrades[idx].trade.name
                    guard targetedSet.contains(symbol.uppercased()) else { continue }

                    if let res = resultDict[symbol.uppercased()] {
                        let wasSuccessful = dataModel.realTimeTrades[idx].updateWithResult(res, retainOnFailure: true)

                        if wasSuccessful {
                            localCacheCoordinator.setSuccessfulFetch(for: symbol, at: now)
                            await Logger.shared.debug("Updated cache for \(symbol) - successful fetch")
                            anySuccessfulUpdate = true

                            // Check price alerts after successful update
                            let newPrice = dataModel.realTimeTrades[idx].realTimeInfo.currentPrice
                            let prevClose = dataModel.realTimeTrades[idx].realTimeInfo.prevClosePrice
                            let currency = dataModel.realTimeTrades[idx].realTimeInfo.currency ?? "USD"
                            await PriceAlertService.shared.checkAlerts(
                                symbol: symbol,
                                currentPrice: newPrice,
                                previousPrice: prevClose,
                                currency: currency
                            )
                        } else {
                            localCacheCoordinator.setFailedFetch(for: symbol, at: now)
                            await Logger.shared.debug("Updated failure cache for \(symbol) - failed fetch, retaining old data")
                        }

                        await Logger.shared.debug("Updated trade \(symbol) from refresh result.")
                    } else {
                        localCacheCoordinator.setFailedFetch(for: symbol, at: now)
                        await Logger.shared.warning("No result returned for symbol \(symbol), treating as failure.")
                    }
                }

                if anySuccessfulUpdate {
                    dataModel.saveTradingInfo()
                    Task { await dataModel.historicalDataManager.recordSnapshot(from: dataModel) }

                    let randomCheck = Int.random(in: 1...100)

                    if randomCheck == 1 {
                        // 1% chance trigger retroactive calculation
                        Task {
                            await Logger.shared.info("🔄 PERIODIC: Triggering retroactive portfolio history calculation")
                            await dataModel.historicalDataManager.calculateRetroactivePortfolioHistory(using: dataModel)
                        }
                    }
                }
            } catch {
                await Logger.shared.error("Batch refresh failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Staggered Refresh

    /// Starts staggered refresh timer
    func startStaggeredRefresh() {
        stopStaggeredRefresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refreshNextSymbol()
            }
        }

        refreshTimer?.tolerance = 5.0
        refreshTimer?.fire()
    }

    /// Stops staggered refresh timer
    func stopStaggeredRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Refreshes the next symbol in the rotation
    private func refreshNextSymbol() async {
        await performRefreshNextSymbol()
    }

    /// Performs the actual refresh of the next symbol
    private func performRefreshNextSymbol() async {
        guard let dataModel = dataModel else { return }

        let now = Date()

        guard !dataModel.realTimeTrades.isEmpty else {
            await Logger.shared.debug("No trades to refresh")
            return
        }

        let symbol = dataModel.realTimeTrades[currentSymbolIndex].trade.name

        // Skip if symbol is empty or still cached
        if symbol.isEmpty {
            currentSymbolIndex = (currentSymbolIndex + 1) % max(dataModel.realTimeTrades.count, 1)
            return
        }

        if !cacheCoordinator.shouldRefresh(symbol: symbol, at: now) {
            if Int.random(in: 1...20) == 1 {
                let timeRemaining = cacheCoordinator.cacheInterval - now.timeIntervalSince(cacheCoordinator.getLastSuccessfulFetch(for: symbol) ?? Date.distantPast)
                Task.detached(priority: .utility) {
                    await Logger.shared.debug("Skipping \(symbol) - still cached (refresh in \(Int(timeRemaining))s)")
                }
            }
            currentSymbolIndex = (currentSymbolIndex + 1) % max(dataModel.realTimeTrades.count, 1)
            return
        }

        do {
            let result: StockFetchResult
            if let pythonService = networkService as? PythonNetworkService {
                result = try await pythonService.fetchEnhancedQuote(for: symbol)
            } else {
                result = try await networkService.fetchQuote(for: symbol)
            }

            if let index = dataModel.realTimeTrades.firstIndex(where: { $0.trade.name == symbol }) {
                let wasSuccessful = dataModel.realTimeTrades[index].updateWithResult(result, retainOnFailure: true)

                if wasSuccessful {
                    cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)
                    Task { await Logger.shared.debug("Updated individual cache for \(symbol) - successful fetch") }
                    dataModel.saveTradingInfo()

                    if Int.random(in: 1...10) == 1 {
                        Task.detached(priority: .utility) {
                            await Logger.shared.debug("✅ SUCCESS: Updated \(symbol) at \(Date()). Triggering snapshot after successful update for \(symbol) at \(Date())")
                        }
                    }

                    await dataModel.historicalDataManager.recordSnapshot(from: dataModel)

                    // Check price alerts after successful individual update
                    let newPrice = dataModel.realTimeTrades[index].realTimeInfo.currentPrice
                    let prevClose = dataModel.realTimeTrades[index].realTimeInfo.prevClosePrice
                    let currency = dataModel.realTimeTrades[index].realTimeInfo.currency ?? "USD"
                    await PriceAlertService.shared.checkAlerts(
                        symbol: symbol,
                        currentPrice: newPrice,
                        previousPrice: prevClose,
                        currency: currency
                    )
                } else {
                    cacheCoordinator.setFailedFetch(for: symbol, at: now)
                    Task { await Logger.shared.debug("Updated individual failure cache for \(symbol) - failed fetch, retaining old data") }

                    if Int.random(in: 1...5) == 1 {
                        Task.detached(priority: .utility) {
                            await Logger.shared.warning("❌ FAILED: Update failed for \(symbol) at \(Date())")
                        }
                    }
                }
            }
        } catch {
            cacheCoordinator.setFailedFetch(for: symbol, at: now)
            Task { await Logger.shared.debug("Individual refresh failed for \(symbol): \(error.localizedDescription)") }

            if Int.random(in: 1...3) == 1 {
                Task.detached(priority: .utility) {
                    await Logger.shared.error("🚨 ERROR: Network error for \(symbol) at \(Date()): \(error.localizedDescription)")
                }
            }
        }

        currentSymbolIndex = (currentSymbolIndex + 1) % max(dataModel.realTimeTrades.count, 1)
    }
}
