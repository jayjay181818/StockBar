//
//  HistoricalDataCoordinator.swift
//  Stockbar
//
//  Historical data backfill coordinator - manages all historical data fetching
//  Extracted from DataModel for better separation of concerns
//

import Foundation

/// Service responsible for coordinating historical data backfill operations
@MainActor
class HistoricalDataCoordinator {
    private let networkService: NetworkService
    private let historicalDataManager: HistoricalDataManager
    private let logger = Logger.shared
    
    // MARK: - Backfill State
    private var isRunningComprehensiveCheck = false
    private var isRunningStandardCheck = false
    private var hasRunStartupBackfill = false
    private var lastComprehensiveCheckTime: Date = Date.distantPast
    
    // MARK: - Configuration
    
    /// Cooldown period between comprehensive checks (read from UserDefaults)
    private var comprehensiveCheckCooldown: TimeInterval {
        let hours = UserDefaults.standard.integer(forKey: "backfillCooldownHours")
        return hours == 0 ? 1800 : TimeInterval(hours * 3600)
    }
    
    /// Backfill schedule mode (read from UserDefaults)
    private var backfillSchedule: String {
        UserDefaults.standard.string(forKey: "backfillSchedule") ?? "startup"
    }
    
    /// Whether to show notifications for backfill progress
    private var backfillNotifications: Bool {
        UserDefaults.standard.bool(forKey: "backfillNotifications")
    }

    private let benchmarkBackfillDays = 30
    private let benchmarkCoverageThreshold: Double = 0.10
    
    init(networkService: NetworkService, historicalDataManager: HistoricalDataManager) {
        self.networkService = networkService
        self.historicalDataManager = historicalDataManager
    }
    
    // MARK: - Startup & Scheduling
    
    /// Performs startup backfill check if enabled by user preferences
    func performStartupBackfillIfNeeded(symbols: [String]) async {
        // Check user preference for backfill schedule
        guard backfillSchedule == "startup" else {
            await logger.info("🔍 STARTUP: Skipping startup backfill - schedule set to '\(backfillSchedule)'")
            return
        }
        
        guard !hasRunStartupBackfill else {
            await logger.info("🔍 STARTUP: Skipping - startup backfill already initiated")
            return
        }
        hasRunStartupBackfill = true
        
        // Wait 60 seconds after app startup to avoid interfering with initial data loading
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        
        await logger.info("🔍 STARTUP: Checking for missing historical data coverage")
        await logger.info("🚀 AUTO-BACKFILL: Starting automatic historical data check")
        
        // Check if this looks like a first run or we have very little historical data
        let totalHistoricalSnapshots = historicalDataManager.priceSnapshots.values.map { $0.count }.reduce(0, +)
        let symbolCount = symbols.count

        // More aggressive check: if we have less than 100 snapshots per symbol (about 4-5 months of data)
        // force immediate backfill bypassing cooldown
        if totalHistoricalSnapshots < (symbolCount * 100) {
            await logger.warning("🔍 STARTUP: Detected minimal historical data (\(totalHistoricalSnapshots) snapshots for \(symbolCount) symbols, avg \(totalHistoricalSnapshots/max(1,symbolCount)) per symbol). Forcing immediate comprehensive backfill bypassing cooldown.")
            lastComprehensiveCheckTime = Date.distantPast
        }

        await checkAndBackfill5YearHistoricalData(symbols: symbols)
    }
    
    // MARK: - Standard 1-Month Backfill Check
    
