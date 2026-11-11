import Foundation
import Observation
import Sparkle

/// Which builds the updater offers.
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    /// Released versions only.
    case stable
    /// Every build of the `testing` branch, as well as released versions.
    case testing

    static let defaultsKey = "updates.channel"
    /// The name testing builds carry in the feed (`<sparkle:channel>`).
    /// `Scripts/release_feed.py` writes the same name.
    static let testingFeedChannel = "testing"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .testing: "Testing"
        }
    }

    var detail: String {
        switch self {
        case .stable: "Released versions only."
        case .testing: "Every change as it lands, before it is released. May be rough."
        }
    }

    /// Feed channels offered besides the default one, which is always offered.
    var allowedFeedChannels: Set<String> {
        self == .testing ? [Self.testingFeedChannel] : []
    }

    static func stored(in defaults: UserDefaults) -> UpdateChannel {
        defaults.string(forKey: defaultsKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}

/// Whether the updater runs in this process, and if not, why.
enum UpdaterAvailability: Equatable, Sendable {
    case available
    /// Built for development: it must not replace itself with a released build.
    case developmentBuild
    /// A test or acceptance run, which may only reach this Mac.
    case isolatedRun
    /// The bundle has no feed address or no public key.
    case notConfigured

    static func resolve(
        isDevelopmentBuild: Bool,
        liveRequestsAllowed: Bool,
        feedURL: String?,
        publicKey: String?
    ) -> UpdaterAvailability {
        guard let feedURL, let host = URL(string: feedURL)?.host, !host.isEmpty,
              let publicKey, !publicKey.isEmpty else {
            return .notConfigured
        }
        if !liveRequestsAllowed, !isLoopback(host: host) {
            return .isolatedRun
        }
        return isDevelopmentBuild ? .developmentBuild : .available
    }

    static func isLoopback(host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// Shown in Settings in place of the controls when updates are off.
    var explanation: String? {
        switch self {
        case .available: nil
        case .developmentBuild: "Updates are off in development builds."
        case .isolatedRun: "Updates are off in an isolated test run."
        case .notConfigured: "This build has no update feed."
        }
    }
}

/// Owns Sparkle's updater: when it runs, which channel it follows, and the
/// state Settings shows. Sparkle downloads, verifies and installs.
@MainActor
@Observable
final class AppUpdateService {
    static let shared = AppUpdateService()

    let availability: UpdaterAvailability
    /// False while a check or an install is under way.
    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?

    var channel: UpdateChannel {
        didSet {
            guard channel != oldValue else { return }
            defaults.set(channel.rawValue, forKey: UpdateChannel.defaultsKey)
            Task { await Logger.shared.info("Update channel set to \(channel.rawValue)") }
            // Look again soon: the other channel may already hold a newer build.
            controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var updaterDelegate: UpdaterDelegate?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        let info = Bundle.main.infoDictionary
        #if DEBUG
        let isDevelopmentBuild = true
        #else
        let isDevelopmentBuild = false
        #endif
        availability = UpdaterAvailability.resolve(
            isDevelopmentBuild: isDevelopmentBuild,
            liveRequestsAllowed: StockbarProviderAccessPolicy.current.liveRequestsAllowed,
            feedURL: info?["SUFeedURL"] as? String,
            publicKey: info?["SUPublicEDKey"] as? String
        )
        defaults = StockbarRuntimeStorage.userDefaults
        channel = UpdateChannel.stored(in: defaults)
        automaticallyChecks = info?["SUEnableAutomaticChecks"] as? Bool ?? false
    }

    /// The version and build number of the running app, for example "3.6.0 (360.14)".
    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Starts the updater once, at launch. Does nothing when updates are off.
    func start() {
        guard availability == .available, controller == nil else {
            if let explanation = availability.explanation {
                Task { await Logger.shared.info("Updater not started: \(explanation)") }
            }
            return
        }
        let delegate = UpdaterDelegate { [weak self] in self?.channel ?? .stable }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        updaterDelegate = delegate
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        }
        Task { await Logger.shared.info("Updater started on the \(channel.rawValue) channel") }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    private func refreshState() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }
}

/// Tells Sparkle which feed channels the chosen update channel may see.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let currentChannel: @MainActor () -> UpdateChannel

    init(currentChannel: @escaping @MainActor () -> UpdateChannel) {
        self.currentChannel = currentChannel
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        currentChannel().allowedFeedChannels
    }
}
