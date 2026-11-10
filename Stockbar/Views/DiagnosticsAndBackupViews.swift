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
    private let logger = Logger.shared
    // CRITICAL FIX: Use @State for timer to ensure proper cleanup
    @State private var timerCancellable: AnyCancellable?
    @State private var confirmingClear = false
    @State private var exportErrorMessage: String?
    /// True while the newest entry (the top of the list) is in view. New logs only pull the
    /// view back to the top when the reader is already there.
    @State private var isScrolledToTop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with controls - compact layout
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Toggle("Auto Refresh", isOn: $isAutoRefresh)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Stepper("Max Lines: \(maxLines)", value: $maxLines, in: 100...2000, step: 100)
                        .fixedSize()

                    Spacer()

                    Button {
                        refreshLogs()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        exportLogs(thenClear: false)
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .help("Save a copy of the log file")

                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
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
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StockbarPalette.cardStroke, lineWidth: 1)
                )
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y <= geometry.contentInsets.top + 8
                } action: { _, atTop in
                    isScrolledToTop = atTop
                }
                .onChange(of: logEntries.count) { _, _ in
                    // Newest logs are at the top. Follow them only if the reader is already
                    // there; otherwise leave the scroll position alone.
                    if isScrolledToTop, !logEntries.isEmpty {
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
        .onChange(of: maxLines) { _, _ in
            refreshLogs()
        }
        .confirmationDialog("Clear all logs?", isPresented: $confirmingClear) {
            Button("Export Logs, Then Clear…") { exportLogs(thenClear: true) }
            Button("Clear Without Exporting", role: .destructive) { clearLogs() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clearing permanently deletes the diagnostic log. Export a copy first if you may need it to investigate a problem.")
        }
        .alert("Couldn't export logs", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    /// Saves a copy of the log file where the user chooses. With `thenClear`,
    /// the log is cleared afterwards, and only if the copy was written.
    private func exportLogs(thenClear: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "stockbar-logs-\(DebugLogView.exportTimestamp()).log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    let sourcePath = await logger.getLogFilePath()
                    let fallback = logEntries.joined(separator: "\n")
                    try await Task.detached {
                        let data: Data
                        if let sourcePath, FileManager.default.fileExists(atPath: sourcePath) {
                            data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
                        } else {
                            data = Data(fallback.utf8)
                        }
                        try data.write(to: destination, options: .atomic)
                    }.value
                    if thenClear { clearLogs() }
                } catch {
                    exportErrorMessage = thenClear
                        ? "\(error.localizedDescription) The logs were not cleared."
                        : error.localizedDescription
                }
            }
        }
    }

    private static func exportTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
    
    private func refreshLogs() {
        Task {
            // Always read from the end of the file, for as many lines as asked.
            // "Tail Mode" used to cap this at 500 whatever Max Lines said.
            let logs = await logger.getRecentLogs(maxLines: maxLines)

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
    let dataModel: DataModel
    @State private var availableBackups: [BackupInfo] = []
    @State private var selectedBackup: BackupInfo?
    @State private var preview: BackupPreviewPayload?
    @State private var showingConfirmation = false
    @State private var isRestoring = false
    @State private var restoreResult: String?
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Restore from Backup")
                    .font(.headline)
                Spacer()
                if isRestoring {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Restoring backup")
                }
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRestoring)
            }
            .padding()
            .background(StockbarPalette.sheetHeaderFill)

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
                        .disabled(isRestoring)

                        Button("Restore") {
                            selectedBackup = backup
                            showingConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .disabled(dataModel.isFolyncPortfolioActive || isRestoring)
                        .help(dataModel.isFolyncPortfolioActive
                              ? "Folync is providing the portfolio. Switch to the local portfolio before restoring."
                              : "Replace the current portfolio with this backup")
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
        // Presented from the loaded contents themselves, so the sheet can never
        // open before they are there and show an empty window.
        .sheet(item: $preview) { payload in
            BackupPreviewView(stocks: payload.stocks, isPresented: Binding(
                get: { preview != nil },
                set: { if !$0 { preview = nil } }
            ))
        }
        .alert("Confirm Restore", isPresented: $showingConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                performRestore()
            }
        } message: {
            Text("This replaces your current portfolio with the backup. A copy of the current portfolio is saved first, so you can restore that one if you change your mind.")
        }
        .alert("Portfolio Restored", isPresented: Binding(
            get: { restoreResult != nil },
            set: { if !$0 { restoreResult = nil } }
        )) {
            Button("OK") { isPresented = false }
        } message: {
            Text(restoreResult ?? "")
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
            let stocks = try BackupService.shared.previewBackup(backupURL: backup.url)
            guard !stocks.isEmpty else {
                errorMessage = "This backup has no holdings in it."
                showingError = true
                return
            }
            preview = BackupPreviewPayload(stocks: stocks)
        } catch {
            errorMessage = "Failed to preview backup: \(error.localizedDescription)"
            showingError = true
        }
    }

    private func performRestore() {
        guard let backup = selectedBackup, !isRestoring else { return }

        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                // Read the chosen backup first, so a bad file changes nothing.
                let restoredTrades = try await BackupService.shared.restoreFromBackup(backupURL: backup.url)

                // Then keep a copy of the current portfolio. Its cleanup never
                // deletes the backup being restored, and a failed copy stops the
                // restore rather than replacing holdings with no way back.
                let current = dataModel.localPortfolioTradesForBackup
                let safetyCopied = await BackupService.shared.performPreRestoreBackup(trades: current, keeping: backup.url)
                if !safetyCopied {
                    throw BackupRestoreSafetyError.safetyBackupFailed
                }

                try await dataModel.replacePortfolioTrades(restoredTrades, source: "backup-restore")

                let count = restoredTrades.count
                await MainActor.run {
                    // Say what happened; OK then closes the sheet.
                    restoreResult = "Restored \(count) \(count == 1 ? "holding" : "holdings") from \(backup.filename)."
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
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(StockbarPalette.sheetHeaderFill)

            Divider()

            // Stock list
            List(stocks, id: \.symbol) { stock in
                HStack {
                    Text(stock.symbol)
                        .frame(width: 100, alignment: .leading)
                    Text("\(BackupPreviewFormat.units(stock.units)) units")
                        .frame(width: 140, alignment: .leading)
                    Text("@ \(BackupPreviewFormat.cost(stock.avgPositionCost, currency: stock.costCurrency))")
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

/// The holdings read from one backup, for the preview sheet.
private struct BackupPreviewPayload: Identifiable {
    let id = UUID()
    let stocks: [PortfolioExportData]
}

private enum BackupRestoreSafetyError: LocalizedError {
    case safetyBackupFailed

    var errorDescription: String? {
        "Stockbar could not save a copy of your current portfolio first, so nothing was restored. Check the backup folder is writable and try again."
    }
}

/// Number formats for the restore preview: fractional shares and sub-penny costs are shown in
/// full rather than rounded to two decimals, and missing values are a dash.
enum BackupPreviewFormat {
    static func units(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        return MenuPopoverFormatter.units(value, locale: locale)
    }

    static func cost(_ value: Double, currency: String?, locale: Locale = .current) -> String {
        guard value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // No currency recorded: the bare number, not a guess at dollars.
        return code.isEmpty ? number : "\(code) \(number)"
    }
}
