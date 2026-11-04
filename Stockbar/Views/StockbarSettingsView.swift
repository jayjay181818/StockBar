import SwiftUI

@MainActor
struct StockbarSettingsView: View {
    @ObservedObject var dataModel: DataModel
    private let onOpenSection: (StockbarMainSection) -> Void

    @AppStorage("appearanceMode", store: StockbarRuntimeStorage.userDefaults) private var appearanceMode: String = "system"
    @AppStorage("settings.selectedTab", store: StockbarRuntimeStorage.userDefaults) private var selectedTab: SettingsTab = .general
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshInterval: TimeInterval
    @State private var snapshotInterval: TimeInterval
    @State private var showingRestoreSheet = false
    @State private var showingBackupAlert = false
    @State private var backupAlertMessage = ""
    @State private var retentionDays = BackupService.shared.retentionDays

    init(dataModel: DataModel, onOpenSection: @escaping (StockbarMainSection) -> Void = { _ in }) {
        self.dataModel = dataModel
        self.onOpenSection = onOpenSection
        _refreshInterval = State(initialValue: dataModel.refreshInterval)
        _snapshotInterval = State(initialValue: HistoricalDataManager.shared.getSnapshotInterval())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                StockbarPageHeader("Settings", subtitle: selectedTab.subtitle)
                Picker("Settings section", selection: Binding(
                    get: { selectedTab },
                    set: { tab in
                        withAnimation(StockbarMotion.animation(StockbarMotion.quick, reduceMotion: reduceMotion)) {
                            selectedTab = tab
                        }
                    }
                )) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, StockbarLayout.pagePadding)
            .padding(.top, StockbarLayout.pageInsets.top)
            .padding(.bottom, 8)

