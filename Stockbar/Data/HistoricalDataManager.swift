import Combine
import CoreData
import Foundation
import Observation

@MainActor
@Observable
class HistoricalDataManager {
    static let shared = HistoricalDataManager()
    
    let logger = Logger.shared
    private let encoder = JSONEncoder()
    
    // Performance optimization services
    private let decoder = JSONDecoder()
    private let cacheManager = CacheManager.shared
    let coreDataService: HistoricalDataServiceProtocol
    private let migrationService = DataMigrationService.shared
    let instrumentAliasStore = InstrumentAliasStore()
    
    var portfolioSnapshots: [PortfolioSnapshot] = []
    var priceSnapshots: [String: [PriceSnapshot]] = [:] {
        didSet { aliasHistoryCache.removeAll() }
    }
    private(set) var priceDataRevision: Int = 0
    /// Which series changed with each `priceDataRevision` bump: upper-cased
    /// symbol and alias keys, or nil when every series may have changed.
    let priceDataChanges = PassthroughSubject<Set<String>?, Never>()
    var portfolioHistoryRevision: Int = 0
    // Written only in HistoricalDataManager+Folync.swift.
    var folyncSupplementalConfigurationRevision: Int = 0
    // Written only in HistoricalDataManager+Folync.swift.
    var folyncSourceStatusBySeries: [String: FolyncSupplementalSourceStatus] = [:]
    /// Folync portfolio-history requests that have not answered yet. A chart with no data
    /// shows a loading state rather than "no data" while this is above zero.
    // Written only in HistoricalDataManager+Folync.swift.
    var folyncPortfolioHistoryRequestsInFlight = 0
    /// False until the stored portfolio history has been read at launch.
    private(set) var hasLoadedStoredPortfolioHistory = false
    // Written only in HistoricalDataManager+Folync.swift.
    var folyncCoverageBySeries: [String: String] = [:]
    
    // MARK: - Enhanced Portfolio Storage
    
    // New persistent portfolio snapshots storage
    var historicalPortfolioSnapshots: [HistoricalPortfolioSnapshot] = []
    @ObservationIgnored var currentPortfolioComposition: PortfolioComposition?
    @ObservationIgnored var lastRetroactiveCalculationDate: Date = Date.distantPast
    
    // Cache for calculated historical portfolio values (legacy - being phased out)
    @ObservationIgnored var cachedHistoricalPortfolioValues: [ChartDataPoint] = []
    
    // CRITICAL FIX: Prevent concurrent calculation overlaps
    @ObservationIgnored var isCalculationInProgress = false
    @ObservationIgnored var lastPortfolioCalculationDate: Date = Date.distantPast
    private let portfolioCalculationCacheInterval: TimeInterval = 1800 // 30 minutes cache (increased from 5 minutes)
    @ObservationIgnored private var earliestAvailableDates: [String: Date] = [:]
    
    // MARK: - Data Storage Configuration
    
    // Storage keys for persistent data
    private enum StorageKeys {
        static let portfolioSnapshots = "portfolioSnapshots"
        static let priceSnapshots = "priceSnapshots"
        static let historicalPortfolioSnapshots = "historicalPortfolioSnapshots"
        static let currentPortfolioComposition = "currentPortfolioComposition"
        static let lastRetroactiveCalculationDate = "lastRetroactiveCalculationDate"
        static let cachedHistoricalPortfolioValues = "cachedHistoricalPortfolioValues"
        static let lastPortfolioCalculationDate = "lastPortfolioCalculationDate"
        // "v2": the first key also held dates recorded from failed fetches, which capped history.
        static let earliestAvailableDates = "earliestAvailableDates.v2"
    }
    
    // MARK: - Performance Caching
    
    // Cache for getOptimalStockData results to prevent repeated expensive calculations
    @ObservationIgnored var stockDataCache: [String: [ChartDataPoint]] = [:]
    @ObservationIgnored var stockDataCacheTimestamp: [String: Date] = [:]
    private let stockDataCacheInterval: TimeInterval = 30 // 30 seconds cache
    
    // Full history stays in Core Data; only the active working set is retained.
    private let maxDataPoints = 1_800
    
    private static let snapshotIntervalDefaultsKey = "portfolioSnapshotIntervalSeconds"
    /// Seconds between recorded portfolio snapshots (default 5 minutes), kept across launches.
    @ObservationIgnored private var snapshotInterval: TimeInterval = {
        let stored = StockbarRuntimeStorage.userDefaults.double(forKey: HistoricalDataManager.snapshotIntervalDefaultsKey)
        return stored >= 30 ? stored : 300
    }()
    @ObservationIgnored private var lastSnapshotTime: Date = Date.distantPast
    /// Last price row recorded per symbol, to skip rows that repeat it.
    @ObservationIgnored private var lastRecordedPrice: [String: PriceSnapshot] = [:]
    @ObservationIgnored private var unsavedPriceSnapshots: [PriceSnapshot] = []
    @ObservationIgnored private var unsavedPortfolioSnapshots: [HistoricalPortfolioSnapshot] = []
    private static let maxUnsavedRows = 5_000
    /// First check ten minutes after launch, then hourly; the work itself is weekly.
    @ObservationIgnored private var nextStoreMaintenanceCheck = Date().addingTimeInterval(600)
    @ObservationIgnored private let storeMaintenanceStart = Date()

    /// A row repeating the previous price is recorded once an hour, enough to
    /// show the series is alive. 62% of stored rows repeated the row before.
    nonisolated static let unchangedPriceRecordInterval: TimeInterval = 3600
    /// Refreshes arrive on a timer of the same length as the snapshot interval,
    /// so asking for the full interval skipped every other snapshot whenever a
    /// refresh landed a moment early.
    nonisolated static let snapshotIntervalTolerance = 0.9

    nonisolated static func shouldRecordPrice(_ snapshot: PriceSnapshot, after last: PriceSnapshot?) -> Bool {
        guard let last else { return true }
        return snapshot.price != last.price
            || snapshot.previousClose != last.previousClose
            || snapshot.timestamp.timeIntervalSince(last.timestamp) >= unchangedPriceRecordInterval
    }

    nonisolated static func isSnapshotDue(elapsed: TimeInterval, interval: TimeInterval) -> Bool {
        elapsed >= interval * snapshotIntervalTolerance
    }

    /// The positions worth storing with a portfolio snapshot: those actually
    /// held. Watch-only and zero-unit rows were 13% of the position table.
    nonisolated static func storedPositions(from trades: [RealTimeTrade]) -> PositionSnapshots {
        PositionSnapshots(firstValuesFor: trades.compactMap { trade -> PositionSnapshot? in
            let units = trade.trade.position.unitSize
            guard !trade.trade.isWatchlistOnly, units.isFinite, units > 0 else { return nil }
            let price = trade.realTimeInfo.currentPrice
            return PositionSnapshot(
                symbol: trade.trade.name,
                units: units,
                priceAtDate: price,
                valueAtDate: price * units,
                currency: trade.realTimeInfo.currency ?? "USD"
            )
        })
    }
    @ObservationIgnored private var livePriceSamples: [String: [PriceSnapshot]] = [:] {
        didSet { aliasHistoryCache.removeAll() }
    }
    @ObservationIgnored private var aliasHistoryCache = AliasPriceSnapshotCache()
    @ObservationIgnored var livePortfolioValueSamples: [ChartDataPoint] = []
    @ObservationIgnored private var livePortfolioGainSamples: [ChartDataPoint] = []
    /// Currency of the live portfolio samples (the menu-bar currency), which
    /// can differ from the main currency the stored snapshots use.
    @ObservationIgnored private var livePortfolioSampleCurrency: String?
    private let priceHistoryScheduler = HistoricalPriceFetchScheduler()
    @ObservationIgnored var folyncPortfolioHistoryContexts: [String: String] = [:]
    @ObservationIgnored var folyncPortfolioHistoryFetchRequestTimes: [String: Date] = [:]
    @ObservationIgnored var folyncPriceOverlays: [String: [PriceSnapshot]] = [:]
    @ObservationIgnored var folyncUnavailableSeries: Set<String> = []
    @ObservationIgnored var folyncPortfolioValueOverlays: [String: [ChartDataPoint]] = [:]
    @ObservationIgnored var folyncPortfolioGainOverlays: [String: [ChartDataPoint]] = [:]
    private let livePriceSampleRetention: TimeInterval = 7 * 24 * 60 * 60
    private let maxLivePriceSamplesPerSymbol = 1_000
    private let maxLivePortfolioSamples = 1_000
    let menuPriceHistoryFetchCooldown: TimeInterval = 10 * 60
    
    // In init() or a new method, add check for retroactive calculation:
    // This check would ideally be in DataModel or AppDelegate after migration completes.
    // For example, in DataModel.init() after ensuring migration service has run:
    // if DataMigrationService.shared.needsRetroactiveCalculation {
    //    Logger.shared.info("HistoricalDataManager: Triggering retroactive calculation due to migration flag.")
    //    Task {
    //        await self.historicalDataManager.calculateRetroactivePortfolioHistory(using: self)
    //        DataMigrationService.shared.needsRetroactiveCalculation = false // Clear the flag
    //    }
    // }

    private init() {
        self.coreDataService = CoreDataHistoricalDataService()
        loadHistoricalData()
        setupPeriodicSave()
    }
    
