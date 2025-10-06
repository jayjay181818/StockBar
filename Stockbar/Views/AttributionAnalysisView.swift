//
//  AttributionAnalysisView.swift
//  Stockbar
//
//  Created by Stockbar Development Team on 10/4/25.
//

import SwiftUI
import Charts

struct AttributionAnalysisView: View {

    @ObservedObject private var historicalDataManager = HistoricalDataManager.shared
    @State private var selectedTimeRange: ChartTimeRange = .month
    @State private var attributionResult: AttributionAnalysisResult?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showDetailedView: Bool = false
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
        .onAppear {
            Task {
                await loadAttributionData()
            }
        }
        .onChange(of: selectedTimeRange) { _, _ in
            Task {
                await loadAttributionData()
            }
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

            Button(action: {
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal)
    }

    // MARK: - Time Range Picker

    private var timeRangePicker: some View {
        Picker("Time Range", selection: $selectedTimeRange) {
            ForEach(ChartTimeRange.allCases, id: \.self) { range in
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
                title: "Total Return",
                value: String(format: "%.2f%%", result.portfolioReturn),
                color: result.portfolioReturn >= 0 ? .green : .red
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

            metricCard(
                title: "Net Cash Flow",
                value: formatCurrency(result.netCashFlow),
                color: result.netCashFlow >= 0 ? .green : .red
            )
        }
    }

    private func metricCard(title: String, value: String, color: Color) -> some View {
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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
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
                    Text(String(format: "%.2f%%", comparison.timeWeightedReturn))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading) {
                    Text("Money-Weighted Return")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f%%", comparison.moneyWeightedReturn))
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading) {
                    Text("Difference")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.2f%%", comparison.difference))
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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Top Contributors

    private func topContributorsView(_ result: AttributionAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Contributors")
                .font(.headline)

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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func contributionRow(_ contribution: StockContribution) -> some View {
        HStack {
            Text(contribution.symbol)
                .font(.body)
                .fontWeight(.medium)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f%%", contribution.stockReturn))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formatCurrency(contribution.dollarContribution))
                    .font(.body)
                    .foregroundColor(contribution.isPositive ? .green : .red)
            }
        }
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
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func sectorRow(_ sector: SectorContribution) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sector.sectorName)
                    .font(.body)
                    .fontWeight(.medium)

                Text("\(sector.stockCount) stocks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f%%", sector.totalContribution))
                    .font(.body)
                    .foregroundColor(sector.isPositive ? .green : .red)

                Text(formatCurrency(sector.dollarContribution))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Waterfall Chart

    private func waterfallChartView(_ result: AttributionAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contribution Waterfall")
                .font(.headline)

            Chart(result.waterfallData) { dataPoint in
                BarMark(
                    x: .value("Label", dataPoint.label),
                    y: .value("Value", dataPoint.value)
                )
                .foregroundStyle(dataPoint.isSummary ? Color.blue : (dataPoint.isPositive ? Color.green : Color.red))
                .opacity(dataPoint.isSummary ? 1.0 : 0.7)
            }
            .frame(height: 250)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
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
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
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
        isLoading = true
        errorMessage = nil

        // Calculate date range
        let endDate = Date()
        let startDate = Date(timeIntervalSince1970: endDate.timeIntervalSince1970 - selectedTimeRange.timeInterval)

        do {
            // Fetch historical portfolio snapshots from Core Data (has actual position data)
            let historicalSnapshots = await historicalDataManager.fetchHistoricalPortfolioSnapshots(from: startDate, to: endDate)

            // Check if we have enough data
            guard historicalSnapshots.count >= 2 else {
                await MainActor.run {
                    self.errorMessage = "Insufficient historical data. Please allow the app to collect data over time."
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
                if let result = result {
                    self.attributionResult = result
                    self.errorMessage = nil
                } else {
                    self.errorMessage = "Unable to calculate attribution. Please try a different time range."
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error loading attribution data: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    // MARK: - Helper Methods

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = dataModel?.preferredCurrency ?? "USD"
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

// MARK: - Preview

#Preview {
    AttributionAnalysisView(dataModel: nil)
        .frame(width: 600, height: 800)
}
