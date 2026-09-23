import Foundation

enum FolyncConnectionState: Equatable {
    case notConfigured
    case connecting
    case current(asOf: String?)
    case stale(asOf: String?, reasons: [String])
    case rebuilding(asOf: String?, reasons: [String])
    case offlineCached(message: String)
    case unauthorized
    case incompatible

    var message: String {
        switch self {
        case .notConfigured: return "Folync is not configured."
        case .connecting: return "Connecting to Folync…"
        case .current(let asOf): return asOf.map { "Current as of \($0)." } ?? "Current."
        case .stale(let asOf, let reasons):
            return "Stale\(asOf.map { " as of \($0)" } ?? ""): \(reasons.joined(separator: ", "))"
        case .rebuilding(_, let reasons): return "Folync is rebuilding: \(reasons.joined(separator: ", "))"
        case .offlineCached(let message): return "Offline — showing last Folync data. \(message)"
        case .unauthorized: return "Folync access token was rejected."
        case .incompatible: return "Folync API version is incompatible."
        }
    }
}

extension DataModel {
    func testFolyncConnection(baseURL: URL, token: String) async throws -> [FolyncPortfolio] {
        folyncConnectionState = .connecting
        let source = try FolyncPortfolioSource(baseURL: baseURL, token: token)
        let portfolios = try await source.listPortfolios()
        folyncCapabilities = try? await source.fetchCapabilities()
        folyncConnectionState = .notConfigured
        return portfolios
    }

    func previewFolyncPortfolio(baseURL: URL, token: String, scopeID: String) async throws -> FolyncPortfolioSnapshot {
        folyncConnectionState = .connecting
        let source = try FolyncPortfolioSource(baseURL: baseURL, token: token)
        let result = try await source.fetchSnapshot(scopeID: scopeID, etag: nil)
        guard case .changed(let snapshot, _) = result else { throw FolyncPortfolioSourceError.invalidResponse }
        folyncConnectionState = connectionState(for: snapshot)
        return snapshot
    }

