//
//  PreferenceView.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import Combine
import SwiftUI
struct PreferenceRow: View {
    @ObservedObject var realTimeTrade: RealTimeTrade
    var body: some View {
        HStack {
            Spacer()
            TextField( "symbol", text: self.$realTimeTrade.trade.name )
            Spacer()
            TextField( "Units", text: self.$realTimeTrade.trade.position.unitSizeString )
            Spacer()
            TextField( "average position cost", text: self.$realTimeTrade.trade.position.positionAvgCostString )
            Spacer()
        }
    }
}

struct PreferenceView: View {
    @ObservedObject var userdata: DataModel
    private let currencyConverter = CurrencyConverter()
    @State private var selectedTab: PreferenceTab = .portfolio

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
            // Tab picker
            Picker("Preference Tab", selection: $selectedTab) {
                Text("Portfolio").tag(PreferenceTab.portfolio)
                Text("Charts").tag(PreferenceTab.charts)
                Text("Debug").tag(PreferenceTab.debug)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            .onChange(of: selectedTab) { _, newTab in
                adjustWindowForTab(newTab)
            }
            
            // Tab content
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
    }
    
    private func adjustWindowForTab(_ tab: PreferenceTab) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Stockbar Preferences" }) else {
                return
            }
            
            let currentFrame = window.frame
            let targetHeight: CGFloat
            
            switch tab {
            case .portfolio:
                targetHeight = 400 // Base height for portfolio view
            case .charts:
                targetHeight = 700 // Larger height for charts view
            case .debug:
                targetHeight = 600 // Medium height for debug view
            }
            
            // Only resize if the target height is significantly different
            if abs(currentFrame.height - targetHeight) > 50 {
                let newFrame = NSRect(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y - (targetHeight - currentFrame.height), // Adjust y to expand downward
                    width: max(currentFrame.width, 600), // Ensure minimum width
                    height: targetHeight
                )
                
                window.setFrame(newFrame, display: true, animate: true)
            }
        }
    }
    
    private var portfolioView: some View {
        VStack {
            HStack {
                Toggle("Color Coding", isOn: $userdata.showColorCoding)
                    .padding(.bottom, 10)
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
                Text("Avg position cost")
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
    }
    
    private var chartsView: some View {
        PerformanceChartView(availableSymbols: availableSymbols, dataModel: userdata)
            .onAppear {
                // Ensure window is properly sized when charts first appear
                adjustWindowForTab(.charts)
            }
    }
    
    private var debugView: some View {
        DebugLogView()
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
    private let timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
    
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
                        ForEach(Array(logEntries.enumerated()), id: \.offset) { index, entry in
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
                    // Auto-scroll to bottom when new logs are added
                    if !logEntries.isEmpty {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(logEntries.count - 1, anchor: .bottom)
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
