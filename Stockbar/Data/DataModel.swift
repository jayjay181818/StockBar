// Stockbar/Stockbar/Data/DataModel.swift
// --- COMPLETELY REPLACED FILE ---

import Combine
import Foundation
import Observation
import Security

extension String {
}
// Removed OSLog import to avoid name clashes with our custom Logger

@MainActor
@Observable
class DataModel {
    nonisolated static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"] // Keep as is

    // MARK: - Properties

    private let networkService: NetworkService = PythonNetworkService.shared

    internal let currencyConverter: CurrencyConverter // Internal for UI access to exchange rate info
    private let decoder = JSONDecoder()           // Keep as is
    private let encoder = JSONEncoder()           // Keep as is
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()// Keep as is
    private let tradeContentDidChange = PassthroughSubject<Void, Never>()
    internal var historicalDataManager: HistoricalDataManager { HistoricalDataManager.shared }
    private let tradeDataService = TradeDataService()
    private let migrationService = DataMigrationService.shared
    private let aliasIdentityMigrationService = AliasIdentityMigrationService()
    @ObservationIgnored private var pendingPersistenceTask: Task<Void, Never>?
    private let trading212SettingsStore = Trading212SettingsStore.shared
    private let trading212CredentialStore = Trading212CredentialStore.shared
    private let trading212PreviewCoordinator = Trading212PreviewCoordinator()
    private let trading212BrokerLinkStore = BrokerLinkStore.shared
    private let trading212BrokerSyncPlanner = Trading212BrokerSyncPlanner()
    private let trading212BrokerOnlyImportPlanner = Trading212BrokerOnlyImportPlanner()
    @ObservationIgnored private var trading212BrokerSyncTask: Task<Void, Never>?
    @ObservationIgnored private var trading212BrokerSyncTimer: Timer?
    @ObservationIgnored private var trading212ScheduledFailureCount = 0
    @ObservationIgnored private var trading212NextScheduledAttempt = Date.distantPast
    /// Why the last scheduled Trading 212 sync failed, for the Connections tab; nil once one succeeds.
    private(set) var trading212ScheduledSyncError: String?
    /// Identifies the current scheduled cycle, so a cancelled older cycle
    /// cannot clear the handle of a newer one.
    @ObservationIgnored private var trading212BrokerSyncGeneration = 0
    @ObservationIgnored private var lastTrading212ScheduledReconciliation = Date.distantPast
    @ObservationIgnored private var isTrading212BrokerSyncInProgress = false
    @ObservationIgnored private var isTrading212HoldingReconciliationInProgress = false
    private(set) var trading212BrokerValuationSnapshot: Trading212BrokerValuationSnapshot?
    var folyncPortfolioSnapshot: FolyncPortfolioSnapshot?
    var folyncConnectionState: FolyncConnectionState = .notConfigured
    var folyncCapabilities: FolyncCapabilities?
    var folyncSupplementalStatuses: [FolyncSupplementalRoute: FolyncSupplementalSourceStatus] = [:]
    private(set) var isInitialPortfolioSourceResolved = false
    /// True after the startup load failed; portfolio writes are refused until a
    /// restore or import succeeds.
    private(set) var portfolioLoadFailed = false
    /// Why the startup load failed, when the cause can be put in words.
    private(set) var portfolioLoadFailureDetail: String?
    /// Last time a Trading 212 sync actually updated linked holdings. Market
    /// refresh only defers to the broker while this is recent.
    @ObservationIgnored private var lastTrading212LinkedSyncAt: Date?
    /// A trade change is waiting out the save debounce.
    @ObservationIgnored private var hasPendingDebouncedTradeSave = false
    @ObservationIgnored var legacyPortfolioTrades: [RealTimeTrade]?
    @ObservationIgnored var folyncBenchmarkBaselines: [String: TradingInfo] = [:]
    @ObservationIgnored var folyncRefreshTimer: Timer?
    @ObservationIgnored var folyncRefreshTask: Task<Void, Never>?
    @ObservationIgnored var folyncRefreshGeneration = UUID()
    @ObservationIgnored var folyncRefreshRequestID: UUID?
    var folyncLastCheckedAt: Date?
    var folyncNextCheckAt: Date?
    @ObservationIgnored var folyncSupplementalRefreshTimer: Timer?
    @ObservationIgnored var folyncSupplementalRefreshTask: Task<Void, Never>?
    @ObservationIgnored var folyncETag: String?
    /// Set after a rejected token or rate limit; automatic polls wait until then.
    @ObservationIgnored var folyncBackoffUntil: Date?
    /// Failed polls in a row; drives the slower retry and the one-line log on
    /// the first failure and on recovery.
    @ObservationIgnored var folyncConsecutivePollFailures = 0
    @ObservationIgnored private var didLogStaleTrading212Valuation = false
    @ObservationIgnored var folyncLastPollFailureCategory: String?

    var isFolyncPortfolioActive: Bool { folyncPortfolioSnapshot != nil }

    var folyncRefreshableSymbols: Set<String> {
        var symbols = Set((legacyPortfolioTrades ?? realTimeTrades)
            .filter(\.trade.isWatchlistOnly)
            .map { $0.trade.name.uppercased() })
        if FolyncSettingsStore.shared.load().isSupplementalRouteActive(.benchmarkMarketData) {
            if folyncSupplementalStatuses[.benchmarkMarketData] != .legacy {
                symbols.subtract(SymbolMetadata.benchmarkSymbols)
            }
        }
        return symbols
    }

    // MARK: - Service Layer
    internal let cacheCoordinator = CacheCoordinator()  // Internal for UI access to suspension state
    /// Outcome of the last quote refresh that reached the provider.
    var quoteRefreshStatus = QuoteRefreshStatus()
    @ObservationIgnored private var refreshService: RefreshService!
    @ObservationIgnored private var portfolioCalculationService: PortfolioCalculationService!
    @ObservationIgnored private var historicalDataCoordinator: HistoricalDataCoordinator!
    
    var realTimeTrades: [RealTimeTrade] = [] {
        didSet { realTimeTradesRevision &+= 1 }
    }
    /// Bumped on every assignment to `realTimeTrades`, including reassigning the
    /// same rows after editing them in place (broker sync), so views can react
    /// to whole-portfolio updates without diffing rows.
    private(set) var realTimeTradesRevision = 0
    var showColorCoding: Bool = (StockbarRuntimeStorage.userDefaults.object(forKey: "showColorCoding") as? Bool) ?? true {
        didSet {
            StockbarRuntimeStorage.userDefaults.set(showColorCoding, forKey: "showColorCoding")
        }
    }
    var preferredCurrency: String = StockbarRuntimeStorage.userDefaults.string(forKey: "preferredCurrency") ?? "USD" { // Keep as is
        didSet {
            StockbarRuntimeStorage.userDefaults.set(preferredCurrency, forKey: "preferredCurrency")
        }
    }
    var showMarketIndicators: Bool = StockbarRuntimeStorage.userDefaults.bool(forKey: "showMarketIndicators") {
        didSet {
            StockbarRuntimeStorage.userDefaults.set(showMarketIndicators, forKey: "showMarketIndicators")
        }
    }

    // MARK: - Menu Bar Display Settings (UI Enhancement v2.3.0)
    var menuBarDisplaySettings: MenuBarDisplaySettings = MenuBarDisplaySettings.load() {
        didSet {
            menuBarDisplaySettings.save()
        }
    }

    var portfolioMenuBarDisplaySettings: PortfolioMenuBarDisplaySettings = {
        let defaultCurrency = StockbarRuntimeStorage.userDefaults.string(forKey: "preferredCurrency") ?? "USD"
        return PortfolioMenuBarDisplaySettings.load(defaultCurrency: defaultCurrency)
    }() {
        didSet {
            portfolioMenuBarDisplaySettings.save()
        }
    }

    var hideAllMenuBarItems: Bool = StockbarRuntimeStorage.userDefaults.bool(forKey: "hideAllMenuBarItems") {
        didSet {
            StockbarRuntimeStorage.userDefaults.set(hideAllMenuBarItems, forKey: "hideAllMenuBarItems")
        }
    }

    var requireExternalDisplayForMenuBarStocks: Bool = MenuBarVisibilityPolicy.loadRequireExternalDisplay() {
        didSet {
            MenuBarVisibilityPolicy.saveRequireExternalDisplay(requireExternalDisplayForMenuBarStocks)
        }
    }

    var isExternalDisplayConnected: Bool = false

    var shouldShowStockMenuBarItems: Bool {
        MenuBarVisibilityPolicy.shouldShowStockItems(
            hideAllMenuBarItems: hideAllMenuBarItems,
            requireExternalDisplay: requireExternalDisplayForMenuBarStocks,
            isExternalDisplayConnected: isExternalDisplayConnected
        )
    }

    private let logger = Logger.shared

    /// Seconds between automatic quote refreshes, always within the supported range.
    var refreshInterval: TimeInterval = RefreshService.clampedRefreshInterval(
        StockbarRuntimeStorage.userDefaults.object(forKey: "refreshInterval") as? TimeInterval
    ) {
        didSet {
            let clamped = RefreshService.clampedRefreshInterval(refreshInterval)
            guard clamped == refreshInterval else {
                refreshInterval = clamped
                return
            }
            StockbarRuntimeStorage.userDefaults.set(refreshInterval, forKey: "refreshInterval")
            // Update RefreshService interval when changed
            Task { @MainActor in
                refreshService?.refreshInterval = refreshInterval
            }
        }
    }
    
    // MARK: - Historical Data Backfill State
    @ObservationIgnored private var hasRunStartupBackfill = false // Prevent duplicate startup tasks
    
    // Cache management now handled by CacheCoordinator service
    
    // MARK: - Memory Management
    @ObservationIgnored private var memoryOptimizer: MemoryOptimizedDataModel?
    @ObservationIgnored private var isMemoryOptimizationEnabled = true
    @ObservationIgnored private(set) var hasCompletedInitialTradeLoad = false
    /// False when the model was created without runtime services (tests, previews), where
    /// no stored portfolio is loaded and so no load has to finish before saving.
    @ObservationIgnored private var requiresInitialTradeLoad = true
    @ObservationIgnored private var mayStartRuntimeSchedulers = false
    /// Set while a settings import runs and until relaunch; cleared only when
    /// a failed import is rolled back.
    @ObservationIgnored private(set) var isBackgroundWorkPausedForImport = false

    var userData: UserData {
        didSet {
            // Save data whenever it changes
            saveUserData()
        }
    }

    // MARK: - Initialization

