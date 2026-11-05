import Combine
import SwiftUI

struct DataSourcesSettingsView: View {
    @ObservedObject var dataModel: DataModel
    
    @State private var fmpApiKey: String = ""
    @State private var twelveDataApiKey: String = ""
    @State private var dataSourcePriority: [String] = []
    @State private var isEditingPriority: Bool = false
    
    // Visibility toggles
    @State private var showFmpKey: Bool = false
    @State private var showTwelveDataKey: Bool = false
    
    // Test/Validation State
    enum VerificationStatus {
        case none
        case verifying
        case success
        case failure
    }
    
    @State private var fmpStatus: VerificationStatus = .none
    @State private var twelveDataStatus: VerificationStatus = .none
    
    // A stored key can be removed; removal is confirmed first.
    @State private var hasStoredFmpKey = false
    @State private var hasStoredTwelveDataKey = false
    @State private var pendingKeyRemoval: String?

    @State private var showingAlert: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    
    // Default priorities including all supported sources
    private let allSources = ["yfinance", "fmp", "twelvedata", "stooq"]
    
    private let configManager = ConfigurationManager.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - API Keys Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("API Keys")
                        .font(.headline)
                    
                    // FMP Key
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Financial Modeling Prep:")
                                .frame(width: 160, alignment: .leading)
                            
                            Group {
                                if showFmpKey {
                                    TextField("Enter API Key", text: $fmpApiKey)
                                } else {
                                    SecureField("Enter API Key", text: $fmpApiKey)
                                }
                            }
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel("Financial Modeling Prep API key")
                            
                            Button(action: { showFmpKey.toggle() }) {
                                Image(systemName: showFmpKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showFmpKey ? "Hide API Key" : "Show API Key")
                            .accessibilityLabel(showFmpKey ? "Hide Financial Modeling Prep API key" : "Show Financial Modeling Prep API key")
                            
                            // Status Indicator and Button
                            HStack(spacing: 4) {
                                statusIndicator(for: fmpStatus)
                                
                                Button(action: {
                                    saveAndTestKey(service: "fmp", key: fmpApiKey)
                                }) {
                                    if fmpStatus == .verifying {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .frame(width: 40)
                                    } else {
                                        Text("Save & Test")
                                    }
                                }
                                .disabled(fmpApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fmpStatus == .verifying)

                                if hasStoredFmpKey {
                                    Button("Remove", role: .destructive) { pendingKeyRemoval = "fmp" }
                                        .disabled(fmpStatus == .verifying)
                                        .help("Remove the stored Financial Modeling Prep API key")
                                        .accessibilityLabel("Remove Financial Modeling Prep API key")
                                }
                            }
                        }
                        Text("Used for US stocks fallback. Free plan allows US historical data.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 164)
                    }
                    
                    // Twelve Data Key
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Twelve Data:")
                                .frame(width: 160, alignment: .leading)
                            
                            Group {
                                if showTwelveDataKey {
                                    TextField("Enter API Key", text: $twelveDataApiKey)
                                } else {
                                    SecureField("Enter API Key", text: $twelveDataApiKey)
                                }
                            }
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .accessibilityLabel("Twelve Data API key")
                            
                            Button(action: { showTwelveDataKey.toggle() }) {
                                Image(systemName: showTwelveDataKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(showTwelveDataKey ? "Hide API Key" : "Show API Key")
                            .accessibilityLabel(showTwelveDataKey ? "Hide Twelve Data API key" : "Show Twelve Data API key")
                            
                            // Status Indicator and Button
                            HStack(spacing: 4) {
                                statusIndicator(for: twelveDataStatus)
                                
                                Button(action: {
                                    saveAndTestKey(service: "twelvedata", key: twelveDataApiKey)
                                }) {
                                    if twelveDataStatus == .verifying {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .frame(width: 40)
                                    } else {
                                        Text("Save & Test")
                                    }
                                }
                                .disabled(twelveDataApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || twelveDataStatus == .verifying)

                                if hasStoredTwelveDataKey {
                                    Button("Remove", role: .destructive) { pendingKeyRemoval = "twelvedata" }
                                        .disabled(twelveDataStatus == .verifying)
                                        .help("Remove the stored Twelve Data API key")
                                        .accessibilityLabel("Remove Twelve Data API key")
                                }
                            }
                        }
                        HStack {
                            Text("Used for LSE/International fallback.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Link("Get Free Key", destination: URL(string: "https://twelvedata.com/")!)
                                .font(.caption)
                        }
                        .padding(.leading, 164)
                    }
                }
                .stockbarCard()

                FolyncDataSourceSection(dataModel: dataModel)

