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

class DataModel: ObservableObject {
    static let supportedCurrencies = ["USD", "GBP", "EUR", "JPY", "CAD", "AUD"] // Keep as is

    // MARK: - Properties

    // --- SWITCHED SERVICE ---
    // Use the Python script-based service implementation
    private let networkService: NetworkService = PythonNetworkService()
    // ------------------------

    private let currencyConverter: CurrencyConverter // Keep as is
    private let decoder = JSONDecoder()           // Keep as is
    private let encoder = JSONEncoder()           // Keep as is
    private var cancellables = Set<AnyCancellable>()// Keep as is
    public let historicalDataManager = HistoricalDataManager.shared
    private let tradeDataService = TradeDataService()
    private let migrationService = DataMigrationService.shared

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

    private let logger = Logger.shared

    private var refreshTimer: Timer?
    private var currentSymbolIndex = 0
    var refreshInterval: TimeInterval = 900 // 15 minutes in seconds (changed from 5 minutes)
    
    // MARK: - Historical Data Backfill State
    private var isRunningComprehensiveCheck = false
    private var isRunningStandardCheck = false
    private var lastComprehensiveCheckTime: Date = Date.distantPast
    private let comprehensiveCheckCooldown: TimeInterval = 3600 * 6 // 6 hours minimum between comprehensive checks
    
    // MARK: - Caching Properties
    private var lastSuccessfulFetch: [String: Date] = [:] // Track last successful fetch time per symbol
    private var lastFailedFetch: [String: Date] = [:] // Track last failed fetch time per symbol
    var cacheInterval: TimeInterval = 900 // 15 minutes cache duration for successful fetches
    private let retryInterval: TimeInterval = 300 // 5 minutes retry interval for failed fetches
    private let maxCacheAge: TimeInterval = 3600 // 1 hour max cache age before forcing refresh

    @Published var userData: UserData {
        didSet {
            // Save data whenever it changes
            saveUserData()
        }
    }

    // MARK: - Initialization

    init(currencyConverter: CurrencyConverter = CurrencyConverter()) {
        // Ensure network service uses the correct implementation
        // self.networkService = PythonNetworkService() // Already done in property declaration

        self.currencyConverter = currencyConverter

        // Initialize userData first
        _userData = Published(initialValue: UserData(positions: [], settings: UserSettings()))

        // Initialize realTimeTrades first - will be loaded async after init
        self.realTimeTrades = []
        
        // Load user data after userData is initialized
        self.userData = loadUserData()
        
        // Note: All data loading now happens asynchronously via loadTradesAsync()
        // including migration of cost currency and trading info currency
        
        if self.realTimeTrades.isEmpty {
            logger.warning("No saved trades found, starting with empty list.")
        }

        setupPublishers() // Keep as is
        logger.info("DataModel initialized, loading trades asynchronously...")
        
        // Load trades asynchronously
        Task {
            await loadTradesAsync()
            await MainActor.run {
                self.startStaggeredRefresh()
            }
        }

        // Apply normalization to loaded stock currency data to ensure consistency
        normalizeLoadedStockCurrencies()
        
        // Clear inconsistent historical data (one-time fix for calculation method changes)
        historicalDataManager.clearInconsistentData()
        
        // NEW: Start enhanced portfolio calculation in background after app startup
        Task {
            // Wait 60 seconds after app startup to avoid interfering with initial data loading
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            
            // Check if we need to calculate retroactive portfolio history
            logger.info("🔄 STARTUP: Checking if retroactive portfolio calculation is needed")
            await historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
        }
    }

     // Helper function for default trades if needed
    private func defaultTrades() -> [Trade] {
        // Return an empty array or some default sample trades
        // Example: return [Trade(name: "AAPL", ...)]
        logger.warning("No saved trades found, starting with empty list.")
        return []
    }
    
    // MARK: - Migration Methods
    
    private func migrateCostCurrencyData() {
        var needsSave = false
        
        for trade in realTimeTrades {
            if trade.trade.position.costCurrency == nil {
                // Auto-detect currency based on symbol
                let detectedCurrency = trade.trade.name.uppercased().hasSuffix(".L") ? "GBX" : "USD"
                trade.trade.position.costCurrency = detectedCurrency
                needsSave = true
                logger.info("Migrated \(trade.trade.name) to use \(detectedCurrency) as cost currency")
            }
        }
        
        if needsSave {
            saveTrades(realTimeTrades)
            logger.info("Migration complete - saved updated trade data with cost currencies")
        }
    }
    
    private func migrateRealTimeTradesCurrency() {
        var needsSave = false
        
        for trade in realTimeTrades {
            if trade.realTimeInfo.currency == nil {
                // Auto-detect currency based on symbol
                let detectedCurrency = trade.trade.name.uppercased().hasSuffix(".L") ? "GBP" : "USD"
                trade.realTimeInfo.currency = detectedCurrency
                needsSave = true
                logger.info("Migrated real-time info for \(trade.trade.name) to use \(detectedCurrency) currency")
            }
        }
        
        if needsSave {
            saveTradingInfo()
            logger.info("Migration complete - saved updated trading info with currencies")
        }
    }
    
    // MARK: - Core Data Aware Persistence Methods
    
    /// Load trades asynchronously from Core Data
    private func loadTradesAsync() async {
        logger.info("🔄 Loading trades from Core Data...")
        
        do {
            // First, trigger migration if needed
            try await migrationService.performFullMigration()
            
            // Load trades from Core Data
            logger.info("📊 Loading trades from Core Data")
            let trades = try await tradeDataService.loadAllTrades()
            
            // Create RealTimeTrade objects
            let realTimeTrades = trades.map { RealTimeTrade(trade: $0, realTimeInfo: TradingInfo()) }
            
            // Load trading info for each trade
            await loadTradingInfoAsync(for: realTimeTrades)
            
            // Update on main thread
            await MainActor.run {
                self.realTimeTrades = realTimeTrades
                logger.info("✅ Loaded \(realTimeTrades.count) trades successfully from Core Data")
                
                // Apply migrations after loading
                self.migrateCostCurrencyData()
                self.migrateRealTimeTradesCurrency()
            }
            
        } catch {
            logger.error("❌ Failed to load trades from Core Data: \(error)")
            
            // Initialize with empty trades if Core Data fails
            await MainActor.run {
                self.realTimeTrades = []
                logger.warning("⚠️ Initialized with empty trades due to Core Data failure")
            }
        }
    }
    