    init(
        currencyConverter: CurrencyConverter = .shared,
        startRuntimeServices: Bool = true
    ) {
        self.currencyConverter = currencyConverter
        // Pure calculation service: create it up front so totals never fall
        // back to a placeholder $0.00 while runtime services start.
        self.portfolioCalculationService = PortfolioCalculationService(currencyConverter: currencyConverter)

        // Initialize userData first without triggering persistence during construction.
        _userData = Self.loadUserData(decoder: decoder)

        // Initialize realTimeTrades first - will be loaded async after init
        self.realTimeTrades = []
        self.isInitialPortfolioSourceResolved = !startRuntimeServices
        self.requiresInitialTradeLoad = startRuntimeServices
        
        // Note: All data loading now happens asynchronously via loadTradesAsync()
        // including migration of cost currency and trading info currency

        guard startRuntimeServices else {
            return
        }

        setupPublishers() // Keep as is
        Task { await logger.info("DataModel initialized, loading trades asynchronously...") }

        // Initialize services with dependencies (must be done after self is fully initialized)
        Task { @MainActor in
            self.refreshService = RefreshService(
                networkService: networkService,
                cacheCoordinator: cacheCoordinator,
                refreshInterval: refreshInterval
            )
            self.refreshService.setDataModel(self)
            
            self.historicalDataCoordinator = HistoricalDataCoordinator(
                networkService: networkService,
                historicalDataManager: historicalDataManager
            )
        }

        // Load trades asynchronously
        Task {
            guard await loadTradesAsync() else {
                markInitialPortfolioSourceResolved()
                await logger.error("Automatic refresh and provider schedulers remain stopped because startup persistence validation failed.")
                return
            }

            // One-time repair of UK price snapshots stored on mixed pence/pound
            // scales; analytics read these snapshots without display-time guards.
            // Runs after the trades load so their saved quotes can be the reference.
            await self.repairUKPriceSnapshotScaleIfNeeded()

            // Emergency recovery removed by user request

            await MainActor.run {
                self.startStaggeredRefresh()
            }
            await self.restartFolyncPortfolioScheduler(runImmediately: true)
            markInitialPortfolioSourceResolved()
            await MainActor.run {
                if !self.isFolyncPortfolioActive {
                    self.restartTrading212LinkedSyncScheduler(keepBackoff: true)
                }
            }
        }

        // Apply normalization to loaded stock currency data to ensure consistency
        normalizeLoadedStockCurrencies()

        // One-time rescale of UK OHLC rows stored in pence before the GBX->GBP
        // fix landed in get_ohlc_data.py. Runs before any chart reads the store.
        Task { await OHLCPenceMigrationService.shared.migrateIfNeeded() }

        // Initialize memory optimization
        setupMemoryManagement()
        
        // NEW: Start enhanced portfolio calculation in background after app startup
        Task { @MainActor in
            // Prevent multiple startup tasks
            guard !hasRunStartupBackfill else {
                await logger.info("🔍 STARTUP: Skipping - startup backfill already initiated")
                return
            }
            hasRunStartupBackfill = true

            // Wait 60 seconds after app startup to avoid interfering with initial data loading
            try? await Task.sleep(nanoseconds: 60_000_000_000)

            // A settings import pauses background work until Stockbar relaunches;
            // this delayed work must not write the old in-memory state meanwhile.
            guard mayStartRuntimeSchedulers, !isBackgroundWorkPausedForImport else { return }

            // Check if migration service indicates retroactive calculation is needed
            if migrationService.needsRetroactiveCalculation {
                await logger.info("🔄 MIGRATION: DataMigrationService indicates retroactive portfolio calculation is needed")
                await historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
                // Clear the flag after calculation
                migrationService.needsRetroactiveCalculation = false
                await logger.info("🔄 MIGRATION: Retroactive calculation completed and flag cleared")
            } else {
                // Check if we need to calculate retroactive portfolio history (regular check)
                await logger.info("🔄 STARTUP: Checking if regular retroactive portfolio calculation is needed")
                await historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
            }

            // AUTO-BACKFILL: Delegate to HistoricalDataCoordinator for startup backfill
            guard !isBackgroundWorkPausedForImport else { return }
            let symbols = legacyHistoryBackfillSymbols(from: realTimeTrades.map { $0.trade.name })
            await historicalDataCoordinator.performStartupBackfillIfNeeded(symbols: symbols) { [weak self] in
                self?.isBackgroundWorkPausedForImport ?? true
            }
        }

        // INTELLIGENT BACKFILL SCHEDULER: Start automatic gap detection and scheduled backfills
        Task { @MainActor in
            // The wait returns as soon as the load finishes. The default 15 s
            // was too short for a launch that migrates the store, and missing
            // it meant no gap checks or scheduled backfills until the next launch.
            guard await waitForInitialTradeLoad(timeout: 600), mayStartRuntimeSchedulers else { return }
            BackfillScheduler.shared.start(dataModel: self)
        }
    }

    // MARK: - Memory Management Methods
    
    private func setupMemoryManagement() {
        guard isMemoryOptimizationEnabled else { return }
        
        memoryOptimizer = MemoryOptimizedDataModel()
        Task {
            await MemoryManagementService.shared.startMonitoring()
            await logger.debug("Memory cache optimization and pressure monitoring enabled")
        }
    }
    
    deinit {
        trading212BrokerSyncTask?.cancel()
        folyncRefreshTask?.cancel()
    }
    
    // MARK: - Migration Methods
    
    private func repairUKPriceSnapshotScaleIfNeeded() async {
        var savedQuotes: [String: Double] = [:]
        for trade in realTimeTrades where SymbolMetadata.isUKSymbol(trade.trade.name) {
            let price = trade.realTimeInfo.currentPrice
            if price.isFinite, price > 0 { savedQuotes[trade.trade.name.uppercased()] = price }
        }
        let repairedSymbols = await UKPriceSnapshotScaleMigrationService.shared.migrateIfNeeded(savedQuotes: savedQuotes)
        guard !repairedSymbols.isEmpty else { return }
        historicalDataManager.invalidatePriceData(for: repairedSymbols)
        await historicalDataManager.reloadStoredPriceHistory(for: repairedSymbols)
    }

    private func isBenchmarkSymbol(_ symbol: String) -> Bool {
        SymbolMetadata.isBenchmarkSymbol(symbol)
    }
    
    private func isBenchmarkTrade(_ trade: RealTimeTrade) -> Bool {
        isBenchmarkSymbol(trade.trade.name)
    }
    
    private func removePersistedBenchmarks() {
        let beforeCount = realTimeTrades.count
        realTimeTrades.removeAll { isBenchmarkTrade($0) }
        let removed = beforeCount - realTimeTrades.count
        if removed > 0 {
            Task { await logger.info("Removed \(removed) persisted benchmark trades") }
        }
    }
    
    private func migrateCostCurrencyData() {
        var needsSave = false
        
        for trade in realTimeTrades {
            if trade.trade.position.costCurrency == nil {
                // Auto-detect currency based on symbol
                let detectedCurrency = SymbolMetadata.isUKSymbol(trade.trade.name) ? "GBX" : "USD"
                trade.trade.position.costCurrency = detectedCurrency
                needsSave = true
                Task { await logger.info("Migrated \(trade.trade.name) to use \(detectedCurrency) as cost currency") }
            }
        }
        
        if needsSave {
            saveTrades(realTimeTrades)
            Task { await logger.info("Migration complete - saved updated trade data with cost currencies") }
        }
    }
    
    private func migrateRealTimeTradesCurrency() {
        var needsSave = false
        
        for trade in realTimeTrades {
            if trade.realTimeInfo.currency == nil {
                // Auto-detect currency based on symbol
                let detectedCurrency = SymbolMetadata.defaultCurrency(for: trade.trade.name)
                trade.realTimeInfo.currency = detectedCurrency
                needsSave = true
                Task { await logger.info("Migrated real-time info for \(trade.trade.name) to use \(detectedCurrency) currency") }
            }
        }
        
        if needsSave {
            saveTradingInfo()
            Task { await logger.info("Migration complete - saved updated trading info with currencies") }
        }
    }
    
    // MARK: - Core Data Aware Persistence Methods

    func markInitialPortfolioSourceResolved() {
        guard !isInitialPortfolioSourceResolved else { return }
        isInitialPortfolioSourceResolved = true
    }

    func waitForInitialTradeLoad(timeout: TimeInterval = 15) async -> Bool {
        if hasCompletedInitialTradeLoad {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !hasCompletedInitialTradeLoad && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }

        return hasCompletedInitialTradeLoad
    }
    
    /// Load trades asynchronously from Core Data
    private func loadTradesAsync() async -> Bool {
        await logger.info("🔄 Loading trades from Core Data...")
        
        do {
            // First, trigger migration if needed
            try await migrationService.performFullMigration()
            
            // Load trades from Core Data
            await logger.info("📊 Loading trades from Core Data")
            _ = try await recoverLegacyUserTradesIfNeeded(
                afterLoading: try await tradeDataService.loadAllTrades()
            )
            let aliasRepair = try await aliasIdentityMigrationService.migrateIfNeeded()
            if aliasRepair.didChange {
                await logger.info("Repaired instrument aliases without summing duplicate broker quantities: \(aliasRepair.aliases)")
            }
            if !aliasRepair.quarantinedProviderKeys.isEmpty {
                await logger.warning("Left ambiguous instrument aliases unchanged for review: \(aliasRepair.quarantinedProviderKeys.sorted())")
            }

            // Create RealTimeTrade objects
            let realTimeTrades = aliasRepair.repairedTrades.map { trade in
                RealTimeTrade(
                    trade: trade,
                    realTimeInfo: aliasRepair.tradingInfoBySymbol[trade.name] ?? TradingInfo()
                )
            }
            
            // Update on main thread
            await MainActor.run {
                // Apply saved order to the loaded trades
                self.realTimeTrades = self.applyUserOrderToTrades(realTimeTrades)
                Task { await logger.info("✅ Loaded \(realTimeTrades.count) trades successfully from Core Data with user order") }
                // Named now: by the time the log task runs, benchmarks have joined the list.
                let loadedNames = self.realTimeTrades.map { $0.trade.name }.joined(separator: ", ")
                Task { await logger.info("📋 DIAGNOSTIC: Trades loaded: \(loadedNames)") }

                // Apply migrations after loading
                self.removePersistedBenchmarks()
                self.migrateCostCurrencyData()
                self.migrateRealTimeTradesCurrency()
                
                self.ensureBenchmarkTracking()
                self.hasCompletedInitialTradeLoad = true
                self.mayStartRuntimeSchedulers = true
            }

            // Kick off an immediate refresh for anything that isn't fresh yet
            await refreshCriticalSymbols(reason: "initial-load")
            return true
        } catch {
            await logger.error("❌ Failed to load trades from Core Data: \(error)")
            let detail = (error as? AliasIdentityMigrationError)?.errorDescription

            // Initialize with empty trades if Core Data fails
            await MainActor.run {
                self.realTimeTrades = []
                self.portfolioLoadFailureDetail = detail
                // Every save replaces the whole stored portfolio, so the unread
                // holdings would be lost by the next edit. Block writes until a
                // restore or import replaces the portfolio deliberately.
                self.portfolioLoadFailed = true
                self.hasCompletedInitialTradeLoad = true
                self.mayStartRuntimeSchedulers = false
                self.ensureBenchmarkTracking()
                Task { await logger.warning("⚠️ Initialized with empty trades due to Core Data failure") }
            }
            return false
        }
    }

