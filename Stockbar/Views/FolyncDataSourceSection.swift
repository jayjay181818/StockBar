import SwiftUI

@MainActor
struct FolyncDataSourceSection: View {
    let dataModel: DataModel
    @State private var endpoint = ""
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var isCheckingStoredToken = false
    @State private var didLoadStoredSettings = false
    @State private var portfolios: [FolyncPortfolio] = []
    @State private var selectedScope = "all"
    @State private var preview: FolyncPortfolioSnapshot?
    @State private var supplemental = FolyncSupplementalSettings.disabled
    @State private var isWorking = false
    @State private var confirmingDisable = false
    @State private var confirmingTokenRemoval = false
    /// Per-holding menu-bar choices, read once. Decoding the stored JSON
    /// inside each row's binding ran it for every holding on every render.
    @State private var overlays: [String: FolyncHoldingOverlay] = [:]
    @State private var statusMessage: String?
    @State private var manualRefreshInProgress = false
    @State private var announcementPolicy = FolyncStatusAnnouncementPolicy()
    private let accessibilityAnnouncer = FolyncStatusAccessibilityAnnouncer.live

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Folync Portfolio Source").font(.headline)
                    Text("Read-only authoritative holdings, valuation, cash, P/L, and freshness.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if dataModel.isFolyncPortfolioActive {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if dataModel.isFolyncEnabled {
                    Label("Enabled", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("HTTPS URL:")
                    TextField("https://folync.example.com", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        // Otherwise VoiceOver reads the example address as the field's name.
                        .accessibilityLabel("Folync HTTPS URL")
                }
                GridRow {
                    Text("Client token:")
                    SecureField(tokenPlaceholder, text: $token)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Folync client token")
                }
                if !portfolios.isEmpty {
                    GridRow {
                        Text("Portfolio:")
                        Picker("Portfolio", selection: $selectedScope) {
                            ForEach(portfolios) { portfolio in
                                Text(portfolio.name).tag(portfolio.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            HStack {
                Button("Test Connection") { testConnection() }
                    .disabled(isWorking || !canSubmitConnectionRequest)
                Button("Preview") { loadPreview() }
                    .disabled(isWorking || !canSubmitConnectionRequest || portfolios.isEmpty)
                Button("Activate Folync") { activate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !canSubmitConnectionRequest || preview?.scope.id != selectedScope)
                if dataModel.isFolyncEnabled {
                    Button("Refresh Now") { refreshNow() }
                    .disabled(isWorking)
                    Button(dataModel.isFolyncPortfolioActive ? "Use Local Portfolio…" : "Disable Folync…") {
                        confirmingDisable = true
                    }
                    .disabled(isWorking)
                    .confirmationDialog(
                        dataModel.isFolyncPortfolioActive ? "Switch back to the local portfolio?" : "Disable Folync?",
                        isPresented: $confirmingDisable,
                        titleVisibility: .visible
                    ) {
                        Button(dataModel.isFolyncPortfolioActive ? "Use Local Portfolio" : "Disable Folync", role: .destructive) {
                            dataModel.deactivateFolyncPortfolio()
                            showStatus("Folync has been disabled.")
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Stockbar stops showing Folync's holdings and figures and goes back to the holdings entered here. The saved address and token are kept, so you can activate it again.")
                    }
                }
                if hasStoredToken {
                    Button("Remove Token…") { confirmingTokenRemoval = true }
                        .disabled(isWorking)
                        .confirmationDialog(
                            "Remove the Folync token?",
                            isPresented: $confirmingTokenRemoval,
                            titleVisibility: .visible
                        ) {
                            Button("Remove Token", role: .destructive) { removeToken() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Stockbar stops using Folync and deletes the token from the Keychain. The saved address is kept.")
                        }
                }
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Folync request in progress")
                }
            }

            if let setupHint, !dataModel.isFolyncEnabled {
                Text(setupHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(displayedStatusMessage)
                .font(.caption)
                .foregroundStyle(statusColor)
                .accessibilityLabel("Folync status")
                .accessibilityValue(Text(displayedStatusMessage))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("folync-connection-status")

            if dataModel.isFolyncEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checks five seconds after each minute, with one follow-up if the broker sync is still pending.")
                    if let checked = dataModel.folyncLastCheckedAt {
                        Text("Last checked: \(checked.formatted(date: .omitted, time: .standard))")
                    }
                    if let next = dataModel.folyncNextCheckAt {
                        Text("Next check: \(next.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Supplemental market data").font(.subheadline).fontWeight(.semibold)
                    Text("Each enabled category uses Folync’s cached data. Existing Stockbar history is retained and becomes active again when a route is disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    supplementalToggle(
                        "Historical line charts",
                        route: .historicalLineCharts,
                        value: supplementalBinding(\.historicalLineCharts)
                    )
                    supplementalToggle(
                        "Candlestick / OHLCV charts",
                        route: .candlestickCharts,
                        value: supplementalBinding(\.candlestickCharts)
                    )
                    supplementalToggle(
                        "Benchmark market data",
                        route: .benchmarkMarketData,
                        value: supplementalBinding(\.benchmarkMarketData)
                    )
                    supplementalToggle(
                        "Exchange rates",
                        route: .exchangeRates,
                        value: supplementalBinding(\.exchangeRates)
                    )
                    Toggle("Allow legacy local-provider fallback", isOn: supplementalBinding(\.allowLegacyFallback))
                        .toggleStyle(.checkbox)

                    Text("Stockbar-only watchlist symbols remain on the local provider. Folync responses are cached separately and never replace Core Data chart history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let capabilities = dataModel.folyncCapabilities {
                        Text("Capabilities revision \(capabilities.sourceRevision.prefix(10)) · checked \(FolyncConnectionState.readable(asOf: capabilities.generatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview: \(preview.scope.name)").fontWeight(.semibold)
                    Text("\(preview.displayHoldings.count) holdings · \(formatted(preview.totalValue)) · \(preview.freshness.status)")
                    Text("Activation preserves the existing local portfolio and broker links; Folync values remain read-only.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if let snapshot = dataModel.folyncPortfolioSnapshot, !snapshot.displayHoldings.isEmpty {
                Divider()
                Text("Folync menu-bar visibility").font(.subheadline).fontWeight(.semibold)
                ForEach(snapshot.displayHoldings, id: \.holdingIdentity) { holding in
                    Toggle(
                        "\(holding.resolvedDisplayTicker) · \(holding.portfolioName ?? holding.portfolioId)",
                        isOn: visibilityBinding(holding)
                    )
                        .toggleStyle(.checkbox)
                }
            }
        }
        .stockbarCard()
        .onAppear(perform: loadStoredSettings)
        .onAppear { overlays = dataModel.folyncSessionDependencies.overlayStore.load() }
        .onChange(of: selectedScope) { _, _ in preview = nil }
        .onChange(of: dataModel.folyncConnectionState) { _, newState in
            // Background checks only; a manual refresh announces its own result.
            guard !manualRefreshInProgress,
                  statusMessage == nil,
                  dataModel.isFolyncEnabled,
                  let message = announcementPolicy.announcement(for: newState) else { return }
            accessibilityAnnouncer.announce(message)
        }
    }

    private var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }

    private var hasUsableToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || storedTokenAppliesToEndpoint
    }

    /// The stored token is only reused for the server it was saved for.
    private var storedTokenAppliesToEndpoint: Bool {
        hasStoredToken && dataModel.storedFolyncTokenApplies(to: endpointURL)
    }

    private var canSubmitConnectionRequest: Bool {
        guard let endpointURL else { return false }
        guard (try? FolyncEndpointPolicy.validate(endpointURL)) != nil else { return false }
        return hasUsableToken
    }

    private var setupHint: String? {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpoint.isEmpty {
            return "Enter a Folync HTTPS URL and client token to test the connection."
        }
        guard let endpointURL else {
            return FolyncPortfolioSourceError.invalidEndpoint.errorDescription
        }
        do {
            try FolyncEndpointPolicy.validate(endpointURL)
        } catch {
            return error.localizedDescription
        }
        if !hasUsableToken {
            return FolyncPortfolioSourceError.missingToken.errorDescription
        }
        return nil
    }

    private var displayedStatusMessage: String {
        if let statusMessage {
            return statusMessage
        }
        if dataModel.isFolyncEnabled || dataModel.folyncConnectionState != .notConfigured {
            return dataModel.folyncConnectionState.message
        }
        return "Folync has not been tested."
    }

    private var statusColor: Color {
        if let statusMessage, statusMessage.hasPrefix("Connected") {
            return .green
        }
        return .secondary
    }

    private func loadStoredSettings() {
        guard !didLoadStoredSettings else { return }
        didLoadStoredSettings = true
        let settings = dataModel.folyncSessionDependencies.settingsStore.load()
        endpoint = settings.baseURL
        selectedScope = settings.scopeID
        supplemental = settings.supplemental
        isCheckingStoredToken = true
        Task {
            hasStoredToken = await dataModel.hasStoredFolyncToken()
            isCheckingStoredToken = false
        }
    }

    /// The Keychain check can wait on a macOS access prompt; don't claim the
    /// token is missing until it has answered.
    private var tokenPlaceholder: String {
        if storedTokenAppliesToEndpoint { return "Stored in Keychain" }
        if hasStoredToken { return "Enter the token for this server" }
        return isCheckingStoredToken ? "Checking Keychain…" : "Required"
    }

    /// Shows a result of the user's own action and announces it, even when it
    /// repeats the previous one.
    private func showStatus(_ message: String?) {
        statusMessage = message
        if let message { accessibilityAnnouncer.announce(message) }
    }

    private func refreshNow() {
        statusMessage = nil
        isWorking = true
        manualRefreshInProgress = true
        Task {
            defer {
                manualRefreshInProgress = false
                isWorking = false
            }
            await dataModel.refreshFolyncPortfolio()
            let message = announcementPolicy.manualRefreshAnnouncement(for: dataModel.folyncConnectionState)
            accessibilityAnnouncer.announce(message)
        }
    }

    func testConnection() {
        guard let endpointURL else {
            showStatus(FolyncPortfolioSourceError.invalidEndpoint.errorDescription)
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let fetchedPortfolios = try await dataModel.testFolyncConnection(baseURL: endpointURL, token: token)
                if !fetchedPortfolios.contains(where: { $0.id == selectedScope }) {
                    selectedScope = fetchedPortfolios.first?.id ?? "all"
                }
                portfolios = fetchedPortfolios
                showStatus("Connected. Select a portfolio and preview it before activation.")
            } catch {
                portfolios = []
                preview = nil
                showStatus(LogRedactor.redact(error.localizedDescription))
            }
        }
    }

    private func loadPreview() {
        guard let endpointURL else {
            showStatus(FolyncPortfolioSourceError.invalidEndpoint.errorDescription)
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                preview = try await dataModel.previewFolyncPortfolio(baseURL: endpointURL, token: token, scopeID: selectedScope)
                showStatus("Preview loaded. No local holdings were changed.")
            } catch {
                preview = nil
                showStatus(LogRedactor.redact(error.localizedDescription))
            }
        }
    }

    private func activate() {
        guard let endpointURL else {
            showStatus(FolyncPortfolioSourceError.invalidEndpoint.errorDescription)
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await dataModel.activateFolyncPortfolio(baseURL: endpointURL, token: token, scopeID: selectedScope)
                supplemental = dataModel.folyncSessionDependencies.settingsStore.load().supplemental
                hasStoredToken = true
                token = ""
                statusMessage = nil
                accessibilityAnnouncer.announce("Folync is active.")
            } catch {
                showStatus(LogRedactor.redact(error.localizedDescription))
            }
        }
    }

    private func removeToken() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await dataModel.removeStoredFolyncToken()
                hasStoredToken = false
                token = ""
                showStatus("The Folync token has been removed.")
            } catch {
                showStatus(LogRedactor.redact(error.localizedDescription))
            }
        }
    }

    private func supplementalBinding(_ keyPath: WritableKeyPath<FolyncSupplementalSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { supplemental[keyPath: keyPath] },
            set: { newValue in
                guard supplemental[keyPath: keyPath] != newValue else { return }
                supplemental[keyPath: keyPath] = newValue
                saveSupplementalSettings()
            }
        )
    }

    @ViewBuilder
    private func supplementalToggle(
        _ title: String,
        route: FolyncSupplementalRoute,
        value: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(title, isOn: value)
                    .toggleStyle(.checkbox)
                    // A lost capability must not trap an already-enabled route.
                    .disabled(!value.wrappedValue && capability(for: route)?.isUsable != true)
                Spacer()
                Text(capabilityLabel(for: route))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let coverage = capabilityCoverageLabel(for: route) {
                Text(coverage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func capability(for route: FolyncSupplementalRoute) -> FolyncCapability? {
        guard let resources = dataModel.folyncCapabilities?.resources else { return nil }
        return switch route {
        case .historicalLineCharts: resources.lineHistory
        case .candlestickCharts: resources.candlesticks
        case .benchmarkMarketData: resources.benchmarks
        case .exchangeRates: resources.exchangeRates
        }
    }

    private func capabilityLabel(for route: FolyncSupplementalRoute) -> String {
        guard let capability = capability(for: route) else { return "Not supported by this Folync server" }
        if !capability.supported { return "Unsupported" }
        if !capability.ready { return "Not ready · \(FolyncConnectionState.readable(reasons: capability.reasonCodes))" }
        return dataModel.folyncSupplementalStatuses[route]?.label ?? "Ready"
    }

    private func capabilityCoverageLabel(for route: FolyncSupplementalRoute) -> String? {
        guard let capabilities = dataModel.folyncCapabilities else { return nil }
        switch route {
        case .historicalLineCharts, .candlestickCharts:
            let identities = capabilities.marketIdentities ?? []
            guard !identities.isEmpty else { return "Per-identity coverage was not reported by this Folync server." }
            let readyCount = identities.filter { identity in
                route == .historicalLineCharts
                    ? identity.resources.lineHistory.isUsable
                    : identity.resources.candlesticks.isUsable
            }.count
            let intervals = Set(identities.flatMap { $0.intervals.keys }).sorted().joined(separator: ", ")
            return "\(readyCount)/\(identities.count) identities ready · cached intervals: \(intervals.isEmpty ? "none" : intervals)"
        case .benchmarkMarketData:
            return "\(capabilities.benchmarks.count) configured benchmark identities"
        case .exchangeRates:
            return "\(capabilities.fx.base) base · \(capabilities.fx.quotes.joined(separator: ", "))"
        }
    }

    private func saveSupplementalSettings() {
        let current = supplemental
        Task { await dataModel.updateFolyncSupplementalSettings(current) }
    }

    private func visibilityBinding(_ holding: FolyncHolding) -> Binding<Bool> {
        Binding(
            get: {
                let key = holding.overlayKey(scopeID: dataModel.folyncPortfolioSnapshot?.scope.id ?? selectedScope)
                return overlays[key]?.showInMenuBar ?? true
            },
            set: {
                dataModel.setFolyncHoldingVisibleInMenuBar($0, holding: holding)
                overlays = dataModel.folyncSessionDependencies.overlayStore.load()
            }
        )
    }

    private func formatted(_ metric: FolyncFinancialMetric) -> String {
        guard let value = metric.value else { return "Unavailable" }
        return "\(metric.currency ?? "") \(value.formatted(.number.precision(.fractionLength(2))))"
    }
}