    func activateFolyncPortfolio(baseURL: URL, token: String, scopeID: String) async throws {
        folyncConnectionState = .connecting
        let source = try FolyncPortfolioSource(baseURL: baseURL, token: token)
        let portfolios = try await source.listPortfolios()
        guard portfolios.contains(where: { $0.id == scopeID }) else {
            throw FolyncPortfolioSourceError.invalidPayload("Selected portfolio scope is unavailable")
        }
        let result = try await source.fetchSnapshot(scopeID: scopeID, etag: nil)
        guard case .changed(let snapshot, let etag) = result else {
            throw FolyncPortfolioSourceError.invalidResponse
        }
        let capabilities = try? await source.fetchCapabilities()
        try FolyncCredentialStore.shared.save(token: token)
        // A successful hot reconfiguration establishes a new cache/overlay
        // identity. Remove only in-memory overlays from the previous endpoint
        // or scope; local history and the separate Folync disk caches remain.
        restoreFolyncBenchmarkOverlays()
        currencyConverter.deactivateFolyncOverlay()
        HistoricalDataManager.shared.clearFolyncSupplementalOverlays()
        folyncSupplementalStatuses = [:]
        await FolyncSupplementalCoordinator.shared.clearInMemoryState()
        FolyncSettingsStore.shared.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: baseURL.absoluteString,
            scopeID: scopeID,
            pollingIntervalSeconds: 60,
            supplemental: .newConnectionDefaults(capabilities: capabilities)
        ))
        HistoricalDataManager.shared.noteFolyncSupplementalConfigurationChanged()
        folyncCapabilities = capabilities
        folyncETag = etag
        applyFolyncSnapshot(snapshot)
        try await FolyncSnapshotCache.shared.save(FolyncCachedSnapshot(
            endpoint: baseURL.absoluteString,
            scopeID: scopeID,
            etag: etag,
            snapshot: snapshot
        ))
        await restartFolyncPortfolioScheduler(runImmediately: false)
    }

    /// Reads the Folync token off the main actor.
    ///
    /// These call sites run during `DataModel.init` and from timer callbacks. A
    /// Keychain read can block on internal locks or a locked keychain, and on
    /// the main thread that stalls the entire app — trade loading, the first
    /// refresh pass and every UI update sit behind it.
    private static func loadFolyncTokenOffMainActor() async -> String? {
        await Task.detached(priority: .userInitiated) {
            try? FolyncCredentialStore.shared.load()
        }.value
    }

    func restartFolyncPortfolioScheduler(runImmediately: Bool) async {
        folyncRefreshGeneration = UUID()
        let generation = folyncRefreshGeneration
        folyncRefreshTimer?.invalidate()
        folyncRefreshTimer = nil
        folyncNextCheckAt = nil
        folyncRefreshTask?.cancel()
        folyncRefreshTask = nil
        folyncRefreshRequestID = nil
        let settings = FolyncSettingsStore.shared.load()
        guard settings.isEnabled else { return }

        folyncCapabilities = await FolyncSupplementalCoordinator.shared.capabilitiesForCurrentSettings(refresh: true)
        guard generation == folyncRefreshGeneration, !Task.isCancelled else { return }
        if runImmediately {
            await refreshFolyncPortfolio()
        } else {
            scheduleFolyncCheck(at: FolyncRefreshSchedule.nextRegularCheck(after: Date()), isCatchUp: false)
        }
        guard generation == folyncRefreshGeneration, !Task.isCancelled else { return }
        await restartFolyncSupplementalScheduler(runImmediately: runImmediately)
    }

    private func scheduleFolyncCheck(at date: Date, isCatchUp: Bool) {
        folyncRefreshTimer?.invalidate()
        guard FolyncSettingsStore.shared.load().isEnabled else {
            folyncNextCheckAt = nil
            return
        }
        folyncNextCheckAt = date
        let generation = folyncRefreshGeneration
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.folyncRefreshGeneration else { return }
                await self.refreshFolyncPortfolio(allowCatchUp: !isCatchUp)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        folyncRefreshTimer = timer
    }

    func refreshFolyncPortfolio() async {
        await refreshFolyncPortfolio(allowCatchUp: false)
    }

    private func refreshFolyncPortfolio(allowCatchUp: Bool) async {
        // Manual and scheduled refreshes share the same in-flight request.
        if let task = folyncRefreshTask {
            await task.value
            return
        }
        let settings = FolyncSettingsStore.shared.load()
        guard settings.isEnabled, let baseURL = URL(string: settings.baseURL) else { return }
        let generation = folyncRefreshGeneration
        let requestID = UUID()
        folyncRefreshRequestID = requestID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if folyncRefreshRequestID == requestID {
                    folyncRefreshTask = nil
                    folyncRefreshRequestID = nil
                }
            }
            let startedAt = Date()
            let token = await Self.loadFolyncTokenOffMainActor()
            guard !Task.isCancelled, generation == folyncRefreshGeneration else { return }
            await Logger.shared.info("Folync poll started at \(startedAt.ISO8601Format())")
            var succeeded = false
            if let token {
                succeeded = await refreshFolyncPortfolio(baseURL: baseURL, token: token, settings: settings)
            }
            guard !Task.isCancelled, generation == folyncRefreshGeneration else { return }
            let completedAt = Date()
            if succeeded { folyncLastCheckedAt = completedAt }
            let providerSyncAt = folyncPortfolioSnapshot?.freshness.sources.provider.lastSuccessfulSyncAt
                .flatMap(FolyncSupplementalDateParser.instant)
            let catchUp = succeeded && allowCatchUp && FolyncRefreshSchedule.needsCatchUp(
                providerSyncAt: providerSyncAt, checkStartedAt: startedAt, completedAt: completedAt
            )
            let next = catchUp ? completedAt.addingTimeInterval(FolyncRefreshSchedule.catchUpDelay)
                : FolyncRefreshSchedule.nextRegularCheck(after: completedAt)
            scheduleFolyncCheck(at: next, isCatchUp: catchUp)
            await Logger.shared.info("Folync poll completed: success=\(succeeded), providerSync=\(providerSyncAt?.ISO8601Format() ?? "unknown"), next=\(next.ISO8601Format()), catchUp=\(catchUp)")
        }
        folyncRefreshTask = task
        await task.value
    }

    private func refreshFolyncPortfolio(baseURL: URL, token: String, settings: FolyncStoredSettings) async -> Bool {
        folyncConnectionState = .connecting
        do {
            if folyncETag == nil,
               let cached = try await FolyncSnapshotCache.shared.load(endpoint: settings.baseURL, scopeID: settings.scopeID) {
                folyncETag = cached.etag
                applyFolyncSnapshot(cached.snapshot)
            }
            let source = try FolyncPortfolioSource(baseURL: baseURL, token: token)
            let result = try await source.fetchSnapshot(scopeID: settings.scopeID, etag: folyncETag)
            guard !Task.isCancelled, FolyncSettingsStore.shared.load().isEnabled,
                  FolyncSettingsStore.shared.load().baseURL == settings.baseURL,
                  FolyncSettingsStore.shared.load().scopeID == settings.scopeID else { return false }
            switch result {
            case .unchanged:
                if let snapshot = folyncPortfolioSnapshot {
                    folyncConnectionState = connectionState(for: snapshot)
                }
            case .changed(let snapshot, let etag):
                folyncETag = etag
                applyFolyncSnapshot(snapshot)
                try await FolyncSnapshotCache.shared.save(FolyncCachedSnapshot(
                    endpoint: settings.baseURL,
                    scopeID: settings.scopeID,
                    etag: etag,
                    snapshot: snapshot
                ))
            }
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            if folyncPortfolioSnapshot == nil,
               let cached = try? await FolyncSnapshotCache.shared.load(endpoint: settings.baseURL, scopeID: settings.scopeID) {
                folyncETag = cached.etag
                applyFolyncSnapshot(cached.snapshot)
            }
            markFolyncRefreshFailure(error)
            return false
        }
    }

    func applyFolyncSnapshot(_ snapshot: FolyncPortfolioSnapshot) {
        if legacyPortfolioTrades == nil {
            legacyPortfolioTrades = realTimeTrades
        }
        folyncPortfolioSnapshot = snapshot
        folyncConnectionState = connectionState(for: snapshot)
        let identityStore = InstrumentAliasStore()
        identityStore.merge(snapshot.preferredAliasMap)
        for holding in snapshot.holdings {
            identityStore.mergeISIN(holding.isin, displaySymbol: holding.resolvedDisplayTicker)
        }
        suspendTrading212LinkedSyncScheduler()
        realTimeTrades = makeFolyncPortfolioTrades(
            snapshot: snapshot,
            preserving: legacyPortfolioTrades ?? [],
            overlays: FolyncOverlayStore.shared.load()
        )
    }

    func updateFolyncSupplementalSettings(_ supplemental: FolyncSupplementalSettings) async {
        let previous = FolyncSettingsStore.shared.load().supplemental
        FolyncSettingsStore.shared.setSupplemental(supplemental)
        if previous.historicalLineCharts && !supplemental.historicalLineCharts {
            HistoricalDataManager.shared.clearFolyncSupplementalOverlays()
        } else if previous.historicalLineCharts != supplemental.historicalLineCharts ||
                    previous.candlestickCharts != supplemental.candlestickCharts {
            HistoricalDataManager.shared.noteFolyncSupplementalConfigurationChanged()
        }
        if previous.benchmarkMarketData && !supplemental.benchmarkMarketData {
            restoreFolyncBenchmarkOverlays()
            folyncSupplementalStatuses.removeValue(forKey: .benchmarkMarketData)
        }
        if previous.exchangeRates && !supplemental.exchangeRates {
            currencyConverter.deactivateFolyncOverlay()
            folyncSupplementalStatuses.removeValue(forKey: .exchangeRates)
        }
        await restartFolyncSupplementalScheduler(runImmediately: true)
    }

    func restartFolyncSupplementalScheduler(runImmediately: Bool) async {
        folyncSupplementalRefreshTimer?.invalidate()
        folyncSupplementalRefreshTimer = nil
        folyncSupplementalRefreshTask?.cancel()
        folyncSupplementalRefreshTask = nil
        let settings = FolyncSettingsStore.shared.load()
        guard settings.isEnabled else { return }

        // Capabilities readiness can change after bounded Folync backfills even
        // when only on-demand chart routes are enabled. Keep this conditional
        // ETag poll active for every configured Folync connection.
        if runImmediately {
            await refreshFolyncSupplementalMarketData()
        }
        let timer = Timer(fire: FolyncRefreshSchedule.nextRegularCheck(after: Date()),
                          interval: FolyncRefreshSchedule.interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.folyncSupplementalRefreshTask == nil else { return }
                self.folyncSupplementalRefreshTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.folyncSupplementalRefreshTask = nil }
                    await self.refreshFolyncSupplementalMarketData()
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        folyncSupplementalRefreshTimer = timer
    }

    func refreshFolyncSupplementalMarketData() async {
        let settings = FolyncSettingsStore.shared.load()
        guard settings.isEnabled else { return }

        folyncCapabilities = await FolyncSupplementalCoordinator.shared.capabilitiesForCurrentSettings(refresh: true)

        if settings.isSupplementalRouteActive(.benchmarkMarketData) {
            switch await FolyncSupplementalCoordinator.shared.routeBenchmarks() {
            case .folync(let benchmarks, let status):
                applyFolyncBenchmarkOverlays(benchmarks)
                folyncSupplementalStatuses[.benchmarkMarketData] = status
            case .legacy:
                restoreFolyncBenchmarkOverlays()
                folyncSupplementalStatuses[.benchmarkMarketData] = .legacy
            case .unavailable:
                markFolyncBenchmarksUnavailable()
                folyncSupplementalStatuses[.benchmarkMarketData] = .unavailable
            }
        }

        if settings.isSupplementalRouteActive(.exchangeRates) {
            await currencyConverter.refreshRatesFromConfiguredSource(force: true)
            folyncSupplementalStatuses[.exchangeRates] = currencyConverter.sourceStatus
        }
    }

    private func applyFolyncBenchmarkOverlays(_ benchmarks: [FolyncBenchmark]) {
        for benchmark in benchmarks {
            guard let last = benchmark.current.last, last.isFinite else { continue }
            guard let trade = realTimeTrades.first(where: {
                $0.trade.name.uppercased() == benchmark.symbol.uppercased()
            }) else { continue }
            let key = benchmark.symbol.uppercased()
            if folyncBenchmarkBaselines[key] == nil {
                folyncBenchmarkBaselines[key] = trade.realTimeInfo
            }
            var info = trade.realTimeInfo
            info.currentPrice = last
            info.previousClose = benchmark.current.previousClose
            info.prevClosePrice = benchmark.current.previousClose ?? .nan
            info.currency = benchmark.currency
            info.shortName = benchmark.name
            info.lastUpdateTime = benchmark.current.asOf
                .flatMap(FolyncSupplementalDateParser.instant)
                .map { Int($0.timeIntervalSince1970) }
            info.errorMessage = benchmark.quality == .unavailable
                ? "Folync benchmark unavailable: \(benchmark.reasonCodes.joined(separator: ", "))"
                : nil
            trade.realTimeInfo = info
        }
    }

    private func restoreFolyncBenchmarkOverlays() {
        restoreFolyncBenchmarkValues(
            &folyncBenchmarkBaselines,
            in: legacyPortfolioTrades ?? realTimeTrades
        )
    }

    private func markFolyncBenchmarksUnavailable() {
        for trade in realTimeTrades where SymbolMetadata.benchmarkSymbols.contains(trade.trade.name.uppercased()) {
            let key = trade.trade.name.uppercased()
            if folyncBenchmarkBaselines[key] == nil {
                folyncBenchmarkBaselines[key] = trade.realTimeInfo
            }
            var info = trade.realTimeInfo
            info.currentPrice = .nan
            info.previousClose = nil
            info.prevClosePrice = .nan
            info.errorMessage = "Folync benchmark data is unavailable."
            trade.realTimeInfo = info
        }
    }

    func markFolyncRefreshFailure(_ error: Error) {
        if folyncPortfolioSnapshot != nil {
            folyncConnectionState = .offlineCached(message: LogRedactor.redact(error.localizedDescription))
        } else if error is FolyncPortfolioSourceError {
            switch error as? FolyncPortfolioSourceError {
            case .unauthorized: folyncConnectionState = .unauthorized
            case .unsupportedSchema: folyncConnectionState = .incompatible
            default: folyncConnectionState = .notConfigured
            }
        }
    }

    func deactivateFolyncPortfolio(persistSetting: Bool = true) {
        folyncRefreshGeneration = UUID()
        folyncRefreshRequestID = nil
        folyncLastCheckedAt = nil
        folyncNextCheckAt = nil
        restoreFolyncBenchmarkOverlays()
        currencyConverter.deactivateFolyncOverlay()
        folyncRefreshTimer?.invalidate()
        folyncRefreshTimer = nil
        folyncRefreshTask?.cancel()
        folyncRefreshTask = nil
        folyncSupplementalRefreshTimer?.invalidate()
        folyncSupplementalRefreshTimer = nil
        folyncSupplementalRefreshTask?.cancel()
        folyncSupplementalRefreshTask = nil
        folyncETag = nil
        folyncPortfolioSnapshot = nil
        folyncCapabilities = nil
        folyncSupplementalStatuses = [:]
        folyncConnectionState = .notConfigured
        if let legacyPortfolioTrades {
            realTimeTrades = legacyPortfolioTrades
        }
        legacyPortfolioTrades = nil
        if persistSetting {
            FolyncSettingsStore.shared.setEnabled(false)
        }
        HistoricalDataManager.shared.clearFolyncSupplementalOverlays()
        Task { await FolyncSupplementalCoordinator.shared.clearInMemoryState() }
        if persistSetting {
            restartTrading212LinkedSyncScheduler()
        }
    }

    func setFolyncHoldingVisibleInMenuBar(_ visible: Bool, holding: FolyncHolding) {
        guard let snapshot = folyncPortfolioSnapshot else { return }
        FolyncOverlayStore.shared.set(
            FolyncHoldingOverlay(showInMenuBar: visible),
            for: holding.overlayKey(scopeID: snapshot.scope.id)
        )
        realTimeTrades = makeFolyncPortfolioTrades(
            snapshot: snapshot,
            preserving: legacyPortfolioTrades ?? [],
            overlays: FolyncOverlayStore.shared.load()
        )
    }

    private func connectionState(for snapshot: FolyncPortfolioSnapshot) -> FolyncConnectionState {
        switch snapshot.freshness.status {
        case "current": return .current(asOf: snapshot.freshness.asOf)
        case "dirty", "rebuilding": return .rebuilding(asOf: snapshot.freshness.asOf, reasons: snapshot.freshness.reasonCodes)
        default: return .stale(asOf: snapshot.freshness.asOf, reasons: snapshot.freshness.reasonCodes)
        }
    }
}

func restoreFolyncBenchmarkValues(
    _ baselines: inout [String: TradingInfo],
    in trades: [RealTimeTrade]
) {
    guard !baselines.isEmpty else { return }
    for trade in trades {
        let key = trade.trade.name.uppercased()
        if let baseline = baselines[key] {
            trade.realTimeInfo = baseline
        }
    }
    baselines.removeAll()
}

func makeFolyncPortfolioTrades(
    snapshot: FolyncPortfolioSnapshot,
    preserving legacyTrades: [RealTimeTrade],
    overlays: [String: FolyncHoldingOverlay]
) -> [RealTimeTrade] {
    snapshot.makeDisplayTrades(overlays: overlays) + legacyTrades.filter(\.trade.isWatchlistOnly)
}