    /// Set once Core Data has held a portfolio (or legacy trades were recovered
    /// once). After that an empty store means the user emptied it on purpose.
    nonisolated static let coreDataPortfolioEstablishedKey = "coreDataPortfolioEstablished"

    private func recoverLegacyUserTradesIfNeeded(afterLoading trades: [Trade]) async throws -> [Trade] {
        let defaults = StockbarRuntimeStorage.userDefaults
        let portfolioTrades = trades.filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }
        guard portfolioTrades.isEmpty else {
            defaults.set(true, forKey: Self.coreDataPortfolioEstablishedKey)
            return portfolioTrades
        }
        // Recover only before Core Data has ever held the portfolio; otherwise
        // deleting every holding brought old legacy holdings back on relaunch.
        guard !defaults.bool(forKey: Self.coreDataPortfolioEstablishedKey) else {
            return portfolioTrades
        }

        guard let legacyData = StockbarRuntimeStorage.userDefaults.data(forKey: "usertrades") else {
            return portfolioTrades
        }

        let legacyTrades = try decoder.decode([Trade].self, from: legacyData)
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }

        guard !legacyTrades.isEmpty else {
            return portfolioTrades
        }

        await logger.warning("⚠️ Core Data portfolio was empty; recovering \(legacyTrades.count) trades from legacy UserDefaults")
        try await tradeDataService.saveAllTrades(legacyTrades)
        defaults.set(true, forKey: Self.coreDataPortfolioEstablishedKey)
        return legacyTrades
    }
    
    
    internal func saveTradingInfo() {
        // Folync display rows must not overwrite the local price cache.
        guard !portfolioLoadFailed, !isFolyncPortfolioActive else { return }
        let tradingInfoDict = Dictionary(firstValuesFor: realTimeTrades
            .filter { !isBenchmarkTrade($0) }
            .map { ($0.trade.name, $0.realTimeInfo) })
        
        // Background save, ordered after any earlier pending save.
        let tradeDataService = tradeDataService
        enqueuePersistence { [logger] in
            do {
                try await tradeDataService.saveAllTradingInfo(tradingInfoDict)
                await logger.debug("Saved trading info for \(tradingInfoDict.count) symbols to Core Data")
            } catch {
                await logger.error("Failed to save trading info to Core Data: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public Methods

    nonisolated static func filterFolyncRoutedHistoryBackfills(
        from symbols: [String],
        lineHistoryActive: Bool,
        benchmarkDataActive: Bool,
        folyncHistorySymbols: Set<String>,
        folyncBenchmarkSymbols: Set<String>
    ) -> [String] {
        func normalized(_ values: Set<String>) -> Set<String> {
            Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() })
        }

        let routedHistory = normalized(folyncHistorySymbols)
        let routedBenchmarks = normalized(folyncBenchmarkSymbols)
        return symbols.filter { symbol in
            let key = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if SymbolMetadata.isBenchmarkSymbol(symbol) {
                return !(benchmarkDataActive && routedBenchmarks.contains(key))
            }
            return !(lineHistoryActive && routedHistory.contains(key))
        }
    }

    private func legacyHistoryBackfillSymbols(from symbols: [String]) -> [String] {
        let settings = FolyncSettingsStore.shared.load()
        var historySymbols = Set<String>()
        var benchmarkSymbols = Set<String>()

        for holding in folyncPortfolioSnapshot?.holdings ?? [] {
            historySymbols.formUnion(holding.resolvedAliases)
            historySymbols.insert(holding.resolvedDisplayTicker)
        }
        if let capabilities = folyncCapabilities {
            for identity in capabilities.trackedAssets {
                historySymbols.formUnion(identity.normalizedAliases)
            }
            historySymbols.formUnion(
                capabilities.trackedSymbols.filter { !SymbolMetadata.isBenchmarkSymbol($0) }
            )
            benchmarkSymbols.formUnion(capabilities.benchmarks.map(\.symbol))
        }

        return Self.filterFolyncRoutedHistoryBackfills(
            from: symbols,
            lineHistoryActive: settings.isSupplementalRouteActive(.historicalLineCharts),
            benchmarkDataActive: settings.isSupplementalRouteActive(.benchmarkMarketData),
            folyncHistorySymbols: historySymbols,
            folyncBenchmarkSymbols: benchmarkSymbols
        )
    }

    /// Checks for missing historical data and triggers backfill if needed (legacy 1-month check) - delegates to HistoricalDataCoordinator
    @MainActor
    public func checkAndBackfillHistoricalData() async {
        let symbols = legacyHistoryBackfillSymbols(from: realTimeTrades.map { $0.trade.name })
        await historicalDataCoordinator.checkAndBackfillHistoricalData(symbols: symbols)
    }
    
    /// Comprehensive 5-year historical data coverage check and automatic backfill - delegates to HistoricalDataCoordinator
    @MainActor
    public func checkAndBackfill5YearHistoricalData() async {
        let symbols = legacyHistoryBackfillSymbols(from: realTimeTrades.map { $0.trade.name })
        await historicalDataCoordinator.checkAndBackfill5YearHistoricalData(symbols: symbols)
        
        // FIX: Trigger retroactive calculation after backfill
        await logger.info("🔄 AUTO: Triggering retroactive portfolio calculation after 5-year backfill")
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: true)
    }
    
    /// Backfills historical data for specified symbols in chunks to avoid hanging - delegates to HistoricalDataCoordinator
    public func backfillHistoricalData(for symbols: [String]) async {
        await historicalDataCoordinator.backfillHistoricalData(
            for: legacyHistoryBackfillSymbols(from: symbols)
        )
        
        // FIX: Trigger retroactive calculation after backfill
        await logger.info("🔄 AUTO: Triggering retroactive portfolio calculation after backfill")
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: true)
    }
    
    
    /// Manually triggers a 5-year chunked historical data backfill for all symbols - delegates to HistoricalDataCoordinator
    public func triggerFullHistoricalBackfill() async {
        let symbols = realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
        await historicalDataCoordinator.triggerFullHistoricalBackfill(symbols: symbols)
        
        // FIX: Trigger retroactive calculation after manual backfill
        await logger.info("🔄 MANUAL: Triggering retroactive portfolio calculation after manual backfill")
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: true)
    }
    
    /// Returns the current status of automatic historical data checking - delegates to HistoricalDataCoordinator
    @MainActor
    public func getHistoricalDataStatus() -> HistoricalDataStatus {
        return historicalDataCoordinator.getHistoricalDataStatus()
    }
    
    
    
    
    /// Verifies a specific API key for a service
    func verifyAPIKey(service: String) async throws -> Bool {
        await logger.info("Verifying API key for service: \(service)")
        return try await networkService.verifyAPIKey(service: service)
    }
    

    /// Triggers retroactive portfolio calculation for a specific number of days
    /// This will calculate portfolio values retroactively from existing historical data
    public func calculateRetroactivePortfolioHistory(days: Int, force: Bool = false) async {
        await logger.info("🔄 BACKFILL: Starting \(days)-day retroactive portfolio calculation (force: \(force))")

        // Calculate portfolio history from existing historical data in Core Data
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: force)

        await logger.info("✅ BACKFILL: \(days)-day retroactive portfolio calculation completed")
    }
    
    /// Refreshes all stock data from the network using the configured networkService
    @objc func refreshAllTrades() async {
        await performRefreshAllTrades()
    }

    /// While Folync supplies the portfolio the rows on screen are Folync's. A
    /// Trading 212 sync planned against them would find every linked holding
    /// missing and drop its link.
    static let trading212SkippedForFolyncReason = "Folync is the portfolio source; Trading 212 sync is paused."

    /// `keepBackoff` is for restarts Stockbar makes itself (launch, a finished
    /// import, switching back from Folync). They must not cut short a wait
    /// Trading 212 asked for; only a change the user saves starts afresh.
    func restartTrading212LinkedSyncScheduler(runImmediately: Bool = true, keepBackoff: Bool = false) {
        trading212BrokerSyncTimer?.invalidate()
        trading212BrokerSyncTimer = nil
        trading212BrokerSyncTask?.cancel()
        trading212BrokerSyncTask = nil
        if !keepBackoff {
            trading212NextScheduledAttempt = .distantPast
            trading212ScheduledFailureCount = 0
            trading212ScheduledSyncError = nil
        }

        guard !isFolyncPortfolioActive, !isBackgroundWorkPausedForImport else { return }

        let settings = trading212SettingsStore.load()
        let credentialState = trading212CredentialStore.storageState(environment: settings.environment)
        guard settings.isEnabled,
              settings.autoSyncEnabled,
              settings.accountType.isSupportedByPublicAPI,
              credentialState.isReadyForBackgroundAccess
        else {
            if settings.isEnabled,
               settings.autoSyncEnabled,
               settings.accountType.isSupportedByPublicAPI,
               credentialState == .legacySplitItems {
                Task {
                    await Logger.shared.warning(
                        "Trading 212 auto-sync not started because credentials use older split Keychain storage. Open Settings and run Test Connection or re-save credentials to upgrade."
                    )
                }
            }
            return
        }

        let intervalSeconds = Trading212SyncPolicy.clampedIntervalSeconds(settings.syncIntervalSeconds)
        Task {
            await Logger.shared.info(
                "Trading 212 auto-sync scheduler started: interval=\(intervalSeconds)s, environment=\(settings.environment.displayName)"
            )
        }
        if runImmediately {
            runTrading212ScheduledCycle(reason: "auto-start")
        }

        trading212BrokerSyncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalSeconds), repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runTrading212ScheduledCycle(reason: "auto")
            }
        }
        trading212BrokerSyncTimer?.tolerance = min(5.0, TimeInterval(intervalSeconds) * 0.1)
    }

    func suspendTrading212LinkedSyncScheduler() {
        trading212BrokerSyncTimer?.invalidate()
        trading212BrokerSyncTimer = nil
        trading212BrokerSyncTask?.cancel()
        trading212BrokerSyncTask = nil
    }

    private func runTrading212ScheduledCycle(reason: String) {
        guard Date() >= trading212NextScheduledAttempt else { return }
        guard trading212BrokerSyncTask == nil else { return }

        trading212BrokerSyncGeneration &+= 1
        let generation = trading212BrokerSyncGeneration
        trading212BrokerSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.trading212BrokerSyncGeneration == generation {
                    self.trading212BrokerSyncTask = nil
                }
            }

            let settings = self.trading212SettingsStore.load()
            let reconciliationInterval = TimeInterval(max(
                Trading212SyncPolicy.defaultHoldingReconciliationIntervalSeconds,
                settings.holdingReconciliationIntervalSeconds
            ))
            let shouldReconcile = settings.autoReconcileHoldingsEnabled
                && Date().timeIntervalSince(self.lastTrading212ScheduledReconciliation) >= reconciliationInterval

            do {
                if shouldReconcile {
                    _ = try await self.reconcileTrading212Holdings(reason: "\(reason)-reconcile")
                    self.lastTrading212ScheduledReconciliation = Date()
                } else {
                    _ = try await self.syncLinkedTrading212Holdings(reason: reason)
                }
                self.trading212ScheduledFailureCount = 0
                self.trading212NextScheduledAttempt = .distantPast
                self.trading212ScheduledSyncError = nil
            } catch {
                // Cancellation (suspend or restart) is not a provider failure.
                if error is CancellationError || Task.isCancelled { return }
                self.trading212ScheduledFailureCount += 1
                self.trading212ScheduledSyncError = LogRedactor.redact(error.localizedDescription)
                // Rejected credentials will not start working on their own. Stop until the
                // scheduler is restarted, which saving new credentials does.
                // A damaged links file does not mend itself either; retrying
                // every cycle only repeats the same error in the log.
                if error as? BrokerLinkStoreError == .unreadableFile {
                    self.trading212NextScheduledAttempt = .distantFuture
                    await Logger.shared.error(
                        "Trading 212 scheduled cycle \(reason) stopped: the links file is damaged. Automatic sync is paused until Trading 212 settings are saved again."
                    )
                    return
                }
                if let providerError = error as? Trading212ProviderError,
                   providerError == .unauthorized || providerError == .forbidden {
                    self.trading212NextScheduledAttempt = .distantFuture
                    await Logger.shared.warning(
                        "Trading 212 scheduled cycle \(reason) was rejected; automatic sync is paused until the credentials are saved again: \(LogRedactor.redact(error.localizedDescription))"
                    )
                    return
                }
                let retryAfter: TimeInterval?
                if case let Trading212ProviderError.rateLimited(value) = error {
                    retryAfter = value
                } else {
                    retryAfter = nil
                }
                let policy = Trading212BackoffPolicy(
                    configuredInterval: TimeInterval(
                        Trading212SyncPolicy.clampedIntervalSeconds(settings.syncIntervalSeconds)
                    )
                )
                let delay = policy.delay(
                    failureCount: self.trading212ScheduledFailureCount,
                    retryAfter: retryAfter
                )
                self.trading212NextScheduledAttempt = Date().addingTimeInterval(delay)
                await Logger.shared.warning(
                    "Trading 212 scheduled cycle \(reason) failed; retrying in \(Int(delay.rounded()))s: \(LogRedactor.redact(error.localizedDescription))"
                )
            }
        }
    }

    func syncLinkedTrading212Holdings(reason: String = "manual") async throws -> Trading212BrokerSyncResult {
        guard !isTrading212BrokerSyncInProgress else {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 sync is already running."
            )
        }
        guard !isFolyncPortfolioActive else {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: Self.trading212SkippedForFolyncReason
            )
        }
        isTrading212BrokerSyncInProgress = true
        defer { isTrading212BrokerSyncInProgress = false }

        let settings = trading212SettingsStore.load()
        guard settings.isEnabled, settings.accountType.isSupportedByPublicAPI else {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 is not enabled."
            )
        }

        let allowKeychainPrompt = !reason.hasPrefix("auto")
        let credentials: Trading212AuthConfiguration
        do {
            credentials = try trading212CredentialStore.load(
                environment: settings.environment,
                allowUserInteraction: allowKeychainPrompt
            )
        } catch Trading212CredentialStoreError.keychainStatus(let status)
            where !allowKeychainPrompt && status == errSecInteractionNotAllowed {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 credentials need Keychain approval. Open Settings and run Test Connection or Sync Linked Holdings once."
            )
        }
        var links = try await trading212BrokerLinkStore.loadSnapshot()
        let trading212AccountKeys = Set(links.accounts.filter { $0.broker == "Trading212" }.map(\.brokerAccountKey))
        guard links.positions.contains(where: { trading212AccountKeys.contains($0.brokerAccountKey) }) else {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "No linked Trading 212 holdings found. Run Preview Import and Link Matched Holdings first."
            )
        }

        let preview = try await trading212PreviewCoordinator.preview(
            settings: settings,
            credentials: credentials,
            existingManualHoldings: realTimeTrades.map { trading212ManualHoldingSnapshot(from: $0) },
            existingBrokerLinks: links,
            includeMetadata: false,
            useCache: false
        )
        // Folync may have taken over while the request was in flight.
        guard !isFolyncPortfolioActive else {
            return Trading212BrokerSyncResult(
                updatedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: Self.trading212SkippedForFolyncReason
            )
        }
        if try await trading212BrokerLinkStore.adoptLinks(for: preview.account) {
            links = try await trading212BrokerLinkStore.loadSnapshot()
            await logger.info("Trading 212 account key changed (label or API key); moved existing links to the new key")
        }
        if try await trading212BrokerLinkStore.recordISINs(from: preview.rows) {
            links = try await trading212BrokerLinkStore.loadSnapshot()
        }
        let plan = trading212BrokerSyncPlanner.plan(
            existingTrades: realTimeTrades.map(\.trade),
            tradingInfoBySymbol: tradingInfoBySymbol(),
            links: links,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: settings.deleteMissingLinkedHoldings),
            quarantinedProviderKeys: AliasIdentityMigrationService.quarantinedProviderKeys(),
            syncedAt: Date()
        )

        trading212BrokerValuationSnapshot = plan.valuationSnapshot
        if !plan.tradeUpdates.isEmpty { lastTrading212LinkedSyncAt = Date() }
        applyTrading212BrokerSyncPlan(plan)
        if !plan.deletedLinkIDs.isEmpty {
            _ = try await trading212BrokerLinkStore.removePositions(ids: plan.deletedLinkIDs)
        }
        if plan.changedCount > 0 {
            persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
        }

        let result = Trading212BrokerSyncResult(
            updatedCount: plan.tradeUpdates.count,
            deletedCount: plan.deletedManualSymbols.count,
            missingCount: plan.missingLinkedSymbols.count,
            brokerOnlyCount: plan.brokerOnlyCount,
            skippedReason: nil
        )
        await logger.info("Trading 212 linked sync (\(reason)): \(result.userMessage)")
        return result
    }

    func reconcileTrading212Holdings(reason: String = "manual-reconcile") async throws -> Trading212HoldingReconciliationResult {
        guard !isTrading212HoldingReconciliationInProgress else {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 holding reconciliation is already running."
            )
        }
        guard !isTrading212BrokerSyncInProgress else {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 live-value sync is already running; hourly holding reconciliation skipped this cycle."
            )
        }

        guard !isFolyncPortfolioActive else {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: Self.trading212SkippedForFolyncReason
            )
        }
        isTrading212HoldingReconciliationInProgress = true
        defer { isTrading212HoldingReconciliationInProgress = false }

        let settings = trading212SettingsStore.load()
        guard settings.isEnabled,
              settings.autoReconcileHoldingsEnabled,
              settings.accountType.isSupportedByPublicAPI else {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 hourly holding reconciliation is not enabled."
            )
        }

        let allowKeychainPrompt = !reason.hasPrefix("auto")
        let credentials: Trading212AuthConfiguration
        do {
            credentials = try trading212CredentialStore.load(
                environment: settings.environment,
                allowUserInteraction: allowKeychainPrompt
            )
        } catch Trading212CredentialStoreError.keychainStatus(let status)
            where !allowKeychainPrompt && status == errSecInteractionNotAllowed {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 credentials need Keychain approval. Open Settings and run Test Connection once."
            )
        }

        let existingManualHoldings = realTimeTrades.map { trading212ManualHoldingSnapshot(from: $0) }
        var links = try await trading212BrokerLinkStore.loadSnapshot()
        var preview = try await trading212PreviewCoordinator.preview(
            settings: settings,
            credentials: credentials,
            existingManualHoldings: existingManualHoldings,
            existingBrokerLinks: links,
            includeMetadata: true,
            useCache: false
        )
        if try await trading212BrokerLinkStore.adoptLinks(for: preview.account) {
            // The preview matched rows against the old keys; rebuild it so linked
            // holdings are not mistaken for broker-only ones and imported again.
            links = try await trading212BrokerLinkStore.loadSnapshot()
            preview = try await trading212PreviewCoordinator.preview(
                settings: settings,
                credentials: credentials,
                existingManualHoldings: existingManualHoldings,
                existingBrokerLinks: links,
                includeMetadata: true,
                useCache: false
            )
            await logger.info("Trading 212 account key changed (label or API key); moved existing links to the new key")
        }
        // Folync may have taken over while the requests were in flight.
        guard !isFolyncPortfolioActive else {
            return Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: 0,
                brokerOnlyCount: 0,
                skippedReason: Self.trading212SkippedForFolyncReason
            )
        }
        if try await trading212BrokerLinkStore.recordISINs(from: preview.rows) {
            links = try await trading212BrokerLinkStore.loadSnapshot()
        }
        let linkedPositionsForAccount = links.positions.filter { $0.brokerAccountKey == preview.account.brokerAccountKey }

        guard !preview.rows.isEmpty || linkedPositionsForAccount.isEmpty else {
            let result = Trading212HoldingReconciliationResult(
                syncedCount: 0,
                importedCount: 0,
                deletedCount: 0,
                missingCount: linkedPositionsForAccount.count,
                brokerOnlyCount: 0,
                skippedReason: "Trading 212 returned no positions for an account with linked holdings. Stockbar did not delete anything; run Preview Import to review."
            )
            await logger.warning("Trading 212 holding reconciliation (\(reason)): \(result.userMessage)")
            return result
        }

        let syncPlan = trading212BrokerSyncPlanner.plan(
            existingTrades: realTimeTrades.map(\.trade),
            tradingInfoBySymbol: tradingInfoBySymbol(),
            links: links,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: settings.deleteMissingLinkedHoldings),
            quarantinedProviderKeys: AliasIdentityMigrationService.quarantinedProviderKeys(),
            syncedAt: Date()
        )
        trading212BrokerValuationSnapshot = syncPlan.valuationSnapshot
        if !syncPlan.tradeUpdates.isEmpty { lastTrading212LinkedSyncAt = Date() }
        applyTrading212BrokerSyncPlan(syncPlan)
        if !syncPlan.deletedLinkIDs.isEmpty {
            _ = try await trading212BrokerLinkStore.removePositions(ids: syncPlan.deletedLinkIDs)
        }

        let importPlan = settings.autoImportBrokerOnlyHoldings
            ? trading212BrokerOnlyImportPlanner.plan(
                existingTrades: realTimeTrades.map(\.trade),
                existingLinks: links,
                preview: preview,
                quarantinedProviderKeys: AliasIdentityMigrationService.quarantinedProviderKeys(),
                importedAt: Date()
            )
            : Trading212BrokerOnlyImportPlan(records: [], skippedRows: [])
        let importedAt = Date()
        for record in importPlan.records {
            realTimeTrades.append(RealTimeTrade(trade: record.trade, realTimeInfo: record.tradingInfo))
            let displayPrice = record.tradingInfo.getCurrentDisplayPrice()
            if displayPrice.isFinite, displayPrice > 0 {
                historicalDataManager.recordLivePriceSample(
                    symbol: record.manualSymbol,
                    price: displayPrice,
                    previousClose: record.tradingInfo.prevClosePrice,
                    timestamp: importedAt
                )
            }
        }
        if !importPlan.records.isEmpty {
            _ = try await trading212BrokerLinkStore.upsertImportedPositions(
                account: preview.account,
                positions: importPlan.records.map(\.linkedPosition),
                linkedAt: importedAt
            )
        }

        if syncPlan.changedCount > 0 || !importPlan.records.isEmpty {
            persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
        }

        let result = Trading212HoldingReconciliationResult(
            syncedCount: syncPlan.tradeUpdates.count,
            importedCount: importPlan.records.count,
            deletedCount: syncPlan.deletedManualSymbols.count,
            missingCount: syncPlan.missingLinkedSymbols.count,
            brokerOnlyCount: syncPlan.brokerOnlyCount,
            skippedReason: nil
        )
        await logger.info("Trading 212 holding reconciliation (\(reason)): \(result.userMessage)")
        return result
    }

    func importBrokerOnlyTrading212Holdings(from preview: Trading212ImportPreview) async throws -> Trading212BrokerOnlyImportResult {
        let importedAt = Date()
        let links = try await trading212BrokerLinkStore.loadSnapshot()
        let plan = trading212BrokerOnlyImportPlanner.plan(
            existingTrades: realTimeTrades.map(\.trade),
            existingLinks: links,
            preview: preview,
            quarantinedProviderKeys: AliasIdentityMigrationService.quarantinedProviderKeys(),
            importedAt: importedAt
        )

        guard !plan.records.isEmpty else {
            return Trading212BrokerOnlyImportResult(
                importedCount: 0,
                linkedCount: 0,
                skippedCount: plan.skippedRows.count,
                importedSymbols: [],
                skippedRows: plan.skippedRows
            )
        }

        for record in plan.records {
            realTimeTrades.append(RealTimeTrade(trade: record.trade, realTimeInfo: record.tradingInfo))
            let displayPrice = record.tradingInfo.getCurrentDisplayPrice()
            if displayPrice.isFinite, displayPrice > 0 {
                historicalDataManager.recordLivePriceSample(
                    symbol: record.manualSymbol,
                    price: displayPrice,
                    previousClose: record.tradingInfo.prevClosePrice,
                    timestamp: importedAt
                )
            }
        }

        let linkResult = try await trading212BrokerLinkStore.upsertImportedPositions(
            account: preview.account,
            positions: plan.records.map(\.linkedPosition),
            linkedAt: importedAt
        )
        persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
        restartTrading212LinkedSyncScheduler(runImmediately: false, keepBackoff: true)

        let result = Trading212BrokerOnlyImportResult(
            importedCount: plan.records.count,
            linkedCount: linkResult.linkedCount,
            skippedCount: plan.skippedRows.count,
            importedSymbols: plan.records.map(\.manualSymbol),
            skippedRows: plan.skippedRows
        )
        await logger.info("Trading 212 broker-only import: \(result.userMessage)")
        return result
    }

    func trading212LinkedMarketRefreshPlan() async -> BrokerLinkedMarketRefreshPlan {
        let settings = trading212SettingsStore.load()
        let credentialState = trading212CredentialStore.storageState(environment: settings.environment)
        guard settings.isEnabled,
              settings.autoSyncEnabled,
              credentialState.isReadyForBackgroundAccess else {
            return .empty
        }
        // Defer to the broker only while its sync is actually updating linked
        // holdings. If sync stops matching (revoked key, outage), market prices
        // resume instead of freezing.
        let freshnessWindow = max(15 * 60, TimeInterval(3 * settings.syncIntervalSeconds))
        guard let lastSync = lastTrading212LinkedSyncAt,
              Date().timeIntervalSince(lastSync) < freshnessWindow else {
            return .empty
        }

        do {
            let snapshot = try await trading212BrokerLinkStore.loadSnapshot()
            let accountKeys = Set(snapshot.accounts.filter { $0.broker == "Trading212" }.map(\.brokerAccountKey))
            let infoBySymbol = tradingInfoBySymbol()
            let linkedPositions = snapshot.positions.filter { accountKeys.contains($0.brokerAccountKey) }
            var skipSymbols: Set<String> = []
            var extendedSessionSymbols: Set<String> = []

            for position in linkedPositions {
                let symbol = position.manualSymbol.uppercased()
                let tradingInfo = infoBySymbol[symbol]

                if BrokerLinkedMarketDataRefreshPolicy.shouldSkipMarketRefresh(
                    symbol: position.manualSymbol,
                    tradingInfo: tradingInfo
                ) {
                    skipSymbols.insert(symbol)
                } else {
                    extendedSessionSymbols.insert(symbol)
                }
            }

            return BrokerLinkedMarketRefreshPlan(
                skipSymbols: skipSymbols,
                extendedSessionSymbols: extendedSessionSymbols
            )
        } catch {
            await logger.warning("Failed to load Trading 212 links for market-refresh skip list: \(LogRedactor.redact(error.localizedDescription))")
            return .empty
        }
    }

    /// Price alerts used to be checked only by the market-quote refresh, so
    /// holdings priced by Folync or Trading 212 never fired. Every price source
    /// now calls this after applying prices.
    func evaluatePriceAlerts(for trades: [RealTimeTrade]) {
        for trade in trades where !isBenchmarkTrade(trade) {
            let info = trade.realTimeInfo
            let price = info.getCurrentDisplayPrice()
            guard price.isFinite, price > 0 else { continue }
            PriceAlertService.shared.checkAlerts(
                symbol: trade.trade.name,
                currentPrice: price,
                previousPrice: info.prevClosePrice,
                currency: info.currency ?? "USD"
            )
        }
    }

    private func applyTrading212BrokerSyncPlan(_ plan: Trading212BrokerSyncPlan) {
        let updatesBySymbol = Dictionary(firstValuesFor: plan.tradeUpdates.map {
            ($0.manualSymbol.uppercased(), $0)
        })
        let deletedSymbols = Set(plan.deletedManualSymbols.map { $0.uppercased() })

        var updatedTrades: [RealTimeTrade] = []
        for realTimeTrade in realTimeTrades {
            let symbolKey = realTimeTrade.trade.name.uppercased()
            if deletedSymbols.contains(symbolKey), !isBenchmarkTrade(realTimeTrade) {
                continue
            }
            if let update = updatesBySymbol[symbolKey], !isBenchmarkTrade(realTimeTrade) {
                realTimeTrade.trade = update.trade
                realTimeTrade.realTimeInfo = update.tradingInfo
                let sampleTimestamp = update.tradingInfo.lastUpdateTime ?? 0
                let sampleTime = sampleTimestamp > 0
                    ? Date(timeIntervalSince1970: TimeInterval(sampleTimestamp))
                    : Date()
                historicalDataManager.recordLivePriceSample(
                    symbol: update.manualSymbol,
                    price: update.tradingInfo.getCurrentDisplayPrice(),
                    previousClose: update.tradingInfo.prevClosePrice,
                    timestamp: sampleTime
                )
            }
            updatedTrades.append(realTimeTrade)
        }

        realTimeTrades = updatedTrades
        evaluatePriceAlerts(for: updatedTrades.filter { updatesBySymbol[$0.trade.name.uppercased()] != nil })

        if !plan.tradeUpdates.isEmpty || !deletedSymbols.isEmpty {
            let summary = calculateDisplayPortfolioSummary(
                preferredCurrency: portfolioMenuBarDisplaySettings.currencyCode
            )
            historicalDataManager.recordLivePortfolioSample(
                totalValue: summary.totalValue,
                totalGains: summary.totalGain,
                currency: summary.currency,
                timestamp: Date()
            )
        }
    }

    private func tradingInfoBySymbol() -> [String: TradingInfo] {
        var values: [String: TradingInfo] = [:]
        for realTimeTrade in realTimeTrades {
            values[realTimeTrade.trade.name.uppercased()] = realTimeTrade.realTimeInfo
        }
        return values
    }

    private func trading212ManualHoldingSnapshot(from realTimeTrade: RealTimeTrade) -> Trading212ManualHoldingSnapshot {
        let trade = realTimeTrade.trade
        let displayName = realTimeTrade.realTimeInfo.shortName.isEmpty ? nil : realTimeTrade.realTimeInfo.shortName
        return Trading212ManualHoldingSnapshot(
            symbol: trade.name,
            displayName: displayName,
            quantity: trade.position.unitSize,
            averageCost: trade.position.positionAvgCost.isFinite ? trade.position.positionAvgCost : nil,
            currency: trade.position.currency ?? trade.position.costCurrency ?? realTimeTrade.realTimeInfo.currency,
            isWatchlistOnly: trade.isWatchlistOnly
        )
    }

    /// Triggers an immediate refresh for the provided symbols, bypassing the
    /// staggered rotation. Symbols are matched case-insensitively against the
    /// current portfolio.
    /// `force` (user-initiated) skips the freshness check and retry backoff.
    func refreshSymbolsImmediately(_ symbols: [String], reason: String, force: Bool = false) async {
        let uniqueTargets = Array(Set(symbols.map { $0.uppercased() }))
        guard !uniqueTargets.isEmpty else { return }

        guard refreshService != nil else {
            await Logger.shared.warning("Immediate refresh (\(reason)) skipped – refresh service not ready yet")
            return
        }

        await Logger.shared.info("🔄 Immediate refresh (\(reason)): \(uniqueTargets.count) symbols queued")

        let resolvedSymbols = realTimeTrades
            .map { $0.trade.name }
            .filter { uniqueTargets.contains($0.uppercased()) }

        guard !resolvedSymbols.isEmpty else {
            await Logger.shared.warning("Immediate refresh (\(reason)) resolved to 0 active symbols - skipping")
            return
        }

        await performRefreshAllTrades(limitedTo: resolvedSymbols, force: force)
    }

    /// Convenience helper that inspects cache status and refreshes any symbol
    /// that is not currently fresh.
    func refreshCriticalSymbols(reason: String) async {
        let now = Date()
        var needsRefresh: [String] = []
        for trade in realTimeTrades {
            let status = await cacheCoordinator.getCacheStatus(for: trade.trade.name, at: now)
            switch status {
            case .fresh:
                continue
            default:
                needsRefresh.append(trade.trade.name)
            }
        }

        guard !needsRefresh.isEmpty else {
            await Logger.shared.debug("No critical symbols detected for immediate refresh (reason: \(reason))")
            return
        }

        guard refreshService != nil else {
            await Logger.shared.debug("Refresh service not ready; deferring critical refresh (reason: \(reason))")
            return
        }

        await refreshSymbolsImmediately(needsRefresh, reason: reason)
    }

    /// Internal method that delegates refresh work to the RefreshService once it is ready.
    private func performRefreshAllTrades(limitedTo symbols: [String]? = nil, force: Bool = false) async {
        guard let refreshService else {
            await Logger.shared.warning("performRefreshAllTrades called before refreshService initialized")
            return
        }

        await refreshService.performRefreshAllTrades(limitedTo: symbols, force: force)
    }

    /// Memory-efficient calculation of portfolio metrics - delegates to PortfolioCalculationService
    func calculatePortfolioMetricsEfficiently() -> (gains: Double, value: Double, currency: String) {
        guard let service = portfolioCalculationService else {
            // Fallback if service not initialized yet
            return (0.0, 0.0, preferredCurrency)
        }
        return service.calculatePortfolioMetricsEfficiently(
            trades: realTimeTrades,
            preferredCurrency: preferredCurrency,
            memoryOptimizer: isMemoryOptimizationEnabled ? memoryOptimizer : nil
        )
    }

    /// Calculates the total net gains across all trades - delegates to PortfolioCalculationService
    func calculateNetGains() -> (amount: Double, currency: String) {
        if let snapshot = folyncPortfolioSnapshot,
           let value = snapshot.profitLoss.unrealized.value,
           value.isFinite {
            return (value, snapshot.profitLoss.unrealized.currency ?? snapshot.scope.currency ?? preferredCurrency)
        }
        guard let service = portfolioCalculationService else {
            // Fallback if service not initialized yet
            return (0.0, preferredCurrency)
        }
        return service.calculateNetGains(
            trades: realTimeTrades,
            preferredCurrency: preferredCurrency,
            brokerValuationSnapshot: freshTrading212BrokerValuationSnapshot()
        )
    }

    /// Calculates the total portfolio value (market value) in the preferred currency - delegates to PortfolioCalculationService
    func calculateNetValue() -> (amount: Double, currency: String) {
        if let snapshot = folyncPortfolioSnapshot,
           let value = snapshot.totalValue.value,
           value.isFinite {
            return (value, snapshot.totalValue.currency ?? snapshot.scope.currency ?? preferredCurrency)
        }
        guard let service = portfolioCalculationService else {
            // Fallback if service not initialized yet
            return (0.0, preferredCurrency)
        }
        return service.calculateNetValue(
            trades: realTimeTrades,
            preferredCurrency: preferredCurrency,
            brokerValuationSnapshot: freshTrading212BrokerValuationSnapshot()
        )
    }

    /// Calculates the display-aware portfolio summary used by menu bar portfolio surfaces.
    /// Where the displayed totals come from, decided the same way as
    /// `calculateDisplayPortfolioSummary` but without valuing every holding.
    /// For labels that only need the source name.
    var displayValuationSource: PortfolioValuationSource {
        if let total = folyncPortfolioSnapshot?.totalValue.value, total.isFinite {
            return .folyncProvided
        }
        guard portfolioCalculationService != nil else { return .localCalculationFallback }
        return freshTrading212BrokerValuationSnapshot() != nil ? .brokerProvided : .localCalculationFallback
    }

    func calculateDisplayPortfolioSummary(preferredCurrency overrideCurrency: String? = nil) -> DisplayPortfolioSummary {
        if let snapshot = folyncPortfolioSnapshot,
           let totalValue = snapshot.totalValue.value,
           totalValue.isFinite {
            let totalGain = snapshot.profitLoss.unrealized.value ?? .nan
            let dayGain = snapshot.profitLoss.day.value ?? .nan
            let totalCost = snapshot.holdings.reduce(0) { $0 + $1.costValue }
            let previousValue = totalValue - dayGain
            return DisplayPortfolioSummary(
                totalValue: totalValue,
                totalGain: totalGain,
                totalGainPct: totalCost > 0 ? totalGain / totalCost * 100 : .nan,
                dayGain: dayGain,
                dayGainPct: previousValue > 0 ? dayGain / previousValue * 100 : .nan,
                totalCost: totalCost,
                ownedPositionCount: snapshot.displayHoldings.count,
                currency: snapshot.scope.currency ?? preferredCurrency,
                valuationSource: .folyncProvided
            )
        }
        let summaryCurrency = overrideCurrency ?? preferredCurrency

        guard let service = portfolioCalculationService else {
            return DisplayPortfolioSummary(
                totalValue: 0.0,
                totalGain: 0.0,
                totalGainPct: 0.0,
                dayGain: 0.0,
                dayGainPct: 0.0,
                totalCost: 0.0,
                ownedPositionCount: 0,
                currency: summaryCurrency
            )
        }

        return service.calculateDisplayPortfolioSummary(
            trades: realTimeTrades,
            preferredCurrency: summaryCurrency,
            brokerValuationSnapshot: freshTrading212BrokerValuationSnapshot()
        )
    }

    /// True when another non-benchmark row uses the same symbol. Persistence
    /// keeps only the first row per symbol (`TradeDataService`), so editors
    /// must flag duplicates before the second row is silently dropped.
    func hasDuplicateSymbol(_ trade: RealTimeTrade) -> Bool {
        let key = Self.symbolKey(trade.trade.name)
        guard !key.isEmpty, !isBenchmarkTrade(trade) else { return false }
        return realTimeTrades.contains { other in
            other !== trade && !isBenchmarkTrade(other) && Self.symbolKey(other.trade.name) == key
        }
    }

    nonisolated static func symbolKey(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The user's own holdings for backups. While Folync is active the displayed
    /// rows are Folync's read-only ones and the local portfolio is set aside.
    var localPortfolioTradesForBackup: [RealTimeTrade] {
        (isFolyncPortfolioActive ? (legacyPortfolioTrades ?? []) : realTimeTrades)
            .filter { $0.sourceIdentity == nil }
    }

    /// Preserve provider-owned position valuations in window tables and inspectors.
    func positionFinancialFieldsReadOnly(for trade: RealTimeTrade) -> Bool {
        isFolyncPortfolioActive || trade.sourceIdentity != nil
            || freshTrading212BrokerValuationSnapshot()?.position(for: trade.trade.name) != nil
    }

    func setPositionMenuBarVisibility(_ visible: Bool, for trade: RealTimeTrade) {
        if let snapshot = folyncPortfolioSnapshot, let identity = trade.sourceIdentity,
           let holding = snapshot.holdings.first(where: { $0.overlayKey(scopeID: snapshot.scope.id) == identity }) {
            setFolyncHoldingVisibleInMenuBar(visible, holding: holding)
        } else {
            trade.trade.showInMenuBar = visible
            triggerTradeUpdate()
            NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
        }
    }

    func calculatePositionValue(for trade: RealTimeTrade) -> (amount: Double, currency: String) {
        if let snapshot = folyncPortfolioSnapshot,
           let identity = trade.sourceIdentity,
           let holding = snapshot.holdings.first(where: { $0.overlayKey(scopeID: snapshot.scope.id) == identity }) {
            return (holding.marketValue ?? .nan, holding.resolvedValueCurrency)
        }
        if let valuation = freshTrading212BrokerValuationSnapshot()?.position(for: trade.trade.name) {
            return (valuation.brokerCurrentValue, valuation.currency)
        }
        let amount = trade.realTimeInfo.getCurrentDisplayPrice() * trade.trade.position.unitSize
        return (amount.isFinite ? amount : .nan, trade.realTimeInfo.currency ?? "")
    }

    /// Calculates per-position P/L for Holdings rows using the shared portfolio math service.
    func calculatePositionProfitLoss(for realTimeTrade: RealTimeTrade) -> PositionProfitLossSummary {
        if let snapshot = folyncPortfolioSnapshot,
           let sourceIdentity = realTimeTrade.sourceIdentity,
           let holding = snapshot.holdings.first(where: {
               $0.overlayKey(scopeID: snapshot.scope.id) == sourceIdentity
           }) {
            return PositionProfitLossSummary(
                dayAmount: holding.dayGain ?? .nan,
                dayPercent: holding.dayGainPct ?? .nan,
                totalAmount: holding.totalGain ?? .nan,
                totalPercent: holding.totalGainPct ?? .nan,
                currency: holding.resolvedValueCurrency
            )
        }
        guard let service = portfolioCalculationService else {
            let currency = realTimeTrade.realTimeInfo.currency
                ?? realTimeTrade.trade.position.currency
                ?? realTimeTrade.trade.position.costCurrency
                ?? preferredCurrency

            return PositionProfitLossSummary(
                dayAmount: .nan,
                dayPercent: .nan,
                totalAmount: .nan,
                totalPercent: .nan,
                currency: currency
            )
        }

        let brokerValuation = freshTrading212BrokerValuationSnapshot()?.position(for: realTimeTrade.trade.name)
        return service.calculatePositionProfitLoss(for: realTimeTrade, brokerValuation: brokerValuation)
    }

    private func freshTrading212BrokerValuationSnapshot(now: Date = Date()) -> Trading212BrokerValuationSnapshot? {
        let settings = trading212SettingsStore.load()
        guard settings.isEnabled,
              settings.accountType.isSupportedByPublicAPI,
              let snapshot = trading212BrokerValuationSnapshot else {
            return nil
        }

        let expectedAccountPrefix = "Trading212|\(settings.environment.rawValue)|\(settings.accountType.rawValue)|"
        guard snapshot.accountKey.hasPrefix(expectedAccountPrefix) else {
            return nil
        }

        let maxAge = max(TimeInterval(settings.syncIntervalSeconds * 4), 120)
        guard snapshot.isFresh(now: now, maxAge: maxAge) else {
            // Read on every redraw, so say it once per stale spell.
            if !didLogStaleTrading212Valuation {
                didLogStaleTrading212Valuation = true
                Task {
                    await Logger.shared.info("Trading 212 broker valuation snapshot is stale; using local portfolio calculation fallback.")
                }
            }
            return nil
        }

        didLogStaleTrading212Valuation = false
        return snapshot
    }

    func startStaggeredRefresh() {
        // Delegate to RefreshService
        Task { @MainActor in
            refreshService?.startRefreshTimer()
        }
    }

    // MARK: - Settings Import

    /// Stops market refresh, Trading 212 and Folync syncs and scheduled
    /// backfills, and writes pending changes first, so nothing writes the old
    /// in-memory state over imported settings or data before Stockbar relaunches.
    func pauseBackgroundWorkForImport() async {
        isBackgroundWorkPausedForImport = true
        await flushPendingPersistence()
        refreshService?.stopRefreshTimer()
        trading212BrokerSyncTimer?.invalidate()
        trading212BrokerSyncTimer = nil
        trading212BrokerSyncTask?.cancel()
        trading212BrokerSyncTask = nil
        // A new generation makes in-flight Folync work stale.
        folyncRefreshGeneration = UUID()
        folyncRefreshTimer?.invalidate()
        folyncRefreshTimer = nil
        folyncRefreshTask?.cancel()
        folyncRefreshTask = nil
        folyncSupplementalRefreshTimer?.invalidate()
        folyncSupplementalRefreshTimer = nil
        folyncSupplementalRefreshTask?.cancel()
        folyncSupplementalRefreshTask = nil
        BackfillScheduler.shared.stop()
    }

    /// Restarts what `pauseBackgroundWorkForImport()` stopped, after an import
    /// failed and was rolled back.
    func resumeBackgroundWorkAfterFailedImport() async {
        isBackgroundWorkPausedForImport = false
        refreshService?.startRefreshTimer()
        if isFolyncEnabled {
            await restartFolyncPortfolioScheduler(runImmediately: false)
        }
        if !isFolyncPortfolioActive {
            restartTrading212LinkedSyncScheduler(runImmediately: false, keepBackoff: true)
        }
        if mayStartRuntimeSchedulers {
            BackfillScheduler.shared.start(dataModel: self)
        }
    }

    // MARK: - Trade Update Trigger
    
    /// Manually triggers a save of all trades.
    /// Use this when updating properties within a RealTimeTrade object (like units or cost),
    /// which changes the trade's content but not the `realTimeTrades` array.
    func triggerTradeUpdate() {
        guard !isFolyncPortfolioActive else { return }
        tradeContentDidChange.send()
        tradeUpdateTrigger.send()
    }

    func persistPortfolioAfterUserEdit(allowEmptyPortfolio: Bool = false) {
        guard !isFolyncPortfolioActive else { return }
        // Every save replaces the whole stored portfolio. Before the stored one has been read,
        // the list in memory is empty, so saving it would wipe the holdings on disk.
        guard hasCompletedInitialTradeLoad || !requiresInitialTradeLoad else {
            Task { await logger.debug("Skipping portfolio save until initial load completes") }
            return
        }
        ensureBenchmarkTracking()

        let validTrades = realTimeTrades.filter { trade in
            let hasSymbol = !trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUnits = trade.trade.position.unitSize > 0
            let hasPrice = !trade.trade.position.positionAvgCostString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasSymbol || hasUnits || hasPrice
        }

        let validPortfolioTrades = validTrades.filter { !isBenchmarkTrade($0) }
        saveTrades(validTrades, allowEmptyPortfolio: allowEmptyPortfolio)

        if !validPortfolioTrades.isEmpty || allowEmptyPortfolio {
            saveUserOrder(validPortfolioTrades)
            saveTradingInfo()
        }
    }
    
    private func ensureBenchmarkTracking() {
        var needsRefresh = false
        
        for symbol in SymbolMetadata.benchmarkSymbols {
            if !realTimeTrades.contains(where: { $0.trade.name == symbol }) {
                let benchmarkTrade = Trade(
                    name: symbol,
                    position: Position(unitSize: "0", positionAvgCost: "0"),
                    isWatchlistOnly: true,
                    showInMenuBar: false
                )
                let rt = RealTimeTrade(trade: benchmarkTrade, realTimeInfo: TradingInfo())
                realTimeTrades.append(rt)
                needsRefresh = true
            }
        }
        
        if needsRefresh {
            Task {
                await refreshAllTrades()
            }
        }
    }

    private let tradeUpdateTrigger = PassthroughSubject<Void, Never>()
    var tradeContentPublisher: AnyPublisher<Void, Never> {
        tradeContentDidChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    // MARK: - Private Methods

    /// The body of the 2-second debounced save. Also run directly on quit, so an
    /// edit made in the last two seconds is not lost.
    private func saveDebouncedTradeChanges() {
        hasPendingDebouncedTradeSave = false
        guard hasCompletedInitialTradeLoad else {
            Task { await logger.debug("Skipping trade save until initial load completes") }
            return
        }
        guard !isFolyncPortfolioActive else { return }

        let trades = realTimeTrades

        // Save trades with meaningful data (units > 0 OR price set OR symbol set)
        // This allows saving partial edits where user enters units/price but hasn't set symbol yet
        let validTrades = trades.filter { trade in
            let hasSymbol = !trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUnits = trade.trade.position.unitSize > 0
            let hasPrice = !trade.trade.position.positionAvgCostString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasSymbol || hasUnits || hasPrice
        }
        if !validTrades.isEmpty {
            let validPortfolioTrades = validTrades.filter { !isBenchmarkTrade($0) }
            saveTrades(validTrades)

            if !validPortfolioTrades.isEmpty {
                saveUserOrder(validPortfolioTrades)
                saveTradingInfo()
            }
        }
    }

    private func setupPublishers() {
        // Save after array changes and explicit content-edit triggers.
        Publishers.Merge(
            ObservationPublisher.values(self, \.realTimeTrades).map { _ in () },
            tradeUpdateTrigger
        )
        .handleEvents(receiveOutput: { [weak self] _ in self?.hasPendingDebouncedTradeSave = true })
        .debounce(for: .seconds(2.0), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.saveDebouncedTradeChanges()
        }
        .store(in: &cancellables)

        // Content changes: the array, or any trade's position or quote. One
        // observation covers every row and re-tracks when rows are replaced.
        ObservationPublisher.values { [weak self] in
            for trade in self?.realTimeTrades ?? [] {
                _ = trade.trade
                _ = trade.realTimeInfo
            }
        }
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            self?.tradeContentDidChange.send()
        }
        .store(in: &cancellables)
    }

    private func saveTrades(_ trades: [RealTimeTrade], allowEmptyPortfolio: Bool = false) {
        guard !isFolyncPortfolioActive else { return }
        guard !portfolioLoadFailed else {
            Task { await logger.warning("Skipped Core Data save: the stored portfolio failed to load and would be overwritten") }
            return
        }
        Task { await logger.debug("Saving \(trades.count) trades to Core Data") }

        // Filter on main actor to avoid crossing actor boundaries in detached task.
        let tradesToSave = trades.filter { !$0.trade.name.isEmpty && !isBenchmarkTrade($0) }
        let tradeModels = tradesToSave.map { $0.trade }

        guard !tradeModels.isEmpty || allowEmptyPortfolio else {
            Task { await logger.debug("Skipped Core Data save because only benchmark/internal rows were present") }
            return
        }
        
        // Background save, ordered after any earlier pending save: each save
        // replaces the whole stored portfolio, so an older list must never
        // finish after a newer one.
        let tradeDataService = tradeDataService
        let savedTradeCount = tradeModels.count
        enqueuePersistence { [logger] in
            do {
                // Save directly to Core Data
                try await tradeDataService.saveAllTrades(tradeModels)
                await logger.debug("Successfully saved \(savedTradeCount) trades to Core Data")
            } catch {
                await logger.error("Failed to save trades to Core Data: \(error.localizedDescription)")
            }
        }
    }

    /// Chains persistence work so saves complete in submission order.
    private func enqueuePersistence(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pendingPersistenceTask
        pendingPersistenceTask = Task.detached(priority: .utility) {
            await previous?.value
            await operation()
        }
    }

    /// Waits for queued background saves, e.g. before the app terminates.
    func flushPendingPersistence() async {
        if hasPendingDebouncedTradeSave {
            saveDebouncedTradeChanges()
        }
        while let task = pendingPersistenceTask {
            await task.value
            if pendingPersistenceTask == task {
                pendingPersistenceTask = nil
            }
        }
    }

    func replacePortfolioTrades(_ trades: [Trade], source: String, allowEmptyPortfolio: Bool = false) async throws {
        // While Folync is active the displayed rows are Folync's and the local
        // portfolio is set aside; a restore here would be undone on deactivation.
        guard !isFolyncPortfolioActive else { throw PortfolioRestoreError.folyncPortfolioActive }
        let portfolioTrades = trades
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }

        guard !portfolioTrades.isEmpty || allowEmptyPortfolio || trades.isEmpty else {
            throw PortfolioRestoreError.noRestorablePortfolioTrades
        }

        try await tradeDataService.saveAllTrades(portfolioTrades)
        if portfolioLoadFailed { aliasIdentityMigrationService.setAsideUnreadablePendingRecovery() }
        portfolioLoadFailed = false
        portfolioLoadFailureDetail = nil

        var existingInfo: [String: TradingInfo] = [:]
        for trade in realTimeTrades {
            existingInfo[trade.trade.name.uppercased()] = trade.realTimeInfo
        }
        let restoredTrades = portfolioTrades.map { trade in
            RealTimeTrade(
                trade: trade,
                realTimeInfo: existingInfo[trade.name.uppercased()] ?? TradingInfo()
            )
        }

        self.realTimeTrades = applyUserOrderToTrades(restoredTrades)
        saveUserOrder(self.realTimeTrades)
        saveTradingInfo()
        ensureBenchmarkTracking()

        await logger.info("Replaced portfolio with \(portfolioTrades.count) trades from \(source)")
        await refreshCriticalSymbols(reason: source)
    }

    private static func loadUserData(decoder: JSONDecoder) -> UserData {
        if let data = StockbarRuntimeStorage.userDefaults.data(forKey: "userData") {
            if let decodedUserData = try? decoder.decode(UserData.self, from: data) {
                // Apply any necessary data migrations after decoding
                var migratedUserData = decodedUserData
                // This migration was for Position.costCurrency
                // Note: Position doesn't have symbol, so we'll set default costCurrency
                migratedUserData.positions = migratedUserData.positions.map { position in
                    var newPosition = position
                    if newPosition.costCurrency == nil {
                        newPosition.costCurrency = "USD" // Default to USD, will be auto-detected when used
                    }
                    return newPosition
                }
                return migratedUserData
            }
        }
        return UserData(positions: [], settings: UserSettings())
    }
    
    private func saveUserData() {
        do {
            let data = try encoder.encode(userData)
            StockbarRuntimeStorage.userDefaults.set(data, forKey: "userData")
            Task { await logger.debug("Successfully saved user data") }
        } catch {
            Task { await logger.error("Failed to save user data: \(error.localizedDescription)") }
        }
    }
    
    // MARK: - Order Management
    
    /// Saves the current order of stocks for menu bar display
    private func saveUserOrder(_ trades: [RealTimeTrade]) {
        let symbolOrder = trades.filter { !isBenchmarkTrade($0) }.map { $0.trade.name }
        StockbarRuntimeStorage.userDefaults.set(symbolOrder, forKey: "stockDisplayOrder")
        Task { await logger.debug("💾 Saved stock display order: \(symbolOrder)") }
    }
    
    /// Loads the saved order of stocks
    private func loadUserOrder() -> [String] {
        return StockbarRuntimeStorage.userDefaults.stringArray(forKey: "stockDisplayOrder") ?? []
    }
    
    /// Applies the saved user order to a list of trades
    private func applyUserOrderToTrades(_ trades: [RealTimeTrade]) -> [RealTimeTrade] {
        let savedOrder = loadUserOrder()
        
        guard !savedOrder.isEmpty else {
            // No saved order, return trades as-is
            return trades
        }
        
        var orderedTrades: [RealTimeTrade] = []
        var remainingTrades = trades
        
        // First, add trades in the saved order
        for symbol in savedOrder {
            if let index = remainingTrades.firstIndex(where: { $0.trade.name == symbol }) {
                orderedTrades.append(remainingTrades.remove(at: index))
            }
        }
        
        // Then, add any new trades that weren't in the saved order (at the end)
        orderedTrades.append(contentsOf: remainingTrades)
        
        Task { await logger.debug("📋 Applied user order: saved=\(savedOrder.count), total=\(orderedTrades.count)") }
        return orderedTrades
    }

    /// Ensures that all loaded stocks have a non-nil currency assigned.
    /// This is crucial for older saved data where currency might not have been explicitly stored.
    private func normalizeLoadedStockCurrencies() {
        // Iterate through all stocks and ensure their currency is set if nil
        for i in 0..<userData.stocks.count {
            var stock = userData.stocks[i]
            if stock.currency == nil {
                // Set default currency if not specified (only for loaded data that might be old)
                stock.currency = SymbolMetadata.defaultCurrency(for: stock.symbol)
                userData.stocks[i] = stock // Update the stock in the array
                let symbol = stock.symbol
                let currency = stock.currency ?? "nil"
                Task { await logger.debug("Normalized currency for \(symbol) to \(currency) upon loading.") }
            }
        }
    }
    
    // MARK: - Emergency Recovery Functions Removed
    // Emergency recovery functions removed by user request
}

