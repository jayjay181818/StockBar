import SwiftUI
import Charts

/// Comprehensive risk analytics dashboard displaying portfolio risk metrics
/// Shows VaR, Sharpe ratio, beta, maximum drawdown, and other risk measures
struct RiskAnalyticsView: View {
    @ObservedObject var dataModel: DataModel

    @State private var isCalculating = false
    @State private var riskMetrics: RiskMetricsService.RiskMetrics?
    @State private var drawdownPeriods: [RiskMetricsService.DrawdownPeriod] = []
    @State private var errorMessage: String?
    @State private var selectedTimeRange: TimeRange = .oneYear

    enum TimeRange: String, CaseIterable {
        case oneMonth = "1M"
        case threeMonths = "3M"
        case sixMonths = "6M"
        case oneYear = "1Y"
        case all = "All"

        var days: Int? {
            switch self {
            case .oneMonth: return 30
            case .threeMonths: return 90
            case .sixMonths: return 180
            case .oneYear: return 365
            case .all: return nil
            }
        }

        var description: String {
            switch self {
            case .oneMonth: return "1 Month"
            case .threeMonths: return "3 Months"
            case .sixMonths: return "6 Months"
            case .oneYear: return "1 Year"
            case .all: return "All Time"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with time range picker
                headerSection

                if isCalculating {
                    ProgressView("Calculating risk metrics...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = errorMessage {
                    errorView(message: error)
                } else if let metrics = riskMetrics {
                    // Risk metrics cards
                    metricsGridView(metrics: metrics)

                    // Value at Risk visualization
                    varVisualizationSection(metrics: metrics)

                    // Risk-adjusted returns
                    riskAdjustedReturnsSection(metrics: metrics)

                    // Maximum drawdown timeline
                    drawdownSection(metrics: metrics)

                    // Drawdown history table
                    if !drawdownPeriods.isEmpty {
                        drawdownHistorySection
                    }

                    // Calculation details
                    calculationDetailsSection(metrics: metrics)
                } else {
                    emptyStateView
                }
            }
            .padding()
        }
        .onAppear {
            calculateRiskMetrics()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Portfolio Risk Analytics")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: calculateRiskMetrics) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(isCalculating)
            }

            // Time range picker
            Picker("Time Range", selection: $selectedTimeRange) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Text(range.description).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTimeRange) {
                calculateRiskMetrics()
            }
        }
    }

    // MARK: - Metrics Grid

    private func metricsGridView(metrics: RiskMetricsService.RiskMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            // Value at Risk cards
            metricCard(
                title: "Value at Risk (95%)",
                value: formatCurrency(metrics.valueAtRisk95),
                subtitle: "5% worst case",
                color: .orange,
                icon: "exclamationmark.triangle.fill"
            )

            metricCard(
                title: "Value at Risk (99%)",
                value: formatCurrency(metrics.valueAtRisk99),
                subtitle: "1% worst case",
                color: .red,
                icon: "exclamationmark.octagon.fill"
            )

            // Sharpe Ratio
            metricCard(
                title: "Sharpe Ratio",
                value: String(format: "%.3f", metrics.sharpeRatio),
                subtitle: sharpeInterpretation(metrics.sharpeRatio),
                color: sharpeColor(metrics.sharpeRatio),
                icon: "chart.line.uptrend.xyaxis"
            )

            // Sortino Ratio
            metricCard(
                title: "Sortino Ratio",
                value: String(format: "%.3f", metrics.sortinoRatio),
                subtitle: "Downside risk-adjusted",
                color: sortinoColor(metrics.sortinoRatio),
                icon: "arrow.down.right.circle.fill"
            )

            // Beta (if available)
            if let beta = metrics.beta {
                metricCard(
                    title: "Portfolio Beta",
                    value: String(format: "%.2f", beta),
                    subtitle: betaInterpretation(beta),
                    color: betaColor(beta),
                    icon: "waveform.path.ecg"
                )
            }

            // Maximum Drawdown
            metricCard(
                title: "Maximum Drawdown",
                value: String(format: "%.2f%%", metrics.maxDrawdown * 100),
                subtitle: "\(metrics.maxDrawdownDuration) days",
                color: .red,
                icon: "arrow.down.circle.fill"
            )

            // Volatility
            metricCard(
                title: "Volatility (Annual)",
                value: String(format: "%.2f%%", metrics.volatility * 100),
                subtitle: volatilityInterpretation(metrics.volatility),
                color: .purple,
                icon: "waveform"
            )

            // Downside Deviation
            metricCard(
                title: "Downside Deviation",
                value: String(format: "%.2f%%", metrics.downsideDeviation * 100),
                subtitle: "Negative returns only",
                color: .orange,
                icon: "arrow.down.square.fill"
            )
        }
    }

    private func metricCard(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                Spacer()
            }

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - VaR Visualization

    private func varVisualizationSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Value at Risk Distribution")
                .font(.headline)

            Text("Potential portfolio losses at different confidence levels")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("95% Confidence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(metrics.valueAtRisk95))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                    Text("1 in 20 days")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 4) {
                    Text("99% Confidence")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(metrics.valueAtRisk99))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                    Text("1 in 100 days")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Risk-Adjusted Returns

    private func riskAdjustedReturnsSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Risk-Adjusted Performance")
                .font(.headline)

            Text("How well the portfolio compensates for risk taken")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                // Sharpe Ratio breakdown
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sharpe Ratio")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Excess return per unit of total risk")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.3f", metrics.sharpeRatio))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(sharpeColor(metrics.sharpeRatio))
                }
                .padding()
                .background(sharpeColor(metrics.sharpeRatio).opacity(0.1))
                .cornerRadius(8)

                // Sortino Ratio breakdown
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sortino Ratio")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Excess return per unit of downside risk")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.3f", metrics.sortinoRatio))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(sortinoColor(metrics.sortinoRatio))
                }
                .padding()
                .background(sortinoColor(metrics.sortinoRatio).opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Drawdown Section

    private func drawdownSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maximum Drawdown Analysis")
                .font(.headline)

            Text("Largest peak-to-trough decline in portfolio value")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 16) {
                // Max drawdown summary
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Peak to Trough")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.2f%%", metrics.maxDrawdown * 100))
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.red)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(metrics.maxDrawdownDuration) days")
                            .font(.title)
                            .fontWeight(.semibold)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

                // Recovery information
                if metrics.maxDrawdownDuration > 0 {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(.orange)
                        Text("Time in drawdown: \(formatDuration(metrics.maxDrawdownDuration))")
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    // MARK: - Drawdown History

    private var drawdownHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Significant Drawdown Periods")
                .font(.headline)

            Text("All drawdowns exceeding 5%")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(drawdownPeriods.prefix(5), id: \.startDate) { period in
                    drawdownRow(period: period)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }

    private func drawdownRow(period: RiskMetricsService.DrawdownPeriod) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.2f%%", period.drawdownPercent * 100))
                    .font(.headline)
                    .foregroundColor(.red)
                Text(formatDateRange(period.startDate, period.endDate))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(period.durationDays) days")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Peak: \(formatCurrency(period.peakValue))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(6)
    }

    // MARK: - Calculation Details

    private func calculationDetailsSection(metrics: RiskMetricsService.RiskMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calculation Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                detailRow(label: "Calculation Date", value: formatDateTime(metrics.calculationDate))
                detailRow(label: "Time Range", value: selectedTimeRange.description)
                detailRow(label: "Risk-Free Rate", value: "4.0% annually")
                detailRow(label: "Methodology", value: "Historical VaR, Annualized metrics")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Historical Data Available")
                .font(.headline)

            Text("Risk metrics require historical portfolio data. Continue using the app to build historical data for analysis.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Calculate Now") {
                calculateRiskMetrics()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Calculation Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Retry") {
                calculateRiskMetrics()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }

    // MARK: - Calculation Logic

    private func calculateRiskMetrics() {
        Task {
            await MainActor.run {
                isCalculating = true
                errorMessage = nil
            }

            // Convert TimeRange to ChartTimeRange
            let chartTimeRange: ChartTimeRange
            switch selectedTimeRange {
            case .oneMonth:
                chartTimeRange = .month
            case .threeMonths:
                chartTimeRange = .threeMonths
            case .sixMonths:
                chartTimeRange = .sixMonths
            case .oneYear:
                chartTimeRange = .year
            case .all:
                chartTimeRange = .all
            }

            // Get portfolio snapshots from HistoricalDataManager
            let snapshots = HistoricalDataManager.shared.getHistoricalPortfolioSnapshots(timeRange: chartTimeRange)

            guard !snapshots.isEmpty else {
                await MainActor.run {
                    errorMessage = "No portfolio history available for selected time range"
                    isCalculating = false
                }
                return
            }

            // Extract portfolio values and dates
            let portfolioValues = snapshots.map { $0.totalValue }
            let dates = snapshots.map { $0.date }

            // Calculate comprehensive risk metrics
            if let metrics = await RiskMetricsService.shared.calculateComprehensiveRiskMetrics(
                portfolioValues: portfolioValues,
                riskFreeRate: 0.04
            ) {
                // Find significant drawdown periods
                let periods = await RiskMetricsService.shared.findDrawdownPeriods(
                    portfolioValues: portfolioValues,
                    dates: dates,
                    threshold: 0.05
                )

                await MainActor.run {
                    self.riskMetrics = metrics
                    self.drawdownPeriods = periods
                    self.isCalculating = false
                }
            } else {
                await MainActor.run {
                    errorMessage = "Insufficient data to calculate risk metrics"
                    isCalculating = false
                }
            }
        }
    }

    // MARK: - Helper Functions

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = dataModel.preferredCurrency
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(dataModel.preferredCurrency)\(String(format: "%.2f", value))"
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    private func formatDuration(_ days: Int) -> String {
        if days < 30 {
            return "\(days) days"
        } else if days < 365 {
            let months = days / 30
            return "\(months) month\(months == 1 ? "" : "s")"
        } else {
            let years = days / 365
            let remainingMonths = (days % 365) / 30
            if remainingMonths > 0 {
                return "\(years) year\(years == 1 ? "" : "s"), \(remainingMonths) month\(remainingMonths == 1 ? "" : "s")"
            } else {
                return "\(years) year\(years == 1 ? "" : "s")"
            }
        }
    }

    // MARK: - Interpretation Functions

    private func sharpeInterpretation(_ sharpe: Double) -> String {
        if sharpe > 3.0 { return "Exceptional" }
        else if sharpe > 2.0 { return "Very good" }
        else if sharpe > 1.0 { return "Good" }
        else if sharpe > 0.5 { return "Adequate" }
        else if sharpe > 0 { return "Below average" }
        else { return "Poor" }
    }

    private func sharpeColor(_ sharpe: Double) -> Color {
        if sharpe > 2.0 { return .green }
        else if sharpe > 1.0 { return .blue }
        else if sharpe > 0.5 { return .orange }
        else { return .red }
    }

    private func sortinoColor(_ sortino: Double) -> Color {
        if sortino > 2.0 { return .green }
        else if sortino > 1.0 { return .blue }
        else if sortino > 0.5 { return .orange }
        else { return .red }
    }

    private func betaInterpretation(_ beta: Double) -> String {
        if beta > 1.2 { return "High volatility" }
        else if beta > 0.8 { return "Market-like" }
        else if beta > 0.5 { return "Low volatility" }
        else { return "Very defensive" }
    }

    private func betaColor(_ beta: Double) -> Color {
        if beta > 1.2 { return .red }
        else if beta > 0.8 { return .blue }
        else { return .green }
    }

    private func volatilityInterpretation(_ volatility: Double) -> String {
        if volatility > 0.30 { return "Very high" }
        else if volatility > 0.20 { return "High" }
        else if volatility > 0.15 { return "Moderate" }
        else if volatility > 0.10 { return "Low" }
        else { return "Very low" }
    }
}

// MARK: - Preview

#Preview {
    RiskAnalyticsView(dataModel: DataModel())
        .frame(width: 800, height: 1000)
}
