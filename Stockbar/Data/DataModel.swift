// Stockbar/Stockbar/Data/DataModel.swift
// --- COMPLETELY REPLACED FILE ---

import Combine
import Foundation

extension String {
    func appendToFile(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let fileHandle = try FileHandle(forWritingTo: url)
            fileHandle.seekToEndOfFile()
            fileHandle.write(self.data(using: .utf8)!)
            fileHandle.closeFile()
        } else {
            try self.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
// Removed OSLog import to avoid name clashes with our custom Logger

/// Simple async lock used to serialize refresh operations so mutations
/// to `realTimeTrades` always occur on the main actor in isolation.
actor RefreshCoordinator {
    private var isRefreshing = false

    func withLock<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        while isRefreshing {
            await Task.yield()
        }

        isRefreshing = true
        defer { isRefreshing = false }

        return try await operation()
    }
}

@MainActor
class DataModel: ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"] // Keep as is

    // MARK: - Properties

    // --- SWITCHED SERVICE ---
    // Use the Python script-based service implementation
    private let networkService: NetworkService = PythonNetworkService()
    // ------------------------

    internal let currencyConverter: CurrencyConverter // Internal for UI access to exchange rate info
    private let decoder = JSONDecoder()           // Keep as is
    private let encoder = JSONEncoder()           // Keep as is
    private var cancellables = Set<AnyCancellable>()// Keep as is
    private let tradeContentDidChange = PassthroughSubject<Void, Never>()
    private var tradeContentCancellables = Set<AnyCancellable>()
    internal var historicalDataManager: HistoricalDataManager { HistoricalDataManager.shared }
    private let tradeDataService = TradeDataService()
    private let migrationService = DataMigrationService.shared
    private let refreshCoordinator = RefreshCoordinator()

    // MARK: - Service Layer
    internal let cacheCoordinator = CacheCoordinator()  // Internal for UI access to suspension state
    private var refreshService: RefreshService!
    private var portfolioCalculationService: PortfolioCalculationService!
    private var historicalDataCoordinator: HistoricalDataCoordinator!
    private let importExportManager = ImportExportManager()
    private let chartAnnotationService = ChartAnnotationService.shared
    
    @Published var realTimeTrades: [RealTimeTrade] = [] // Keep as is
    @Published var showColorCoding: Bool = UserDefaults.standard.bool(forKey: "showColorCoding") { // Keep as is
        didSet {
            UserDefaults.standard.set(showColorCoding, forKey: "showColorCoding")
        }
    }
    @Published var preferredCurrency: String = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "USD" { // Keep as is
        didSet {
            UserDefaults.standard.set(preferredCurrency, forKey: "preferredCurrency")
        }
    }
    @Published var showMarketIndicators: Bool = UserDefaults.standard.bool(forKey: "showMarketIndicators") {
        didSet {
            UserDefaults.standard.set(showMarketIndicators, forKey: "showMarketIndicators")
        }
    }

    // MARK: - Menu Bar Display Settings (UI Enhancement v2.3.0)
    @Published var menuBarDisplaySettings: MenuBarDisplaySettings = MenuBarDisplaySettings.load() {
        didSet {
            menuBarDisplaySettings.save()
        }
    }

    @Published var portfolioMenuBarDisplaySettings: PortfolioMenuBarDisplaySettings = {
        let defaultCurrency = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "USD"
        return PortfolioMenuBarDisplaySettings.load(defaultCurrency: defaultCurrency)
    }() {
        didSet {
            portfolioMenuBarDisplaySettings.save()
        }
    }

    @Published var hideAllMenuBarItems: Bool = UserDefaults.standard.bool(forKey: "hideAllMenuBarItems") {
        didSet {
            UserDefaults.standard.set(hideAllMenuBarItems, forKey: "hideAllMenuBarItems")
        }
    }

    private let logger = Logger.shared

