//
//  PreferenceView.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let chartMetricsToggled = Notification.Name("chartMetricsToggled")
    static let refreshIntervalChanged = Notification.Name("refreshIntervalChanged")
    static let realTimeTradesUIUpdateNeeded = Notification.Name("realTimeTradesUIUpdateNeeded")
}

// MARK: - Portfolio Export/Import Data Structure
struct PortfolioExportData: Codable {
    let symbol: String
    let units: Double
    let avgPositionCost: Double
    let costCurrency: String?
    
    init(from trade: Trade) {
        self.symbol = trade.name
        self.units = trade.position.unitSize
        self.avgPositionCost = trade.position.positionAvgCost
        self.costCurrency = trade.position.costCurrency
    }
    
    func toTrade() -> Trade {
        let position = Position(unitSize: String(units), 
                               positionAvgCost: String(avgPositionCost),
                               currency: costCurrency,
                               costCurrency: costCurrency)
        return Trade(name: symbol, position: position)
    }
}

// MARK: - CSV Document for Export/Import
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    
    var text: String
    
    init(text: String = "") {
        self.text = text
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8)!
        return .init(regularFileWithContents: data)
    }
}

// MARK: - Portfolio Export/Import Manager
class PortfolioManager {
    static func exportToCSV(trades: [RealTimeTrade]) -> String {
        var csvString = "Symbol,Units,AvgPositionCost,CostCurrency\n"
        
        for trade in trades {
            let symbol = trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let units = trade.trade.position.unitSize
            let avgCost = trade.trade.position.positionAvgCost
            let currency = trade.trade.position.costCurrency ?? (symbol.uppercased().hasSuffix(".L") ? "GBX" : "USD")
            
            // Skip empty trades
            if !symbol.isEmpty && units > 0 {
                csvString += "\(symbol),\(units),\(avgCost),\(currency)\n"
            }
        }
        
        return csvString
    }
    
    static func importFromCSV(_ csvString: String) -> (trades: [Trade], errors: [String]) {
        var trades: [Trade] = []
        var errors: [String] = []
        
        let lines = csvString.components(separatedBy: .newlines)
        
        // Skip header line
        for (index, line) in lines.enumerated() {
            if index == 0 || line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            
            let components = line.components(separatedBy: ",")
            if components.count >= 3 {
                let symbol = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let unitsString = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let avgCostString = components[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let currency = components.count > 3 ? components[3].trimmingCharacters(in: .whitespacesAndNewlines) : nil
                
                // Validate data
                guard !symbol.isEmpty else {
                    errors.append("Line \(index + 1): Empty symbol")
                    continue
                }
                
                guard let units = Double(unitsString), units > 0 else {
                    errors.append("Line \(index + 1): Invalid units value '\(unitsString)'")
                    continue
                }
                
                guard let avgCost = Double(avgCostString), avgCost > 0 else {
                    errors.append("Line \(index + 1): Invalid average cost value '\(avgCostString)'")
                    continue
                }
                
                // Create trade
                let position = Position(unitSize: String(units),
                                       positionAvgCost: String(avgCost),
                                       currency: currency,
                                       costCurrency: currency)
                let trade = Trade(name: symbol, position: position)
                
                trades.append(trade)
            } else {
                errors.append("Line \(index + 1): Invalid format - expected at least 3 columns")
            }
        }
        
        return (trades, errors)
    }
}

struct PreferenceRow: View {
    @ObservedObject var realTimeTrade: RealTimeTrade
    // Add DataModel dependency to trigger saves
    @ObservedObject var dataModel: DataModel
    @State private var showCurrencyPicker = false
    @State private var validationError: String? = nil

    private let validator = DataValidationService.shared

    private var detectedCurrency: String {
        if let costCurrency = realTimeTrade.trade.position.costCurrency {
            return costCurrency
        }
        // Auto-detect based on symbol
        return realTimeTrade.trade.name.uppercased().hasSuffix(".L") ? "GBX" : "USD"
    }

    private var availableCurrencies: [String] {
        if realTimeTrade.trade.name.uppercased().hasSuffix(".L") {
            return ["GBX", "GBP"]
        } else {
            return ["USD", "GBP", "EUR"]
        }
    }

    // Validation state
    private var symbolIsValid: Bool {
        validator.validateSymbol(realTimeTrade.trade.name).isValid
    }

    private var unitsIsValid: Bool {
        if let units = Double(realTimeTrade.trade.position.unitSizeString) {
            return validator.validateUnits(units).isValid
        }
        return false
    }

    private var costIsValid: Bool {
        if let cost = Double(realTimeTrade.trade.position.positionAvgCostString) {
            return validator.validateCost(cost).isValid
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Symbol field - flexible width with validation indicator
                HStack(spacing: 2) {
                    TextField("symbol", text: self.$realTimeTrade.trade.name)
                        .frame(minWidth: 60, idealWidth: 80, maxWidth: 120)
                        .onChange(of: realTimeTrade.trade.name) { _ in
                            validateInput()
                            // Trigger save on change
                            dataModel.triggerTradeUpdate()
                        }
                    if !symbolIsValid && !realTimeTrade.trade.name.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                            .help("Invalid symbol format")
                    }
                }

                // Units field - moderate width with validation
                HStack(spacing: 2) {
                    TextField("Units", text: self.$realTimeTrade.trade.position.unitSizeString)
                        .frame(minWidth: 50, idealWidth: 70, maxWidth: 100)
                        .onChange(of: realTimeTrade.trade.position.unitSizeString) { _ in
                            validateInput()
                            // Trigger save on change
                            dataModel.triggerTradeUpdate()
                        }
                    if !unitsIsValid && !realTimeTrade.trade.position.unitSizeString.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                            .help("Invalid units value")
                    }
                }

