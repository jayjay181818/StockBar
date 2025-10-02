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
    @State private var showingAddAlert = false
    @State private var selectedSymbol: String = ""
    @State private var selectedCondition: AlertCondition = .above
    @State private var thresholdValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Price Alerts")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button(action: { showingAddAlert = true }) {
                    Label("Add Alert", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            if alertService.alerts.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("No price alerts configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Add alerts to get notified when prices reach your targets")
                        .font(.caption2)
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Alert list
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(alertService.alerts) { alert in
                            PriceAlertRow(alert: alert, dataModel: dataModel)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            Text("Alerts notify you when price thresholds are crossed. Each alert can trigger once every 15 minutes.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showingAddAlert) {
            AddPriceAlertView(
                dataModel: dataModel,
                isPresented: $showingAddAlert
            )
        }
    }
}

struct PriceAlertRow: View {
    let alert: PriceAlert
    @ObservedObject var dataModel: DataModel
    @ObservedObject private var alertService = PriceAlertService.shared

    private var currency: String {
        if let symbol = alert.symbol {
            return dataModel.realTimeTrades.first(where: { $0.trade.name == symbol })?.realTimeInfo.currency ?? "USD"
        } else {
            // Portfolio milestone - use preferred currency
            return dataModel.preferredCurrency
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Image(systemName: alert.isEnabled ? "bell.fill" : "bell.slash")
                .font(.caption)
                .foregroundColor(alert.isEnabled ? .blue : .secondary)
                .frame(width: 20)

            // Alert details
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.symbol ?? "Portfolio")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(alert.condition.description) \(alert.formattedThreshold(currency: currency))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Last triggered
            if let lastTriggered = alert.lastTriggered {
                Text(timeAgo(from: lastTriggered))
                    .font(.caption2)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }

            // Actions
            HStack(spacing: 4) {
                Button(action: {
                    alertService.toggleAlert(id: alert.id)
                }) {
                    Image(systemName: alert.isEnabled ? "pause.circle" : "play.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(alert.isEnabled ? "Disable alert" : "Enable alert")

                Button(action: {
                    alertService.removeAlert(id: alert.id)
                }) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete alert")
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
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
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    private var availableSymbols: [String] {
        dataModel.realTimeTrades.map { $0.trade.name }.sorted()
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Price Alert")
                .font(.headline)
                .padding(.top)

            // Symbol picker
            HStack {
                Text("Symbol:")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $selectedSymbol) {
                    Text("Select...").tag("")
                    ForEach(availableSymbols, id: \.self) { symbol in
                        Text(symbol).tag(symbol)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            // Condition picker
            HStack {
                Text("Condition:")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $selectedCondition) {
                    ForEach(AlertCondition.allCases, id: \.self) { condition in
                        Text(condition.description).tag(condition)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            // Threshold input
            HStack {
                Text("Threshold:")
                    .frame(width: 80, alignment: .leading)
                TextField(thresholdPlaceholder, text: $thresholdValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Text(thresholdUnit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if showError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Alert") {
                    addAlert()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSymbol.isEmpty || thresholdValue.isEmpty)
            }
            .padding(.bottom)
        }
        .padding()
        .frame(width: 350)
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
        guard let threshold = Double(thresholdValue) else {
            showError = true
            errorMessage = "Please enter a valid number"
            return
        }

        guard threshold > 0 else {
            showError = true
            errorMessage = "Threshold must be positive"
            return
        }

        if selectedCondition == .percentChange && threshold > 100 {
            showError = true
            errorMessage = "Percentage must be between 0 and 100"
            return
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
