import Foundation

enum StockbarAcceptanceAlertsFixtureError: Error, Equatable, LocalizedError {
    case notARegularFile
    case notOwnerOnly
    case tooLarge
    case unreadable(String)
    case notMadeUp(String)

    var errorDescription: String? {
        switch self {
        case .notARegularFile: "the alerts fixture is not a regular file"
        case .notOwnerOnly: "the alerts fixture must be owned by this user and readable by no one else"
        case .tooLarge: "the alerts fixture is too large"
        case .unreadable(let message): "the alerts fixture could not be read: \(message)"
        case .notMadeUp(let symbol): "the alerts fixture names \(symbol), which is not a symbol Stockbar accepts"
        }
    }
}

/// Made-up price alerts for the acceptance copy, so the Alerts page can be
/// looked at with alerts in it.
///
/// Adding or resuming an alert asks macOS for notification permission, which
/// puts a consent dialog on the screen. With `STOCKBAR_ACCEPTANCE_ALERTS`
/// naming a fixture file, `--acceptance-bootstrap` checks it and copies it,
/// owner-only, into the run's root; the app reads only that copy, checks it
/// again, and `PriceAlertService` shows its alerts instead of the stored ones.
/// Both steps happen only in an explicit acceptance run
/// (`StockbarAcceptanceRuntime.isExplicitAcceptanceRun`).
///
/// Seeded alerts are shown only: they are never written to Core Data, never
/// checked against prices and never fire, and nothing they do reaches
/// `UNUserNotificationCenter` (see `PriceAlertService.isShowingFixture`).
///
/// The file must be a regular file, owned by this user and readable by no one
/// else. Each symbol must be one the Python bridge accepts. A symbol that
/// starts with `FAKE` is always shown; any other is shown only while the
/// copy's own portfolio holds it, which in an acceptance run comes only from
/// the stand-in's invented data. Trigger times are given in hours before now,
/// so the fixture does not go stale.
struct StockbarAcceptanceAlertsFixture: Codable, Equatable, Sendable {
    enum Condition: String, Codable, Sendable {
        case above
        case below
        case percentChange

        var alertCondition: AlertCondition {
            switch self {
            case .above: .above
            case .below: .below
            case .percentChange: .percentChange
            }
        }
    }

    struct Alert: Codable, Equatable, Sendable {
        let symbol: String
        let condition: Condition
        let threshold: Double
        /// True shows the alert as paused.
        let paused: Bool?
        /// When it last fired, in hours before now; nil if it never has.
        let triggeredHoursAgo: Double?
    }

    static let fileName = "alerts-fixture.json"
    static let madeUpPrefix = "FAKE"
    static let maximumSize = 16 * 1024

    let version: Int
    let alerts: [Alert]

    /// A symbol with the made-up prefix and at least one more character.
    static func isMadeUp(_ symbol: String) -> Bool {
        symbol.hasPrefix(madeUpPrefix) && symbol.count > madeUpPrefix.count && isAcceptedSymbol(symbol)
    }

    /// Upper case and accepted by the Python bridge.
    static func isAcceptedSymbol(_ symbol: String) -> Bool {
        symbol == symbol.uppercased() && PythonConfiguration.validateSymbol(symbol)
    }

    /// Whether a seeded alert for `symbol` may be shown, given the symbols the
    /// copy's portfolio holds now.
    static func isShowable(_ symbol: String?, held: Set<String>) -> Bool {
        guard let symbol else { return false }
        return isMadeUp(symbol) || held.contains(symbol)
    }

    /// The alerts as the service holds them, timed from `now`.
    func priceAlerts(now: Date) -> [PriceAlert] {
        alerts.map { seed in
            PriceAlert(
                symbol: seed.symbol,
                condition: seed.condition.alertCondition,
                threshold: seed.threshold,
                isEnabled: !(seed.paused ?? false),
                createdAt: now,
                lastTriggered: seed.triggeredHoursAgo.map { now.addingTimeInterval(-$0 * 3_600) }
            )
        }
    }

    /// Reads a fixture: a regular file (not a link), owned by this user and
    /// readable by no one else, small, and naming accepted symbols only.
    static func read(at url: URL, fileManager: FileManager = .default) throws -> Self {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw StockbarAcceptanceAlertsFixtureError.unreadable(error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StockbarAcceptanceAlertsFixtureError.notARegularFile
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard permissions & 0o077 == 0, owner == getuid() else {
            throw StockbarAcceptanceAlertsFixtureError.notOwnerOnly
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maximumSize else {
            throw StockbarAcceptanceAlertsFixtureError.tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StockbarAcceptanceAlertsFixtureError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw StockbarAcceptanceAlertsFixtureError.unreadable(error.localizedDescription)
        }
        guard fixture.version == 1 else {
            throw StockbarAcceptanceAlertsFixtureError.unreadable("unknown version \(fixture.version)")
        }
        if let bad = fixture.alerts.first(where: { !isAcceptedSymbol($0.symbol) }) {
            throw StockbarAcceptanceAlertsFixtureError.notMadeUp(bad.symbol)
        }
        if fixture.alerts.contains(where: {
            !$0.threshold.isFinite || $0.threshold <= 0 || !($0.triggeredHoursAgo ?? 0).isFinite
        }) {
            throw StockbarAcceptanceAlertsFixtureError.unreadable("a threshold or trigger time is not a positive number")
        }
        return fixture
    }

    // MARK: The run's copy

    /// The copy the app reads, in an explicit acceptance run's root, or nil.
    static func copyURL(runtime: StockbarAcceptanceRuntime) -> URL? {
        guard runtime.isExplicitAcceptanceRun else { return nil }
        return runtime.root?.appendingPathComponent(fileName)
    }

    /// For `--acceptance-bootstrap`: checks the fixture `STOCKBAR_ACCEPTANCE_ALERTS`
    /// names and writes an owner-only copy into the run's root. Does nothing
    /// unless this is an explicit acceptance run and the option is given.
    ///
    /// - Returns: True when a copy was written.
    @discardableResult
    static func installCopy(environment: [String: String], runtime: StockbarAcceptanceRuntime,
                            fileManager: FileManager = .default) throws -> Bool {
        let options = StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: runtime)
        guard options.usesAlertsFixture, let destination = copyURL(runtime: runtime),
              let source = environment[StockbarAcceptanceLaunchOptions.alertsKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let fixture = try read(at: URL(fileURLWithPath: source), fileManager: fileManager)
        let data = try JSONEncoder().encode(fixture)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw StockbarAcceptanceAlertsFixtureError.unreadable("the run's copy could not be written")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw StockbarAcceptanceAlertsFixtureError.unreadable("the run's copy could not be written")
        }
        return true
    }

    /// The run's copy, read and checked, when the option is on in an explicit
    /// acceptance run; nil otherwise. Throws when the option is on and the
    /// copy is missing or fails a check.
    static func load(options: StockbarAcceptanceLaunchOptions, runtime: StockbarAcceptanceRuntime,
                     fileManager: FileManager = .default) throws -> Self? {
        guard runtime.isExplicitAcceptanceRun, options.usesAlertsFixture,
              let url = copyURL(runtime: runtime) else { return nil }
        return try read(at: url, fileManager: fileManager)
    }

    /// This process's fixture: only in an explicit acceptance run started
    /// with the option. `main.swift` checks it at launch and stops the copy
    /// if it fails, so nil here means no fixture was asked for.
    static let current: Self? = try? load(options: .current, runtime: StockbarRuntimeStorage.acceptance)
}
