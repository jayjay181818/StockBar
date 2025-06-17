//
//  PreferenceView.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Combine
import SwiftUI

extension Notification.Name {
    static let chartMetricsToggled = Notification.Name("chartMetricsToggled")
    static let refreshIntervalChanged = Notification.Name("refreshIntervalChanged")
}

struct PreferenceRow: View {
    @ObservedObject var realTimeTrade: RealTimeTrade
    @State private var showCurrencyPicker = false
    
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
    
    var body: some View {
        HStack(spacing: 8) {
            // Symbol field - flexible width
            TextField("symbol", text: self.$realTimeTrade.trade.name)
                .frame(minWidth: 60, idealWidth: 80, maxWidth: 120)
                .onChange(of: realTimeTrade.trade.name) { _, newValue in
                    // Auto-detect currency when symbol changes
                    if realTimeTrade.trade.position.costCurrency == nil {
                        let newCurrency = newValue.uppercased().hasSuffix(".L") ? "GBX" : "USD"
                        realTimeTrade.trade.position.costCurrency = newCurrency
                    }
                }
            
            // Units field - moderate width
            TextField("Units", text: self.$realTimeTrade.trade.position.unitSizeString)
                .frame(minWidth: 50, idealWidth: 70, maxWidth: 100)
            
            // Cost and currency field - expandable
            HStack(spacing: 4) {
                TextField("average position cost", text: self.$realTimeTrade.trade.position.positionAvgCostString)
                    .frame(minWidth: 80, idealWidth: 120)
                
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading) // Fill available width efficiently
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
    
    // Debug control state variables
    @State private var currentRefreshInterval: TimeInterval = 900
    @State private var currentCacheInterval: TimeInterval = 900
    @State private var currentSnapshotInterval: TimeInterval = 30

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
            
            // Tab content area - remove ScrollView to let auto-sizing work properly
            Group {
                switch selectedTab {
                case .portfolio:
                    portfolioView
                case .charts:
                    chartsView
                case .debug:
                    debugView
                }
            }
        }
        .padding() // Add some padding around the content
        .frame(minWidth: 650, idealWidth: 1000, maxWidth: 1200,
               minHeight: 500, idealHeight: 700, maxHeight: 900)
        .fixedSize(horizontal: false, vertical: false) // Allow both horizontal and vertical resizing
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
            
            // API Key management section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Financial Modeling Prep API Key:")
                        .font(.headline)
                    Spacer()
                    Button("Get Free API Key") {
                        NSWorkspace.shared.open(URL(string: "https://financialmodelingprep.com/")!)
                    }
                    .foregroundColor(.blue)
                }
                
                HStack {
                    Group {
                        if isAPIKeyVisible {
                            TextField("Enter your FMP API key", text: $apiKey)
                        } else {
                            SecureField("Enter your FMP API key", text: $apiKey)
                        }
                    }
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onAppear {
                        apiKey = configManager.getFMPAPIKey() ?? ""
                    }
                    .help("Paste your FMP API key here. It will be stored securely in your Documents folder.")
                    
                    Button(action: {
                        isAPIKeyVisible.toggle()
                    }) {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .help(isAPIKeyVisible ? "Hide API key" : "Show API key")
                    .buttonStyle(BorderlessButtonStyle())
                    
                    Button("Save & Test") {
                        saveAndTestAPIKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Save API key and test its validity")
                    
                    Button("Clear") {
                        clearAPIKey()
                    }
                    .foregroundColor(.red)
                }
                
                // API key status
                HStack {
                    if let storedKey = configManager.getFMPAPIKey(), !storedKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API key configured")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("API key required for historical data")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    
                    if configManager.configFileExists() {
                        Button("Show Config File") {
                            showConfigFile()
                        }
                        .font(.caption)
                    }
                }
                
                // Historical data backfill section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Historical Data Backfill:")
                            .font(.headline)
                        Spacer()
                        Button(isBackfillingData ? "Backfilling..." : "Check & Fill Missing Data") {
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

            HStack {
                Text("Exchange Rates Updated:")
                Text(formattedTimestamp)
                Button(action: {
                    currencyConverter.refreshRates()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
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
            
            // List for drag-and-drop functionality
            List {
                ForEach(userdata.realTimeTrades) { item in
                    HStack {
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
                        PreferenceRow(realTimeTrade: item)
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert("API Key", isPresented: $showingAPIKeyAlert) {
            Button("OK") { }
        } message: {
            Text(apiKeyAlertMessage)
        }
    }
    
    private var chartsView: some View {
        PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
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
            currentCacheInterval = userdata.cacheInterval
            currentSnapshotInterval = HistoricalDataManager.shared.getSnapshotInterval()
        }
        .onChange(of: selectedTab) { _, newTab in
            // Sync state variables when debug tab is selected
            if newTab == .debug {
                currentRefreshInterval = userdata.refreshInterval
                currentCacheInterval = userdata.cacheInterval
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
            
            // Cache Interval
            VStack(alignment: .leading, spacing: 4) {
                Text("Cache Duration:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Picker("", selection: $currentCacheInterval) {
                        ForEach(cacheIntervalOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .onChange(of: currentCacheInterval) { _, newValue in
                        setCacheInterval(newValue)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 150)
                    
                    Text("(how long to keep data before re-fetching)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
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
                
                HStack(spacing: 12) {
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
    
    private func setCacheInterval(_ interval: TimeInterval) {
        userdata.cacheInterval = interval
        Task { await Logger.shared.info("🔧 Debug: Cache interval changed to \(interval) seconds") }
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
        userdata.cacheInterval = 300    // 5 minutes
        HistoricalDataManager.shared.setSnapshotInterval(300)  // 5 minutes
        
        // Update state variables to reflect the reset
        currentRefreshInterval = 300
        currentCacheInterval = 300
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
    
    private func clearBadHistoricalData() {
        // Clear corrupted data for known problematic UK stocks that had double conversion issues
        let ukSymbolsWithBadData = ["RR.L", "TSCO.L", "BP.L", "LLOY.L", "VOD.L", "AZN.L", "SHEL.L", "GSK.L", "BT-A.L", "NG.L"]
        
        // Filter to only clear symbols that actually exist in our data
        let symbolsToProcess = userdata.realTimeTrades.map { $0.trade.name }.filter { symbol in
            ukSymbolsWithBadData.contains(symbol) || symbol.uppercased().hasSuffix(".L")
        }
        
        if !symbolsToProcess.isEmpty {
            userdata.clearHistoricalDataForSymbols(symbolsToProcess)
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
}

enum PreferenceTab {
    case portfolio
    case charts
    case debug
}

struct DebugLogView: View {
    @State private var logEntries: [String] = []
    @State private var logFilePath: String = ""
    @AppStorage("debugLogAutoRefresh") private var isAutoRefresh: Bool = true
    @AppStorage("debugLogMaxLines") private var maxLines: Int = 500
    @AppStorage("debugLogTailMode") private var useTailMode: Bool = false
    private let logger = Logger.shared
    private let timer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()
    
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
        .onReceive(timer) { _ in
            if isAutoRefresh {
                refreshLogs()
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
}

struct PreferenceView_Previews: PreviewProvider {
    static var previews: some View {
        PreferenceView(userdata: DataModel())
    }
}
