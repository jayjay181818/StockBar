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

        let brokerRefreshPlan: BrokerLinkedMarketRefreshPlan

        if let targetSymbols, !targetSymbols.isEmpty {
            brokerRefreshPlan = .empty
            let targetSet = Set(targetSymbols.map { $0.uppercased() })
            candidateSymbols = allSymbols.filter { targetSet.contains($0.uppercased()) }
        } else {
            brokerRefreshPlan = await dataModel.trading212LinkedMarketRefreshPlan()
            candidateSymbols = allSymbols.filter { !brokerRefreshPlan.skipSymbols.contains($0.uppercased()) }
        }

        if candidateSymbols.isEmpty {
            Task { await Logger.shared.debug("refreshAllTrades(limitedTo:) called with no matching symbols – skipping fetch") }
            return
        }

        for symbol in candidateSymbols {
            let freshnessInterval = brokerRefreshPlan.extendedSessionSymbols.contains(symbol.uppercased())
                ? refreshInterval
                : nil

            if await cacheCoordinator.shouldRefresh(symbol: symbol, at: now, freshnessInterval: freshnessInterval) {
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

        var anySuccessfulUpdate = false
        var successfullyRefreshedSymbols: Set<String> = []

        do {
            let results = try await networkService.fetchBatchQuotes(for: finalSymbolsToRefresh)

            guard !results.isEmpty else {
                await Logger.shared.warning("Refresh completed but received no results from network service.")
                return
            }

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
                        successfullyRefreshedSymbols.insert(symbol.uppercased())

                        // Check price alerts after successful update
                        let newPrice = dataModel.realTimeTrades[idx].realTimeInfo.getCurrentDisplayPrice()
                        let prevClose = dataModel.realTimeTrades[idx].realTimeInfo.prevClosePrice
                        let currency = dataModel.realTimeTrades[idx].realTimeInfo.currency ?? "USD"
                        dataModel.historicalDataManager.recordLivePriceSample(
                            symbol: symbol,
                            price: newPrice,
                            previousClose: prevClose,
                            timestamp: now
                        )
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
                let summary = dataModel.calculateDisplayPortfolioSummary(
                    preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
                )
                dataModel.historicalDataManager.recordLivePortfolioSample(
                    totalValue: summary.totalValue,
                    totalGains: summary.totalGain,
                    timestamp: now
                )
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

struct BrokerLinkedMarketRefreshPlan {
    let skipSymbols: Set<String>
    let extendedSessionSymbols: Set<String>

    static let empty = BrokerLinkedMarketRefreshPlan(skipSymbols: [], extendedSessionSymbols: [])
}

enum BrokerLinkedMarketDataRefreshPolicy {
    static func shouldSkipMarketRefresh(
        symbol: String,
        tradingInfo: TradingInfo?,
        now: Date = Date()
    ) -> Bool {
        let knownState = normalizedState(tradingInfo?.marketState)
        let inferredState = normalizedState(inferredMarketState(for: symbol, at: now))
        return !isExtendedMarketState(knownState) && !isExtendedMarketState(inferredState)
    }

    static func inferredMarketState(for symbol: String, at date: Date = Date()) -> String? {
        let timeZone = TimeZone(identifier: SymbolMetadata.defaultTimezone(for: symbol)) ?? TimeZone.current
        let components = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: date)
        let hour = components.hour ?? 12
        let minute = components.minute ?? 0
        let weekday = components.weekday ?? 1

        guard weekday != 1, weekday != 7 else {
            return "CLOSED"
        }

        if SymbolMetadata.isUKSymbol(symbol) {
            if hour >= 7 && hour < 8 {
                return "PRE"
            }
            if hour >= 8 && (hour < 16 || (hour == 16 && minute < 30)) {
                return "REGULAR"
            }
            if (hour == 16 && minute >= 30) || (hour == 17 && minute < 30) {
                return "POST"
            }
            return "CLOSED"
        }

        if hour >= 4 && (hour < 9 || (hour == 9 && minute < 30)) {
            return "PRE"
        }
        if (hour == 9 && minute >= 30) || (hour >= 10 && hour < 16) {
            return "REGULAR"
        }
        if hour >= 16 && hour < 20 {
            return "POST"
        }
        return "CLOSED"
    }

    private static func normalizedState(_ state: String?) -> String? {
        state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isExtendedMarketState(_ state: String?) -> Bool {
        state == "PRE" || state == "POST"
    }
}
