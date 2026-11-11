import SwiftUI

/// The "Updates" section of Settings > General: channel, automatic checks and
/// a manual check.
@MainActor
struct UpdateSettingsSection: View {
    @Bindable private var updates = AppUpdateService.shared

    var body: some View {
        Section {
            LabeledContent("Version") {
                Text(updates.versionDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let explanation = updates.availability.explanation {
                Text(explanation)
                    .foregroundStyle(.secondary)
            } else {
                Picker(selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                } label: {
                    Text("Update Channel")
                    Text(updates.channel.detail)
                }
                Toggle(isOn: $updates.automaticallyChecks) {
                    Text("Check Automatically")
                    Text("Looks for a new version about once a day.")
                }
                LabeledContent {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                } label: {
                    Text("Check for Updates")
                    Text(lastCheckedDescription)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            if updates.availability == .available {
                Text("Updates are downloaded from GitHub and checked against Stockbar's signing key before they are installed. After an update, macOS asks once for access to your saved credentials in the Keychain. Moving from Testing to Stable takes effect at the next released version.")
            }
        }
    }

    private var lastCheckedDescription: String {
        guard let date = updates.lastCheckDate else { return "Not checked yet." }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
    }
}
