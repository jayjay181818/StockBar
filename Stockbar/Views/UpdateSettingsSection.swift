import SwiftUI

/// The "Updates" section of Settings > General: channel, automatic checks and
/// a manual check.
@MainActor
struct UpdateSettingsSection: View {
    @Bindable private var updates = AppUpdateService.shared

    var body: some View {
        StockbarSettingsSection(
            "Updates",
            footer: updates.availability == .available
                ? "Updates are downloaded from GitHub and checked against Stockbar's signing key before they are installed. After an update, macOS asks once for access to your saved credentials in the Keychain. A change of channel takes effect once that channel has a build newer than this one."
                : nil
        ) {
            StockbarSettingsRow("Version") {
                Text(updates.versionDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let explanation = updates.availability.explanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                StockbarSettingsRow("Update Channel", detail: updates.channel.detail) {
                    Picker("Update Channel", selection: $updates.channel) {
                        ForEach(UpdateChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                }
                StockbarSettingsRow("Check Automatically", detail: "Looks for a new version about once a day.") {
                    Toggle("Check Automatically", isOn: $updates.automaticallyChecks)
                }
                StockbarSettingsRow("Check for Updates", detail: lastCheckedDescription) {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
    }

    private var lastCheckedDescription: String {
        guard let date = updates.lastCheckDate else { return "Not checked yet." }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
    }
}
