import SwiftUI

enum MenuChartTimeRange: String, CaseIterable {
    case day = "1D"
    case week = "1W"
    case month = "1M"

    var description: String {
        switch self {
        case .day: return "1 Day"
        case .week: return "1 Week"
        case .month: return "1 Month"
        }
    }

    var timeInterval: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }

    var chartTimeRange: ChartTimeRange {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }

    func startDate(from endDate: Date = Date()) -> Date {
        endDate.addingTimeInterval(-timeInterval)
    }
}

struct MenuChartDataPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let price: Double
    let symbol: String

    init(id: UUID = UUID(), date: Date, price: Double, symbol: String) {
        self.id = id
        self.date = date
        self.price = price
        self.symbol = symbol
    }
}

enum MenuChartDataBuilder {
    static let defaultMaxPoints = 1000
    private static let dayBucketSize: TimeInterval = 120

    static func prepareValuePoints(
        storedPoints: [ChartDataPoint],
        currentValue: Double,
        symbol: String,
        range: MenuChartTimeRange,
        now: Date = Date(),
        maxPoints: Int = defaultMaxPoints
    ) -> [MenuChartDataPoint] {
        prepareMenuPoints(
            storedPoints: storedPoints.map {
                MenuChartDataPoint(date: $0.date, price: $0.value, symbol: symbol)
            },
            currentValue: currentValue,
            symbol: symbol,
            range: range,
            now: now,
            maxPoints: maxPoints
        )
    }

    static func preparePricePoints(
        storedPoints: [MenuChartDataPoint],
        currentPrice: Double,
        symbol: String,
        range: MenuChartTimeRange,
        now: Date = Date(),
        maxPoints: Int = defaultMaxPoints
    ) -> [MenuChartDataPoint] {
        prepareMenuPoints(
            storedPoints: storedPoints,
            currentValue: currentPrice,
            symbol: symbol,
            range: range,
            now: now,
            maxPoints: maxPoints
        )
    }

    private static func prepareMenuPoints(
        storedPoints: [MenuChartDataPoint],
        currentValue: Double,
        symbol: String,
        range: MenuChartTimeRange,
        now: Date,
        maxPoints: Int
    ) -> [MenuChartDataPoint] {
        let startDate = range.startDate(from: now)
        var points = storedPoints
            .filter { $0.date >= startDate && $0.date <= now && $0.price.isFinite && $0.price > 0 }
            .sorted { $0.date < $1.date }

        if range == .day {
            points = latestPointPerBucket(points, bucketSize: dayBucketSize)
        }

        appendCurrentEndpoint(
            to: &points,
            currentValue: currentValue,
            symbol: symbol,
            range: range,
            startDate: startDate,
            now: now
        )

        guard points.count >= 2 else {
            return []
        }

        return downsample(points, maxPoints: maxPoints)
    }

    private static func appendCurrentEndpoint(
        to points: inout [MenuChartDataPoint],
        currentValue: Double,
        symbol: String,
        range: MenuChartTimeRange,
        startDate: Date,
        now: Date
    ) {
        guard currentValue.isFinite, currentValue > 0 else {
            return
        }

        let endpoint = MenuChartDataPoint(date: now, price: currentValue, symbol: symbol)

        if points.isEmpty {
            points = [
                MenuChartDataPoint(date: startDate, price: currentValue, symbol: symbol),
                endpoint
            ]
            return
        }

        if let last = points.last {
            if range == .day,
               bucketIndex(for: last.date, bucketSize: dayBucketSize) == bucketIndex(for: now, bucketSize: dayBucketSize) {
                points[points.count - 1] = endpoint
            } else if abs(last.date.timeIntervalSince(now)) < 1 {
                points[points.count - 1] = endpoint
            } else {
                points.append(endpoint)
            }
        }

        if points.count == 1 {
            points.insert(
                MenuChartDataPoint(date: startDate, price: points[0].price, symbol: symbol),
                at: 0
            )
        }
    }

