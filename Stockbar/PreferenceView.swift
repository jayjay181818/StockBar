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
    static let contentSizeChanged = Notification.Name("contentSizeChanged")
    static let forceWindowResize = Notification.Name("forceWindowResize")
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
        .frame(minWidth: 400, idealWidth: 500) // Ensure adequate width for the row
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
                .padding(.horizontal)
                .padding(.vertical, 8)
                .onChange(of: selectedTab) { _, newTab in
                    adjustWindowForTab(newTab, forceResize: true)
                }
                
                // Separator line for visual clarity
                Divider()
                    .padding(.horizontal)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .frame(minHeight: 60, maxHeight: 60) // Fixed height for navigation
            
            // Scrollable tab content area
            ScrollView {
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
            .frame(minHeight: 300) // Ensure minimum content area
        }
        .frame(minWidth: 650, idealWidth: 800, maxWidth: 1400, minHeight: 400) // More flexible width handling
        .onReceive(NotificationCenter.default.publisher(for: .forceWindowResize)) { _ in
            // Handle forced window resize requests from child views
            adjustWindowForTab(selectedTab, forceResize: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentSizeChanged)) { notification in
            // Handle content size changes, including horizontal scaling needs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Check if this is a width-related change
                let forceResize = notification.object as? Bool ?? false
                adjustWindowForTab(selectedTab, forceResize: forceResize)
            }
        }
    }
    
    private func adjustWindowForTab(_ tab: PreferenceTab, forceResize: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Small delay to let content render
            self.performWindowResize(for: tab, forceResize: forceResize)
        }
    }
    
    private func performWindowResize(for tab: PreferenceTab, forceResize: Bool = false) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Stockbar Preferences" }) else {
            return
        }
        
        let currentFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? currentFrame
        
        // Calculate content dimensions more intelligently
        let (targetWidth, targetHeight) = calculateOptimalDimensions(for: tab)
        
        // Check if window has been manually maximized or significantly enlarged by user
        let isLikelyMaximized = currentFrame.height > screenFrame.height * 0.8 || 
                               currentFrame.width > screenFrame.width * 0.8
        
        // Ensure we don't exceed screen bounds
        let maxAvailableHeight = screenFrame.height * 0.9
        let maxAvailableWidth = screenFrame.width * 0.8
        
        // Smart resizing logic that handles both horizontal and vertical scaling
        let finalHeight: CGFloat
        let finalWidth: CGFloat
        
        // Check if content requires more width than current window
        let needsMoreWidth = targetWidth > currentFrame.width + 30 // 30px threshold
        let needsMoreHeight = targetHeight > currentFrame.height + 30 // 30px threshold
        
        if isLikelyMaximized && !forceResize {
            // Preserve user's manual sizing, but grow if content absolutely requires it
            let minRequiredHeight: CGFloat = 350 // Minimum for navigation + some content
            let minRequiredWidth: CGFloat = 650  // Minimum for content readability
            
            // Only grow the window if content truly needs more space
            finalHeight = needsMoreHeight ? min(targetHeight, maxAvailableHeight) : max(currentFrame.height, minRequiredHeight)
            finalWidth = needsMoreWidth ? min(targetWidth, maxAvailableWidth) : max(currentFrame.width, minRequiredWidth)
        } else {
            // Normal auto-resize behavior for both dimensions
            finalHeight = min(targetHeight, maxAvailableHeight)
            finalWidth = min(targetWidth, maxAvailableWidth)
        }
        
        // Be more sensitive to size changes for better responsiveness
        let heightDifference = abs(currentFrame.height - finalHeight)
        let widthDifference = abs(currentFrame.width - finalWidth)
        
        // More responsive resize logic that handles horizontal scaling better
        let shouldResizeHeight = forceResize || heightDifference > 20
        let shouldResizeWidth = forceResize || widthDifference > 30
        
        // For maximized windows, only resize if growing or forced
        let shouldResize = if isLikelyMaximized && !forceResize {
            (shouldResizeHeight && finalHeight > currentFrame.height) ||
            (shouldResizeWidth && finalWidth > currentFrame.width)
        } else {
            // For normal windows, resize more freely
            shouldResizeHeight || shouldResizeWidth
        }
        
        if shouldResize {
            // Calculate new origin to keep window centered or prevent off-screen movement
            let newX = max(screenFrame.minX, min(currentFrame.origin.x, screenFrame.maxX - finalWidth))
            var newY = currentFrame.origin.y - (finalHeight - currentFrame.height) // Expand downward
            
            // Ensure window doesn't go off screen
            if newY < screenFrame.minY {
                newY = screenFrame.minY
            } else if newY + finalHeight > screenFrame.maxY {
                newY = screenFrame.maxY - finalHeight
            }
            
            let newFrame = NSRect(
                x: newX,
                y: newY,
                width: finalWidth,
                height: finalHeight
            )
            
            window.setFrame(newFrame, display: true, animate: true)
        }
    }
    
    private func calculateOptimalDimensions(for tab: PreferenceTab) -> (width: CGFloat, height: CGFloat) {
        // CRITICAL: Always ensure navigation is visible
        let navigationHeight: CGFloat = 60   // Tab picker area
        let windowChromeHeight: CGFloat = 40  // Window title bar and padding
        let safetyPadding: CGFloat = 20       // Extra safety margin
        let baseRequiredHeight = navigationHeight + windowChromeHeight + safetyPadding
        
        let minWidth: CGFloat = 650
        let maxWidth: CGFloat = 1200  // Increased maximum width
        
        var contentHeight: CGFloat
        var contentWidth: CGFloat = minWidth
        
        switch tab {
        case .portfolio:
            // Portfolio content calculations
            let tradesCount = max(1, userdata.realTimeTrades.count)
            let tradingSymbolsHeight = CGFloat(tradesCount * 30 + 80) // Row height + headers
            let toggleHeight: CGFloat = 40
            let currencyPickerHeight: CGFloat = 50
            let netGainsHeight: CGFloat = 60
            let apiKeySectionHeight: CGFloat = 220 // API key section is fairly large
            let historicalDataSectionHeight: CGFloat = 160 // Historical data controls
            let exchangeRatesHeight: CGFloat = 40
            
            contentHeight = tradingSymbolsHeight + toggleHeight + currencyPickerHeight + 
                           netGainsHeight + apiKeySectionHeight + historicalDataSectionHeight + exchangeRatesHeight
            
            // Portfolio needs more width for the trade entry fields - be more generous
            let basePortfolioWidth: CGFloat = 800
            let extraWidthForTrades = CGFloat(max(0, tradesCount - 3) * 20) // Extra width for more trades
            contentWidth = max(minWidth, min(maxWidth, basePortfolioWidth + extraWidthForTrades))
            
        case .charts:
            // Charts need substantial space for proper display
            let chartDisplayHeight: CGFloat = 280 // Main chart area
            let pickerControlsHeight: CGFloat = 80 // Chart type and time range pickers
            let progressIndicatorHeight: CGFloat = 60 // Progress/error indicators when visible
            let metricsHeight: CGFloat = 140 // Performance metrics (expanded state)
            let returnAnalysisHeight: CGFloat = 180 // Return analysis section
            let exportFiltersHeight: CGFloat = 100 // Export and filter sections
            
            contentHeight = chartDisplayHeight + pickerControlsHeight + progressIndicatorHeight + 
                           metricsHeight + returnAnalysisHeight + exportFiltersHeight
            
            // Charts need significant width for proper display - more generous
            contentWidth = max(minWidth, min(maxWidth, 1000))
            
        case .debug:
            // Debug needs good dimensions for log readability
            let debugControlsHeight: CGFloat = 120 // Frequency controls
            let debugActionsHeight: CGFloat = 100 // Debug action buttons
            let logDisplayHeight: CGFloat = 350 // Main log display area
            
            contentHeight = debugControlsHeight + debugActionsHeight + logDisplayHeight
            
            // Debug logs benefit from much wider display for readability
            contentWidth = max(minWidth, min(maxWidth, 950))
        }
        
        let totalHeight = baseRequiredHeight + contentHeight
        let minHeight: CGFloat = 400  // Absolute minimum
        let maxHeight: CGFloat = 900  // Reasonable maximum for auto-sizing
        
        return (width: contentWidth, height: max(minHeight, min(maxHeight, totalHeight)))
    }
    
    private var portfolioView: some View {
        VStack {
            HStack {
                Toggle("Color Coding", isOn: $userdata.showColorCoding)
                    .padding(.bottom, 10)
                Spacer()
            }
            .onAppear {
                adjustWindowForTab(.portfolio)
            }
            .onChange(of: userdata.realTimeTrades.count) { _, _ in
                // Adjust window when number of trades changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    adjustWindowForTab(.portfolio, forceResize: true)
                }
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
            .padding(.bottom, 10)
            
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
                    
                    Button("Paste") {
                        if let clipboardString = NSPasteboard.general.string(forType: .string) {
                            apiKey = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .help("Paste API key from clipboard")
                    
                    Button("Save") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button("Test") {
                        testAPIKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
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
                        
                        Button("Clear Bad Data") {
                            clearBadHistoricalData()
                        }
                        .help("Clears corrupted historical data for UK stocks (RR.L, etc.)")
                        
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
                        
                        Button("Calculate 5Y Portfolio Values") {
                            calculate5YearPortfolioValues()
                        }
                        .disabled(isBackfillingData)
                        .foregroundColor(.green)
                        .help("Calculate 5 years of portfolio values for charts using existing price data")
                    }
                    
                    if !backfillStatus.isEmpty {
                        Text(backfillStatus)
                            .font(.caption)
                            .foregroundColor(backfillStatus.contains("Error") ? .red : .blue)
                            .onAppear {
                                // Status text appearance may change layout
                                NotificationCenter.default.post(name: .contentSizeChanged, object: nil)
                            }
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
            ForEach(userdata.realTimeTrades) { item in
                HStack {
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
            }
        }
        .padding()
        .alert("API Key", isPresented: $showingAPIKeyAlert) {
            Button("OK") { }
        } message: {
            Text(apiKeyAlertMessage)
        }
    }
    
    private var chartsView: some View {
        PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
            .onAppear {
                // Ensure window is properly sized when charts first appear
                adjustWindowForTab(.charts, forceResize: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chartMetricsToggled)) { _ in
                // Re-adjust window size when chart metrics are toggled
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    adjustWindowForTab(.charts, forceResize: true)
                }
            }
    }
    
    private var debugView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Compact controls section - not in ScrollView to stay visible
            VStack(alignment: .leading, spacing: 12) {
                // Refresh Frequency Controls (condensed)
                debugFrequencyControls
                
                Divider()
                
                // Debug Actions (condensed)
                debugActions
            }
            .padding(.horizontal)
            .padding(.top)
            
            Divider()
            
            // Debug Logs in their own scroll area
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Debug Logs")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text("(Scrollable)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
                DebugLogView()
                    .frame(minHeight: 200, maxHeight: 500) // Constrained but flexible
                    .clipped()
            }
        }
        .onAppear {
            adjustWindowForTab(.debug, forceResize: true)
            // Initialize state variables with current values
            currentRefreshInterval = userdata.refreshInterval
            currentCacheInterval = userdata.cacheInterval
            currentSnapshotInterval = HistoricalDataManager.shared.getSnapshotInterval()
        }
    }
    
    private var debugFrequencyControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Refresh Frequency Controls")
                .font(.headline)
                .foregroundColor(.primary)
            
            // Refresh Interval
            HStack {
                Text("Main Refresh Interval (how often stock prices update):")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Picker("", selection: $currentRefreshInterval) {
                    ForEach(refreshIntervalOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .onChange(of: currentRefreshInterval) { _, newValue in
                    setRefreshInterval(newValue)
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 100)
            }
            
            // Cache Interval
            HStack {
                Text("Cache Duration (how long to keep data before re-fetching):")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Picker("", selection: $currentCacheInterval) {
                    ForEach(cacheIntervalOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .onChange(of: currentCacheInterval) { _, newValue in
                    setCacheInterval(newValue)
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 100)
            }
            
            // Snapshot Interval
            HStack {
                Text("Chart Data Collection Interval (how often to save data for charts):")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Picker("", selection: $currentSnapshotInterval) {
                    ForEach(snapshotIntervalOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .onChange(of: currentSnapshotInterval) { _, newValue in
                    setSnapshotInterval(newValue)
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 100)
            }
        }
    }
    
    private var debugActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug Actions")
                .font(.headline)
                .foregroundColor(.primary)
            
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button("Force Snapshot") {
                        forceDataSnapshot()
                    }
                    .buttonStyle(.bordered)
                    .help("Manually trigger a data snapshot for charts")
                    
                    Button("Clear Historical Data") {
                        clearHistoricalData()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .help("Delete all historical price data and charts")
                    
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .buttonStyle(.bordered)
                    .help("Reset all frequency settings to default values")
                    
                    Spacer()
                }
                
                HStack(spacing: 16) {
                    Button("Fetch 5 Years Historical Data") {
                        fetch5YearsHistoricalData()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.blue)
                    .help("Fetch 5 years of historical data in yearly chunks (avoids hanging)")
                    
                    Button("Show Automatic Check Status") {
                        showAutomaticCheckStatus()
                    }
                    .buttonStyle(.bordered)
                    .help("Shows status of automatic historical data checking")
                    
                    Button("Calculate 5Y Portfolio Values") {
                        calculate5YearPortfolioValuesDebug()
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)
                    .help("Calculate 5 years of portfolio values for charts using existing price data")
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Debug Interval Options
    
    private let refreshIntervalOptions: [(String, TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("15 minutes (default)", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600)
    ]
    
    private let cacheIntervalOptions: [(String, TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes (default)", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600)
    ]
    
    private let snapshotIntervalOptions: [(String, TimeInterval)] = [
        ("5 seconds", 5),
        ("10 seconds", 10),
        ("30 seconds (default)", 30),
        ("1 minute", 60),
        ("5 minutes", 300)
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
        Logger.shared.info("🔧 Debug: Refresh interval changed to \(interval) seconds")
        
        // Notify the menu bar controller to restart its timer
        NotificationCenter.default.post(name: .refreshIntervalChanged, object: interval)
    }
    
    private func setCacheInterval(_ interval: TimeInterval) {
        userdata.cacheInterval = interval
        Logger.shared.info("🔧 Debug: Cache interval changed to \(interval) seconds")
    }
    
    private func setSnapshotInterval(_ interval: TimeInterval) {
        HistoricalDataManager.shared.setSnapshotInterval(interval)
        Logger.shared.info("🔧 Debug: Snapshot interval changed to \(interval) seconds")
    }
    
    private func forceDataSnapshot() {
        HistoricalDataManager.shared.forceSnapshot(from: userdata)
        Logger.shared.info("🔧 Debug: Forced data snapshot")
    }
    
    private func clearHistoricalData() {
        HistoricalDataManager.shared.clearAllData()
        Logger.shared.info("🔧 Debug: Cleared all historical data")
    }
    
    private func fetch5YearsHistoricalData() {
        Task {
            Logger.shared.info("🔧 Debug: Starting 5-year historical data fetch")
            await userdata.triggerFullHistoricalBackfill()
            Logger.shared.info("🔧 Debug: 5-year historical data fetch completed")
        }
    }
    
    private func resetToDefaults() {
        userdata.refreshInterval = 900  // 15 minutes
        userdata.cacheInterval = 900    // 15 minutes
        HistoricalDataManager.shared.setSnapshotInterval(30)  // 30 seconds
        
        // Update state variables to reflect the reset
        currentRefreshInterval = 900
        currentCacheInterval = 900
        currentSnapshotInterval = 30
        
        Logger.shared.info("🔧 Debug: Reset all intervals to defaults")
        
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
                        print("DEBUG: \(symbol) has only \(uniqueDays.count) unique days of data, needs backfill")
                    } else {
                        print("DEBUG: \(symbol) has \(uniqueDays.count) unique days of data, sufficient")
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
            Logger.shared.info("🔧 Debug: Starting 5-year portfolio value calculation")
            await userdata.calculate5YearPortfolioValues()
            Logger.shared.info("🔧 Debug: 5-year portfolio value calculation completed")
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
    @State private var isAutoRefresh = true
    @State private var maxLines = 500
    private let logger = Logger.shared
    private let timer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12) {
            // Header with controls
            HStack {
                Text("Debug Logs")
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 12) {
                    Toggle("Auto Refresh", isOn: $isAutoRefresh)
                        .toggleStyle(SwitchToggleStyle())
                    
                    Stepper("Max Lines: \(maxLines)", value: $maxLines, in: 100...2000, step: 100)
                        .frame(width: 150)
                    
                    Button("Refresh") {
                        refreshLogs()
                    }
                    
                    Button("Clear Logs") {
                        clearLogs()
                    }
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            
            // Log file path info
            if let logPath = logger.getLogFilePath() {
                HStack {
                    Text("Log File:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(logPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal)
            }
            
            // Log display
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logEntries.reversed().enumerated()), id: \.offset) { index, entry in
                            HStack {
                                Text(entry)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(colorForLogEntry(entry))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
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
        .padding()
        .onAppear {
            refreshLogs()
        }
        .onReceive(timer) { _ in
            if isAutoRefresh {
                refreshLogs()
            }
        }
    }
    
    private func refreshLogs() {
        logEntries = logger.getRecentLogs(maxLines: maxLines)
    }
    
    private func clearLogs() {
        logger.clearLogs()
        logEntries = []
        logger.info("Debug logs cleared by user")
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
