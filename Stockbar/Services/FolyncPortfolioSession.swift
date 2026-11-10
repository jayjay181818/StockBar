import Foundation

enum FolyncConnectionState: Equatable {
    case notConfigured
    case waitingForKeychain
    case connecting
    case current(asOf: String?)
    case stale(asOf: String?, reasons: [String])
    case rebuilding(asOf: String?, reasons: [String])
    case offlineCached(message: String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(message: String)
    case incompatible

    var message: String {
        switch self {
        case .notConfigured: return "Folync is not configured."
        case .waitingForKeychain:
            return "Waiting for Keychain access. If macOS asks to let Stockbar use its saved credentials, choose Always Allow."
        case .connecting: return "Connecting to Folync…"
        case .current(let asOf): return asOf.map { "Current as of \($0)." } ?? "Current."
        case .stale(let asOf, let reasons):
            return "Stale\(asOf.map { " as of \($0)" } ?? ""): \(reasons.joined(separator: ", "))"
        case .rebuilding(_, let reasons): return "Folync is rebuilding: \(reasons.joined(separator: ", "))"
        case .offlineCached(let message): return "Offline — showing last Folync data. \(message)"
        case .unauthorized: return "Folync access token was rejected."
        case .rateLimited(let retryAfter):
            return FolyncPortfolioSourceError.rateLimited(retryAfter: retryAfter).errorDescription
                ?? "Folync is rate limiting requests."
        case .unavailable(let message):
            return message.isEmpty ? "Folync is unavailable." : message
        case .incompatible: return "Folync API version is incompatible."
        }
    }
}

struct FolyncSessionDependencies {
    var settingsStore: FolyncSettingsStore
    var snapshotCache: FolyncSnapshotCache
    var overlayStore: FolyncOverlayStore
    var supplementalCoordinator: FolyncSupplementalCoordinator
    var urlSession: URLSession
    var providerPolicy: StockbarProviderAccessPolicy
    var loadToken: @Sendable () async -> String?
    var saveToken: @Sendable (String) throws -> Void
    var hasToken: @Sendable () async -> Bool
    /// How long the first token read may take before the status says Stockbar
    /// is waiting for Keychain access.
    var keychainWaitNoticeDelay: TimeInterval = 2

    static let live = FolyncSessionDependencies(
        settingsStore: .shared,
        snapshotCache: .shared,
        overlayStore: .shared,
        supplementalCoordinator: .shared,
        urlSession: .shared,
        providerPolicy: .current,
        loadToken: {
            await Task.detached(priority: .userInitiated) {
                try? FolyncCredentialStore.shared.load()
            }.value
        },
        saveToken: { token in
            try FolyncCredentialStore.shared.save(token: token)
        },
        hasToken: {
            await Task.detached(priority: .userInitiated) {
                FolyncCredentialStore.shared.hasToken()
            }.value
        }
    )
}

@MainActor private var folyncSessionDependenciesByModel: [ObjectIdentifier: FolyncSessionDependencies] = [:]
@MainActor private var folyncSupplementalGenerationsByModel: [ObjectIdentifier: UUID] = [:]

extension DataModel {
    var folyncSessionDependencies: FolyncSessionDependencies {
        get { folyncSessionDependenciesByModel[ObjectIdentifier(self)] ?? .live }
        set { folyncSessionDependenciesByModel[ObjectIdentifier(self)] = newValue }
    }

    var folyncSupplementalGeneration: UUID {
        get { folyncSupplementalGenerationsByModel[ObjectIdentifier(self)] ?? folyncRefreshGeneration }
        set { folyncSupplementalGenerationsByModel[ObjectIdentifier(self)] = newValue }
    }

    var isFolyncEnabled: Bool {
        isFolyncPortfolioActive || folyncSessionDependencies.settingsStore.load().isEnabled
    }

    func hasStoredFolyncToken() async -> Bool {
        await folyncSessionDependencies.hasToken()
    }

