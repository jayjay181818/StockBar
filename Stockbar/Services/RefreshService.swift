//
//  RefreshService.swift
//  Stockbar
//
//  Service responsible for managing stock price refresh operations
//  Handles both batch and staggered refresh strategies
//

import Combine
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
    private var cancellables = Set<AnyCancellable>()
    private var scheduler: RefreshPassScheduler!
    private var lastImmediateFireAt: Date?
    /// When connectivity was last lost; used to forgive failures caused by the outage.
    private var offlineSince: Date?

    /// Failures recorded this long before connectivity was reported lost are still
    /// attributed to the outage (path monitoring lags the first failed fetch).
    private static let outageAttributionGrace: TimeInterval = 120

    /// Floor between the immediate refreshes triggered by timer (re)starts.
    /// `startRefreshTimer` is called from reactive paths — an interval change or
    /// a connectivity flap — and firing on every one of those would hammer the
    /// providers.
    private static let immediateFireCooldown: TimeInterval = 30

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
        self.scheduler = RefreshPassScheduler { [weak self] request in
            await self?.runRefreshPass(request)
        }
        
        setupConnectivityMonitoring()
    }
    
    private func setupConnectivityMonitoring() {
        ConnectivityMonitor.shared.$isConnected
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self else { return }
                if isConnected {
                    let outageStart = self.offlineSince
                    self.offlineSince = nil
                    Task { @MainActor in
                        // Failures caused by the outage must not keep symbols
                        // suspended for the full circuit-breaker timeout.
                        if let outageStart {
                            await self.clearNetworkCausedSuspensions(since: outageStart)
                        }
                        // If network returns, restart the timer (which also refreshes immediately)
                        if self.refreshTimer == nil {
                            self.startRefreshTimer()
                        }
                        await Logger.shared.info("🌐 Network restored: Resuming refresh operations")
                    }
                } else {
                    // Pause refresh timer when offline to save resources
                    if self.offlineSince == nil { self.offlineSince = Date() }
                    self.stopRefreshTimer()
                    Task { await Logger.shared.info("🌐 Network lost: Pausing refresh operations") }
                }
            }
            .store(in: &cancellables)
    }

    /// Un-suspends symbols whose recent failures happened during (or just before) an
    /// outage, and resets their backoff so the post-reconnect refresh retries them.
    private func clearNetworkCausedSuspensions(since outageStart: Date) async {
        guard let dataModel else { return }
        let cutoff = outageStart.addingTimeInterval(-Self.outageAttributionGrace)
        for symbol in Set(dataModel.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }) {
            guard let lastFailed = await cacheCoordinator.getLastFailedFetch(for: symbol),
                  lastFailed >= cutoff else { continue }
            await cacheCoordinator.clearSuspension(for: symbol)
            await Logger.shared.debug("Cleared outage-caused failures for \(symbol) after reconnect")
        }
    }

    func setDataModel(_ dataModel: DataModel) {
        self.dataModel = dataModel
    }

    // MARK: - Batch Refresh

    /// Performs a refresh of trades. When `limitedTo` is provided, only those
    /// symbols are evaluated and fetched. Otherwise the entire portfolio is
    /// considered.
    ///
    /// A request that arrives while a refresh is running is not dropped: it is
    /// queued and a follow-up pass runs once the current one finishes.
    ///
    /// - Parameters:
    ///   - limitedTo: Optional list of symbols to refresh immediately.
    ///   - force: User-initiated refresh. Skips the freshness check and retry
    ///     backoff (suspended symbols are still skipped unless explicitly targeted).
    func performRefreshAllTrades(limitedTo targetSymbols: [String]? = nil, force: Bool = false) async {
        let symbols = targetSymbols.flatMap { $0.isEmpty ? nil : Set($0.map { $0.uppercased() }) }
        await scheduler.schedule(RefreshRequest(symbols: symbols, force: force))
    }

    private func runRefreshPass(_ request: RefreshRequest) async {
        guard let dataModel = dataModel else { return }
        let targetSymbols: [String]? = request.symbols.map { Array($0) }
        let force = request.force

        guard ConnectivityMonitor.shared.isConnected else {
            await Logger.shared.debug("Offline – skipping refresh pass")
            return
        }

        let now = Date()
        var symbolsToRefresh: [String] = []
        var symbolsToForceRefresh: [String] = []

        let allSymbols = dataModel.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
        let baseCandidateSymbols: [String]

        let brokerRefreshPlan: BrokerLinkedMarketRefreshPlan

        if dataModel.isFolyncPortfolioActive {
            brokerRefreshPlan = .empty
            let allowed = dataModel.folyncRefreshableSymbols
            if let targetSymbols, !targetSymbols.isEmpty {
                let targets = Set(targetSymbols.map { $0.uppercased() })
                baseCandidateSymbols = allSymbols.filter { allowed.contains($0.uppercased()) && targets.contains($0.uppercased()) }
            } else {
                baseCandidateSymbols = allSymbols.filter { allowed.contains($0.uppercased()) }
            }
        } else if let targetSymbols, !targetSymbols.isEmpty {
            brokerRefreshPlan = .empty
            let targetSet = Set(targetSymbols.map { $0.uppercased() })
            baseCandidateSymbols = allSymbols.filter { targetSet.contains($0.uppercased()) }
        } else {
            brokerRefreshPlan = await dataModel.trading212LinkedMarketRefreshPlan()
            baseCandidateSymbols = allSymbols.filter { !brokerRefreshPlan.skipSymbols.contains($0.uppercased()) }
        }

        let benchmarkRouteActive = FolyncSettingsStore.shared.load()
            .isSupplementalRouteActive(.benchmarkMarketData)
        let candidateSymbols = Self.filterFolyncRoutedBenchmarks(
            from: baseCandidateSymbols,
            routeActive: benchmarkRouteActive,
            sourceStatus: dataModel.folyncSupplementalStatuses[.benchmarkMarketData]
        )

        if candidateSymbols.isEmpty {
            Task { await Logger.shared.debug("refreshAllTrades(limitedTo:) called with no matching symbols – skipping fetch") }
            return
        }

        // Honour the user's "Main Refresh Interval". The small grace factor
        // keeps timer tolerance from making each pass see a just-too-young
        // quote and silently doubling the effective interval.
        let freshnessInterval = Self.freshnessInterval(forRefreshInterval: refreshInterval)
        for symbol in candidateSymbols {
            if force {
                let explicitlyTargeted = request.symbols?.contains(symbol.uppercased()) ?? false
                let suspended = await cacheCoordinator.isSuspended(symbol: symbol, at: now)
                if explicitlyTargeted || !suspended {
                    symbolsToForceRefresh.append(symbol)
                }
            } else if await cacheCoordinator.shouldRefresh(symbol: symbol, at: now, freshnessInterval: freshnessInterval) {
                symbolsToRefresh.append(symbol)
            } else if await cacheCoordinator.shouldRetry(symbol: symbol, at: now) {
                symbolsToForceRefresh.append(symbol)
            }
        }

        let finalSymbolsToRefresh = Array(Set(symbolsToRefresh + symbolsToForceRefresh))

        if finalSymbolsToRefresh.isEmpty {
            await Logger.shared.debug(
                "All \(candidateSymbols.count) targeted symbols are cached or in retry cooldown, skipping network refresh"
            )
            return
        }

        await Logger.shared.debug(
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

            let resultDict = Dictionary(firstValuesFor: results.map { ($0.symbol.uppercased(), $0) })

            let targetedSet = Set(finalSymbolsToRefresh.map { $0.uppercased() })

            // Snapshot the symbols up front, then re-resolve each one by identity
            // inside the loop. This method suspends on every `await`, which lets
            // other @MainActor work (holding deletion, Trading 212 sync, a Folync
            // portfolio swap) mutate or reorder `realTimeTrades` underneath us —
            // a captured index would go stale and either trap or update the
            // wrong holding.
            let symbolsToApply = dataModel.realTimeTrades
                .map { $0.trade.name }
                .filter { targetedSet.contains($0.uppercased()) }

            for symbol in symbolsToApply {
                guard let idx = dataModel.realTimeTrades.firstIndex(
                    where: { $0.trade.name == symbol }
                ) else { continue }

                if let res = resultDict[symbol.uppercased()] {
                    let wasSuccessful = dataModel.realTimeTrades[idx].updateWithResult(res, retainOnFailure: true)

                    // Read everything this iteration needs while still in the same
                    // synchronous region as the update — `idx` is only valid until
                    // the next suspension point.
                    let info = dataModel.realTimeTrades[idx].realTimeInfo
                    let newPrice = info.getCurrentDisplayPrice()
                    let prevClose = info.prevClosePrice
                    let currency = info.currency ?? "USD"

                    if wasSuccessful {
                        await cacheCoordinator.setSuccessfulFetch(for: symbol, at: now)
                        await Logger.shared.debug("Updated cache for \(symbol) - successful fetch")
                        anySuccessfulUpdate = true
                        successfullyRefreshedSymbols.insert(symbol.uppercased())

                        // Check price alerts after successful update
                        dataModel.historicalDataManager.recordLivePriceSample(
                            symbol: symbol,
                            price: newPrice,
                            previousClose: prevClose,
                            timestamp: now
                        )
                        PriceAlertService.shared.checkAlerts(
                            symbol: symbol,
                            currentPrice: newPrice,
                            previousPrice: prevClose,
                            currency: currency
                        )
                    } else {
                        await recordFailure(for: symbol, at: now)
                        await Logger.shared.debug("Updated failure cache for \(symbol) - failed fetch, retaining old data")
                    }

                    await Logger.shared.debug("Updated trade \(symbol) from refresh result.")
                } else {
                    await recordFailure(for: symbol, at: now)
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
                    currency: summary.currency,
                    timestamp: now
                )
                Task { dataModel.historicalDataManager.recordSnapshot(from: dataModel) }

                await Logger.shared.info(
                    "Refresh completed: \(successfullyRefreshedSymbols.count)/\(finalSymbolsToRefresh.count) symbols updated"
                )
            }
        } catch let error as ProviderAccessError {
            await Logger.shared.debug("Batch refresh skipped: \(error.localizedDescription)")
        } catch {
            await Logger.shared.error("Batch refresh failed: \(error.localizedDescription)")
        }
    }

    /// Counts a failed fetch toward the circuit breaker, unless the device is
    /// offline: an outage says nothing about the symbol, and suspensions it caused
    /// would outlive the outage by up to the breaker timeout.
    private func recordFailure(for symbol: String, at time: Date) async {
        guard ConnectivityMonitor.shared.isConnected else {
            await Logger.shared.debug("Offline – not counting failed fetch for \(symbol)")
            return
        }
        await cacheCoordinator.setFailedFetch(for: symbol, at: time)
    }

    nonisolated static func freshnessInterval(forRefreshInterval interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 300 }
        return max(30, interval * 0.9)
    }

    nonisolated static func filterFolyncRoutedBenchmarks(
        from symbols: [String],
        routeActive: Bool,
        sourceStatus: FolyncSupplementalSourceStatus?
    ) -> [String] {
        guard routeActive, sourceStatus != .legacy else { return symbols }
        return symbols.filter { !SymbolMetadata.isBenchmarkSymbol($0) }
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

        // Fire immediately to start, but not if we just did — see cooldown note.
        let now = Date()
        if let last = lastImmediateFireAt,
           now.timeIntervalSince(last) < Self.immediateFireCooldown {
            Task {
                await Logger.shared.debug(
                    "Refresh timer restarted within cooldown, skipping immediate fire"
                )
            }
            return
        }
        lastImmediateFireAt = now
        refreshTimer?.fire()
    }

    /// Stops the refresh timer
    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // Legacy support / Staggered refresh placeholders if needed
    // For now, we unify on batch refresh per the optimization plan
}

