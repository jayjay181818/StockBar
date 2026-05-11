import AppKit
import SwiftUI

@MainActor
struct StockbarMainView: View {
    @ObservedObject var dataModel: DataModel
    @State private var selectedSection: StockbarMainSection = .holdings

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 1280, minHeight: 680)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stockbar")
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.top, 18)

            ForEach(StockbarMainSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedSection == section ? Color.accentColor.opacity(0.24) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSection == section ? .primary : .secondary)
                .padding(.horizontal, 10)
            }

            Spacer()

            Divider()
                .padding(.horizontal, 12)

            Button {
                Task { await dataModel.refreshAllTrades() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            Button {
                NSApp.sendAction(#selector(AppDelegate.showPreferences(_:)), to: NSApp.delegate, from: nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .frame(width: 190)
        .background(.bar)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .holdings:
            StockbarHoldingsView(dataModel: dataModel)
        case .charts:
            ScrollView {
                PerformanceChartView(availableSymbols: availableSymbols, dataModel: dataModel)
                    .padding(24)
            }
        case .risk:
            RiskAnalyticsView(dataModel: dataModel)
                .padding(24)
        case .allocation:
            PortfolioAnalyticsView(dataModel: dataModel)
                .padding(24)
        case .alerts:
            ScrollView {
                PriceAlertManagementView(dataModel: dataModel)
                    .padding(24)
            }
        case .backups:
            StockbarBackupsView(dataModel: dataModel)
        case .dataHealth:
            StockbarDataHealthView(dataModel: dataModel)
        case .diagnostics:
            StockbarDiagnosticsView()
        }
    }

    private var availableSymbols: [String] {
        dataModel.realTimeTrades
            .map(\.trade.name)
            .filter { !$0.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0) }
    }
}

private enum StockbarMainSection: String, CaseIterable, Identifiable {
    case holdings
    case charts
    case risk
    case allocation
    case alerts
    case backups
    case dataHealth
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdings: "Holdings"
        case .charts: "Charts"
        case .risk: "Risk"
        case .allocation: "Allocation"
        case .alerts: "Alerts"
        case .backups: "Backups"
        case .dataHealth: "Data Health"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .holdings: "tablecells"
        case .charts: "chart.line.uptrend.xyaxis"
        case .risk: "exclamationmark.triangle"
        case .allocation: "chart.pie"
        case .alerts: "bell"
        case .backups: "clock.arrow.circlepath"
        case .dataHealth: "externaldrive.badge.checkmark"
        case .diagnostics: "stethoscope"
        }
    }
}

private enum ProfitLossDisplayMode {
    case amount
    case percent

    var label: String {
        switch self {
        case .amount: "Amt"
        case .percent: "%"
        }
    }

    mutating func toggle() {
        self = self == .amount ? .percent : .amount
    }
}

@MainActor
private struct StockbarHoldingsView: View {
    @ObservedObject var dataModel: DataModel
    @State private var dayProfitLossDisplayMode: ProfitLossDisplayMode = .amount
    @State private var totalProfitLossDisplayMode: ProfitLossDisplayMode = .amount

