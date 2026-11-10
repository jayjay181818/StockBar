import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Advanced → Export & Import.
@MainActor
struct SettingsTransferSection: View {
    let dataModel: DataModel
    @State private var model = SettingsTransferModel()

    var body: some View {
        Section {
            LabeledContent {
                Button("Export…") { model.beginExport() }
                    .disabled(model.isBusy)
            } label: {
                Text("Export")
                Text(model.everythingSizeDescription)
            }
            LabeledContent {
                Button("Import…") { model.beginImport() }
                    .disabled(model.isBusy)
            } label: {
                Text("Import")
                Text("Replaces your settings, and your portfolio if the file includes it. Stockbar relaunches afterwards.")
            }
        } header: {
            Text("Export & Import")
        } footer: {
            Text("Exports contain your API keys and, with Everything, your portfolio. They're encrypted with a password you choose: keep the file and the password safe.")
        }
        .task { await model.refreshEstimate() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .export:
                SettingsExportSheet(model: model, dataModel: dataModel)
            case .importFile:
                SettingsImportSheet(model: model, dataModel: dataModel)
            }
        }
        .alert(model.alertTitle, isPresented: $model.showingAlert) {
            Button("OK") { }
        } message: {
            Text(model.alertMessage)
        }
    }
}

@MainActor
@Observable
final class SettingsTransferModel {
    enum Sheet: String, Identifiable {
        case export
        case importFile
        var id: String { rawValue }
    }

    var sheet: Sheet?
    var exportType: SettingsTransferExportType = .settingsAndKeys
    var password = ""
    var confirmation = ""
    var progress: String?
    var errorMessage: String?
    var estimatedDatabaseBytes: Int64?
    var importURL: URL?
    var prepared: PreparedSettingsImport?
    var showingImportConfirmation = false
    var showingAlert = false
    var alertTitle = ""
    var alertMessage = ""

    @ObservationIgnored private let service: SettingsTransferService

    init(service: SettingsTransferService = SettingsTransferService()) {
        self.service = service
    }

    var isBusy: Bool { progress != nil }

    var everythingSizeDescription: String {
        guard let bytes = estimatedDatabaseBytes else {
            return "Settings & Keys, or Everything with your portfolio database."
        }
        return "Settings & Keys, or Everything with your portfolio database (about \(Self.formatted(bytes)))."
    }