    private static func latestPointPerBucket(
        _ points: [MenuChartDataPoint],
        bucketSize: TimeInterval
    ) -> [MenuChartDataPoint] {
        guard bucketSize > 0, !points.isEmpty else {
            return points
        }

        var latestByBucket: [Int: MenuChartDataPoint] = [:]
        for point in points {
            let bucket = bucketIndex(for: point.date, bucketSize: bucketSize)
            if let existing = latestByBucket[bucket], existing.date > point.date {
                continue
            }
            latestByBucket[bucket] = point
        }

        return latestByBucket
            .keys
            .sorted()
            .compactMap { latestByBucket[$0] }
    }

    static func downsample(
        _ points: [MenuChartDataPoint],
        maxPoints: Int
    ) -> [MenuChartDataPoint] {
        guard maxPoints > 1, points.count > maxPoints else {
            return points
        }

        // Each bucket keeps its lowest and highest point, so a spike or dip is
        // never thinned away; picking every nth point lost them.
        let lastIndex = points.count - 1
        guard maxPoints >= 4 else { return [points[0], points[lastIndex]] }
        let bucketCount = max(1, (maxPoints - 2) / 2)
        let interior = lastIndex - 1
        let bucketSize = max(1, Int((Double(interior) / Double(bucketCount)).rounded(.up)))

        var sampled: [MenuChartDataPoint] = [points[0]]
        sampled.reserveCapacity(maxPoints)
        var start = 1
        while start < lastIndex {
            let end = min(start + bucketSize, lastIndex)
            var low = start
            var high = start
            for index in start..<end {
                if points[index].price < points[low].price { low = index }
                if points[index].price > points[high].price { high = index }
            }
            sampled.append(points[min(low, high)])
            if low != high { sampled.append(points[max(low, high)]) }
            start = end
        }
        sampled.append(points[lastIndex])
        return sampled
    }

    private static func bucketIndex(for date: Date, bucketSize: TimeInterval) -> Int {
        Int(floor(date.timeIntervalSince1970 / bucketSize))
    }
}

/// Aligns a comparison series with the primary one so both start at 0% on the same instant.
enum MenuChartSeriesAlignment {
    /// Percent change of `series` relative to its value at the start of `window`.
    ///
    /// Points outside the window are dropped. The baseline is the last price at or before the
    /// window start (a benchmark that began earlier is rebased to where it stood when the primary
    /// series began); a series that only starts inside the window is rebased to its first point.
    /// Expects `series` in ascending date order.
    static func percentSeries(
        _ series: [MenuChartDataPoint],
        window: ClosedRange<Date>
    ) -> [(time: TimeInterval, value: Double)] {
        let inside = series.filter { window.contains($0.date) && $0.price.isFinite }
        let before = series.last { $0.date <= window.lowerBound && $0.price.isFinite }
        guard let baselinePoint = before ?? inside.first else { return [] }
        let baseline = baselinePoint.price
        guard baseline != 0 else { return [] }

        var result: [(time: TimeInterval, value: Double)] = []
        if let before, inside.first.map({ $0.date > window.lowerBound }) ?? true {
            result.append((window.lowerBound.timeIntervalSince1970, (before.price / baseline) - 1.0))
        }
        result.append(contentsOf: inside.map { ($0.date.timeIntervalSince1970, ($0.price / baseline) - 1.0) })
        return result
    }
}

enum MenuPopoverFormatter {
    static func currency(_ value: Double?, currency: String, includeSign: Bool = false) -> String {
        HoldingsCurrencyFormatter.compactAmount(value, currency: currency, includeSign: includeSign)
    }

    static func currencyExact(_ value: Double?, currency: String, includeSign: Bool = false) -> String {
        guard let value, value.isFinite else { return "-" }
        return includeSign
            ? HoldingsCurrencyFormatter.signedAmount(value, currency: currency)
            : HoldingsCurrencyFormatter.amount(value, currency: currency)
    }