enum PortfolioRestoreError: LocalizedError {
    case noRestorablePortfolioTrades
    case folyncPortfolioActive

    var errorDescription: String? {
        switch self {
        case .noRestorablePortfolioTrades:
            return "The selected backup does not contain any portfolio stocks. It only contains internal benchmark rows."
        case .folyncPortfolioActive:
            return "Folync is providing the portfolio. Switch to the local portfolio in Settings → Connections before restoring a backup."
        }
    }
}

// MARK: - RealTimeTrade Extension

extension RealTimeTrade {
    /// Infers market state based on current time and symbol timezone
    private func inferMarketState(for symbol: String) -> String? {
        BrokerLinkedMarketDataRefreshPolicy.inferredMarketState(for: symbol)
    }

    @MainActor
    private func resolvePreviousCloseFromSnapshots(symbol: String, referenceDate: Date, cutoff: Double, epsilon: Double) -> Double? {
        let timeZone = TimeZone(identifier: SymbolMetadata.defaultTimezone(for: symbol)) ?? TimeZone.current
        var calendar = Calendar.current
        calendar.timeZone = timeZone

        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            return nil
        }

        let snapshots = HistoricalDataManager.shared.getPriceSnapshots(for: symbol, from: yesterdayStart, to: todayStart)
        guard let lastSnapshot = snapshots.last(where: { $0.timestamp < todayStart && $0.price.isFinite && $0.price > 0 }) else {
            return nil
        }

