import CoreGraphics
import Foundation

/// Pure, UI-free helpers shared by the chart views so their behaviour can be tested directly.
enum ChartSeriesProcessing {
    static let downsampleThreshold = 1_000
    static let downsampleTarget = 800

    // MARK: - Downsampling

    /// Min/max bucketing: every bucket keeps its lowest and highest point so price extremes
    /// survive, and the first and last points are always kept so the latest value is never
    /// dropped. Buckets are `ceil`-sized so the result never exceeds `target`. Expects `points`
    /// in ascending date order and leaves series at or below `threshold` untouched.
    static func downsample(
        _ points: [ChartDataPoint],
        threshold: Int = downsampleThreshold,
        target: Int = downsampleTarget
    ) -> [ChartDataPoint] {
        guard target >= 4, points.count > max(threshold, target), let first = points.first, let last = points.last else {
            return points
        }
        let interiorCount = points.count - 2
        let bucketCount = max(1, (target - 2) / 2)
        let bucketSize = Int((Double(interiorCount) / Double(bucketCount)).rounded(.up))

        var result: [ChartDataPoint] = [first]
        result.reserveCapacity(target)
        var start = 1
        let end = points.count - 1
        while start < end {
            let stop = min(start + bucketSize, end)
            var minIndex = start
            var maxIndex = start
            for index in start..<stop {
                if points[index].value < points[minIndex].value { minIndex = index }
                if points[index].value > points[maxIndex].value { maxIndex = index }
            }
            if minIndex == maxIndex {
                result.append(points[minIndex])
            } else if minIndex < maxIndex {
                result.append(points[minIndex])
                result.append(points[maxIndex])
            } else {
                result.append(points[maxIndex])
                result.append(points[minIndex])
            }
            start = stop
        }
        result.append(last)
        return result
    }

    // MARK: - Filtering

    /// Applies the value-threshold and date-window filters. `dateWindow.toExclusive` is an
    /// exclusive upper bound.
    static func applyFilters(
        _ data: [ChartDataPoint],
        valueThreshold: Double,
        dateWindow: (from: Date, toExclusive: Date)?
    ) -> [ChartDataPoint] {
        var filtered = data
        if valueThreshold > 0 {
            filtered = filtered.filter { abs($0.value) >= valueThreshold }
        }
        if let dateWindow {
            filtered = filtered.filter { $0.date >= dateWindow.from && $0.date < dateWindow.toExclusive }
        }
        return filtered
    }

    /// Date-picker values carry a time of day. A custom range covers whole days: it starts at
    /// the start of the first day and ends before the start of the day after the last one.
    static func normalizedCustomRange(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> (from: Date, toExclusive: Date) {
        let firstDay = calendar.startOfDay(for: min(start, end))
        let lastDay = calendar.startOfDay(for: max(start, end))
        let toExclusive = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return (firstDay, toExclusive)
    }

    /// True when two series draw identically, so a refresh can keep the existing chart.
    static func isSameSeries(_ lhs: [ChartDataPoint], _ rhs: [ChartDataPoint]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where left.date != right.date || left.value != right.value {
            return false
        }
        return true
    }

    // MARK: - Selection and export

    /// Point ids are regenerated on every load, so a selection is carried across reloads by date.
    static func remapSelection(
        selected: Set<UUID>,
        oldData: [ChartDataPoint],
        newData: [ChartDataPoint]
    ) -> Set<UUID> {
        guard !selected.isEmpty else { return [] }
        let dates = Set(oldData.filter { selected.contains($0.id) }.map(\.date))
        guard !dates.isEmpty else { return [] }
        return Set(newData.filter { dates.contains($0.date) }.map(\.id))
    }

    /// The points to export: the full-resolution series, narrowed by the selection when there
    /// is one. The selection is matched by date, never by id. When the display was downsampled
    /// the selected span is exported in full; otherwise exactly the selected points.
    static func exportSeries(
        full: [ChartDataPoint],
        displayed: [ChartDataPoint],
        selected: Set<UUID>
    ) -> [ChartDataPoint] {
        guard !selected.isEmpty else { return full }
        let selectedDates = displayed.filter { selected.contains($0.id) }.map(\.date)
        guard let lowest = selectedDates.min(), let highest = selectedDates.max() else { return full }
        if full.count > displayed.count {
            return full.filter { $0.date >= lowest && $0.date <= highest }
        }
        let dates = Set(selectedDates)
        return full.filter { dates.contains($0.date) }
    }

    // MARK: - Dates

    /// Day-only sources stamp points at UTC midnight. Formatting those in the local zone shows
    /// the previous day west of UTC, so they are formatted in UTC without a time of day.
    static func isDayGranular(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds.truncatingRemainder(dividingBy: 86_400) == 0
    }

    static func isDayGranular(_ points: [ChartDataPoint]) -> Bool {
        !points.isEmpty && points.allSatisfy { isDayGranular($0.date) }
    }

    /// Index of the date closest to `target`; nil for an empty list.
    static func nearestIndex(in dates: [Date], to target: Date) -> Int? {
        var best: Int?
        var bestDistance = TimeInterval.infinity
        for (index, date) in dates.enumerated() {
            let distance = abs(date.timeIntervalSince(target))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// X domain for a candlestick chart: the candles, padded by half a candle so the first
    /// and last bodies are not clipped. Annotations never widen it.
    static func paddedDateDomain(_ dates: [Date]) -> ClosedRange<Date>? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        guard last > first else {
            return first.addingTimeInterval(-3_600)...last.addingTimeInterval(3_600)
        }
        let padding = last.timeIntervalSince(first) / Double(max(dates.count - 1, 1)) / 2
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }
}

/// Maps pointer positions in the chart interaction view to the chart plot area.
enum ChartHitTesting {
    /// The interaction view is flipped, so its y axis points down like the chart's.
    /// Subtracting the plot-area origin gives the coordinates `ChartProxy` expects.
    static func plotPoint(fromViewPoint point: CGPoint, plotOrigin: CGPoint) -> CGPoint {
        CGPoint(x: point.x - plotOrigin.x, y: point.y - plotOrigin.y)
    }

    /// Ids of the points whose plot-area position lies inside a rectangle given in view space.
    static func selectedIDs(
        inViewRect viewRect: CGRect,
        plotOrigin: CGPoint,
        positions: [(id: UUID, point: CGPoint)]
    ) -> Set<UUID> {
        let plotRect = viewRect.offsetBy(dx: -plotOrigin.x, dy: -plotOrigin.y)
        return Set(positions.filter { plotRect.contains($0.point) }.map(\.id))
    }
}
