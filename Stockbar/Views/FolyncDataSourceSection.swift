import SwiftUI

@MainActor
struct FolyncDataSourceSection: View {
    @ObservedObject var dataModel: DataModel
    @State private var endpoint = ""
    @State private var token = ""
    @State private var portfolios: [FolyncPortfolio] = []
    @State private var selectedScope = "all"
    @State private var preview: FolyncPortfolioSnapshot?
    @State private var supplemental = FolyncSupplementalSettings.disabled
    @State private var isWorking = false
    @State private var statusMessage = "Folync has not been tested."

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
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("HTTPS URL:")
                    TextField("https://folync.example.com", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Client token:")
                    SecureField(FolyncCredentialStore.shared.hasToken() ? "Stored in Keychain" : "Required", text: $token)
                        .textFieldStyle(.roundedBorder)
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
                    .disabled(isWorking || endpointURL == nil || token.isEmpty)
                Button("Preview") { loadPreview() }
                    .disabled(isWorking || portfolios.isEmpty)
                Button("Activate Folync") { activate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || preview?.scope.id != selectedScope)
                if dataModel.isFolyncPortfolioActive {
                    Button("Refresh Now") { Task { await dataModel.refreshFolyncPortfolio() } }
                    Button("Use Local Portfolio") { dataModel.deactivateFolyncPortfolio() }
                }
                if isWorking { ProgressView().controlSize(.small) }
            }

            Text(dataModel.isFolyncPortfolioActive ? dataModel.folyncConnectionState.message : statusMessage)
                .font(.caption)
                .foregroundStyle(statusColor)

            if dataModel.isFolyncPortfolioActive {
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
                        value: $supplemental.historicalLineCharts
                    )
                    supplementalToggle(
                        "Candlestick / OHLCV charts",
                        route: .candlestickCharts,
                        value: $supplemental.candlestickCharts
                    )
                    supplementalToggle(
                        "Benchmark market data",
                        route: .benchmarkMarketData,
                        value: $supplemental.benchmarkMarketData
                    )
                    supplementalToggle(
                        "Exchange rates",
                        route: .exchangeRates,
                        value: $supplemental.exchangeRates
                    )
                    Toggle("Allow legacy local-provider fallback", isOn: $supplemental.allowLegacyFallback)
                        .toggleStyle(.checkbox)
                        .onChange(of: supplemental.allowLegacyFallback) { _, _ in saveSupplementalSettings() }

                    Text("Stockbar-only watchlist symbols remain on the local provider. Folync responses are cached separately and never replace Core Data chart history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let capabilities = dataModel.folyncCapabilities {
                        Text("Capabilities revision \(capabilities.sourceRevision.prefix(10)) · checked \(capabilities.generatedAt)")
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
        .onChange(of: selectedScope) { _, _ in preview = nil }
    }

    private var endpointURL: URL? { URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var statusColor: Color {
        dataModel.isFolyncPortfolioActive ? .secondary : (statusMessage.hasPrefix("Connected") ? .green : .secondary)
    }

    private func loadStoredSettings() {
        let settings = FolyncSettingsStore.shared.load()
        endpoint = settings.baseURL
        selectedScope = settings.scopeID
        supplemental = settings.supplemental
    }

    func testConnection() {
        guard let endpointURL else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                portfolios = try await dataModel.testFolyncConnection(baseURL: endpointURL, token: token)
                if !portfolios.contains(where: { $0.id == selectedScope }) { selectedScope = portfolios.first?.id ?? "all" }
                statusMessage = "Connected. Select a portfolio and preview it before activation."
            } catch {
                portfolios = []
                preview = nil
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
        }
    }

    private func loadPreview() {
        guard let endpointURL else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                preview = try await dataModel.previewFolyncPortfolio(baseURL: endpointURL, token: token, scopeID: selectedScope)
                statusMessage = "Preview loaded. No local holdings were changed."
            } catch {
                preview = nil
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
        }
    }

    private func activate() {
        guard let endpointURL else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await dataModel.activateFolyncPortfolio(baseURL: endpointURL, token: token, scopeID: selectedScope)
                supplemental = FolyncSettingsStore.shared.load().supplemental
                token = ""
                statusMessage = "Folync is active."
            } catch {
                statusMessage = LogRedactor.redact(error.localizedDescription)
            }
        }
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
                    .onChange(of: value.wrappedValue) { _, _ in saveSupplementalSettings() }
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
        if !capability.ready { return "Not ready · \(capability.reasonCodes.joined(separator: ", "))" }
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
        Task { await dataModel.updateFolyncSupplementalSettings(supplemental) }
    }

    private func visibilityBinding(_ holding: FolyncHolding) -> Binding<Bool> {
        Binding(
            get: {
                let key = holding.overlayKey(scopeID: dataModel.folyncPortfolioSnapshot?.scope.id ?? selectedScope)
                return FolyncOverlayStore.shared.load()[key]?.showInMenuBar ?? true
            },
            set: { dataModel.setFolyncHoldingVisibleInMenuBar($0, holding: holding) }
        )
    }

    private func formatted(_ metric: FolyncFinancialMetric) -> String {
        guard let value = metric.value else { return "Unavailable" }
        return "\(metric.currency ?? "") \(value.formatted(.number.precision(.fractionLength(2))))"
    }
}
