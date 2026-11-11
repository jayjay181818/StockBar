//
//  HistoricalDataCoordinator.swift
//  Stockbar
//
//  Historical data backfill coordinator - manages all historical data fetching
//  Extracted from DataModel for better separation of concerns
//

import Foundation

struct HistoricalDataStatus: Sendable {
    let isRunningComprehensive: Bool
    let isRunningStandard: Bool
    let lastComprehensiveCheck: Date
    let nextComprehensiveCheck: Date
}

enum BackfillOutcome: Codable, Equatable, Sendable {
    case addedData(Int)
    case alreadyComplete
    case earliestDataBoundary
    case rateLimited
    case noData
    case failed
}

struct BackfillAttemptState: Codable, Equatable, Sendable {
    var attemptCount: Int
    var consecutiveFailures: Int
    var lastAttempt: Date
    var nextEligibleAt: Date
    var outcome: BackfillOutcome
}

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
    private let attemptStateKey = "historicalBackfillAttemptState.v1"
    
    // MARK: - Configuration
    
    /// Cooldown period between comprehensive checks (read from UserDefaults)
    private var comprehensiveCheckCooldown: TimeInterval {
        let hours = StockbarRuntimeStorage.userDefaults.integer(forKey: "backfillCooldownHours")
        return hours == 0 ? 1800 : TimeInterval(hours * 3600)
    }
    
    /// Backfill schedule mode (read from UserDefaults)
    private var backfillSchedule: String {
        StockbarRuntimeStorage.userDefaults.string(forKey: "backfillSchedule") ?? "startup"
    }
    
    /// Whether to show notifications for backfill progress
    private var backfillNotifications: Bool {
        StockbarRuntimeStorage.userDefaults.bool(forKey: "backfillNotifications")
    }

    private let benchmarkBackfillDays = 30
    private let benchmarkCoverageThreshold: Double = 0.10
    
    init(networkService: NetworkService, historicalDataManager: HistoricalDataManager) {
        self.networkService = networkService
        self.historicalDataManager = historicalDataManager
        if let state = loadAttemptState() {
            lastComprehensiveCheckTime = state.lastAttempt
        }
    }
    
    // MARK: - Startup & Scheduling
    
    /// Performs startup backfill check if enabled by user preferences.
    /// `isPaused` is checked again after the startup delay, so a settings
    /// import that started in the meantime stops the backfill.
    func performStartupBackfillIfNeeded(symbols: [String], isPaused: () -> Bool = { false }) async {
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

        guard !isPaused() else {
            await logger.info("🔍 STARTUP: Skipping startup backfill - background work is paused for a settings import")
            return
        }
        
        await logger.info("🔍 STARTUP: Checking for missing historical data coverage")
        await logger.info("🚀 AUTO-BACKFILL: Starting automatic historical data check")
        
        // Check if this looks like a first run or we have very little historical data
        let totalHistoricalSnapshots = historicalDataManager.priceSnapshots.values.map { $0.count }.reduce(0, +)
        let symbolCount = symbols.count

        // Minimal data may bypass cooldown only for the first persisted attempt.
        if totalHistoricalSnapshots < (symbolCount * 100), loadAttemptState() == nil {
            await logger.warning("🔍 STARTUP: Detected minimal historical data (\(totalHistoricalSnapshots) snapshots for \(symbolCount) symbols, avg \(totalHistoricalSnapshots / max(1, symbolCount)) per symbol). Forcing immediate comprehensive backfill bypassing cooldown.")
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
        let now = Date()
        if let state = loadAttemptState(), now < state.nextEligibleAt {
            await logger.info("🔍 COMPREHENSIVE: Skipping until persisted retry time \(state.nextEligibleAt)")
            return
        }
        let timeSinceLastCheck = now.timeIntervalSince(lastComprehensiveCheckTime)
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
            // 10% let ten months of data count as five years covered, so older history was never
            // fetched. The per-year pass below skips years that are already complete.
            let coverageThreshold = isBenchmark ? benchmarkCoverageThreshold : 0.80

            // Below the threshold over the coverage window, trigger the per-year backfill
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
            let outcomes = await staggeredBackfillHistoricalData(for: symbolsNeedingBackfill)
            let outcome = aggregate(outcomes)
            recordAttempt(outcome: outcome)

            if backfillNotifications, case .addedData = outcome {
                sendBackfillNotification(title: "Historical Data Backfill Complete", message: "Successfully backfilled \(symbolsNeedingBackfill.count) symbols")
            }
            await logComprehensiveOutcome(outcome, symbolCount: symbolsNeedingBackfill.count)
        } else {
            await logger.info("✅ COMPREHENSIVE: All symbols have good 5-year historical coverage")
            recordAttempt(outcome: .alreadyComplete)
        }
    }
    
    // MARK: - Backfill Execution
    
    /// Staggered backfill that processes symbols with delays to prevent UI blocking
    private func staggeredBackfillHistoricalData(for symbols: [String]) async -> [BackfillOutcome] {
        await logger.info("⏱️ STAGGERED: Starting staggered 5-year backfill for \(symbols.count) symbols")
        let startTime = Date()
        var outcomes: [BackfillOutcome] = []

        for (index, symbol) in symbols.enumerated() {
            let progress = "\(index + 1)/\(symbols.count)"
            await logger.info("⏱️ STAGGERED: [\(progress)] Processing \(symbol)...")

            let symbolOutcomes = await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)
            outcomes.append(contentsOf: symbolOutcomes)
            let symbolOutcome = aggregate(symbolOutcomes)

            // Log progress update
            let elapsed = Date().timeIntervalSince(startTime)
            let avgTimePerSymbol = elapsed / Double(index + 1)
            let remaining = Int(avgTimePerSymbol * Double(symbols.count - index - 1) / 60)
            await logStaggeredOutcome(
                symbolOutcome,
                symbol: symbol,
                progress: progress,
                remainingMinutes: remaining
            )

            if index < symbols.count - 1 {
                await logger.debug("⏱️ STAGGERED: Waiting 10 seconds before next symbol...")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }

        let totalTime = Int(Date().timeIntervalSince(startTime) / 60)
        await logger.info("🏁 STAGGERED: Finished backfill attempts for \(symbols.count) symbols in \(totalTime) minutes")
        return outcomes
    }
    
    /// Backfills historical data for specified symbols in chunks to avoid hanging
    public func backfillHistoricalData(for symbols: [String]) async {
        await logger.info("🚀 CHUNKED BACKFILL: Starting 5-year chunked historical data backfill")
        
        for symbol in symbols {
            _ = await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        await logger.info("🏁 CHUNKED BACKFILL: Completed 5-year chunked backfill for all symbols")
    }
    
    /// Backfills historical data for a single symbol in yearly chunks
    private func backfillHistoricalDataForSymbol(_ symbol: String, yearsToFetch: Int) async -> [BackfillOutcome] {
        if SymbolMetadata.isBenchmarkSymbol(symbol) {
            return [await backfillBenchmarkHistory(for: symbol)]
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
        var outcomes: [BackfillOutcome] = []
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
            
            let outcome = await fetchHistoricalDataChunk(
                for: symbol,
                from: chunkStartDate,
                to: chunkEndDate,
                yearOffset: yearOffset
            )
            outcomes.append(outcome)
            if outcome == .earliestDataBoundary {
                await logger.info("⏹️ CHUNKED BACKFILL: Stopping older chunks for \(symbol) after reaching earliest available data")
                break
            }
            if outcome == .rateLimited {
                await logger.warning("⏹️ CHUNKED BACKFILL: Rate limited; deferring remaining chunks for \(symbol)")
                break
            }
            if outcome == .failed {
                await logger.warning("⏹️ CHUNKED BACKFILL: Fetch failed; deferring remaining chunks for \(symbol)")
                break
            }
            
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        
        await logger.info("✅ CHUNKED BACKFILL: Completed \(yearsToFetch)-year backfill for \(symbol)")
        return outcomes.isEmpty ? [.alreadyComplete] : outcomes
    }

    private func backfillBenchmarkHistory(for symbol: String) async -> BackfillOutcome {
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -benchmarkBackfillDays, to: endDate) else {
            await logger.warning("⚠️ BENCHMARK: Unable to compute backfill window for \(symbol)")
            return .failed
        }

        await logger.info("🧭 BENCHMARK: Backfilling last \(benchmarkBackfillDays) days for \(symbol)")
        return await fetchHistoricalDataChunk(for: symbol, from: startDate, to: endDate, yearOffset: 1)
    }
    
    /// Fetches a single chunk of historical data
    private func fetchHistoricalDataChunk(
        for symbol: String,
        from startDate: Date,
        to endDate: Date,
        yearOffset: Int
    ) async -> BackfillOutcome {
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
                    BackfillScheduler.shared.historyDidChange()
                    await logger.info("✅ CHUNKED BACKFILL: Added \(newSnapshots.count) new data points for \(symbol) chunk \(yearOffset)")
                    
                    if let first = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).first,
                       let last = newSnapshots.sorted(by: { $0.timestamp < $1.timestamp }).last {
                        await logger.info("📊 CHUNKED BACKFILL: \(symbol) chunk \(yearOffset) range: \(dateFormatter.string(from: first.timestamp)) to \(dateFormatter.string(from: last.timestamp))")
                    }
                    return .addedData(newSnapshots.count)
                } else {
                    await logger.info("ℹ️ CHUNKED BACKFILL: No new data needed for \(symbol) chunk \(yearOffset) - all dates already exist")
                    return .alreadyComplete
                }
            } else {
                await logger.warning("⚠️ CHUNKED BACKFILL: No data received for \(symbol) chunk \(yearOffset)")
                return .noData
            }
        } catch let error as ProviderAccessError {
            await logger.debug(
                "CHUNKED BACKFILL: \(symbol) skipped because provider access is disabled: \(error.localizedDescription)"
            )
            return .failed
        } catch let error as NetworkError {
            if case let .noData(details) = error,
               let message = details?.lowercased(),
               message.contains("no historical data available") {
                // The helper reports rate limits and outages with the same message, and the
                // boundary is permanent. Record it only when it cannot be one of those: the chunk
                // ends well in the past and nothing older is already stored for the symbol.
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
                let hasOlderData = (historicalDataManager.priceSnapshots[symbol] ?? [])
                    .contains { $0.timestamp < endDate }
                guard endDate < cutoff, !hasOlderData else {
                    await logger.warning("⚠️ CHUNKED BACKFILL: No data received for \(symbol) chunk \(yearOffset); not treated as the start of its history")
                    return .noData
                }
                historicalDataManager.recordEarliestAvailableDate(endDate, for: symbol)
                await logger.warning("⛔️ CHUNKED BACKFILL: \(symbol) reported no historical data prior to \(dateFormatter.string(from: endDate))")
                return .earliestDataBoundary
            }
            if case .rateLimit = error {
                await logger.warning("❌ CHUNKED BACKFILL: Rate limited for \(symbol) chunk \(yearOffset)")
                return .rateLimited
            }
            await logger.error("❌ CHUNKED BACKFILL: Failed to fetch chunk \(yearOffset) for \(symbol): \(error.localizedDescription)")
            await logger.error("❌ CHUNKED BACKFILL ERROR for \(symbol) chunk \(yearOffset) at \(Date()): \(error.localizedDescription)")
            return .failed
        } catch {
            await logger.error("❌ CHUNKED BACKFILL: Failed to fetch chunk \(yearOffset) for \(symbol): \(error.localizedDescription)")
            await logger.error("❌ CHUNKED BACKFILL ERROR for \(symbol) chunk \(yearOffset) at \(Date()): \(error.localizedDescription)")
            return .failed
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
        var outcomes: [BackfillOutcome] = []
        for symbol in filteredSymbols {
            outcomes.append(contentsOf: await backfillHistoricalDataForSymbol(symbol, yearsToFetch: 5))
        }
        recordAttempt(outcome: aggregate(outcomes))
        await logger.info("🏁 MANUAL TRIGGER: Full 5-year historical backfill completed")
    }
    
    /// Returns the current status of automatic historical data checking
    public func getHistoricalDataStatus() -> HistoricalDataStatus {
        let nextCheck = lastComprehensiveCheckTime.addingTimeInterval(comprehensiveCheckCooldown)
        return HistoricalDataStatus(
            isRunningComprehensive: isRunningComprehensiveCheck,
            isRunningStandard: isRunningStandardCheck,
            lastComprehensiveCheck: lastComprehensiveCheckTime,
            nextComprehensiveCheck: nextCheck
        )
    }
    
    // MARK: - Notifications
    
    private func sendBackfillNotification(title: String, message: String) {
        Task {
            await StockbarNotificationPoster.post(title: title, body: message)
        }
    }

    private func loadAttemptState() -> BackfillAttemptState? {
        guard let data = StockbarRuntimeStorage.userDefaults.data(forKey: attemptStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BackfillAttemptState.self, from: data)
    }

    private func recordAttempt(outcome: BackfillOutcome, now: Date = Date()) {
        let previous = loadAttemptState()
        let isFailure = outcome == .failed || outcome == .rateLimited
        let failures = isFailure ? (previous?.consecutiveFailures ?? 0) + 1 : 0
        let exponentialDelay = min(86_400, 60 * pow(2, Double(max(0, failures - 1))))
        let delay = isFailure ? max(comprehensiveCheckCooldown, exponentialDelay) : comprehensiveCheckCooldown
        let state = BackfillAttemptState(
            attemptCount: (previous?.attemptCount ?? 0) + 1,
            consecutiveFailures: failures,
            lastAttempt: now,
            nextEligibleAt: now.addingTimeInterval(delay),
            outcome: outcome
        )
        if let data = try? JSONEncoder().encode(state) {
            StockbarRuntimeStorage.userDefaults.set(data, forKey: attemptStateKey)
        }
        lastComprehensiveCheckTime = now
    }

    private func aggregate(_ outcomes: [BackfillOutcome]) -> BackfillOutcome {
        if outcomes.contains(.rateLimited) { return .rateLimited }
        if outcomes.contains(.failed) { return .failed }
        let added = outcomes.reduce(0) { total, outcome in
            if case .addedData(let count) = outcome { return total + count }
            return total
        }
        if added > 0 { return .addedData(added) }
        if outcomes.contains(.earliestDataBoundary) { return .earliestDataBoundary }
        if outcomes.contains(.noData) { return .noData }
        return .alreadyComplete
    }

    private func logStaggeredOutcome(
        _ outcome: BackfillOutcome,
        symbol: String,
        progress: String,
        remainingMinutes: Int
    ) async {
        let suffix = "Estimated time remaining: ~\(remainingMinutes) minutes"
        switch outcome {
        case .addedData(let count):
            await logger.info("✅ STAGGERED: [\(progress)] Added \(count) points for \(symbol). \(suffix)")
        case .alreadyComplete:
            await logger.info("✅ STAGGERED: [\(progress)] \(symbol) was already complete. \(suffix)")
        case .earliestDataBoundary:
            await logger.info("⛔️ STAGGERED: [\(progress)] \(symbol) reached its earliest-data boundary. \(suffix)")
        case .rateLimited:
            await logger.warning("⏸️ STAGGERED: [\(progress)] \(symbol) was rate limited. \(suffix)")
        case .noData:
            await logger.warning("⚠️ STAGGERED: [\(progress)] No data was available for \(symbol). \(suffix)")
        case .failed:
            await logger.warning("⚠️ STAGGERED: [\(progress)] \(symbol) backfill failed. \(suffix)")
        }
    }

    private func logComprehensiveOutcome(_ outcome: BackfillOutcome, symbolCount: Int) async {
        switch outcome {
        case .addedData(let count):
            await logger.info(
                "✅ COMPREHENSIVE: Added \(count) historical points across \(symbolCount) symbols"
            )
        case .alreadyComplete:
            await logger.info("✅ COMPREHENSIVE: All \(symbolCount) symbols were already complete")
        case .earliestDataBoundary:
            await logger.info("⛔️ COMPREHENSIVE: Reached the earliest-data boundary")
        case .rateLimited:
            await logger.warning("⏸️ COMPREHENSIVE: Backfill deferred after rate limiting")
        case .noData:
            await logger.warning("⚠️ COMPREHENSIVE: Backfill finished without provider data")
        case .failed:
            await logger.warning("⚠️ COMPREHENSIVE: Backfill attempt failed and was recorded for retry")
        }
    }
}