    /// Signed percentage in the user's locale; `value` is already in percent (1.5 means 1.5%).
    static func percent(_ value: Double?, locale: Locale = .current) -> String {
        guard let value, value.isFinite else { return "" }
        return (value / 100).formatted(
            .percent.precision(.fractionLength(2)).sign(strategy: .always()).locale(locale)
        )
    }

    /// Displays fractional share quantities without rounding them away.
    static func units(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "-" }
        return unitsFormatter(locale: locale, usesGrouping: true).string(from: NSNumber(value: value)) ?? "-"
    }

    /// Editable representation: locale decimal separator, no grouping.
    static func editableUnits(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "" }
        return unitsFormatter(locale: locale, usesGrouping: false).string(from: NSNumber(value: value)) ?? ""
    }

    /// Parses user-entered units in the given locale, also accepting a plain
    /// `.` decimal. Returns nil for empty, nonfinite or non-positive input.
    static func parseUnits(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = unitsFormatter(locale: locale, usesGrouping: true)
        formatter.isLenient = true
        let parsed = formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed)
        guard let parsed, parsed.isFinite, parsed > 0 else { return nil }
        return parsed
    }

    private static func unitsFormatter(locale: Locale, usesGrouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = usesGrouping
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter
    }

    /// Hover label for a chart point, in the user's locale.
    static func date(_ date: Date, range: MenuChartTimeRange) -> String {
        range == .day
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// "Updated 14:05" for today, otherwise with the date, in the user's locale.
    static func updatedText(from timestamps: [Int?], now: Date = Date()) -> String {
        guard let date = StockbarRelativeTime.latest(timestamps) else { return "Not updated yet" }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "Updated \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Updated \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}

struct MenuPopoverStatBox: View {
    let label: String
    let value: String
    var subValue: String?
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())

            if let subValue, !subValue.isEmpty {
                Text(subValue)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueColor == .primary ? Color.secondary : valueColor.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .menuPopoverTile()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Rounded tile used for the popover statistics grid.
    func menuPopoverTile() -> some View {
        frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .padding(10)
            .background(StockbarPalette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
            )
    }
}

struct MenuPopoverFooter: View {
    let updatedText: String
    let onRefresh: () -> Void
    var onOpenApp: (() -> Void)?
    let onPreferences: () -> Void
    let onQuit: () -> Void
    @State private var refreshCount = 0

    var body: some View {
        HStack(spacing: 2) {
            Button {
                refreshCount += 1
                onRefresh()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                        .symbolEffect(.rotate, value: refreshCount)
                    Text(updatedText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(MenuPopoverFooterButtonStyle())
            .help("Refresh now")
            .accessibilityLabel("\(updatedText). Refresh now")

            Spacer(minLength: 8)

            if let onOpenApp {
                iconButton("macwindow", help: "Open Stockbar", action: onOpenApp)
            }
            iconButton("gearshape", help: "Settings", action: onPreferences)
            iconButton("power", help: "Quit Stockbar", action: onQuit)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(MenuPopoverFooterButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Borderless footer button that highlights on hover and press.
private struct MenuPopoverFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered || configuration.isPressed ? StockbarPalette.hoverFill : Color.clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(StockbarMotion.quick) { isHovered = hovering }
                }
        }
    }
}

struct MenuPopoverTimeRangePicker: View {
    @Binding var selectedRange: MenuChartTimeRange
    /// The portfolio's shortest period runs from the previous close; a stock's
    /// runs over the last 24 hours, so it is not called "Today".
    var dayLabel = "Today"
    let onSelect: (MenuChartTimeRange) -> Void

    var body: some View {
        Picker("Chart period", selection: Binding(
            get: { selectedRange },
            set: { range in
                selectedRange = range
                onSelect(range)
            }
        )) {
            ForEach(MenuChartTimeRange.allCases, id: \.self) { range in
                Text(range == .day ? dayLabel : range.description).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// Legend under a chart that compares a series with a benchmark.
struct MenuPopoverChartLegend: View {
    let primaryLabel: String
    let primaryColor: Color
    let comparisonLabel: String

    var body: some View {
        HStack(spacing: 14) {
            item(label: primaryLabel) {
                Capsule().fill(primaryColor).frame(width: 12, height: 3)
            }
            item(label: comparisonLabel) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 12, y: 1))
                }
                .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 12, height: 2)
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item<Swatch: View>(label: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 5) {
            swatch()
            Text(label)
        }
    }
}

struct MenuPopoverLineChart: View {
    let points: [MenuChartDataPoint]
    var comparisonPoints: [MenuChartDataPoint] = []
    var isLoading: Bool = false
    /// Replays the draw-in animation when it changes (e.g. a new period loads).
    var revealTrigger: String = ""
    var emptyTitle = "No history yet"
    var emptyMessage = "Stockbar stores prices while it runs."

    @Binding var hoveredPoint: MenuChartDataPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if points.count >= 2 {
                    chartCanvas
                        .chartReveal(trigger: revealTrigger)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // Writing the binding re-renders the popover; only do it for a new point.
                                let nearest = nearestPoint(toX: location.x, width: geometry.size.width)
                                if nearest?.id != hoveredPoint?.id { hoveredPoint = nearest }
                            case .ended:
                                if hoveredPoint != nil { hoveredPoint = nil }
                            }
                        }
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: "chart.xyaxis.line")
                            .accessibilityHidden(true)
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(emptyTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Snaps to the observation closest in time to the pointer, so uneven
    /// sampling (gaps overnight or at weekends) doesn't skew the cursor.
    private func nearestPoint(toX x: CGFloat, width: CGFloat) -> MenuChartDataPoint? {
        guard let first = points.first?.date.timeIntervalSince1970,
              let last = points.last?.date.timeIntervalSince1970,
              width > 0 else { return nil }
        let fraction = Double(max(0, min(1, x / width)))
        let target = first + (last - first) * fraction
        return points.min { abs($0.date.timeIntervalSince1970 - target) < abs($1.date.timeIntervalSince1970 - target) }
    }

    private var chartCanvas: some View {
        Canvas { context, size in
            guard points.count >= 2,
                  let minDate = points.first?.date.timeIntervalSince1970,
                  let maxDate = points.last?.date.timeIntervalSince1970 else {
                return
            }

            let dateRange = maxDate - minDate
            let safeDateRange = dateRange == 0 ? 1.0 : dateRange

            // Both series are clipped to the primary series' window and rebased to the value at its start.
            let window = (points.first?.date ?? .distantPast)...(points.last?.date ?? .distantFuture)
            let primarySeries = MenuChartSeriesAlignment.percentSeries(points, window: window)
            let comparisonSeries = MenuChartSeriesAlignment.percentSeries(comparisonPoints, window: window)
            let combinedValues = (primarySeries.map { $0.value } + comparisonSeries.map { $0.value }).filter(\.isFinite)
            let lowestValue = combinedValues.min() ?? 0
            let highestValue = combinedValues.max() ?? 0
            // A day that barely moved is drawn nearly flat: the scale never
            // covers less than half a percent, or a 0.01% wobble filled the chart.
            let minimumSpan = 0.005
            let span = highestValue - lowestValue
            let padding = max(0, (minimumSpan - span) / 2)
            let minValue = lowestValue - padding
            let range = max(span, minimumSpan)
            let bottomInset = size.height * 0.06
            let topInset = size.height * 0.1
            let usableHeight = max(size.height - topInset - bottomInset, 1)

            func normalize(_ series: [(time: TimeInterval, value: Double)]) -> [CGPoint] {
                series.map { item in
                    let normalizedX = (item.time - minDate) / safeDateRange
                    let normalizedY = (item.value - minValue) / range
                    return CGPoint(
                        x: normalizedX * size.width,
                        y: size.height - bottomInset - (normalizedY * usableHeight)
                    )
                }
            }

            let primaryPoints = normalize(primarySeries)
            let comparisonPathPoints = normalize(comparisonSeries)

            if let comparisonPath = smoothedPath(comparisonPathPoints), !comparisonPathPoints.isEmpty {
                context.stroke(
                    comparisonPath,
                    with: .color(Color.primary.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [3, 3])
                )
            }

            guard let linePath = smoothedPath(primaryPoints) else { return }
            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [chartColor.opacity(0.3), chartColor.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                linePath,
                with: .color(chartColor),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )

            drawHoverState(context: context, primaryPoints: primaryPoints, size: size)
        }
    }

    var chartColor: Color {
        Self.color(for: points)
    }

    /// Green when the series ended higher than it started, red when lower.
    static func color(for points: [MenuChartDataPoint]) -> Color {
        guard let first = points.first?.price,
              let last = points.last?.price,
              first.isFinite, last.isFinite, last != first else {
            return .accentColor
        }
        return last > first ? .green : .red
    }

    /// Catmull-Rom spline through the points: smooth without the ripples
    /// that flat-tangent curves add to dense series.
    private func smoothedPath(_ points: [CGPoint]) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        for index in 1..<points.count {
            let controls = Self.curveControls(points, endingAt: index)
            path.addCurve(to: points[index], control1: controls.first, control2: controls.second)
        }

        return path
    }

    /// The control points of the curve from `points[index - 1]` to `points[index]`.
    ///
    /// The direction at each end comes from the points either side of it. Where
    /// the points are unevenly spaced in time (the night between two trading
    /// days), a far neighbour made that pull many times longer than the piece
    /// of curve it shapes, and the line doubled back on itself before the gap
    /// and after it. The pull is therefore shortened, keeping its direction,
    /// to reach no further than a third of the way across its own piece, which
    /// is what evenly spaced points give anyway. The line then always moves
    /// forward in time. Expects `points` in ascending x order.
    static func curveControls(_ points: [CGPoint], endingAt index: Int) -> (first: CGPoint, second: CGPoint) {
        let p0 = points[max(index - 2, 0)]
        let p1 = points[index - 1]
        let p2 = points[index]
        let p3 = points[min(index + 1, points.count - 1)]
        let reach = max(0, (p2.x - p1.x) / 3)

        func pull(from start: CGPoint, to end: CGPoint) -> CGVector {
            let dx = (end.x - start.x) / 6
            let dy = (end.y - start.y) / 6
            let scale = dx > reach ? reach / dx : 1
            return CGVector(dx: dx * scale, dy: dy * scale)
        }

        let leaving = pull(from: p0, to: p2)
        let arriving = pull(from: p1, to: p3)
        return (
            CGPoint(x: p1.x + leaving.dx, y: p1.y + leaving.dy),
            CGPoint(x: p2.x - arriving.dx, y: p2.y - arriving.dy)
        )
    }

    private func drawHoverState(context: GraphicsContext, primaryPoints: [CGPoint], size: CGSize) {
        guard let hoveredPoint,
              let index = points.firstIndex(where: { $0.id == hoveredPoint.id }),
              primaryPoints.indices.contains(index) else {
            return
        }

        let point = primaryPoints[index]
        var cursorPath = Path()
        cursorPath.move(to: CGPoint(x: point.x, y: 0))
        cursorPath.addLine(to: CGPoint(x: point.x, y: size.height))

        context.stroke(
            cursorPath,
            with: .color(Color.primary.opacity(0.25)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )

        let halo = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        context.fill(Path(ellipseIn: halo), with: .color(chartColor.opacity(0.2)))
        let dotRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: dotRect), with: .color(chartColor))
        context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 1.5)
    }
}
