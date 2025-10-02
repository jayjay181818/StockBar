import SwiftUI
import AppKit

/// NSView wrapper for SparklineView to embed in NSMenu
class SparklineHostingView: NSView {
    private let hostingView: NSHostingView<AnyView>

    init(symbol: String, timeRange: SparklineTimeRange = .week) {
        let sparklineContent = SparklineMenuContent(symbol: symbol, timeRange: timeRange)
        self.hostingView = NSHostingView(rootView: AnyView(sparklineContent))
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 40))

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum SparklineTimeRange {
    case day
    case week
    case month

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    var description: String {
        switch self {
        case .day: return "Today"
        case .week: return "7-Day"
        case .month: return "30-Day"
        }
    }
}

/// SwiftUI content for the sparkline menu item
struct SparklineMenuContent: View {
    let symbol: String
    let timeRange: SparklineTimeRange
    @State private var snapshots: [PriceSnapshot] = []

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(timeRange.description) Trend")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let first = snapshots.first, let last = snapshots.last {
                    let change = last.price - first.price
                    let changePercent = (change / first.price) * 100
                    HStack(spacing: 4) {
                        Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text(String(format: "%+.2f%%", changePercent))
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(change >= 0 ? .green : .red)
                } else {
                    Text("No data")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80, alignment: .leading)

            SparklineView(snapshots: snapshots, showArea: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            loadData()
        }
    }

    private func loadData() {
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -timeRange.days, to: endDate) ?? endDate

        // Get snapshots from HistoricalDataManager
        let fetchedSnapshots = HistoricalDataManager.shared.getPriceSnapshots(
            for: symbol,
            from: startDate,
            to: endDate
        )

        // Sample data if we have too many points (keep every Nth point for performance)
        let maxPoints = 50
        if fetchedSnapshots.count > maxPoints {
            let step = fetchedSnapshots.count / maxPoints
            snapshots = stride(from: 0, to: fetchedSnapshots.count, by: step).map { fetchedSnapshots[$0] }
        } else {
            snapshots = fetchedSnapshots
        }
    }
}

#Preview {
    SparklineMenuContent(symbol: "AAPL", timeRange: .week)
        .frame(width: 260, height: 40)
}
