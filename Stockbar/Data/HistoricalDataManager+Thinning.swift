import Foundation

// Bounding and merging the history held in memory. Core Data keeps every
// snapshot; these only decide what stays loaded.
extension HistoricalDataManager {
    /// Bounds in-memory price history by resolution instead of count: every
    /// point from the last `intradayDays` (enough for the 1M charts), then the last point of each earlier
    /// day. A newest-N cap let dense intraday samples push a multi-year daily
    /// backfill out of memory.
    nonisolated static func thinnedPriceHistory(
        _ snapshots: [PriceSnapshot],
        now: Date = Date(),
        intradayDays: Int = 31,
        calendar: Calendar = .current
    ) -> [PriceSnapshot] {
        let cutoff = now.addingTimeInterval(-Double(intradayDays) * 86_400)
        var result: [PriceSnapshot] = []
        // The result is kept for as long as the app runs. Left to grow by
        // doubling, these arrays ended up nearly half empty.
        result.reserveCapacity(snapshots.count)
        var lastDay: Date?
        for snapshot in snapshots.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard snapshot.timestamp < cutoff else {
                result.append(snapshot)
                continue
            }
            let day = calendar.startOfDay(for: snapshot.timestamp)
            if day == lastDay {
                result[result.count - 1] = snapshot
            } else {
                result.append(snapshot)
                lastDay = day
            }
        }
        // Thinning that dropped a lot would leave the same waste the other way.
        guard result.count * 8 < result.capacity * 7 else { return result }
        var fitted: [PriceSnapshot] = []
        fitted.reserveCapacity(result.count)
        fitted.append(contentsOf: result)
        return fitted
    }

    /// How many more points a full price series makes room for.
    nonisolated static let priceHistoryGrowthStep = 256

    /// Adds a point to a series held in memory. A series gains a point at a
    /// time for as long as the app runs, and an array that is full doubles
    /// when it is appended to, which would undo the fit above at the first
    /// new price. A full series grows by a fixed step instead.
    nonisolated static func appendToPriceHistory(_ snapshot: PriceSnapshot, _ series: inout [PriceSnapshot]) {
        if series.count == series.capacity {
            series.reserveCapacity(series.count + priceHistoryGrowthStep)
        }
        series.append(snapshot)
    }

    /// Recorded snapshots are the record of what the portfolio was actually
    /// worth, so a recalculation only fills calendar days that have none. It
    /// must never replace them: it is limited by the price history available
    /// and works from today's holdings, and replacing recorded days with it
    /// threw away intraday history and real past values.
    /// Days of portfolio history kept in memory at full resolution.
    nonisolated static let fullResolutionPortfolioDays = 90

    /// In-memory portfolio history: full resolution for the recent window, and
    /// the last snapshot of each day before it (about 40k snapshots a year are
    /// recorded). Core Data keeps every snapshot; this only bounds memory.
    nonisolated static func thinnedPortfolioHistory(
        _ snapshots: [HistoricalPortfolioSnapshot],
        fullResolutionDays: Int = fullResolutionPortfolioDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistoricalPortfolioSnapshot] {
        guard let cutoff = calendar.date(byAdding: .day, value: -fullResolutionDays, to: calendar.startOfDay(for: now)) else {
            return snapshots
        }
        let sorted = snapshots.sorted { $0.date < $1.date }
        var result: [HistoricalPortfolioSnapshot] = []
        result.reserveCapacity(sorted.count)
        for snapshot in sorted {
            if snapshot.date < cutoff, let last = result.last,
               calendar.isDate(last.date, inSameDayAs: snapshot.date),
               last.currency == snapshot.currency {
                result[result.count - 1] = snapshot
            } else {
                result.append(snapshot)
            }
        }
        return result
    }

    nonisolated static func mergePortfolioHistory(
        existing: [HistoricalPortfolioSnapshot],
        recalculated: [HistoricalPortfolioSnapshot],
        calendar: Calendar = .current
    ) -> [HistoricalPortfolioSnapshot] {
        let recordedDays = Set(existing.map { calendar.startOfDay(for: $0.date) })
        let fills = recalculated.filter { !recordedDays.contains(calendar.startOfDay(for: $0.date)) }
        return (existing + fills).sorted { $0.date < $1.date }
    }
}
