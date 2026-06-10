import Combine
import Combine
import SwiftUI

struct PortfolioMenuActions {
    let refresh: () -> Void
    let preferences: () -> Void
    let quit: () -> Void

    @MainActor
    static let noop = PortfolioMenuActions(refresh: {}, preferences: {}, quit: {})
}

enum PortfolioMenuChartDataBuilder {
    static let defaultMaxPoints = 1000

    static func prepareChartPoints(
        storedPoints: [ChartDataPoint],
        currentValue: Double,
        range: MenuChartTimeRange,
        now: Date = Date(),
        maxPoints: Int = defaultMaxPoints
    ) -> [MenuChartDataPoint] {
        MenuChartDataBuilder.prepareValuePoints(
            storedPoints: storedPoints,
            currentValue: currentValue,
            symbol: "Portfolio",
            range: range,
            now: now,
            maxPoints: maxPoints
        )
    }
}

@MainActor
final class PortfolioMenuChartViewModel: ObservableObject {
    @Published var chartData: [MenuChartDataPoint] = []
    @Published var selectedTimeRange: MenuChartTimeRange = .day
    @Published var isLoading = false

    private let historicalDataManager = HistoricalDataManager.shared
    private var currentValue: Double
    private var currentTrades: [RealTimeTrade]
    private var preferredCurrency: String
    private var cancellables = Set<AnyCancellable>()

    init(currentValue: Double, currentTrades: [RealTimeTrade], preferredCurrency: String) {
        self.currentValue = currentValue
        self.currentTrades = currentTrades
        self.preferredCurrency = preferredCurrency
        historicalDataManager.$priceSnapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadChartData()
            }
            .store(in: &cancellables)
        loadChartData()
    }

    func update(currentValue: Double, currentTrades: [RealTimeTrade], preferredCurrency: String) {
        self.currentValue = currentValue
        self.currentTrades = currentTrades
        self.preferredCurrency = preferredCurrency
        loadChartData()
    }

    func setTimeRange(_ range: MenuChartTimeRange) {
        selectedTimeRange = range
        loadChartData()
    }

    func loadChartData() {
        isLoading = true
        let storedPoints = historicalDataManager.getPortfolioMenuValues(
            for: selectedTimeRange.chartTimeRange,
            currentTrades: currentTrades,
            preferredCurrency: preferredCurrency
        )
        chartData = PortfolioMenuChartDataBuilder.prepareChartPoints(
            storedPoints: storedPoints,
            currentValue: currentValue,
            range: selectedTimeRange
        )
        isLoading = false
    }
}

@MainActor
struct PortfolioMenuPopoverView: View {
    @ObservedObject private var dataModel: DataModel
    @StateObject private var viewModel: PortfolioMenuChartViewModel
    @State private var hoveredPoint: MenuChartDataPoint?
    @Namespace private var animationNamespace

    private let actions: PortfolioMenuActions
    private let chartHeight: CGFloat = 160

    init(dataModel: DataModel, actions: PortfolioMenuActions) {
        self.dataModel = dataModel
        self.actions = actions
        let summary = dataModel.calculateDisplayPortfolioSummary(
            preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
        )
        self._viewModel = StateObject(
            wrappedValue: PortfolioMenuChartViewModel(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency
            )
        )
    }

    private var summary: DisplayPortfolioSummary {
        dataModel.calculateDisplayPortfolioSummary(
            preferredCurrency: dataModel.portfolioMenuBarDisplaySettings.currencyCode
        )
    }

    private var currentDisplayValue: String {
        MenuPopoverFormatter.currency(hoveredPoint?.price ?? summary.totalValue, currency: summary.currency)
    }

    private var rangeChange: (value: Double, percent: Double)? {
        guard let first = viewModel.chartData.first,
              let last = viewModel.chartData.last,
              first.price.isFinite,
              first.price > 0,
              last.price.isFinite else {
            return nil
        }

        let value = last.price - first.price
        return (value, (value / first.price) * 100)
    }