    var exportPasswordProblem: String? {
        if password.count < SettingsTransferContainer.minimumPasswordLength {
            return "Use at least \(SettingsTransferContainer.minimumPasswordLength) characters."
        }
        if password != confirmation {
            return "The passwords don't match."
        }
        return nil
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func refreshEstimate() async {
        let service = service
        estimatedDatabaseBytes = await Task.detached(priority: .utility) {
            service.estimatedDatabaseBytes()
        }.value
    }

    // MARK: Export

    func beginExport() {
        resetEntry()
        exportType = .settingsAndKeys
        sheet = .export
        Task { await refreshEstimate() }
    }

    func export(dataModel: DataModel) async {
        guard exportPasswordProblem == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Stockbar \(exportType.title)"
        panel.allowedContentTypes = [Self.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Stockbar \(exportType.title.replacingOccurrences(of: "&", with: "and")) \(date)"
        // Not runModal: that spins a nested run loop on the main actor and holds
        // up price refreshes and the menu bar for as long as the panel is open.
        guard await Self.present(panel) == .OK, let destination = panel.url else { return }

        errorMessage = nil
        progress = "Exporting and encrypting…"
        defer { progress = nil }
        if exportType == .everything {
            await dataModel.flushPendingPersistence()
        }
        do {
            _ = try await service.export(exportType, password: password, to: destination)
            resetEntry()
            sheet = nil
            presentAlert(
                title: "Export Saved",
                message: "Saved \(destination.lastPathComponent). You'll need the password to import it."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Import

    func beginImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Stockbar Settings"
        panel.allowedContentTypes = [Self.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        Task {
            guard await Self.present(panel) == .OK, let url = panel.url else { return }
            await checkImportFile(url)
        }
    }

    /// Shows a save or open panel without blocking: as a sheet on the front
    /// window when there is one, otherwise as its own window.
    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await panel.beginSheetModal(for: window)
        }
        return await panel.begin()
    }

    private func checkImportFile(_ url: URL) async {
        do {
            try await service.checkImportFile(at: url)
        } catch {
            presentAlert(title: "Can't Import This File", message: error.localizedDescription)
            return
        }
        resetEntry()
        importURL = url
        sheet = .importFile
    }

    func unlockImport() async {
        guard let importURL, !password.isEmpty else { return }
        errorMessage = nil
        progress = "Decrypting and checking the file…"
        defer { progress = nil }
        do {
            prepared = try await service.prepareImport(from: importURL, password: password)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelImport() {
        prepared?.discard()
        prepared = nil
        importURL = nil
        resetEntry()
        sheet = nil
    }

    func applyImport(dataModel: DataModel) async {
        guard let prepared else { return }
        errorMessage = nil
        progress = prepared.includesDatabase ? "Backing up, then importing…" : "Importing…"
        await dataModel.pauseBackgroundWorkForImport()
        do {
            try await service.apply(prepared) {
                await Self.backUpPortfolio(dataModel: dataModel)
            }
        } catch {
            // After an incomplete rollback, refresh and sync stay paused until
            // the user quits, so nothing writes over a half-restored state.
            if case .applyFailedPartlyRestored = error as? SettingsTransferError {} else {
                await dataModel.resumeBackgroundWorkAfterFailedImport()
            }
            progress = nil
            errorMessage = error.localizedDescription
            return
        }
        self.prepared = nil
        // Close the import sheet first, so its spinner is never left showing
        // behind the alert, then bring this menu-bar app forward: otherwise the
        // alert can open behind the main window and the import looks stuck.
        progress = nil
        sheet = nil
        NSApp.activate()
        // Let the sheet finish closing before the modal alert takes over.
        await Task.yield()
        presentRelaunchPrompt()
    }

    /// The existing automatic portfolio backup, before an import replaces the database.
    private static func backUpPortfolio(dataModel: DataModel) async -> Bool {
        let trades = dataModel.localPortfolioTradesForBackup
        let hasPortfolioRows = trades.contains { trade in
            !trade.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !SymbolMetadata.isBenchmarkSymbol(trade.trade.name)
        }
        guard hasPortfolioRows else { return true }
        return await BackupService.shared.performPreImportBackup(trades: trades)
    }

    /// Both choices end this process: the running app still holds the old
    /// settings and data in memory, and writes stay paused until it exits.
    private func presentRelaunchPrompt() {
        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = "Stockbar needs to relaunch to use the imported settings."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Quit")
        alert.window.level = .floating
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            StockbarRelauncher.quitAfterCurrentWork()
            return
        }
        do {
            try StockbarRelauncher.relaunch()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Stockbar Couldn't Relaunch"
            failure.informativeText = "\(error.localizedDescription) Stockbar will quit now. Open it again to use the imported settings."
            failure.addButton(withTitle: "Quit")
            failure.runModal()
            StockbarRelauncher.quitAfterCurrentWork()
        }
    }

    // MARK: Helpers

    static var contentType: UTType {
        UTType(filenameExtension: SettingsTransferContainer.fileExtension, conformingTo: .data) ?? .data
    }

    private func resetEntry() {
        password = ""
        confirmation = ""
        errorMessage = nil
    }

    private func presentAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showingAlert = true
    }
}

// MARK: - Export sheet

@MainActor
private struct SettingsExportSheet: View {
    @Bindable var model: SettingsTransferModel
    let dataModel: DataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Include", selection: $model.exportType) {
                        Text("Settings & Keys").tag(SettingsTransferExportType.settingsAndKeys)
                        Text("Everything").tag(SettingsTransferExportType.everything)
                    }
                    .pickerStyle(.radioGroup)
                    Text(exportDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Export Stockbar")
                }
                Section {
                    SecureField("Password", text: $model.password)
                    SecureField("Confirm Password", text: $model.confirmation)
                } header: {
                    Text("Encryption")
                } footer: {
                    Text(passwordFooter)
                        .foregroundStyle(model.password.isEmpty || model.exportPasswordProblem == nil ? Color.secondary : Color.orange)
                }
                SettingsTransferStatus(model: model)
            }
            .formStyle(.grouped)
            SettingsTransferSheetButtons {
                Button("Cancel", role: .cancel) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    Task { await model.export(dataModel: dataModel) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.exportPasswordProblem != nil || model.isBusy)
            }
        }
        .frame(width: 480)
        .disabled(model.isBusy)
    }

    private var exportDescription: String {
        switch model.exportType {
        case .settingsAndKeys:
            return "Preferences and connection settings, plus your FMP, Twelve Data, Trading 212 and Folync keys."
        case .everything:
            let size = model.estimatedDatabaseBytes.map { " About \(SettingsTransferModel.formatted($0)) before encryption." } ?? ""
            return "Settings & Keys plus your portfolio database: holdings, price history and snapshots.\(size)"
        }
    }

    private var passwordFooter: String {
        guard !model.password.isEmpty, let problem = model.exportPasswordProblem else {
            return "You'll need this password to import the file. Stockbar can't recover it."
        }
        return problem
    }
}

