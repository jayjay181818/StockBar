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
         refreshInterval: TimeInterval = 300) {
        self.networkService = networkService
        self.cacheCoordinator = cacheCoordinator
        self.refreshInterval = Self.clampedRefreshInterval(refreshInterval)
        self.scheduler = RefreshPassScheduler { [weak self] request in
            await self?.runRefreshPass(request)
        }
        
        setupConnectivityMonitoring()
    }
    
    private func setupConnectivityMonitoring() {
        ObservationPublisher.values(ConnectivityMonitor.shared, \.isConnected)
            .removeDuplicates()
            .dropFirst()
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

        // A user-requested refresh always tries; automatic passes wait out a failing provider.
        if !force, let wait = await cacheCoordinator.providerBackoffRemaining(at: now) {
            await Logger.shared.debug("Quote provider back-off active for \(Int(wait))s – skipping refresh pass")
            return
        }

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

        await cacheCoordinator.setFreshnessInterval(Self.freshnessInterval(forRefreshInterval: refreshInterval))
        let finalSymbolsToRefresh = await symbolsDue(among: candidateSymbols, request: request, at: now)

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
        var failedSymbols: [(symbol: String, failure: QuoteFailure)] = []

        do {
            let results = try await networkService.fetchBatchQuotes(for: finalSymbolsToRefresh)

            guard !results.isEmpty else {
                await Logger.shared.warning("Refresh completed but received no results from network service.")
                dataModel.quoteRefreshStatus.record(
                    attempted: finalSymbolsToRefresh.count,
                    failures: Array(repeating: .noData, count: finalSymbolsToRefresh.count),
                    at: now
                )
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
                        failedSymbols.append((symbol, res.failure ?? .noData))
                        await Logger.shared.debug(
                            "Quote for \(symbol) failed (\((res.failure ?? .noData).rawValue)), retaining old data"
                        )
                    }
                } else {
                    failedSymbols.append((symbol, .noData))
                    await Logger.shared.warning("No result returned for symbol \(symbol), treating as failure.")
                }
            }

            await recordFailures(failedSymbols, anySucceeded: anySuccessfulUpdate, at: now)
            dataModel.quoteRefreshStatus.record(
                attempted: symbolsToApply.count,
                failures: failedSymbols.map(\.failure),
                at: now
            )

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
        } catch is CancellationError {
            await Logger.shared.debug("Batch refresh cancelled")
        } catch NetworkError.pythonInterpreterNotFound(let path) {
            // Nothing to retry and nobody to back off from: say so once and wait
            // for the environment to be set up.
            let isNew = dataModel.quoteRefreshStatus.recordSetupProblem(
                "Prices cannot be fetched: Python is not set up (Settings > Advanced > Python)",
                attempted: finalSymbolsToRefresh.count,
                at: now
            )
            if isNew {
                await Logger.shared.error("Quote refresh needs Python, which is missing at \(path)")
            }
        } catch {
            await Logger.shared.error("Batch refresh failed: \(error.localizedDescription)")
            dataModel.quoteRefreshStatus.record(
                attempted: finalSymbolsToRefresh.count,
                failures: Array(repeating: .network, count: finalSymbolsToRefresh.count),
                at: now
            )
            // The whole batch failed, so no symbol is to blame.
            if ConnectivityMonitor.shared.isConnected {
                let wait = await cacheCoordinator.recordProviderFailure(at: now)
                await Logger.shared.warning("Quote provider back-off: next automatic refresh in \(Int(wait))s")
            }
        }
    }

    /// The candidates this pass should fetch: quotes older than the user's "Main
    /// Refresh Interval" (longer while the exchange is shut), plus failed symbols whose
    /// back-off has run out. A forced pass takes everything except suspended symbols
    /// the user did not name.
    private func symbolsDue(among candidates: [String], request: RefreshRequest, at now: Date) async -> [String] {
        var due: Set<String> = []
        for symbol in candidates {
            if request.force {
                let explicitlyTargeted = request.symbols?.contains(symbol.uppercased()) ?? false
                let suspended = await cacheCoordinator.isSuspended(symbol: symbol, at: now)
                if explicitlyTargeted || !suspended { due.insert(symbol) }
                continue
            }
            let freshness = Self.freshnessInterval(forRefreshInterval: refreshInterval, symbol: symbol, at: now)
            let refresh = await cacheCoordinator.shouldRefresh(symbol: symbol, at: now, freshnessInterval: freshness)
            let retry = await cacheCoordinator.shouldRetry(symbol: symbol, at: now)
            if refresh || retry { due.insert(symbol) }
        }
        return Array(due)
    }

    /// Sorts one pass's failures into symbol faults and provider faults.
    ///
    /// A failure counts toward the symbol's own back-off and circuit breaker when the
    /// provider is otherwise working. When nothing succeeded, throttling, timeouts and
    /// connection errors, or several symbols failing together, share one provider
    /// back-off instead, so a bad hour at the provider cannot suspend every holding.
    /// Nothing is counted while offline, because an outage says nothing about a symbol.
    private func recordFailures(
        _ failures: [(symbol: String, failure: QuoteFailure)],
        anySucceeded: Bool,
        at time: Date
    ) async {
        if anySucceeded {
            await cacheCoordinator.recordProviderSuccess()
        }
        guard !failures.isEmpty else { return }
        guard ConnectivityMonitor.shared.isConnected else {
            await Logger.shared.debug("Offline – not counting \(failures.count) failed fetch(es)")
            return
        }

        let outcome = Self.classifyFailures(failures.map(\.failure), anySucceeded: anySucceeded)
        if outcome.providerFailed {
            let wait = await cacheCoordinator.recordProviderFailure(at: time)
            let causes = Set(failures.map(\.failure.rawValue)).sorted().joined(separator: ", ")
            await Logger.shared.warning(
                "Quote refresh failed for all \(failures.count) symbol(s) (\(causes)); next automatic refresh in \(Int(wait))s"
            )
        }
        guard outcome.countsAgainstSymbols else { return }
        // When other symbols succeeded the provider is evidently working, so even a
        // timeout is this symbol's own problem and must back off like any other.
        for entry in failures where anySucceeded || !entry.failure.isProviderWide {
            await cacheCoordinator.setFailedFetch(for: entry.symbol, at: time)
        }
    }

    nonisolated static func classifyFailures(
        _ failures: [QuoteFailure],
        anySucceeded: Bool
    ) -> (providerFailed: Bool, countsAgainstSymbols: Bool) {
        guard !failures.isEmpty else { return (false, false) }
        if anySucceeded { return (false, true) }
        let wholePassFailed = failures.count > 1
        let providerFailed = wholePassFailed || failures.contains(where: \.isProviderWide)
        return (providerFailed, !wholePassFailed)
    }

    /// The supported range of the "Main Refresh Interval". A stored or imported value
    /// outside it (zero, negative, a boolean) would otherwise reach `Timer` directly
    /// and refresh many times a second.
    nonisolated static let refreshIntervalRange: ClosedRange<TimeInterval> = 60...3_600
    nonisolated static let defaultRefreshInterval: TimeInterval = 300

    nonisolated static func clampedRefreshInterval(_ interval: TimeInterval?) -> TimeInterval {
        guard let interval, interval.isFinite, interval > 1 else { return defaultRefreshInterval }
        return min(max(interval, refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
    }

    nonisolated static func freshnessInterval(forRefreshInterval interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 300 }
        return max(30, interval * 0.9)
    }

    /// How long a quote stays fresh while its exchange is shut.
    nonisolated static let closedMarketFreshness: TimeInterval = 1_800

    /// The freshness interval for one symbol. A London or US listing cannot change
    /// price at the weekend or overnight, so it is polled slowly then rather than at
    /// the full rate round the clock. Exchange holidays are not known and poll normally.
    nonisolated static func freshnessInterval(
        forRefreshInterval interval: TimeInterval,
        symbol: String,
        at now: Date
    ) -> TimeInterval {
        let base = freshnessInterval(forRefreshInterval: interval)
        guard let closed = isExchangeClosed(for: symbol, at: now), closed else { return base }
        return max(base, closedMarketFreshness)
    }

    /// Whether the symbol's exchange is outside its extended trading day, or nil when
    /// the exchange is not one whose hours are known (other suffixes, crypto, FX, futures).
    nonisolated static func isExchangeClosed(for symbol: String, at now: Date) -> Bool? {
        let upper = symbol.uppercased()
        let isUK = SymbolMetadata.isUKSymbol(upper)
        let isPlainUSTicker = !upper.contains(".") && !upper.contains("-") && !upper.contains("=")
        guard isUK || isPlainUSTicker,
              let timeZone = TimeZone(identifier: SymbolMetadata.defaultTimezone(for: upper)) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDateInWeekend(now) { return true }

        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // London 07:00–18:00 covers the auctions; New York 04:00–20:00 covers pre- and post-market.
        let open = isUK ? 7 * 60 : 4 * 60
        let close = isUK ? 18 * 60 : 20 * 60
        return minutes < open || minutes >= close
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
        // A settings import pauses refresh until Stockbar relaunches.
        guard dataModel?.isBackgroundWorkPausedForImport != true else { return }

        let interval = Self.clampedRefreshInterval(refreshInterval)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
