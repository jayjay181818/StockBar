import AppKit
import Combine
import SwiftUI

@MainActor
struct StockbarMainView: View {
    @ObservedObject var dataModel: DataModel
    @ObservedObject var navigationState: StockbarMainNavigationState
    @AppStorage("appearanceMode", store: StockbarRuntimeStorage.userDefaults) private var appearanceMode = "system"

    init(dataModel: DataModel, navigationState: StockbarMainNavigationState? = nil) {
        self.dataModel = dataModel
        self.navigationState = navigationState ?? StockbarMainNavigationState()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 1060, minHeight: 680)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
    }

    @State private var isRefreshing = false
    @State private var lastManualRefresh: Date?

    private var sidebar: some View {
        List(selection: Binding(
            get: { Optional(navigationState.selectedSection) },
            set: { newValue in
                if let newValue { navigationState.selectedSection = newValue }
            }
        )) {
            Section("Portfolio") {
                sidebarRows(StockbarMainSection.portfolioSections)
            }
            Section("Analysis") {
                sidebarRows(StockbarMainSection.analysisSections)
            }
            Section("Maintenance") {
                sidebarRows(StockbarMainSection.maintenanceSections)
            }
            Section {
                sidebarRows([.settings])
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            refreshControl
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 210)
    }

    private func sidebarRows(_ sections: [StockbarMainSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
    }

    private var refreshControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await dataModel.refreshAllTrades()
                    isRefreshing = false
                    lastManualRefresh = Date()
                }
            } label: {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "Refreshing…" : "Refresh Prices")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh market prices now (⌘R). Prices refreshed recently may be served from cache.")

            if let lastManualRefresh {
                Text("Requested \(lastManualRefresh, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationState.selectedSection {
        case .overview:
            StockbarOverviewView(dataModel: dataModel, navigationState: navigationState)
        case .holdings:
            StockbarHoldingsView(dataModel: dataModel)
        case .charts:
            VStack(alignment: .leading, spacing: 16) {
                Text("Performance").font(.largeTitle).fontWeight(.semibold)
                ScrollView {
                    PerformanceChartView(availableSymbols: availableSymbols, dataModel: dataModel)
                }
            }
            .padding(26)
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
        case .settings:
            StockbarSettingsView(dataModel: dataModel)
        }
    }

    private var availableSymbols: [String] {
        dataModel.realTimeTrades
            .map(\.trade.name)
            .filter { !$0.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0) }
    }
}

@MainActor
final class StockbarMainNavigationState: ObservableObject {
    @Published var selectedSection: StockbarMainSection {
        didSet { defaults.set(selectedSection.rawValue, forKey: "mainWindow.selectedSection") }
    }
    private let defaults: UserDefaults

    init(selectedSection: StockbarMainSection? = nil, defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
        self.selectedSection = selectedSection
            ?? defaults.string(forKey: "mainWindow.selectedSection").flatMap(StockbarMainSection.init(rawValue:))
            ?? .overview
    }
}

enum StockbarMainSection: String, CaseIterable, Identifiable {
    case overview
    case holdings
    case charts
    case risk
    case allocation
    case alerts
    case backups
    case dataHealth
    case diagnostics
    case settings

    var id: String { rawValue }

    static var portfolioSections: [StockbarMainSection] {
        [.overview, .holdings, .alerts]
    }

    static var analysisSections: [StockbarMainSection] {
        [.charts, .risk, .allocation]
    }