            ZStack {
                content
                    .id(selectedTab)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingRestoreSheet) {
            RestoreBackupView(isPresented: $showingRestoreSheet, dataModel: dataModel)
        }
        .alert("Backup", isPresented: $showingBackupAlert) {
            Button("OK") { }
        } message: {
            Text(backupAlertMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            settingsForm { generalPane }
        case .menuBar:
            settingsForm { menuBarPane }
        case .appearance:
            settingsForm { appearancePane }
        case .dataSources:
            DataSourcesSettingsView(dataModel: dataModel)
        case .refresh:
            settingsForm { refreshPane }
                .onAppear(perform: syncRefreshState)
        case .advanced:
            settingsForm { advancedPane }
        }
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, StockbarLayout.pagePadding - 20)
        .frame(maxWidth: 820, alignment: .topLeading)
    }

    @ViewBuilder
    private var generalPane: some View {
        Section("Portfolio") {
            Picker("Preferred Currency", selection: $dataModel.preferredCurrency) {
                ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                    Text(currency).tag(currency)
                }
            }
            Toggle(isOn: $dataModel.showColorCoding) {
                Text("Color Coding")
                Text("Green for gains and red for losses in the menu bar. Unchanged values stay neutral.")
            }
            Toggle(isOn: $dataModel.showMarketIndicators) {
                Text("Market Indicators")
                Text("Show pre-market, after-hours and closed-market indicators.")
            }
        }

        exchangeRatesSection
    }

    @ViewBuilder
    private var menuBarPane: some View {
        Section {
            LabeledContent("Preview") {
                MenuBarPreview(text: dataModel.menuBarDisplaySettings.samplePreview())
            }
            Picker("Display Mode", selection: $dataModel.menuBarDisplaySettings.displayMode) {
                ForEach(MenuBarDisplaySettings.DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }

            if dataModel.menuBarDisplaySettings.displayMode.usesConfigurableChangeFormat {
                Picker("Change Format", selection: $dataModel.menuBarDisplaySettings.changeFormat) {
                    ForEach(MenuBarDisplaySettings.ChangeFormat.allCases, id: \.self) { format in
                        Text(format.description).tag(format)
                    }
                }
            }

            if dataModel.menuBarDisplaySettings.displayMode == .custom {
                TextField(
                    "Custom Template",
                    text: Binding(
                        get: { dataModel.menuBarDisplaySettings.customTemplate ?? "" },
                        set: { dataModel.menuBarDisplaySettings.customTemplate = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text("{symbol} {price} {arrow}{changePct}")
                )
                templateValidation
            }

            Picker("Arrow Indicators", selection: $dataModel.menuBarDisplaySettings.arrowStyle) {
                ForEach(MenuBarDisplaySettings.ArrowStyle.allCases, id: \.self) { style in
                    Text(style.description).tag(style)
                }
            }

            if dataModel.menuBarDisplaySettings.arrowStyle != .none {
                Toggle("Show arrow before symbol", isOn: $dataModel.menuBarDisplaySettings.showArrowBeforeSymbol)
            }

            Picker("Decimal Places", selection: $dataModel.menuBarDisplaySettings.decimalPlaces) {
                ForEach(0...4, id: \.self) { Text("\($0)").tag($0) }
            }

            Toggle("Show currency symbols", isOn: $dataModel.menuBarDisplaySettings.showCurrency)
        } header: {
            Text("Stock Items")
        } footer: {
            Text("Each visible holding gets its own menu bar item. Choose which holdings appear from the Menu Bar column in Holdings.")
        }

        Section("Menu Bar Visibility") {
            Toggle(
                "Show stocks in the menu bar",
                isOn: Binding(
                    get: { !dataModel.hideAllMenuBarItems },
                    set: { newValue in
                        dataModel.hideAllMenuBarItems = !newValue
                        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                    }
                )
            )
            Toggle(isOn: $dataModel.requireExternalDisplayForMenuBarStocks) {
                Text("Only with an external display")
                Text(menuBarVisibilityStatusText)
                    .foregroundStyle(!dataModel.hideAllMenuBarItems
                                     && dataModel.requireExternalDisplayForMenuBarStocks
                                     && !dataModel.isExternalDisplayConnected ? .orange : .secondary)
            }
            .disabled(dataModel.hideAllMenuBarItems)
        }

        Section("Portfolio Menu Bar") {
            LabeledContent("Preview") {
                MenuBarPreview(text: dataModel.portfolioMenuBarDisplaySettings.samplePreview())
            }
            Toggle("Show portfolio total in the menu bar", isOn: $dataModel.portfolioMenuBarDisplaySettings.isEnabled)
            Picker("Currency", selection: $dataModel.portfolioMenuBarDisplaySettings.currencyCode) {
                ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                    Text(currency).tag(currency)
                }
            }
            Picker("Day Gain", selection: $dataModel.portfolioMenuBarDisplaySettings.dayGainFormat) {
                ForEach(PortfolioMenuBarDisplaySettings.DayGainFormat.allCases, id: \.self) { format in
                    Text(format.description).tag(format)
                }
            }
            Picker("Decimal Places", selection: $dataModel.portfolioMenuBarDisplaySettings.decimalPlaces) {
                ForEach(0...4, id: \.self) { Text("\($0)").tag($0) }
            }
        }

        Section {
            Toggle("Compare with a benchmark", isOn: $benchmarkEnabled)
        } header: {
            Text("Stock Popover")
        } footer: {
            Text("Draws the S&P 500 (US listings) or FTSE 100 (London listings) behind a stock's price chart.")
        }
    }

    @AppStorage("menu.benchmarkComparisonEnabled", store: StockbarRuntimeStorage.userDefaults) private var benchmarkEnabled: Bool = true

    @ViewBuilder
    private var appearancePane: some View {
        Section {
            Picker("Theme", selection: $appearanceMode) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Applies to the Stockbar window and menu bar popovers.")
        }
    }

    @ViewBuilder
    private var refreshPane: some View {
        Section {
            Picker("Main Refresh Interval", selection: $refreshInterval) {
                ForEach(refreshIntervalOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .onChange(of: refreshInterval) { _, newValue in
                dataModel.refreshInterval = newValue
                dataModel.saveTradingInfo()
                NotificationCenter.default.post(name: .refreshIntervalChanged, object: newValue)
            }

            Picker("Chart Data Collection", selection: $snapshotInterval) {
                ForEach(snapshotIntervalOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .onChange(of: snapshotInterval) { _, newValue in
                HistoricalDataManager.shared.setSnapshotInterval(newValue)
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("A price fetched within about 90% of the refresh interval is reused. Symbols that keep failing are retried after 1, 2, 5 and 10 minutes, then paused for an hour.")
        }

        Section("Now") {
            HStack(spacing: 12) {
                Button {
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                Button {
                    dataModel.historicalDataManager.forceSnapshot(from: dataModel)
                } label: {
                    Label("Save Chart Snapshot", systemImage: "chart.xyaxis.line")
                }
            }
        }
    }

    @ViewBuilder
    private var advancedPane: some View {
        Section {
            LabeledContent("Last Backup") {
                if let lastBackup = BackupService.shared.lastBackupDate {
                    Label(lastBackup.formatted(date: .abbreviated, time: .shortened), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("None yet").foregroundStyle(.secondary)
                }
            }
            Picker("Keep Backups For", selection: $retentionDays) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .onChange(of: retentionDays) { _, newValue in
                BackupService.shared.retentionDays = newValue
            }
            HStack(spacing: 12) {
                Button {
                    performManualBackup()
                } label: {
                    Label("Back Up Now", systemImage: "externaldrive.badge.plus")
                }
                Button {
                    showingRestoreSheet = true
                } label: {
                    Label("Restore from Backup…", systemImage: "arrow.counterclockwise")
                }
                .disabled(BackupService.shared.listAvailableBackups().isEmpty)
                Button {
                    BackupService.shared.openBackupDirectory()
                } label: {
                    Label("View Backups", systemImage: "folder")
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            Text("Stockbar backs up your holdings once a day. Keychain credentials are not included.")
        }

        Section("Diagnostics") {
            LabeledContent {
                Button("Open Diagnostics") { onOpenSection(.diagnostics) }
            } label: {
                Text("Logs")
                Text("View, refresh and clear Stockbar's log. Credentials are redacted.")
            }
            LabeledContent {
                Button("Open Data Health") { onOpenSection(.dataHealth) }
            } label: {
                Text("Data health")
                Text("Price, exchange-rate and portfolio-source freshness.")
            }
        }
    }

    @ViewBuilder
    private var exchangeRatesSection: some View {
        Section {
            LabeledContent("Last Updated") {
                HStack(spacing: 8) {
                    Text(dataModel.currencyConverter.getTimeSinceRefresh())
                        .foregroundStyle(dataModel.currencyConverter.lastRefreshSuccess ? Color.secondary : Color.orange)
                    Button {
                        dataModel.currencyConverter.refreshRates()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh exchange rates")
                    .accessibilityLabel("Refresh exchange rates")
                }
            }
            ForEach(["GBP", "EUR", "JPY"], id: \.self) { currency in
                if let rate = dataModel.currencyConverter.exchangeRates[currency] {
                    LabeledContent("1 USD in \(currency)") {
                        Text(String(format: "%.4f", rate)).monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Exchange Rates")
        } footer: {
            Text("Rates refresh at most every five minutes. A failed update keeps the previous time.")
        }
    }

    @ViewBuilder
    private var templateValidation: some View {
        if let template = dataModel.menuBarDisplaySettings.customTemplate {
            let validation = MenuBarDisplaySettings.validateTemplate(template)
            Label(
                validation.isValid ? "Template is valid" : (validation.errorMessage ?? "Invalid template"),
                systemImage: validation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(validation.isValid ? .green : .orange)
        } else {
            Text("Tokens: {symbol} {price} {change} {changePct} {dayPL} {currency} {arrow}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var menuBarVisibilityStatusText: String {
        if dataModel.hideAllMenuBarItems {
            return "All stock items are hidden. Use the Dock icon or the portfolio item to open Stockbar."
        }
        guard dataModel.requireExternalDisplayForMenuBarStocks else {
            return "Hide stock items while only the built-in display is in use."
        }
        return dataModel.isExternalDisplayConnected
            ? "External display detected — stock items are shown."
            : "No external display — stock items are hidden until one is connected."
    }

    private let refreshIntervalOptions: [(String, TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1_800),
        ("1 hour", 3_600)
    ]

    private let snapshotIntervalOptions: [(String, TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1_800)
    ]

    private func syncRefreshState() {
        refreshInterval = dataModel.refreshInterval
        snapshotInterval = HistoricalDataManager.shared.getSnapshotInterval()
    }

    private func performManualBackup() {
        Task {
            let success = await BackupService.shared.performManualBackup(trades: dataModel.localPortfolioTradesForBackup)
            backupAlertMessage = success ? "Backup completed." : "Backup failed. See Diagnostics for details."
            showingBackupAlert = true
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case appearance
    case dataSources
    case refresh
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .appearance: "Appearance"
        case .dataSources: "Connections"
        case .refresh: "Refresh"
        case .advanced: "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Currency, colours and exchange rates."
        case .menuBar: "What appears in the menu bar and how it's formatted."
        case .appearance: "Light, dark or match the system."
        case .dataSources: "Brokers, Folync and market-data providers."
        case .refresh: "How often prices and chart history update."
        case .advanced: "Backups and troubleshooting."
        }
    }
}

/// Menu bar text rendered the way it appears in the menu bar.
private struct MenuBarPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(StockbarPalette.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Menu bar preview: \(text)")
    }
}