// MARK: - Import sheet

@MainActor
private struct SettingsImportSheet: View {
    @Bindable var model: SettingsTransferModel
    let dataModel: DataModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let prepared = model.prepared {
                    SettingsImportPreview(preview: prepared.preview)
                } else {
                    Section {
                        LabeledContent("File", value: model.importURL?.lastPathComponent ?? "")
                        SecureField("Password", text: $model.password)
                            .onSubmit { Task { await model.unlockImport() } }
                    } header: {
                        Text("Import Stockbar")
                    } footer: {
                        Text("Enter the password used when the file was exported.")
                    }
                }
                SettingsTransferStatus(model: model)
            }
            .formStyle(.grouped)
            SettingsTransferSheetButtons {
                Button("Cancel", role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                if model.prepared == nil {
                    Button("Continue") { Task { await model.unlockImport() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.password.isEmpty || model.isBusy)
                } else {
                    Button("Import…") { model.showingImportConfirmation = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy)
                }
            }
        }
        .frame(width: 480)
        .disabled(model.isBusy)
        .confirmationDialog(
            confirmationTitle,
            isPresented: $model.showingImportConfirmation
        ) {
            Button("Import and Replace", role: .destructive) {
                Task { await model.applyImport(dataModel: dataModel) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var includesDatabase: Bool { model.prepared?.includesDatabase == true }

    private var confirmationTitle: String {
        includesDatabase ? "Replace your settings and portfolio?" : "Replace your settings?"
    }

    private var confirmationMessage: String {
        if includesDatabase {
            return "Your current portfolio is backed up first. Keys not in the file stay as they are. Stockbar relaunches afterwards."
        }
        return "Keys not in the file stay as they are. Stockbar relaunches afterwards."
    }
}

@MainActor
private struct SettingsImportPreview: View {
    let preview: SettingsTransferPreview

    var body: some View {
        Section("This File Contains") {
            LabeledContent("Type", value: preview.manifest.exportType.title)
            LabeledContent("Exported", value: preview.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("From", value: "Stockbar \(preview.manifest.appVersion) (\(preview.manifest.appBuild))")
            LabeledContent("Settings", value: settingsSummary)
        }
        Section("Keys") {
            if preview.credentialNames.isEmpty {
                Text("No keys").foregroundStyle(.secondary)
            } else {
                ForEach(preview.credentialNames, id: \.self) { name in
                    Label(name, systemImage: "key")
                }
            }
        }
        if let database = preview.database {
            Section("Portfolio Database") {
                LabeledContent("Holdings and watchlist", value: "\(database.tradeCount)")
                LabeledContent("Portfolio snapshots", value: "\(database.portfolioSnapshotCount)")
                LabeledContent("Price snapshots", value: "\(database.priceSnapshotCount)")
                LabeledContent("Size", value: SettingsTransferModel.formatted(database.byteCount))
            }
        }
    }

    private var settingsSummary: String {
        var text = "\(preview.settingsCount)"
        if preview.includesDataSourcePriority { text += ", plus provider order" }
        if preview.ignoredSettingsCount > 0 { text += " (\(preview.ignoredSettingsCount) not used by this version)" }
        return text
    }
}

@MainActor
private struct SettingsTransferStatus: View {
    let model: SettingsTransferModel

    var body: some View {
        if let progress = model.progress {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                }
                .accessibilityElement(children: .combine)
            }
        } else if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct SettingsTransferSheetButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Spacer()
            content
        }
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 4)
    }
}
