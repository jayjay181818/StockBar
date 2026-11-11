import CoreGraphics
import Foundation

/// Pure, UI-free helpers shared by the chart views so their behaviour can be tested directly.
enum ChartSeriesProcessing {
    static let downsampleThreshold = 1_000
    static let downsampleTarget = 800

    // MARK: - Comparison

    /// Each series as a fractional change from its value on the first date
    /// every series has data for, clipped to start there. Rebasing each to its
    /// own first point compared changes over different periods.
    static func rebasedToCommonStart(_ series: [String: [ChartDataPoint]]) -> [String: [ChartDataPoint]] {
        let usable = series.mapValues { points in points.filter { $0.value.isFinite } }.filter { !$0.value.isEmpty }
        guard let start = usable.values.compactMap({ $0.first?.date }).max() else { return [:] }
        var result: [String: [ChartDataPoint]] = [:]
        for (symbol, points) in usable {
            let window = points.filter { $0.date >= start }
            guard let base = window.first?.value, base != 0 else { continue }
            result[symbol] = window.map {
                ChartDataPoint(date: $0.date, value: ($0.value - base) / base, symbol: $0.symbol)
            }
        }
        return result
    }

    // MARK: - Candle aggregation

    static let maxCandles = 400

    /// Merges candles until at most `maxCandles` remain: daily candles into
    /// calendar weeks, months, quarters or years, shorter ones into equal runs.
    /// Thousands of one-pixel daily candles are unreadable and slow to draw.
    /// Expects ascending order.
    static func aggregatedCandles(_ candles: [OHLCDataPoint], maxCandles: Int = maxCandles) -> [OHLCDataPoint] {
        guard maxCandles > 0, candles.count > maxCandles else { return candles }

        let gaps = zip(candles.dropFirst(), candles).map { $0.timestamp.timeIntervalSince($1.timestamp) }.sorted()
        let isDaily = (gaps.isEmpty ? 0 : gaps[gaps.count / 2]) >= 20 * 3600

        if isDaily {
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let steps: [(Date) -> DateComponents] = [
                { calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) },
                { calendar.dateComponents([.year, .month], from: $0) },
                { calendar.dateComponents([.year, .quarter], from: $0) },
                { calendar.dateComponents([.year], from: $0) }
            ]
            var merged = candles
            for bucket in steps {
                merged = mergeRuns(candles) { bucket($0.timestamp) == bucket($1.timestamp) }
                if merged.count <= maxCandles { return merged }
            }
            return merged
        }

        let size = Int((Double(candles.count) / Double(maxCandles)).rounded(.up))
        return stride(from: 0, to: candles.count, by: size).compactMap { start in
            mergedCandle(Array(candles[start..<min(start + size, candles.count)]))
        }
    }

    private static func mergeRuns(
        _ candles: [OHLCDataPoint],
        sameBucket: (OHLCDataPoint, OHLCDataPoint) -> Bool
    ) -> [OHLCDataPoint] {
        var result: [OHLCDataPoint] = []
        var run: [OHLCDataPoint] = []
        for candle in candles {
            if let first = run.first, !sameBucket(first, candle) {
                if let merged = mergedCandle(run) { result.append(merged) }
                run.removeAll(keepingCapacity: true)
            }
            run.append(candle)
        }
        if let merged = mergedCandle(run) { result.append(merged) }
        return result
    }

    /// Opens at the first candle, closes at the last, and spans every high and
    /// low between. Volume is the total, or nil if no candle reported any.
    private static func mergedCandle(_ run: [OHLCDataPoint]) -> OHLCDataPoint? {
        guard let first = run.first, let last = run.last else { return nil }
        guard run.count > 1 else { return first }
        let volumes = run.compactMap(\.volume)
        return OHLCDataPoint(
            timestamp: first.timestamp,
            open: first.open,
            high: run.map(\.high).max() ?? first.high,
            low: run.map(\.low).min() ?? first.low,
            close: last.close,
            volume: volumes.isEmpty ? nil : volumes.reduce(0) { $0.addingReportingOverflow($1).partialValue }
        )
    }

    // MARK: - Zoom

    static let maxZoom = 10.0

    /// The dates shown at `scale` (1 is the whole series). `panFraction` moves
    /// the window by that fraction of its own width, positive towards earlier
    /// dates, and never past either end. Nil when there is nothing to zoom.
    static func zoomedDomain(
        first: Date,
        last: Date,
        scale: Double,
        panFraction: Double
    ) -> ClosedRange<Date>? {
        let full = last.timeIntervalSince(first)
        guard scale.isFinite, scale > 1.001, full.isFinite, full > 0 else { return nil }
        let visible = full / min(scale, maxZoom)
        let slack = (full - visible) / 2
        let pan = panFraction.isFinite ? panFraction : 0
        let shift = max(-slack, min(slack, -pan * visible))
        let middle = first.addingTimeInterval(full / 2 + shift)
        return middle.addingTimeInterval(-visible / 2)...middle.addingTimeInterval(visible / 2)
    }

    // MARK: - Axis domain

    /// The range of the finite values with `padding` (a fraction of the span)
    /// added at each end. Never empty, inverted or non-finite, any of which
    /// crashes a chart scale; `fallback` is used when no value is finite.
    static func paddedDomain(
        _ values: [Double],
        padding: Double = 0.05,
        fallback: ClosedRange<Double> = 0...1
    ) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return fallback }
        let span = high - low
        guard span.isFinite, span > 0 else {
            let margin = max(abs(low) * padding, 0.5)
            return (low - margin)...(low + margin)
        }
        let lower = low - span * padding
        let upper = high + span * padding
        guard lower.isFinite, upper.isFinite, lower < upper else { return fallback }
        return lower...upper
    }

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
