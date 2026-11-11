import Combine
import CoreData
import Foundation
import Observation

extension HistoricalDataManager {
    /// Manually triggers calculation of historical portfolio values
    func calculateHistoricalPortfolioValues(using dataModel: DataModel) {
        Task {
            await calculateAndCacheHistoricalPortfolioValues(using: dataModel)
        }
    }

    /// Calculates and caches historical portfolio values using historical price data (async)
    func calculateAndCacheHistoricalPortfolioValues(using dataModel: DataModel) async {
        let totalSnapshots = priceSnapshots.values.map { $0.count }.reduce(0, +)
        
        // Use progressive data sampling for large datasets instead of skipping entirely
        let useSampling = totalSnapshots > 15000
        let startDate: Date
        
        if totalSnapshots > 50000 {
            // For very large datasets, limit to 3 months
            startDate = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
            await logger.warning("📊 Large dataset (\(totalSnapshots) snapshots) - using 3-month window with sampling") 
        } else if totalSnapshots > 25000 {
            // For large datasets, limit to 6 months
            startDate = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
            await logger.info("📊 Medium dataset (\(totalSnapshots) snapshots) - using 6-month window") 
        } else {
            // For reasonable datasets, use 1 year
            startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            await logger.debug("📊 Processing \(totalSnapshots) snapshots with 1-year window") 
        }
        
        await logger.debug("📊 Starting background calculation of historical portfolio values") 
        
        let portfolioValues = await calculateHistoricalPortfolioValues(from: startDate, using: dataModel, useSampling: useSampling)
        
        await MainActor.run {
            self.cachedHistoricalPortfolioValues = portfolioValues
            self.lastPortfolioCalculationDate = Date()
        }
        await logger.debug("📊 Cached \(portfolioValues.count) historical portfolio values")
    }

    /// Calculates historical portfolio values using historical price data (sync, for background use)
    func calculateHistoricalPortfolioValues(from startDate: Date, using dataModel: DataModel, useSampling: Bool = false) async -> [ChartDataPoint] {
        let actualStartDate = startDate
        
        // Get all available historical dates across all symbols with chunked processing
        var allDates = Set<Date>()
        let calendar = Calendar.current
        
        await Task.yield() // Allow UI updates
        
        for (_, snapshots) in priceSnapshots {
            for snapshot in snapshots {
                if snapshot.timestamp >= actualStartDate {
                    // Use start of day to group by date
                    let dayStart = calendar.startOfDay(for: snapshot.timestamp)
                    allDates.insert(dayStart)
                }
            }
            
            // Yield periodically to prevent blocking
            if allDates.count % 100 == 0 {
                await Task.yield()
            }
        }
        
        guard !allDates.isEmpty else {
            Task { await logger.debug("📊 No historical price data available for portfolio calculation") }
            return []
        }
        
        var portfolioValues: [ChartDataPoint] = []
        let currencyConverter = CurrencyConverter.shared
        let preferredCurrency = dataModel.preferredCurrency
        
        // Sort dates chronologically and apply sampling if needed
        let sortedAllDates = allDates.sorted()
        let sortedDates: [Date]
        
        if useSampling && sortedAllDates.count > 1000 {
            // Sample every 3rd data point for large datasets to maintain performance
            let step = max(1, sortedAllDates.count / 500) // Target ~500 data points
            sortedDates = stride(from: 0, to: sortedAllDates.count, by: step).map { sortedAllDates[$0] }
            Task { await logger.debug("📊 Sampling \(sortedDates.count) dates from \(sortedAllDates.count) total dates (step: \(step))") }
        } else {
            // For smaller datasets, use all data but limit to reasonable amount
            sortedDates = Array(sortedAllDates.suffix(800))
            Task { await logger.debug("📊 Using \(sortedDates.count) dates from \(sortedAllDates.count) total dates") }
        }
        
        // Process in chunks to avoid hanging
        let chunkSize = 20
        for chunk in sortedDates.chunked(into: chunkSize) {
            await Task.yield() // Yield between chunks
            
            for date in chunk {
                var totalValueUSD = 0.0
                var hasValidData = false
                
                // Calculate portfolio value for this date
                for trade in dataModel.realTimeTrades {
                    let symbol = trade.trade.name
                    
                    // Find the historical price for this symbol on this date
                    let symbolSnapshots = aliasAwarePriceSnapshots(for: symbol)
                    
                    if !symbolSnapshots.isEmpty,
                       let historicalSnapshot = findClosestSnapshot(in: symbolSnapshots, to: date) {
                        
                        let units = trade.trade.position.unitSize
                        let historicalPrice = historicalSnapshot.price
                        let currency = trade.realTimeInfo.currency ?? "USD"
                        
                        guard !historicalPrice.isNaN && historicalPrice > 0 && units > 0 else {
                            continue
                        }
                        
                        let positionValue = historicalPrice * units
                        
                        // Convert to USD for aggregation
                        var valueInUSD = positionValue
                        if currency == "GBP" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: "GBP", to: "USD")
                        } else if currency != "USD" {
                            valueInUSD = currencyConverter.convert(amount: positionValue, from: currency, to: "USD")
                        }
                        
                        totalValueUSD += valueInUSD
                        hasValidData = true
                    }
                }
                
                if hasValidData {
                    // Convert to preferred currency
                    var finalValue = totalValueUSD
                    if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
                        let gbpAmount = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: "GBP")
                        finalValue = gbpAmount * 100.0
                    } else if preferredCurrency != "USD" {
                        finalValue = currencyConverter.convert(amount: totalValueUSD, from: "USD", to: preferredCurrency)
                    }
                    