    // MARK: - Core Data Integration
    
    /// Load portfolio snapshots from Core Data
    func loadPortfolioSnapshotsFromCoreData(timeRange: ChartTimeRange) async -> [HistoricalPortfolioSnapshot] {
        do {
            let startDate = timeRange.startDate()
            let endDate = Date()
            await logger.info("📈 Loading portfolio snapshots from Core Data: startDate=\(startDate), endDate=\(endDate)")
            let snapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)
            await logger.info("📈 Loaded \(snapshots.count) portfolio snapshots from Core Data")
            return snapshots
        } catch {
            await logger.error("❌ Failed to load portfolio snapshots from Core Data: \(error)")
            return []
        }
    }

    /// Fetch historical portfolio snapshots for attribution analysis (preferred method - has position data)
    func fetchHistoricalPortfolioSnapshots(from startDate: Date, to endDate: Date) async -> [HistoricalPortfolioSnapshot] {
        do {
            let historicalSnapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)
            await logger.debug("📊 Fetched \(historicalSnapshots.count) historical portfolio snapshots for attribution analysis")
            return historicalSnapshots
        } catch {
            await logger.error("❌ Failed to fetch historical portfolio snapshots: \(error)")
            return []
        }
    }

    /// Fetch portfolio snapshots for a specific date range (legacy converted format)
    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async -> [PortfolioSnapshot] {
        do {
            // Fetch from Core Data
            let historicalSnapshots = try await coreDataService.fetchPortfolioSnapshots(from: startDate, to: endDate)

            // Convert HistoricalPortfolioSnapshot to PortfolioSnapshot format
            let portfolioSnapshots: [PortfolioSnapshot] = historicalSnapshots.map { historical in
                // Convert the positions to a PriceSnapshot array
                let priceSnapshots = historical.portfolioComposition.map { position -> PriceSnapshot in
                    PriceSnapshot(
                        timestamp: historical.date,
                        price: position.priceAtDate,
                        previousClose: position.priceAtDate, // We don't have previous close in PositionSnapshot
                        volume: nil,
                        symbol: position.symbol
                    )
                }

                return PortfolioSnapshot(
                    timestamp: historical.date,
                    totalValue: historical.totalValue,
                    totalGains: historical.totalGains,
                    currency: historical.currency,
                    priceSnapshots: priceSnapshots
                )
            }

            await logger.debug("📊 Fetched \(portfolioSnapshots.count) portfolio snapshots (legacy format)")
            return portfolioSnapshots
        } catch {
            await logger.error("❌ Failed to fetch portfolio snapshots: \(error)")
            return []
        }
    }
    
    /// Saves price snapshots to Core Data. Rows from a failed save are kept
    /// and written with the next one; memory already holds them, and without
    /// this they were lost at quit.
    private func savePriceSnapshotsToCoreData(_ snapshots: [PriceSnapshot]) async {
        let batch = unsavedPriceSnapshots + snapshots
        unsavedPriceSnapshots = []
        do {
            try await coreDataService.savePriceSnapshots(batch)
            await logger.debug("💾 Saved \(batch.count) price snapshots to Core Data")
        } catch {
            unsavedPriceSnapshots = Array((batch + unsavedPriceSnapshots).suffix(Self.maxUnsavedRows))
            await logger.error("❌ Failed to save price snapshots to Core Data; \(unsavedPriceSnapshots.count) kept for the next save: \(error)")
        }
    }

    /// Saves a portfolio snapshot to Core Data, with any left from failed saves.
    private func savePortfolioSnapshotToCoreData(_ snapshot: HistoricalPortfolioSnapshot) async {
        let batch = unsavedPortfolioSnapshots + [snapshot]
        unsavedPortfolioSnapshots = []
        for (index, pending) in batch.enumerated() {
            do {
                try await coreDataService.savePortfolioSnapshot(pending)
            } catch {
                unsavedPortfolioSnapshots = Array((batch[index...] + unsavedPortfolioSnapshots).suffix(Self.maxUnsavedRows))
                await logger.error("❌ Failed to save portfolio snapshot to Core Data; \(unsavedPortfolioSnapshots.count) kept for the next save: \(error)")
                return
            }
        }
        await logger.debug("💾 Saved portfolio snapshot to Core Data for \(snapshot.date)")
    }
    
    // MARK: - Cache

    private func storeInCache<T: Codable & Sendable>(_ data: T, key: String) {
        cacheManager.store(data, forKey: key)
    }
    
    /// Retrieve data from cache with fallback to UserDefaults for migration
    private func retrieveFromCache<T: Codable & Sendable>(_ type: T.Type, key: String) -> T? {
        // Try cache first
        if let cachedData = cacheManager.retrieve(type, forKey: key) {
            return cachedData
        }
        
        // Fallback to UserDefaults for backward compatibility during migration
        if let data = StockbarRuntimeStorage.userDefaults.data(forKey: key),
           let decoded = try? decoder.decode(type, from: data) {
            // Migrate to cache for future access
            storeInCache(decoded, key: key)
                            Task { await logger.debug("🔄 Migrated \(key) from UserDefaults to cache") }
            return decoded
        }
        
        return nil
    }
    
    /// Historical portfolio snapshots for a range. Filtering the in-memory
    /// array is cheap, and a cache here went stale (or stayed empty) whenever
    /// snapshots were loaded or merged without a new recording.
    func getHistoricalPortfolioSnapshots(timeRange: ChartTimeRange) -> [HistoricalPortfolioSnapshot] {
        let cutoffDate = timeRange.startDate()
        return historicalPortfolioSnapshots.filter { $0.date >= cutoffDate }
    }
    
    
    // MARK: - Performance Enhancement Methods
    
    
    func recordSnapshot(from dataModel: DataModel) {
        // Until the portfolio source (local, Trading 212 or Folync) is known, the holdings in
        // memory may be the old local list. A snapshot of those would store a false dip.
        guard dataModel.isInitialPortfolioSourceResolved else { return }
        let now = Date()
        let timeSinceLastSnapshot = now.timeIntervalSince(lastSnapshotTime)
        
        Task { await logger.debug("📸 Snapshot attempt: timeSinceLastSnapshot=\(Int(timeSinceLastSnapshot))s, required=\(Int(snapshotInterval))s") }
        
        guard Self.isSnapshotDue(elapsed: timeSinceLastSnapshot, interval: snapshotInterval) else {
            Task { await logger.debug("📸 Skipping snapshot - too soon (\(Int(timeSinceLastSnapshot))s < \(Int(snapshotInterval))s)") }
            return // Too soon since last snapshot
        }
        
        lastSnapshotTime = now
        Task { await logger.debug("📸 Recording snapshot at \(now)") }
        
        var currentPriceSnapshots: [PriceSnapshot] = []
        var changedPriceSnapshots: [PriceSnapshot] = []
        var hasValidData = false
        
        Task { await logger.debug("📸 Checking \(dataModel.realTimeTrades.count) trades for valid data") }
        
        for trade in dataModel.realTimeTrades {
            let price = trade.realTimeInfo.getCurrentDisplayPrice()
            let prevClose = trade.realTimeInfo.prevClosePrice

            Task { await logger.debug("📸 \(trade.trade.name): price=\(price), prevClose=\(prevClose), currency=\(trade.realTimeInfo.currency ?? "nil")") }

            guard !price.isNaN && !prevClose.isNaN && price > 0 else {
                Task { await logger.debug("📸 Skipping \(trade.trade.name) - invalid data") }
                continue // Skip invalid data
            }
            
            let snapshot = PriceSnapshot(
                timestamp: now,
                price: price,
                previousClose: prevClose,
                volume: nil,
                symbol: trade.trade.name
            )
            
            currentPriceSnapshots.append(snapshot)
            hasValidData = true

            let name = trade.trade.name
            guard Self.shouldRecordPrice(snapshot, after: lastRecordedPrice[name] ?? priceSnapshots[name]?.last) else {
                continue
            }
            lastRecordedPrice[name] = snapshot
            changedPriceSnapshots.append(snapshot)
            // `now` is normally the newest timestamp, so appending keeps the
            // history sorted without re-sorting thousands of rows per symbol.
            let needsSort = (priceSnapshots[name]?.last?.timestamp ?? .distantPast) > now
            priceSnapshots[name, default: []].append(snapshot)
            if needsSort {
                priceSnapshots[name]?.sort { $0.timestamp < $1.timestamp }
            }
        }
        
        guard hasValidData else {
            Task { await logger.debug("Skipping snapshot - no valid price data") }
            return
        }
        
        // Calculate portfolio metrics
        let gains = dataModel.calculateNetGains()
        let totalValue = calculateTotalPortfolioValue(from: dataModel)
        
        let portfolioSnapshot = PortfolioSnapshot(
            timestamp: now,
            totalValue: totalValue,
            totalGains: gains.amount,
            currency: gains.currency,
            priceSnapshots: currentPriceSnapshots
        )
        
        portfolioSnapshots.append(portfolioSnapshot)
        
        // Clean up old data
        cleanupOldData()
        
        // Save data to legacy storage
        saveHistoricalData()
        
        // Read the positions now: by the time the save runs the holdings may
        // have changed, and the snapshot must match the totals worked out above.
        let portfolioComposition = Self.storedPositions(from: dataModel.realTimeTrades)
        Task {
            await savePriceSnapshotsToCoreData(changedPriceSnapshots)

            // A portfolio of watch-only symbols has no value to record.
            guard !portfolioComposition.isEmpty else { return }
            let enhancedPortfolioSnapshot = HistoricalPortfolioSnapshot(
                date: now,
                totalValue: totalValue,
                totalGains: gains.amount,
                totalCost: totalValue - gains.amount,
                currency: gains.currency,
                portfolioComposition: portfolioComposition
            )
            
            await savePortfolioSnapshotToCoreData(enhancedPortfolioSnapshot)
        }
        
        Task { await logger.debug("Recorded portfolio snapshot: value=\(totalValue), gains=\(gains.amount) \(gains.currency)") }
        runStoreMaintenanceIfDue(heldSymbols: dataModel.realTimeTrades.map(\.trade.name), now: now)
    }

    /// Starts the weekly database upkeep and the daily change-history trim
    /// when they are due (see `StoreMaintenance`).
    private func runStoreMaintenanceIfDue(heldSymbols: [String], now: Date) {
        guard now >= nextStoreMaintenanceCheck else { return }
        nextStoreMaintenanceCheck = now.addingTimeInterval(3600)
        // With no holdings loaded there is no telling which symbols are in use.
        let held: Set<String>? = heldSymbols.isEmpty ? nil : Set(
            heldSymbols.flatMap { [$0] + instrumentAliasStore.aliases(for: $0) }.map { $0.uppercased() }
        )
        let launchedAt = storeMaintenanceStart
        Task.detached(priority: .background) {
            await StoreMaintenance.shared.runIfDue(heldSymbols: held, now: now)
            await StoreMaintenance.shared.purgeHistoryIfDue(launchedAt: launchedAt, now: now)
        }
    }

    /// Records a memory-only price point from live refresh/broker sync paths.
    /// This improves intraday menu charts without changing persistent snapshot cadence.
    func recordLivePriceSample(
        symbol: String,
        price: Double,
        previousClose: Double?,
        timestamp: Date = Date()
    ) {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbolKey.isEmpty, price.isFinite, price > 0 else {
            Task { await logger.debug("📈 Skipping live price sample for \(symbol) - invalid price \(price)") }
            return
        }

        let previousCloseValue: Double
        if let previousClose, previousClose.isFinite, previousClose > 0 {
            previousCloseValue = previousClose
        } else {
            previousCloseValue = price
        }

        let sample = PriceSnapshot(
            timestamp: timestamp,
            price: price,
            previousClose: previousCloseValue,
            volume: nil,
            symbol: symbolKey
        )

        var samples = livePriceSamples[symbolKey] ?? []
        if let last = samples.last, abs(last.timestamp.timeIntervalSince(timestamp)) < 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }

        let cutoff = timestamp.addingTimeInterval(-livePriceSampleRetention)
        samples = samples
            .filter { $0.timestamp >= cutoff && $0.price.isFinite && $0.price > 0 }
            .sorted { $0.timestamp < $1.timestamp }

        if samples.count > maxLivePriceSamplesPerSymbol {
            samples = Array(samples.suffix(maxLivePriceSamplesPerSymbol))
        }

        livePriceSamples[symbolKey] = samples
        notePriceDataChanged(for: symbolKey)
    }

    /// Records a memory-only portfolio value/gain point from live refresh paths.
    /// This keeps portfolio menu charts responsive without changing persistent snapshot cadence.
    func recordLivePortfolioSample(
        totalValue: Double,
        totalGains: Double,
        currency: String? = nil,
        timestamp: Date = Date()
    ) {
        guard totalValue.isFinite, totalValue > 0 else {
            Task { await logger.debug("📈 Skipping live portfolio sample - invalid value \(totalValue)") }
            return
        }

        if let currency, currency.uppercased() != livePortfolioSampleCurrency?.uppercased() {
            // Samples in different currencies cannot share one series.
            if livePortfolioSampleCurrency != nil {
                livePortfolioValueSamples.removeAll()
                livePortfolioGainSamples.removeAll()
            }
            livePortfolioSampleCurrency = currency
        }

        livePortfolioValueSamples = appendLivePortfolioPoint(
            ChartDataPoint(date: timestamp, value: totalValue),
            to: livePortfolioValueSamples,
            timestamp: timestamp
        )

        if totalGains.isFinite {
            livePortfolioGainSamples = appendLivePortfolioPoint(
                ChartDataPoint(date: timestamp, value: totalGains),
                to: livePortfolioGainSamples,
                timestamp: timestamp
            )
        }
    }

    /// Which portfolio figure a chart shows.
    private enum PortfolioSeries {
        case value
        case gains

        var folyncKind: String { self == .value ? "portfolio-value" : "portfolio-gain" }
        var label: String { self == .value ? "value" : "gains" }
    }

    /// The portfolio chart's sources, in the order they are tried:
    ///
    /// 1. Folync's own series, when Folync is the portfolio source.
    /// 2. Stored portfolio snapshots, when they cover the range (more than
    ///    ten points, or any at all for the day and week ranges).
    /// 3. Stored snapshots however few, while a recalculation is started in
    ///    the background (at most hourly).
    /// 4. The values of the last recalculation, for half an hour after it.
    /// 5. The snapshots recorded this session, forcing one for the day range
    ///    when there are none.
    private func portfolioChartData(
        _ series: PortfolioSeries,
        timeRange: ChartTimeRange,
        dataModel: DataModel?,
        customFrom: Date?,
        customTo: Date?
    ) -> [ChartDataPoint] {
        // 1. Folync.
        if let routed = folyncPortfolioOverlay(
            kind: series.folyncKind,
            timeRange: timeRange,
            dataModel: dataModel,
            customFrom: customFrom,
            customTo: customTo
        ) {
            return routed
        }

        func stored(currency: String?) -> [ChartDataPoint] {
            switch series {
            case .value:
                return getStoredPortfolioValues(
                    for: timeRange, currency: currency, customFrom: customFrom, customTo: customTo
                )
            case .gains:
                return getStoredPortfolioGains(
                    for: timeRange, currency: currency, customFrom: customFrom, customTo: customTo
                )
            }
        }
        let label = series.label

        // 2. Stored snapshots with good coverage.
        if !historicalPortfolioSnapshots.isEmpty {
            let data = stored(currency: dataModel?.preferredCurrency)
            Task { await logger.debug("📊 Portfolio \(label) chart data: \(data.count) stored portfolio points for range \(timeRange.rawValue)") }
            if data.count > 10 || timeRange == .day || timeRange == .week {
                return data
            }
        }

        // 3. Start a recalculation and show what is stored meanwhile.
        if let dataModel {
            let timeSinceLastRetroactive = Date().timeIntervalSince(lastRetroactiveCalculationDate)
            // A chart drawn while the store is still loading sees no history and no
            // holdings. Calculating then would record an empty portfolio as the
            // current one, and the next launch-time check would rebuild everything.
            let storeIsLoaded = dataModel.hasCompletedInitialTradeLoad && hasLoadedStoredPortfolioHistory
            if storeIsLoaded, timeSinceLastRetroactive > 3600 || historicalPortfolioSnapshots.isEmpty {
                Task { await logger.info("📊 Portfolio \(label) chart: Triggering background retroactive calculation") }
                Task.detached(priority: .background) { [self] in
                    await self.calculateRetroactivePortfolioHistory(using: dataModel)
                }
            }
            if !historicalPortfolioSnapshots.isEmpty {
                return stored(currency: dataModel.preferredCurrency)
            }
        }

        // 4. The last recalculation's values.
        let startDate = timeRange.startDate(from: Date())
        let timeSinceLastCalculation = Date().timeIntervalSince(lastPortfolioCalculationDate)
        if !cachedHistoricalPortfolioValues.isEmpty && timeSinceLastCalculation < portfolioCalculationCacheInterval {
            let values = cachedHistoricalPortfolioValues
                .filter { $0.date >= startDate }
                .sorted { $0.date < $1.date }
            let data = series == .value ? values : calculateHistoricalGains(from: values, dataModel: dataModel)
            Task { await logger.debug("📊 Portfolio \(label) chart data: \(data.count) legacy cached points for range \(timeRange.rawValue)") }
            return data
        }

        // 5. This session's snapshots.
        func sessionPoints() -> [ChartDataPoint] {
            portfolioSnapshots
                .filter { $0.timestamp >= startDate }
                .map { ChartDataPoint(date: $0.timestamp, value: series == .value ? $0.totalValue : $0.totalGains) }
                .sorted { $0.date < $1.date }
        }
        let data = sessionPoints()
        Task { await logger.debug("📊 Portfolio \(label) chart data: \(data.count) real-time fallback points for range \(timeRange.rawValue)") }

        // Not while the store is still loading: the snapshot would be taken from
        // an empty holdings list.
        if data.isEmpty && timeRange == .day, let dataModel,
           dataModel.hasCompletedInitialTradeLoad, hasLoadedStoredPortfolioHistory {
            Task { await logger.info("📊 No 1-day portfolio \(label) data available, forcing snapshot creation") }
            forceSnapshot(from: dataModel)
            let newData = sessionPoints()
            Task { await logger.debug("📊 Portfolio \(label) chart data after forced snapshot: \(newData.count) points") }
            return newData
        }
        return data
    }

    func getChartData(
        for type: ChartType,
        timeRange: ChartTimeRange,
        dataModel: DataModel? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        switch type {
        case .portfolioValue:
            return portfolioChartData(
                .value, timeRange: timeRange, dataModel: dataModel, customFrom: customFrom, customTo: customTo
            )

        case .portfolioGains:
            return portfolioChartData(
                .gains, timeRange: timeRange, dataModel: dataModel, customFrom: customFrom, customTo: customTo
            )

        case .individualStock(let symbol):
            let endDate = timeRange == .custom ? (customTo ?? Date()) : Date()
            let startDate = timeRange == .custom
                ? (customFrom ?? timeRange.startDate(from: endDate))
                : timeRange.startDate(from: endDate)
            return getOptimalStockData(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate,
                dataModel: dataModel
            )
        }
    }
    
    /// Gets stock data for charts with increased data limits and caching
    private func getOptimalStockData(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date,
        dataModel: DataModel?
    ) -> [ChartDataPoint] {
        // Rolling ranges end "now", so their dates must not be part of the key
        // (it changed every second and the cache grew without bound).
        let cacheKey = timeRange == .custom
            ? "\(symbol)-\(timeRange.rawValue)-\(Int(startDate.timeIntervalSince1970))-\(Int(endDate.timeIntervalSince1970))"
            : "\(symbol)-\(timeRange.rawValue)"
        let folyncEnabled = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        let folyncRouteApplies = folyncEnabled
            && dataModel?.folyncCapabilities?.isTrackedOrAllowlisted(symbol) == true
        let folyncSeriesKeys = folyncLineSeriesKeys(
            for: symbol,
            timeRange: timeRange,
            customFrom: timeRange == .custom ? startDate : nil,
            customTo: timeRange == .custom ? endDate : nil
        )
        let folyncStatus = folyncSeriesKeys.compactMap { folyncSourceStatusBySeries[$0] }.first

        if folyncEnabled {
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate
            )
        }
        
        // Check cache first
        if !folyncRouteApplies || folyncStatus != nil,
           let cachedData = stockDataCache[cacheKey],
           let cacheTime = stockDataCacheTimestamp[cacheKey],
           Date().timeIntervalSince(cacheTime) < stockDataCacheInterval {
            Task { await logger.debug("📊 CACHE HIT: Stock data for \(symbol) \(timeRange.rawValue): \(cachedData.count) points") }
            return cachedData
        }
        
        let allSnapshots = folyncRouteApplies && folyncStatus == nil
            ? []
            : aliasAwarePriceSnapshots(for: symbol, folyncSeriesKeys: folyncSeriesKeys)
        
        // Filter and convert to chart data points
        let filteredData = allSnapshots
            .filter { $0.timestamp >= startDate && (timeRange != .custom || $0.timestamp <= endDate) }
            .map { ChartDataPoint(date: $0.timestamp, value: $0.price, symbol: symbol) }
            .sorted { $0.date < $1.date }
        
        Task { await logger.debug("📊 CACHE MISS: Stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count) points") }
        
        // Cache the result, dropping expired entries first.
        let now = Date()
        for (key, cachedAt) in stockDataCacheTimestamp where now.timeIntervalSince(cachedAt) >= stockDataCacheInterval {
            stockDataCache.removeValue(forKey: key)
            stockDataCacheTimestamp.removeValue(forKey: key)
        }
        stockDataCache[cacheKey] = filteredData
        stockDataCacheTimestamp[cacheKey] = now
        
        // Check if we have insufficient data for the requested time range
        let minimumExpectedDataPoints = getExpectedDataPointsForTimeRange(timeRange)
        let hasInsufficientData = filteredData.count < minimumExpectedDataPoints
        
        // Trigger historical data fetching if we don't have enough data
        if hasInsufficientData {
            Task { await logger.info("📊 Insufficient stock data for \(symbol) \(timeRange.rawValue): \(filteredData.count)/\(minimumExpectedDataPoints) points. Triggering historical data fetch.") }
            schedulePriceHistoryFetchIfNeeded(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate
            )
        }
        
        return filteredData
    }
    
    /// Determines expected minimum data points for a time range
    private func getExpectedDataPointsForTimeRange(_ timeRange: ChartTimeRange) -> Int {
        switch timeRange {
        case .day:
            return 10  // Expect at least 10 data points for a day
        case .week:
            return 30  // Expect at least 30 data points for a week
        case .month:
            return 60  // Expect at least 60 data points for a month
        case .threeMonths:
            return 100 // Expect at least 100 data points for 3 months
        case .sixMonths:
            return 150 // Expect at least 150 data points for 6 months
        case .year:
            return 200 // Expect at least 200 data points for a year
        case .all:
            return 300 // Expect at least 300 data points for all time
        case .custom:
            return 60  // Default expectation for custom range (similar to month)
        }
    }
    
    /// Triggers historical data fetching for a specific symbol and time range
    func triggerHistoricalDataFetch(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date = Date(),
        folyncConfigurationRevision: Int? = nil
    ) async -> HistoricalPriceFetchOutcome {
        guard !Task.isCancelled,
              folyncConfigurationRevision == nil || folyncConfigurationRevision == self.folyncSupplementalConfigurationRevision
        else { return .cancelled }
        await logger.info("🔄 Starting historical data fetch for \(symbol) from \(startDate)")

        if FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts) {
            let result = await FolyncSupplementalCoordinator.shared.routeLineHistory(
                symbol: symbol,
                range: timeRange.folyncRange,
                from: timeRange == .custom ? startDate : nil,
                to: timeRange == .custom ? endDate : nil
            )
            if let folyncConfigurationRevision,
               folyncConfigurationRevision != self.folyncSupplementalConfigurationRevision {
                await logger.info("Discarding superseded Folync history response for \(symbol)")
                return .cancelled
            }
            switch result {
            case .folync(let snapshots, let status, let identity, let metadata):
                setFolyncPriceOverlay(
                    snapshots,
                    identity: identity,
                    requestedSymbol: symbol,
                    status: status,
                    metadata: metadata,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
                await logger.info("Using \(snapshots.count) non-persisted \(status.label) line-chart points for \(symbol)")
                return .success
            case .unavailable:
                markFolyncSeriesUnavailable(
                    symbol,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
                await logger.warning("Folync line history is unavailable for \(symbol); local fallback is disabled")
                return .failed
            case .legacy:
                clearFolyncPriceOverlayForLegacy(
                    symbol,
                    timeRange: timeRange,
                    customFrom: timeRange == .custom ? startDate : nil,
                    customTo: timeRange == .custom ? endDate : nil
                )
            }
        }
        
        // Use NetworkService to fetch historical data
        guard let networkService = getNetworkService() else {
            await logger.error("❌ Cannot fetch historical data: NetworkService not available")
            return .failed
        }
        
        do {
            let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
            guard !Task.isCancelled,
                  folyncConfigurationRevision == nil || folyncConfigurationRevision == self.folyncSupplementalConfigurationRevision
            else { return .cancelled }
            
            await logger.info("📥 Received \(historicalData.count) historical data points for \(symbol)")
            
            if !historicalData.isEmpty {
                // Add the historical data to our cache
                addImportedSnapshots(historicalData, for: symbol)
                await logger.info("✅ Successfully added \(historicalData.count) historical data points for \(symbol)")
            } else {
                await logger.warning("⚠️ No historical data received for \(symbol)")
            }
            return historicalData.isEmpty ? .empty : .success
        } catch NetworkError.noData {
            await logger.info("No history available for \(symbol) in the requested interval; delaying automatic retry")
            return .empty
        } catch is CancellationError {
            return .cancelled
        } catch {
            await logger.error("❌ Failed to fetch historical data for \(symbol): \(error.localizedDescription)")
            return .failed
        }
    }
    
    /// The one quote service the app uses, shared with `DataModel`.
    private func getNetworkService() -> NetworkService? {
        PythonNetworkService.shared
    }
    
    /// Start and end of a portfolio chart range; `.custom` uses the user's dates.
    func portfolioRangeBounds(
        for timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        guard timeRange == .custom, let customFrom else {
            return (timeRange.startDate(from: now), now)
        }
        return (customFrom, min(customTo ?? now, now))
    }

    /// Metrics for the series the portfolio chart draws: recorded snapshots
    /// plus this session's live samples, falling back to session snapshots.
    func getPerformanceMetrics(
        for timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil,
        currency: String? = nil,
        now: Date = Date()
    ) -> PerformanceMetrics? {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo, now: now)
        let seriesCurrency = currency ?? historicalPortfolioSnapshots.last?.currency
        var points = storedAndLivePortfolioValues(from: bounds.start, to: bounds.end, currency: seriesCurrency)
            .filter { $0.value.isFinite && $0.value > 0 }
        var previousPoint = storedAndLivePortfolioValues(from: .distantPast, to: bounds.start, currency: seriesCurrency)
            .last { $0.value.isFinite && $0.value > 0 && $0.date < bounds.start }
        var metricsCurrency = seriesCurrency
        if points.isEmpty {
            let session = portfolioSnapshots.sorted { $0.timestamp < $1.timestamp }
            points = session
                .filter { $0.timestamp >= bounds.start && $0.timestamp <= bounds.end && $0.totalValue.isFinite && $0.totalValue > 0 }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
            previousPoint = session
                .last { $0.timestamp < bounds.start && $0.totalValue.isFinite && $0.totalValue > 0 }
                .map { ChartDataPoint(date: $0.timestamp, value: $0.totalValue) }
            metricsCurrency = metricsCurrency ?? session.last?.currency
        }
        return Self.performanceMetrics(points: points, previousPoint: previousPoint, currency: metricsCurrency ?? "USD")
    }

    /// Calculates maximum drawdown for individual stock prices
    private func calculateStockMaxDrawdown(snapshots: [PriceSnapshot]) -> (maxDrawdown: Double?, maxDrawdownPercent: Double?) {
        guard snapshots.count > 1 else { return (nil, nil) }
        
        var maxDrawdown: Double = 0
        var maxDrawdownPercent: Double = 0
        var peak: Double = snapshots.first?.price ?? 0
        
        for snapshot in snapshots {
            let currentPrice = snapshot.price
            
            // Update peak if we have a new high
            if currentPrice > peak {
                peak = currentPrice
            }
            
            // Calculate drawdown from peak
            let drawdown = peak - currentPrice
            let drawdownPercent = peak > 0 ? (drawdown / peak) * 100 : 0
            
            // Update maximum drawdown
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                maxDrawdownPercent = drawdownPercent
            }
        }
        
        return (maxDrawdown, maxDrawdownPercent)
    }
    
    /// Gets performance metrics for an individual stock symbol
    /// `customFrom` and `customTo` (exclusive) bound a Custom range; without
    /// them a Custom range fell back to the last 30 days.
    func getStockPerformanceMetrics(
        for symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> PerformanceMetrics? {
        let stockSnapshots = aliasAwarePriceSnapshots(
            for: symbol,
            folyncSeriesKeys: folyncLineSeriesKeys(
                for: symbol, timeRange: timeRange, customFrom: customFrom, customTo: customTo
            )
        )
        guard !stockSnapshots.isEmpty else { return nil }
        
        let startDate = customFrom ?? timeRange.startDate(from: Date())
        let endDate = customTo ?? .distantFuture
        let relevantSnapshots = stockSnapshots
            .filter { $0.timestamp >= startDate && $0.timestamp < endDate }
            .sorted { $0.timestamp < $1.timestamp }
        
        guard let firstSnapshot = relevantSnapshots.first,
              let lastSnapshot = relevantSnapshots.last else {
            return nil
        }
        
        // For single day or very short periods, compare with previous day if available
        let totalReturn: Double
        let totalReturnPercent: Double
        
        if relevantSnapshots.count == 1 {
            // Single snapshot - compare with the most recent snapshot before the time range
            let previousSnapshots = stockSnapshots.filter { $0.timestamp < startDate }.sorted { $0.timestamp < $1.timestamp }
            if let previousSnapshot = previousSnapshots.last {
                totalReturn = lastSnapshot.price - previousSnapshot.price
                totalReturnPercent = (totalReturn / previousSnapshot.price) * 100
            } else {
                totalReturn = 0
                totalReturnPercent = 0
            }
        } else {
            totalReturn = lastSnapshot.price - firstSnapshot.price
            totalReturnPercent = (totalReturn / firstSnapshot.price) * 100
        }
        
        // Calculate daily returns for advanced metrics
        // One close per weekday. The stored samples are minutes apart, and treating each as a
        // day understated volatility and counted every unchanged sample as a losing day.
        let closes = RiskMetricsService.dailyCloses(
            dates: relevantSnapshots.map(\.timestamp),
            values: relevantSnapshots.map(\.price)
        ).values
        let dailyReturns = zip(closes.dropFirst(), closes).map { current, previous in
            (current - previous) / previous
        }
        
        let statistics = ReturnStatistics(dailyReturns: dailyReturns)
        
        let maxValue = relevantSnapshots.map { $0.price }.max() ?? lastSnapshot.price
        let minValue = relevantSnapshots.map { $0.price }.min() ?? lastSnapshot.price
        
        // Determine currency for the stock
        let currency = SymbolMetadata.defaultCurrency(for: symbol)
        
        // Calculate Maximum Drawdown
        let (maxDrawdown, maxDrawdownPercent) = calculateStockMaxDrawdown(snapshots: relevantSnapshots)
        
        // Calculate Annualized Return and Volatility
        // Compounded, and only for a month or more: scaling a one-day move to a year
        // turned +1% into +365%.
        let span = lastSnapshot.timestamp.timeIntervalSince(firstSnapshot.timestamp)
        let periodInYears = span / (365.25 * 24 * 3600)
        let compounded = (pow(1 + totalReturnPercent / 100, 1 / max(periodInYears, 0.001)) - 1) * 100
        let annualizedReturn: Double? = span >= 30 * 86_400 && compounded.isFinite ? compounded : nil
        // Beta calculation would require market benchmark data - set to nil for now
        let beta: Double? = nil
        
        return PerformanceMetrics(
            totalReturn: totalReturn,
            totalReturnPercent: totalReturnPercent,
            volatility: statistics.volatility,
            maxValue: maxValue,
            minValue: minValue,
            currency: currency,
            startDate: firstSnapshot.timestamp,
            endDate: lastSnapshot.timestamp,
            sharpeRatio: statistics.sharpeRatio,
            maxDrawdown: maxDrawdown,
            maxDrawdownPercent: maxDrawdownPercent,
            beta: beta,
            annualizedReturn: annualizedReturn,
            annualizedVolatility: statistics.annualizedVolatility,
            valueAtRisk: statistics.valueAtRisk,
            winRate: statistics.winRate
        )
    }
    
    private func calculateTotalPortfolioValue(from dataModel: DataModel) -> Double {
        // Use the same calculation method as DataModel.calculateNetValue() to ensure consistency
        let netValue = dataModel.calculateNetValue()
        
        // The DataModel already handles all currency conversions and preferred currency logic
        // We just need to extract the numeric amount
        return netValue.amount
    }
    
    private func cleanupOldData() {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        // Stock history is bounded by resolution below, so a large total is
        // expected after long backfills. The total only sets how many session
        // portfolio snapshots (the fallback chart series) are kept.
        let targetLimit: Int
        if totalSnapshots > 40000 {
            targetLimit = 1500
        } else if totalSnapshots > 20000 {
            targetLimit = 2000
        } else {
            targetLimit = maxDataPoints
        }

        if portfolioSnapshots.count > targetLimit {
            let previousCount = portfolioSnapshots.count
            portfolioSnapshots = Array(portfolioSnapshots.suffix(targetLimit))
            Task {
                await logger.debug(
                    "📊 Trimmed session portfolio snapshots from \(previousCount) to \(targetLimit) (stock history total: \(totalSnapshots))"
                )
            }
        }

        // Bound stock history by resolution, not count, so long backfills survive.
        for symbol in priceSnapshots.keys {
            if let snapshots = priceSnapshots[symbol] {
                let thinned = Self.thinnedPriceHistory(snapshots)
                if thinned.count != snapshots.count {
                    priceSnapshots[symbol] = thinned
                    Task { await logger.debug("📊 Thinned \(symbol) from \(snapshots.count) to \(thinned.count) snapshots") }
                }
            }
        }
        
        let newTotal = priceSnapshots.values.map { $0.count }.reduce(0, +)
        if newTotal != totalSnapshots {
            Task { await logger.info("📊 Data cleanup completed: \(totalSnapshots) → \(newTotal) snapshots") }
        }
    }
    
    
    private func loadHistoricalData() {
        Task { await logger.info("HistoricalDataManager: Loading historical data...") }
        let migrationService = DataMigrationService.shared // Assuming it's accessible or passed

        // Core Data version where PriceSnapshotEntity and PortfolioSnapshotEntity are considered mastered
        let coreDataMasterVersion = 3

        if migrationService.migrationVersionStored >= coreDataMasterVersion {
            Task {
                await logger.info("HistoricalDataManager: Prioritizing Core Data for snapshots (version \(migrationService.migrationVersionStored)).")

                // Core Data is the store of record; load each symbol's history.
                await self.reloadStoredPriceHistory()

                // Load portfolio snapshots from Core Data
                let coreDataPortfolioSnaps = Self.thinnedPortfolioHistory(
                    await loadPortfolioSnapshotsFromCoreData(timeRange: .all)
                )
                await MainActor.run {
                    self.historicalPortfolioSnapshots = coreDataPortfolioSnaps
                    self.hasLoadedStoredPortfolioHistory = true
                }
                await logger.info("HistoricalDataManager: Loaded \(self.historicalPortfolioSnapshots.count) historical portfolio snapshots from Core Data.")
            }
        } else {
            Task { await logger.info("HistoricalDataManager: Falling back to CacheManager/UserDefaults for snapshots (migration version \(migrationService.migrationVersionStored)).") }
            // Legacy loading from CacheManager / UserDefaults
            self.priceSnapshots = retrieveFromCache([String: [PriceSnapshot]].self, key: StorageKeys.priceSnapshots) ?? [:]
            self.historicalPortfolioSnapshots = retrieveFromCache([HistoricalPortfolioSnapshot].self, key: StorageKeys.historicalPortfolioSnapshots) ?? []
            self.hasLoadedStoredPortfolioHistory = true
            // Also load legacy portfolioSnapshots if necessary for compatibility or if historicalPortfolioSnapshots is empty
            if self.historicalPortfolioSnapshots.isEmpty {
                 self.portfolioSnapshots = retrieveFromCache([PortfolioSnapshot].self, key: StorageKeys.portfolioSnapshots) ?? []
                 // Potentially convert these legacy ones if needed, though migration should handle this.
            }
        }

        // Load metadata (still useful from CacheManager/UserDefaults)
        currentPortfolioComposition = retrieveFromCache(PortfolioComposition.self, key: StorageKeys.currentPortfolioComposition)
        if currentPortfolioComposition != nil {
            Task { await logger.info("HistoricalDataManager: Loaded current portfolio composition") }
        }
        
        // Load last retroactive calculation date
        lastRetroactiveCalculationDate = retrieveFromCache(Date.self, key: StorageKeys.lastRetroactiveCalculationDate) ?? Date.distantPast
        if lastRetroactiveCalculationDate != Date.distantPast {
            Task { await logger.info("HistoricalDataManager: Last retroactive calculation: \(DateFormatter.debug.string(from: lastRetroactiveCalculationDate))") }
        }
        
        // Load cached historical portfolio values (legacy)
        cachedHistoricalPortfolioValues = retrieveFromCache([ChartDataPoint].self, key: StorageKeys.cachedHistoricalPortfolioValues) ?? []
        Task { await logger.info("HistoricalDataManager: Loaded \(cachedHistoricalPortfolioValues.count) cached portfolio values (legacy)") }
        
        // Load last portfolio calculation date (legacy)
        lastPortfolioCalculationDate = retrieveFromCache(Date.self, key: StorageKeys.lastPortfolioCalculationDate) ?? Date.distantPast
        if lastPortfolioCalculationDate != Date.distantPast {
            Task { await logger.info("HistoricalDataManager: Last portfolio calculation: \(DateFormatter.debug.string(from: lastPortfolioCalculationDate)) (legacy)") }
        }

        earliestAvailableDates = retrieveFromCache([String: Date].self, key: StorageKeys.earliestAvailableDates) ?? [:]
        if !earliestAvailableDates.isEmpty {
            Task { await logger.info("HistoricalDataManager: Loaded earliest available dates for \(earliestAvailableDates.count) symbols") }
        }
        
        let totalSnaps = priceSnapshots.values.reduce(0) { $0 + $1.count }
        Task { await logger.info("HistoricalDataManager: Loaded. Price snapshots in memory: \(totalSnaps). Historical portfolio snapshots in memory: \(historicalPortfolioSnapshots.count). Legacy portfolio snapshots in memory: \(portfolioSnapshots.count).") }
    }
    
    func saveHistoricalData() {
        // Core Data is now the primary store for snapshot arrays.
        // New snapshots are saved to Core Data directly in recordSnapshot().
        // This method will now focus on saving metadata or non-CoreData state
        // that HistoricalDataManager itself manages.

        let currentPortfolioComposition = self.currentPortfolioComposition // capture for async
        let currentRetroactiveCalculationDate = self.lastRetroactiveCalculationDate
        let currentCalculationDate = self.lastPortfolioCalculationDate
        // The large arrays like self.priceSnapshots and self.historicalPortfolioSnapshots
        // are primarily reflections of Core Data or temporary caches, so we might not
        // persist them back to CacheManager if Core Data is the source of truth.
        // However, if they contain data not yet in Core Data (e.g. from a failed save),
        // then saving them via CacheManager might be a temporary backup.
        // For this iteration, let's assume Core Data saves are robust and CacheManager
        // is for metadata or as a staging area if Core Data fails.

        Task.detached(priority: .utility) { [weak self, encoder, logger] in
            guard let self = self else { return }
            
            // Save metadata and non-CoreData state to CacheManager
            if let composition = currentPortfolioComposition {
                await self.saveToTieredCache(portfolioComposition: composition,
                                       retroactiveCalculationDate: currentRetroactiveCalculationDate,
                                       calculationDate: currentCalculationDate)
            } else {
                 await self.saveToTieredCache(portfolioComposition: nil,
                                       retroactiveCalculationDate: currentRetroactiveCalculationDate,
                                       calculationDate: currentCalculationDate)
            }

            // We are removing the direct saving of large snapshot arrays to CacheManager here,
            // assuming they are mastered in Core Data.
            // If CacheManager was used as a staging area before Core Data saving,
            // that logic would need to be more explicit.

            // UserDefaults backup for metadata. This runs after every snapshot,
            // so write only what changed: any write rewrites the whole file.
            let defaults = StockbarRuntimeStorage.userDefaults
            let compositionData = try? currentPortfolioComposition.map { try encoder.encode($0) }
            if defaults.data(forKey: StorageKeys.currentPortfolioComposition) != compositionData {
                if let compositionData {
                    defaults.set(compositionData, forKey: StorageKeys.currentPortfolioComposition)
                } else if currentPortfolioComposition == nil {
                    defaults.removeObject(forKey: StorageKeys.currentPortfolioComposition)
                }
            }
            if defaults.object(forKey: StorageKeys.lastRetroactiveCalculationDate) as? Date != currentRetroactiveCalculationDate {
                defaults.set(currentRetroactiveCalculationDate, forKey: StorageKeys.lastRetroactiveCalculationDate)
            }
            if defaults.object(forKey: StorageKeys.lastPortfolioCalculationDate) as? Date != currentCalculationDate {
                defaults.set(currentCalculationDate, forKey: StorageKeys.lastPortfolioCalculationDate)
            }
            // Avoid saving large snapshot arrays to UserDefaults directly
            
            Task { await logger.debug("HistoricalDataManager: Saved metadata to CacheManager and UserDefaults backup.") }
        }
    }

    // Simplified saveToTieredCache to only handle metadata for this example
    private func saveToTieredCache(
        portfolioComposition: PortfolioComposition?,
        retroactiveCalculationDate: Date,
        calculationDate: Date
    ) async {
        if let composition = portfolioComposition {
            // Written to the disk tier: a memory-only write left an older disk copy in place,
            // which the next launch read first and took for a changed portfolio.
            storeInCache(composition, key: StorageKeys.currentPortfolioComposition)
        } else {
            // If composition is nil, consider removing it from cache or storing a representation of nil
            // For now, we just don't store it if it's nil. A remove(forKey:) might be better.
            cacheManager.remove(forKey: StorageKeys.currentPortfolioComposition)
        }
        storeInCache(retroactiveCalculationDate, key: StorageKeys.lastRetroactiveCalculationDate)
        storeInCache(calculationDate, key: StorageKeys.lastPortfolioCalculationDate)
        if !earliestAvailableDates.isEmpty {
            storeInCache(earliestAvailableDates, key: StorageKeys.earliestAvailableDates)
        }
        
        Task { await logger.debug("HistoricalDataManager: Metadata saved to tiered cache.") }
    }

    // The old saveToTieredCache that handled snapshot arrays would need to be adjusted or removed
    // if snapshot arrays are no longer persisted this way.
    // For this subtask, we assume the new simpler one above.
    
    private func setupPeriodicSave() {
        // Save data every 30 minutes to avoid too frequent writes
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveHistoricalData()
            }
        }
        
        // Perform aggressive cleanup every 6 hours to maintain optimal performance
        Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in
            Task {
                await self?.performPeriodicMaintenance()
            }
        }
    }
    
    private func performPeriodicMaintenance() async {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        if totalSnapshots > 30000 {
            await logger.info("📊 Performing periodic maintenance on \(totalSnapshots) snapshots") 
            
            // Force more aggressive cleanup during maintenance
            // Temporarily reduce limits for maintenance cleanup
            for symbol in priceSnapshots.keys {
                if let snapshots = priceSnapshots[symbol] {
                    priceSnapshots[symbol] = Self.thinnedPriceHistory(snapshots)
                }
            }
            
            if portfolioSnapshots.count > 1800 {
                portfolioSnapshots = Array(portfolioSnapshots.suffix(1800))
            }
            
            let newTotal = priceSnapshots.values.map { $0.count }.reduce(0, +)
            await logger.info("📊 Maintenance cleanup: \(totalSnapshots) → \(newTotal) snapshots") 
            
            // Clear cached calculations to force recalculation with clean data
            cachedHistoricalPortfolioValues.removeAll()
            lastPortfolioCalculationDate = Date.distantPast
            
            saveHistoricalData()
        }
    }
    
    func earliestAvailableDate(for symbol: String) -> Date? {
        earliestAvailableDates[symbol.uppercased()]
    }

    func recordEarliestAvailableDate(_ date: Date, for symbol: String) {
        let key = symbol.uppercased()
        if let existing = earliestAvailableDates[key], existing >= date {
            return
        }
        earliestAvailableDates[key] = date
        storeInCache(earliestAvailableDates, key: StorageKeys.earliestAvailableDates)
        Task { await logger.info("HistoricalDataManager: Recorded earliest available date for \(symbol): \(DateFormatter.debug.string(from: date))") }
    }
    
    func forceSnapshot(from dataModel: DataModel) {
        Task { await logger.info("🔧 FORCING snapshot for debugging") }
        
        // Temporarily bypass the interval check
        lastSnapshotTime = Date.distantPast
        recordSnapshot(from: dataModel)
        
        Task { await logger.info("🔧 Forced snapshot complete. Portfolio snapshots: \(portfolioSnapshots.count), Price snapshots: \(priceSnapshots.count)") }
    }
    
    
    
    /// Adds imported historical snapshots while avoiding duplicates
    func addImportedSnapshots(_ snapshots: [PriceSnapshot], for symbol: String) {
        Task { await logger.debug("Adding \(snapshots.count) imported snapshots for \(symbol)") }
        
        if priceSnapshots[symbol] == nil {
            priceSnapshots[symbol] = []
        }
        
        // Filter exact timestamp duplicates while preserving same-day backfills.
        let existingTimestampKeys = Set(
            priceSnapshots[symbol]?.map { snapshotTimestampKey($0.timestamp) } ?? []
        )

        Task { await logger.debug("🔍 DUPLICATE FILTER: \(symbol) has \(existingTimestampKeys.count) existing timestamps") }

        let newSnapshots = snapshots.filter { snapshot in
            !existingTimestampKeys.contains(snapshotTimestampKey(snapshot.timestamp))
        }
        
        Task { await logger.debug("🔍 DUPLICATE FILTER: Filtered \(snapshots.count) snapshots down to \(newSnapshots.count) new snapshots for \(symbol)") }
        
        if !newSnapshots.isEmpty {
            priceSnapshots[symbol]?.append(contentsOf: newSnapshots)
            
            // Sort by timestamp to maintain chronological order
            priceSnapshots[symbol]?.sort { $0.timestamp < $1.timestamp }
            
            if let current = priceSnapshots[symbol] {
                priceSnapshots[symbol] = Self.thinnedPriceHistory(current)
            }

            // Persist the imported history; saveHistoricalData stores metadata only.
            // The Core Data save skips timestamps it already has.
            let toPersist = newSnapshots
            Task { await self.savePriceSnapshotsToCoreData(toPersist) }
            saveHistoricalData()
            notePriceDataChanged(for: symbol)
            
            Task { await logger.info("Added \(newSnapshots.count) new historical snapshots for \(symbol) (filtered from \(snapshots.count) total)") }
            
            // Invalidate portfolio cache when new historical data is added
            cachedHistoricalPortfolioValues.removeAll()
            lastPortfolioCalculationDate = Date.distantPast
            Task { await logger.debug("📊 Invalidated portfolio cache due to new historical data for \(symbol)") }
        } else {
            Task { await logger.debug("No new snapshots to add for \(symbol) - all would be duplicates") }
        }
    }
    
    
    
    /// Calculates historical portfolio values for a specific time period
    private func calculateHistoricalPortfolioValuesForPeriod(from startDate: Date, to endDate: Date, using dataModel: DataModel) async -> [ChartDataPoint] {
        let input = HistoricalPortfolioCalculationInput(
            startDate: startDate,
            endDate: endDate,
            priceSnapshots: storedPriceSnapshots(resolvingAliasesFor: dataModel.realTimeTrades.map { $0.trade.name }),
            composition: createPortfolioComposition(from: dataModel),
            preferredCurrency: dataModel.preferredCurrency
        )
        let startTime = Date()
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)
        await logger.debug(
            "📊 PERIOD CALC: Generated \(snapshots.count) values from " +
            "\(DateFormatter.debug.string(from: startDate)) to \(DateFormatter.debug.string(from: endDate)) " +
            "off the main actor in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s"
        )
        return snapshots.map { ChartDataPoint(date: $0.date, value: $0.totalValue) }
    }
    
    /// Calculates historical gains from portfolio values by subtracting total investment cost
    private func calculateHistoricalGains(from portfolioValues: [ChartDataPoint], dataModel: DataModel?) -> [ChartDataPoint] {
        guard let dataModel = dataModel else { return [] }
        
        // Calculate total investment cost (what the user paid)
        let totalInvestmentCost = calculateTotalInvestmentCost(dataModel: dataModel)
        
        // Convert portfolio values to gains by subtracting the investment cost
        let gainsData = portfolioValues.map { portfolioValue in
            let gains = portfolioValue.value - totalInvestmentCost
            return ChartDataPoint(date: portfolioValue.date, value: gains, symbol: portfolioValue.symbol)
        }
        
        return gainsData
    }
    
    // MARK: - Performance Optimization Methods
    
    func evictMemoryCachesForPressure(critical: Bool) {
        aliasHistoryCache.removeAll()
        stockDataCache.removeAll(keepingCapacity: false)
        stockDataCacheTimestamp.removeAll(keepingCapacity: false)
        cachedHistoricalPortfolioValues.removeAll(keepingCapacity: false)

        let retainedPoints = critical ? 450 : 900
        for symbol in Array(livePriceSamples.keys) {
            if let samples = livePriceSamples[symbol], samples.count > retainedPoints {
                livePriceSamples[symbol] = Array(samples.suffix(retainedPoints))
            }
        }
        if livePortfolioValueSamples.count > retainedPoints {
            livePortfolioValueSamples = Array(livePortfolioValueSamples.suffix(retainedPoints))
        }
        if livePortfolioGainSamples.count > retainedPoints {
            livePortfolioGainSamples = Array(livePortfolioGainSamples.suffix(retainedPoints))
        }
    }
    
    
    
    

    // MARK: - Debug Methods
    
    /// Gets the current snapshot interval for debug purposes
    func getSnapshotInterval() -> TimeInterval {
        return snapshotInterval
    }
    
    /// Sets the snapshot interval for debug purposes
    func setSnapshotInterval(_ interval: TimeInterval) {
        snapshotInterval = interval
        StockbarRuntimeStorage.userDefaults.set(interval, forKey: Self.snapshotIntervalDefaultsKey)
        Task { await logger.info("📊 Snapshot interval changed to \(interval) seconds") }
    }
    
    
    // MARK: - Enhanced Retroactive Portfolio Calculation
    
    /// Creates portfolio composition from current DataModel
    func createPortfolioComposition(from dataModel: DataModel) -> PortfolioComposition {
        let positions = dataModel.realTimeTrades.filter { !$0.trade.isWatchlistOnly }.map { trade in
            // An unreadable or blank average cost is NaN. NaN cannot be stored as JSON and never
            // equals itself, so it would both fail to cache and look like a change on every check.
            let avgCost = trade.trade.position.getNormalizedAvgCost(for: trade.trade.name)
            return PortfolioPosition(
                symbol: trade.trade.name,
                units: trade.trade.position.unitSize,
                avgCost: avgCost.isFinite ? avgCost : 0,
                currency: trade.realTimeInfo.currency ?? "USD"
            )
        }
        return PortfolioComposition(positions: positions)
    }
    
    /// Checks if portfolio composition has changed
    func hasPortfolioCompositionChanged(_ newComposition: PortfolioComposition) -> Bool {
        guard let currentComposition = currentPortfolioComposition else {
            return true // First time calculation
        }
        return currentComposition.compositionHash != newComposition.compositionHash
    }
    
    /// Gets the date of the last portfolio snapshot
    func getLastPortfolioSnapshotDate() -> Date {
        return historicalPortfolioSnapshots.last?.date ?? findEarliestHistoricalData()
    }
    
    /// Gets stored portfolio values for chart display
    func getStoredPortfolioValues(
        for timeRange: ChartTimeRange,
        currency: String? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo)
        let startDate = bounds.start

        // Debug logging
        Task { await logger.debug("📊 GET PORTFOLIO VALUES: totalSnapshots=\(historicalPortfolioSnapshots.count), startDate=\(startDate), timeRange=\(timeRange.rawValue)") }

        let values = storedAndLivePortfolioValues(from: startDate, to: bounds.end, currency: currency)

        Task { await logger.debug("📊 GET PORTFOLIO VALUES: filteredCount=\(values.count)") }

        return values
    }
    
    /// Gets stored portfolio gains for chart display
    func getStoredPortfolioGains(
        for timeRange: ChartTimeRange,
        currency: String? = nil,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) -> [ChartDataPoint] {
        let bounds = portfolioRangeBounds(for: timeRange, customFrom: customFrom, customTo: customTo)

        let storedGains = portfolioSnapshots(in: currency)
            .filter { $0.date >= bounds.start && $0.date <= bounds.end }
            .map { snapshot in
                ChartDataPoint(date: snapshot.date, value: snapshot.totalGains)
            }
        let liveGains = liveSamplesMatch(currency)
            ? livePortfolioGainSamples.filter { $0.date >= bounds.start && $0.date <= bounds.end }
            : []

        return deduplicatedSortedChartPoints(storedGains + liveGains)
    }
    
    /// Pure read of sorted history. Display formatting must never start provider work.
    /// Pass `timeRange` to read the Folync overlay for that range when one
    /// exists; without it only local history is returned.
    func getPriceSnapshots(
        for symbol: String,
        from startDate: Date,
        to endDate: Date = Date(),
        timeRange: ChartTimeRange? = nil
    ) -> [PriceSnapshot] {
        let seriesKeys = timeRange.map {
            folyncLineSeriesKeys(for: symbol, timeRange: $0, customFrom: nil, customTo: nil)
        }
        return aliasAwarePriceSnapshots(for: symbol, folyncSeriesKeys: seriesKeys)
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Chart consumers explicitly request missing history after reading their current slice.
    func requestPriceHistoryIfNeeded(
        for symbol: String,
        timeRange: ChartTimeRange,
        from startDate: Date,
        to endDate: Date,
        availablePointCount: Int,
        coversRange: Bool = true,
        force: Bool = false
    ) {
        let folyncEnabled = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        guard force || folyncEnabled || availablePointCount < 10 || !coversRange else { return }
        schedulePriceHistoryFetchIfNeeded(
            for: symbol, timeRange: timeRange, startDate: startDate, endDate: endDate, force: force
        )
    }

    /// Whether sorted snapshots start near the beginning of the range (within
    /// a fifth of its length), so plenty of recent points cannot hide a gap.
    nonisolated static func snapshotsReachRangeStart(_ snapshots: [PriceSnapshot], from startDate: Date, to endDate: Date) -> Bool {
        guard let first = snapshots.first else { return false }
        let slack = endDate.timeIntervalSince(startDate) * 0.2
        return first.timestamp <= startDate.addingTimeInterval(slack)
    }

    /// Stored snapshots in `currency`, or all of them when no currency is given.
    func portfolioSnapshots(in currency: String?) -> [HistoricalPortfolioSnapshot] {
        guard let currency else { return historicalPortfolioSnapshots }
        return historicalPortfolioSnapshots.filter { $0.currency.uppercased() == currency.uppercased() }
    }

    /// Whether the live samples can join a series in `currency`. With no
    /// currency given, the stored snapshots' latest currency decides.
    func liveSamplesMatch(_ currency: String?) -> Bool {
        guard let sampleCurrency = livePortfolioSampleCurrency,
              let seriesCurrency = currency ?? historicalPortfolioSnapshots.last?.currency else {
            return true
        }
        return sampleCurrency.uppercased() == seriesCurrency.uppercased()
    }

    func schedulePriceHistoryFetchIfNeeded(
        for symbol: String,
        timeRange: ChartTimeRange,
        startDate: Date,
        endDate: Date = Date(),
        force: Bool = false
    ) {
        let symbolKey = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbolKey.isEmpty else { return }
        let configurationRevision = folyncSupplementalConfigurationRevision
        let customKey = timeRange == .custom
            ? "|\(startDate.timeIntervalSince1970)|\(endDate.timeIntervalSince1970)"
            : ""
        let requestKey = "price|\(symbolKey)|\(timeRange.rawValue)\(customKey)|revision:\(configurationRevision)"

        priceHistoryScheduler.schedule(key: requestKey, force: force) { [weak self] in
            guard let self else { return .cancelled }
            return await self.triggerHistoricalDataFetch(
                for: symbol,
                timeRange: timeRange,
                startDate: startDate,
                endDate: endDate,
                folyncConfigurationRevision: configurationRevision
            )
        }
    }

    private func livePriceSamples(for symbol: String) -> [PriceSnapshot] {
        if let samples = livePriceSamples[symbol] {
            return samples
        }

        let normalizedSymbol = symbol.uppercased()
        return livePriceSamples.first { $0.key.uppercased() == normalizedSymbol }?.value ?? []
    }

    /// Stored prices for `symbol` and every alias of it, oldest first. A ticker
    /// that was renamed keeps its history under the old key, so an exact-key
    /// read would report the holding as having none.
    func storedPriceSnapshots(for symbol: String) -> [PriceSnapshot] {
        let aliases = instrumentAliasStore.aliases(for: symbol)
        if aliases.allSatisfy({ $0 == symbol }), let exact = priceSnapshots[symbol] { return exact }
        return InstrumentAliasHistoryLookup.combinedSnapshots(
            for: symbol, aliases: aliases, storedBySymbol: priceSnapshots, liveBySymbol: [:]
        )
    }

    /// The stored prices keyed for a calculation over `symbols`: each symbol's
    /// entry also carries what is stored under its aliases.
    func storedPriceSnapshots(resolvingAliasesFor symbols: [String]) -> [String: [PriceSnapshot]] {
        var result = priceSnapshots
        for symbol in Set(symbols) where instrumentAliasStore.aliases(for: symbol).contains(where: { $0 != symbol }) {
            result[symbol] = storedPriceSnapshots(for: symbol)
        }
        return result
    }

    func aliasAwarePriceSnapshots(
        for symbol: String,
        folyncSeriesKeys requestedSeriesKeys: Set<String>? = nil
    ) -> [PriceSnapshot] {
        let aliases = instrumentAliasStore.aliases(for: symbol)
        // Folync overlays are per range. Without the caller's range there is no
        // way to know which overlay applies, so range-less reads use local data
        // (the most recently fetched overlay could be any range).
        let seriesKeys = requestedSeriesKeys ?? []
        if let overlay = seriesKeys.compactMap({ folyncPriceOverlays[$0] }).first {
            return overlay
        }
        if !seriesKeys.isDisjoint(with: folyncUnavailableSeries) {
            return []
        }
        let stored = priceSnapshots
        let live = livePriceSamples
        return aliasHistoryCache.snapshots(for: normalizedSeriesKey(symbol), aliases: aliases) {
            InstrumentAliasHistoryLookup.combinedSnapshots(
                for: symbol, aliases: aliases, storedBySymbol: stored, liveBySymbol: live
            )
        }
    }

    func normalizedSeriesKey(_ symbol: String) -> String {
        symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func chartPoint(_ point: FolyncPortfolioHistory.SeriesPoint) -> ChartDataPoint? {
        let date = FolyncSupplementalDateParser.instant(point.date)
            ?? FolyncSupplementalDateParser.day(point.date)
        guard let date, point.value.isFinite else { return nil }
        return ChartDataPoint(date: date, value: point.value)
    }

    func notePriceDataChanged(for symbol: String) {
        invalidateStockDataCache(for: symbol)
        notePriceDataRevision(changed: [symbol])
    }

    func notePriceDataRevision(changed symbols: Set<String>?) {
        let keys = symbols.map { symbols in
            Set(symbols.flatMap { [$0] + instrumentAliasStore.aliases(for: $0) }.map(normalizedSeriesKey))
        }
        priceDataRevision &+= 1
        priceDataChanges.send(keys)
    }

    /// Count and latest timestamp of the in-memory price series for `symbols`
    /// and their aliases. Changes when any of those series gains or loses points.
    func priceSeriesFingerprint(for symbols: [String]) -> [String] {
        let wanted = Set(symbols.flatMap { [$0] + instrumentAliasStore.aliases(for: $0) }.map(normalizedSeriesKey))
        return priceSnapshots
            .filter { wanted.contains(normalizedSeriesKey($0.key)) }
            .map { key, snapshots in
                "\(key)|\(snapshots.count)|\(snapshots.last?.timestamp.timeIntervalSince1970 ?? 0)"
            }
            .sorted()
    }

    /// True when a `priceDataChanges` value can affect any of `symbols` (or
    /// their aliases). A nil change affects everything.
    func priceDataChange(_ changed: Set<String>?, affects symbols: [String]) -> Bool {
        guard let changed else { return true }
        return symbols.contains { symbol in
            ([symbol] + instrumentAliasStore.aliases(for: symbol))
                .contains { changed.contains(normalizedSeriesKey($0)) }
        }
    }

    /// Drops in-memory price data for symbols whose stored snapshots changed
    /// underneath (e.g. after a data migration) so every view reloads them.
    func invalidatePriceData(for symbols: Set<String>) {
        guard !symbols.isEmpty else { return }
        let keys = Set(symbols.map { $0.uppercased() })
        for key in priceSnapshots.keys where keys.contains(key.uppercased()) {
            priceSnapshots.removeValue(forKey: key)
        }
        symbols.forEach { invalidateStockDataCache(for: $0) }
        notePriceDataRevision(changed: symbols)
    }

    func invalidateStockDataCache(for symbol: String) {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedSymbol.isEmpty else { return }

        let matchingKeys = stockDataCache.keys.filter { cacheKey in
            cacheKey.uppercased().hasPrefix("\(normalizedSymbol)-")
        }

        for cacheKey in matchingKeys {
            stockDataCache.removeValue(forKey: cacheKey)
            stockDataCacheTimestamp.removeValue(forKey: cacheKey)
        }
    }

    func snapshotTimestampKey(_ timestamp: Date) -> Int64 {
        Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
    }

    private func appendLivePortfolioPoint(
        _ point: ChartDataPoint,
        to points: [ChartDataPoint],
        timestamp: Date
    ) -> [ChartDataPoint] {
        var updatedPoints = points
        if let last = updatedPoints.last, abs(last.date.timeIntervalSince(timestamp)) < 1 {
            updatedPoints[updatedPoints.count - 1] = point
        } else {
            updatedPoints.append(point)
        }

        let cutoff = timestamp.addingTimeInterval(-livePriceSampleRetention)
        updatedPoints = updatedPoints
            .filter { $0.date >= cutoff && $0.value.isFinite }
            .sorted { $0.date < $1.date }

        if updatedPoints.count > maxLivePortfolioSamples {
            updatedPoints = Array(updatedPoints.suffix(maxLivePortfolioSamples))
        }

        return updatedPoints
    }

    func deduplicatedSortedChartPoints(_ points: [ChartDataPoint]) -> [ChartDataPoint] {
        var latestByTimestamp: [Int64: ChartDataPoint] = [:]
        for point in points where point.value.isFinite {
            let key = Int64((point.date.timeIntervalSince1970 * 1_000).rounded())
            latestByTimestamp[key] = point
        }
        return latestByTimestamp.values.sorted { $0.date < $1.date }
    }
}
