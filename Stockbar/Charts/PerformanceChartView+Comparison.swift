import AppKit
import Charts
import SwiftUI

extension PerformanceChartView {
    var comparisonModeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Comparison Mode", isOn: $comparisonMode)
                    .toggleStyle(SwitchToggleStyle())
                    .onChange(of: comparisonMode) { _, newValue in
                        if !newValue {
                            // Clear selection when disabling comparison
                            selectedComparisonSymbols.removeAll()
                            comparisonChartData.removeAll()
                        } else if case .individualStock(let symbol) = selectedChartType,
                                  availableSymbols.contains(symbol) {
                            // The stock on screen is the one being compared against.
                            selectedComparisonSymbols.insert(symbol)
                            Task { await loadComparisonData(for: symbol) }
                        }
                    }

                Spacer()

                if comparisonMode {
                    Toggle("Normalized (%)", isOn: Binding(
                        get: { usesNormalizedComparison },
                        set: { normalizedComparison = $0 }
                    ))
                        .toggleStyle(SwitchToggleStyle())
                        .disabled(comparisonMixesCurrencies)
                        .help(comparisonMixesCurrencies
                            ? "These stocks trade in different currencies, so only percentage change can be compared"
                            : "Show as percentage change from the first date all selected stocks have")
                }
            }

            if comparisonMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select stocks to compare (max 5)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(availableSymbols, id: \.self) { symbol in
                                comparisonSymbolChip(for: symbol)
                            }
                        }
                    }

                    if !selectedComparisonSymbols.isEmpty {
                        HStack {
                            Text("\(selectedComparisonSymbols.count) stock(s) selected")
                                .font(.caption2)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button("Clear All") {
                                selectedComparisonSymbols.removeAll()
                                comparisonChartData.removeAll()
                            }
                            .font(.caption)
                            .buttonStyle(PlainButtonStyle())
                            .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(StockbarPalette.panelFill)
                .cornerRadius(8)
            }
        }
    }

    func comparisonSymbolChip(for symbol: String) -> some View {
        let isSelected = selectedComparisonSymbols.contains(symbol)
        let canSelect = selectedComparisonSymbols.count < 5 || isSelected

        return Button {
            if isSelected {
                selectedComparisonSymbols.remove(symbol)
                comparisonChartData.removeValue(forKey: symbol)
            } else if canSelect {
                selectedComparisonSymbols.insert(symbol)
                // Load data for this symbol
                Task {
                    await loadComparisonData(for: symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                Text(symbol)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : StockbarPalette.panelFill)
            .foregroundColor(isSelected ? Color.accentColor : (canSelect ? Color.primary : Color.secondary))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canSelect)
        .accessibilityLabel("Compare \(symbol)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(canSelect ? "" : "Up to 5 stocks can be compared")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    func loadComparisonData(for symbol: String) async {
        let data = historicalDataManager.getChartData(
            for: .individualStock(symbol),
            timeRange: selectedTimeRange,
            dataModel: dataModel,
            customFrom: queryCustomFrom,
            customTo: queryCustomTo
        )

        guard !Task.isCancelled, selectedComparisonSymbols.contains(symbol) else { return }
        if let existing = comparisonChartData[symbol], ChartSeriesProcessing.isSameSeries(existing, data) { return }
        comparisonChartData[symbol] = data
        await Logger.shared.debug("📊 Loaded \(data.count) data points for comparison symbol: \(symbol)")
    }

    var comparisonChartContent: some View {
        VStack(spacing: 12) {
            comparisonChart
                .frame(height: 300)

            // Color Legend
            comparisonLegend
        }
    }

    var comparisonChart: some View {
        let sortedSymbols = Array(selectedComparisonSymbols).sorted()
        let normalized = usesNormalizedComparison
        let selected = comparisonChartData.filter { selectedComparisonSymbols.contains($0.key) }
        let series = normalized ? ChartSeriesProcessing.rebasedToCommonStart(selected) : selected

        return Chart {
            ForEach(sortedSymbols, id: \.self) { symbol in
                if let processedData = series[symbol] {
                    let color = colorForSymbol(symbol)

                    ForEach(processedData) { dataPoint in
                        LineMark(
                            x: .value("Date", dataPoint.date),
                            y: .value("Value", dataPoint.value),
                            series: .value("Symbol", symbol)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: lineThickness))
                    }
                }
            }
        }
        .accessibilityLabel("Comparison of \(sortedSymbols.joined(separator: ", ")), \(selectedTimeRange.description)")
        .accessibilityValue(normalized ? "Normalised to percentage change" : "Absolute prices")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6))
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisTick()
                if normalized {
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text(doubleValue.formatted(.percent.precision(.fractionLength(0))))
                        }
                    }
                } else {
                    AxisValueLabel()
                }
            }
        }
    }

    var comparisonLegend: some View {
        // Read once for the legend, not once per entry.
        let lineRouteActive = FolyncSettingsStore.shared.load().isSupplementalRouteActive(.historicalLineCharts)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                ForEach(Array(selectedComparisonSymbols).sorted(), id: \.self) { symbol in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForSymbol(symbol))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(symbol)
                                .font(.caption)
                                .foregroundColor(.primary)
                            if let status = comparisonSourceStatus(for: symbol, lineRouteActive: lineRouteActive) {
                                Text(status.label)
                                    .font(.caption2)
                                    .foregroundStyle(status == .unavailable ? .red : .secondary)
                            } else {
                                Text("Folync · loading")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let coverage = historicalDataManager.folyncCoverage(
                                for: symbol,
                                timeRange: selectedTimeRange,
                                customFrom: queryCustomFrom,
                                customTo: queryCustomTo
                            ) {
                                Text(coverage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StockbarPalette.sheetHeaderFill)
        .cornerRadius(6)
    }

    func comparisonSourceStatus(for symbol: String, lineRouteActive: Bool) -> FolyncSupplementalSourceStatus? {
        if let status = historicalDataManager.folyncSourceStatus(
            for: symbol,
            timeRange: selectedTimeRange,
            customFrom: queryCustomFrom,
            customTo: queryCustomTo
        ) {
            return status
        }
        guard lineRouteActive,
              dataModel?.folyncCapabilities?.isTrackedOrAllowlisted(symbol) == true else {
            return .legacy
        }
        return nil
    }

    /// Prices in different currencies cannot share one axis.
    var comparisonMixesCurrencies: Bool {
        Set(selectedComparisonSymbols.map { symbol in
            dataModel?.realTimeTrades.first { $0.trade.name == symbol }?.realTimeInfo.currency
                ?? SymbolMetadata.defaultCurrency(for: symbol)
        }).count > 1
    }

    var usesNormalizedComparison: Bool { normalizedComparison || comparisonMixesCurrencies }

    func colorForSymbol(_ symbol: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink]
        let sortedSymbols = Array(selectedComparisonSymbols).sorted()
        guard let index = sortedSymbols.firstIndex(of: symbol) else { return .gray }
        return colors[index % colors.count]
    }
}