/// One requested refresh pass. `symbols == nil` means the whole portfolio.
struct RefreshRequest: Equatable, Sendable {
    var symbols: Set<String>?
    var force: Bool
}

/// Pending refresh requests that arrived while a pass was running. Requests with
/// the same `force` merge (a whole-portfolio request absorbs targeted ones);
/// forced requests are served first.
struct RefreshRequestQueue: Sendable {
    private(set) var pending: [RefreshRequest] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func enqueue(_ request: RefreshRequest) {
        guard let index = pending.firstIndex(where: { $0.force == request.force }) else {
            pending.append(request)
            return
        }
        if let existing = pending[index].symbols, let incoming = request.symbols {
            pending[index].symbols = existing.union(incoming)
        } else {
            pending[index].symbols = nil
        }
    }

    mutating func dequeue() -> RefreshRequest? {
        guard !pending.isEmpty else { return nil }
        let index = pending.firstIndex(where: \.force) ?? 0
        return pending.remove(at: index)
    }
}

/// Serialises refresh passes. A request made during a running pass is queued and
/// served by a follow-up pass instead of being dropped.
@MainActor
final class RefreshPassScheduler {
    private var queue = RefreshRequestQueue()
    private(set) var isRunning = false
    private let runPass: (RefreshRequest) async -> Void

    init(runPass: @escaping (RefreshRequest) async -> Void) {
        self.runPass = runPass
    }

    func schedule(_ request: RefreshRequest) async {
        if isRunning {
            queue.enqueue(request)
            return
        }
        isRunning = true
        defer { isRunning = false }

        var next: RefreshRequest? = request
        while let current = next {
            await runPass(current)
            next = queue.dequeue()
        }
    }
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
