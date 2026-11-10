//
//  AttributionAnalysisView.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import Charts
import SwiftUI

struct AttributionAnalysisView: View {

    private let historicalDataManager = HistoricalDataManager.shared
    @State private var selectedTimeRange: ChartTimeRange = .month
    @State private var attributionResult: AttributionAnalysisResult?
    @State private var isLoading: Bool = false
    /// Counts loads so a superseded one (Refresh pressed twice, or a range change) is ignored.
    @State private var requestGeneration = 0
    @State private var errorMessage: String?
    /// True when `errorMessage` only says there is not enough history yet:
    /// that is the normal state of a new install, not a fault.
    @State private var messageIsNotice = false
    @Environment(\.dismiss) private var dismiss

    let dataModel: DataModel?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            headerView

            // Time Range Picker
            timeRangePicker

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if let result = attributionResult {
                ScrollView {
                    VStack(spacing: 20) {
                        // Summary Cards
                        summaryCardsView(result)

                        // TWR vs MWR Comparison
                        if let comparison = result.twrMwrComparison {
                            twrMwrComparisonView(comparison)
                        }

                        // Top Contributors
                        topContributorsView(result)

                        // Sector Breakdown
                        sectorBreakdownView(result)

                        // Waterfall Chart
                        waterfallChartView(result)
                    }
                    .padding()
                }
            } else {
                emptyStateView
            }
        }
        // One task per range: choosing another range cancels the load in
        // flight, so a slow answer for the old range cannot land on the new one.
        .task(id: selectedTimeRange) {
            await loadAttributionData()
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack {
            Text("Performance Attribution")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Button(action: {
                Task {
                    await loadAttributionData()
                }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Recalculate attribution")
            .accessibilityLabel("Recalculate attribution")

            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close attribution")
        }
        .padding(.horizontal)
    }

    // MARK: - Time Range Picker

    private var timeRangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            // Attribution has no custom date range, so `.custom` would always fail.
            ForEach(ChartTimeRange.allCases.filter { $0 != .custom }, id: \.self) { range in
                Text(range.description).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    // MARK: - Summary Cards

    private func summaryCardsView(_ result: AttributionAnalysisResult) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "Return (excl. new money)",
                value: AttributionFormat.signedPercent(result.portfolioReturn),
                color: StockbarPalette.signed(result.portfolioReturn),
                spokenValue: AttributionFormat.spokenPercent(result.portfolioReturn)
            )

            metricCard(
                title: "Starting Value",
                value: formatCurrency(result.startingValue),
                color: .blue
            )

            metricCard(
                title: "Ending Value",
                value: formatCurrency(result.endingValue),
                color: .blue
            )

            // Only shown when real cash-flow data exists; Stockbar does not track deposits yet.
            if let netCashFlow = result.netCashFlow {
                metricCard(
                    title: "Net Cash Flow",
                    value: formatSignedCurrency(netCashFlow),
                    color: StockbarPalette.signed(netCashFlow)
                )
            }
        }
    }

    private func metricCard(title: String, value: String, color: Color, spokenValue: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(StockbarPalette.subtleFill)
        .cornerRadius(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue ?? value)
    }

    // MARK: - TWR vs MWR Comparison

    private func twrMwrComparisonView(_ comparison: TWRMWRComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Return Analysis")
                .font(.headline)

            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Time-Weighted Return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(AttributionFormat.signedPercent(comparison.timeWeightedReturn))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading) {
                    Text("Money-Weighted Return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(AttributionFormat.signedPercent(comparison.moneyWeightedReturn))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading) {
                    Text("Difference")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(AttributionFormat.signedPercent(comparison.difference))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(comparison.favorsTWR ? .green : .red)
                }
            }

            Text(comparison.interpretation)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(StockbarPalette.subtleFill)
        .cornerRadius(8)
    }

    // MARK: - Top Contributors

    private func topContributorsView(_ result: AttributionAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Contributors")
                .font(.headline)

            if result.topContributors.isEmpty {
                Text("No holding gained over this period.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(result.topContributors.prefix(5)) { contribution in
                contributionRow(contribution)
            }

            if !result.topDetractors.isEmpty {
                Text("Top Detractors")
                    .font(.headline)
                    .padding(.top, 8)

                ForEach(result.topDetractors.prefix(5)) { contribution in
                    contributionRow(contribution)
                }
            }
        }
        .padding()
        .background(StockbarPalette.subtleFill)
        .cornerRadius(8)
    }

    private func contributionRow(_ contribution: StockContribution) -> some View {
        HStack {
            Text(contribution.symbol)
                .font(.body)
                .fontWeight(.medium)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(AttributionFormat.signedPercent(contribution.stockReturn))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formatSignedCurrency(contribution.dollarContribution))
                    .font(.body)
                    .foregroundColor(StockbarPalette.signed(contribution.dollarContribution))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(contribution.symbol)
        .accessibilityValue(
            "\(AttributionFormat.direction(contribution.dollarContribution)) of "
            + "\(formatCurrency(abs(contribution.dollarContribution))), "
            + "stock return \(AttributionFormat.spokenPercent(contribution.stockReturn))"
        )
    }

    // MARK: - Sector Breakdown

    private func sectorBreakdownView(_ result: AttributionAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sector Attribution")
                .font(.headline)

            ForEach(result.sectorContributions.prefix(10)) { sector in
                sectorRow(sector)
            }
        }
        .padding()
        .background(StockbarPalette.subtleFill)
        .cornerRadius(8)
    }

    private func sectorRow(_ sector: SectorContribution) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sector.sectorName)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(sector.stockCount) \(sector.stockCount == 1 ? "stock" : "stocks")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(AttributionFormat.signedPercent(sector.totalContribution))
                    .font(.body)
                    .foregroundColor(StockbarPalette.signed(sector.totalContribution))

                Text(formatSignedCurrency(sector.dollarContribution))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sector.sectorName), \(sector.stockCount) \(sector.stockCount == 1 ? "stock" : "stocks")")
        .accessibilityValue(
            "\(AttributionFormat.direction(sector.dollarContribution)) of "
            + "\(formatCurrency(abs(sector.dollarContribution))), "
            + "\(AttributionFormat.spokenPercent(sector.totalContribution)) contribution"
        )
    }

    // MARK: - Waterfall Chart

    private func waterfallChartView(_ result: AttributionAnalysisResult) -> some View {
        let bars = WaterfallBars.make(from: result.waterfallData)
        let domain = WaterfallBars.yDomain(for: bars)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Contribution Waterfall")
                .font(.headline)

            // Floating bars: each contribution runs from the running total before it to the
            // running total after it; start and end values are full bars from the baseline.
            Chart(bars) { bar in
                BarMark(
                    x: .value("Step", bar.label),
                    yStart: .value("From", bar.isSummary ? domain.lowerBound : bar.start),
                    yEnd: .value("To", bar.end)
                )
                .foregroundStyle(bar.isSummary ? Color.blue : (bar.value >= 0 ? Color.green : Color.red))
                .opacity(bar.isSummary ? 1.0 : 0.8)
                .accessibilityLabel(bar.label)
                .accessibilityValue(bar.isSummary
                    ? formatCurrency(bar.end)
                    : "\(AttributionFormat.direction(bar.value)) of \(formatCurrency(abs(bar.value)))")
            }
            .frame(height: 250)
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .accessibilityLabel("Contribution waterfall")
            .accessibilityValue(waterfallSummary(result, bars: bars))

            Text("Blue bars are the starting and ending portfolio value; green and red bars add to or subtract from the running total. “Trades & Other” reconciles deposits, withdrawals and FX moves.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(StockbarPalette.subtleFill)
        .cornerRadius(8)
    }

    private func waterfallSummary(_ result: AttributionAnalysisResult, bars: [WaterfallBars.Bar]) -> String {
        let steps = bars.filter { !$0.isSummary }
        let parts = steps.map { "\($0.label) \(AttributionFormat.direction($0.value)) \(formatCurrency(abs($0.value)))" }
        return "From \(formatCurrency(result.startingValue)) to \(formatCurrency(result.endingValue)). "
            + (parts.isEmpty ? "No contributions." : parts.joined(separator: "; "))
    }

    // MARK: - Loading & Error Views

    private var loadingView: some View {
        VStack {
            ProgressView()
                .progressViewStyle(.circular)
            Text("Calculating attribution...")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Image(systemName: messageIsNotice ? "clock" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(messageIsNotice ? .secondary : .orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No attribution data available")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadAttributionData() async {
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil

        // Calculate date range
        let endDate = Date()
        let startDate = Date(timeIntervalSince1970: endDate.timeIntervalSince1970 - selectedTimeRange.timeInterval)

        // Fetch historical portfolio snapshots from Core Data (has actual position data)
        var historicalSnapshots = await historicalDataManager.fetchHistoricalPortfolioSnapshots(from: startDate, to: endDate)

        // Each snapshot was recorded in the currency preferred at the time. Bring them all into
        // today's currency so a USD start is never compared with a GBP end.
        if let dataModel {
            let converter = dataModel.currencyConverter
            historicalSnapshots = RiskMetricsService.normalizingSnapshotCurrencies(
                historicalSnapshots, to: dataModel.preferredCurrency,
                convert: { converter.convert(amount: $0, from: $1, to: $2) }
            ).snapshots
        }

        // Check if we have enough data
        guard historicalSnapshots.count >= 2 else {
            await MainActor.run {
                guard generation == requestGeneration else { return }
                self.messageIsNotice = true
                self.errorMessage = "Not enough history yet. Attribution needs portfolio values from at least two points in this range."
                self.isLoading = false
            }
            return
        }

        // Calculate attribution using historical snapshots (more accurate - has position data)
        let result = await AttributionAnalysisService.shared.calculateAttributionFromHistorical(
            startDate: startDate,
            endDate: endDate,
            historicalSnapshots: historicalSnapshots,
            cashFlows: [] // TODO: Add cash flow tracking in future version
        )

        await MainActor.run {
            guard generation == requestGeneration else { return }
            if let result = result {
                self.attributionResult = result
                self.errorMessage = nil
            } else {
                self.messageIsNotice = false
                self.errorMessage = "Unable to calculate attribution. Please try a different time range."
            }
            self.isLoading = false
        }
    }

    // MARK: - Helper Methods

    private var displayCurrency: String { dataModel?.preferredCurrency ?? "USD" }

    /// Missing or non-finite values show a dash, never a fabricated "$0.00".
    private func formatCurrency(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return HoldingsCurrencyFormatter.amount(value, currency: displayCurrency)
    }

    private func formatSignedCurrency(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return HoldingsCurrencyFormatter.signedAmount(value, currency: displayCurrency)
    }
}

/// Text formats that do not rely on colour to convey direction.
enum AttributionFormat {
    static func signedPercent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return value == 0 ? "0.00%" : String(format: "%+.2f%%", value)
    }

    static func spokenPercent(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        if value == 0 { return "unchanged" }
        return String(format: "%@ %.2f percent", value > 0 ? "up" : "down", abs(value))
    }

    /// "gain" / "loss" / "no change" wording for an amount.
    static func direction(_ value: Double) -> String {
        guard value.isFinite else { return "unavailable" }
        if value == 0 { return "no change" }
        return value > 0 ? "gain" : "loss"
    }
}

/// Floating-bar geometry for the attribution waterfall, derived from the cumulative values the
/// attribution service already reconciles (including its "Trades & Other" step).
enum WaterfallBars {
    struct Bar: Identifiable {
        let id: UUID
        let label: String
        let value: Double
        /// Running total before this step (the baseline for a summary bar).
        let start: Double
        /// Running total after this step.
        let end: Double
        let isSummary: Bool
    }

    static func make(from data: [WaterfallDataPoint]) -> [Bar] {
        data.compactMap { point in
            guard point.value.isFinite, point.cumulativeValue.isFinite else { return nil }
            if point.isSummary {
                return Bar(id: point.id, label: point.label, value: point.value,
                           start: 0, end: point.cumulativeValue, isSummary: true)
            }
            return Bar(id: point.id, label: point.label, value: point.value,
                       start: point.cumulativeValue - point.value, end: point.cumulativeValue, isSummary: false)
        }
    }

    /// A y-range that makes small contributions visible against a large portfolio value.
    static func yDomain(for bars: [Bar]) -> ClosedRange<Double> {
        let levels = bars.flatMap { $0.isSummary ? [$0.end] : [$0.start, $0.end] }
        guard let low = levels.min(), let high = levels.max() else { return 0...1 }
        let padding = max((high - low) * 0.15, abs(high) * 0.001, 0.01)
        return (low - padding)...(high + padding)
    }
}

// MARK: - Preview

#Preview {
    AttributionAnalysisView(dataModel: nil)
        .frame(width: 600, height: 800)
}
