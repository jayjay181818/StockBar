import AppKit
import Combine
import SwiftUI

@MainActor
struct StockbarMainView: View {
    let dataModel: DataModel
    let navigationState: StockbarMainNavigationState
    @AppStorage("appearanceMode", store: StockbarRuntimeStorage.userDefaults) private var appearanceMode = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRefreshing = false

    init(dataModel: DataModel, navigationState: StockbarMainNavigationState? = nil) {
        self.dataModel = dataModel
        self.navigationState = navigationState ?? StockbarMainNavigationState()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // Pin each page to the column's exact size. Pages that fill the
            // height without their own scroll view (Holdings, Diagnostics)
            // otherwise take their ideal height and overflow the window.
            GeometryReader { proxy in
                ZStack {
                    detail
                        .id(navigationState.selectedSection)
                        .transition(.stockbarPage(reduceMotion: reduceMotion))
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion),
                           value: navigationState.selectedSection)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1060, minHeight: 680)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
    }

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
    }

    private func sidebarRows(_ sections: [StockbarMainSection]) -> some View {
        ForEach(sections) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
    }

    /// Where the numbers come from, when they last changed, and a way to
    /// refresh them — visible from every section.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(portfolioSourceTitle, systemImage: portfolioSourceIcon)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .help(dataModel.isFolyncPortfolioActive ? dataModel.folyncConnectionState.message : portfolioSourceTitle)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(StockbarRelativeTime.updatedText(lastPriceUpdate, now: context.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button(action: refresh) {
                    StockbarRefreshIcon(isRefreshing: isRefreshing)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh prices now (⌘R). Prices fetched very recently may be reused.")
                .accessibilityLabel(isRefreshing ? "Refreshing prices" : "Refresh prices")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await dataModel.refreshAllTrades()
            isRefreshing = false
        }
    }

    private var portfolioSourceTitle: String {
        switch dataModel.displayValuationSource {
        case .folyncProvided: "Folync portfolio"
        case .brokerProvided: "Trading 212"
        case .localCalculationFallback, .marketDataFallback: "Local portfolio"
        }
    }

    private var portfolioSourceIcon: String {
        dataModel.isFolyncPortfolioActive ? "link" : "internaldrive"
    }

    private var lastPriceUpdate: Date? {
        StockbarRelativeTime.latest(dataModel.realTimeTrades
            .filter { !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }
            .map { $0.realTimeInfo.lastUpdateTime })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationState.selectedSection {
        case .overview:
            StockbarOverviewView(dataModel: dataModel, navigationState: navigationState)
        case .holdings:
            StockbarHoldingsView(dataModel: dataModel)
        case .charts:
            VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
                StockbarPageHeader("Performance", subtitle: "Portfolio value, gains and individual stocks over time.")
                PerformanceChartView(availableSymbols: availableSymbols, dataModel: dataModel)
            }
            .stockbarPage()
        case .risk:
            RiskAnalyticsView(dataModel: dataModel)
        case .allocation:
            PortfolioAnalyticsView(dataModel: dataModel)
        case .alerts:
            PriceAlertManagementView(dataModel: dataModel)
        case .backups:
            StockbarBackupsView(dataModel: dataModel)
        case .dataHealth:
            StockbarDataHealthView(dataModel: dataModel)
        case .diagnostics:
            StockbarDiagnosticsView()
        case .settings:
            StockbarSettingsView(dataModel: dataModel) { section in
                navigationState.selectedSection = section
            }
        }
    }

    private var availableSymbols: [String] {
        // One entry per ticker: the same one held in two accounts would
        // otherwise give two rows the same identity.
        var seen = Set<String>()
        return dataModel.realTimeTrades
            .map(\.trade.name)
            .filter { !$0.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0) && seen.insert($0).inserted }
    }
}

@MainActor
@Observable
final class StockbarMainNavigationState {
    var selectedSection: StockbarMainSection {
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

    mutating func toggle() {
        self = self == .amount ? .percent : .amount
    }
}

@MainActor
private struct StockbarHoldingsView: View {
    let dataModel: DataModel
    private let currencyConverter = CurrencyConverter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isEditing = false
    /// The row "Add Holding" just made, so the table can scroll to it and put
    /// the cursor in its symbol field instead of leaving it off screen.
    @State private var newlyAddedHoldingID: UUID?
    @State private var selectedHoldingID: UUID?
    @State private var sortOrder: [KeyPathComparator<RealTimeTrade>] = []
    @State private var dayProfitLossDisplayMode: ProfitLossDisplayMode = .amount
    @State private var totalProfitLossDisplayMode: ProfitLossDisplayMode = .amount
    @State private var pendingRemoval: PendingHoldingRemoval?