        if abs(lastSnapshot.price - cutoff) <= epsilon {
            return nil
        }

        return lastSnapshot.price
    }

    /// Updates the trade with new data from the network service
    /// Returns true if the update was successful (non-NaN data), false if it failed and old data was retained
    @MainActor
    func updateWithResult(_ result: StockFetchResult, retainOnFailure: Bool = true) -> Bool {
        let validator = DataValidationService.shared

        // Use separate prices for different purposes
        let regularPrice = result.regularMarketPrice  // For day calculations
        let displayPrice = result.displayPrice        // For market value and display
        let prevClose = result.regularMarketPreviousClose

        // Sanitize price data using validation service
        let (sanitizedRegularPrice, sanitizedPrevClose) = validator.sanitizeStockData(
            price: regularPrice,
            previousClose: prevClose
        )

        // Check if this is a failed fetch (NaN values or invalid prices)
        let isFetchFailure = sanitizedRegularPrice == nil || sanitizedPrevClose == nil
        var updatedInfo = self.realTimeInfo
        
        if isFetchFailure {
            Task { await Logger.shared.warning("Fetch failed for \(result.symbol) - regularPrice: \(regularPrice), prevClose: \(prevClose)") }

            if retainOnFailure {
                // Keep the existing price, previous close, currency and both timestamps. The price
                // shown is still the last one fetched, so "updated" must keep saying when that was;
                // stamping a failed attempt as fresh would present a stale price as current.
                Task { await Logger.shared.info("Retaining last successful data for \(result.symbol)") }

                updatedInfo.exchangeTimezoneName = result.exchangeTimezoneName ?? updatedInfo.exchangeTimezoneName
                updatedInfo.shortName = result.shortName ?? updatedInfo.shortName

                // Market state handling: if result provides a state, use it; otherwise infer from current time
                if let newMarketState = result.marketState?.rawValue {
                    updatedInfo.marketState = newMarketState
                } else {
                    // When FMP fallback is used (no market state), infer based on current time
                    updatedInfo.marketState = inferMarketState(for: self.trade.name)
                }

                // Also update pre/post market times if available
                if let preTime = result.preMarketTime {
                    updatedInfo.preMarketTime = preTime
                }
                if let postTime = result.postMarketTime {
                    updatedInfo.postMarketTime = postTime
                }

                self.realTimeInfo = updatedInfo
                return false // Indicate failure
            } else {
                // Old behavior - update with NaN values
                Task { await Logger.shared.warning("Updating \(result.symbol) with NaN values (retainOnFailure=false)") }
            }
        }

        let symbol = result.symbol
        let currency = SymbolMetadata.normalizeCurrency(result.currency) ?? SymbolMetadata.defaultCurrency(for: symbol)
        
        // IMPORTANT: Our Python script already converts pence to pounds for .L stocks
        // So we should NOT do any additional conversion here
        // Use sanitized values if validation passed, otherwise use originals
        let finalRegularPrice = sanitizedRegularPrice ?? regularPrice
        _ = displayPrice  // Display price not currently sanitized
        let finalPrevClose = sanitizedPrevClose ?? prevClose

        // Only update price data if fetch was successful or retainOnFailure is false
        if !isFetchFailure || !retainOnFailure {
            updatedInfo.currentPrice = finalRegularPrice  // Use regular market price for day calculations
            var resolvedPrevClose = finalPrevClose

            // UK symbols sometimes return previousClose == currentPrice; fall back to prior-day snapshot if available.
            if SymbolMetadata.isUKSymbol(symbol),
               finalRegularPrice.isFinite,
               finalRegularPrice > 0,
               resolvedPrevClose.isFinite,
               resolvedPrevClose > 0 {
                let epsilon = max(0.0001, finalRegularPrice * 0.0001)
                if abs(resolvedPrevClose - finalRegularPrice) <= epsilon {
                    if let fallbackPrev = resolvePreviousCloseFromSnapshots(symbol: symbol, referenceDate: Date(), cutoff: finalRegularPrice, epsilon: epsilon) {
                        resolvedPrevClose = fallbackPrev
                        Task { await Logger.shared.info("Resolved prev close from snapshots for \(symbol): \(fallbackPrev)") }
                    }
                }
            }

            updatedInfo.previousClose = resolvedPrevClose // Use the (potentially adjusted) prev close
            updatedInfo.prevClosePrice = resolvedPrevClose // Also set the field that StockStatusBar reads
            updatedInfo.currency = currency // Now always GBP for GBX/GBp or .L stocks that were converted
            
            // Update pre/post market data
            updatedInfo.preMarketPrice = result.preMarketPrice
            updatedInfo.preMarketChange = result.preMarketChange
            updatedInfo.preMarketChangePercent = result.preMarketChangePercent
            updatedInfo.preMarketTime = result.preMarketTime
            updatedInfo.postMarketPrice = result.postMarketPrice
            updatedInfo.postMarketChange = result.postMarketChange
            updatedInfo.postMarketChangePercent = result.postMarketChangePercent
            updatedInfo.postMarketTime = result.postMarketTime
        }
        
        // ALWAYS update timestamp, metadata, and market state - even if we retained old price data
        // lastUpdateTime reflects when we fetched/refreshed; regularMarketTime reflects exchange-reported time
        updatedInfo.lastUpdateTime = Int(Date().timeIntervalSince1970)
        updatedInfo.regularMarketTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970)
        // A provider that omits these (the FMP fallback does) must not replace
        // a known time zone with GMT or a known name with the ticker.
        if let zone = result.exchangeTimezoneName, !zone.isEmpty {
            updatedInfo.exchangeTimezoneName = zone
        } else if updatedInfo.exchangeTimezoneName.isEmpty {
            updatedInfo.exchangeTimezoneName = "GMT"
        }
        if let name = result.shortName, !name.isEmpty {
            updatedInfo.shortName = name
        } else if updatedInfo.shortName.isEmpty {
            updatedInfo.shortName = self.trade.name
        }

        // Market state handling: if result provides a state, use it; otherwise infer from current time
        if let newMarketState = result.marketState?.rawValue {
            updatedInfo.marketState = newMarketState
        } else {
            // When FMP fallback is used (no market state), infer based on current time
            updatedInfo.marketState = inferMarketState(for: self.trade.name)
        }

        let logger = Logger.shared // Already defined in DataModel, but ok for local scope too

        self.realTimeInfo = updatedInfo

        if isFetchFailure && retainOnFailure {
            Task { await logger.info("Retained old data for \(self.trade.name): Price \(updatedInfo.currentPrice) Currency: \(updatedInfo.currency ?? "N/A") (fetch failed)") }
        } else {
            Task { await logger.debug("Updated trade \(self.trade.name): Price \(updatedInfo.currentPrice) PrevClose: \(String(describing: updatedInfo.previousClose)) prevClosePrice: \(updatedInfo.prevClosePrice) Currency: \(updatedInfo.currency ?? "N/A") originalRegularPrice: \(regularPrice) originalDisplayPrice: \(displayPrice) originalPrevClose: \(prevClose) originalCurrency: \(result.currency ?? "nil")") }
        }

        return !isFetchFailure // Return true if successful, false if failed
    }
}