    private var visibleIndices: [Int] {
        dataModel.realTimeTrades.indices.filter {
            !SymbolMetadata.isBenchmarkSymbol(dataModel.realTimeTrades[$0].trade.name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Holdings")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Edit positions, menu bar visibility, cost basis, and watchlist status.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dataModel.realTimeTrades.append(emptyRealTimeTrade())
                    dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
                } label: {
                    Label("Add Holding", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 16) {
                HoldingMetricCard(title: "Net Value", value: formatted(dataModel.calculateNetValue()), tint: .blue)
                let gains = dataModel.calculateNetGains()
                HoldingMetricCard(
                    title: "Total Net Gains",
                    value: formatted(gains),
                    tint: gains.amount >= 0 ? .green : .red
                )
                HoldingMetricCard(title: "Tracked Symbols", value: "\(visibleIndices.count)", tint: .purple)
            }

            holdingsTable
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var holdingsTable: some View {
        VStack(spacing: 0) {
            HoldingsHeaderRow(
                dayProfitLossDisplayMode: dayProfitLossDisplayMode,
                totalProfitLossDisplayMode: totalProfitLossDisplayMode,
                onToggleDayProfitLossDisplayMode: { dayProfitLossDisplayMode.toggle() },
                onToggleTotalProfitLossDisplayMode: { totalProfitLossDisplayMode.toggle() }
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleIndices, id: \.self) { index in
                        HoldingsEditableRow(
                            realTimeTrade: dataModel.realTimeTrades[index],
                            dataModel: dataModel,
                            dayProfitLossDisplayMode: dayProfitLossDisplayMode,
                            totalProfitLossDisplayMode: totalProfitLossDisplayMode,
                            onToggleDayProfitLossDisplayMode: { dayProfitLossDisplayMode.toggle() },
                            onToggleTotalProfitLossDisplayMode: { totalProfitLossDisplayMode.toggle() },
                            rowIndex: index,
                            canMoveUp: index > 0,
                            canMoveDown: index < dataModel.realTimeTrades.count - 1,
                            onDelete: { delete(at: index) },
                            onMove: { move(from: index, by: $0) }
                        )
                        .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatted(_ amount: (amount: Double, currency: String)) -> String {
        "\(String(format: "%.2f", amount.amount)) \(amount.currency)"
    }

    private func delete(at index: Int) {
        dataModel.realTimeTrades.remove(at: index)
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
    }

    private func move(from index: Int, by offset: Int) {
        let destination = index + offset
        guard dataModel.realTimeTrades.indices.contains(index),
              dataModel.realTimeTrades.indices.contains(destination)
        else { return }
        dataModel.realTimeTrades.swapAt(index, destination)
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
    }
}

@MainActor
private struct HoldingsHeaderRow: View {
    let dayProfitLossDisplayMode: ProfitLossDisplayMode
    let totalProfitLossDisplayMode: ProfitLossDisplayMode
    let onToggleDayProfitLossDisplayMode: () -> Void
    let onToggleTotalProfitLossDisplayMode: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            header("Visible", width: 58)
            header("Symbol", width: 150)
            header("Units", width: 130)
            header("Avg Cost", width: 140)
            header("Currency", width: 120)
            header("Current", width: 130)
            header("Value", width: 145)
            profitLossHeader(
                title: "Day P/L",
                displayMode: dayProfitLossDisplayMode,
                width: 120,
                action: onToggleDayProfitLossDisplayMode
            )
            profitLossHeader(
                title: "Total P/L",
                displayMode: totalProfitLossDisplayMode,
                width: 120,
                action: onToggleTotalProfitLossDisplayMode
            )
            header("Actions", width: 105)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private func header(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.headline)
            .frame(width: width, alignment: .leading)
    }

    private func profitLossHeader(
        title: String,
        displayMode: ProfitLossDisplayMode,
        width: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text(displayMode.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle \(title) between amount and percentage")
    }
}

@MainActor
private struct HoldingsEditableRow: View {
    @ObservedObject var realTimeTrade: RealTimeTrade
    let dataModel: DataModel
    let dayProfitLossDisplayMode: ProfitLossDisplayMode
    let totalProfitLossDisplayMode: ProfitLossDisplayMode
    let onToggleDayProfitLossDisplayMode: () -> Void
    let onToggleTotalProfitLossDisplayMode: () -> Void
    let rowIndex: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    private let currencies = ["GBX", "GBP", "USD", "EUR", "JPY"]

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { realTimeTrade.trade.showInMenuBar },
                set: { newValue in
                    realTimeTrade.trade.showInMenuBar = newValue
                    dataModel.triggerTradeUpdate()
                    NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                }
            ))
            .labelsHidden()
            .frame(width: 58, alignment: .leading)

            TextField("Symbol", text: $realTimeTrade.trade.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onChange(of: realTimeTrade.trade.name) { _, _ in dataModel.triggerTradeUpdate() }

            TextField("Units", text: $realTimeTrade.trade.position.unitSizeString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onChange(of: realTimeTrade.trade.position.unitSizeString) { _, _ in dataModel.triggerTradeUpdate() }

            TextField("Avg Cost", text: $realTimeTrade.trade.position.positionAvgCostString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onChange(of: realTimeTrade.trade.position.positionAvgCostString) { _, _ in dataModel.triggerTradeUpdate() }

            Picker("", selection: currencyBinding) {
                ForEach(currencies, id: \.self) { currency in
                    Text(currency).tag(currency)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Text(currentPriceText)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)

            Text(valueText)
                .frame(width: 145, alignment: .leading)

            ProfitLossCell(
                summary: profitLossSummary,
                kind: .day,
                displayMode: dayProfitLossDisplayMode,
                action: onToggleDayProfitLossDisplayMode
            )
                .frame(width: 120, alignment: .leading)

            ProfitLossCell(
                summary: profitLossSummary,
                kind: .total,
                displayMode: totalProfitLossDisplayMode,
                action: onToggleTotalProfitLossDisplayMode
            )
            .frame(width: 120, alignment: .leading)

            HStack(spacing: 8) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                Button(action: onDelete) { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 105, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var currencyBinding: Binding<String> {
        Binding(
            get: { realTimeTrade.trade.position.costCurrency ?? defaultCurrency },
            set: { newValue in
                realTimeTrade.trade.position.costCurrency = newValue
                realTimeTrade.trade.position.currency = newValue
                dataModel.triggerTradeUpdate()
            }
        )
    }

    private var defaultCurrency: String {
        SymbolMetadata.isUKSymbol(realTimeTrade.trade.name) ? "GBX" : "USD"
    }

    private var currentPrice: Double {
        realTimeTrade.realTimeInfo.getCurrentDisplayPrice()
    }

    private var currentPriceText: String {
        guard currentPrice.isFinite else { return "-" }
        return "\(String(format: "%.2f", currentPrice)) \(realTimeTrade.realTimeInfo.currency ?? "")"
    }

    private var valueText: String {
        guard currentPrice.isFinite else { return "-" }
        let value = currentPrice * realTimeTrade.trade.position.unitSize
        return "\(String(format: "%.2f", value)) \(realTimeTrade.realTimeInfo.currency ?? "")"
    }

    private var profitLossSummary: PositionProfitLossSummary {
        dataModel.calculatePositionProfitLoss(for: realTimeTrade)
    }
}

private enum ProfitLossKind {
    case day
    case total
}

@MainActor
private struct ProfitLossCell: View {
    let summary: PositionProfitLossSummary
    let kind: ProfitLossKind
    let displayMode: ProfitLossDisplayMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .foregroundStyle(foregroundStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var amount: Double {
        switch kind {
        case .day: summary.dayAmount
        case .total: summary.totalAmount
        }
    }

    private var percent: Double {
        switch kind {
        case .day: summary.dayPercent
        case .total: summary.totalPercent
        }
    }

    private var text: String {
        switch displayMode {
        case .amount:
            guard amount.isFinite else { return "-" }
            return String(format: "%+.2f", amount)
        case .percent:
            guard percent.isFinite else { return "-" }
            return String(format: "%+.2f%%", percent)
        }
    }

    private var foregroundStyle: Color {
        guard amount.isFinite else { return .secondary }
        return amount >= 0 ? .green : .red
    }

    private var helpText: String {
        switch displayMode {
        case .amount: "Show percentage"
        case .percent: "Show amount"
        }
    }
}

@MainActor
private struct HoldingMetricCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private struct StockbarBackupsView: View {
    @ObservedObject var dataModel: DataModel
    @State private var showingRestoreSheet = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Backups", subtitle: "Create, restore, and inspect portfolio backups.")
                HStack(spacing: 12) {
                    Button("Backup Now") {
                        Task {
                            let success = await BackupService.shared.performManualBackup(trades: dataModel.realTimeTrades)
                            status = success ? "Backup completed successfully." : "Backup failed. Check Diagnostics."
                        }
                    }
                    Button("Restore from Backup") {
                        showingRestoreSheet = true
                    }
                    .disabled(BackupService.shared.listAvailableBackups().isEmpty)
                    Button("View Backups") {
                        BackupService.shared.openBackupDirectory()
                    }
                }
                if !status.isEmpty {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
        }
        .sheet(isPresented: $showingRestoreSheet) {
            RestoreBackupView(isPresented: $showingRestoreSheet, dataModel: dataModel)
        }
    }
}

@MainActor
private struct StockbarDataHealthView: View {
    @ObservedObject var dataModel: DataModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Data Health", subtitle: "Current portfolio and cache state at a glance.")
                HealthRow(label: "Tracked rows", value: "\(dataModel.realTimeTrades.count)")
                HealthRow(label: "Visible in menu bar", value: "\(dataModel.realTimeTrades.filter(\.trade.showInMenuBar).count)")
                HealthRow(label: "Preferred currency", value: dataModel.preferredCurrency)
                HealthRow(label: "Refresh interval", value: "\(Int(dataModel.refreshInterval / 60)) min")
            }
            .padding(26)
        }
    }
}

@MainActor
private struct StockbarDiagnosticsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Diagnostics", subtitle: "Recent Stockbar logs and runtime diagnostics.")
            DebugLogView()
        }
        .padding(26)
    }
}

@MainActor
private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title)
                .fontWeight(.semibold)
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct HealthRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