    /// Checks for missing historical data and triggers backfill if needed (legacy 1-month check)
    public func checkAndBackfillHistoricalData(symbols: [String]) async {
        // Safety check: Don't run if already running
        guard !isRunningStandardCheck else {
            await logger.info("🔍 STANDARD: Skipping - standard check already in progress")
            return
        }
        
        // Don't run standard check if comprehensive check is running
        guard !isRunningComprehensiveCheck else {
            await logger.info("🔍 STANDARD: Skipping - comprehensive check in progress")
            return
        }
        
        isRunningStandardCheck = true
        defer { isRunningStandardCheck = false }
        
        await logger.info("🔍 Checking for missing historical data gaps (1-month scope)")
        await logger.debug("🔍 HISTORICAL BACKFILL: Starting data coverage check at \(Date())")
        
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
            let estimatedBusinessDays = max(1, daysSinceOneMonth * 5 / 7)

            // If we're missing more than 90% of business days, trigger backfill (lowered from 25% threshold)
            if uniqueDays.count < estimatedBusinessDays / 10 {
                symbolsNeedingBackfill.append(symbol)
                await logger.info("Symbol \(symbol) needs backfill - only \(uniqueDays.count) days of data vs ~\(estimatedBusinessDays) expected business days (\(String(format: "%.1f", Double(uniqueDays.count) / Double(estimatedBusinessDays) * 100))% coverage)")
            } else {
                await logger.debug("Symbol \(symbol) has sufficient recent data - \(uniqueDays.count) days (\(String(format: "%.1f", Double(uniqueDays.count) / Double(estimatedBusinessDays) * 100))% coverage)")
            }
        }
        
