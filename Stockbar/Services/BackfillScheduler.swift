//
//  BackfillScheduler.swift
//  Stockbar
//
//  Created by Development Team on 2025-10-06.
//  Intelligent automatic backfilling with gap detection and API quota management
//

import Foundation

/// Thread-safe scheduler for intelligent portfolio data backfilling
@MainActor
final class BackfillScheduler {

    // MARK: - Singleton

    static let shared = BackfillScheduler()

    // MARK: - Properties

    private let logger = Logger.shared
    private nonisolated let historicalDataManager = HistoricalDataManager.shared

    private var startupTimer: Timer?
    private var dailyCheckTimer: Timer?

    // MARK: - UserDefaults Keys

    private enum UserDefaultsKey {
        static let lastBackfillDate = "lastBackfillDate"
        static let lastBackfillTimestamp = "lastBackfillTimestamp"
    }

    // MARK: - Configuration

    private let startupDelaySeconds: TimeInterval = 1200  // 20 minutes
    private let dailyCheckHour = 15  // 3:00 PM
    private let dailyCheckMinute = 0
    private let backfillDays = 7  // Past week
    private let minimumSnapshotsPerDay = 6  // Expect at least 6 snapshots per day (every 5 min during market hours = ~78 per day, but we'll be conservative)

    // MARK: - Initialization

    private init() {
        Task {
            await logger.info("📅 BackfillScheduler initialized")
        }
    }

    // MARK: - Public Methods

    /// Starts the backfill scheduler with startup timer and daily checks
    /// - Parameter dataModel: DataModel instance for executing backfill
    func start(dataModel: DataModel) {
        Task {
            await logger.info("📅 SCHEDULER: Starting backfill scheduler...")

            // Schedule startup backfill check (10 minutes after app launch)
            scheduleStartupCheck(dataModel: dataModel)

            // Schedule daily 15:00 check
            scheduleDailyCheck(dataModel: dataModel)

            await logger.info("📅 SCHEDULER: Backfill scheduler started successfully")
        }
    }

    /// Stops all scheduled timers
    func stop() {
        Task {
            await logger.info("📅 SCHEDULER: Stopping backfill scheduler...")
        }

        startupTimer?.invalidate()
        startupTimer = nil

        dailyCheckTimer?.invalidate()
        dailyCheckTimer = nil

        Task {
            await logger.info("📅 SCHEDULER: Backfill scheduler stopped")
        }
    }

    /// Checks if backfill should run and executes if needed
    /// - Parameter dataModel: DataModel instance for executing backfill
    /// - Returns: True if backfill was executed, false if skipped
    @discardableResult
    func checkAndRunBackfillIfNeeded(dataModel: DataModel) async -> Bool {
        await logger.info("📅 CHECK: Starting backfill eligibility check...")

        // Check if already run today
        if hasRunToday() {
            await logger.info("📅 CHECK: Backfill already ran today - skipping")
            return false
        }

        // Detect gaps in portfolio data
        let gaps = await detectPortfolioDataGaps()

        if gaps.isEmpty {
            await logger.info("📅 CHECK: No gaps detected - portfolio data is complete")
            recordBackfillRun()  // Mark as run to prevent redundant checks
            return false
        }

        await logger.info("📅 CHECK: Found \(gaps.count) day(s) with missing data - executing backfill")
        await executeBackfill(dataModel: dataModel)
        recordBackfillRun()

        return true
    }

    // MARK: - Private Methods - Scheduling

