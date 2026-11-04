//
//  PriceAlertManagementView.swift
//  Stockbar
//
//  User interface for managing price alerts
//

import SwiftUI

struct PriceAlertManagementView: View {
    @ObservedObject private var alertService = PriceAlertService.shared
    @ObservedObject var dataModel: DataModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingAddAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: StockbarLayout.sectionSpacing) {
            StockbarPageHeader(
                "Alerts",
                subtitle: "Get a notification when a price crosses a threshold or moves by a percentage."
            ) {
                Button { showingAddAlert = true } label: {
                    Label("Add Alert", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(alertableSymbols.isEmpty)
                .help(alertableSymbols.isEmpty ? "Add a holding first" : "Create a price alert")
            }

            if alertService.alerts.isEmpty {
                ContentUnavailableView {
                    Label("No alerts yet", systemImage: "bell.badge")
                } description: {
                    Text(alertableSymbols.isEmpty
                         ? "Add a holding, then create an alert for it."
                         : "Create an alert to be notified when a price reaches your target.")
                } actions: {
                    if !alertableSymbols.isEmpty {
                        Button("Add Alert") { showingAddAlert = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .stockbarCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(alertService.alerts.enumerated()), id: \.element.id) { index, alert in
                        PriceAlertRow(alert: alert, dataModel: dataModel)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        if index < alertService.alerts.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .stockbarCard(padding: 6)
                .animation(StockbarMotion.animation(StockbarMotion.standard, reduceMotion: reduceMotion),
                           value: alertService.alerts.map(\.id))
            }

            Label("Alerts are delivered as macOS notifications. Each alert triggers at most once every 15 minutes.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .stockbarPage()
        .sheet(isPresented: $showingAddAlert) {
            AddPriceAlertView(
                dataModel: dataModel,
                isPresented: $showingAddAlert
            )
        }
    }

    private var alertableSymbols: [String] {
        dataModel.realTimeTrades
            .map(\.trade.name)
            .filter { !$0.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0) }
    }
}

struct PriceAlertRow: View {
    let alert: PriceAlert
    @ObservedObject var dataModel: DataModel
    @ObservedObject private var alertService = PriceAlertService.shared
    @State private var isHovered = false

    private var currency: String {
        if let symbol = alert.symbol {
            return dataModel.realTimeTrades.first(where: { $0.trade.name == symbol })?.realTimeInfo.currency ?? "USD"
        } else {
            // Portfolio milestone - use preferred currency
            return dataModel.preferredCurrency
        }
    }

    private var currentPriceText: String? {
        guard let symbol = alert.symbol,
              let trade = dataModel.realTimeTrades.first(where: { $0.trade.name == symbol }) else { return nil }
        let price = trade.realTimeInfo.getCurrentDisplayPrice()
        guard price.isFinite, price > 0 else { return nil }
        return "Now \(HoldingsCurrencyFormatter.amount(price, currency: currency))"
    }

    private var conditionIcon: String {
        switch alert.condition {
        case .above: "arrow.up.right.circle.fill"
        case .below: "arrow.down.right.circle.fill"
        case .percentChange: "percent"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conditionIcon)
                .font(.title2)
                .foregroundStyle(alert.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(alert.symbol ?? "Portfolio")
                        .fontWeight(.semibold)
                    if !alert.isEnabled {
                        Text("Paused")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(StockbarPalette.hoverFill, in: Capsule())
                    }
                }
                Text("\(alert.condition.description) \(alert.formattedThreshold(currency: currency))")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let currentPriceText {
                    Text(currentPriceText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let lastTriggered = alert.lastTriggered {
                    Text("Triggered \(lastTriggered.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 4) {
                Button {
                    alertService.toggleAlert(id: alert.id)
                } label: {
                    Image(systemName: alert.isEnabled ? "pause.circle" : "play.circle")
                        .font(.title3)
                }
                .help(alert.isEnabled ? "Pause alert" : "Resume alert")
                .accessibilityLabel(alert.isEnabled ? "Pause alert for \(alert.symbol ?? "portfolio")" : "Resume alert for \(alert.symbol ?? "portfolio")")

                Button(role: .destructive) {
                    alertService.removeAlert(id: alert.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                }
                .help("Delete alert")
                .accessibilityLabel("Delete alert for \(alert.symbol ?? "portfolio")")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? StockbarPalette.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            withAnimation(StockbarMotion.quick) { isHovered = hovering }
        }
        .contextMenu {
            Button(alert.isEnabled ? "Pause Alert" : "Resume Alert") { alertService.toggleAlert(id: alert.id) }
            Button("Delete Alert", role: .destructive) { alertService.removeAlert(id: alert.id) }
        }
    }
}

struct AddPriceAlertView: View {
    @ObservedObject var dataModel: DataModel
    @Binding var isPresented: Bool
    @ObservedObject private var alertService = PriceAlertService.shared

    @State private var selectedSymbol: String = ""
    @State private var selectedCondition: AlertCondition = .above
    @State private var thresholdValue: String = ""
    @State private var errorMessage: String?
    /// Set after warning that the condition is already met; a second Add creates it.
    @State private var confirmedAlreadyMet = false

    private var availableSymbols: [String] {
        dataModel.realTimeTrades
            .map { $0.trade.name }
            .filter { !$0.isEmpty && !SymbolMetadata.isBenchmarkSymbol($0) }
            .sorted()
    }

    private var currentPriceText: String? {
        guard let trade = dataModel.realTimeTrades.first(where: { $0.trade.name == selectedSymbol }) else { return nil }
        let price = trade.realTimeInfo.getCurrentDisplayPrice()
        guard price.isFinite, price > 0 else { return nil }
        return HoldingsCurrencyFormatter.amount(price, currency: trade.realTimeInfo.currency ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Symbol", selection: $selectedSymbol) {
                        if selectedSymbol.isEmpty {
                            Text("Select…").tag("")
                        }
                        ForEach(availableSymbols, id: \.self) { symbol in
                            Text(symbol).tag(symbol)
                        }
                    }
                    if let currentPriceText {
                        LabeledContent("Current price", value: currentPriceText)
                            .monospacedDigit()
                    }
                    Picker("Condition", selection: $selectedCondition) {
                        ForEach(AlertCondition.allCases, id: \.self) { condition in
                            Text(condition.description).tag(condition)
                        }
                    }
                    LabeledContent("Threshold") {
                        HStack(spacing: 6) {
                            TextField("Threshold", text: $thresholdValue, prompt: Text(thresholdPlaceholder))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                                .onSubmit(addAlert)
                            Text(thresholdUnit)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("New Price Alert")
                } footer: {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: thresholdValue) { _, _ in errorMessage = nil; confirmedAlreadyMet = false }
            .onChange(of: selectedCondition) { _, _ in errorMessage = nil; confirmedAlreadyMet = false }
            .onChange(of: selectedSymbol) { _, _ in errorMessage = nil; confirmedAlreadyMet = false }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Alert") {
                    addAlert()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSymbol.isEmpty || thresholdValue.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .onAppear {
            if !availableSymbols.isEmpty && selectedSymbol.isEmpty {
                selectedSymbol = availableSymbols[0]
            }
        }
    }

    private var thresholdPlaceholder: String {
        switch selectedCondition {
        case .above, .below:
            return "e.g., 150.00"
        case .percentChange:
            return "e.g., 5.0"
        }
    }

    private var thresholdUnit: String {
        let currency = dataModel.realTimeTrades.first(where: { $0.trade.name == selectedSymbol })?.realTimeInfo.currency ?? "USD"
        switch selectedCondition {
        case .above, .below:
            return currency
        case .percentChange:
            return "%"
        }
    }

    private func addAlert() {
        guard !selectedSymbol.isEmpty else { return }
        // Accept the user's locale decimal separator as well as a plain ".".
        guard let threshold = MenuPopoverFormatter.parseUnits(thresholdValue) else {
            errorMessage = "Enter a number greater than zero."
            return
        }

        if selectedCondition == .percentChange && threshold > 100 {
            errorMessage = "Enter a percentage between 0 and 100."
            return
        }

        if alertService.alerts.contains(where: {
            $0.symbol == selectedSymbol && $0.condition == selectedCondition && abs($0.threshold - threshold) < 1e-9
        }) {
            errorMessage = "An identical alert already exists for \(selectedSymbol)."
            return
        }

        // Above/below alerts fire when the price crosses the threshold, so one
        // already on the far side would stay silent until the price comes back.
        let currentPrice = dataModel.realTimeTrades.first(where: { $0.trade.name == selectedSymbol })?
            .realTimeInfo.getCurrentDisplayPrice()
        if let currentPrice, currentPrice.isFinite, currentPrice > 0 {
            if selectedCondition == .above && currentPrice >= threshold {
                errorMessage = "The price is already above this level, so the alert only fires after it dips and rises through it again. Press Add again to create it anyway."
                guard confirmedAlreadyMet else { confirmedAlreadyMet = true; return }
            } else if selectedCondition == .below && currentPrice <= threshold {
                errorMessage = "The price is already below this level, so the alert only fires after it recovers and falls through it again. Press Add again to create it anyway."
                guard confirmedAlreadyMet else { confirmedAlreadyMet = true; return }
            }
        }

        let alert = PriceAlert(
            symbol: selectedSymbol,
            condition: selectedCondition,
            threshold: threshold,
            isEnabled: true
        )

        alertService.addAlert(alert)
        isPresented = false
    }
}
