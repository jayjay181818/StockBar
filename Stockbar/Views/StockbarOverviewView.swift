import Charts
import SwiftUI

/// The window's quick-check surface shares its data and period semantics with the menu bar.
@MainActor
struct StockbarOverviewView: View {
    @ObservedObject var dataModel: DataModel
    @ObservedObject var navigationState: StockbarMainNavigationState
    @StateObject private var chartModel: PortfolioMenuChartViewModel
    @State private var selectedSymbol = ""

    init(dataModel: DataModel, navigationState: StockbarMainNavigationState) {
        self.dataModel = dataModel
        self.navigationState = navigationState
        let summary = dataModel.calculateDisplayPortfolioSummary()
        _chartModel = StateObject(wrappedValue: PortfolioMenuChartViewModel(
            currentValue: summary.totalValue,
            currentTrades: dataModel.realTimeTrades,
            preferredCurrency: summary.currency,
            valuationSource: summary.valuationSource,
            initialRange: .week
        ))
    }

    private var summary: DisplayPortfolioSummary { dataModel.calculateDisplayPortfolioSummary() }
    private var holdings: [RealTimeTrade] {
        dataModel.realTimeTrades.filter {
            !$0.trade.isWatchlistOnly && !SymbolMetadata.isBenchmarkSymbol($0.trade.name)
                && $0.trade.position.unitSize > 0
        }
    }
    private var selectedHolding: RealTimeTrade? {
        holdings.first { $0.trade.name == selectedSymbol } ?? holdings.first
    }
    private var source: String {
        switch summary.valuationSource {
        case .folyncProvided: "Folync"
        case .brokerProvided: "Trading 212"
        case .localCalculationFallback, .marketDataFallback: "Local portfolio"
        }
    }
    private var rangeChange: PortfolioMenuRangeChange? {
        PortfolioMenuPerformanceResolver.resolve(
            summary: summary, range: chartModel.selectedTimeRange,
            chartChange: chartModel.hasRangeCoverage && chartModel.chartData.count > 1
                ? PortfolioMenuChartDataBuilder.rangeChange(for: chartModel.chartData) : nil
        )
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        metrics
                        chart
                        if !chartModel.coverageLabel.isEmpty {
                            Text(chartModel.coverageLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        summaryRows
                        HStack {
                            Label(source, systemImage: "externaldrive")
                            if dataModel.isFolyncPortfolioActive {
                                Text(dataModel.folyncConnectionState.message).lineLimit(1)
                            }
                            Spacer()
                            Text(MenuPopoverFormatter.updatedText(from: holdings.map { $0.realTimeInfo.lastUpdateTime }))
                            Button { Task { await dataModel.refreshAllTrades() } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help("Refresh portfolio")
                            .accessibilityLabel("Refresh portfolio")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if geometry.size.width < 1050 { inspector }
                    }
                    .padding(30)
                }
                if geometry.size.width >= 1050 {
                    Divider()
                    ScrollView { inspector.padding(24) }
                        .frame(width: 250)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { updateChart(); chartModel.activate() }
        .onDisappear { chartModel.deactivate() }
        .onReceive(dataModel.tradeContentPublisher) { _ in updateChart() }
        .onChange(of: summary.totalValue) { _, _ in updateChart() }
        .onChange(of: summary.currency) { _, _ in updateChart() }
        .onChange(of: summary.valuationSource) { _, _ in updateChart() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Overview").font(.largeTitle).fontWeight(.semibold)
                Text(dataModel.isFolyncPortfolioActive ? "Read-only portfolio summary" : "Your portfolio at a glance")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Time range", selection: Binding(get: { chartModel.selectedTimeRange }, set: { chartModel.setTimeRange($0) })) {
                ForEach(MenuChartTimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                portfolioValue
                changeMetric("Today", amount: summary.dayGain, percent: summary.dayGainPct)
                if chartModel.selectedTimeRange != .day {
                    changeMetric("\(chartModel.selectedTimeRange.rawValue) change",
                                 amount: rangeChange?.value ?? .nan, percent: rangeChange?.percent ?? .nan)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                portfolioValue
                HStack(spacing: 30) {
                    changeMetric("Today", amount: summary.dayGain, percent: summary.dayGainPct)
                    if chartModel.selectedTimeRange != .day {
                        changeMetric("\(chartModel.selectedTimeRange.rawValue) change",
                                     amount: rangeChange?.value ?? .nan, percent: rangeChange?.percent ?? .nan)
                    }
                }
            }
        }
    }

    private var portfolioValue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Total portfolio value · \(summary.currency)").foregroundStyle(.secondary)
            Text(HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))
                .font(.system(size: 36, weight: .semibold)).monospacedDigit().fixedSize()
        }
    }

    private func changeMetric(_ title: String, amount: Double, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(amount.isFinite && percent.isFinite
                 ? "\(HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency)) (\(String(format: "%+.2f%%", percent)))"
                 : "Unavailable")
                .font(.headline).monospacedDigit()
                .foregroundStyle(amount.isFinite ? (amount < 0 ? Color.red : Color.green) : Color.secondary)
        }
        .fixedSize()
    }