                // Cost and currency field - expandable with validation
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        TextField("average position cost", text: self.$realTimeTrade.trade.position.positionAvgCostString)
                            .frame(minWidth: 80, idealWidth: 120)
                            .onChange(of: realTimeTrade.trade.position.positionAvgCostString) { _ in
                                validateInput()
                                // Trigger save on change
                                dataModel.triggerTradeUpdate()
                            }
                        if !costIsValid && !realTimeTrade.trade.position.positionAvgCostString.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption2)
                                .help("Invalid cost value")
                        }
                    }
                
                Button(action: {
                    showCurrencyPicker.toggle()
                }) {
                    Text(detectedCurrency)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("Click to change currency unit")
                .popover(isPresented: $showCurrencyPicker) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cost Currency Unit")
                            .font(.headline)
                            .padding(.bottom, 4)
                        
                        ForEach(availableCurrencies, id: \.self) { currency in
                            Button(action: {
                                realTimeTrade.trade.position.costCurrency = currency
                                showCurrencyPicker = false
                                // Trigger save on change
                                dataModel.triggerTradeUpdate()
                            }) {
                                HStack {
                                    Text(currency)
                                    if currency == detectedCurrency {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        
                        if realTimeTrade.trade.name.uppercased().hasSuffix(".L") {
                            Text("UK stocks (.L) are typically quoted in GBX (pence)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding()
                    .frame(width: 200)
                }
                }  // Close HStack(spacing: 4) from line 213

                Spacer()

                // Watchlist toggle
                Button(action: {
                    realTimeTrade.trade.isWatchlistOnly.toggle()
                    // Trigger save on change
                    dataModel.triggerTradeUpdate()
                }) {
                    Image(systemName: realTimeTrade.trade.isWatchlistOnly ? "eye.fill" : "eye")
                        .foregroundColor(realTimeTrade.trade.isWatchlistOnly ? .secondary : .blue)
                        .font(.body)
                        .help(realTimeTrade.trade.isWatchlistOnly ? "Watchlist only (not included in portfolio calculations)" : "Portfolio stock (click to make watchlist-only)")
                }
                .buttonStyle(BorderlessButtonStyle())
            }  // Close HStack(spacing: 8) from line 181

            // Validation error message
            if let error = validationError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading) // Fill available width efficiently
    }

    private func validateInput() {
        var errors: [String] = []

        // Validate symbol
        if !realTimeTrade.trade.name.isEmpty && !symbolIsValid {
            errors.append("Invalid symbol")
        }

        // Validate units
        if !realTimeTrade.trade.position.unitSizeString.isEmpty && !unitsIsValid {
            errors.append("Invalid units")
        }

        // Validate cost
        if !realTimeTrade.trade.position.positionAvgCostString.isEmpty && !costIsValid {
            errors.append("Invalid cost")
        }

        validationError = errors.isEmpty ? nil : errors.joined(separator: ", ")
    }
}

struct PreferenceView: View {
    @ObservedObject var userdata: DataModel
    private let currencyConverter = CurrencyConverter()
    private let configManager = ConfigurationManager.shared
    @State private var selectedTab: PreferenceTab = .portfolio
    @State private var apiKey: String = ""
    @State private var showingAPIKeyAlert = false
    @State private var apiKeyAlertMessage = ""
    @State private var isAPIKeyVisible = false
    @State private var isBackfillingData = false
    @State private var backfillStatus = ""

    // Bulk edit mode state
    @State private var bulkEditMode: Bool = false
    @State private var selectedSymbols: Set<String> = []
    @State private var showingBulkCurrencyPicker = false
    @State private var bulkCurrency: String = "USD"

    // Backfill configuration
    @AppStorage("backfillSchedule") private var backfillSchedule: String = "startup"
    @AppStorage("backfillCooldownHours") private var backfillCooldownHours: Int = 2
    @AppStorage("backfillNotifications") private var backfillNotifications: Bool = true

    // Portfolio Export/Import state variables
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var exportDocument: CSVDocument?
    @State private var showingImportAlert = false
    @State private var importAlertMessage = ""
    @State private var importResult: (success: Bool, message: String) = (false, "")

    // Backup state variables
    @State private var showingRestoreSheet = false
    @State private var selectedBackup: BackupInfo?
    @State private var showingRestoreConfirmation = false
    @State private var showingBackupAlert = false
    @State private var backupAlertMessage = ""

    // Debug control state variables
    @State private var currentRefreshInterval: TimeInterval = 900
    @State private var currentSnapshotInterval: TimeInterval = 30

    // Advanced debug tools state
    @State private var simulateMarketClosed: Bool = false
    @State private var debugReportStatus: String = ""

    // Appearance preference
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @Environment(\.colorScheme) private var systemColorScheme

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
    
    private var availableSymbols: [String] {
        userdata.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // CRITICAL: Fixed navigation area that should never be cut off
            VStack(spacing: 0) {
                // Tab picker - always visible
                Picker("Preference Tab", selection: $selectedTab) {
                    Text("Portfolio").tag(PreferenceTab.portfolio)
                    Text("Charts").tag(PreferenceTab.charts)
                    Text("Risk").tag(PreferenceTab.risk)
                    Text("Analytics").tag(PreferenceTab.analytics)
                    Text("Data").tag(PreferenceTab.dataSources)
                    Text("Debug").tag(PreferenceTab.debug)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                
                // Separator line for visual clarity
                Divider()
                    .padding(.horizontal, 12)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .frame(minHeight: 60, idealHeight: 60, maxHeight: 60) // Fixed height for navigation with more space
            
            // Tab content area with proper spacing
            Group {
                switch selectedTab {
                case .portfolio:
                    portfolioView
                case .charts:
                    chartsView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .risk:
                    riskView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .analytics:
                    analyticsView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .dataSources:
                    dataSourcesView
                case .debug:
                    debugView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 650, idealWidth: 1000, maxWidth: 1200,
               minHeight: 500, idealHeight: 700, maxHeight: 900)
        .fixedSize(horizontal: false, vertical: false) // Allow both horizontal and vertical resizing
        .preferredColorScheme(preferredColorScheme)
    }

    /// Computed property to determine the effective color scheme based on user preference
    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light":
            return .light
        case "dark":
            return .dark
        default: // "system"
            return nil
        }
    }
    
    private var portfolioView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Color Coding", isOn: $userdata.showColorCoding)
                Spacer()
            }
            
            HStack {
                Toggle("Market Indicators", isOn: $userdata.showMarketIndicators)
                    .help("Show emoji indicators for pre-market 🔆, after-hours 🌙, and closed markets 🔒")
                Spacer()
            }

            HStack {
                Text("Preferred Currency:")
                Picker("", selection: $userdata.preferredCurrency) {
                    ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                        Text(currency).tag(currency)
                    }
                }
                .frame(width: 100)
                Spacer()
            }

            HStack {
                Text("Appearance:")
                Picker("", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .frame(width: 120)
                .help("Override system appearance settings")
                Spacer()
            }

            Divider()
                .padding(.vertical, 8)

            // Menu Bar Display Settings (UI Enhancement v2.3.0)
            VStack(alignment: .leading, spacing: 12) {
                Text("Menu Bar Display")
                    .font(.headline)
                    .padding(.bottom, 4)

                // Display Mode
                HStack {
                    Text("Display Mode:")
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $userdata.menuBarDisplaySettings.displayMode) {
                        ForEach(MenuBarDisplaySettings.DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .frame(width: 220)
                    .help("Choose how stock information appears in the menu bar")
                    Spacer()
                }

                // Change Format
                HStack {
                    Text("Change Format:")
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $userdata.menuBarDisplaySettings.changeFormat) {
                        ForEach(MenuBarDisplaySettings.ChangeFormat.allCases, id: \.self) { format in
                            Text(format.description).tag(format)
                        }
                    }
                    .frame(width: 220)
                    .help("Show price changes as percentage, dollar amount, or both")
                    Spacer()
                }

                // Custom Template (only shown when custom mode is selected)
                if userdata.menuBarDisplaySettings.displayMode == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Custom Template:")
                                .frame(width: 120, alignment: .leading)
                            TextField("e.g., {symbol}: {changePct}", text: Binding(
                                get: { userdata.menuBarDisplaySettings.customTemplate ?? "" },
                                set: { userdata.menuBarDisplaySettings.customTemplate = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .help("Use placeholders: {symbol}, {price}, {change}, {changePct}, {currency}, {arrow}")
                        }

                        // Template validation message
                        if let template = userdata.menuBarDisplaySettings.customTemplate {
                            let validation = MenuBarDisplaySettings.validateTemplate(template)
                            if !validation.isValid {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(validation.errorMessage ?? "Invalid template")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                .padding(.leading, 120)
                            } else {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Template is valid")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                .padding(.leading, 120)
                            }
                        }
                    }
                }

                // Arrow Style
                HStack {
                    Text("Arrow Indicators:")
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $userdata.menuBarDisplaySettings.arrowStyle) {
                        ForEach(MenuBarDisplaySettings.ArrowStyle.allCases, id: \.self) { style in
                            Text(style.description).tag(style)
                        }
                    }
                    .frame(width: 220)
                    .help("Add visual arrow indicators for price movement")
                    Spacer()
                }

                // Arrow Position (only shown if arrows are enabled)
                if userdata.menuBarDisplaySettings.arrowStyle != .none {
                    HStack {
                        Text("")
                            .frame(width: 120, alignment: .leading)
                        Toggle("Show arrow before symbol", isOn: $userdata.menuBarDisplaySettings.showArrowBeforeSymbol)
                            .help("Place arrow indicator before or after the stock symbol")
                        Spacer()
                    }
                }

                // Decimal Places
                HStack {
                    Text("Decimal Places:")
                        .frame(width: 120, alignment: .leading)
                    Stepper(value: $userdata.menuBarDisplaySettings.decimalPlaces, in: 0...4) {
                        Text("\(userdata.menuBarDisplaySettings.decimalPlaces)")
                            .frame(width: 30)
                    }
                    .help("Number of decimal places for prices and changes")
                    Spacer()
                }

                // Show Currency
                HStack {
                    Text("")
                        .frame(width: 120, alignment: .leading)
                    Toggle("Show currency symbols", isOn: $userdata.menuBarDisplaySettings.showCurrency)
                        .help("Display currency symbols (e.g., $, £) with prices")
                    Spacer()
                }

                // Live Preview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(userdata.menuBarDisplaySettings.samplePreview())
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // API Key management section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Data Sources & API Keys")
                            .font(.headline)
                        Text("Manage API keys and fetch priorities in the Data tab.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Go to Data Settings") {
                        selectedTab = .dataSources
                    }
                }
                .padding(.vertical, 4)
                
                Divider()
                
                // Historical data backfill section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Historical Data Backfill:")
                            .font(.headline)
                        Spacer()
                        Button(isBackfillingData ? "Backfilling..." : "Force 5-Year Backfill") {
                            force5YearBackfill()
                        }
                        .disabled(isBackfillingData)
                        .help("Forces comprehensive 5-year historical data backfill for all stocks")

                        Button("Check & Fill Missing Data") {
                            manualBackfillHistoricalData()
                        }
                        .disabled(isBackfillingData || (configManager.getFMPAPIKey()?.isEmpty ?? true))
                        .help("Checks for missing historical data and fetches only missing days")

                        Button("Clean Anomalous Data") {
                            cleanAnomalousData()
                        }
                        .help("Removes anomalous price data points that may cause chart dips")

                        Button("Clear All Historical Data") {
                            clearAllHistoricalData()
                        }
                        .help("Clears all historical chart data to start fresh")
                        
                        Button("Fetch 5 Years Data") {
                            fetch5YearsHistoricalDataPortfolio()
                        }
                        .disabled(isBackfillingData || (configManager.getFMPAPIKey()?.isEmpty ?? true))
                        .foregroundColor(.blue)
                        .help("Fetch 5 years of historical data in yearly chunks")
                    }
                    
                    if !backfillStatus.isEmpty {
                        Text(backfillStatus)
                            .font(.caption)
                            .foregroundColor(backfillStatus.contains("Error") ? .red : .blue)
                    }
                    
                    Text("Automatically checks for gaps and fetches up to 5 years of missing daily data")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("Show Current Data Status") {
                        showCurrentDataStatus()
                    }
                    .font(.caption)
                    .help("Shows how much historical data is currently stored for each symbol")
                    
                    Button("Optimize Data Storage") {
                        optimizeDataStorage()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    .help("Cleans up historical data to stay within storage limits")
                    
                    Button("Force Snapshot (Debug)") {
                        userdata.historicalDataManager.forceSnapshot(from: userdata)
                    }
                    .font(.caption)
                    .help("Forces a historical data snapshot for debugging")
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(8)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Exchange Rates")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        currencyConverter.refreshRates()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh exchange rates")
                }

                HStack {
                    Text("Last Updated:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currencyConverter.getTimeSinceRefresh())
                        .font(.caption)
                        .foregroundColor(currencyConverter.lastRefreshSuccess ? .secondary : .orange)
                    if !currencyConverter.lastRefreshSuccess && currencyConverter.lastRefreshTime != Date.distantPast {
                        Text("(using fallback rates)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                // Show current exchange rates for common currencies
                if !currencyConverter.exchangeRates.isEmpty {
                    Divider()
                    Text("Current Rates (from USD):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        ForEach(["GBP", "EUR", "JPY"], id: \.self) { currency in
                            if let rate = currencyConverter.exchangeRates[currency] {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(currency)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(String(format: "%.4f", rate))
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .padding(.bottom, 10)

            // Display total net gains
            HStack {
                Text("Total Net Gains:")
                let gains = userdata.calculateNetGains()
                let formattedAmount = String(format: "%+.2f", gains.amount)
                Text("\(formattedAmount) \(gains.currency)")
                    .foregroundColor(gains.amount >= 0 ? .green : .red)
                Spacer()
            }
            .padding(.bottom, 5)
            
            // Display net portfolio value
            HStack {
                Text("Net Value:")
                let netValue = userdata.calculateNetValue()
                let formattedValue = String(format: "%.2f", netValue.amount)
                Text("\(formattedValue) \(netValue.currency)")
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.bottom, 10)
            // Force view to update when trades change
            .id(userdata.realTimeTrades.map { $0.realTimeInfo.currentPrice }.reduce(0, +))
            HStack {
                Spacer()
                Text("Symbol")
                Spacer()
                Text("Units")
                Spacer()
                Text("Avg position cost (currency)")
                    .help("Click the currency button next to each cost to specify GBX, GBP, USD, etc.")
                Button(action: {
                    let emptyTrade = emptyRealTimeTrade()
                    self.userdata.realTimeTrades.insert(emptyTrade, at: 0)
                    }
                ) {
                    Text("+")
                }
            }

            // Bulk edit mode toggle and toolbar
            HStack {
                Button(action: {
                    bulkEditMode.toggle()
                    if !bulkEditMode {
                        selectedSymbols.removeAll()
                    }
                }) {
                    HStack {
                        Image(systemName: bulkEditMode ? "checkmark.square" : "square")
                        Text(bulkEditMode ? "Exit Bulk Edit" : "Bulk Edit")
                    }
                }
                .buttonStyle(.bordered)
                .help("Toggle bulk selection mode for multiple stocks")

                if bulkEditMode {
                    Divider()
                        .frame(height: 20)

                    Button("Select All") {
                        selectedSymbols = Set(userdata.realTimeTrades.map { $0.trade.name })
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSymbols.count == userdata.realTimeTrades.count)

                    Button("Deselect All") {
                        selectedSymbols.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedSymbols.isEmpty)

                    Divider()
                        .frame(height: 20)

                    Text("\(selectedSymbols.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    // Bulk actions
                    Button(action: {
                        showingBulkCurrencyPicker = true
                    }) {
                        HStack {
                            Image(systemName: "coloncurrencysign.circle")
                            Text("Change Currency")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedSymbols.isEmpty)
                    .popover(isPresented: $showingBulkCurrencyPicker) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Change Currency for Selected Stocks")
                                .font(.headline)
                                .padding(.bottom, 4)

                            ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                                Button(action: {
                                    applyBulkCurrency(currency)
                                    showingBulkCurrencyPicker = false
                                }) {
                                    Text(currency)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding()
                        .frame(width: 200)
                    }

                    Button(action: {
                        deleteSelectedStocks()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete")
                        }
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .disabled(selectedSymbols.isEmpty)
                }
            }
            .padding(.vertical, 8)

            // List for drag-and-drop functionality
            List {
                ForEach(userdata.realTimeTrades) { item in
                    HStack {
                        // Show checkbox in bulk edit mode
                        if bulkEditMode {
                            Button(action: {
                                toggleSelection(for: item.trade.name)
                            }) {
                                Image(systemName: selectedSymbols.contains(item.trade.name) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(selectedSymbols.contains(item.trade.name) ? .blue : .secondary)
                            }
                            .buttonStyle(.borderless)
                        }

                        // Drag handle icon
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                            .help("Drag to reorder stocks in menu bar")
                        
                        Button(action: {
                            if let index = self.userdata.realTimeTrades.map({ $0.id }).firstIndex(of: item.id) {
                                self.userdata.realTimeTrades.remove(at: index)
                            }
                        }) {
                            Text("-")
                        }
                        PreferenceRow(realTimeTrade: item, dataModel: userdata)
                        Button(action: {
                            let emptyTrade = emptyRealTimeTrade()
                            if let index = self.userdata.realTimeTrades.map({ $0.id }).firstIndex(of: item.id) {
                                self.userdata.realTimeTrades.insert(emptyTrade, at: index + 1)
                            }
                        }) {
                            Text("+")
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: moveStocks)
                .onDelete(perform: deleteStocks)
            }
            .listStyle(PlainListStyle())
            .frame(minHeight: CGFloat(userdata.realTimeTrades.count * 40 + 20))
            
            // Portfolio Export/Import Section
            VStack(spacing: 12) {
                Text("Portfolio Management")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack(spacing: 16) {
                    Button(action: {
                        exportPortfolio()
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export Portfolio")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .help("Export your stock positions to CSV file")
                    
                    Button(action: {
                        showingImportSheet = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Portfolio")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .help("Import stock positions from CSV file")
                    
                    Spacer()
                }
                
                Text("Export/import your stock positions: Symbol, Units, Average Position Cost")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)

            // Backup Management Section
            VStack(spacing: 12) {
                HStack {
                    Text("Automatic Backups")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                }

                // Backup status
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let lastBackup = BackupService.shared.lastBackupDate {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Last backup: \(formattedBackupDate(lastBackup))")
                                    .font(.caption)
                            }
                        } else {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.blue)
                                Text("No backup performed yet")
                                    .font(.caption)
                            }
                        }

                        Text("Automatic daily backups saved to Application Support folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                // Backup actions
                HStack(spacing: 16) {
                    Button(action: {
                        performManualBackup()
                    }) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Backup Now")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .help("Manually create a backup of your portfolio")

                    Button(action: {
                        showingRestoreSheet = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restore from Backup...")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help("Restore portfolio from a backup file")
                    .disabled(BackupService.shared.listAvailableBackups().isEmpty)

                    Button(action: {
                        BackupService.shared.openBackupDirectory()
                    }) {
                        HStack {
                            Image(systemName: "folder")
                            Text("View Backups")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .help("Open backup folder in Finder")

                    Spacer()
                }

                // Retention settings
                HStack {
                    Text("Keep backups for:")
                    Picker("", selection: Binding(
                        get: { BackupService.shared.retentionDays },
                        set: { BackupService.shared.retentionDays = $0 }
                    )) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 120)
                    .help("Old backups will be automatically deleted")
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)

            // MARK: - Price Alerts Section
            Divider()
                .padding(.vertical, 8)

            PriceAlertManagementView(dataModel: userdata)
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fileExporter(
            isPresented: $showingExportSheet,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "StockbarPortfolio"
        ) { result in
            switch result {
            case .success(let url):
                print("Portfolio exported to: \(url)")
            case .failure(let error):
                print("Export failed: \(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            importPortfolio(result: result)
        }
        .alert("API Key", isPresented: $showingAPIKeyAlert) {
            Button("OK") { }
        } message: {
            Text(apiKeyAlertMessage)
        }
        .alert("Import Result", isPresented: $showingImportAlert) {
            Button("OK") { }
        } message: {
            Text(importAlertMessage)
        }
        .alert("Backup", isPresented: $showingBackupAlert) {
            Button("OK") { }
        } message: {
            Text(backupAlertMessage)
        }
        .sheet(isPresented: $showingRestoreSheet) {
            RestoreBackupView(
                isPresented: $showingRestoreSheet,
                dataModel: userdata
            )
        }
    }
    
    private var chartsView: some View {
        ScrollView {
            PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
        }
    }

    private var riskView: some View {
        RiskAnalyticsView(dataModel: userdata)
    }

    private var analyticsView: some View {
        PortfolioAnalyticsView(dataModel: userdata)
    }

    private var dataSourcesView: some View {
        DataSourcesSettingsView(dataModel: userdata)
    }

    private var debugView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                debugFrequencyControls
                debugActions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Debug Logs section - remove from container since DebugLogView handles its own layout
            DebugLogView()
                .frame(minHeight: 200, maxHeight: 500)
                .clipped()
        }
        .onAppear {
            // Initialize state variables with current values
            currentRefreshInterval = userdata.refreshInterval
            currentSnapshotInterval = HistoricalDataManager.shared.getSnapshotInterval()
        }
        .onChange(of: selectedTab) { _, newTab in
            // Sync state variables when debug tab is selected
            if newTab == .debug {
                currentRefreshInterval = userdata.refreshInterval
                currentSnapshotInterval = HistoricalDataManager.shared.getSnapshotInterval()
            }
        }
    }
    
    private var debugFrequencyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Refresh Frequency Controls")
                .font(.headline)
                .foregroundColor(.primary)
            
            // Refresh Interval
            VStack(alignment: .leading, spacing: 4) {
                Text("Main Refresh Interval:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Picker("", selection: $currentRefreshInterval) {
                        ForEach(refreshIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .onChange(of: currentRefreshInterval) { _, newValue in
                        setRefreshInterval(newValue)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                    
                    Text("(how often stock prices update)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Cache interval removed - now managed internally by CacheCoordinator (fixed at 15 minutes)

            // Snapshot Interval
            VStack(alignment: .leading, spacing: 4) {
                Text("Chart Data Collection Interval:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Picker("", selection: $currentSnapshotInterval) {
                        ForEach(snapshotIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .onChange(of: currentSnapshotInterval) { _, newValue in
                        setSnapshotInterval(newValue)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                    
                    Text("(how often to save data for charts)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var debugActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug Actions")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                    .help("Reset all frequency settings to default values")
                }
                
                HStack(spacing: 12) {
                    Button("Show Automatic Check Status") {
                        showAutomaticCheckStatus()
                    }
                    .buttonStyle(.bordered)
                    .help("Shows status of automatic historical data checking")
                }
            }

            // Log Management Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Log File Management")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                HStack {
                    Text("Total log size:")
                    Text(String(format: "%.2f MB", Logger.shared.getTotalLogSize()))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .font(.caption)

                Text("Log files are automatically rotated when they exceed 10MB. Up to 3 files are kept: stockbar.log, stockbar.1.log, stockbar.2.log")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Clear Old Logs") {
                        clearOldLogs()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Delete all log files to free up space")
                }
            }

            // Historical Data Backfill Configuration
            VStack(alignment: .leading, spacing: 8) {
                Text("Historical Data Backfill")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                // Schedule selector
                HStack {
                    Text("Auto-backfill schedule:")
                        .font(.caption)
                    Picker("", selection: $backfillSchedule) {
                        Text("On Startup").tag("startup")
                        Text("Manual Only").tag("manual")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    Spacer()
                }

                // Cooldown period
                HStack {
                    Text("Cooldown between checks:")
                        .font(.caption)
                    Picker("", selection: $backfillCooldownHours) {
                        Text("30 minutes").tag(0)
                        Text("1 hour").tag(1)
                        Text("2 hours (default)").tag(2)
                        Text("6 hours").tag(6)
                        Text("12 hours").tag(12)
                        Text("24 hours").tag(24)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    Spacer()
                }

                // Notifications toggle
                Toggle("Show notifications for backfill progress", isOn: $backfillNotifications)
                    .font(.caption)

                Text("Backfill automatically checks for and fetches missing 5-year historical data. Adjust cooldown to control frequency.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Manual trigger button
                HStack(spacing: 12) {
                    Button(isBackfillingData ? "Backfilling..." : "Trigger Manual Backfill") {
                        triggerManualBackfill()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBackfillingData)
                    .help("Manually trigger a full 5-year historical data backfill for all symbols")

                    if !backfillStatus.isEmpty {
                        Text(backfillStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Cache Inspector Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Cache Inspector")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                if userdata.realTimeTrades.isEmpty {
                    Text("No stocks in portfolio to inspect")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(userdata.realTimeTrades.prefix(10)) { trade in
                                cacheInspectorRow(for: trade.trade.name)
                            }

                            if userdata.realTimeTrades.count > 10 {
                                Text("...and \(userdata.realTimeTrades.count - 10) more")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }

                HStack(spacing: 12) {
                    Button("Clear All Caches") {
                        clearAllCaches()
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help("Clear all cached data and force fresh fetch")

                    Button("Refresh Cache View") {
                        // Force view update
                        Task { @MainActor in
                            self.userdata.objectWillChange.send()
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh cache status display")
                }
            }

            // Portfolio Data Debug Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Portfolio Data Debug")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                HStack(spacing: 12) {
                    Button("Reload Portfolio Snapshots") {
                        Task {
                            await HistoricalDataManager.shared.reloadPortfolioSnapshotsFromCoreData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .help("Reload portfolio snapshots from Core Data (use if charts show no data)")

                    Text("Snapshots in memory: \(HistoricalDataManager.shared.historicalPortfolioSnapshots.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Backfill Past Week Portfolio Data") {
                        Task {
                            await Logger.shared.info("🔄 Starting 1-week portfolio backfill...")
                            await userdata.calculateRetroactivePortfolioHistory(days: 7)
                            await HistoricalDataManager.shared.reloadPortfolioSnapshotsFromCoreData()
                            await Logger.shared.info("✅ 1-week portfolio backfill completed")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .help("Fetch hourly price data for past week and calculate portfolio values retroactively")
                }
            }

            // Automatic Backfill Scheduler Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic Backfill Scheduler")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.blue)
                        Text("Schedule:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("20 min after startup, then daily at 15:00")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.green)
                        Text("Gap Detection:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("Validates existing data before API calls")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let lastBackfill = BackfillScheduler.shared.getLastBackfillDate() {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.orange)
                            Text("Last Run:")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text(lastBackfill)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.gray)
                            Text("Last Run:")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("Never")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button("Run Backfill Check Now") {
                        Task {
                            await Logger.shared.info("📅 Manual backfill check triggered from UI")
                            let didRun = await BackfillScheduler.shared.checkAndRunBackfillIfNeeded(dataModel: userdata)
                            if didRun {
                                await Logger.shared.info("✅ Manual backfill check completed - backfill was executed")
                            } else {
                                await Logger.shared.info("ℹ️ Manual backfill check completed - no backfill needed")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .help("Manually trigger gap detection and backfill if needed")

                    Text("Checks for gaps before running")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Advanced Debug Tools Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Advanced Debug Tools")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.top, 8)

                // Simulate Market Closed toggle
                Toggle("Simulate Market Closed Mode", isOn: $simulateMarketClosed)
                    .font(.caption)
                    .help("Override market status detection for testing")

                if simulateMarketClosed {
                    Text("⚠️ Market will appear closed even if actually open")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.leading, 20)
                }

                // Export Debug Report button
                HStack(spacing: 12) {
                    Button("Export Debug Report") {
                        exportDebugReport()
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .help("Bundle logs, config, and portfolio summary for troubleshooting")

                    if !debugReportStatus.isEmpty {
                        Text(debugReportStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    
    // MARK: - Debug Interval Options
    
    private let refreshIntervalOptions: [(String, TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes (default)", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600)
    ]
    
    private let cacheIntervalOptions: [(String, TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes (default)", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600)
    ]
    
    private let snapshotIntervalOptions: [(String, TimeInterval)] = [
        ("5 seconds", 5),
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes (default)", 300)
    ]
    
    // MARK: - Debug Action Functions
    
    private func formatInterval(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds >= 3600 {
            return "\(seconds / 3600)h"
        } else if seconds >= 60 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds)s"
        }
    }
    
    private func setRefreshInterval(_ interval: TimeInterval) {
        userdata.refreshInterval = interval
        Task { await Logger.shared.info("🔧 Debug: Refresh interval changed to \(interval) seconds") }
        
        // Notify the menu bar controller to restart its timer
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: interval)
    }
    
    private func setSnapshotInterval(_ interval: TimeInterval) {
        HistoricalDataManager.shared.setSnapshotInterval(interval)
        Task { await Logger.shared.info("🔧 Debug: Snapshot interval changed to \(interval) seconds") }
    }
    
    private func forceDataSnapshot() {
        HistoricalDataManager.shared.forceSnapshot(from: userdata)
        Task { await Logger.shared.info("🔧 Debug: Forced data snapshot") }
    }
    
    private func clearHistoricalData() {
        HistoricalDataManager.shared.clearAllData()
        Task { await Logger.shared.info("🔧 Debug: Cleared all historical data") }
    }
    
    private func fetch5YearsHistoricalData() {
        Task {
            await Logger.shared.info("🔧 Debug: Starting 5-year historical data fetch")
            await userdata.triggerFullHistoricalBackfill()
            await Logger.shared.info("🔧 Debug: 5-year historical data fetch completed")
        }
    }
    
    private func resetToDefaults() {
        userdata.refreshInterval = 300  // 5 minutes
        HistoricalDataManager.shared.setSnapshotInterval(300)  // 5 minutes

        // Update state variables to reflect the reset
        currentRefreshInterval = 300
        currentSnapshotInterval = 300
        
        Task { await Logger.shared.info("🔧 Debug: Reset all intervals to defaults") }
        
        // Notify the menu bar controller to restart its timer
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: TimeInterval(900))
    }
    
    private func saveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        configManager.setFMPAPIKey(trimmedKey)
        showAPIKeyAlert(title: "API Key Saved", message: "Your API key has been saved securely to your local Documents folder.")
    }
    
    private func testAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        // Save the key first so the network service can use it
        configManager.setFMPAPIKey(trimmedKey)
        
        Task {
            do {
                // Test with a simple API call
                let testResult = try await userdata.testAPIConnection()
                DispatchQueue.main.async {
                    if testResult {
                        showAPIKeyAlert(title: "API Key Valid", message: "Your Financial Modeling Prep API key is working correctly!")
                    } else {
                        showAPIKeyAlert(title: "API Key Invalid", message: "The API key could not be validated. Please check your key and try again.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    showAPIKeyAlert(title: "API Test Failed", message: "Failed to test API key: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func saveAndTestAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        // Save the key first
        configManager.setFMPAPIKey(trimmedKey)
        
        // Then test it
        Task {
            do {
                let testResult = try await userdata.testAPIConnection()
                DispatchQueue.main.async {
                    if testResult {
                        showAPIKeyAlert(title: "API Key Saved & Validated", message: "Your Financial Modeling Prep API key has been saved and is working correctly!")
                    } else {
                        showAPIKeyAlert(title: "API Key Saved but Invalid", message: "The API key has been saved but could not be validated. Please check your key.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    showAPIKeyAlert(title: "API Key Saved", message: "Your API key has been saved, but testing failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func clearAPIKey() {
        configManager.removeFMPAPIKey()
        apiKey = ""
        showAPIKeyAlert(title: "API Key Cleared", message: "Your API key has been removed from local storage.")
    }
    
    private func showConfigFile() {
        guard let configPath = configManager.getConfigFilePath() else { return }
        NSWorkspace.shared.selectFile(configPath, inFileViewerRootedAtPath: "")
    }
    
    private func showAPIKeyAlert(title: String, message: String) {
        apiKeyAlertMessage = message
        showingAPIKeyAlert = true
    }
    
    private func moveStocks(from source: IndexSet, to destination: Int) {
        userdata.realTimeTrades.move(fromOffsets: source, toOffset: destination)
        // The move operation will automatically trigger the DataModel's didSet observer
        // which will save the new order to UserDefaults
    }
    
    private func deleteStocks(at offsets: IndexSet) {
        userdata.realTimeTrades.remove(atOffsets: offsets)
    }

    // MARK: - Bulk Edit Functions

    private func toggleSelection(for symbol: String) {
        if selectedSymbols.contains(symbol) {
            selectedSymbols.remove(symbol)
        } else {
            selectedSymbols.insert(symbol)
        }
    }

    private func applyBulkCurrency(_ currency: String) {
        for symbol in selectedSymbols {
            if let index = userdata.realTimeTrades.firstIndex(where: { $0.trade.name == symbol }) {
                userdata.realTimeTrades[index].trade.position.costCurrency = currency
            }
        }
        Task { await Logger.shared.info("💱 [BulkEdit] Changed currency to \(currency) for \(selectedSymbols.count) stocks") }
    }

    private func deleteSelectedStocks() {
        // Get indices of selected stocks
        let indicesToRemove = userdata.realTimeTrades.indices.filter { index in
            selectedSymbols.contains(userdata.realTimeTrades[index].trade.name)
        }

        // Remove in reverse order to avoid index shifting issues
        for index in indicesToRemove.reversed() {
            userdata.realTimeTrades.remove(at: index)
        }

        Task { await Logger.shared.info("🗑️ [BulkEdit] Deleted \(selectedSymbols.count) stocks") }
        selectedSymbols.removeAll()
    }

    private func showCurrentDataStatus() {
        var statusMessage = "Current Historical Data Status:\n\n"
        
        let dataStatus = userdata.historicalDataManager.getComprehensiveDataStatus()
        
        if dataStatus.isEmpty {
            statusMessage += "No historical data stored."
        } else {
            statusMessage += "Symbol | Data Points | Date Range\n"
            statusMessage += "─────────────────────────────────────\n"
            
            for status in dataStatus {
                statusMessage += "\(status.symbol): \(status.daily) points (\(status.oldestDate) to \(status.newestDate))\n"
            }
            
            let totalPoints = dataStatus.reduce(0) { $0 + $1.daily }
            
            statusMessage += "\n📊 Total: \(totalPoints) data points across all symbols"
            statusMessage += "\n\nData Storage: Up to 2500 points per symbol for 5+ years coverage"
        }
        
        showAPIKeyAlert(title: "Historical Data Status", message: statusMessage)
    }
    
    private func optimizeDataStorage() {
        Task {
            await MainActor.run {
                backfillStatus = "🔧 Optimizing data storage..."
            }

            userdata.historicalDataManager.optimizeAllDataStorage()

            await MainActor.run {
                backfillStatus = "✅ Data storage optimization completed"
            }
        }
    }

    private func force5YearBackfill() {
        guard !isBackfillingData else { return }

        isBackfillingData = true
        backfillStatus = "🚀 Starting comprehensive 5-year backfill..."

        Task {
            let symbols = userdata.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }

            if symbols.isEmpty {
                await MainActor.run {
                    backfillStatus = "❌ No symbols to backfill"
                    isBackfillingData = false
                }
                return
            }

            await Logger.shared.info("🔄 MANUAL: User initiated forced 5-year backfill for \(symbols.count) symbols")

            await MainActor.run {
                backfillStatus = "📊 Backfilling 5 years of data for \(symbols.count) symbols... (this may take several minutes)"
            }

            // Force comprehensive 5-year backfill
            await userdata.checkAndBackfill5YearHistoricalData()

            await MainActor.run {
                backfillStatus = "✅ 5-year backfill completed! Check Charts tab to view historical data."
                isBackfillingData = false
            }

            await Logger.shared.info("✅ MANUAL: 5-year backfill completed successfully")
        }
    }

    private func manualBackfillHistoricalData() {
        guard !isBackfillingData else { return }
        guard let apiKey = configManager.getFMPAPIKey(), !apiKey.isEmpty else {
            backfillStatus = "Error: API key required"
            return
        }
        
        isBackfillingData = true
        backfillStatus = "Analyzing data gaps..."
        
        Task {
            do {
                // First check what symbols we have
                let symbols = userdata.realTimeTrades.map { $0.trade.name }.filter { !$0.isEmpty }
                
                if symbols.isEmpty {
                    await MainActor.run {
                        backfillStatus = "No symbols to backfill"
                        isBackfillingData = false
                    }
                    return
                }
                
                await MainActor.run {
                    backfillStatus = "Checking \(symbols.count) symbols for missing data..."
                }
                
                // Check each symbol for gaps - simplified logic for testing
                var symbolsNeedingBackfill: [String] = []
                let calendar = Calendar.current
                let today = Date()
                let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: today) ?? today
                
                for symbol in symbols {
                    let existingSnapshots = userdata.historicalDataManager.priceSnapshots[symbol] ?? []
                    let historicalSnapshots = existingSnapshots.filter { $0.timestamp >= oneYearAgo }
                    
                    // Count unique days with data in the past year
                    let uniqueDays = Set(historicalSnapshots.map { calendar.startOfDay(for: $0.timestamp) })
                    
                    // If we have less than 50 unique days of data in the past year, trigger backfill
                    if uniqueDays.count < 50 {
                        symbolsNeedingBackfill.append(symbol)
                                            await Logger.shared.debug("DEBUG: \(symbol) has only \(uniqueDays.count) unique days of data, needs backfill")
                } else {
                    await Logger.shared.debug("DEBUG: \(symbol) has \(uniqueDays.count) unique days of data, sufficient")
                    }
                }
                
                await MainActor.run {
                    if symbolsNeedingBackfill.isEmpty {
                        backfillStatus = "✅ All symbols have sufficient historical data"
                        isBackfillingData = false
                    } else {
                        backfillStatus = "Found \(symbolsNeedingBackfill.count) symbols needing backfill: \(symbolsNeedingBackfill.joined(separator: ", "))"
                    }
                }
                
                // Perform backfill if needed
                if !symbolsNeedingBackfill.isEmpty {
                    await userdata.checkAndBackfillHistoricalData()
                    
                    await MainActor.run {
                        backfillStatus = "✅ Historical data backfill completed"
                        isBackfillingData = false
                    }
                }
                
            } catch {
                await MainActor.run {
                    backfillStatus = "Error: \(error.localizedDescription)"
                    isBackfillingData = false
                }
            }
        }
    }
    
    private func clearBadHistoricalData() async {
        // Clear corrupted data for known problematic UK stocks that had double conversion issues
        let ukSymbolsWithBadData = ["RR.L", "TSCO.L", "BP.L", "LLOY.L", "VOD.L", "AZN.L", "SHEL.L", "GSK.L", "BT-A.L", "NG.L"]
        
        // Filter to only clear symbols that actually exist in our data
        let symbolsToProcess = userdata.realTimeTrades.map { $0.trade.name }.filter { symbol in
            ukSymbolsWithBadData.contains(symbol) || symbol.uppercased().hasSuffix(".L")
        }
        
        if !symbolsToProcess.isEmpty {
            await userdata.clearHistoricalDataForSymbols(symbolsToProcess)
            backfillStatus = "✅ Cleared corrupted data for \(symbolsToProcess.count) UK symbols: \(symbolsToProcess.joined(separator: ", "))"
        } else {
            backfillStatus = "No UK stocks found to clear"
        }
    }
    
    private func cleanAnomalousData() {
        userdata.historicalDataManager.cleanAnomalousData()
        backfillStatus = "✅ Cleaned anomalous data points from historical data"
    }
    
    private func clearAllHistoricalData() {
        userdata.historicalDataManager.clearAllData()
        backfillStatus = "✅ Cleared all historical data - charts will rebuild from current values"
    }
    
    private func fetch5YearsHistoricalDataPortfolio() {
        guard !isBackfillingData else { return }
        guard let apiKey = configManager.getFMPAPIKey(), !apiKey.isEmpty else {
            backfillStatus = "Error: API key required"
            return
        }
        
        isBackfillingData = true
        backfillStatus = "🚀 Starting 5-year chunked historical data fetch..."
        
        Task {
            await userdata.triggerFullHistoricalBackfill()
            
            await MainActor.run {
                backfillStatus = "✅ 5-year historical data fetch completed"
                isBackfillingData = false
            }
        }
    }
    
    private func triggerManualBackfill() {
        guard !isBackfillingData else { return }

        isBackfillingData = true
        backfillStatus = "🚀 Starting..."

        // Send notification if enabled
        if backfillNotifications {
            sendNotification(title: "Historical Data Backfill", message: "Starting 5-year data fetch for all symbols...")
        }

        Task {
            await userdata.triggerFullHistoricalBackfill()

            await MainActor.run {
                backfillStatus = "✅ Completed"
                isBackfillingData = false

                // Send completion notification if enabled
                if backfillNotifications {
                    sendNotification(title: "Historical Data Backfill Complete", message: "5-year historical data fetch finished successfully")
                }
            }

            // Clear status after 5 seconds
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                backfillStatus = ""
            }
        }
    }

    private func sendNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func clearOldLogs() {
        Task {
            await Logger.shared.clearAllLogs()
            await Logger.shared.info("Debug: User cleared all log files from Debug tab")
        }
    }

    private func showAutomaticCheckStatus() {
        let status = userdata.getHistoricalDataStatus()

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        var statusMessage = "Automatic Historical Data Check Status:\n\n"

        if status.isRunningComprehensive {
            statusMessage += "🔍 RUNNING: Comprehensive 5-year coverage analysis in progress\n\n"
        } else {
            statusMessage += "✅ IDLE: No comprehensive check running\n\n"
        }

        if status.isRunningStandard {
            statusMessage += "🔍 RUNNING: Standard 1-month gap check in progress\n\n"
        } else {
            statusMessage += "✅ IDLE: No standard check running\n\n"
        }

        if status.lastComprehensiveCheck != Date.distantPast {
            statusMessage += "Last comprehensive check: \(formatter.string(from: status.lastComprehensiveCheck))\n"
        } else {
            statusMessage += "Last comprehensive check: Never\n"
        }
        
        if status.nextComprehensiveCheck > Date() {
            statusMessage += "Next comprehensive check: \(formatter.string(from: status.nextComprehensiveCheck))\n\n"
        } else {
            statusMessage += "Next comprehensive check: Available now\n\n"
        }
        
        statusMessage += "Automatic checks run in the background:\n"
        statusMessage += "• 2% chance per successful refresh: Comprehensive 5-year analysis\n"
        statusMessage += "• 8% chance per successful refresh: Standard 1-month gap check\n"
        statusMessage += "• Minimum 6 hours between comprehensive checks\n"
        statusMessage += "• All checks include staggered processing to prevent UI freezing"
        
        showAPIKeyAlert(title: "Automatic Check Status", message: statusMessage)
    }
    
    private func calculate5YearPortfolioValues() {
        guard !isBackfillingData else { return }
        
        isBackfillingData = true
        backfillStatus = "📊 Calculating 5-year portfolio values in monthly chunks..."
        
        Task {
            await userdata.calculate5YearPortfolioValues()
            
            await MainActor.run {
                backfillStatus = "✅ 5-year portfolio value calculation completed"
                isBackfillingData = false
            }
        }
    }
    
    private func calculate5YearPortfolioValuesDebug() {
        Task {
            await Logger.shared.info("🔧 Debug: Starting 5-year portfolio value calculation")
            await userdata.calculate5YearPortfolioValues()
            await Logger.shared.info("🔧 Debug: 5-year portfolio value calculation completed")
        }
    }
    
    // MARK: - Portfolio Export/Import Functions

    private func exportPortfolio() {
        let csvContent = PortfolioManager.exportToCSV(trades: self.userdata.realTimeTrades)
        self.exportDocument = CSVDocument(text: csvContent)
        self.showingExportSheet = true
    }

    // MARK: - Backup Functions

    private func formattedBackupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func performManualBackup() {
        Task {
            let success = await BackupService.shared.performManualBackup(trades: userdata.realTimeTrades)
            await MainActor.run {
                if success {
                    backupAlertMessage = "Backup completed successfully"
                } else {
                    backupAlertMessage = "Backup failed. Check logs for details."
                }
                showingBackupAlert = true
            }
        }
    }
    
    private func importPortfolio(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                self.importAlertMessage = "No file selected"
                self.showingImportAlert = true
                return
            }
            
            do {
                let csvContent = try String(contentsOf: url, encoding: .utf8)
                let importResult = PortfolioManager.importFromCSV(csvContent)
                
                if importResult.errors.isEmpty {
                    // Clear existing trades and add imported ones
                    self.userdata.realTimeTrades.removeAll()
                    
                    for trade in importResult.trades {
                        let emptyTradingInfo = TradingInfo()
                        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: emptyTradingInfo)
                        self.userdata.realTimeTrades.append(realTimeTrade)
                    }
                    
                    self.importAlertMessage = "Successfully imported \(importResult.trades.count) stocks from portfolio"
                } else {
                    let successCount = importResult.trades.count
                    let errorCount = importResult.errors.count
                    
                    if successCount > 0 {
                        // Clear existing trades and add successfully imported ones
                        self.userdata.realTimeTrades.removeAll()
                        
                        for trade in importResult.trades {
                            let emptyTradingInfo = TradingInfo()
                            let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: emptyTradingInfo)
                            self.userdata.realTimeTrades.append(realTimeTrade)
                        }
                        
                        self.importAlertMessage = "Imported \(successCount) stocks with \(errorCount) errors:\n\(importResult.errors.joined(separator: "\n"))"
                    } else {
                        self.importAlertMessage = "Import failed with \(errorCount) errors:\n\(importResult.errors.joined(separator: "\n"))"
                    }
                }
                
                self.showingImportAlert = true
                
            } catch {
                self.importAlertMessage = "Failed to read file: \(error.localizedDescription)"
                self.showingImportAlert = true
            }
            
        case .failure(let error):
            self.importAlertMessage = "Import failed: \(error.localizedDescription)"
            self.showingImportAlert = true
        }
    }

    // MARK: - Advanced Debug Tools Helper Functions

    /// Display cache status row for a single symbol
    @ViewBuilder
    private func cacheInspectorRow(for symbol: String) -> some View {
        CacheInspectorRowAsync(userdata: userdata, symbol: symbol)
    }

    /// Get color for cache status display
    private func cacheStatusColor(for status: CacheStatus) -> Color {
        switch status {
        case .fresh:
            return .green
        case .stale:
            return .orange
        case .expired:
            return .red
        case .failedRecently, .readyToRetry:
            return .orange
        case .suspended:
            return .red
        case .neverFetched:
            return .secondary
        }
    }

    /// Clear all cached data and force refresh
    private func clearAllCaches() {
        Task {
            await Logger.shared.info("🗑️ [Debug] Clearing all caches (user requested)")

            // Clear cache coordinator
            await userdata.cacheCoordinator.clearAllCache()

            // Clear historical data manager cache if needed
            // userdata.historicalDataManager.clearCaches() // Uncomment if available

            // Force immediate refresh of anything now uncached
            await userdata.refreshCriticalSymbols(reason: "cache-reset")

            await Logger.shared.info("✅ [Debug] All caches cleared and data refreshed")
        }
    }

    /// Export comprehensive debug report
    private func exportDebugReport() {
        Task {
            debugReportStatus = "Generating report..."
            await Logger.shared.info("📋 [Debug] Generating debug report")

            do {
                // Create export directory
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let exportFolder = documentsPath.appendingPathComponent("Stockbar_Debug_\(Int(Date().timeIntervalSince1970))")
                try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)

                // 1. Export current configuration
                // Get cache statistics and stock details asynchronously
                let cacheStats = await userdata.cacheCoordinator.getCacheStatistics()
                var stockDetails: [String] = []
                for trade in userdata.realTimeTrades {
                    let status = await userdata.cacheCoordinator.getCacheStatus(for: trade.trade.name, at: Date())
                    stockDetails.append("\(trade.trade.name): \(status.description)")
                }

                let configText = """
                === Stockbar Debug Report ===
                Generated: \(Date())

                === Configuration ===
                Preferred Currency: \(userdata.preferredCurrency)
                Refresh Interval: \(userdata.refreshInterval)s
                Color Coding: \(userdata.showColorCoding ? "Enabled" : "Disabled")
                Portfolio Size: \(userdata.realTimeTrades.count) stocks

                === Cache Statistics ===
                \(cacheStats.description)

                === Stock Details ===
                \(stockDetails.joined(separator: "\n"))

                === Portfolio Summary ===
                Total Stocks: \(userdata.realTimeTrades.count)
                Net Gains: \(userdata.calculateNetGains().currency) \(String(format: "%.2f", userdata.calculateNetGains().amount))
                Total Value: \(userdata.calculateNetValue().currency) \(String(format: "%.2f", userdata.calculateNetValue().amount))
                """

                let configFile = exportFolder.appendingPathComponent("configuration.txt")
                try configText.write(to: configFile, atomically: true, encoding: .utf8)

                // 2. Copy log file if it exists
                let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/stockbar.log")
                if FileManager.default.fileExists(atPath: logPath.path) {
                    let logDestination = exportFolder.appendingPathComponent("stockbar.log")
                    try FileManager.default.copyItem(at: logPath, to: logDestination)
                }

                // 3. Export portfolio data
                if let tradesData = try? JSONEncoder().encode(userdata.realTimeTrades.map { $0.trade }) {
                    let portfolioFile = exportFolder.appendingPathComponent("portfolio.json")
                    try tradesData.write(to: portfolioFile)
                }

                debugReportStatus = "✅ Exported to: \(exportFolder.lastPathComponent)"
                await Logger.shared.info("✅ [Debug] Debug report exported successfully")

                // Open the export folder in Finder
                NSWorkspace.shared.open(exportFolder)

            } catch {
                debugReportStatus = "❌ Export failed: \(error.localizedDescription)"
                await Logger.shared.error("❌ [Debug] Debug report export failed: \(error)")
            }
        }
    }
}

/// Helper view to handle async cache status fetching
private struct CacheInspectorRowAsync: View {
    let userdata: DataModel
    let symbol: String
    @State private var cacheStatus: CacheStatus?

    var body: some View {
        Group {
            if let cacheStatus = cacheStatus {
                cacheInspectorRowContent(cacheStatus: cacheStatus)
            } else {
                ProgressView()
                    .onAppear {
                        Task {
                            cacheStatus = await userdata.cacheCoordinator.getCacheStatus(for: symbol, at: Date())
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func cacheInspectorRowContent(cacheStatus: CacheStatus) -> some View {

        HStack {
            Text(symbol)
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)

            Text(cacheStatus.description)
                .font(.caption2)
                .foregroundColor(cacheStatusColor(for: cacheStatus))

            Spacer()

            // Show retry button for suspended or failed symbols
            if case .suspended = cacheStatus {
                Button("Retry Now") {
                    Task {
                        await userdata.cacheCoordinator.clearSuspension(for: symbol)
                        await userdata.refreshSymbolsImmediately([symbol], reason: "manual-retry")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }

    private func cacheStatusColor(for status: CacheStatus) -> Color {
        switch status {
        case .fresh:
            return .green
        case .stale:
            return .orange
        case .expired:
            return .red
        case .failedRecently, .readyToRetry:
            return .orange
        case .suspended:
            return .red
        case .neverFetched:
            return .secondary
        }
    }
}

enum PreferenceTab {
    case portfolio
    case charts
    case risk
    case analytics
    case debug
    case dataSources
}

struct DebugLogView: View {
    @State private var logEntries: [String] = []
    @State private var logFilePath: String = ""
    @AppStorage("debugLogAutoRefresh") private var isAutoRefresh: Bool = true
    @AppStorage("debugLogMaxLines") private var maxLines: Int = 500
    @AppStorage("debugLogTailMode") private var useTailMode: Bool = false
    private let logger = Logger.shared
    // CRITICAL FIX: Use @State for timer to ensure proper cleanup
    @State private var timerCancellable: AnyCancellable?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with controls - compact layout
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Debug Logs")
                        .font(.headline)
                    Text(useTailMode ? "(Tail Mode)" : "(Scrollable)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 8) {
                    Toggle("Auto Refresh", isOn: $isAutoRefresh)
                        .toggleStyle(SwitchToggleStyle())
                    
                    Toggle("Tail Mode", isOn: $useTailMode)
                        .toggleStyle(SwitchToggleStyle())
                        .help("Use tail mode for very large log files")
                    
                    Stepper("Max Lines: \(maxLines)", value: $maxLines, in: 100...2000, step: 100)
                        .frame(width: 140)
                    
                    Button("Refresh") {
                        refreshLogs()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Clear Logs") {
                        clearLogs()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                }
            }
            
            // Log file path info - compact
            if !logFilePath.isEmpty {
                HStack {
                    Text("Log File:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(logFilePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            // Log display - full width
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logEntries.reversed().enumerated()), id: \.offset) { index, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(colorForLogEntry(entry))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(index % 2 == 0 ? Color.clear : Color(NSColor.controlBackgroundColor).opacity(0.3))
                                .id(index)
                        }
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(Color(NSColor.separatorColor))
                .onChange(of: logEntries.count) { _, _ in
                    // Auto-scroll to top when new logs are added (newest logs are now at top)
                    if !logEntries.isEmpty {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(0, anchor: .top)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear {
            refreshLogs()
            Task {
                let path = await logger.getLogFilePath() ?? ""
                await MainActor.run {
                    logFilePath = path
                }
            }
        }
        .onAppear {
            // CRITICAL FIX: Start timer with proper cleanup
            startAutoRefreshTimer()
        }
        .onDisappear {
            // CRITICAL FIX: Stop timer to prevent memory leaks
            stopAutoRefreshTimer()
        }
        .onChange(of: isAutoRefresh) { _, newValue in
            if newValue {
                startAutoRefreshTimer()
            } else {
                stopAutoRefreshTimer()
            }
        }
        .onChange(of: useTailMode) { _, _ in
            refreshLogs()
        }
    }
    
    private func refreshLogs() {
        Task {
            let logs: [String]
            if useTailMode {
                logs = await logger.getTailLogs(maxLines: min(maxLines, 500)) // Limit tail mode to 500 lines max
            } else {
                logs = await logger.getRecentLogs(maxLines: maxLines)
            }
            
            await MainActor.run {
                logEntries = logs
            }
        }
    }
    
    private func clearLogs() {
        Task {
            await logger.clearLogs()
            await MainActor.run {
                logEntries = []
            }
            await logger.info("Debug logs cleared by user")
        }
    }
    
    private func colorForLogEntry(_ entry: String) -> Color {
        if entry.contains("[ERROR]") {
            return .red
        } else if entry.contains("[WARNING]") {
            return .orange
        } else if entry.contains("[INFO]") {
            return .blue
        } else if entry.contains("[DEBUG]") {
            return .gray
        } else {
            return .primary
        }
    }
    
    // CRITICAL FIX: Proper timer lifecycle management to prevent memory leaks
    private func startAutoRefreshTimer() {
        stopAutoRefreshTimer() // Stop any existing timer first
        
        timerCancellable = Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if isAutoRefresh {
                    refreshLogs()
                }
            }
    }
    
    private func stopAutoRefreshTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }
}

// MARK: - Restore Backup View

struct RestoreBackupView: View {
    @Binding var isPresented: Bool
    @ObservedObject var dataModel: DataModel
    @State private var availableBackups: [BackupInfo] = []
    @State private var selectedBackup: BackupInfo?
    @State private var previewData: [PortfolioExportData] = []
    @State private var showingPreview = false
    @State private var showingConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Restore from Backup")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    isPresented = false
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Backup list
            if availableBackups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No backups available")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text("Backups will appear here after you create them")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(availableBackups) { backup in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.filename)
                                .font(.body)
                            Text(backup.formattedDate)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(backup.formattedSize)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Preview") {
                            previewBackup(backup)
                        }
                        .buttonStyle(.bordered)

                        Button("Restore") {
                            selectedBackup = backup
                            showingConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 600, height: 400)
        .onAppear {
            loadAvailableBackups()
        }
        .sheet(isPresented: $showingPreview) {
            if !previewData.isEmpty {
                BackupPreviewView(stocks: previewData, isPresented: $showingPreview)
            }
        }
        .alert("Confirm Restore", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                performRestore()
            }
        } message: {
            Text("This will replace your current portfolio with the backup. This action cannot be undone. Current portfolio will be backed up first.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    private func loadAvailableBackups() {
        availableBackups = BackupService.shared.listAvailableBackups()
    }

    private func previewBackup(_ backup: BackupInfo) {
        do {
            previewData = try BackupService.shared.previewBackup(backupURL: backup.url)
            showingPreview = true
        } catch {
            errorMessage = "Failed to preview backup: \(error.localizedDescription)"
            showingError = true
        }
    }

    private func performRestore() {
        guard let backup = selectedBackup else { return }

        Task {
            do {
                // Backup current portfolio first
                _ = await BackupService.shared.performManualBackup(trades: dataModel.realTimeTrades)

                // Restore from backup
                let restoredTrades = try await BackupService.shared.restoreFromBackup(backupURL: backup.url)

                await MainActor.run {
                    // Clear existing trades
                    dataModel.realTimeTrades.removeAll()

                    // Add restored trades
                    for trade in restoredTrades {
                        let emptyTradingInfo = TradingInfo()
                        let realTimeTrade = RealTimeTrade(trade: trade, realTimeInfo: emptyTradingInfo)
                        dataModel.realTimeTrades.append(realTimeTrade)
                    }

                    // Close the sheet
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to restore backup: \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
}

// MARK: - Backup Preview View

struct BackupPreviewView: View {
    let stocks: [PortfolioExportData]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Backup Preview")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    isPresented = false
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Stock list
            List(stocks, id: \.symbol) { stock in
                HStack {
                    Text(stock.symbol)
                        .frame(width: 100, alignment: .leading)
                    Text("\(String(format: "%.2f", stock.units)) units")
                        .frame(width: 120, alignment: .leading)
                    Text("@ \(stock.costCurrency ?? "USD") \(String(format: "%.2f", stock.avgPositionCost))")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .listStyle(.plain)

            Divider()

            // Footer
            HStack {
                Text("\(stocks.count) stocks in this backup")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }
}

struct PreferenceView_Previews: PreviewProvider {
    static var previews: some View {
        PreferenceView(userdata: DataModel())
    }
}