    @Published var refreshInterval: TimeInterval = UserDefaults.standard.object(forKey: "refreshInterval") as? TimeInterval ?? 300 { // 5 minutes default
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            // Update RefreshService interval when changed
            Task { @MainActor in
                refreshService?.refreshInterval = refreshInterval
            }
        }
    }
    
    // MARK: - Historical Data Backfill State
    private var hasRunStartupBackfill = false // Prevent duplicate startup tasks
    
    // Cache management now handled by CacheCoordinator service
    
    // MARK: - Memory Management
    private var memoryOptimizer: MemoryOptimizedDataModel?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastMemoryWarning = Date.distantPast
    private let maxTradesInMemory = 100 // Limit trades kept in memory
    private var isMemoryOptimizationEnabled = true
    private var hasCompletedInitialTradeLoad = false

    @Published var userData: UserData {
        didSet {
            // Save data whenever it changes
            saveUserData()
        }
    }

    // MARK: - Initialization

    init(
        currencyConverter: CurrencyConverter = CurrencyConverter(),
        startRuntimeServices: Bool = true
    ) {
        // Ensure network service uses the correct implementation
        // self.networkService = PythonNetworkService() // Already done in property declaration

        self.currencyConverter = currencyConverter

        // Initialize userData first without triggering persistence during construction.
        _userData = Published(initialValue: Self.loadUserData(decoder: decoder))

        // Initialize realTimeTrades first - will be loaded async after init
        self.realTimeTrades = []
        
        // Note: All data loading now happens asynchronously via loadTradesAsync()
        // including migration of cost currency and trading info currency
        
        if self.realTimeTrades.isEmpty {
            Task { await logger.warning("No saved trades found, starting with empty list.") }
        }

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
                refreshCoordinator: refreshCoordinator,
                refreshInterval: refreshInterval
            )
            self.refreshService.setDataModel(self)
            
            self.portfolioCalculationService = PortfolioCalculationService(currencyConverter: currencyConverter)
            self.historicalDataCoordinator = HistoricalDataCoordinator(
                networkService: networkService,
                historicalDataManager: historicalDataManager
            )

            // Once core services are available, make sure any stale symbols are refreshed.
            Task { await self.refreshCriticalSymbols(reason: "service-ready") }
        }

        // Load trades asynchronously
        Task {
            await loadTradesAsync()

            // Emergency recovery removed by user request

            await MainActor.run {
                self.startStaggeredRefresh()
            }
        }

        // Apply normalization to loaded stock currency data to ensure consistency
        normalizeLoadedStockCurrencies()

        // Clear inconsistent historical data (one-time fix for calculation method changes)
        Task { await historicalDataManager.clearInconsistentData() }

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
            let symbols = realTimeTrades.map { $0.trade.name }
            await historicalDataCoordinator.performStartupBackfillIfNeeded(symbols: symbols)
        }

        // INTELLIGENT BACKFILL SCHEDULER: Start automatic gap detection and scheduled backfills
        Task { @MainActor in
            BackfillScheduler.shared.start(dataModel: self)
        }
    }

     // Helper function for default trades if needed
    private func defaultTrades() -> [Trade] {
        // Return an empty array or some default sample trades
        // Example: return [Trade(name: "AAPL", ...)]
        Task { await logger.warning("No saved trades found, starting with empty list.") }
        return []
    }
    
    // MARK: - Memory Management Methods
    
    private func setupMemoryManagement() {
        guard isMemoryOptimizationEnabled else { return }
        
        memoryOptimizer = MemoryOptimizedDataModel()
        setupMemoryPressureMonitoring()
        
        Task { await logger.info("Memory optimization enabled with limit of \(maxTradesInMemory) trades") }
    }
    
    private func setupMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        memoryPressureSource?.setEventHandler { [weak self] in
            Task {
                await self?.handleMemoryPressure()
            }
        }
        
        memoryPressureSource?.resume()
    }
    
    private func handleMemoryPressure() async {
        await logger.warning("⚠️ Memory pressure detected in DataModel")
        
        let now = Date()
        guard now.timeIntervalSince(lastMemoryWarning) > 30 else {
            await logger.debug("Skipping memory cleanup - too recent")
            return
        }
        
        lastMemoryWarning = now
        
        // Perform memory optimization
        await performMemoryOptimization()
    }
    
    private func performMemoryOptimization() async {
        await logger.info("🧹 Performing DataModel memory optimization")
        
        // Limit realTimeTrades array size
        await MainActor.run {
            if realTimeTrades.count > maxTradesInMemory {
                let excess = realTimeTrades.count - maxTradesInMemory
                realTimeTrades.removeFirst(excess)
                Task { await logger.info("Removed \(excess) old trades from memory") }
            }
        }
        
        // Clear old cache entries (delegated to CacheCoordinator)
        await cacheCoordinator.clearOldCacheEntries()

        // Notify historical data manager to clean up
        await historicalDataManager.clearInconsistentData()
        
        await logger.info("Memory optimization completed")
    }
    
    deinit {
        memoryPressureSource?.cancel()
    }
    
    // MARK: - Migration Methods
    
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
    private func loadTradesAsync() async {
        await logger.info("🔄 Loading trades from Core Data...")
        
        do {
            // First, trigger migration if needed
            try await migrationService.performFullMigration()
            
            // Load trades from Core Data
            await logger.info("📊 Loading trades from Core Data")
            let trades = try await recoverLegacyUserTradesIfNeeded(
                afterLoading: try await tradeDataService.loadAllTrades()
            )
            
            // Create RealTimeTrade objects
            let realTimeTrades = trades.map { RealTimeTrade(trade: $0, realTimeInfo: TradingInfo()) }
            
            // Load trading info for each trade
            await loadTradingInfoAsync(for: realTimeTrades)
            
            // Update on main thread
            await MainActor.run {
                // Apply saved order to the loaded trades
                self.realTimeTrades = self.applyUserOrderToTrades(realTimeTrades)
                Task { await logger.info("✅ Loaded \(realTimeTrades.count) trades successfully from Core Data with user order") }
                Task { await logger.info("📋 DIAGNOSTIC: Trades loaded: \(self.realTimeTrades.map { $0.trade.name }.joined(separator: ", "))") }

                // Apply migrations after loading
                self.removePersistedBenchmarks()
                self.migrateCostCurrencyData()
                self.migrateRealTimeTradesCurrency()
                
                self.ensureBenchmarkTracking()
                self.hasCompletedInitialTradeLoad = true
            }

            // Kick off an immediate refresh for anything that isn't fresh yet
            await refreshCriticalSymbols(reason: "initial-load")
            
        } catch {
            await logger.error("❌ Failed to load trades from Core Data: \(error)")
            
            // Initialize with empty trades if Core Data fails
            await MainActor.run {
                self.realTimeTrades = []
                self.hasCompletedInitialTradeLoad = true
                self.ensureBenchmarkTracking()
                Task { await logger.warning("⚠️ Initialized with empty trades due to Core Data failure") }
            }
        }
    }

    private func recoverLegacyUserTradesIfNeeded(afterLoading trades: [Trade]) async throws -> [Trade] {
        let portfolioTrades = trades.filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }
        guard portfolioTrades.isEmpty else {
            return portfolioTrades
        }

        guard let legacyData = UserDefaults.standard.data(forKey: "usertrades") else {
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
        return legacyTrades
    }
    
    /// Load trading info asynchronously from Core Data
    private func loadTradingInfoAsync(for trades: [RealTimeTrade]) async {
        do {
            await logger.info("📊 Loading trading info from Core Data")
            let tradingInfoDict = try await tradeDataService.loadAllTradingInfo()
            
            // Apply trading info to trades
            for trade in trades {
                if let savedInfo = tradingInfoDict[trade.trade.name] {
                    trade.realTimeInfo = savedInfo
                    await logger.debug("Restored trading info for \(trade.trade.name) from Core Data")
                }
            }
        } catch {
            await logger.error("❌ Failed to load trading info from Core Data: \(error)")
        }
    }
    
    
    internal func saveTradingInfo() {
        let tradingInfoDict = Dictionary(uniqueKeysWithValues: realTimeTrades
            .filter { !isBenchmarkTrade($0) }
            .map { ($0.trade.name, $0.realTimeInfo) })
        
        // Move saving to background queue to prevent UI blocking
        Task.detached(priority: .utility) { [weak self, logger] in
            guard let self = self else { return }
            
            do {
                // Save directly to Core Data
                try await self.tradeDataService.saveAllTradingInfo(tradingInfoDict)
                await logger.debug("Saved trading info for \(tradingInfoDict.count) symbols to Core Data")
            } catch {
                await logger.error("Failed to save trading info to Core Data: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public Methods

    /// Checks for missing historical data and triggers backfill if needed (legacy 1-month check) - delegates to HistoricalDataCoordinator
    @MainActor
    public func checkAndBackfillHistoricalData() async {
        let symbols = realTimeTrades.map { $0.trade.name }
        await historicalDataCoordinator.checkAndBackfillHistoricalData(symbols: symbols)
    }
    
    /// Comprehensive 5-year historical data coverage check and automatic backfill - delegates to HistoricalDataCoordinator
    @MainActor
    public func checkAndBackfill5YearHistoricalData() async {
        let symbols = realTimeTrades.map { $0.trade.name }
        await historicalDataCoordinator.checkAndBackfill5YearHistoricalData(symbols: symbols)
        
        // FIX: Trigger retroactive calculation after backfill
        await logger.info("🔄 AUTO: Triggering retroactive portfolio calculation after 5-year backfill")
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: true)
    }
    
    /// Backfills historical data for specified symbols in chunks to avoid hanging - delegates to HistoricalDataCoordinator
    public func backfillHistoricalData(for symbols: [String]) async {
        await historicalDataCoordinator.backfillHistoricalData(for: symbols)
        
        // FIX: Trigger retroactive calculation after backfill
        await logger.info("🔄 AUTO: Triggering retroactive portfolio calculation after backfill")
        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: true)
    }
    
    
    /// Adds historical snapshots to the data manager
    @MainActor
    private func addHistoricalSnapshots(_ snapshots: [PriceSnapshot], for symbol: String) async {
        historicalDataManager.addImportedSnapshots(snapshots, for: symbol)
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
    
    /// Triggers comprehensive 5-year portfolio value calculation in monthly chunks
    public func calculate5YearPortfolioValues() async {
        await logger.info("🚀 MANUAL TRIGGER: Starting 5-year portfolio value calculation")
        await historicalDataManager.calculate5YearHistoricalPortfolioValues(using: self)
        await logger.info("🏁 MANUAL TRIGGER: Completed 5-year portfolio value calculation")
    }
    
    /// Checks if portfolio value calculation is needed and triggers it automatically
    private func checkAndCalculatePortfolioValues() async {
        await logger.info("🔍 STARTUP: Checking if portfolio value calculation is needed")
        
        // Check if we have sufficient historical price data but no portfolio value data
        let totalPriceSnapshots = await historicalDataManager.priceSnapshots.values.map { $0.count }.reduce(0, +)
        let portfolioValueCount = await historicalDataManager.cachedHistoricalPortfolioValues.count
        
        await logger.info("🔍 STARTUP: Found \(totalPriceSnapshots) price snapshots and \(portfolioValueCount) portfolio value points")
        
        // If we have lots of price data but no portfolio values, trigger calculation
        if totalPriceSnapshots > 100 && portfolioValueCount < 50 {
            await logger.info("🚀 STARTUP: Sufficient price data available, triggering automatic 5-year portfolio value calculation")
            await historicalDataManager.calculate5YearHistoricalPortfolioValues(using: self)
            await logger.info("🏁 STARTUP: Automatic portfolio value calculation completed")
        } else {
            await logger.info("ℹ️ STARTUP: Portfolio value calculation not needed - sufficient data already exists")
        }
    }
    
    /// Tests the API connection with a simple request
    func testAPIConnection() async throws -> Bool {
        await logger.info("Testing API connection (default AAPL fetch)")
        
        do {
            // Test with a simple quote request for Apple stock
            let result = try await networkService.fetchQuote(for: "AAPL")
            
            // Check if we got valid data back
            let isValid = !result.regularMarketPrice.isNaN && 
                         !result.regularMarketPreviousClose.isNaN && 
                         result.regularMarketPrice > 0
            
            if isValid {
                await logger.info("API test successful - received valid data for AAPL")
            } else {
                await logger.warning("API test returned invalid data - price: \(result.regularMarketPrice)")
            }
            
            return isValid
        } catch {
            await logger.error("API test failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Verifies a specific API key for a service
    func verifyAPIKey(service: String) async throws -> Bool {
        await logger.info("Verifying API key for service: \(service)")
        return try await networkService.verifyAPIKey(service: service)
    }
    
    /// Clears bad historical data for specific symbols
    @MainActor
    public func clearHistoricalDataForSymbol(_ symbol: String) async {
        historicalDataManager.clearDataForSymbol(symbol)
        await logger.info("Cleared bad historical data for \(symbol)")
    }

    /// Clears bad historical data for multiple symbols
    @MainActor
    public func clearHistoricalDataForSymbols(_ symbols: [String]) async {
        historicalDataManager.clearDataForSymbols(symbols)
        await logger.info("Cleared bad historical data for \(symbols.count) symbols")
    }
    
    /// Manually triggers retroactive portfolio calculation
    public func triggerRetroactivePortfolioCalculation(force: Bool = false) {
        Task {
            await logger.info("🔄 MANUAL: Starting retroactive portfolio calculation (force: \(force))")
            await historicalDataManager.calculateRetroactivePortfolioHistory(using: self, force: force)
            await logger.info("🔄 MANUAL: Retroactive portfolio calculation completed")
        }
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

    /// Triggers an immediate refresh for the provided symbols, bypassing the
    /// staggered rotation. Symbols are matched case-insensitively against the
    /// current portfolio.
    func refreshSymbolsImmediately(_ symbols: [String], reason: String) async {
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

        await performRefreshAllTrades(limitedTo: resolvedSymbols)
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
    private func performRefreshAllTrades(limitedTo symbols: [String]? = nil) async {
        guard let refreshService else {
            await Logger.shared.warning("performRefreshAllTrades called before refreshService initialized")
            return
        }

        await refreshService.performRefreshAllTrades(limitedTo: symbols)
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
        guard let service = portfolioCalculationService else {
            // Fallback if service not initialized yet
            return (0.0, preferredCurrency)
        }
        return service.calculateNetGains(trades: realTimeTrades, preferredCurrency: preferredCurrency)
    }

    /// Calculates the total portfolio value (market value) in the preferred currency - delegates to PortfolioCalculationService
    func calculateNetValue() -> (amount: Double, currency: String) {
        guard let service = portfolioCalculationService else {
            // Fallback if service not initialized yet
            return (0.0, preferredCurrency)
        }
        return service.calculateNetValue(trades: realTimeTrades, preferredCurrency: preferredCurrency)
    }

    /// Calculates the display-aware portfolio summary used by menu bar portfolio surfaces.
    func calculateDisplayPortfolioSummary(preferredCurrency overrideCurrency: String? = nil) -> DisplayPortfolioSummary {
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
            preferredCurrency: summaryCurrency
        )
    }

    func startStaggeredRefresh() {
        // Delegate to RefreshService
        Task { @MainActor in
            refreshService?.startRefreshTimer()
        }
    }

    func stopStaggeredRefresh() {
        // Delegate to RefreshService
        Task { @MainActor in
            refreshService?.stopRefreshTimer()
        }
    }

    // MARK: - Trade Update Trigger
    
    /// Manually triggers a save of all trades.
    /// Use this when updating properties within a RealTimeTrade object (like units or cost)
    /// which doesn't automatically trigger the @Published realTimeTrades publisher.
    func triggerTradeUpdate() {
        tradeContentDidChange.send()
        tradeUpdateTrigger.send()
    }

    func persistPortfolioAfterUserEdit(allowEmptyPortfolio: Bool = false) {
        objectWillChange.send()
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

    // Keep setupPublishers and saveTrades as they are
    private func setupPublishers() {
        // Merge updates from $realTimeTrades (array changes) and manual triggers (content changes)
        // Reduced debounce to 2.0 seconds for faster saving
        Publishers.Merge(
            $realTimeTrades.map { _ in () },
            tradeUpdateTrigger
        )
        .debounce(for: .seconds(2.0), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            guard let self = self else { return }
            guard self.hasCompletedInitialTradeLoad else {
                Task { await self.logger.debug("Skipping trade save until initial load completes") }
                return
            }

            let trades = self.realTimeTrades
            
            // Save trades with meaningful data (units > 0 OR price set OR symbol set)
            // This allows saving partial edits where user enters units/price but hasn't set symbol yet
            let validTrades = trades.filter { trade in
                let hasSymbol = !trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasUnits = trade.trade.position.unitSize > 0
                let hasPrice = !trade.trade.position.positionAvgCostString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return hasSymbol || hasUnits || hasPrice
            }
            if !validTrades.isEmpty {
                let validPortfolioTrades = validTrades.filter { !self.isBenchmarkTrade($0) }
                self.saveTrades(validTrades)

                if !validPortfolioTrades.isEmpty {
                    self.saveUserOrder(validPortfolioTrades)
                    self.saveTradingInfo()
                }

                self.objectWillChange.send()
            }
        }
        .store(in: &cancellables)

        $realTimeTrades
            .receive(on: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                self.bindTradeContentObservers(for: trades)
                self.tradeContentDidChange.send()
            }
            .store(in: &cancellables)
    }

    private func bindTradeContentObservers(for trades: [RealTimeTrade]) {
        tradeContentCancellables.removeAll()
        for trade in trades {
            trade.objectWillChange
                .sink { [weak self] _ in
                    self?.tradeContentDidChange.send()
                }
                .store(in: &tradeContentCancellables)
        }
    }

    private func saveTrades(_ trades: [RealTimeTrade], allowEmptyPortfolio: Bool = false) {
        Task { await logger.debug("Saving \(trades.count) trades to Core Data") }

        // Filter on main actor to avoid crossing actor boundaries in detached task.
        let tradesToSave = trades.filter { !$0.trade.name.isEmpty && !isBenchmarkTrade($0) }
        let tradeModels = tradesToSave.map { $0.trade }

        guard !tradeModels.isEmpty || allowEmptyPortfolio else {
            Task { await logger.warning("Skipped Core Data save because only benchmark/internal rows were present") }
            return
        }
        
        // Move saving to background queue to prevent UI blocking
        let tradeDataService = tradeDataService
        let savedTradeCount = tradeModels.count
        Task.detached(priority: .utility) { [logger, tradeDataService, tradeModels, savedTradeCount] in
            do {
                // Save directly to Core Data
                try await tradeDataService.saveAllTrades(tradeModels)
                await logger.debug("Successfully saved \(savedTradeCount) trades to Core Data")
            } catch {
                await logger.error("Failed to save trades to Core Data: \(error.localizedDescription)")
            }
        }
    }

    func replacePortfolioTrades(_ trades: [Trade], source: String, allowEmptyPortfolio: Bool = false) async throws {
        let portfolioTrades = trades
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !SymbolMetadata.isBenchmarkSymbol($0.name) }

        guard !portfolioTrades.isEmpty || allowEmptyPortfolio || trades.isEmpty else {
            throw PortfolioRestoreError.noRestorablePortfolioTrades
        }

        try await tradeDataService.saveAllTrades(portfolioTrades)

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
        if let data = UserDefaults.standard.data(forKey: "userData") {
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
            UserDefaults.standard.set(data, forKey: "userData")
            Task { await logger.debug("Successfully saved user data") }
        } catch {
            Task { await logger.error("Failed to save user data: \(error.localizedDescription)") }
        }
    }
    
    // MARK: - Order Management
    
    /// Saves the current order of stocks for menu bar display
    private func saveUserOrder(_ trades: [RealTimeTrade]) {
        let symbolOrder = trades.filter { !isBenchmarkTrade($0) }.map { $0.trade.name }
        UserDefaults.standard.set(symbolOrder, forKey: "stockDisplayOrder")
        Task { await logger.debug("💾 Saved stock display order: \(symbolOrder)") }
    }
    
    /// Loads the saved order of stocks
    private func loadUserOrder() -> [String] {
        return UserDefaults.standard.stringArray(forKey: "stockDisplayOrder") ?? []
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

    // MARK: - Portfolio Export/Import
    
    /// Exports current portfolio to JSON format
    func exportPortfolio() async -> String? {
        return await importExportManager.exportPortfolio(trades: realTimeTrades)
    }
    
    /// Imports portfolio from JSON string, optionally replacing current portfolio
    func importPortfolio(from jsonString: String, replaceExisting: Bool = false) async -> ImportResult {
        // Delegate to ImportExportManager
        let (result, newTrades) = await importExportManager.importPortfolio(
            from: jsonString,
            currentTrades: realTimeTrades,
            replaceExisting: replaceExisting
        )
        
        if let trades = newTrades {
            let portfolioTrades = trades.filter { !isBenchmarkTrade($0) }
            await MainActor.run {
                self.realTimeTrades = portfolioTrades
                self.persistPortfolioAfterUserEdit(allowEmptyPortfolio: replaceExisting)
            }
            
            // Trigger refresh for the new trades
            await refreshAllTrades()
        }
        
        return result
    }
}

enum PortfolioRestoreError: LocalizedError {
    case noRestorablePortfolioTrades

    var errorDescription: String? {
        switch self {
        case .noRestorablePortfolioTrades:
            return "The selected backup does not contain any portfolio stocks. It only contains internal benchmark rows."
        }
    }
}

// MARK: - RealTimeTrade Extension

extension RealTimeTrade {
    /// Infers market state based on current time and symbol timezone
    private func inferMarketState(for symbol: String) -> String? {
        let now = Date()
        let calendar = Calendar.current

        // Determine timezone based on symbol
        let timeZone: TimeZone
        timeZone = TimeZone(identifier: SymbolMetadata.defaultTimezone(for: symbol)) ?? TimeZone.current

        let components = calendar.dateComponents(in: timeZone, from: now)
        let hour = components.hour ?? 12
        let minute = components.minute ?? 0
        let weekday = components.weekday ?? 1 // 1 = Sunday, 7 = Saturday

        // Check if weekend
        if weekday == 1 || weekday == 7 {
            return "CLOSED"
        }

        if SymbolMetadata.isUKSymbol(symbol) {
            // LSE hours (London time)
            // Pre-market: 7:00-8:00
            // Regular: 8:00-16:30
            // Post-market: 16:30-17:30
            // Closed: 17:30-7:00
            if hour >= 7 && hour < 8 {
                return "PRE"
            } else if hour >= 8 && (hour < 16 || (hour == 16 && minute < 30)) {
                return "REGULAR"
            } else if (hour == 16 && minute >= 30) || (hour == 17 && minute < 30) {
                return "POST"
            } else {
                return "CLOSED"
            }
        } else {
            // US market hours (Eastern time)
            // Pre-market: 4:00-9:30
            // Regular: 9:30-16:00
            // Post-market: 16:00-20:00
            // Closed: 20:00-4:00
            if hour >= 4 && (hour < 9 || (hour == 9 && minute < 30)) {
                return "PRE"
            } else if (hour == 9 && minute >= 30) || (hour >= 10 && hour < 16) {
                return "REGULAR"
            } else if hour >= 16 && hour < 20 {
                return "POST"
            } else {
                return "CLOSED"
            }
        }
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
                // Don't update the price data, but DO update the timestamp to show when we last tried
                // Keep existing currentPrice, previousClose, prevClosePrice, currency
                Task { await Logger.shared.info("Retaining last successful data for \(result.symbol)") }

                // CRITICAL: Update timestamp and metadata even on failure so UI shows fresh "last updated" time
                updatedInfo.lastUpdateTime = Int(Date().timeIntervalSince1970)
                updatedInfo.regularMarketTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970)
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
        let _ = displayPrice  // Display price not currently sanitized
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
        updatedInfo.exchangeTimezoneName = result.exchangeTimezoneName ?? "GMT"
        updatedInfo.shortName = result.shortName ?? self.trade.name

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
            Task { await logger.info("Updated trade \(self.trade.name): Price \(updatedInfo.currentPrice) PrevClose: \(String(describing: updatedInfo.previousClose)) prevClosePrice: \(updatedInfo.prevClosePrice) Currency: \(updatedInfo.currency ?? "N/A") originalRegularPrice: \(regularPrice) originalDisplayPrice: \(displayPrice) originalPrevClose: \(prevClose) originalCurrency: \(result.currency ?? "nil")") }
        }

        return !isFetchFailure // Return true if successful, false if failed
    }
}
