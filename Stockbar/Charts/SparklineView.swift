import SwiftUI
import Charts

/// Compact sparkline chart for displaying mini price trends in menus
struct SparklineView: View {
    let data: [SparklineDataPoint]
    let accentColor: Color
    let showArea: Bool

    init(data: [SparklineDataPoint], accentColor: Color = .blue, showArea: Bool = true) {
        self.data = data
        self.accentColor = accentColor
        self.showArea = showArea
    }

    var body: some View {
        if data.isEmpty {
            // Empty state
            Text("—")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(height: 24)
        } else {
            Chart(data) { point in
                if showArea {
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Price", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentColor.opacity(0.3), accentColor.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Price", point.value)
                )
                .foregroundStyle(accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 24)
        }
    }
}

struct SparklineDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

// MARK: - Convenience Initializer for PriceSnapshots
extension SparklineView {
    /// Create sparkline from price snapshots
    init(snapshots: [PriceSnapshot], accentColor: Color = .blue, showArea: Bool = true) {
        let points = snapshots.map { snapshot in
            SparklineDataPoint(timestamp: snapshot.timestamp, value: snapshot.price)
        }.sorted { $0.timestamp < $1.timestamp }

        self.init(data: points, accentColor: accentColor, showArea: showArea)
    }

    /// Create sparkline with automatic color based on trend
    init(snapshots: [PriceSnapshot], showArea: Bool = true) {
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }

        // Determine trend color (green if up, red if down)
        let trendColor: Color
        if let first = sorted.first, let last = sorted.last {
            trendColor = last.price >= first.price ? .green : .red
        } else {
            trendColor = .blue
        }

        self.init(snapshots: snapshots, accentColor: trendColor, showArea: showArea)
    }
}

#Preview("Sparkline - Uptrend") {
    let upData = (0..<15).map { i in
        SparklineDataPoint(
            timestamp: Date().addingTimeInterval(TimeInterval(i * 3600)),
            value: 100 + Double(i) * 2 + Double.random(in: -1...1)
        )
    }

    VStack(spacing: 16) {
        SparklineView(data: upData, accentColor: .green)
        SparklineView(data: upData, accentColor: .green, showArea: false)
    }
    .padding()
}

#Preview("Sparkline - Downtrend") {
    let downData = (0..<15).map { i in
        SparklineDataPoint(
            timestamp: Date().addingTimeInterval(TimeInterval(i * 3600)),
            value: 120 - Double(i) * 1.5 + Double.random(in: -1...1)
        )
    }

    VStack(spacing: 16) {
        SparklineView(data: downData, accentColor: .red)
        SparklineView(data: downData, accentColor: .red, showArea: false)
    }
    .padding()
}

#Preview("Sparkline - Empty") {
    SparklineView(data: [])
        .padding()
}