    private func resolveFolyncToken(_ candidate: String) async throws -> (token: String, isNewToken: Bool) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return (trimmed, true)
        }
        if let stored = await folyncSessionDependencies.loadToken()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return (stored, false)
        }
        throw FolyncPortfolioSourceError.missingToken
    }

    func testFolyncConnection(baseURL: URL, token: String) async throws -> [FolyncPortfolio] {
        let previousState = folyncConnectionState
        let previousCapabilities = folyncCapabilities
        defer {
            folyncConnectionState = previousState
            folyncCapabilities = previousCapabilities
        }
        let resolved = try await resolveFolyncToken(token)
        let deps = folyncSessionDependencies
        let source = try FolyncPortfolioSource(
            baseURL: baseURL,
            token: resolved.token,
            session: deps.urlSession,
            providerPolicy: deps.providerPolicy
        )
        return try await source.listPortfolios()
    }

    func previewFolyncPortfolio(baseURL: URL, token: String, scopeID: String) async throws -> FolyncPortfolioSnapshot {
        let previousState = folyncConnectionState
        let previousCapabilities = folyncCapabilities
        defer {
            folyncConnectionState = previousState
            folyncCapabilities = previousCapabilities
        }
        let resolved = try await resolveFolyncToken(token)
        let deps = folyncSessionDependencies
        let source = try FolyncPortfolioSource(
            baseURL: baseURL,
            token: resolved.token,
            session: deps.urlSession,
            providerPolicy: deps.providerPolicy
        )
        let result = try await source.fetchSnapshot(scopeID: scopeID, etag: nil)
        guard case .changed(let snapshot, _) = result else { throw FolyncPortfolioSourceError.invalidResponse }
        return snapshot
    }

    func activateFolyncPortfolio(baseURL: URL, token: String, scopeID: String) async throws {
        let previousState = folyncConnectionState
        var didCommit = false
        folyncConnectionState = .connecting
        defer {
            if !didCommit {
                folyncConnectionState = previousState
            }
        }
        let resolved = try await resolveFolyncToken(token)
        let deps = folyncSessionDependencies
        let source = try FolyncPortfolioSource(
            baseURL: baseURL,
            token: resolved.token,
            session: deps.urlSession,
            providerPolicy: deps.providerPolicy
        )
        let portfolios = try await source.listPortfolios()
        guard portfolios.contains(where: { $0.id == scopeID }) else {
            throw FolyncPortfolioSourceError.invalidScope("Selected portfolio scope is unavailable")
        }
        let result = try await source.fetchSnapshot(scopeID: scopeID, etag: nil)
        guard case .changed(let snapshot, let etag) = result else {
            throw FolyncPortfolioSourceError.invalidResponse
        }
        let capabilities = try? await source.fetchCapabilities()
        if resolved.isNewToken {
            try deps.saveToken(resolved.token)
        }
        // A successful hot reconfiguration establishes a new cache/overlay
        // identity. Remove only in-memory overlays from the previous endpoint
        // or scope; local history and the separate Folync disk caches remain.
        restoreFolyncBenchmarkOverlays()
        currencyConverter.deactivateFolyncOverlay()
        HistoricalDataManager.shared.clearFolyncSupplementalOverlays()
        folyncSupplementalStatuses = [:]
        await deps.supplementalCoordinator.clearInMemoryState()
        deps.settingsStore.save(FolyncStoredSettings(
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
        didCommit = true
        do {
            try await deps.snapshotCache.save(FolyncCachedSnapshot(
                endpoint: baseURL.absoluteString,
                scopeID: scopeID,
                etag: etag,
                snapshot: snapshot
            ))
        } catch {
            await Logger.shared.warning("Failed to save Folync snapshot cache during activation: \(LogRedactor.redact(error.localizedDescription))")
        }
        await restartFolyncPortfolioScheduler(runImmediately: false)
    }

    private func isFolyncSessionCurrent(generation: UUID, settings: FolyncStoredSettings? = nil) -> Bool {
        guard !Task.isCancelled, !isBackgroundWorkPausedForImport,
              generation == folyncRefreshGeneration else { return false }
        let current = folyncSessionDependencies.settingsStore.load()
        guard current.isEnabled else { return false }
        if let settings {
            return current.baseURL == settings.baseURL && current.scopeID == settings.scopeID
        }
        return true
    }

    func restartFolyncPortfolioScheduler(runImmediately: Bool) async {
        folyncRefreshGeneration = UUID()
        folyncSupplementalGeneration = UUID()
        let generation = folyncRefreshGeneration
        folyncRefreshTimer?.invalidate()
        folyncRefreshTimer = nil
        folyncNextCheckAt = nil
        folyncRefreshTask?.cancel()
        folyncRefreshTask = nil
        folyncRefreshRequestID = nil
        // A restart follows a new URL, token or scope, so earlier backoff no longer applies.
        folyncBackoffUntil = nil
        let deps = folyncSessionDependencies
        // Before touching the supplemental coordinator: its Keychain read is
        // synchronous, so while macOS shows the access prompt the actor (and
        // clearBackoff below) waits too.
        if isFolyncSessionCurrent(generation: generation, settings: deps.settingsStore.load()) {
            await waitForStoredFolyncCredentials(generation: generation)
        }
        await deps.supplementalCoordinator.clearBackoff()
        let settings = deps.settingsStore.load()
        guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return }

        let capabilities = await deps.supplementalCoordinator.capabilitiesForCurrentSettings(refresh: true)
        guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return }
        folyncCapabilities = capabilities
        if runImmediately {
            await refreshFolyncPortfolio(allowCatchUp: false)
        } else {
            scheduleFolyncCheck(at: FolyncRefreshSchedule.nextRegularCheck(after: Date()), isCatchUp: false)
        }
        guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return }
        await restartFolyncSupplementalScheduler(runImmediately: runImmediately)
    }

    /// Reads the stored token before the session starts. macOS blocks that read
    /// while it shows its Keychain access prompt (for example after a rebuild
    /// changes the app's signature), and every Folync request waits behind it.
    /// A slow read is reported as waiting for Keychain access rather than
    /// leaving the status at "not configured".
    func waitForStoredFolyncCredentials(generation: UUID) async {
        let deps = folyncSessionDependencies
        let delayNanoseconds = UInt64(max(0, deps.keychainWaitNoticeDelay) * 1_000_000_000)
        let notice = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self,
                  generation == self.folyncRefreshGeneration,
                  self.folyncConnectionState == .notConfigured else { return }
            self.folyncConnectionState = .waitingForKeychain
        }
        _ = await deps.loadToken()
        notice.cancel()
        if generation == folyncRefreshGeneration, folyncConnectionState == .waitingForKeychain {
            folyncConnectionState = .connecting
        }
    }

    private func scheduleFolyncCheck(at date: Date, isCatchUp: Bool) {
        folyncRefreshTimer?.invalidate()
        guard folyncSessionDependencies.settingsStore.load().isEnabled else {
            folyncNextCheckAt = nil
            return
        }
        folyncNextCheckAt = date
        let generation = folyncRefreshGeneration
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isFolyncSessionCurrent(generation: generation) else { return }
                if let backoff = await self.folyncSessionDependencies.supplementalCoordinator.backoffUntil(),
                   backoff > Date() {
                    guard self.isFolyncSessionCurrent(generation: generation) else { return }
                    self.folyncBackoffUntil = backoff
                    self.scheduleFolyncCheck(at: backoff, isCatchUp: false)
                    return
                }
                // No network at all: a poll can only fail, so wait for the
                // next minute instead. A Folync on this Mac is still asked.
                if !ConnectivityMonitor.shared.isConnected,
                   let url = URL(string: self.folyncSessionDependencies.settingsStore.load().baseURL),
                   !FolyncRefreshSchedule.isLoopback(url) {
                    self.scheduleFolyncCheck(
                        at: FolyncRefreshSchedule.nextRegularCheck(after: Date()), isCatchUp: false
                    )
                    return
                }
                await self.refreshFolyncPortfolio(allowCatchUp: !isCatchUp)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        folyncRefreshTimer = timer
    }

    func refreshFolyncPortfolio() async {
        folyncBackoffUntil = nil
        await folyncSessionDependencies.supplementalCoordinator.clearBackoff()
        await refreshFolyncPortfolio(allowCatchUp: false)
    }

    var isFolyncBackingOff: Bool {
        guard let folyncBackoffUntil else { return false }
        return folyncBackoffUntil > Date()
    }

    private func refreshFolyncPortfolio(allowCatchUp: Bool) async {
        // Manual and scheduled refreshes share the same in-flight request.
        if let task = folyncRefreshTask {
            await task.value
            return
        }
        let deps = folyncSessionDependencies
        let settings = deps.settingsStore.load()
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
            let token = await deps.loadToken()
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return }
            var succeeded = false
            if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                succeeded = await refreshFolyncPortfolio(
                    baseURL: baseURL,
                    token: token,
                    settings: settings,
                    generation: generation
                )
            } else {
                markFolyncRefreshFailure(FolyncPortfolioSourceError.missingToken)
                noteFolyncPollFailure(FolyncPortfolioSourceError.missingToken)
            }
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return }
            let completedAt = Date()
            if succeeded { folyncLastCheckedAt = completedAt }
            let providerSyncAt = folyncPortfolioSnapshot?.freshness.sources.provider.lastSuccessfulSyncAt
                .flatMap(FolyncSupplementalDateParser.instant)
            let catchUp = succeeded && allowCatchUp && FolyncRefreshSchedule.needsCatchUp(
                providerSyncAt: providerSyncAt, checkStartedAt: startedAt, completedAt: completedAt
            )
            let regular = FolyncRefreshSchedule.nextRegularCheck(after: completedAt)
            let next = catchUp ? completedAt.addingTimeInterval(FolyncRefreshSchedule.catchUpDelay)
                : max(regular, folyncBackoffUntil ?? regular)
            scheduleFolyncCheck(at: next, isCatchUp: catchUp)
            await logFolyncPollOutcome(succeeded: succeeded, next: next)
            await Logger.shared.debug("Folync poll: success=\(succeeded), providerSync=\(providerSyncAt?.ISO8601Format() ?? "unknown"), next=\(next.ISO8601Format()), catchUp=\(catchUp), backoff=\(isFolyncBackingOff)")
        }
        folyncRefreshTask = task
        await task.value
    }

    private func noteFolyncPollFailure(_ error: Error) {
        folyncConsecutivePollFailures += 1
        folyncLastPollFailureCategory = FolyncRefreshSchedule.failureCategory(error)
    }

    /// One line when polling starts to fail and one when it works again. A
    /// pair of lines for every poll was more than half of the log.
    private func logFolyncPollOutcome(succeeded: Bool, next: Date) async {
        if succeeded {
            let failures = folyncConsecutivePollFailures
            folyncConsecutivePollFailures = 0
            folyncLastPollFailureCategory = nil
            if failures > 0 {
                await Logger.shared.info("Folync poll recovered after \(failures) failed poll\(failures == 1 ? "" : "s")")
            }
            return
        }
        let category = folyncLastPollFailureCategory ?? "other"
        if folyncConsecutivePollFailures == 1 {
            await Logger.shared.warning("Folync poll failed (\(category)); next try \(next.ISO8601Format())")
        } else {
            await Logger.shared.debug("Folync poll failed again (\(category)), \(folyncConsecutivePollFailures) in a row; next try \(next.ISO8601Format())")
        }
    }

    private func refreshFolyncPortfolio(
        baseURL: URL,
        token: String,
        settings: FolyncStoredSettings,
        generation: UUID
    ) async -> Bool {
        let deps = folyncSessionDependencies
        folyncConnectionState = .connecting
        if folyncETag == nil {
            if let cached = try? await deps.snapshotCache.load(endpoint: settings.baseURL, scopeID: settings.scopeID) {
                guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
                folyncETag = cached.etag
                applyFolyncSnapshot(cached.snapshot)
            } else {
                guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            }
        }
        do {
            let source = try FolyncPortfolioSource(
                baseURL: baseURL,
                token: token,
                session: deps.urlSession,
                providerPolicy: deps.providerPolicy
            )
            let result = try await source.fetchSnapshot(scopeID: settings.scopeID, etag: folyncETag)
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            switch result {
            case .unchanged:
                if let snapshot = folyncPortfolioSnapshot {
                    folyncConnectionState = connectionState(for: snapshot)
                }
            case .changed(let snapshot, let etag):
                folyncETag = etag
                applyFolyncSnapshot(snapshot)
                do {
                    try await deps.snapshotCache.save(FolyncCachedSnapshot(
                        endpoint: settings.baseURL,
                        scopeID: settings.scopeID,
                        etag: etag,
                        snapshot: snapshot
                    ))
                } catch {
                    await Logger.shared.warning("Failed to save Folync snapshot cache: \(LogRedactor.redact(error.localizedDescription))")
                }
                guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            }
            folyncBackoffUntil = nil
            await deps.supplementalCoordinator.clearBackoff()
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            return true
        } catch {
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            if folyncPortfolioSnapshot == nil,
               let cached = try? await deps.snapshotCache.load(endpoint: settings.baseURL, scopeID: settings.scopeID) {
                guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
                folyncETag = cached.etag
                applyFolyncSnapshot(cached.snapshot)
            } else {
                guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            }
            markFolyncRefreshFailure(error)
            noteFolyncPollFailure(error)
            let now = Date()
            let backoff = await deps.supplementalCoordinator.recordBackoff(after: error, at: now)
                ?? FolyncRefreshSchedule.backoff(after: error, at: now)
                ?? FolyncRefreshSchedule.repeatedFailureBackoff(
                    consecutiveFailures: folyncConsecutivePollFailures, at: now
                )
            guard isFolyncSessionCurrent(generation: generation, settings: settings) else { return false }
            folyncBackoffUntil = backoff
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
            overlays: folyncSessionDependencies.overlayStore.load()
        )
        evaluatePriceAlerts(for: realTimeTrades.filter { $0.sourceIdentity != nil })
    }

    func updateFolyncSupplementalSettings(_ supplemental: FolyncSupplementalSettings) async {
        let settingsStore = folyncSessionDependencies.settingsStore
        let previous = settingsStore.load().supplemental
        guard previous != supplemental else { return }
        settingsStore.setSupplemental(supplemental)
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
        let refreshGeneration = folyncRefreshGeneration
        let supplementalGeneration = UUID()
        folyncSupplementalGeneration = supplementalGeneration
        folyncSupplementalRefreshTimer?.invalidate()
        folyncSupplementalRefreshTimer = nil
        folyncSupplementalRefreshTask?.cancel()
        folyncSupplementalRefreshTask = nil
        let deps = folyncSessionDependencies
        let settings = deps.settingsStore.load()
        guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
              supplementalGeneration == folyncSupplementalGeneration else { return }

        // Capabilities readiness can change after bounded Folync backfills even
        // when only on-demand chart routes are enabled. Keep this conditional
        // ETag poll active for every configured Folync connection.
        let coordinatorBackingOff = await deps.supplementalCoordinator.isBackingOff()
        guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
              supplementalGeneration == folyncSupplementalGeneration else { return }
        if runImmediately, !isFolyncBackingOff, !coordinatorBackingOff {
            await refreshFolyncSupplementalMarketData()
            guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
                  supplementalGeneration == folyncSupplementalGeneration else { return }
        }
        folyncSupplementalRefreshTimer?.invalidate()
        let timer = Timer(fire: FolyncRefreshSchedule.nextRegularCheck(after: Date()),
                          interval: FolyncRefreshSchedule.interval, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                // Supplemental routes use the same token, so they wait out the same backoff.
                guard let self,
                      self.isFolyncSessionCurrent(generation: refreshGeneration),
                      supplementalGeneration == self.folyncSupplementalGeneration,
                      self.folyncSupplementalRefreshTask == nil,
                      !self.isFolyncBackingOff else { return }
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
        let refreshGeneration = folyncRefreshGeneration
        let supplementalGeneration = folyncSupplementalGeneration
        let deps = folyncSessionDependencies
        let settings = deps.settingsStore.load()
        guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
              supplementalGeneration == folyncSupplementalGeneration else { return }

        if let backoff = await deps.supplementalCoordinator.backoffUntil(), backoff > Date() {
            guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
                  supplementalGeneration == folyncSupplementalGeneration else { return }
            folyncBackoffUntil = backoff
            return
        }
        guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
              supplementalGeneration == folyncSupplementalGeneration,
              !isFolyncBackingOff else { return }

        let capabilities = await deps.supplementalCoordinator.capabilitiesForCurrentSettings(refresh: true)
        guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
              supplementalGeneration == folyncSupplementalGeneration else { return }
        folyncCapabilities = capabilities

        if deps.settingsStore.load().isSupplementalRouteActive(.benchmarkMarketData) {
            let benchmarkResult = await deps.supplementalCoordinator.routeBenchmarks()
            guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
                  supplementalGeneration == folyncSupplementalGeneration,
                  deps.settingsStore.load().isSupplementalRouteActive(.benchmarkMarketData) else { return }
            switch benchmarkResult {
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

        if deps.settingsStore.load().isSupplementalRouteActive(.exchangeRates) {
            await currencyConverter.refreshRatesFromConfiguredSource(force: true)
            guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
                  supplementalGeneration == folyncSupplementalGeneration,
                  deps.settingsStore.load().isSupplementalRouteActive(.exchangeRates) else { return }
            folyncSupplementalStatuses[.exchangeRates] = currencyConverter.sourceStatus
        }

        if let backoff = await deps.supplementalCoordinator.backoffUntil(), backoff > Date() {
            guard isFolyncSessionCurrent(generation: refreshGeneration, settings: settings),
                  supplementalGeneration == folyncSupplementalGeneration else { return }
            folyncBackoffUntil = backoff
        }
    }

    func applyFolyncBenchmarkOverlays(_ benchmarks: [FolyncBenchmark]) {
        for benchmark in benchmarks {
            guard let trade = realTimeTrades.first(where: {
                $0.trade.name.uppercased() == benchmark.symbol.uppercased()
            }) else { continue }
            let key = benchmark.symbol.uppercased()
            if folyncBenchmarkBaselines[key] == nil {
                folyncBenchmarkBaselines[key] = trade.realTimeInfo
            }
            var info = trade.realTimeInfo
            info.currency = benchmark.currency
            info.shortName = benchmark.name
            info.lastUpdateTime = benchmark.current.asOf
                .flatMap(FolyncSupplementalDateParser.instant)
                .map { Int($0.timeIntervalSince1970) }
            if benchmark.quality != .unavailable,
               let last = benchmark.current.last,
               last.isFinite {
                info.currentPrice = last
                info.previousClose = benchmark.current.previousClose
                info.prevClosePrice = benchmark.current.previousClose ?? .nan
                info.errorMessage = nil
            } else {
                info.currentPrice = .nan
                info.previousClose = nil
                info.prevClosePrice = .nan
                let reasons = benchmark.reasonCodes.joined(separator: ", ")
                info.errorMessage = reasons.isEmpty
                    ? "Folync benchmark data is unavailable."
                    : "Folync benchmark unavailable: \(reasons)"
            }
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
            return
        }
        if let sourceError = error as? FolyncPortfolioSourceError {
            switch sourceError {
            case .unauthorized:
                folyncConnectionState = .unauthorized
            case .rateLimited(let retryAfter):
                folyncConnectionState = .rateLimited(retryAfter: retryAfter)
            case .unsupportedSchema:
                folyncConnectionState = .incompatible
            case .unavailable, .invalidPayload, .invalidResponse, .insecureTransport, .invalidEndpoint, .missingToken, .invalidScope:
                folyncConnectionState = .unavailable(message: LogRedactor.redact(sourceError.localizedDescription))
            }
        } else {
            folyncConnectionState = .unavailable(message: LogRedactor.redact(error.localizedDescription))
        }
    }

    func deactivateFolyncPortfolio(persistSetting: Bool = true) {
        let deps = folyncSessionDependencies
        folyncRefreshGeneration = UUID()
        folyncSupplementalGeneration = UUID()
        folyncRefreshRequestID = nil
        folyncLastCheckedAt = nil
        folyncNextCheckAt = nil
        folyncBackoffUntil = nil
        folyncConsecutivePollFailures = 0
        folyncLastPollFailureCategory = nil
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
            deps.settingsStore.setEnabled(false)
        }
        HistoricalDataManager.shared.clearFolyncSupplementalOverlays()
        Task { await deps.supplementalCoordinator.clearInMemoryState() }
        if persistSetting {
            restartTrading212LinkedSyncScheduler()
        }
    }

    func setFolyncHoldingVisibleInMenuBar(_ visible: Bool, holding: FolyncHolding) {
        guard let snapshot = folyncPortfolioSnapshot else { return }
        let overlayStore = folyncSessionDependencies.overlayStore
        overlayStore.set(
            FolyncHoldingOverlay(showInMenuBar: visible),
            for: holding.overlayKey(scopeID: snapshot.scope.id)
        )
        realTimeTrades = makeFolyncPortfolioTrades(
            snapshot: snapshot,
            preserving: legacyPortfolioTrades ?? [],
            overlays: overlayStore.load()
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