        if !symbolsNeedingBackfill.isEmpty {
            await logger.info("🚀 Starting historical data backfill for \(symbolsNeedingBackfill.count) symbols")
            await backfillHistoricalData(for: symbolsNeedingBackfill)
        } else {
            await logger.info("No symbols need historical data backfill")
        }
    }
    
    // MARK: - Comprehensive 5-Year Backfill Check
    
    /// Comprehensive 5-year historical data coverage check and automatic backfill
    public func checkAndBackfill5YearHistoricalData(symbols: [String]) async {
        // Safety check: Don't run if already running
        guard !isRunningComprehensiveCheck else {
            await logger.info("🔍 COMPREHENSIVE: Skipping - comprehensive check already in progress")
            return
        }
        
        // Safety check: Don't run too frequently
        let timeSinceLastCheck = Date().timeIntervalSince(lastComprehensiveCheckTime)
        guard timeSinceLastCheck >= comprehensiveCheckCooldown else {
            await logger.info("🔍 COMPREHENSIVE: Skipping - last check was only \(Int(timeSinceLastCheck/3600)) hours ago (minimum \(Int(comprehensiveCheckCooldown/3600)) hours)")
            return
        }
        
        isRunningComprehensiveCheck = true
        defer {
            isRunningComprehensiveCheck = false
            lastComprehensiveCheckTime = Date()
        }
        
        await logger.info("🔍 COMPREHENSIVE: Starting 5-year historical data coverage analysis")
        
        let filteredSymbols = symbols.filter { !$0.isEmpty }
        guard !filteredSymbols.isEmpty else {
            await logger.info("No symbols to analyze for 5-year coverage")
            return
        }
        
        await logger.info("🔍 COMPREHENSIVE: Analyzing \(filteredSymbols.count) symbols for 5-year coverage")
        
        var symbolsNeedingBackfill: [String] = []
        let calendar = Calendar.current
        let today = Date()
        let fiveYearsAgo = calendar.date(byAdding: .year, value: -5, to: today) ?? today
        
        // Analyze each symbol individually to avoid blocking
        for symbol in filteredSymbols {
            await Task.yield()
            
            let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
            let isBenchmark = SymbolMetadata.isBenchmarkSymbol(symbol)
            let baseCoverageStartDate = isBenchmark
                ? (calendar.date(byAdding: .day, value: -benchmarkBackfillDays, to: today) ?? today)
                : fiveYearsAgo
            var coverageStartDate = baseCoverageStartDate
            var coverageLabel = isBenchmark ? "\(benchmarkBackfillDays)-day benchmark" : "5-year"
            if let earliestAvailable = historicalDataManager.earliestAvailableDate(for: symbol),
               earliestAvailable > baseCoverageStartDate {
                coverageStartDate = earliestAvailable
                coverageLabel = "\(coverageLabel) since \(DateFormatter.debug.string(from: earliestAvailable))"
            }
            let historicalSnapshots = existingSnapshots.filter { $0.timestamp >= coverageStartDate }
            
            // Count unique days with data in the past 5 years
            let uniqueDays = Set(historicalSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
            
            // Calculate expected business days over coverage window
            let daysInRange = calendar.dateComponents([.day], from: coverageStartDate, to: today).day ?? 0
            let expectedBusinessDays = max(1, daysInRange * 5 / 7)
            
            let coverageRatio = Double(uniqueDays.count) / Double(expectedBusinessDays)
            let coverageThreshold = isBenchmark ? benchmarkCoverageThreshold : 0.10

            // If we have less than 10% coverage over 5 years, trigger backfill (lowered from 50% for better detection)
            if coverageRatio < coverageThreshold {
                symbolsNeedingBackfill.append(symbol)
                await logger.info("📊 COMPREHENSIVE: \(symbol) needs \(coverageLabel) backfill - only \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))% coverage)")
            } else {
                await logger.debug("✅ COMPREHENSIVE: \(symbol) has good \(coverageLabel) coverage - \(uniqueDays.count)/\(expectedBusinessDays) days (\(String(format: "%.1f", coverageRatio * 100))% coverage)")
            }
        }
        
        if !symbolsNeedingBackfill.isEmpty {
            if backfillNotifications {
                sendBackfillNotification(title: "Historical Data Backfill", message: "Starting 5-year backfill for \(symbolsNeedingBackfill.count) symbols...")
            }

            await logger.info("🚀 COMPREHENSIVE: Starting automatic 5-year backfill for \(symbolsNeedingBackfill.count) symbols: \(symbolsNeedingBackfill.joined(separator: ", "))")
            await logger.info("⏱️ COMPREHENSIVE: Estimated time: \(symbolsNeedingBackfill.count * 5) minutes (5 years × \(symbolsNeedingBackfill.count) symbols with delays)")
            await staggeredBackfillHistoricalData(for: symbolsNeedingBackfill)

            if backfillNotifications {
                sendBackfillNotification(title: "Historical Data Backfill Complete", message: "Successfully backfilled \(symbolsNeedingBackfill.count) symbols")
            }
            await logger.info("✅ COMPREHENSIVE: Backfill completed for all \(symbolsNeedingBackfill.count) symbols")
        } else {
            await logger.info("✅ COMPREHENSIVE: All symbols have good 5-year historical coverage")
        }
    }
    
    // MARK: - Backfill Execution
    
    /// Staggered backfill that processes symbols with delays to prevent UI blocking
    private func staggeredBackfillHistoricalData(for symbols: [String]) async {
        await logger.info("⏱️ STAGGERED: Starting staggered 5-year backfill for \(symbols.count) symbols")
        let startTime = Date()

        for (index, symbol) in symbols.enumerated() {
            let progress = "\(index + 1)/\(symbols.count)"
            await logger.info("⏱️ STAGGERED: [\(progress)] Processing \(symbol)...")

            await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)

            // Log progress update
            let elapsed = Date().timeIntervalSince(startTime)
            let avgTimePerSymbol = elapsed / Double(index + 1)
            let remaining = Int(avgTimePerSymbol * Double(symbols.count - index - 1) / 60)
            await logger.info("✅ STAGGERED: [\(progress)] Completed \(symbol). Estimated time remaining: ~\(remaining) minutes")

            if index < symbols.count - 1 {
                await logger.debug("⏱️ STAGGERED: Waiting 10 seconds before next symbol...")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }

        let totalTime = Int(Date().timeIntervalSince(startTime) / 60)
        await logger.info("🏁 STAGGERED: Completed staggered 5-year backfill for all \(symbols.count) symbols in \(totalTime) minutes")
    }
    
    /// Backfills historical data for specified symbols in chunks to avoid hanging
    public func backfillHistoricalData(for symbols: [String]) async {
        await logger.info("🚀 CHUNKED BACKFILL: Starting 5-year chunked historical data backfill")
        
        for symbol in symbols {
            await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        await logger.info("🏁 CHUNKED BACKFILL: Completed 5-year chunked backfill for all symbols")
    }
    
    /// Backfills historical data for a single symbol in yearly chunks
    private func backfillHistoricalDataForSymbol(_ symbol: String, yearsToFetch: Int) async {
        if SymbolMetadata.isBenchmarkSymbol(symbol) {
            await backfillBenchmarkHistory(for: symbol)
            return
        }

        let calendar = Calendar.current
        let endDate = Date()
        let earliestAvailableDate = historicalDataManager.earliestAvailableDate(for: symbol)
        
        await logger.info("🔄 CHUNKED BACKFILL: Starting \(yearsToFetch)-year backfill for \(symbol)")
        
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
            
            await logger.info("📊 CHUNKED BACKFILL: \(symbol) existing data: \(existingSnapshots.count) points from \(dateFormatter.string(from: oldestExistingDate!)) to \(dateFormatter.string(from: newestExistingDate!))")
        } else {
            await logger.info("📊 CHUNKED BACKFILL: \(symbol) has no existing historical data")
        }
        
        // Fetch data in yearly chunks, working backwards from current date
        for yearOffset in 1...yearsToFetch {
            let chunkEndDate = calendar.date(byAdding: .year, value: -(yearOffset - 1), to: endDate) ?? endDate
            var chunkStartDate = calendar.date(byAdding: .year, value: -yearOffset, to: endDate) ?? endDate

            if let earliestAvailableDate {
                if chunkEndDate <= earliestAvailableDate {
                    await logger.info("⏭️ CHUNKED BACKFILL: \(symbol) skipping year \(yearOffset) - reached earliest available data at \(DateFormatter.debug.string(from: earliestAvailableDate))")
                    break
                }
                if chunkStartDate < earliestAvailableDate {
                    chunkStartDate = earliestAvailableDate
                }
            }

            if chunkStartDate >= chunkEndDate {
                await logger.info("⏭️ CHUNKED BACKFILL: \(symbol) skipping year \(yearOffset) - invalid range after bounds adjustment")
                continue
            }

            // Check if this chunk has significant gaps
            let daysInChunk = calendar.dateComponents([.day], from: chunkStartDate, to: chunkEndDate).day ?? 0
            let expectedBusinessDays = max(1, daysInChunk * 5 / 7)

            let chunkExistingDates = existingDates.filter { date in
                date >= chunkStartDate && date < chunkEndDate
            }

            let coverageRatio = Double(chunkExistingDates.count) / Double(expectedBusinessDays)

            // Only skip if we have excellent coverage (>90%, lowered from 80%)
            if coverageRatio > 0.90 {
                await logger.info("⏭️ CHUNKED BACKFILL: Skipping year \(yearOffset) for \(symbol) - excellent coverage (\(String(format: "%.1f", coverageRatio * 100))%)")
                continue
            }
            
            await logger.info("📅 CHUNKED BACKFILL: Fetching year \(yearOffset) for \(symbol) (\(chunkExistingDates.count)/\(expectedBusinessDays) days, \(String(format: "%.1f", coverageRatio * 100))% coverage)")
            
            let shouldContinue = await fetchHistoricalDataChunk(for: symbol, from: chunkStartDate, to: chunkEndDate, yearOffset: yearOffset)
            if !shouldContinue {
                await logger.info("⏹️ CHUNKED BACKFILL: Stopping older chunks for \(symbol) after reaching earliest available data")
                break
            }
            
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        
        await logger.info("✅ CHUNKED BACKFILL: Completed \(yearsToFetch)-year backfill for \(symbol)")
    }

    private func backfillBenchmarkHistory(for symbol: String) async {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -benchmarkBackfillDays, to: endDate) else {
            await logger.warning("⚠️ BENCHMARK: Unable to compute backfill window for \(symbol)")
            return
        }

        await logger.info("🧭 BENCHMARK: Backfilling last \(benchmarkBackfillDays) days for \(symbol)")
        _ = await fetchHistoricalDataChunk(for: symbol, from: startDate, to: endDate, yearOffset: 1)
    }
    
    /// Fetches a single chunk of historical data
    private func fetchHistoricalDataChunk(for symbol: String, from startDate: Date, to endDate: Date, yearOffset: Int) async -> Bool {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        
        do {
            await logger.info("🔄 CHUNKED BACKFILL: Fetching chunk \(yearOffset) for \(symbol): \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
            
            let historicalData = try await networkService.fetchHistoricalData(for: symbol, from: startDate, to: endDate)
            
            await logger.info("📥 CHUNKED BACKFILL: Received \(historicalData.count) data points for \(symbol) chunk \(yearOffset)")
            
            if !historicalData.isEmpty {
                // Filter out dates that already have data to avoid duplicates
                let calendar = Calendar.current
                let existingSnapshots = historicalDataManager.priceSnapshots[symbol] ?? []
                let existingDates = Set(existingSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
                
                let newSnapshots = historicalData.filter { snapshot in
                    let snapshotDay = calendar.startOfDay(for: snapshot.timestamp)
                    return !existingDates.contains(snapshotDay)
                }
                
                await logger.info("🔍 CHUNKED BACKFILL: After filtering, \(newSnapshots.count) new snapshots for \(symbol) chunk \(yearOffset)")
                
                if !newSnapshots.isEmpty {
                    historicalDataManager.addImportedSnapshots(newSnapshots, for: symbol)
                    await logger.info("✅ CHUNKED BACKFILL: Added \(newSnapshots.count) new data points for \(symbol) chunk \(yearOffset)")
                    
                    if let first = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).first,
                       let last = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).last {
                        await logger.info("📊 CHUNKED BACKFILL: \(symbol) chunk \(yearOffset) range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                } else {
                    await logger.info("ℹ️ CHUNKED BACKFILL: No new data needed for \(symbol) chunk \(yearOffset) - all dates already exist")
                }
            } else {
                await logger.warning("⚠️ CHUNKED BACKFILL: No data received for \(symbol) chunk \(yearOffset)")
            }
            
            return true
        } catch let error as NetworkError {
            if case let .noData(details) = error,
               let message = details?.lowercased(),
               message.contains("no historical data available") {
                historicalDataManager.recordEarliestAvailableDate(endDate, for: symbol)
                await logger.warning("⛔️ CHUNKED BACKFILL: \(symbol) reported no historical data prior to \(dateFormatter.string(from: endDate))")
                return false
            }
            await logger.error("❌ CHUNKED BACKFILL: Failed to fetch chunk \(yearOffset) for \(symbol): \(error.localizedDescription)")
            await logger.error("❌ CHUNKED BACKFILL ERROR for \(symbol) chunk \(yearOffset) at \(Date()): \(error.localizedDescription)")
            return true
        } catch {
            await logger.error("❌ CHUNKED BACKFILL: Failed to fetch chunk \(yearOffset) for \(symbol): \(error.localizedDescription)")
            await logger.error("❌ CHUNKED BACKFILL ERROR for \(symbol) chunk \(yearOffset) at \(Date()): \(error.localizedDescription)")
            return true
        }
    }
    
    /// Manually triggers a 5-year chunked historical data backfill for all symbols
    public func triggerFullHistoricalBackfill(symbols: [String]) async {
        let filteredSymbols = symbols.filter { !$0.isEmpty }
        
        guard !filteredSymbols.isEmpty else {
            await logger.info("No symbols to backfill")
            return
        }
        
        await logger.info("🚀 MANUAL TRIGGER: Starting full 5-year historical backfill for \(filteredSymbols.count) symbols")
        await backfillHistoricalData(for: filteredSymbols)
        await logger.info("🏁 MANUAL TRIGGER: Full 5-year historical backfill completed")
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
    
    // MARK: - Notifications
    
    private func sendBackfillNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}