    @ViewBuilder private var chart: some View {
        if chartModel.isLoading {
            ProgressView("Loading portfolio history…").frame(height: 280)
        } else if chartModel.chartData.count > 1 {
            Chart(chartModel.chartData) { point in
                LineMark(x: .value("Date", point.date), y: .value(summary.currency, point.price))
                    .foregroundStyle((rangeChange?.value ?? 0) >= 0 ? Color.green : Color.red)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 280)
            .accessibilityLabel("Portfolio value over \(chartModel.selectedTimeRange.description), in \(summary.currency)")
        } else {
            ContentUnavailableView(
                chartModel.selectedTimeRange == .day && summary.valuationSource == .folyncProvided
                    ? "Daily result from Folync" : "Not enough history",
                systemImage: "chart.xyaxis.line",
                description: Text(chartModel.selectedTimeRange == .day && summary.valuationSource == .folyncProvided
                                  ? "Folync has not supplied enough intraday history to draw a chart. Today's result uses its daily reference."
                                  : "A chart appears when at least two portfolio observations are available.")
            )
            .frame(height: 280)
        }
    }

    private var summaryRows: some View {
        VStack(spacing: 0) {
            detailRow("Portfolio value", HoldingsCurrencyFormatter.amount(summary.totalValue, currency: summary.currency))
            detailRow("Unrealised P&L", HoldingsCurrencyFormatter.signedAmount(summary.totalGain, currency: summary.currency))
            detailRow("Cost basis", HoldingsCurrencyFormatter.amount(summary.totalCost, currency: summary.currency))
            detailRow("Positions", "\(summary.ownedPositionCount)")
            if dataModel.isFolyncPortfolioActive, let cash = dataModel.folyncPortfolioSnapshot?.cash {
                detailRow("Cash", HoldingsCurrencyFormatter.amount(cash.value ?? .nan, currency: cash.currency ?? summary.currency))
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Selected position").foregroundStyle(.secondary)
            if let trade = selectedHolding {
                Picker("Position", selection: Binding(
                    get: { selectedHolding?.trade.name ?? "" }, set: { selectedSymbol = $0 }
                )) {
                    ForEach(holdings, id: \.trade.name) { Text($0.displayLabel ?? $0.trade.name).tag($0.trade.name) }
                }
                .labelsHidden()
                Divider()
                Text(trade.displayLabel ?? trade.trade.name).font(.title3).fontWeight(.semibold)
                let value = dataModel.calculatePositionValue(for: trade)
                detailRow("Market value", HoldingsCurrencyFormatter.amount(value.amount, currency: value.currency))
                detailRow("Units", trade.trade.position.unitSize.formatted(.number.precision(.fractionLength(0...6))))
                detailRow("Price", HoldingsCurrencyFormatter.amount(trade.realTimeInfo.getCurrentDisplayPrice(),
                                                                    currency: trade.realTimeInfo.currency ?? ""))
                detailRow("Average cost", trade.trade.position.getDisplayCost(for: trade.trade.name))
                let profit = dataModel.calculatePositionProfitLoss(for: trade)
                detailRow("Total P&L", HoldingsCurrencyFormatter.signedAmount(profit.totalAmount, currency: profit.currency))
            } else {
                Text("Add a holding or connect a portfolio to see position details.").foregroundStyle(.secondary)
            }
            Button { navigationState.selectedSection = .holdings } label: {
                Label("Open Holdings", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Button("View data health") { navigationState.selectedSection = .dataHealth }
                .buttonStyle(.link)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).monospacedDigit().multilineTextAlignment(.trailing)
            }.padding(.vertical, 12)
            Divider()
        }
    }

    private func updateChart() {
        chartModel.update(currentValue: summary.totalValue, currentTrades: dataModel.realTimeTrades,
                          preferredCurrency: summary.currency, valuationSource: summary.valuationSource)
    }
}