                Trading212DataSourceSection(dataModel: dataModel)
                    .disabled(dataModel.isFolyncPortfolioActive)
                    .overlay(alignment: .topTrailing) {
                        if dataModel.isFolyncPortfolioActive {
                            Text("Inactive while Folync is authoritative")
                                .font(.caption)
                                .padding(6)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                
                // MARK: - Priority Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Fetch Priority")
                            .font(.headline)
                        Spacer()
                        Button(isEditingPriority ? "Done" : "Edit Order") {
                            isEditingPriority.toggle()
                        }
                    }
                    
                    Text("Drag to reorder. The app will attempt to fetch data from sources in this order.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if isEditingPriority {
                        List {
                            ForEach(dataSourcePriority, id: \.self) { source in
                                HStack {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundColor(.secondary)
                                        .accessibilityHidden(true)
                                    sourceLabel(for: source)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .onMove(perform: movePriority)
                        }
                        .frame(height: 200)
                        .listStyle(PlainListStyle())
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(dataSourcePriority.enumerated()), id: \.element) { index, source in
                                HStack {
                                    Text("\(index + 1).")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                        .frame(width: 24)
                                    sourceLabel(for: source)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(StockbarPalette.hoverFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
                .stockbarCard()
                
                Spacer()
            }
            .padding(.horizontal, StockbarLayout.pagePadding)
            .padding(.vertical, 12)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear {
            loadSettings()
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Remove the \(pendingKeyRemoval.map(sourceName(for:)) ?? "API") key?",
            isPresented: Binding(get: { pendingKeyRemoval != nil }, set: { if !$0 { pendingKeyRemoval = nil } }),
            presenting: pendingKeyRemoval
        ) { service in
            Button("Remove Key", role: .destructive) { removeKey(service: service) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Stockbar stops using this source until you enter a key again.")
        }
    }

    private func removeKey(service: String) {
        switch service {
        case "fmp":
            configManager.removeFMPAPIKey()
            fmpApiKey = ""
            fmpStatus = .none
        case "twelvedata":
            configManager.removeTwelveDataAPIKey()
            twelveDataApiKey = ""
            twelveDataStatus = .none
        default:
            return
        }
        refreshStoredKeyFlags()
    }

    private func refreshStoredKeyFlags() {
        hasStoredFmpKey = !(configManager.getFMPAPIKey() ?? "").isEmpty
        hasStoredTwelveDataKey = !(configManager.getTwelveDataAPIKey() ?? "").isEmpty
    }
    
    private func statusIndicator(for status: VerificationStatus) -> some View {
        Group {
            switch status {
            case .none:
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
            case .verifying:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 10, height: 10)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
            }
        }
        .frame(width: 16, height: 16)
        .help(Self.statusDescription(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("API key status")
        .accessibilityValue(Self.statusDescription(status))
    }
    
    static func statusDescription(_ status: VerificationStatus) -> String {
        switch status {
        case .none: return "Not verified"
        case .verifying: return "Verifying"
        case .success: return "Verified"
        case .failure: return "Verification failed"
        }
    }

    private func sourceLabel(for source: String) -> some View {
        HStack {
            Text(sourceName(for: source))
                .fontWeight(.medium)
            
            if source == "yfinance" {
                Text("(Recommended Primary)")
                    .font(.caption)
                    .foregroundColor(.green)
            } else if source == "stooq" {
                Text("(No Key Required)")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
    }
    
    private func sourceName(for source: String) -> String {
        switch source {
        case "yfinance": return "Yahoo Finance (yfinance)"
        case "fmp": return "Financial Modeling Prep"
        case "twelvedata": return "Twelve Data"
        case "stooq": return "Stooq"
        default: return source
        }
    }
    
    private func loadSettings() {
        fmpApiKey = configManager.getFMPAPIKey() ?? ""
        twelveDataApiKey = configManager.getTwelveDataAPIKey() ?? ""
        refreshStoredKeyFlags()
        
        let savedPriority = configManager.getDataSourcePriority()
        if let saved = savedPriority, !saved.isEmpty {
            // Ensure all known sources are present (in case new ones added)
            var merged = saved
            for source in allSources {
                if !merged.contains(source) {
                    merged.append(source)
                }
            }
            dataSourcePriority = merged
        } else {
            dataSourcePriority = allSources
        }
    }
    
    private func movePriority(from source: IndexSet, to destination: Int) {
        dataSourcePriority.move(fromOffsets: source, toOffset: destination)
        configManager.setDataSourcePriority(dataSourcePriority)
    }
    
    private func saveAndTestKey(service: String, key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        // Save first
        if service == "fmp" {
            configManager.setFMPAPIKey(trimmedKey)
            fmpStatus = .verifying
        } else if service == "twelvedata" {
            configManager.setTwelveDataAPIKey(trimmedKey)
            twelveDataStatus = .verifying
        }
        
        refreshStoredKeyFlags()

        // Test
        Task {
            do {
                let isValid = try await dataModel.verifyAPIKey(service: service)
                
                await MainActor.run {
                    if service == "fmp" {
                        fmpStatus = isValid ? .success : .failure
                    } else if service == "twelvedata" {
                        twelveDataStatus = isValid ? .success : .failure
                    }
                    
                    if isValid {
                        alertTitle = "Success"
                        alertMessage = "API key verified successfully!"
                    } else {
                        alertTitle = "Verification Failed"
                        alertMessage = "The API key could not be verified. Please check if it is correct and try again."
                    }
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    if service == "fmp" {
                        fmpStatus = .failure
                    } else if service == "twelvedata" {
                        twelveDataStatus = .failure
                    }
                    
                    alertTitle = "Error"
                    alertMessage = "Verification error: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
}