    /// Load trading info asynchronously from Core Data
    private func loadTradingInfoAsync(for trades: [RealTimeTrade]) async {
        do {
            logger.info("📊 Loading trading info from Core Data")
            let tradingInfoDict = try await tradeDataService.loadAllTradingInfo()
            
            // Apply trading info to trades
            for trade in trades {
                if let savedInfo = tradingInfoDict[trade.trade.name] {
                    trade.realTimeInfo = savedInfo
                    logger.debug("Restored trading info for \(trade.trade.name) from Core Data")
                }
            }
        } catch {
            logger.error("❌ Failed to load trading info from Core Data: \(error)")
        }
    }
    
    
    private func saveTradingInfo() {
        let tradingInfoDict = Dictionary(uniqueKeysWithValues: realTimeTrades.map { ($0.trade.name, $0.realTimeInfo) })
        
        // Move saving to background queue to prevent UI blocking
        Task.detached(priority: .utility) { [weak self, logger] in
            guard let self = self else { return }
            
            do {
                // Save directly to Core Data
                try await self.tradeDataService.saveAllTradingInfo(tradingInfoDict)
                logger.debug("Saved trading info for \(tradingInfoDict.count) symbols to Core Data")
            } catch {
                logger.error("Failed to save trading info to Core Data: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Public Methods

    /// Checks for missing historical data and triggers backfill if needed (legacy 1-month check)
    public func checkAndBackfillHistoricalData() async {
        // Safety check: Don't run if already running
        guard !isRunningStandardCheck else {
            logger.info("🔍 STANDARD: Skipping - standard check already in progress")
            return
        }
        
        // Don't run standard check if comprehensive check is running
        guard !isRunningComprehensiveCheck else {
            logger.info("🔍 STANDARD: Skipping - comprehensive check in progress")
            return
        }
        
        isRunningStandardCheck = true
        defer { isRunningStandardCheck = false }
        
        logger.info("🔍 Checking for missing historical data gaps (1-month scope)")
        
        // Log to file
        logger.debug("🔍 HISTORICAL BACKFILL: Starting data coverage check at \(Date())")
        
        let symbols = realTimeTrades.map { $0.trade.name }
        let calendar = Calendar.current
        let today = Date()
        let oneMonthAgo = calendar.date(byAdding: .month, value: -1, to: today) ?? today
        
        var symbolsNeedingBackfill: [String] = []
        
        for symbol in symbols {
            // Check if we have complete data for the past month
            let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
            let recentSnapshots = existingSnapshots.filter { $0.timestamp >= oneMonthAgo }
            
            // Count unique days with data in the past month
            let uniqueDays = Set(recentSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
            
            // Calculate business days in the past month (rough estimate)
            let daysSinceOneMonth = calendar.dateComponents([.day], from: oneMonthAgo, to: today).day ?? 0
            let estimatedBusinessDays = max(1, daysSinceOneMonth * 5 / 7) // Rough estimate
            
            // If we're missing more than 25% of business days, trigger backfill
            if uniqueDays.count < estimatedBusinessDays * 3 / 4 {
                symbolsNeedingBackfill.append(symbol)
                logger.info("Symbol \(symbol) needs backfill - only \(uniqueDays.count) days of data vs ~\(estimatedBusinessDays) expected business days (\(String(format: "%.1f", Double(uniqueDays.count) / Double(estimatedBusinessDays) * 100))% coverage)")
            } else {
                logger.debug("Symbol \(symbol) has sufficient recent data - \(uniqueDays.count) days (\(String(format: "%.1f", Double(uniqueDays.count) / Double(estimatedBusinessDays) * 100))% coverage)")
            }
        }
        
        if !symbolsNeedingBackfill.isEmpty {
            logger.info("🚀 Starting historical data backfill for \(symbolsNeedingBackfill.count) symbols")
            await backfillHistoricalData(for: symbolsNeedingBackfill)
        } else {
            logger.info("No symbols need historical data backfill")
        }
    }
    
    /// Comprehensive 5-year historical data coverage check and automatic backfill
    public func checkAndBackfill5YearHistoricalData() async {
        // Safety check: Don't run if already running
        guard !isRunningComprehensiveCheck else {
            logger.info("🔍 COMPREHENSIVE: Skipping - comprehensive check already in progress")
            return
        }
        
        // Safety check: Don't run too frequently
        let timeSinceLastCheck = Date().timeIntervalSince(lastComprehensiveCheckTime)
        guard timeSinceLastCheck >= comprehensiveCheckCooldown else {
            logger.info("🔍 COMPREHENSIVE: Skipping - last check was only \(Int(timeSinceLastCheck/3600)) hours ago (minimum \(Int(comprehensiveCheckCooldown/3600)) hours)")
            return
        }
        
        isRunningComprehensiveCheck = true
        defer { 
            isRunningComprehensiveCheck = false
            lastComprehensiveCheckTime = Date()
        }
        
        logger.info("🔍 COMPREHENSIVE: Starting 5-year historical data coverage analysis")
        
        let symbols = realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
        
        guard !symbols.isEmpty else {
            logger.info("No symbols to analyze for 5-year coverage")
            return
        }
        
        logger.info("🔍 COMPREHENSIVE: Analyzing \(symbols.count) symbols for 5-year coverage")
        
        var symbolsNeedingBackfill: [String] = []
        let calendar = Calendar.current
        let today = Date()
        let fiveYearsAgo = calendar.date(byAdding: .year, value: -5, to: today) ?? today
        
        // Analyze each symbol individually to avoid blocking
        for symbol in symbols {
            await Task.yield() // Allow UI updates between symbols
            
            let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
            let historicalSnapshots = existingSnapshots.filter { $0.timestamp >= fiveYearsAgo }
            
            // Count unique days with data in the past 5 years
            let uniqueDays = Set(historicalSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
            
            // Calculate expected business days over 5 years
            let daysIn5Years = calendar.dateComponents([.day], from: fiveYearsAgo, to: today).day ?? 0
            let expectedBusinessDays = max(1, daysIn5Years * 5 / 7) // Rough estimate
            
            let coverageRatio = Double(uniqueDays.count) / Double(expectedBusinessDays)
            
            // If we have less than 50% coverage over 5 years, trigger backfill
            if coverageRatio < 0.5 {
                symbolsNeedingBackfill.append(symbol)
                logger.info("📊 COMPREHENSIVE: \(symbol) needs 5-year backfill - only \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))% coverage)")
            } else {
                logger.debug("✅ COMPREHENSIVE: \(symbol) has good 5-year coverage - \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))% coverage)")
            }
        }
        
        if !symbolsNeedingBackfill.isEmpty {
            logger.info("🚀 COMPREHENSIVE: Starting automatic 5-year backfill for \(symbolsNeedingBackfill.count) symbols")
            await staggeredBackfillHistoricalData(for: symbolsNeedingBackfill)
        } else {
            logger.info("✅ COMPREHENSIVE: All symbols have good 5-year historical coverage")
        }
    }
    
    /// Staggered backfill that processes symbols with delays to prevent UI blocking
    private func staggeredBackfillHistoricalData(for symbols: [String]) async {
        logger.info("⏱️ STAGGERED: Starting staggered 5-year backfill for \(symbols.count) symbols")
        
        for (index, symbol) in symbols.enumerated() {
            logger.info("⏱️ STAGGERED: Processing symbol \(index + 1)/\(symbols.count): \(symbol)")
            
            // Process each symbol individually with the chunked system
            await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)
            
            // Longer delay between symbols to respect API limits and prevent blocking
            if index < symbols.count - 1 { // Don't delay after the last symbol
                logger.info("⏱️ STAGGERED: Waiting 10 seconds before next symbol...")
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 second delay between symbols
            }
        }
        
        logger.info("🏁 STAGGERED: Completed staggered 5-year backfill for all symbols")
    }
    
    /// Backfills historical data for specified symbols in chunks to avoid hanging
    public func backfillHistoricalData(for symbols: [String]) async {
        logger.info("🚀 CHUNKED BACKFILL: Starting 5-year chunked historical data backfill")
        
        for symbol in symbols {
            await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)
            
            // Add delay between symbols to respect rate limits
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 second delay between symbols
        }
        
        logger.info("🏁 CHUNKED BACKFILL: Completed 5-year chunked backfill for all symbols")
    }
    
    /// Backfills historical data for a single symbol in yearly chunks
    private func backfillHistoricalDataForSymbol(_ symbol: String, yearsToFetch: Int) async {
        let calendar = Calendar.current
        let endDate = Date()
        
        logger.info("🔄 CHUNKED BACKFILL: Starting \(yearsToFetch)-year backfill for \(symbol)")
        
        // Determine what data we already have
        let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
        let existingDates = Set(existingSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
        
        var oldestExistingDate: Date?
        var newestExistingDate: Date?
        
        if !existingSnapshots.isEmpty {
            let sortedSnapshots = existingSnapshots.sorted { $0.timestamp < $1.timestamp }
            oldestExistingDate = sortedSnapshots.first?.timestamp
            newestExistingDate = sortedSnapshots.last?.timestamp
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            
            logger.info("📊 CHUNKED BACKFILL: \(symbol) existing data: \(existingSnapshots.count) points from \(dateFormatter.string(from: oldestExistingDate!)) to \(dateFormatter.string(from: newestExistingDate!))")
        } else {
            logger.info("📊 CHUNKED BACKFILL: \(symbol) has no existing historical data")
        }
        
        // Fetch data in yearly chunks, working backwards from current date
        for yearOffset in 1...yearsToFetch {
            let chunkEndDate = calendar.date(byAdding: .year, value: -(yearOffset - 1), to: endDate) ?? endDate
            let chunkStartDate = calendar.date(byAdding: .year, value: -yearOffset, to: endDate) ?? endDate
            
            // Skip this chunk if we already have good coverage for this period
            if let oldestExisting = oldestExistingDate, chunkEndDate <= oldestExisting {
                logger.info("⏭️ CHUNKED BACKFILL: Skipping year \(yearOffset) for \(symbol) - already have data for this period")
                continue
            }
            
            // Check if this chunk has significant gaps
            let daysInChunk = calendar.dateComponents([.day], from: chunkStartDate, to: chunkEndDate).day ?? 0
            let expectedBusinessDays = max(1, daysInChunk * 5 / 7) // Rough estimate
            
            let chunkExistingDates = existingDates.filter { date in
                date >= chunkStartDate && date < chunkEndDate
            }
            
            let coverageRatio = Double(chunkExistingDates.count) / Double(expectedBusinessDays)
            
            if coverageRatio > 0.8 { // If we have >80% coverage, skip this chunk
                logger.info("⏭️ CHUNKED BACKFILL: Skipping year \(yearOffset) for \(symbol) - good coverage (\(String(format: "%.1f", coverageRatio * 100))%)")
                continue
            }
            
            logger.info("📅 CHUNKED BACKFILL: Fetching year \(yearOffset) for \(symbol) (\(chunkExistingDates.count)/\(expectedBusinessDays) days, \(String(format: "%.1f", coverageRatio * 100))% coverage)")
            
            await fetchHistoricalDataChunk(for: symbol, from: chunkStartDate, to: chunkEndDate, yearOffset: yearOffset)
            
            // Add delay between chunks to respect rate limits
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second delay between chunks
        }
        
        logger.info("✅ CHUNKED BACKFILL: Completed \(yearsToFetch)-year backfill for \(symbol)")
    }
    
    /// Fetches a single chunk of historical data
    private func fetchHistoricalDataChunk(for symbol: String, from startDate: Date, to endDate: Date, yearOffset: Int) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        
        do {
            logger.info("🔄 CHUNKED BACKFILL: Fetching chunk \(yearOffset) for \(symbol): \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
            
            let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
            
            logger.info("📥 CHUNKED BACKFILL: Received \(historicalData.count) data points for \(symbol) chunk \(yearOffset)")
            
            if !historicalData.isEmpty {
                // Filter out dates that already have data to avoid duplicates
                let calendar = Calendar.current
                let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
                let existingDates = Set(existingSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
                
                let newSnapshots = historicalData.filter { snapshot in
                    let snapshotDay = calendar.startOfDay(for: snapshot.timestamp)
                    return !existingDates.contains(snapshotDay)
                }
                
                logger.info("🔍 CHUNKED BACKFILL: After filtering, \(newSnapshots.count) new snapshots for \(symbol) chunk \(yearOffset)")
                
                if !newSnapshots.isEmpty {
                    await addHistoricalSnapshots(newSnapshots, for: symbol)
                    logger.info("✅ CHUNKED BACKFILL: Added \(newSnapshots.count) new data points for \(symbol) chunk \(yearOffset)")
                    
                    // Log sample data for verification
                    if let first = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).first,
                       let last = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).last {
                        logger.info("📊 CHUNKED BACKFILL: \(symbol) chunk \(yearOffset) range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                } else {
                    logger.info("ℹ️ CHUNKED BACKFILL: No new data needed for \(symbol) chunk \(yearOffset) - all dates already exist")
                }
            } else {
                logger.warning("⚠️ CHUNKED BACKFILL: No data received for \(symbol) chunk \(yearOffset)")
            }
            
        } catch {
            logger.error("❌ CHUNKED BACKFILL: Failed to fetch chunk \(yearOffset) for \(symbol): \(error.localizedDescription)")
            
            // Log to file for debugging
            logger.error("❌ CHUNKED BACKFILL ERROR for \(symbol) chunk \(yearOffset) at \(Date()): \(error.localizedDescription)")
        }
    }
    
    /// Legacy backfill method - now calls the chunked version
    public func backfillHistoricalDataLegacy(for symbols: [String]) async {
        let calendar = Calendar.current
        let endDate = Date()
        // Start with 1 year instead of 5 years to test
        let startDate = calendar.date(byAdding: .year, value: -1, to: endDate) ?? endDate
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        logger.info("🚀 HISTORICAL BACKFILL: Starting for \(symbols.count) symbols")
        logger.info("🚀 HISTORICAL BACKFILL: Date range \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        logger.info("🚀 HISTORICAL BACKFILL: Calculated start date: \(startDate)")
        logger.info("🚀 HISTORICAL BACKFILL: End date: \(endDate)")
        
        // Log to file
        logger.debug("🚀 HISTORICAL BACKFILL: Starting for \(symbols.count) symbols at \(Date()). Symbols: \(symbols). Date range: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        
        for symbol in symbols {
            do {
                logger.info("🔄 HISTORICAL BACKFILL: Starting fetch for \(symbol)")
                
                // Fetch historical data directly without timeout for now
                let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
                
                logger.info("📥 HISTORICAL BACKFILL: Received \(historicalData.count) data points for \(symbol)")
                
                if !historicalData.isEmpty {
                    // Show sample of received data for debugging
                    if historicalData.count > 0 {
                        let sortedData = historicalData.sorted { $0.timestamp < $1.timestamp }
                        if let first = sortedData.first, let last = sortedData.last {
                            logger.info("📊 HISTORICAL BACKFILL: \(symbol) data range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                        }
                        
                        // Show first few data points
                        logger.info("📊 HISTORICAL BACKFILL: First 3 data points for \(symbol):")
                        for (index, snapshot) in sortedData.prefix(3).enumerated() {
                            logger.info("   \(index + 1): \(dateFormatter.string(from: snapshot.timestamp)) - Price: \(snapshot.price)")
                        }
                    }
                    
                    // Filter out dates that already have data to avoid duplicates
                    let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
                    let existingDates = Set(existingSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
                    
                    logger.info("🔍 HISTORICAL BACKFILL: \(symbol) has \(existingSnapshots.count) existing snapshots")
                    
                    let newSnapshots = historicalData.filter { snapshot in
                        let snapshotDay = calendar.startOfDay(for: snapshot.timestamp)
                        return !existingDates.contains(snapshotDay)
                    }
                    
                    logger.info("🔍 HISTORICAL BACKFILL: After filtering, \(newSnapshots.count) new snapshots for \(symbol)")
                    
                    if !newSnapshots.isEmpty {
                        // Add the new snapshots to historical data manager
                        await addHistoricalSnapshots(newSnapshots, for: symbol)
                        logger.info("✅ HISTORICAL BACKFILL: Added \(newSnapshots.count) new historical data points for \(symbol) (filtered from \(historicalData.count) total)")
                        
                        // Verify the data was actually stored
                        let storedCount = historicalDataManager.priceSnapshots[symbol]?.count ?? 0
                        logger.info("📊 HISTORICAL BACKFILL: \(symbol) now has \(storedCount) total stored data points")
                    } else {
                        logger.info("ℹ️ HISTORICAL BACKFILL: No new historical data points needed for \(symbol) - all dates already exist")
                    }
                } else {
                    logger.warning("⚠️ HISTORICAL BACKFILL: No historical data received for \(symbol)")
                }
                
                // Add delay between requests to respect rate limits
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                
            } catch {
                logger.error("❌ HISTORICAL BACKFILL: Failed to backfill historical data for \(symbol): \(error.localizedDescription)")
                
                // Log to file for debugging
                logger.error("❌ HISTORICAL BACKFILL ERROR for \(symbol) at \(Date()): \(error.localizedDescription)")
            }
        }
        
        logger.info("🏁 HISTORICAL BACKFILL: Completed historical data backfill process")
    }
    
    /// Adds historical snapshots to the data manager
    @MainActor
    private func addHistoricalSnapshots(_ snapshots: [PriceSnapshot], for symbol: String) async {
        historicalDataManager.addImportedSnapshots(snapshots, for: symbol)
    }
    
    /// Manually triggers a 5-year chunked historical data backfill for all symbols
    public func triggerFullHistoricalBackfill() async {
        let symbols = realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
        
        guard !symbols.isEmpty else {
            logger.info("No symbols to backfill")
            return
        }
        
        logger.info("🚀 MANUAL TRIGGER: Starting full 5-year historical backfill for \(symbols.count) symbols")
        await backfillHistoricalData(for: symbols)
        logger.info("🏁 MANUAL TRIGGER: Full 5-year historical backfill completed")
    }
    
    /// Returns the current status of automatic historical data checking
    public func getHistoricalDataStatus() -> (isRunningComprehensive: Bool, isRunningStandard: Bool, lastComprehensiveCheck: Date, nextComprehensiveCheck: Date) {
        let nextCheck = lastComprehensiveCheckTime.addingTimeInterval(comprehensiveCheckCooldown)
        return (
            isRunningComprehensive: isRunningComprehensiveCheck,
            isRunningStandard: isRunningStandardCheck,
            lastComprehensiveCheck: lastComprehensiveCheckTime,
            nextComprehensiveCheck: nextCheck
        )
    }
    
    /// Triggers comprehensive 5-year portfolio value calculation in monthly chunks
    public func calculate5YearPortfolioValues() async {
        logger.info("🚀 MANUAL TRIGGER: Starting 5-year portfolio value calculation")
        await historicalDataManager.calculate5YearHistoricalPortfolioValues(using: self)
        logger.info("🏁 MANUAL TRIGGER: Completed 5-year portfolio value calculation")
    }
    
    /// Checks if portfolio value calculation is needed and triggers it automatically
    private func checkAndCalculatePortfolioValues() async {
        logger.info("🔍 STARTUP: Checking if portfolio value calculation is needed")
        
        // Check if we have sufficient historical price data but no portfolio value data
        let totalPriceSnapshots = historicalDataManager.priceSnapshots.values.map { $0.count }.reduce(0, +)
        let portfolioValueCount = historicalDataManager.cachedHistoricalPortfolioValues.count
        
        logger.info("🔍 STARTUP: Found \(totalPriceSnapshots) price snapshots and \(portfolioValueCount) portfolio value points")
        
        // If we have lots of price data but no portfolio values, trigger calculation
        if totalPriceSnapshots > 100 && portfolioValueCount < 50 {
            logger.info("🚀 STARTUP: Sufficient price data available, triggering automatic 5-year portfolio value calculation")
            await historicalDataManager.calculate5YearHistoricalPortfolioValues(using: self)
            logger.info("🏁 STARTUP: Automatic portfolio value calculation completed")
        } else {
            logger.info("ℹ️ STARTUP: Portfolio value calculation not needed - sufficient data already exists")
        }
    }
    
    /// Tests the API connection with a simple request
    func testAPIConnection() async throws -> Bool {
        logger.info("Testing FMP API connection")
        
        do {
            // Test with a simple quote request for Apple stock
            let result = try await networkService.fetchQuote(for: "AAPL")
            
            // Check if we got valid data back
            let isValid = !result.regularMarketPrice.isNaN && 
                         !result.regularMarketPreviousClose.isNaN && 
                         result.regularMarketPrice > 0
            
            if isValid {
                logger.info("FMP API test successful - received valid data for AAPL")
            } else {
                logger.warning("FMP API test returned invalid data - price: \(result.regularMarketPrice), prevClose: \(result.regularMarketPreviousClose)")
            }
            
            return isValid
        } catch {
            logger.error("FMP API test failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Clears bad historical data for specific symbols
    public func clearHistoricalDataForSymbol(_ symbol: String) {
        historicalDataManager.clearDataForSymbol(symbol)
        logger.info("Cleared bad historical data for \(symbol)")
    }
    
    /// Clears bad historical data for multiple symbols
    public func clearHistoricalDataForSymbols(_ symbols: [String]) {
        historicalDataManager.clearDataForSymbols(symbols)
        logger.info("Cleared bad historical data for \(symbols.count) symbols")
    }
    
    /// Manually triggers retroactive portfolio calculation
    public func triggerRetroactivePortfolioCalculation() {
        Task {
            logger.info("🔄 MANUAL: Starting retroactive portfolio calculation")
            await historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
            logger.info("🔄 MANUAL: Retroactive portfolio calculation completed")
        }
    }
    
    /// Refreshes all stock data from the network using the configured networkService
    @objc func refreshAllTrades() async {
        logger.info("Starting refresh for all trades using PythonNetworkService")
        // Prevent refresh if no trades are loaded
        guard !realTimeTrades.isEmpty else {
            logger.info("No trades to refresh.")
            return
        }
        
        // Use detached task to prevent blocking the calling context (especially timers)
        await Task.detached(priority: .background) { [weak self] in
            await self?.performRefreshAllTrades()
        }.value
    }
    
    /// Internal method that performs the actual refresh work
    private func performRefreshAllTrades() async {
        let allSymbols = realTimeTrades.map { $0.trade.name }
        let now = Date()
        
        // Filter symbols that need refreshing based on cache and retry logic
        let symbolsToRefresh = allSymbols.filter { symbol in
            // Check if we have a successful fetch that's still valid
            if let lastSuccess = lastSuccessfulFetch[symbol] {
                let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
                if timeSinceSuccess < cacheInterval {
                    logger.debug("Symbol \(symbol) successfully cached for \(Int(timeSinceSuccess))s, skipping refresh")
                    return false
                }
            }
            
            // Check if we have a recent failed fetch that we shouldn't retry yet
            if let lastFailure = lastFailedFetch[symbol] {
                let timeSinceFailure = now.timeIntervalSince(lastFailure)
                if timeSinceFailure < retryInterval {
                    logger.debug("Symbol \(symbol) failed \(Int(timeSinceFailure))s ago, waiting for retry interval")
                    return false
                }
            }
            
            logger.debug("Symbol \(symbol) needs refresh")
            return true
        }
        
        // Also force refresh symbols that are very old (beyond max cache age)
        let symbolsToForceRefresh = allSymbols.filter { symbol in
            guard let lastSuccess = lastSuccessfulFetch[symbol] else { return true }
            let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
            return timeSinceSuccess >= maxCacheAge
        }
        
        let finalSymbolsToRefresh = Array(Set(symbolsToRefresh + symbolsToForceRefresh))
        
        if finalSymbolsToRefresh.isEmpty {
            logger.info("All \(allSymbols.count) symbols are cached or in retry cooldown, skipping network refresh")
            return
        }
        
        logger.info("About to refresh \(finalSymbolsToRefresh.count) of \(allSymbols.count) trades: \(finalSymbolsToRefresh)")

        do {
            // This now calls PythonNetworkService.fetchBatchQuotes
            let results = try await networkService.fetchBatchQuotes(for: finalSymbolsToRefresh)

            guard !results.isEmpty else {
                 logger.warning("Refresh completed but received no results from network service.")
                 return
             }

            var anySuccessfulUpdate = false
            
            // Update each trade with its corresponding result
            let resultDict: [String: StockFetchResult] = Dictionary(uniqueKeysWithValues: results.map { ($0.symbol, $0) })
            for idx in self.realTimeTrades.indices {
                let symbol = self.realTimeTrades[idx].trade.name
                if let res = resultDict[symbol] {
                    let wasSuccessful = self.realTimeTrades[idx].updateWithResult(res, retainOnFailure: true)
                    
                    // Update cache based on success/failure
                    if wasSuccessful {
                        self.lastSuccessfulFetch[symbol] = now
                        self.lastFailedFetch.removeValue(forKey: symbol) // Clear any previous failure
                        logger.debug("Updated cache for \(symbol) - successful fetch")
                        anySuccessfulUpdate = true
                    } else {
                        self.lastFailedFetch[symbol] = now
                        logger.debug("Updated failure cache for \(symbol) - failed fetch, retaining old data")
                    }
                    
                    logger.debug("Updated trade \(symbol) from refresh result.")
                } else {
                    // No result returned - treat as failure
                    self.lastFailedFetch[symbol] = now
                    logger.warning("No result returned for symbol \(symbol), treating as failure.")
                }
            }
            
            // Save trading info if any successful updates occurred
            if anySuccessfulUpdate {
                saveTradingInfo()
                // Record historical data snapshot after successful updates
                historicalDataManager.recordSnapshot(from: self)
                
                // NEW: Trigger enhanced portfolio calculation periodically
                let randomCheck = Int.random(in: 1...100)
                
                if randomCheck == 1 {
                    // 1% chance: Trigger retroactive portfolio calculation
                    Task {
                        logger.info("🔄 PERIODIC: Triggering retroactive portfolio history calculation")
                        await historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
                    }
                } else if randomCheck <= 5 {
                    // 4% chance: Check for historical data gaps (reduced frequency)
                    if results.count > 0 {
                        Task {
                            logger.info("🔍 PERIODIC: Triggering standard 1-month gap check")
                            await checkAndBackfillHistoricalData()
                        }
                    }
                }
                // 95% of the time: No heavy background processing
            }
            
            logger.info("Successfully processed \(results.count) trades of \(finalSymbolsToRefresh.count) requested.")
        } catch {
            // Mark all requested symbols as failed
            for symbol in finalSymbolsToRefresh {
                self.lastFailedFetch[symbol] = now
            }
            
            // Log the specific error from NetworkError enum if possible
            if let networkError = error as? NetworkError {
                 logger.error("Failed to refresh trades: \(networkError.localizedDescription)")
             } else {
                 logger.error("Failed to refresh trades (unknown error): \(error.localizedDescription)")
             }
        }
    }

    /// Calculates the total net gains across all trades
    func calculateNetGains() -> (amount: Double, currency: String) {
        logger.debug("Calculating net gains in \(preferredCurrency)")
        var totalGainsUSD = 0.0

        for realTimeTradeItem in realTimeTrades {
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else {
                logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }

            // Get normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = realTimeTradeItem.trade.position.getNormalizedAvgCost(for: realTimeTradeItem.trade.name)
            guard !adjustedCost.isNaN, adjustedCost > 0 else {
                logger.debug("Skipping net gain calculation for \(realTimeTradeItem.trade.name) due to invalid cost.")
                continue
            }

            let currentPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            logger.debug("Using normalized cost for \(symbol): \(adjustedCost) (from \(realTimeTradeItem.trade.position.positionAvgCostString) \(realTimeTradeItem.trade.position.costCurrency ?? "auto-detected"))")

            // Calculate gains in the stock's currency (currentPrice and adjustedCost are now in same currency)
            let rawGains = (currentPrice - adjustedCost) * units

            // Convert to USD for aggregation
            var gainsInUSD = rawGains
            if let knownCurrency = currency {
                if knownCurrency == "GBP" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: "GBP", to: "USD")
                } else if knownCurrency != "USD" {
                    gainsInUSD = currencyConverter.convert(amount: rawGains, from: knownCurrency, to: "USD")
                }
                // If knownCurrency is USD, gainsInUSD remains rawGains
            } else {
                // Assume USD if currency is nil
                logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for gain calculation.")
                // gainsInUSD remains rawGains
            }

            logger.debug("Gain calculation for \(symbol): currentPrice=\(currentPrice), adjustedCost=\(adjustedCost), units=\(units), currency=\(currency ?? "nil"), rawGains=\(rawGains), gainsInUSD=\(gainsInUSD)")
            totalGainsUSD += gainsInUSD
        }

        // Convert final total to preferred currency - Keep as is
        var finalAmount = totalGainsUSD
         if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
             let gbpAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: "GBP")
             finalAmount = gbpAmount * 100.0 // Convert GBP to GBX
         } else if preferredCurrency != "USD" { // Only convert if not already USD
             finalAmount = currencyConverter.convert(amount: totalGainsUSD, from: "USD", to: preferredCurrency)
         }
        // If preferredCurrency is USD, finalAmount remains totalGainsUSD


        logger.debug("Net gains calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }

    /// Calculates the total portfolio value (market value) in the preferred currency
    func calculateNetValue() -> (amount: Double, currency: String) {
        logger.debug("Calculating net value in \(preferredCurrency)")
        var totalValueUSD = 0.0

        for realTimeTradeItem in realTimeTrades {
            // Ensure price is valid before calculation
            guard !realTimeTradeItem.realTimeInfo.currentPrice.isNaN,
                  realTimeTradeItem.realTimeInfo.currentPrice != 0 else {
                logger.debug("Skipping net value calculation for \(realTimeTradeItem.trade.name) due to invalid price.")
                continue
            }

            let currentPrice = realTimeTradeItem.realTimeInfo.currentPrice
            let units = realTimeTradeItem.trade.position.unitSize
            let currency = realTimeTradeItem.realTimeInfo.currency
            let symbol = realTimeTradeItem.trade.name
            
            // Calculate market value in the stock's currency
            let marketValueInStockCurrency = currentPrice * units

            // Convert to USD for aggregation
            var marketValueInUSD = marketValueInStockCurrency
            if let knownCurrency = currency {
                if knownCurrency == "GBP" {
                    marketValueInUSD = currencyConverter.convert(amount: marketValueInStockCurrency, from: "GBP", to: "USD")
                } else if knownCurrency != "USD" {
                    marketValueInUSD = currencyConverter.convert(amount: marketValueInStockCurrency, from: knownCurrency, to: "USD")
                }
                // If knownCurrency is USD, marketValueInUSD remains marketValueInStockCurrency
            } else {
                // Assume USD if currency is nil
                logger.warning("Currency unknown for \(realTimeTradeItem.trade.name), assuming USD for value calculation.")
                // marketValueInUSD remains marketValueInStockCurrency
            }

            logger.debug("Value calculation for \(symbol): currentPrice=\(currentPrice), units=\(units), currency=\(currency ?? "nil"), marketValueInStockCurrency=\(marketValueInStockCurrency), marketValueInUSD=\(marketValueInUSD)")
            totalValueUSD += marketValueInUSD
        }

        // Convert final total to preferred currency
        var finalAmount = totalValueUSD
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0 // Convert GBP to GBX
        } else if preferredCurrency != "USD" { // Only convert if not already USD
            finalAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
        }
        // If preferredCurrency is USD, finalAmount remains totalValueUSD

        logger.debug("Net value calculated: \(finalAmount) \(preferredCurrency)")
        return (finalAmount, preferredCurrency)
    }

    func startStaggeredRefresh() {
        refreshTimer?.invalidate()
        currentSymbolIndex = 0
        let count = max(1, realTimeTrades.count)
        let interval = max(60.0, refreshInterval / Double(count)) // Minimum 60 seconds between individual refreshes
        
        print("🔄 [DataModel] Starting staggered refresh: \(count) symbols, interval=\(interval)s")
        
        // Reduced file logging frequency to improve performance
        // let debugInfo = "Starting refresh: \(count) symbols, interval=\(interval)s at \(Date())\n"
        // if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        //     let debugFile = documentsPath.appendingPathComponent("stockbar_debug.log")
        //     try? debugInfo.appendToFile(url: debugFile)
        // }
        
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshNextSymbol()
        }
    }

    private func refreshNextSymbol() {
        guard !realTimeTrades.isEmpty else { 
            print("🔄 [DataModel] No trades to refresh")
            return 
        }
        
        // Ensure currentSymbolIndex is within bounds
        if currentSymbolIndex >= realTimeTrades.count {
            currentSymbolIndex = 0
        }
        
        let symbol = realTimeTrades[currentSymbolIndex].trade.name
        
        print("🔄 [DataModel] Refreshing symbol: \(symbol) (index \(currentSymbolIndex)/\(realTimeTrades.count))")
        
        // Reduced file logging frequency to improve performance
        // let debugInfo = "Refreshing symbol: \(symbol) at \(Date())\n"
        // if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        //     let debugFile = documentsPath.appendingPathComponent("stockbar_debug.log")
        //     try? debugInfo.appendToFile(url: debugFile)
        // }
        
        // Check cache and retry logic before making individual requests
        let now = Date()
        
        // Check if we have a successful fetch that's still valid
        if let lastSuccess = lastSuccessfulFetch[symbol] {
            let timeSinceSuccess = now.timeIntervalSince(lastSuccess)
            if timeSinceSuccess < cacheInterval {
                logger.debug("Skipping individual refresh for \(symbol) - successfully cached for \(Int(timeSinceSuccess))s")
                self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
                return
            }
        }
        
        // Check if we have a recent failed fetch that we shouldn't retry yet
        if let lastFailure = lastFailedFetch[symbol] {
            let timeSinceFailure = now.timeIntervalSince(lastFailure)
            if timeSinceFailure < retryInterval {
                logger.debug("Skipping individual refresh for \(symbol) - failed \(Int(timeSinceFailure))s ago, waiting for retry")
                self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
                return
            }
        }
        
        Task {
            do {
                // Use enhanced quote fetching for individual symbol refreshes to get pre/post market data
                let result: StockFetchResult
                if let pythonService = self.networkService as? PythonNetworkService {
                    result = try await pythonService.fetchEnhancedQuote(for: symbol)
                } else {
                    result = try await self.networkService.fetchQuote(for: symbol)
                }
                
                if let index = self.realTimeTrades.firstIndex(where: { $0.trade.name == symbol }) {
                    let wasSuccessful = self.realTimeTrades[index].updateWithResult(result, retainOnFailure: true)
                    
                    // Update cache based on success/failure
                    if wasSuccessful {
                        self.lastSuccessfulFetch[symbol] = now
                        self.lastFailedFetch.removeValue(forKey: symbol)
                        self.logger.debug("Updated individual cache for \(symbol) - successful fetch")
                        
                        // Save trading info for successful individual updates
                        self.saveTradingInfo()
                        // Record historical data snapshot after successful individual update
                        print("📸 [DataModel] Triggering snapshot after successful update for \(symbol)")
                        
                        // Reduced file logging frequency - only log to file occasionally to improve performance
                        if Int.random(in: 1...10) == 1 { // 10% chance to reduce I/O load
                            Task.detached(priority: .utility) { [logger] in // Capture logger
                                logger.debug("✅ SUCCESS: Updated \(symbol) at \(Date()). Triggering snapshot after successful update for \(symbol) at \(Date())")
                            }
                        }
                        
                        self.historicalDataManager.recordSnapshot(from: self)
                    } else {
                        self.lastFailedFetch[symbol] = now
                        self.logger.debug("Updated individual failure cache for \(symbol) - failed fetch, retaining old data")
                        
                        // Reduced file logging frequency for failures too
                        if Int.random(in: 1...5) == 1 { // 20% chance for errors (higher than success)
                            Task.detached(priority: .utility) { [logger] in // Capture logger
                                logger.warning("❌ FAILED: Update failed for \(symbol) at \(Date())")
                            }
                        }
                    }
                }
            } catch {
                // Mark as failed
                self.lastFailedFetch[symbol] = now
                self.logger.debug("Individual refresh failed for \(symbol): \(error.localizedDescription)")
                
                // Reduced file logging frequency for network errors
                if Int.random(in: 1...3) == 1 { // 33% chance for network errors (higher priority)
                    Task.detached(priority: .utility) { [logger] in // Capture logger
                        logger.error("🚨 ERROR: Network error for \(symbol) at \(Date()): \(error.localizedDescription)")
                    }
                }
            }
            self.currentSymbolIndex = (self.currentSymbolIndex + 1) % self.realTimeTrades.count
        }
    }

    // MARK: - Private Methods

    // Keep setupPublishers and saveTrades as they are
    private func setupPublishers() {
        // Increased debounce time to reduce frequency of saves and prevent rapid successive operations
        $realTimeTrades
            .debounce(for: .seconds(2.0), scheduler: RunLoop.main)
            .sink { [weak self] trades in
                guard let self = self else { return }
                self.saveTrades(trades)
                // Also save trading info when trades change (e.g., when adding/removing stocks)
                self.saveTradingInfo()
            }
            .store(in: &cancellables)
    }

    private func saveTrades(_ trades: [RealTimeTrade]) {
        logger.debug("Saving \(trades.count) trades to Core Data")
        
        // Move saving to background queue to prevent UI blocking
        Task.detached(priority: .utility) { [weak self, logger] in
            guard let self = self else { return }
            
            do {
                // Filter out any potential placeholder/empty trades before saving
                let tradesToSave = trades.filter { !$0.trade.name.isEmpty }
                let tradeModels = tradesToSave.map { $0.trade }
                
                // Save directly to Core Data
                try await self.tradeDataService.saveAllTrades(tradeModels)
                logger.debug("Successfully saved \(tradesToSave.count) trades to Core Data")
            } catch {
                logger.error("Failed to save trades to Core Data: \(error.localizedDescription)")
            }
        }
    }

    private func loadUserData() -> UserData {
        if let data = UserDefaults.standard.data(forKey: "userData") {
            if let decodedUserData = try? JSONDecoder().decode(UserData.self, from: data) {
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
            logger.debug("Successfully saved user data")
        } catch {
            logger.error("Failed to save user data: \(error.localizedDescription)")
        }
    }

    /// Ensures that all loaded stocks have a non-nil currency assigned.
    /// This is crucial for older saved data where currency might not have been explicitly stored.
    private func normalizeLoadedStockCurrencies() {
        // Iterate through all stocks and ensure their currency is set if nil
        for i in 0..<userData.stocks.count {
            var stock = userData.stocks[i]
            if stock.currency == nil {
                // Set default currency if not specified (only for loaded data that might be old)
                if stock.symbol.uppercased().hasSuffix(".L") {
                    stock.currency = "GBP" // UK stocks (since Python script converted pence to pounds)
                } else {
                    stock.currency = "USD" // Default to USD for other stocks
                }
                userData.stocks[i] = stock // Update the stock in the array
                logger.debug("Normalized currency for \(stock.symbol) to \(stock.currency ?? "nil") upon loading.")
            }
        }
    }
}

// MARK: - RealTimeTrade Extension

extension RealTimeTrade {
    /// Updates the trade with new data from the network service
    /// Returns true if the update was successful (non-NaN data), false if it failed and old data was retained
    func updateWithResult(_ result: StockFetchResult, retainOnFailure: Bool = true) -> Bool {
        // Use separate prices for different purposes
        let regularPrice = result.regularMarketPrice  // For day calculations
        let displayPrice = result.displayPrice        // For market value and display
        let prevClose = result.regularMarketPreviousClose
        
        // Check if this is a failed fetch (NaN values)
        let isFetchFailure = regularPrice.isNaN || prevClose.isNaN
        
        if isFetchFailure {
            Logger.shared.warning("Fetch failed for \(result.symbol) - regularPrice: \(regularPrice), prevClose: \(prevClose)")
            
            if retainOnFailure {
                // Don't update the price data, but we can update the timestamp to show when we last tried
                // Keep existing currentPrice, previousClose, prevClosePrice, currency
                Logger.shared.info("Retaining last successful data for \(result.symbol)")
                return false // Indicate failure
            } else {
                // Old behavior - update with NaN values
                Logger.shared.warning("Updating \(result.symbol) with NaN values (retainOnFailure=false)")
            }
        }

        var currency = result.currency
        let symbol = result.symbol
        
        // IMPORTANT: Our Python script already converts pence to pounds for .L stocks
        // So we should NOT do any additional conversion here
        var finalRegularPrice = regularPrice
        var finalDisplayPrice = displayPrice
        var finalPrevClose = prevClose
        
        // Set default currency if not specified
        if currency == nil {
            if symbol.uppercased().hasSuffix(".L") {
                currency = "GBP" // UK stocks (since Python script converted pence to pounds)
            } else {
                currency = "USD" // Default to USD for other stocks
            }
        }

        // Only update price data if fetch was successful or retainOnFailure is false
        if !isFetchFailure || !retainOnFailure {
            self.realTimeInfo.currentPrice = finalRegularPrice  // Use regular market price for day calculations
            self.realTimeInfo.previousClose = finalPrevClose // Use the (potentially adjusted) finalPrevClose
            self.realTimeInfo.prevClosePrice = finalPrevClose // Also set the field that StockStatusBar reads
            self.realTimeInfo.currency = currency // Now always GBP for GBX/GBp or .L stocks that were converted
            
            // Update pre/post market data
            self.realTimeInfo.preMarketPrice = result.preMarketPrice
            self.realTimeInfo.preMarketChange = result.preMarketChange
            self.realTimeInfo.preMarketChangePercent = result.preMarketChangePercent
            self.realTimeInfo.preMarketTime = result.preMarketTime
            self.realTimeInfo.postMarketPrice = result.postMarketPrice
            self.realTimeInfo.postMarketChange = result.postMarketChange
            self.realTimeInfo.postMarketChangePercent = result.postMarketChangePercent
            self.realTimeInfo.postMarketTime = result.postMarketTime
            self.realTimeInfo.marketState = result.marketState?.rawValue
        }
        
        // Always update metadata (but not the last update time if we're retaining old data)
        if !isFetchFailure || !retainOnFailure {
            self.realTimeInfo.lastUpdateTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970) // Fallback to current time if nil
            self.realTimeInfo.regularMarketTime = result.regularMarketTime ?? Int(Date().timeIntervalSince1970) // Set the field that getTimeInfo() reads
        }
        
        self.realTimeInfo.exchangeTimezoneName = result.exchangeTimezoneName ?? "GMT" // Set a default timezone
        self.realTimeInfo.shortName = result.shortName ?? self.trade.name // Use symbol if name nil

        let logger = Logger.shared // Already defined in DataModel, but ok for local scope too
        
        if isFetchFailure && retainOnFailure {
            logger.info("Retained old data for \(self.trade.name): Price \(self.realTimeInfo.currentPrice) Currency: \(self.realTimeInfo.currency ?? "N/A") (fetch failed)")
        } else {
            logger.info("Updated trade \(self.trade.name): Price \(self.realTimeInfo.currentPrice) PrevClose: \(String(describing: self.realTimeInfo.previousClose)) prevClosePrice: \(self.realTimeInfo.prevClosePrice) Currency: \(self.realTimeInfo.currency ?? "N/A") originalRegularPrice: \(regularPrice) originalDisplayPrice: \(displayPrice) originalPrevClose: \(prevClose) originalCurrency: \(result.currency ?? "nil")")
        }
        
        return !isFetchFailure // Return true if successful, false if failed
    }
}