    static var maintenanceSections: [StockbarMainSection] {
        [.backups, .dataHealth, .diagnostics]
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .holdings: "Holdings"
        case .charts: "Performance"
        case .risk: "Risk"
        case .allocation: "Allocation"
        case .alerts: "Alerts"
        case .backups: "Backups"
        case .dataHealth: "Data Health"
        case .diagnostics: "Diagnostics"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.xyaxis.line"
        case .holdings: "tablecells"
        case .charts: "chart.line.uptrend.xyaxis"
        case .risk: "waveform.path.ecg"
        case .allocation: "chart.pie"
        case .alerts: "bell"
        case .backups: "clock.arrow.circlepath"
        case .dataHealth: "externaldrive.badge.checkmark"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
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
    @ObservedObject private var currencyConverter = CurrencyConverter.shared
    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selectedHoldingID: UUID?
    @State private var sortOrder: [KeyPathComparator<RealTimeTrade>] = []
    @State private var dayProfitLossDisplayMode: ProfitLossDisplayMode = .amount
    @State private var totalProfitLossDisplayMode: ProfitLossDisplayMode = .amount

    private var visibleIndices: [Int] {
        dataModel.realTimeTrades.indices.filter {
            !SymbolMetadata.isBenchmarkSymbol(dataModel.realTimeTrades[$0].trade.name)
                && (searchText.isEmpty || dataModel.realTimeTrades[$0].trade.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if currencyConverter.isUsingFallbackRates {
                // Converted values are estimates until a live FX refresh lands —
                // never present them as if they were live figures.
                Label(
                    "Live exchange rates unavailable — converted values are approximate.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Warning: live exchange rates unavailable, converted values are approximate")
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Holdings")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(dataModel.isFolyncPortfolioActive
                         ? "Read-only Folync holdings. Visibility and alerts remain local to Stockbar."
                         : "Edit positions, menu bar visibility, cost basis, and watchlist status.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isEditing = true
                    searchText = ""
                    dataModel.realTimeTrades.append(emptyRealTimeTrade())
                    dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
                } label: {
                    Label("Add Holding", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(dataModel.isFolyncPortfolioActive)
            }

            HStack(spacing: 16) {
                let netValue = dataModel.calculateNetValue()
                HoldingMetricCard(
                    title: "Net Value",
                    value: HoldingsSummaryAmountFormatter.format(
                        netValue,
                        dataModel: dataModel
                    ),
                    tint: .blue
                )
                let gains = dataModel.calculateNetGains()
                HoldingMetricCard(
                    title: "Total Net Gains",
                    value: HoldingsSummaryAmountFormatter.format(
                        gains,
                        dataModel: dataModel,
                        signed: true
                    ),
                    tint: gains.amount > 0 ? .green : (gains.amount < 0 ? .red : .secondary)
                )
                HoldingMetricCard(title: "Tracked Symbols", value: "\(dataModel.realTimeTrades.filter { !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }.count)", tint: .purple)
            }

            HStack {
                TextField("Search holdings", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Search holdings")
                Spacer()
                if !dataModel.isFolyncPortfolioActive {
                    Toggle("Edit positions", isOn: $isEditing).toggleStyle(.button)
                }
            }
            if isEditing && !dataModel.isFolyncPortfolioActive {
                holdingsTable
            } else {
                compactTable
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactTable: some View {
        Table(visibleIndices.map { dataModel.realTimeTrades[$0] }.sorted(using: sortOrder),
              selection: $selectedHoldingID, sortOrder: $sortOrder) {
            TableColumn("Instrument", value: \.trade.name) { trade in
                VStack(alignment: .leading, spacing: 3) {
                    Text(trade.trade.name).fontWeight(.medium)
                    Text(trade.displayLabel ?? trade.realTimeInfo.shortName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 5)
            }.width(min: 130, ideal: 180)
            TableColumn("Price", value: \.realTimeInfo.currentPrice) { trade in
                Text(HoldingsCurrencyFormatter.amount(trade.realTimeInfo.getCurrentDisplayPrice(),
                                                      currency: trade.realTimeInfo.currency ?? ""))
                    .monospacedDigit()
            }.width(min: 85, ideal: 100)
            TableColumn("Value") { trade in
                if trade.trade.isWatchlistOnly {
                    // No position: a $0.00 value would read as a real holding.
                    Text("—").foregroundStyle(.secondary).help("Watchlist only")
                } else {
                    let value = dataModel.calculatePositionValue(for: trade)
                    Text(HoldingsCurrencyFormatter.amount(value.amount, currency: value.currency))
                        .monospacedDigit()
                }
            }.width(min: 95, ideal: 115)
            TableColumn("Today") { trade in
                ProfitLossCell(summary: dataModel.calculatePositionProfitLoss(for: trade), kind: .day,
                               displayMode: dayProfitLossDisplayMode, action: { dayProfitLossDisplayMode.toggle() })
            }.width(min: 90, ideal: 110)
            TableColumn("Total P&L") { trade in
                ProfitLossCell(summary: dataModel.calculatePositionProfitLoss(for: trade), kind: .total,
                               displayMode: totalProfitLossDisplayMode, action: { totalProfitLossDisplayMode.toggle() })
            }.width(min: 100, ideal: 120)
            TableColumn("Menu bar") { trade in
                Toggle("Show \(trade.trade.name) in menu bar", isOn: Binding(
                    get: { trade.trade.showInMenuBar },
                    set: { dataModel.setPositionMenuBarVisibility($0, for: trade) }
                )).labelsHidden()
            }.width(60)
        }
        .overlay {
            if visibleIndices.isEmpty {
                ContentUnavailableView(searchText.isEmpty ? "No holdings yet" : "No matching holdings",
                                       systemImage: "tablecells",
                                       description: Text(searchText.isEmpty ? "Add a holding or connect a portfolio in Settings." : "Try another symbol."))
            }
        }
    }

    private var holdingsTable: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HoldingsHeaderRow(
                        dayProfitLossDisplayMode: dayProfitLossDisplayMode,
                        totalProfitLossDisplayMode: totalProfitLossDisplayMode,
                        onToggleDayProfitLossDisplayMode: { dayProfitLossDisplayMode.toggle() },
                        onToggleTotalProfitLossDisplayMode: { totalProfitLossDisplayMode.toggle() }
                    )
                    ScrollView(.vertical) {
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
                                .background(
                                    index.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color(nsColor: .controlBackgroundColor).opacity(0.35)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(
                    width: max(HoldingsTableLayout.contentWidth, geometry.size.width),
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(minHeight: 280, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func delete(at index: Int) {
        // The row index can be stale if the portfolio was replaced between render
        // and tap (e.g. a Folync activation swapping the whole array).
        guard dataModel.realTimeTrades.indices.contains(index) else { return }
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
        HStack(spacing: HoldingsTableLayout.spacing) {
            header("Visible", width: HoldingsTableLayout.visibleWidth)
            header("Symbol", width: HoldingsTableLayout.symbolWidth)
            header("Units", width: HoldingsTableLayout.unitsWidth)
            header("Avg Cost", width: HoldingsTableLayout.averageCostWidth)
            header("Currency", width: HoldingsTableLayout.currencyWidth)
            header("Current", width: HoldingsTableLayout.currentWidth)
            header("Value", width: HoldingsTableLayout.valueWidth)
            profitLossHeader(
                title: "Day P/L",
                displayMode: dayProfitLossDisplayMode,
                width: HoldingsTableLayout.dayProfitLossWidth,
                action: onToggleDayProfitLossDisplayMode
            )
            profitLossHeader(
                title: "Total P/L",
                displayMode: totalProfitLossDisplayMode,
                width: HoldingsTableLayout.totalProfitLossWidth,
                action: onToggleTotalProfitLossDisplayMode
            )
            header("Actions", width: HoldingsTableLayout.actionsWidth)
        }
        .padding(.horizontal, HoldingsTableLayout.horizontalPadding)
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

    /// An empty field is still being typed into, so only flag real violations.
    private var isSymbolAcceptable: Bool {
        let name = realTimeTrade.trade.name
        return name.isEmpty || PythonConfiguration.validateSymbol(name)
    }

    private var isDuplicateSymbol: Bool {
        dataModel.hasDuplicateSymbol(realTimeTrade)
    }

    private var symbolHelp: String {
        if !isSymbolAcceptable {
            return "Only A–Z, 0–9, . ^ = - are allowed, and a symbol cannot start with '-'"
        }
        if isDuplicateSymbol {
            return "This symbol is already in your portfolio. Only the first row is kept when saved — combine the units into one row."
        }
        return "Ticker symbol"
    }

    private let currencies = ["GBX", "GBP", "USD", "EUR", "JPY"]

    private var financialFieldsReadOnly: Bool {
        dataModel.positionFinancialFieldsReadOnly(for: realTimeTrade)
    }

    var body: some View {
        HStack(spacing: HoldingsTableLayout.spacing) {
            Toggle("", isOn: Binding(
                get: { realTimeTrade.trade.showInMenuBar },
                set: { newValue in
                    dataModel.setPositionMenuBarVisibility(newValue, for: realTimeTrade)
                }
            ))
            .labelsHidden()
            .frame(width: HoldingsTableLayout.visibleWidth, alignment: .leading)

            if let displayLabel = realTimeTrade.displayLabel, realTimeTrade.sourceIdentity != nil {
                Text(displayLabel)
                    .lineLimit(2)
                    .frame(width: HoldingsTableLayout.symbolWidth, alignment: .leading)
            } else {
                TextField("Symbol", text: $realTimeTrade.trade.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: HoldingsTableLayout.symbolWidth)
                    .foregroundStyle(isSymbolAcceptable && !isDuplicateSymbol ? Color.primary : Color.red)
                    .overlay(alignment: .trailing) {
                        if isDuplicateSymbol {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .padding(.trailing, 6)
                                .accessibilityLabel("Duplicate symbol")
                        }
                    }
                    .help(symbolHelp)
                    .onChange(of: realTimeTrade.trade.name) { _, newValue in
                        // Normalise as the user types so an unusable ticker never
                        // reaches the Python bridge in the first place.
                        let normalized = newValue.uppercased()
                        if normalized != newValue {
                            realTimeTrade.trade.name = normalized
                            return
                        }
                        dataModel.triggerTradeUpdate()
                    }
            }

            if financialFieldsReadOnly {
                Text(realTimeTrade.trade.position.unitSize, format: .number.precision(.fractionLength(0...6)))
                    .monospacedDigit()
                    .frame(width: HoldingsTableLayout.unitsWidth, alignment: .leading)
                Text(realTimeTrade.trade.position.getNormalizedAvgCost(for: realTimeTrade.trade.name),
                     format: .number.precision(.fractionLength(2...4)))
                    .monospacedDigit()
                    .frame(width: HoldingsTableLayout.averageCostWidth, alignment: .leading)
                Text(realTimeTrade.realTimeInfo.currency ?? "—")
                    .frame(width: HoldingsTableLayout.currencyWidth, alignment: .leading)
            } else {
            TextField("Units", text: $realTimeTrade.trade.position.unitSizeString)
                .textFieldStyle(.roundedBorder)
                .frame(width: HoldingsTableLayout.unitsWidth)
                .onChange(of: realTimeTrade.trade.position.unitSizeString) { _, _ in dataModel.triggerTradeUpdate() }

            TextField("Avg Cost", text: $realTimeTrade.trade.position.positionAvgCostString)
                .textFieldStyle(.roundedBorder)
                .frame(width: HoldingsTableLayout.averageCostWidth)
                .onChange(of: realTimeTrade.trade.position.positionAvgCostString) { _, _ in dataModel.triggerTradeUpdate() }

            Picker("", selection: currencyBinding) {
                ForEach(currencies, id: \.self) { currency in
                    Text(currency).tag(currency)
                }
            }
            .labelsHidden()
            .frame(width: HoldingsTableLayout.currencyWidth)

            }

            Text(currentPriceText)
                .foregroundStyle(.secondary)
                .frame(width: HoldingsTableLayout.currentWidth, alignment: .leading)

            Text(valueText)
                .frame(width: HoldingsTableLayout.valueWidth, alignment: .leading)

            ProfitLossCell(
                summary: profitLossSummary,
                kind: .day,
                displayMode: dayProfitLossDisplayMode,
                action: onToggleDayProfitLossDisplayMode
            )
            .frame(width: HoldingsTableLayout.dayProfitLossWidth, alignment: .leading)

            ProfitLossCell(
                summary: profitLossSummary,
                kind: .total,
                displayMode: totalProfitLossDisplayMode,
                action: onToggleTotalProfitLossDisplayMode
            )
            .frame(width: HoldingsTableLayout.totalProfitLossWidth, alignment: .leading)

            HStack(spacing: 8) {
                Button {
                    realTimeTrade.trade.isWatchlistOnly.toggle()
                    dataModel.triggerTradeUpdate()
                } label: {
                    Image(systemName: realTimeTrade.trade.isWatchlistOnly ? "eye.fill" : "eye")
                }
                .help(realTimeTrade.trade.isWatchlistOnly
                      ? "Watchlist only — excluded from portfolio totals. Click to track as a holding."
                      : "Track as watchlist only (price shown, excluded from portfolio totals)")
                .accessibilityLabel(realTimeTrade.trade.isWatchlistOnly ? "Track as holding" : "Mark as watchlist only")
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                    .help("Move up")
                    .accessibilityLabel("Move \(realTimeTrade.trade.name) up")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
                    .help("Move down")
                    .accessibilityLabel("Move \(realTimeTrade.trade.name) down")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help("Remove holding")
                    .accessibilityLabel("Remove \(realTimeTrade.trade.name)")
            }
            .buttonStyle(.borderless)
            .disabled(financialFieldsReadOnly)
            .foregroundStyle(.secondary)
            .frame(width: HoldingsTableLayout.actionsWidth, alignment: .leading)
        }
        .padding(.horizontal, HoldingsTableLayout.horizontalPadding)
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
        let value = dataModel.calculatePositionValue(for: realTimeTrade)
        return HoldingsCurrencyFormatter.amount(value.amount, currency: value.currency)
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
            return HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency)
        case .percent:
            guard percent.isFinite else { return "-" }
            return String(format: "%+.2f%%", percent)
        }
    }

    private var foregroundStyle: Color {
        guard amount.isFinite, amount != 0 else { return .secondary }
        return amount > 0 ? .green : .red
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
        .monospacedDigit()
        .overlay(alignment: .bottom) { Divider() }
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
