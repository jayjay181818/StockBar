import SwiftUI

@MainActor
struct Trading212DataSourceSection: View {
    @ObservedObject var dataModel: DataModel

    @State private var settings = Trading212StoredSettings.defaults
    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var showAPIKey = false
    @State private var showAPISecret = false
    @State private var keychainStatus = "Not stored"
    @State private var hasStoredCredentials = false
    @State private var isTesting = false
    @State private var isPreviewing = false
    @State private var isLinking = false
    @State private var isImportingBrokerOnly = false
    @State private var isSyncing = false
    @State private var isReconcilingHoldings = false
    @State private var showingLinkConfirmation = false
    @State private var showingBrokerOnlyImportConfirmation = false
    @State private var statusMessage = "Trading 212 preview has not been tested."
    @State private var preview: Trading212ImportPreview?

    private let settingsStore = Trading212SettingsStore.shared
    private let credentialStore = Trading212CredentialStore.shared
    private let coordinator = Trading212PreviewCoordinator()
    private let brokerLinkStore = BrokerLinkStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            accountConfiguration
            syncConfiguration
            credentialFields
            permissionMatrix
            actionRow
            statusBlock
            previewBlock
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .onAppear(perform: loadSettings)
        .alert("Link matched holdings?", isPresented: $showingLinkConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Link") {
                linkMatchedHoldings()
            }
        } message: {
            Text("StockBar will save broker links for exact manual matches only. Broker-only rows will not be imported by this action.")
        }
        .alert("Import broker-only holdings?", isPresented: $showingBrokerOnlyImportConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Import") {
                importBrokerOnlyHoldings()
            }
        } message: {
            Text("StockBar will create new holdings only for clean broker-only Trading 212 rows and save broker links so future syncs update them. Existing manual holdings, backups, historical data, and market caches are not deleted or migrated.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Broker / Portfolio Provider")
                    .font(.headline)
                Spacer()
                Toggle("Enable Trading 212", isOn: binding(\.isEnabled))
                    .toggleStyle(.switch)
            }
            Text("Trading 212 can test, preview, link, and sync matched broker holdings without using order permissions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var accountConfiguration: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Environment:")
                Picker("Environment", selection: binding(\.environment)) {
                    ForEach(Trading212Environment.allCases, id: \.self) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            GridRow {
                Text("Account Type:")
                Picker("Account Type", selection: binding(\.accountType)) {
                    ForEach(Trading212AccountType.allCases, id: \.self) { accountType in
                        Text(accountType.displayName).tag(accountType)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            GridRow {
                Text("Account Label:")
                TextField("Trading 212 ISA", text: binding(\.accountLabel))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }
        }
        .disabled(!settings.isEnabled)
    }

    private var syncConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linked Holding Sync")
                .font(.subheadline)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Auto-sync:")
                    Toggle("Refresh linked holdings periodically", isOn: binding(\.autoSyncEnabled))
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Text("Interval:")
                    Picker("Interval", selection: binding(\.syncIntervalSeconds)) {
                        ForEach(Trading212SyncPolicy.intervalOptionsSeconds, id: \.self) { seconds in
                            Text(Trading212SyncPolicy.displayName(for: seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    Text("Removed holdings:")
                    Toggle("Delete linked manual holdings missing from Trading 212", isOn: binding(\.deleteMissingLinkedHoldings))
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Text("Portfolio changes:")
                    Toggle("Check hourly and automatically apply Trading 212 holding changes", isOn: binding(\.autoReconcileHoldingsEnabled))
                        .toggleStyle(.checkbox)
                }
                GridRow {
                    Text("New holdings:")
                    Toggle("Automatically import clean broker-only holdings during hourly checks", isOn: binding(\.autoImportBrokerOnlyHoldings))
                        .toggleStyle(.checkbox)
                        .disabled(!settings.autoReconcileHoldingsEnabled)
                }
            }

            Text(settings.deleteMissingLinkedHoldings
                 ? "Enabled: if a linked position disappears from Trading 212, StockBar deletes the matched manual holding and removes its broker link."
                 : "Disabled: removed Trading 212 positions are reported as missing and manual holdings stay in StockBar.")
                .font(.caption)
                .foregroundColor(settings.deleteMissingLinkedHoldings ? .orange : .secondary)
            Text(settings.autoReconcileHoldingsEnabled
                 ? "Hourly reconciliation uses one Trading 212 account preview to sync linked holdings and, if enabled, import clean new positions. Failed or empty broker responses never delete the whole portfolio."
                 : "Hourly reconciliation is disabled. Use Preview Import or Sync Linked Holdings manually to apply structural changes.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Linked holdings sync through one Trading 212 positions request per cycle; StockBar does not poll each ticker separately.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .disabled(!settings.isEnabled)
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credentials")
                .font(.subheadline)
                .fontWeight(.semibold)

            secretField(
                label: "API Key:",
                text: $apiKey,
                isVisible: $showAPIKey,
                placeholder: credentialPlaceholder("API key")
            )
            secretField(
                label: "API Secret:",
                text: $apiSecret,
                isVisible: $showAPISecret,
                placeholder: credentialPlaceholder("API secret")
            )

            HStack(spacing: 12) {
                Label("Keychain: \(keychainStatus)", systemImage: hasStoredCredentials ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundColor(hasStoredCredentials ? .green : .secondary)
                Button(hasStoredCredentials ? "Update Credentials" : "Save Credentials") {
                    saveCredentials()
                }
                .disabled(!canSaveCredentials)
                Button("Clear Credentials") {
                    clearCredentials()
                }
                .disabled(!settings.isEnabled || !hasStoredCredentials)
            }

            Text(credentialHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .disabled(!settings.isEnabled)
    }

    private var permissionMatrix: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(Trading212PermissionPolicy.mvpRows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.area.displayName)
                        .frame(width: 150, alignment: .leading)
                    Text(row.requirement.displayName)
                        .frame(width: 110, alignment: .leading)
                        .foregroundColor(permissionColor(row.requirement))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.stockBarUse)
                        Text(row.notes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                testConnection()
            } label: {
                if isTesting {
                    ProgressView().scaleEffect(0.6).frame(width: 90)
                } else {
                    Text("Test Connection")
                }
            }
            .disabled(!canRunBrokerAction || isTesting || isPreviewing)

            Button {
                previewImport()
            } label: {
                if isPreviewing {
                    ProgressView().scaleEffect(0.6).frame(width: 90)
                } else {
                    Text("Preview Import")
                }
            }
            .disabled(!canRunBrokerAction || isTesting || isPreviewing)

            Button("Clear Preview") {
                preview = nil
                statusMessage = "Preview cleared. No holdings were changed."
            }
            .disabled(preview == nil)

            Button {
                syncLinkedHoldings()
            } label: {
                if isSyncing {
                    ProgressView().scaleEffect(0.6).frame(width: 120)
                } else {
                    Text("Sync Linked Holdings")
                }
            }
            .disabled(!canRunBrokerAction || isTesting || isPreviewing || isSyncing)

            Button {
                reconcileHoldings()
            } label: {
                if isReconcilingHoldings {
                    ProgressView().scaleEffect(0.6).frame(width: 130)
                } else {
                    Text("Reconcile Holdings Now")
                }
            }
            .disabled(!canRunBrokerAction || isTesting || isPreviewing || isSyncing || isReconcilingHoldings)
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
            if settings.accountType == .cfdUnsupported {
                Text("Trading 212's current public API docs list Invest and Stocks ISA only; CFD is not supported.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var previewBlock: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 8) {
                Text("Read-Only Import Preview")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("No holdings, backups, historical data, market caches, or Core Data rows are changed by this preview.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Matched \(preview.manualMatchCount) manual holdings, \(preview.brokerOnlyCount) broker-only rows, \(preview.quantityMismatchCount) quantity differences, \(preview.needsReviewCount) rows needing review.")
                    .font(.caption)
                    .foregroundColor(preview.needsReviewCount == 0 ? .green : .orange)
                HStack(spacing: 10) {
                    Button {
                        showingLinkConfirmation = true
                    } label: {
                        if isLinking {
                            ProgressView().scaleEffect(0.6).frame(width: 120)
                        } else {
                            Text("Link Matched Holdings")
                        }
                    }
                    .disabled(!canLinkPreview(preview) || isLinking)
                    Button {
                        showingBrokerOnlyImportConfirmation = true
                    } label: {
                        if isImportingBrokerOnly {
                            ProgressView().scaleEffect(0.6).frame(width: 150)
                        } else {
                            Text("Import Broker-Only Holdings")
                        }
                    }
                    .disabled(!canImportBrokerOnly(preview) || isImportingBrokerOnly)
                    Text("Linking saves broker links; importing creates new holdings only for broker-only rows.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 6) {
                        previewHeader
                        ForEach(preview.rows) { row in
                            previewRow(row)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 12) {
            Text("Ticker").frame(width: 90, alignment: .leading)
            Text("Instrument").frame(width: 100, alignment: .leading)
            Text("Manual").frame(width: 100, alignment: .leading)
            Text("Account").frame(width: 140, alignment: .leading)
            Text("Qty").frame(width: 70, alignment: .trailing)
            Text("Qty Delta").frame(width: 70, alignment: .trailing)
            Text("Avg").frame(width: 70, alignment: .trailing)
            Text("Broker Price").frame(width: 90, alignment: .trailing)
            Text("Value").frame(width: 90, alignment: .trailing)
            Text("P/L").frame(width: 90, alignment: .trailing)
            Text("Match").frame(width: 150, alignment: .leading)
        }
        .fontWeight(.semibold)
    }

    private func previewRow(_ row: Trading212ImportPreviewRow) -> some View {
        HStack(spacing: 12) {
            Text(row.providerTicker).frame(width: 90, alignment: .leading)
            Text(row.instrumentId ?? "Needs review").frame(width: 100, alignment: .leading)
            Text(row.manualMatch?.symbol ?? "-").frame(width: 100, alignment: .leading)
            Text(row.account.accountLabel).frame(width: 140, alignment: .leading)
            Text(format(row.quantity)).frame(width: 70, alignment: .trailing)
            Text(formatSigned(row.quantityDelta)).frame(width: 70, alignment: .trailing)
            Text(format(row.averagePrice)).frame(width: 70, alignment: .trailing)
            Text(format(row.brokerProvidedPrice)).frame(width: 90, alignment: .trailing)
            Text(format(row.currentValue)).frame(width: 90, alignment: .trailing)
            Text(format(row.unrealizedProfitLoss)).frame(width: 90, alignment: .trailing)
            Text(matchLabel(row)).frame(width: 150, alignment: .leading)
        }
        .foregroundColor(matchColor(row.conflictStatus))
    }

    private var canRunBrokerAction: Bool {
        settings.isEnabled && settings.accountType.isSupportedByPublicAPI
    }

    private var canSaveCredentials: Bool {
        settings.isEnabled &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canLinkPreview(_ preview: Trading212ImportPreview) -> Bool {
        preview.rows.contains { row in
            row.conflictStatus == .manualHoldingMatch || row.conflictStatus == .manualQuantityMismatch
        }
    }

    private func canImportBrokerOnly(_ preview: Trading212ImportPreview) -> Bool {
        preview.rows.contains { row in
            row.conflictStatus == .none &&
                row.instrumentId != nil &&
                (row.quantity ?? 0) > 0
        }
    }

    private var credentialHelpText: String {
        if hasStoredCredentials {
            return "Credentials are stored in Keychain. Fields stay empty for security; paste both values to replace them."
        }
        return "Trading 212 credentials can expose sensitive account data. StockBar stores them in Keychain only."
    }

    private func credentialPlaceholder(_ label: String) -> String {
        if hasStoredCredentials {
            return "Stored in Keychain - paste new \(label) to replace"
        }
        return "Paste Trading 212 \(label)"
    }

    private func secretField(
        label: String,
        text: Binding<String>,
        isVisible: Binding<Bool>,
        placeholder: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            Group {
                if isVisible.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
    }

    private func loadSettings() {
        settings = settingsStore.load()
        refreshKeychainStatus()
    }

    private func saveSettings(
        _ settingsToSave: Trading212StoredSettings? = nil,
        restartScheduler: Bool = true,
        runImmediately: Bool = false
    ) {
        settingsStore.save(settingsToSave ?? settings)
        if restartScheduler {
            dataModel.restartTrading212LinkedSyncScheduler(runImmediately: runImmediately)
        }
        refreshKeychainStatus()
    }

    private func saveCredentials() {
        do {
            try credentialStore.save(Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret), environment: settings.environment)
            apiKey = ""
            apiSecret = ""
            refreshKeychainStatus()
            dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
            statusMessage = "Trading 212 credentials saved to Keychain. The fields were cleared intentionally."
        } catch {
            statusMessage = LogRedactor.redact(error.localizedDescription)
        }
    }

    private func clearCredentials() {
        do {
            try credentialStore.delete(environment: settings.environment)
            apiKey = ""
            apiSecret = ""
            refreshKeychainStatus()
            dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
            statusMessage = "Trading 212 credentials cleared from Keychain."
        } catch {
            statusMessage = LogRedactor.redact(error.localizedDescription)
        }
    }

    private func credentialsForAction() throws -> Trading212AuthConfiguration {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let credentials = Trading212AuthConfiguration(apiKey: apiKey, apiSecret: apiSecret)
            _ = try Trading212AuthHeaderBuilder().authorizationHeader(for: credentials)
            try credentialStore.save(credentials, environment: settings.environment)
            return credentials.normalized
        }
        return try credentialStore.load(environment: settings.environment)
    }

    private func testConnection() {
        do {
            let credentials = try credentialsForAction()
            saveSettings(restartScheduler: false)
            dataModel.suspendTrading212LinkedSyncScheduler()
            isTesting = true
            Task {
                let result = await coordinator.testConnection(settings: settings, credentials: credentials)
                isTesting = false
                refreshKeychainStatus()
                dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
                statusMessage = "\(result.environment.displayName): \(result.safeMessage) Positions: \(result.positionCount)."
            }
        } catch {
            statusMessage = LogRedactor.redact(error.localizedDescription)
        }
    }

    private func previewImport() {
        do {
            let credentials = try credentialsForAction()
            saveSettings(restartScheduler: false)
            dataModel.suspendTrading212LinkedSyncScheduler()
            let existingManualHoldings = dataModel.realTimeTrades.map { manualHoldingSnapshot(from: $0) }
            isPreviewing = true
            Task {
                do {
                    let result = try await coordinator.preview(
                        settings: settings,
                        credentials: credentials,
                        existingManualHoldings: existingManualHoldings
                    )
                    preview = result
                    statusMessage = "Preview loaded from \(settings.environment.displayName). Rows: \(result.rows.count)."
                } catch {
                    statusMessage = LogRedactor.redact(error.localizedDescription)
                }
                isPreviewing = false
                refreshKeychainStatus()
                dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
            }
        } catch {
            statusMessage = LogRedactor.redact(error.localizedDescription)
        }
    }

    private func linkMatchedHoldings() {
        guard let preview else {
            statusMessage = "Run Preview Import before linking broker holdings."
            return
        }

        isLinking = true
        Task {
            do {
                let result = try await brokerLinkStore.linkMatchedHoldings(from: preview)
                statusMessage = "Linked \(result.linkedCount) matched Trading 212 holding(s). Broker-only rows were not imported."
                dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
            } catch {
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
            isLinking = false
        }
    }

    private func importBrokerOnlyHoldings() {
        guard let preview else {
            statusMessage = "Run Preview Import before importing broker-only holdings."
            return
        }

        isImportingBrokerOnly = true
        Task {
            do {
                let result = try await dataModel.importBrokerOnlyTrading212Holdings(from: preview)
                statusMessage = result.userMessage
                self.preview = nil
            } catch {
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
            isImportingBrokerOnly = false
            refreshKeychainStatus()
        }
    }

    private func syncLinkedHoldings() {
        saveSettings(restartScheduler: false)
        dataModel.suspendTrading212LinkedSyncScheduler()
        isSyncing = true
        Task {
            do {
                let result = try await dataModel.syncLinkedTrading212Holdings(reason: "settings-manual")
                statusMessage = result.userMessage
            } catch {
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
            isSyncing = false
            refreshKeychainStatus()
            dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
        }
    }

    private func reconcileHoldings() {
        saveSettings(restartScheduler: false)
        dataModel.suspendTrading212LinkedSyncScheduler()
        isReconcilingHoldings = true
        Task {
            do {
                let result = try await dataModel.reconcileTrading212Holdings(reason: "settings-manual-reconcile")
                statusMessage = result.userMessage
            } catch {
                statusMessage = "\(LogRedactor.redact(error.localizedDescription)) No holdings were changed."
            }
            isReconcilingHoldings = false
            refreshKeychainStatus()
            dataModel.restartTrading212LinkedSyncScheduler(runImmediately: false)
        }
    }

    private func refreshKeychainStatus() {
        let storageState = credentialStore.storageState(environment: settings.environment)
        hasStoredCredentials = storageState.hasCredentials
        switch storageState {
        case .currentSingleItem:
            keychainStatus = "\(settings.environment.displayName) stored"
        case .legacySplitItems:
            keychainStatus = "Stored in older format - test/sync once or re-save to upgrade"
        case .notStored:
            keychainStatus = "Not stored"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Trading212StoredSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var updatedSettings = settings
                updatedSettings[keyPath: keyPath] = newValue
                settings = updatedSettings
                saveSettings(updatedSettings, runImmediately: false)
            }
        )
    }

    private func permissionColor(_ requirement: Trading212PermissionRequirement) -> Color {
        switch requirement {
        case .required: return .red
        case .recommended: return .blue
        case .optionalFuture: return .secondary
        case .neverRequired: return .green
        }
    }

    private func format(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }
        return String(format: "%.2f", value)
    }

    private func formatSigned(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }
        return String(format: "%+.2f", value)
    }

    private func matchLabel(_ row: Trading212ImportPreviewRow) -> String {
        switch row.conflictStatus {
        case .none: return "Broker only"
        case .manualHoldingMatch: return "Manual match"
        case .manualQuantityMismatch: return "Qty differs"
        case .manualWatchlistMatch: return "Watchlist match"
        case .duplicateManualMatches: return "Multiple manual (+\(row.additionalManualMatchCount))"
        case .unresolvedInstrument: return "Needs review"
        }
    }

    private func matchColor(_ status: Trading212PreviewConflictStatus) -> Color {
        switch status {
        case .manualHoldingMatch: return .green
        case .none: return .primary
        case .manualQuantityMismatch, .manualWatchlistMatch, .duplicateManualMatches, .unresolvedInstrument:
            return .orange
        }
    }

    private func manualHoldingSnapshot(from realTimeTrade: RealTimeTrade) -> Trading212ManualHoldingSnapshot {
        let trade = realTimeTrade.trade
        let displayName = realTimeTrade.realTimeInfo.shortName.isEmpty ? nil : realTimeTrade.realTimeInfo.shortName
        return Trading212ManualHoldingSnapshot(
            symbol: trade.name,
            displayName: displayName,
            quantity: trade.position.unitSize,
            averageCost: finite(trade.position.positionAvgCost),
            currency: trade.position.currency ?? trade.position.costCurrency ?? realTimeTrade.realTimeInfo.currency,
            isWatchlistOnly: trade.isWatchlistOnly
        )
    }

    private func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}
