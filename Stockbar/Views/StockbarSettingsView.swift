import SwiftUI

@MainActor
struct StockbarSettingsView: View {
    @ObservedObject var dataModel: DataModel

    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @State private var selectedTab: SettingsTab = .general
    @State private var refreshInterval: TimeInterval
    @State private var snapshotInterval: TimeInterval
    @State private var showingRestoreSheet = false
    @State private var showingBackupAlert = false
    @State private var backupAlertMessage = ""

    init(dataModel: DataModel) {
        self.dataModel = dataModel
        _refreshInterval = State(initialValue: dataModel.refreshInterval)
        _snapshotInterval = State(initialValue: HistoricalDataManager.shared.getSnapshotInterval())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Divider()
            content
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 680, idealHeight: 820)
        .preferredColorScheme(preferredColorScheme)
        .sheet(isPresented: $showingRestoreSheet) {
            RestoreBackupView(isPresented: $showingRestoreSheet, dataModel: dataModel)
        }
        .alert("Backup", isPresented: $showingBackupAlert) {
            Button("OK") { }
        } message: {
            Text(backupAlertMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Stockbar Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button {
                NotificationCenter.default.post(name: .openStockbarWindowRequested, object: nil)
            } label: {
                Label("Open Stockbar", systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var tabStrip: some View {
        Picker("Settings Tab", selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 110)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .general:
            settingsScroll { generalPane }
        case .menuBar:
            settingsScroll { menuBarPane }
        case .appearance:
            settingsScroll { appearancePane }
        case .dataSources:
            DataSourcesSettingsView(dataModel: dataModel)
        case .refresh:
            settingsScroll { refreshPane }
                .onAppear(perform: syncRefreshState)
        case .advanced:
            settingsScroll { advancedPane }
        }
    }

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Portfolio Defaults") {
                Toggle("Color Coding", isOn: $dataModel.showColorCoding)
                Toggle("Market Indicators", isOn: $dataModel.showMarketIndicators)
                    .help("Show pre-market, after-hours, and closed market indicators.")
                SettingsPickerRow("Preferred Currency") {
                    Picker("", selection: $dataModel.preferredCurrency) {
                        ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                            Text(currency).tag(currency)
                        }
                    }
                    .frame(width: 120)
                }
            }

            SettingsSection("Portfolio Summary") {
                HStack(spacing: 16) {
                    SummaryMetricCard(
                        title: "Net Value",
                        value: formatted(dataModel.calculateNetValue()),
                        tint: .blue
                    )
                    let gains = dataModel.calculateNetGains()
                    SummaryMetricCard(
                        title: "Total Net Gains",
                        value: formatted(gains),
                        tint: gains.amount >= 0 ? .green : .red
                    )
                    SummaryMetricCard(
                        title: "Tracked Symbols",
                        value: "\(trackedSymbolCount)",
                        tint: .purple
                    )
                }
            }

            exchangeRatesSection
        }
    }

    private var menuBarPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Menu Bar Display") {
                SettingsPickerRow("Display Mode") {
                    Picker("", selection: $dataModel.menuBarDisplaySettings.displayMode) {
                        ForEach(MenuBarDisplaySettings.DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .frame(width: 240)
                }

                SettingsPickerRow("Change Format") {
                    Picker("", selection: $dataModel.menuBarDisplaySettings.changeFormat) {
                        ForEach(MenuBarDisplaySettings.ChangeFormat.allCases, id: \.self) { format in
                            Text(format.description).tag(format)
                        }
                    }
                    .frame(width: 240)
                }

                if dataModel.menuBarDisplaySettings.displayMode == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsPickerRow("Custom Template") {
                            TextField(
                                "e.g. {symbol}: {changePct}",
                                text: Binding(
                                    get: { dataModel.menuBarDisplaySettings.customTemplate ?? "" },
                                    set: { dataModel.menuBarDisplaySettings.customTemplate = $0.isEmpty ? nil : $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        templateValidation
                            .padding(.leading, 150)
                    }
                }

                SettingsPickerRow("Arrow Indicators") {
                    Picker("", selection: $dataModel.menuBarDisplaySettings.arrowStyle) {
                        ForEach(MenuBarDisplaySettings.ArrowStyle.allCases, id: \.self) { style in
                            Text(style.description).tag(style)
                        }
                    }
                    .frame(width: 240)
                }

                if dataModel.menuBarDisplaySettings.arrowStyle != .none {
                    Toggle("Show arrow before symbol", isOn: $dataModel.menuBarDisplaySettings.showArrowBeforeSymbol)
                }

                SettingsPickerRow("Decimal Places") {
                    Stepper(value: $dataModel.menuBarDisplaySettings.decimalPlaces, in: 0...4) {
                        Text("\(dataModel.menuBarDisplaySettings.decimalPlaces)")
                            .frame(width: 28)
                    }
                }

                Toggle("Show currency symbols", isOn: $dataModel.menuBarDisplaySettings.showCurrency)

                PreviewPill(title: "Preview", value: dataModel.menuBarDisplaySettings.samplePreview())
            }

            SettingsSection("Menu Bar Visibility") {
                Toggle(
                    "Show stocks in menu bar",
                    isOn: Binding(
                        get: { !dataModel.hideAllMenuBarItems },
                        set: { newValue in
                            dataModel.hideAllMenuBarItems = !newValue
                            NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                        }
                    )
                )
                if dataModel.hideAllMenuBarItems {
                    Text("All menu bar items are hidden. Use the Dock icon or Open Stockbar button to access Stockbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection("Portfolio Menu Bar") {
                Toggle("Show portfolio total in menu bar", isOn: $dataModel.portfolioMenuBarDisplaySettings.isEnabled)
                SettingsPickerRow("Currency") {
                    Picker("", selection: $dataModel.portfolioMenuBarDisplaySettings.currencyCode) {
                        ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                            Text(currency).tag(currency)
                        }
                    }
                    .frame(width: 120)
                }
                SettingsPickerRow("Day Gain") {
                    Picker("", selection: $dataModel.portfolioMenuBarDisplaySettings.dayGainFormat) {
                        ForEach(PortfolioMenuBarDisplaySettings.DayGainFormat.allCases, id: \.self) { format in
                            Text(format.description).tag(format)
                        }
                    }
                    .frame(width: 190)
                }
                SettingsPickerRow("Decimal Places") {
                    Stepper(value: $dataModel.portfolioMenuBarDisplaySettings.decimalPlaces, in: 0...4) {
                        Text("\(dataModel.portfolioMenuBarDisplaySettings.decimalPlaces)")
                            .frame(width: 28)
                    }
                }
                PreviewPill(title: "Preview", value: dataModel.portfolioMenuBarDisplaySettings.samplePreview())
            }
        }
    }

    private var appearancePane: some View {
        SettingsSection("Appearance") {
            SettingsPickerRow("Theme") {
                Picker("", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .frame(width: 160)
            }
            Text("Theme changes apply to Stockbar windows and settings surfaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var refreshPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Refresh") {
                SettingsPickerRow("Main Refresh Interval") {
                    Picker("", selection: $refreshInterval) {
                        ForEach(refreshIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .frame(width: 170)
                    .onChange(of: refreshInterval) { _, newValue in
                        dataModel.refreshInterval = newValue
                        dataModel.saveTradingInfo()
                        NotificationCenter.default.post(name: .refreshIntervalChanged, object: newValue)
                    }
                }

                SettingsPickerRow("Chart Data Collection") {
                    Picker("", selection: $snapshotInterval) {
                        ForEach(snapshotIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .frame(width: 170)
                    .onChange(of: snapshotInterval) { _, newValue in
                        HistoricalDataManager.shared.setSnapshotInterval(newValue)
                    }
                }

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
    }

    private var advancedPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Backups") {
                backupStatus
                HStack(spacing: 12) {
                    Button {
                        performManualBackup()
                    } label: {
                        Label("Backup Now", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        showingRestoreSheet = true
                    } label: {
                        Label("Restore from Backup", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(BackupService.shared.listAvailableBackups().isEmpty)
                    Button {
                        BackupService.shared.openBackupDirectory()
                    } label: {
                        Label("View Backups", systemImage: "folder")
                    }
                }
                SettingsPickerRow("Keep backups for") {
                    Picker("", selection: Binding(
                        get: { BackupService.shared.retentionDays },
                        set: { BackupService.shared.retentionDays = $0 }
                    )) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 130)
                }
            }

            SettingsSection("Diagnostics") {
                DebugLogView()
                    .frame(minHeight: 260, maxHeight: 420)
            }
        }
    }

    private var exchangeRatesSection: some View {
        SettingsSection("Exchange Rates") {
            HStack {
                Text("Last updated:")
                    .foregroundStyle(.secondary)
                Text(dataModel.currencyConverter.getTimeSinceRefresh())
                    .foregroundColor(dataModel.currencyConverter.lastRefreshSuccess ? .secondary : .orange)
                Spacer()
                Button {
                    dataModel.currencyConverter.refreshRates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh exchange rates")
            }

            if !dataModel.currencyConverter.exchangeRates.isEmpty {
                HStack(spacing: 16) {
                    ForEach(["GBP", "EUR", "JPY"], id: \.self) { currency in
                        if let rate = dataModel.currencyConverter.exchangeRates[currency] {
                            PreviewPill(title: currency, value: String(format: "%.4f", rate))
                        }
                    }
                }
            }
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
        }
    }

    private var backupStatus: some View {
        HStack {
            if let lastBackup = BackupService.shared.lastBackupDate {
                Label("Last backup: \(formattedBackupDate(lastBackup))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No backup performed yet", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var trackedSymbolCount: Int {
        dataModel.realTimeTrades.filter { !$0.trade.name.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0.trade.name) }.count
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

    private func formatted(_ amount: (amount: Double, currency: String)) -> String {
        "\(String(format: "%.2f", amount.amount)) \(amount.currency)"
    }

    private func formattedBackupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func performManualBackup() {
        Task {
            let success = await BackupService.shared.performManualBackup(trades: dataModel.realTimeTrades)
            await MainActor.run {
                backupAlertMessage = success ? "Backup completed successfully" : "Backup failed. Check logs for details."
                showingBackupAlert = true
            }
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
        case .dataSources: "Data Sources"
        case .refresh: "Refresh"
        case .advanced: "Advanced"
        }
    }
}

@MainActor
private struct SettingsSection<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private struct SettingsPickerRow<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 150, alignment: .leading)
            content
            Spacer()
        }
    }
}

@MainActor
private struct SummaryMetricCard: View {
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
private struct PreviewPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