                    portfolioValues.append(ChartDataPoint(date: date, value: finalValue))
                }
            }
        }
        
        Task { await logger.debug("📊 Calculated \(portfolioValues.count) historical portfolio values from \(sortedDates.count) dates") }
        return portfolioValues.sorted { $0.date < $1.date }
    }

    /// Finds the closest historical snapshot to a given date using optimized binary search
    /// CRITICAL FIX: Assumes snapshots are already sorted to avoid O(n log n) performance bottleneck
    func findClosestSnapshot(in sortedSnapshots: [PriceSnapshot], to targetDate: Date) -> PriceSnapshot? {
        guard !sortedSnapshots.isEmpty else { return nil }
        
        // PERFORMANCE: Snapshots MUST be pre-sorted by timestamp for binary search to work
        // This function no longer sorts to avoid O(n log n) bottleneck on every call
        let targetDayStart = Calendar.current.startOfDay(for: targetDate)
        
        // Binary search for exact or closest match
        var left = 0
        var right = sortedSnapshots.count - 1
        var bestMatch: PriceSnapshot?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        
        while left <= right {
            let mid = (left + right) / 2
            let midSnapshot = sortedSnapshots[mid]
            let midDayStart = Calendar.current.startOfDay(for: midSnapshot.timestamp)
            
            let distance = abs(midDayStart.timeIntervalSince(targetDayStart))
            
            // Check if this is our best match so far
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = midSnapshot
            }
            
            // Exact match found
            if midDayStart == targetDayStart {
                return midSnapshot
            }
            
            if midDayStart < targetDayStart {
                left = mid + 1
            } else {
                right = mid - 1
            }
        }
        
        // Only return if within reasonable time range (30 days)
        if let match = bestMatch, bestDistance <= 30 * 24 * 60 * 60 {
            return match
        }
        
        return nil
    }

    /// Calculates the total amount the user invested (purchase cost) in preferred currency
    func calculateTotalInvestmentCost(dataModel: DataModel) -> Double {
        let currencyConverter = CurrencyConverter.shared
        var totalCostUSD = 0.0
        
        for trade in dataModel.realTimeTrades {
            // Use normalized average cost (handles GBX to GBP conversion automatically)
            let adjustedCost = trade.trade.position.averageCost(
                for: trade.trade.name, inQuoteCurrency: trade.realTimeInfo.currency
            )
            guard !adjustedCost.isNaN, adjustedCost > 0 else { continue }
            
            let units = trade.trade.position.unitSize
            let currency = trade.realTimeInfo.currency ?? "USD"
            
            let totalPositionCost = adjustedCost * units
            
            // Convert to USD for aggregation
            var costInUSD = totalPositionCost
            if currency == "GBP" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: "GBP", to: "USD")
            } else if currency != "USD" {
                costInUSD = currencyConverter.convert(amount: totalPositionCost, from: currency, to: "USD")
            }
            
            totalCostUSD += costInUSD
        }
        
        // Convert to preferred currency
        let preferredCurrency = dataModel.preferredCurrency
        var finalAmount = totalCostUSD
        
        if preferredCurrency == "GBX" || preferredCurrency == "GBp" {
            let gbpAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: "GBP")
            finalAmount = gbpAmount * 100.0
        } else if preferredCurrency != "USD" {
            finalAmount = currencyConverter.convert(amount: totalCostUSD, from: "USD", to: preferredCurrency)
        }
        
        return finalAmount
    }

    /// Main method to trigger retroactive portfolio calculation
    func calculateRetroactivePortfolioHistory(using dataModel: DataModel, force: Bool = false) async {
        // CRITICAL FIX: Prevent concurrent calculation overlaps
        guard !isCalculationInProgress else {
            await logger.warning("🔄 RETROACTIVE: Calculation already in progress, skipping duplicate request") 
            return
        }
        isCalculationInProgress = true
        
        // Ensure calculation state is cleared when function exits
        defer {
            isCalculationInProgress = false
        }
        
        await logger.info("🔄 RETROACTIVE: Starting comprehensive portfolio history calculation (force: \(force))") 
        
        // Initialize progress tracking
        let calculationManager = BackgroundCalculationManager.shared
        calculationManager.startCalculation(operation: "Portfolio History Calculation", totalOperations: 100)
        
        // Create current portfolio composition for tracking changes
        calculationManager.updateProgress(completed: 10, status: "Analyzing portfolio composition")
        let newComposition = createPortfolioComposition(from: dataModel)

        // Check if portfolio composition has changed
        calculationManager.updateProgress(completed: 20, status: "Checking for portfolio changes")
        let compositionChanged = hasPortfolioCompositionChanged(newComposition)
        let needsFullRecalculation = force || compositionChanged

        if needsFullRecalculation {
            if force {
                await logger.info("🔄 RETROACTIVE: Forced full recalculation requested")
            } else {
                await logger.info("🔄 RETROACTIVE: Portfolio composition changed - full recalculation needed")
            }
            
            calculationManager.updateProgress(completed: 30, status: "Starting full recalculation")
            await performFullPortfolioRecalculation(using: dataModel, composition: newComposition)
        } else {
            await logger.info("🔄 RETROACTIVE: Portfolio composition unchanged - incremental update")
            calculationManager.updateProgress(completed: 30, status: "Starting incremental update")
            await performIncrementalPortfolioUpdate(using: dataModel)
        }

        // A cancelled run stores nothing and is not recorded as done, so the
        // next request starts it again.
        guard !calculationManager.isCancellationRequested else {
            await logger.info("🔄 RETROACTIVE: Calculation cancelled before its results were stored")
            return
        }

        // Update composition tracking
        calculationManager.updateProgress(completed: 90, status: "Finalizing calculation")
        await MainActor.run {
            self.currentPortfolioComposition = newComposition
            self.lastRetroactiveCalculationDate = Date()
        }

        // Save updated data
        calculationManager.updateProgress(completed: 95, status: "Saving data")
        saveHistoricalData()

        // Complete the calculation
        calculationManager.completeCalculation()
        await logger.info("🔄 RETROACTIVE: Portfolio history calculation completed")
    }

    /// Performs full portfolio recalculation for entire history
    func performFullPortfolioRecalculation(using dataModel: DataModel, composition: PortfolioComposition) async {
        await logger.info("🔄 FULL RECALC: Starting full portfolio history recalculation") 
        
        let calculationManager = BackgroundCalculationManager.shared
        
        // Find the earliest available historical data
        calculationManager.updateProgress(completed: 45, status: "Finding earliest data")
        let earliestDate = findEarliestHistoricalData()
        let endDate = Date()
        
        await logger.info("🔄 FULL RECALC: Calculating from \(DateFormatter.debug.string(from: earliestDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        // Calculate portfolio values for the entire historical period
        calculationManager.updateProgress(completed: 50, status: "Calculating portfolio values")
        let snapshots = await calculatePortfolioSnapshotsForPeriod(
            from: earliestDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        guard !calculationManager.isCancellationRequested else { return }
        calculationManager.updateProgress(completed: 85, status: "Storing portfolio snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots = Self.mergePortfolioHistory(
                existing: self.historicalPortfolioSnapshots,
                recalculated: snapshots
            )
        }
        
        await logger.info("🔄 FULL RECALC: Generated \(snapshots.count) portfolio snapshots; history now holds \(historicalPortfolioSnapshots.count) (recorded days kept, gaps filled)")
    }

    /// Loads stored price history from Core Data for the given symbols (all
    /// stored symbols when nil), merging with anything recorded in memory since.
    func reloadStoredPriceHistory(for symbols: Set<String>? = nil) async {
        await adoptStoredPriceHistory(await Self.readStoredPriceHistory(for: symbols, from: coreDataService))
    }

    /// Stored price history as it is kept in memory, read away from the main actor.
    struct StoredPriceHistory: Sendable {
        /// Symbols looked up, with or without stored history.
        let symbolCount: Int
        /// Each symbol that has stored history, already thinned.
        let series: [(symbol: String, snapshots: [PriceSnapshot])]
    }

    /// Reads and thins stored price history for the given symbols (all stored
    /// symbols when nil). Nothing here needs the main actor, so a busy main
    /// thread does not hold the read up. Nil when the store cannot list its symbols.
    nonisolated static func readStoredPriceHistory(
        for symbols: Set<String>?, from service: HistoricalDataServiceProtocol
    ) async -> StoredPriceHistory? {
        let targets: [String]
        if let symbols {
            targets = Array(symbols)
        } else {
            do {
                targets = try await service.fetchStoredPriceSymbols()
            } catch {
                await Logger.shared.error("❌ Could not list stored price history: \(error)")
                return nil
            }
        }
        var series: [(symbol: String, snapshots: [PriceSnapshot])] = []
        for symbol in targets {
            guard let stored = try? await service.fetchAllPriceSnapshots(for: symbol), !stored.isEmpty else { continue }
            series.append((symbol, thinnedPriceHistory(stored)))
        }
        return StoredPriceHistory(symbolCount: targets.count, series: series)
    }

    /// Takes stored price history into memory, keeping anything recorded since
    /// it was read.
    func adoptStoredPriceHistory(_ history: StoredPriceHistory?) async {
        guard let history else { return }
        var loadedCount = 0
        for (symbol, stored) in history.series {
            let inMemory = priceSnapshots[symbol] ?? []
            if inMemory.isEmpty {
                priceSnapshots[symbol] = stored
            } else {
                // Thinning keeps every recent point and the last point of each
                // earlier day, so thinning this merge gives what thinning the
                // unthinned history with the same additions would.
                let storedKeys = Set(stored.map { snapshotTimestampKey($0.timestamp) })
                let merged = stored + inMemory.filter { !storedKeys.contains(snapshotTimestampKey($0.timestamp)) }
                priceSnapshots[symbol] = Self.thinnedPriceHistory(merged)
            }
            loadedCount += priceSnapshots[symbol]?.count ?? 0
            notePriceDataChanged(for: symbol)
        }
        await logger.info("HistoricalDataManager: Loaded stored price history for \(history.symbolCount) symbols (\(loadedCount) points in memory)")
    }

    /// Performs incremental portfolio update for new dates only
    func performIncrementalPortfolioUpdate(using dataModel: DataModel) async {
        let calculationManager = BackgroundCalculationManager.shared
        
        calculationManager.updateProgress(completed: 40, status: "Checking for new data")
        let lastCalculatedDate = getLastPortfolioSnapshotDate()
        let endDate = Date()
        
        // Only calculate if there's a meaningful gap (more than 1 day)
        guard endDate.timeIntervalSince(lastCalculatedDate) > 86400 else {
            await logger.debug("🔄 INCREMENTAL: No significant time gap, skipping update") 
            calculationManager.updateProgress(completed: 85, status: "No update needed")
            return
        }
        
        await logger.info("🔄 INCREMENTAL: Updating from \(DateFormatter.debug.string(from: lastCalculatedDate)) to \(DateFormatter.debug.string(from: endDate))") 
        
        guard let composition = currentPortfolioComposition else {
            await logger.warning("🔄 INCREMENTAL: Missing portfolio composition, skipping incremental update")
            calculationManager.updateProgress(completed: 85, status: "No portfolio composition")
            return
        }

        calculationManager.updateProgress(completed: 50, status: "Calculating new portfolio values")
        let newSnapshots = await calculatePortfolioSnapshotsForPeriod(
            from: lastCalculatedDate,
            to: endDate,
            using: dataModel,
            composition: composition
        )
        
        guard !calculationManager.isCancellationRequested else { return }
        calculationManager.updateProgress(completed: 80, status: "Adding new snapshots")
        await MainActor.run {
            self.historicalPortfolioSnapshots.append(contentsOf: newSnapshots)
            self.historicalPortfolioSnapshots.sort { $0.date < $1.date }
            // No count cap here: trimming to the newest points threw away the
            // long-range history the 1M/1Y/All charts and risk metrics read.
        }
        
        await logger.info("🔄 INCREMENTAL: Added \(newSnapshots.count) new portfolio snapshots") 
    }

    /// Calculates portfolio snapshots for a specific date range with concurrent processing
    func calculatePortfolioSnapshotsForPeriod(
        from startDate: Date,
        to endDate: Date,
        using dataModel: DataModel,
        composition: PortfolioComposition
    ) async -> [HistoricalPortfolioSnapshot] {
        let input = HistoricalPortfolioCalculationInput(
            startDate: startDate,
            endDate: endDate,
            priceSnapshots: storedPriceSnapshots(resolvingAliasesFor: composition.positions.map(\.symbol)),
            composition: composition,
            preferredCurrency: dataModel.preferredCurrency
        )
        let startTime = Date()
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)
        await logger.info(
            "🔄 CALC PERIOD: Generated \(snapshots.count) portfolio snapshots off the main actor in " +
            "\(String(format: "%.2f", Date().timeIntervalSince(startTime)))s"
        )
        return snapshots
    }

    /// Finds the earliest available historical data across all symbols
    func findEarliestHistoricalData() -> Date {
        var earliestDate = Date()
        
        for (_, snapshots) in priceSnapshots {
            if let earliest = snapshots.min(by: { $0.timestamp < $1.timestamp })?.timestamp {
                if earliest < earliestDate {
                    earliestDate = earliest
                }
            }
        }
        
        // Don't go back more than 5 years
        let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
        return max(earliestDate, fiveYearsAgo)
    }
}