    private func scheduleStartupCheck(dataModel: DataModel) {
        Task {
            await logger.info("📅 SCHEDULER: Scheduling startup check in \(Int(startupDelaySeconds / 60)) minutes")
        }

        startupTimer = Timer.scheduledTimer(withTimeInterval: startupDelaySeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.logger.info("📅 STARTUP: Running scheduled startup backfill check")
                await self.checkAndRunBackfillIfNeeded(dataModel: dataModel)
            }
        }
    }

    private func scheduleDailyCheck(dataModel: DataModel) {
        // Calculate next 15:00 occurrence
        let now = Date()
        let calendar = Calendar.current

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = dailyCheckHour
        components.minute = dailyCheckMinute
        components.second = 0

        guard var nextRun = calendar.date(from: components) else {
            Task {
                await logger.error("📅 SCHEDULER: Failed to calculate next daily check time")
            }
            return
        }

        // If 15:00 already passed today, schedule for tomorrow
        if nextRun <= now {
            nextRun = calendar.date(byAdding: .day, value: 1, to: nextRun) ?? nextRun
        }

        let timeInterval = nextRun.timeIntervalSince(now)

        Task {
            await logger.info("📅 SCHEDULER: Scheduling daily 15:00 check (next run in \(Int(timeInterval / 3600)) hours)")
        }

        dailyCheckTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.logger.info("📅 DAILY: Running scheduled 15:00 backfill check")
                await self.checkAndRunBackfillIfNeeded(dataModel: dataModel)

                // Reschedule for next day
                self.scheduleDailyCheck(dataModel: dataModel)
            }
        }
    }

    // MARK: - Private Methods - Gap Detection

    /// Detects gaps in portfolio snapshot data for the past week
    /// - Returns: Array of dates with insufficient data
    private func detectPortfolioDataGaps() async -> [Date] {
        await logger.info("🔍 GAP DETECTION: Analyzing portfolio data coverage...")

        let calendar = Calendar.current
        let now = Date()

        // Calculate start date (7 days ago)
        guard let startDate = calendar.date(byAdding: .day, value: -backfillDays, to: now) else {
            await logger.error("🔍 GAP DETECTION: Failed to calculate start date")
            return []
        }

        // Get all portfolio snapshots from memory
        let allSnapshots = historicalDataManager.historicalPortfolioSnapshots

        await logger.info("🔍 GAP DETECTION: Loaded \(allSnapshots.count) total snapshots from memory")

        // Filter snapshots within the past week (use 'date' instead of 'timestamp')
        let recentSnapshots = allSnapshots.filter { $0.date >= startDate }

        await logger.info("🔍 GAP DETECTION: Found \(recentSnapshots.count) snapshots in past \(backfillDays) days")

        // Group snapshots by day
        var snapshotsByDay: [String: Int] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        for snapshot in recentSnapshots {
            let dayKey = dateFormatter.string(from: snapshot.date)
            snapshotsByDay[dayKey, default: 0] += 1
        }

        // Check each day for sufficient data
        var gapDays: [Date] = []
        var currentDate = startDate

        while currentDate <= now {
            let dayKey = dateFormatter.string(from: currentDate)
            let snapshotCount = snapshotsByDay[dayKey, default: 0]

            // Skip weekends (no market data expected)
            let weekday = calendar.component(.weekday, from: currentDate)
            let isWeekend = weekday == 1 || weekday == 7  // Sunday = 1, Saturday = 7

            if !isWeekend && snapshotCount < minimumSnapshotsPerDay {
                await logger.info("🔍 GAP: \(dayKey) has only \(snapshotCount) snapshots (expected \(minimumSnapshotsPerDay)+)")
                gapDays.append(currentDate)
            }

            // Move to next day
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDate) else { break }
            currentDate = nextDay
        }

        await logger.info("🔍 GAP DETECTION: Found \(gapDays.count) day(s) with insufficient data")

        return gapDays
    }

    // MARK: - Private Methods - Backfill Execution

    private func executeBackfill(dataModel: DataModel) async {
        await logger.info("🔄 BACKFILL: Starting intelligent backfill for past \(backfillDays) days")

        // Use existing backfill method
        await dataModel.calculateRetroactivePortfolioHistory(days: backfillDays)

        // Reload snapshots into memory
        await historicalDataManager.reloadPortfolioSnapshotsFromCoreData()

        await logger.info("✅ BACKFILL: Intelligent backfill completed")
    }

    // MARK: - Private Methods - Persistence

    /// Checks if backfill has already run today
    /// - Returns: True if backfill ran today, false otherwise
    private func hasRunToday() -> Bool {
        let defaults = UserDefaults.standard

        guard let lastRunTimestamp = defaults.object(forKey: UserDefaultsKey.lastBackfillTimestamp) as? Double else {
            Task {
                await logger.info("📅 PERSISTENCE: No previous backfill run recorded")
            }
            return false
        }

        let lastRunDate = Date(timeIntervalSince1970: lastRunTimestamp)
        let calendar = Calendar.current

        let lastRunDay = calendar.startOfDay(for: lastRunDate)
        let today = calendar.startOfDay(for: Date())

        let hasRun = lastRunDay == today

        if hasRun {
            Task {
                await logger.info("📅 PERSISTENCE: Last backfill ran today at \(lastRunDate)")
            }
        } else {
            Task {
                await logger.info("📅 PERSISTENCE: Last backfill ran on \(lastRunDate) - eligible for new run")
            }
        }

        return hasRun
    }

    /// Records the current backfill run timestamp
    private func recordBackfillRun() {
        let now = Date()
        let defaults = UserDefaults.standard

        defaults.set(now.timeIntervalSince1970, forKey: UserDefaultsKey.lastBackfillTimestamp)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        defaults.set(dateFormatter.string(from: now), forKey: UserDefaultsKey.lastBackfillDate)

        Task {
            await logger.info("📅 PERSISTENCE: Recorded backfill run at \(now)")
        }
    }

    // MARK: - Public Helpers

    /// Returns the last backfill run date as a formatted string
    nonisolated func getLastBackfillDate() -> String? {
        return UserDefaults.standard.string(forKey: UserDefaultsKey.lastBackfillDate)
    }
}