    private var updatedText: String {
        let ownedTimestamps = dataModel.realTimeTrades
            .filter { !$0.trade.isWatchlistOnly && $0.trade.position.unitSize > 0 }
            .map { $0.realTimeInfo.lastUpdateTime }

        return MenuPopoverFormatter.updatedText(from: ownedTimestamps)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ZStack(alignment: .topTrailing) {
                MenuPopoverLineChart(
                    points: viewModel.chartData,
                    isLoading: viewModel.isLoading,
                    hoveredPoint: $hoveredPoint
                )
                .frame(height: chartHeight)
                .clipShape(Rectangle())

                MenuPopoverTimeRangePicker(
                    selectedRange: $viewModel.selectedTimeRange,
                    namespace: animationNamespace
                ) { range in
                    viewModel.setTimeRange(range)
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
            }
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.2), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            statsGrid
                .padding(16)

            Divider()
                .overlay(Color.white.opacity(0.1))

            MenuPopoverFooter(
                updatedText: updatedText,
                onRefresh: actions.refresh,
                onPreferences: actions.preferences,
                onQuit: actions.quit
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency
            )
        }
        .onReceive(dataModel.$realTimeTrades) { _ in
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency
            )
        }
        .onReceive(dataModel.$portfolioMenuBarDisplaySettings) { _ in
            viewModel.update(
                currentValue: summary.totalValue,
                currentTrades: dataModel.realTimeTrades,
                preferredCurrency: summary.currency
            )
        }
    }

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Portfolio")
                    .font(.system(size: 24, weight: .bold, design: .default))
                    .foregroundColor(.white)

                Text("\(summary.currency) • \(positionCountText)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(currentDisplayValue)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if let point = hoveredPoint {
                    Text(MenuPopoverFormatter.date(point.date, range: viewModel.selectedTimeRange))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                } else {
                    performancePill(percent: rangeChange?.percent ?? summary.totalGainPct)
                }
            }
        }
    }

    private var statsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MenuPopoverStatBox(
                    label: "Market Value",
                    value: MenuPopoverFormatter.currency(summary.totalValue, currency: summary.currency)
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                let totalColor: Color = summary.totalGain >= 0 ? .green : .red
                MenuPopoverStatBox(
                    label: "Total P&L",
                    value: MenuPopoverFormatter.currency(summary.totalGain, currency: summary.currency, includeSign: true),
                    subValue: MenuPopoverFormatter.percent(summary.totalGainPct),
                    valueColor: totalColor
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            HStack(spacing: 0) {
                let range = rangeChange
                let rangeColor: Color = (range?.value ?? 0) >= 0 ? .green : .red
                MenuPopoverStatBox(
                    label: "\(viewModel.selectedTimeRange.rawValue) P&L",
                    value: MenuPopoverFormatter.currency(range?.value, currency: summary.currency, includeSign: true),
                    subValue: MenuPopoverFormatter.percent(range?.percent),
                    valueColor: rangeColor
                )

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                MenuPopoverStatBox(
                    label: "Cost Basis",
                    value: MenuPopoverFormatter.currency(summary.totalCost, currency: summary.currency)
                )
            }
        }
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private var positionCountText: String {
        summary.ownedPositionCount == 1 ? "1 position" : "\(summary.ownedPositionCount) positions"
    }

    private func performancePill(percent: Double) -> some View {
        let safePercent = percent.isFinite ? percent : 0
        let isPositive = safePercent >= 0

        return HStack(spacing: 2) {
            Image(systemName: isPositive ? "arrow.up" : "arrow.down")
                .font(.system(size: 8, weight: .bold))
            Text("\(String(format: "%.2f", abs(safePercent)))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(isPositive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
        )
        .foregroundColor(isPositive ? .green : .red)
        .overlay(
            Capsule()
                .strokeBorder(isPositive ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}
