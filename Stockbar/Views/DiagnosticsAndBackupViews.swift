//
//  DiagnosticsAndBackupViews.swift
//  StockBar
//
//  Diagnostics log viewer and backup restore/preview sheets, used by
//  StockbarMainView and StockbarSettingsView. Extracted from the retired
//  PreferenceView.swift.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DebugLogView: View {
    @State private var logEntries: [String] = []
    @State private var logFilePath: String = ""
    @AppStorage("debugLogAutoRefresh", store: StockbarRuntimeStorage.userDefaults) private var isAutoRefresh: Bool = true
    @AppStorage("debugLogMaxLines", store: StockbarRuntimeStorage.userDefaults) private var maxLines: Int = 500
    @AppStorage("debugLogTailMode", store: StockbarRuntimeStorage.userDefaults) private var useTailMode: Bool = false
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
                try await dataModel.replacePortfolioTrades(restoredTrades, source: "backup-restore")

                await MainActor.run {
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
