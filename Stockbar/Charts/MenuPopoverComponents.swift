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

    private static func downsample(
        _ points: [MenuChartDataPoint],
        maxPoints: Int
    ) -> [MenuChartDataPoint] {
        guard maxPoints > 1, points.count > maxPoints else {
            return points
        }

        let lastIndex = points.count - 1
        let step = Double(lastIndex) / Double(maxPoints - 1)
        var sampled: [MenuChartDataPoint] = []
        sampled.reserveCapacity(maxPoints)

        for offset in 0..<maxPoints {
            let rawIndex = Int((Double(offset) * step).rounded())
            let index = min(rawIndex, lastIndex)
            if sampled.last?.date != points[index].date {
                sampled.append(points[index])
            }
        }

        if sampled.first?.date != points.first?.date {
            sampled.insert(points[0], at: 0)
        }
        if sampled.last?.date != points.last?.date {
            sampled.append(points[lastIndex])
        }

        return sampled.count <= maxPoints ? sampled : Array(sampled.prefix(maxPoints - 1)) + [points[lastIndex]]
    }

    private static func bucketIndex(for date: Date, bucketSize: TimeInterval) -> Int {
        Int(floor(date.timeIntervalSince1970 / bucketSize))
    }
}

enum MenuPopoverFormatter {
    static func currency(_ value: Double?, currency: String, includeSign: Bool = false) -> String {
        HoldingsCurrencyFormatter.compactAmount(value, currency: currency, includeSign: includeSign)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%+.2f%%", value)
    }

    static func units(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f", value) : "-"
    }

    static func date(_ date: Date, range: MenuChartTimeRange) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = range == .day ? "HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    static func updatedText(from timestamps: [Int?]) -> String {
        let latest = timestamps
            .compactMap { $0 }
            .filter { $0 > 0 }
            .max()

        guard let latest else { return "Updated: -" }
        let date = Date(timeIntervalSince1970: TimeInterval(latest))
        return "Updated: \(updatedDateFormatter.string(from: date))"
    }

    private static let updatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm dd/MM/yy"
        return formatter
    }()
}

struct MenuPopoverStatBox: View {
    let label: String
    let value: String
    var subValue: String?
    var valueColor: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let subValue, !subValue.isEmpty {
                    Text(subValue)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(valueColor.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct MenuPopoverFooter: View {
    let updatedText: String
    let onRefresh: () -> Void
    let onPreferences: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            Button(action: onRefresh) {
                HStack(spacing: 6) {
                    Text(updatedText)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            HStack {
                Button(action: onPreferences) {
                    Text("Preferences")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MenuPopoverTimeRangePicker: View {
    @Binding var selectedRange: MenuChartTimeRange

    let namespace: Namespace.ID
    let onSelect: (MenuChartTimeRange) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MenuChartTimeRange.allCases, id: \.self) { range in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedRange = range
                        onSelect(range)
                    }
                }) {
                    Text(range.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(selectedRange == range ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            if selectedRange == range {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "activeTab", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        )
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

struct MenuPopoverLineChart: View {
    let points: [MenuChartDataPoint]
    var comparisonPoints: [MenuChartDataPoint] = []
    var comparisonLabel: String?
    var isLoading: Bool = false

    @Binding var hoveredPoint: MenuChartDataPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if points.count >= 2 {
                    chartCanvas
                        .gesture(hoverGesture(width: geometry.size.width))
                } else {
                    Text("No Data")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let comparisonLabel {
                    Text(comparisonLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                        .padding(.leading, 16)
                        .padding(.top, 12)
                }
            }
        }
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

            func percentSeries(_ series: [MenuChartDataPoint]) -> [(time: TimeInterval, value: Double)] {
                guard let first = series.first else { return [] }
                let baseline = first.price
                return series.map { point in
                    let percent = baseline.isFinite && baseline != 0 ? (point.price / baseline) - 1.0 : 0.0
                    return (point.date.timeIntervalSince1970, percent)
                }
            }

            let primarySeries = percentSeries(points)
            let comparisonSeries = percentSeries(comparisonPoints)
            let combinedValues = primarySeries.map { $0.value } + comparisonSeries.map { $0.value }
            let minValue = combinedValues.min() ?? 0
            let maxValue = combinedValues.max() ?? 0
            let range = max(maxValue - minValue, 0.0001)
            let bottomInset = size.height * 0.06
            let topInset = calculateTopInset(
                primarySeries: primarySeries,
                comparisonSeries: comparisonSeries,
                minDate: minDate,
                safeDateRange: safeDateRange,
                minValue: minValue,
                range: range,
                size: size,
                bottomInset: bottomInset
            )
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
                    with: .color(.white.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
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
                    Gradient(colors: [chartColor.opacity(0.5), chartColor.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                linePath,
                with: .color(chartColor.opacity(0.35)),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                linePath,
                with: .color(chartColor),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )

            drawHoverState(context: context, primaryPoints: primaryPoints, size: size)
        }
    }

    private var chartColor: Color {
        guard let first = points.first?.price,
              let last = points.last?.price else {
            return .blue
        }
        return last >= first ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    private func hoverGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let percentage = max(0, min(1, value.location.x / max(width, 1)))
                let index = Int(Double(points.count - 1) * percentage)
                if points.indices.contains(index) {
                    hoveredPoint = points[index]
                }
            }
            .onEnded { _ in
                hoveredPoint = nil
            }
    }

    private func calculateTopInset(
        primarySeries: [(time: TimeInterval, value: Double)],
        comparisonSeries: [(time: TimeInterval, value: Double)],
        minDate: TimeInterval,
        safeDateRange: TimeInterval,
        minValue: Double,
        range: Double,
        size: CGSize,
        bottomInset: CGFloat
    ) -> CGFloat {
        let pickerHeight: CGFloat = 45.0
        let dangerZoneThreshold = minDate + (safeDateRange * 0.60)
        let baseTopInset = size.height * 0.16

        func requiredInset(_ series: [(time: TimeInterval, value: Double)]) -> CGFloat {
            var maxInset = baseTopInset
            for point in series where point.time > dangerZoneThreshold {
                let value = CGFloat((point.value - minValue) / range)
                if value > 0.05 {
                    let availableHeight = size.height - bottomInset
                    let required = (pickerHeight - availableHeight * (1.0 - value)) / value
                    maxInset = max(maxInset, required)
                }
            }
            return maxInset
        }

        return min(max(requiredInset(primarySeries), requiredInset(comparisonSeries)), size.height * 0.45)
    }

    private func smoothedPath(_ points: [CGPoint]) -> Path? {
        guard let first = points.first else { return nil }
        var path = Path()
        path.move(to: first)

        for index in 1..<points.count {
            let current = points[index]
            let previous = points[index - 1]
            let midX = previous.x + (current.x - previous.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: midX, y: previous.y),
                control2: CGPoint(x: midX, y: current.y)
            )
        }

        return path
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
            with: .color(.white.opacity(0.25)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        let dotRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: dotRect), with: .color(.white))
        context.stroke(Path(ellipseIn: dotRect), with: .color(chartColor), lineWidth: 2)
    }
}