    private struct PendingHoldingRemoval: Identifiable {
        let id: UUID
        let symbol: String
    }

    /// Search by ticker or by company name.
    private static func matches(_ trade: RealTimeTrade, search: String) -> Bool {
        if trade.trade.name.localizedCaseInsensitiveContains(search) { return true }
        if let label = trade.displayLabel, label.localizedCaseInsensitiveContains(search) { return true }
        return trade.realTimeInfo.shortName.localizedCaseInsensitiveContains(search)
    }

    private var visibleIndices: [Int] {
        dataModel.realTimeTrades.indices.filter {
            !SymbolMetadata.isBenchmarkSymbol(dataModel.realTimeTrades[$0].trade.name)
                && (searchText.isEmpty || Self.matches(dataModel.realTimeTrades[$0], search: searchText))
        }
    }

    private var trackedTrades: [RealTimeTrade] {
        dataModel.realTimeTrades.filter { !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }
    }

    private var canEditPortfolio: Bool { !dataModel.isFolyncPortfolioActive && !dataModel.portfolioLoadFailed }

    private var subtitle: String {
        if dataModel.portfolioLoadFailed {
            return "Your saved holdings could not be loaded, so editing is paused to avoid overwriting them. Restart Stockbar or restore a backup."
        }
        return dataModel.isFolyncPortfolioActive
            ? "Read-only Folync holdings. Visibility and alerts remain local to Stockbar."
            : "Positions, cost basis, menu bar visibility and watchlist status."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StockbarPageHeader(
                "Holdings",
                subtitle: subtitle
            ) {
                HStack(spacing: 10) {
                    if canEditPortfolio {
                        Button {
                            setEditing(!isEditing)
                        } label: {
                            Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
                        }
                        .controlSize(.large)
                        .help(isEditing ? "Finish editing" : "Edit units, cost, currency and order")
                    }
                    Button(action: addHolding) {
                        Label("Add Holding", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canEditPortfolio)
                }
            }

            if currencyConverter.isUsingFallbackRates {
                // Converted values are estimates until a live FX refresh lands —
                // never present them as if they were live figures.
                StockbarNotice(message: "Live exchange rates unavailable — converted values are approximate.")
                    .accessibilityLabel("Warning: live exchange rates unavailable, converted values are approximate")
            }

            HStack(spacing: 14) {
                StockbarMetricTile(
                    title: "Net Value",
                    value: HoldingsSummaryAmountFormatter.format(dataModel.calculateNetValue(), dataModel: dataModel),
                    systemImage: "banknote"
                )
                let gains = dataModel.calculateNetGains()
                StockbarMetricTile(
                    title: "Total Net Gains",
                    value: HoldingsSummaryAmountFormatter.format(gains, dataModel: dataModel, signed: true),
                    systemImage: "chart.line.uptrend.xyaxis",
                    valueColor: StockbarPalette.signed(gains.amount, neutral: .primary)
                )
                StockbarMetricTile(
                    title: "Tracked Symbols",
                    value: "\(trackedTrades.count)",
                    detail: trackedSymbolsDetail,
                    systemImage: "list.bullet"
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                StockbarSearchField(text: $searchText, prompt: "Search holdings")
                    .frame(maxWidth: 320)
                if !searchText.isEmpty {
                    Text("\(visibleIndices.count) of \(trackedTrades.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if isEditing && canEditPortfolio {
                    Label("Editing — changes save automatically", systemImage: "pencil.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            ZStack {
                if isEditing && canEditPortfolio {
                    holdingsTable
                        .transition(.opacity)
                } else {
                    compactTable
                        .transition(.opacity)
                }
            }
            // Let the table shrink with the window instead of pushing the
            // page taller than it.
            .frame(minHeight: 220, maxHeight: .infinity)
        }
        .padding(StockbarLayout.pageInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Remove \(pendingRemoval?.symbol ?? "holding")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) { remove(id: removal.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The holding and its menu bar item will be removed from your portfolio.")
        }
    }

    private var trackedSymbolsDetail: String {
        let watchlist = trackedTrades.filter(\.trade.isWatchlistOnly).count
        let owned = trackedTrades.count - watchlist
        return watchlist == 0 ? "\(owned) held" : "\(owned) held · \(watchlist) watchlist"
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion)) {
            isEditing = editing
        }
    }

    private func addHolding() {
        searchText = ""
        setEditing(true)
        let added = emptyRealTimeTrade()
        dataModel.realTimeTrades.append(added)
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
        newlyAddedHoldingID = added.id
    }

    private var compactTable: some View {
        Table(visibleIndices.map { dataModel.realTimeTrades[$0] }.sorted(using: sortOrder),
              selection: $selectedHoldingID, sortOrder: $sortOrder) {
            TableColumn("Instrument", value: \.trade.name) { trade in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(trade.trade.name).fontWeight(.semibold)
                        if trade.trade.isWatchlistOnly {
                            Text("Watchlist")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(StockbarPalette.hoverFill, in: Capsule())
                        }
                    }
                    let name = trade.displayLabel ?? trade.realTimeInfo.shortName
                    if !name.isEmpty && name != trade.trade.name {
                        Text(name)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }.width(min: 130, ideal: 190)
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
            TableColumn("Menu Bar") { trade in
                Toggle("Show \(trade.trade.name) in menu bar", isOn: Binding(
                    get: { trade.trade.showInMenuBar },
                    set: { dataModel.setPositionMenuBarVisibility($0, for: trade) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show \(trade.trade.name) as its own menu bar item")
            }.width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .clipShape(RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous)
                .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
        )
        .overlay {
            if visibleIndices.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "No holdings yet" : "No matching holdings",
                          systemImage: searchText.isEmpty ? "tablecells" : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? "Add a holding, or connect a portfolio in Settings → Connections." : "Try another symbol.")
                } actions: {
                    if searchText.isEmpty && canEditPortfolio {
                        Button("Add Holding", action: addHolding)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var holdingsTable: some View {
        // Read the rows here, while the page's body is evaluated. GeometryReader
        // builds its content later, during layout, and Observation does not
        // re-run it when the rows change in the same update that shows the table.
        let indices = visibleIndices
        let trades = dataModel.realTimeTrades
        return GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HoldingsHeaderRow()
                    Divider()
                    ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Keyed by the holding, not its position: keyed by
                            // index, deleting or moving a row handed its focus
                            // and half-typed text to whichever row took its place.
                            ForEach(indices.map { HoldingsRowEntry(index: $0, trade: trades[$0]) }) { entry in
                                let index = entry.index
                                let realTimeTrade = entry.trade
                                HoldingsEditableRow(
                                    realTimeTrade: realTimeTrade,
                                    dataModel: dataModel,
                                    rowIndex: index,
                                    focusSymbolOnAppear: entry.id == newlyAddedHoldingID,
                                    canMoveUp: HoldingsEditing.moveDestination(from: index, by: -1, visibleIndices: indices) != nil,
                                    canMoveDown: HoldingsEditing.moveDestination(from: index, by: 1, visibleIndices: indices) != nil,
                                    onDelete: { requestRemoval(of: realTimeTrade) },
                                    onMove: { move(from: index, by: $0) }
                                )
                                .background(
                                    index.isMultiple(of: 2)
                                    ? Color.clear
                                    : StockbarPalette.cardFill
                                )
                                .transition(.opacity)
                                .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: newlyAddedHoldingID) { _, added in
                        guard let added else { return }
                        withAnimation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion)) {
                            scroller.scrollTo(added, anchor: .bottom)
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
        .clipShape(RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StockbarLayout.cardRadius, style: .continuous)
                .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
        )
    }

    /// Blank rows go immediately; anything with a symbol asks first.
    private func requestRemoval(of realTimeTrade: RealTimeTrade) {
        let symbol = realTimeTrade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if symbol.isEmpty {
            remove(id: realTimeTrade.id)
        } else {
            pendingRemoval = PendingHoldingRemoval(id: realTimeTrade.id, symbol: symbol)
        }
    }

    private func remove(id: UUID) {
        // Look the row up by identity: the portfolio may have been replaced
        // between render and confirmation (e.g. a Folync activation).
        guard let index = dataModel.realTimeTrades.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
            _ = dataModel.realTimeTrades.remove(at: index)
        }
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
    }

    private func move(from index: Int, by offset: Int) {
        // Swap with the neighbouring *visible* row, so hidden rows (benchmarks, rows filtered
        // out by search) are never moved behind the user's back.
        guard let destination = HoldingsEditing.moveDestination(from: index, by: offset, visibleIndices: visibleIndices),
              dataModel.realTimeTrades.indices.contains(index),
              dataModel.realTimeTrades.indices.contains(destination)
        else { return }
        withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
            dataModel.realTimeTrades.swapAt(index, destination)
        }
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
    }
}

/// Header for the editing table. Profit and loss stay in the read-only table
/// so the editing columns, including row actions, fit the window.
@MainActor
private struct HoldingsHeaderRow: View {
    var body: some View {
        HStack(spacing: HoldingsTableLayout.spacing) {
            header("Menu Bar", width: HoldingsTableLayout.visibleWidth)
            header("Symbol", width: HoldingsTableLayout.symbolWidth)
            header("Units", width: HoldingsTableLayout.unitsWidth)
            header("Avg Cost", width: HoldingsTableLayout.averageCostWidth)
            header("Currency", width: HoldingsTableLayout.currencyWidth)
            header("Current", width: HoldingsTableLayout.currentWidth)
            header("Value", width: HoldingsTableLayout.valueWidth)
            header("Actions", width: HoldingsTableLayout.actionsWidth)
        }
        .padding(.horizontal, HoldingsTableLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StockbarPalette.cardFill)
    }

    private func header(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

@MainActor
private struct HoldingsEditableRow: View {
    @Bindable var realTimeTrade: RealTimeTrade
    let dataModel: DataModel
    let rowIndex: Int
    /// True for the row just added, which takes the cursor when it appears.
    var focusSymbolOnAppear = false
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var symbolFieldFocused: Bool
    /// The symbol when its field gained focus, to detect a rename on commit.
    @State private var symbolAtFocus: String?

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

    /// Every supported currency plus pence; a stored legacy code stays selectable.
    private var currencies: [String] {
        HoldingsEditing.currencyOptions(current: realTimeTrade.trade.position.costCurrency)
    }

    private var financialFieldsReadOnly: Bool {
        dataModel.positionFinancialFieldsReadOnly(for: realTimeTrade)
    }

    var body: some View {
        HStack(spacing: HoldingsTableLayout.spacing) {
            Toggle("Show \(realTimeTrade.trade.name) in menu bar", isOn: Binding(
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
                    .holdingsFieldProblem(
                        isSymbolAcceptable && !isDuplicateSymbol ? nil : symbolHelp,
                        help: symbolHelp
                    )
                    .focused($symbolFieldFocused)
                    .onAppear {
                        if focusSymbolOnAppear { symbolFieldFocused = true }
                    }
                    .onSubmit { commitSymbolChange() }
                    .onChange(of: symbolFieldFocused) { _, focused in
                        if focused {
                            symbolAtFocus = realTimeTrade.trade.name
                        } else {
                            commitSymbolChange()
                        }
                    }
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
                .holdingsFieldProblem(
                    Position.isReadableAmount(realTimeTrade.trade.position.unitSizeString)
                        ? nil : "Not a number Stockbar can read; it counts as 0 units",
                    help: "Units held"
                )
                .onChange(of: realTimeTrade.trade.position.unitSizeString) { _, _ in dataModel.triggerTradeUpdate() }

            TextField("Avg Cost", text: $realTimeTrade.trade.position.positionAvgCostString)
                .textFieldStyle(.roundedBorder)
                .frame(width: HoldingsTableLayout.averageCostWidth)
                .holdingsFieldProblem(
                    Position.isReadableAmount(realTimeTrade.trade.position.positionAvgCostString)
                        ? nil : "Not a number Stockbar can read; cost and P&L are left blank",
                    help: "Average cost per unit"
                )
                .onChange(of: realTimeTrade.trade.position.positionAvgCostString) { _, _ in dataModel.triggerTradeUpdate() }

            Picker("Currency for \(realTimeTrade.trade.name)", selection: currencyBinding) {
                ForEach(currencies, id: \.self) { currency in
                    Text(currency).tag(currency)
                }
            }
            .labelsHidden()
            .frame(width: HoldingsTableLayout.currencyWidth)

            }

            Text(currentPriceText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: HoldingsTableLayout.currentWidth, alignment: .leading)

            Text(valueText)
                .monospacedDigit()
                .frame(width: HoldingsTableLayout.valueWidth, alignment: .leading)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? StockbarPalette.hoverFill : Color.clear)
        .onHover { hovering in
            withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) { isHovered = hovering }
        }
    }

    /// A renamed holding must not keep showing the previous symbol's price: drop the stale quote
    /// and ask for a refresh once the edit is committed (Return or focus change).
    private func commitSymbolChange() {
        guard let original = symbolAtFocus, original != realTimeTrade.trade.name else { return }
        symbolAtFocus = realTimeTrade.trade.name
        guard !realTimeTrade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        realTimeTrade.realTimeInfo = TradingInfo()
        dataModel.persistPortfolioAfterUserEdit(allowEmptyPortfolio: true)
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
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
        HoldingsCurrencyFormatter.amount(currentPrice, currency: realTimeTrade.realTimeInfo.currency ?? "")
    }

    private var valueText: String {
        let value = dataModel.calculatePositionValue(for: realTimeTrade)
        return HoldingsCurrencyFormatter.amount(value.amount, currency: value.currency)
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
                .monospacedDigit()
                .foregroundStyle(foregroundStyle)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(kind == .day ? "Today's profit and loss" : "Total profit and loss")
        .accessibilityValue("\(text), \(AttributionFormat.direction(amount))")
        .accessibilityHint(helpText)
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
            guard amount.isFinite else { return "—" }
            return HoldingsCurrencyFormatter.signedAmount(amount, currency: summary.currency)
        case .percent:
            guard percent.isFinite else { return "—" }
            return String(format: "%+.2f%%", percent)
        }
    }

    private var foregroundStyle: Color {
        // Coloured by what is shown, so "£0.00" is never red or green.
        StockbarPalette.signed(HoldingsCurrencyFormatter.displayedSign(of: amount, currency: summary.currency))
    }

    private var helpText: String {
        switch displayMode {
        case .amount: "Show percentage"
        case .percent: "Show amount"
        }
    }
}

@MainActor
private struct StockbarBackupsView: View {
    let dataModel: DataModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingRestoreSheet = false
    @State private var status: BackupStatusMessage?
    @State private var isBackingUp = false
    @State private var backupCount = 0
    @State private var lastBackupDate: Date?
    @State private var retentionDays = BackupService.shared.retentionDays

    private struct BackupStatusMessage: Equatable {
        let text: String
        let succeeded: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader(
                "Backups",
                subtitle: "Stockbar backs up your holdings once a day while it runs. Backups don't include Keychain credentials."
            )

            HStack(spacing: 14) {
                StockbarMetricTile(
                    title: "Last Backup",
                    value: lastBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet",
                    systemImage: "clock.arrow.circlepath"
                )
                StockbarMetricTile(title: "Saved Backups", value: "\(backupCount)", systemImage: "archivebox")
                StockbarMetricTile(title: "Kept For", value: "\(retentionDays) days", systemImage: "calendar")
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                StockbarSectionTitle(title: "Manage")
                HStack(spacing: 12) {
                    Button(action: backUpNow) {
                        HStack(spacing: 6) {
                            if isBackingUp {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "externaldrive.badge.plus")
                            }
                            Text("Back Up Now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBackingUp)
                    Button {
                        showingRestoreSheet = true
                    } label: {
                        Label("Restore from Backup…", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(backupCount == 0)
                    .help(backupCount == 0 ? "No backups available yet" : "Choose a backup to restore")
                    Button {
                        BackupService.shared.openBackupDirectory()
                    } label: {
                        Label("View Backups", systemImage: "folder")
                    }
                }
                .controlSize(.large)

                Picker("Keep Backups For", selection: $retentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .fixedSize()
                .onChange(of: retentionDays) { _, newValue in
                    BackupService.shared.retentionDays = newValue
                }

                if let status {
                    Label(status.text, systemImage: status.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(status.succeeded ? .green : .red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .stockbarCard()
            .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion), value: status)
        }
        .stockbarPage()
        .onAppear(perform: reloadBackupState)
        .sheet(isPresented: $showingRestoreSheet, onDismiss: reloadBackupState) {
            RestoreBackupView(isPresented: $showingRestoreSheet, dataModel: dataModel)
        }
    }

    private func reloadBackupState() {
        backupCount = BackupService.shared.listAvailableBackups().count
        lastBackupDate = BackupService.shared.lastBackupDate
        retentionDays = BackupService.shared.retentionDays
    }

    private func backUpNow() {
        isBackingUp = true
        Task {
            let outcome = await BackupService.shared.performManualBackupReportingOutcome(trades: dataModel.localPortfolioTradesForBackup)
            isBackingUp = false
            status = BackupStatusMessage(text: outcome.userMessage, succeeded: outcome != .failed)
            reloadBackupState()
        }
    }
}

@MainActor
private struct StockbarDataHealthView: View {
    let dataModel: DataModel
    private let currencyConverter: CurrencyConverter

    init(dataModel: DataModel) {
        self.dataModel = dataModel
        self.currencyConverter = dataModel.currencyConverter
    }

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]

    private var trackedTrades: [RealTimeTrade] {
        dataModel.realTimeTrades.filter { !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader("Data Health", subtitle: "Where Stockbar's numbers come from and how fresh they are.")

            TimelineView(.periodic(from: .now, by: 30)) { context in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    StockbarMetricTile(
                        title: "Prices",
                        value: pricesValue(now: context.date),
                        detail: pricesDetail(now: context.date),
                        systemImage: "clock",
                        valueColor: pricesAreStale(now: context.date) || dataModel.quoteRefreshStatus.lastAttemptFailed
                            ? .orange : .primary
                    )
                    StockbarMetricTile(
                        title: "Exchange Rates",
                        value: exchangeRateStatus.title,
                        detail: "Last obtained \(currencyConverter.getTimeSinceRefresh())",
                        systemImage: "dollarsign.arrow.circlepath",
                        valueColor: exchangeRateStatus.color
                    )
                    StockbarMetricTile(
                        title: "Portfolio Source",
                        value: sourceTitle,
                        detail: sourceDetail,
                        systemImage: dataModel.isFolyncPortfolioActive ? "link" : "internaldrive"
                    )
                    StockbarMetricTile(
                        title: "Tracked Symbols",
                        value: "\(trackedTrades.count)",
                        detail: "\(trackedTrades.filter(\.trade.isWatchlistOnly).count) watchlist only",
                        systemImage: "list.bullet"
                    )
                    StockbarMetricTile(
                        title: "Menu Bar",
                        value: dataModel.hideAllMenuBarItems ? "Hidden" : "\(trackedTrades.filter(\.trade.showInMenuBar).count) visible",
                        detail: dataModel.requireExternalDisplayForMenuBarStocks ? "Only with an external display" : "Shown on every display",
                        systemImage: "menubar.rectangle"
                    )
                    StockbarMetricTile(
                        title: "Preferred Currency",
                        value: dataModel.preferredCurrency,
                        detail: "Totals are converted to this currency",
                        systemImage: "coloncurrencysign.circle"
                    )
                }
            }
        }
        .stockbarPage()
    }

    /// Held positions drive the freshness figure (watchlist-only rows only when nothing is held).
    private var pricedTrades: [RealTimeTrade] {
        let held = trackedTrades.filter { !$0.trade.isWatchlistOnly }
        return held.isEmpty ? trackedTrades : held
    }

    /// The oldest price update among positions, not the newest: one fresh quote must not hide
    /// a stale or missing one.
    private var priceFreshness: (date: Date?, missingCount: Int) {
        StockbarRelativeTime.oldest(pricedTrades.map { $0.realTimeInfo.lastUpdateTime })
    }

    private var lastPriceUpdate: Date? { priceFreshness.date }

    private var exchangeRateStatus: (title: String, color: Color) {
        if currencyConverter.isUsingFallbackRates { return ("Approximate", .orange) }
        if currencyConverter.lastRefreshTime == .distantPast { return ("Not updated yet", .secondary) }
        guard currencyConverter.lastRefreshSuccess else { return ("Update failed", .orange) }
        return currencyConverter.ratesAreStale() ? ("Stale", .orange) : ("Live", .green)
    }

    private func pricesValue(now: Date) -> String {
        let freshness = priceFreshness
        if pricedTrades.isEmpty { return "No positions" }
        if freshness.missingCount > 0 {
            return "\(freshness.missingCount) not updated yet"
        }
        guard let lastPriceUpdate else { return "Not updated yet" }
        return StockbarRelativeTime.updatedText(lastPriceUpdate, now: now)
            .replacingOccurrences(of: "Updated ", with: "")
            .capitalizedFirstLetter
    }

    private func pricesDetail(now: Date) -> String {
        guard !pricedTrades.isEmpty else { return "Add a holding to start tracking prices" }
        let base = "Oldest of \(pricedTrades.count) · refreshes every \(refreshIntervalText)"
        let status = dataModel.quoteRefreshStatus
        if let problem = status.problemSummary, let tried = status.lastAttempt {
            let tried = StockbarRelativeTime.updatedText(tried, now: now)
                .replacingOccurrences(of: "Updated ", with: "")
            return "\(problem) (tried \(tried)) · \(base)"
        }
        return pricesAreStale(now: now) && !pricedTrades.isEmpty ? "Stale · \(base)" : base
    }

    /// Stale once more than two refresh intervals have passed without new prices for any position.
    private func pricesAreStale(now: Date) -> Bool {
        // Nothing to price is not a problem: an empty portfolio is not "stale".
        guard !pricedTrades.isEmpty else { return false }
        let freshness = priceFreshness
        guard freshness.missingCount == 0, let lastPriceUpdate else { return true }
        // Shut exchanges are polled slowly, so their quotes are allowed to be older.
        let anyExchangeClosed = pricedTrades.contains {
            RefreshService.isExchangeClosed(for: $0.trade.name, at: now) == true
        }
        let closedAllowance = anyExchangeClosed ? RefreshService.closedMarketFreshness * 2 : 0
        return now.timeIntervalSince(lastPriceUpdate) > max(dataModel.refreshInterval * 2, 600, closedAllowance)
    }

    private var refreshIntervalText: String {
        let minutes = Int(dataModel.refreshInterval / 60)
        return minutes >= 60 ? "\(minutes / 60) hr" : "\(max(minutes, 1)) min"
    }

    private var sourceDetail: String {
        if dataModel.isFolyncPortfolioActive { return dataModel.folyncConnectionState.message }
        switch dataModel.displayValuationSource {
        case .folyncProvided: return dataModel.folyncConnectionState.message
        case .brokerProvided: return "Holdings and values synced from Trading 212"
        case .localCalculationFallback, .marketDataFallback: return "Holdings entered in Stockbar"
        }
    }

    private var sourceTitle: String {
        switch dataModel.displayValuationSource {
        case .folyncProvided: "Folync"
        case .brokerProvided: "Trading 212"
        case .localCalculationFallback, .marketDataFallback: "Local"
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}

@MainActor
private struct StockbarDiagnosticsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader("Diagnostics", subtitle: "Recent Stockbar logs. Credentials and API keys are redacted.")
            DebugLogView()
                .stockbarCard(padding: 6)
        }
        .padding(StockbarLayout.pageInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One editable holdings row: the holding and where it sits in the full list.
private struct HoldingsRowEntry: Identifiable {
    let index: Int
    let trade: RealTimeTrade
    var id: UUID { trade.id }
}

private extension View {
    /// Marks a holdings field whose contents cannot be used. Red text alone is
    /// invisible to anyone who cannot tell red from black and to VoiceOver, so
    /// the field also gets a warning symbol and reads the problem aloud.
    func holdingsFieldProblem(_ problem: String?, help: String) -> some View {
        self
            .foregroundStyle(problem == nil ? Color.primary : Color.red)
            .overlay(alignment: .trailing) {
                if problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.trailing, 6)
                        .accessibilityHidden(true)
                }
            }
            .help(problem ?? help)
            .accessibilityHint(problem ?? "")
    }
}
