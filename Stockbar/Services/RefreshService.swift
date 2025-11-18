//
//  RefreshService.swift
//  Stockbar
//
//  Service responsible for managing stock price refresh operations
//  Handles both batch and staggered refresh strategies
//

import Foundation
import Combine

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
    private var cancellables = Set<AnyCancellable>()
    private var isRefreshing = false

    // MARK: - Configuration
    var refreshInterval: TimeInterval {
        didSet {
            if refreshTimer != nil {
                startRefreshTimer()
            }
        }
    }

    // MARK: - Initialization
    init(networkService: NetworkService,
         cacheCoordinator: CacheCoordinator,
         refreshCoordinator: RefreshCoordinator,
         refreshInterval: TimeInterval = 300) {
        self.networkService = networkService
        self.cacheCoordinator = cacheCoordinator
        self.refreshCoordinator = refreshCoordinator
        self.refreshInterval = refreshInterval
        
        setupConnectivityMonitoring()
    }
    
    private func setupConnectivityMonitoring() {
        ConnectivityMonitor.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self else { return }
                if isConnected {
                    // If network returns, trigger an immediate refresh if needed or restart timer
                    if self.refreshTimer == nil {
                         self.startRefreshTimer()
                    }
                    // Optionally trigger immediate refresh if it was down for a while
                    Task { await Logger.shared.info("🌐 Network restored: Resuming refresh operations") }
                } else {
                    // Pause refresh timer when offline to save resources
                    self.stopRefreshTimer()
                    Task { await Logger.shared.info("🌐 Network lost: Pausing refresh operations") }
                }
            }
            .store(in: &cancellables)
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
        
        // Prevent concurrent refreshes
        if isRefreshing {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

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
            if await cacheCoordinator.shouldRefresh(symbol: symbol, at: now) {
                symbolsToRefresh.append(symbol)
            } else if await cacheCoordinator.shouldRetry(symbol: symbol, at: now) {
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
                        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)
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
                        await cacheCoordinator.setFailedFetch(for: symbol, at: now)
                        await Logger.shared.debug("Updated failure cache for \(symbol) - failed fetch, retaining old data")
                    }

                    await Logger.shared.debug("Updated trade \(symbol) from refresh result.")
                } else {
                    await cacheCoordinator.setFailedFetch(for: symbol, at: now)
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

    // MARK: - Refresh Timer

    /// Starts the refresh timer (Batch Refresh)
    func startRefreshTimer() {
        stopRefreshTimer()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performRefreshAllTrades()
            }
        }

        refreshTimer?.tolerance = 5.0
        refreshTimer?.fire() // Fire immediately to start
    }

    /// Stops the refresh timer
    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // Legacy support / Staggered refresh placeholders if needed
    // For now, we unify on batch refresh per the optimization plan
}
