import Foundation

enum StockbarAcceptanceHoldingsFixtureError: Error, Equatable, LocalizedError {
    case notARegularFile
    case notOwnerOnly
    case tooLarge
    case unreadable(String)
    case notMadeUp(String)
    case badFigure(String)

    var errorDescription: String? {
        switch self {
        case .notARegularFile: "the holdings fixture is not a regular file"
        case .notOwnerOnly: "the holdings fixture must be owned by this user and readable by no one else"
        case .tooLarge: "the holdings fixture is too large"
        case .unreadable(let message): "the holdings fixture could not be read: \(message)"
        case .notMadeUp(let symbol): "the holdings fixture names \(symbol), which is not a made-up symbol"
        case .badFigure(let symbol): "the holdings fixture gives \(symbol) units or a cost that is not a positive number"
        }
    }
}

/// Made-up local holdings for the acceptance copy, so a local portfolio's
/// pages (the Calendar with the events fixture, above all) can be looked at
/// without typing holdings into the copy.
///
/// With `STOCKBAR_ACCEPTANCE_HOLDINGS` naming a fixture file,
/// `--acceptance-bootstrap` checks it and copies it, owner-only, into the
/// run's root. At launch, before the data model exists, the app checks that
/// copy again and, in a fresh copy only (no portfolio stored yet), writes its
/// holdings into the copy's own isolated defaults, where the first launch
/// moves them into the copy's Core Data store, and switches Folync off for the
/// copy, so it opens on the local portfolio. Both steps happen only in an
/// explicit acceptance run (`StockbarAcceptanceRuntime.isExplicitAcceptanceRun`),
/// never in a normal run or under the automatic XCTest isolation.
///
/// The file must be a regular file, owned by this user and readable by no one
/// else, and every symbol must be made up: it starts with `FAKE`. Units must be
/// a positive number and the average cost a positive number or absent.
struct StockbarAcceptanceHoldingsFixture: Codable, Equatable, Sendable {
    struct Holding: Codable, Equatable, Sendable {
        let symbol: String
        let units: Double
        /// Per unit, in `costCurrency`.
        let averageCost: Double?
        /// "USD", "GBP", "GBX", "EUR"…; nil leaves it to the app's own rule.
        let costCurrency: String?
    }

    static let fileName = "holdings-fixture.json"
    static let maximumSize = 64 * 1024
    /// The copy's defaults key for its holdings before they reach Core Data.
    static let legacyTradesKey = "usertrades"

    let version: Int
    let holdings: [Holding]

    /// Whether `symbol` is one the fixture may name: the events fixture's rule.
    static func isMadeUp(_ symbol: String) -> Bool {
        StockbarAcceptanceEventsFixture.isMadeUp(symbol)
    }

    /// Reads a fixture: a regular file (not a link), owned by this user and
    /// readable by no one else, small, and naming made-up symbols only.
    static func read(at url: URL, fileManager: FileManager = .default) throws -> Self {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable(error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StockbarAcceptanceHoldingsFixtureError.notARegularFile
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard permissions & 0o077 == 0, owner == getuid() else {
            throw StockbarAcceptanceHoldingsFixtureError.notOwnerOnly
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maximumSize else {
            throw StockbarAcceptanceHoldingsFixtureError.tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable(error.localizedDescription)
        }
        guard fixture.version == 1 else {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable("unknown version \(fixture.version)")
        }
        guard !fixture.holdings.isEmpty else {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable("it lists no holdings")
        }
        for holding in fixture.holdings {
            guard isMadeUp(holding.symbol) else { throw StockbarAcceptanceHoldingsFixtureError.notMadeUp(holding.symbol) }
            guard holding.units.isFinite, holding.units > 0,
                  holding.averageCost.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw StockbarAcceptanceHoldingsFixtureError.badFigure(holding.symbol)
            }
        }
        return fixture
    }

    /// The holdings as the app stores them.
    var trades: [Trade] {
        holdings.map { holding in
            Trade(name: holding.symbol,
                  position: Position(unitSize: Self.text(holding.units),
                                     positionAvgCost: holding.averageCost.map(Self.text) ?? "",
                                     costCurrency: holding.costCurrency))
        }
    }

    private static func text(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: The run's copy

    /// The copy the app reads, in an explicit acceptance run's root, or nil.
    static func copyURL(runtime: StockbarAcceptanceRuntime) -> URL? {
        guard runtime.isExplicitAcceptanceRun else { return nil }
        return runtime.root?.appendingPathComponent(fileName)
    }

    /// For `--acceptance-bootstrap`: checks the fixture `STOCKBAR_ACCEPTANCE_HOLDINGS`
    /// names and writes an owner-only copy into the run's root. Does nothing
    /// unless this is an explicit acceptance run and the option is given.
    ///
    /// - Returns: True when a copy was written.
    @discardableResult
    static func installCopy(environment: [String: String], runtime: StockbarAcceptanceRuntime,
                            fileManager: FileManager = .default) throws -> Bool {
        let options = StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: runtime)
        guard options.usesHoldingsFixture, let destination = copyURL(runtime: runtime),
              let source = environment[StockbarAcceptanceLaunchOptions.holdingsKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let fixture = try read(at: URL(fileURLWithPath: source), fileManager: fileManager)
        let data = try JSONEncoder().encode(fixture)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw StockbarAcceptanceHoldingsFixtureError.unreadable("the run's copy could not be written")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw StockbarAcceptanceHoldingsFixtureError.unreadable("the run's copy could not be written")
        }
        return true
    }

    /// The run's copy, read and checked, when the option is on in an explicit
    /// acceptance run; nil otherwise. Throws when the option is on and the
    /// copy is missing or fails a check.
    static func load(options: StockbarAcceptanceLaunchOptions, runtime: StockbarAcceptanceRuntime,
                     fileManager: FileManager = .default) throws -> Self? {
        guard runtime.isExplicitAcceptanceRun, options.usesHoldingsFixture,
              let url = copyURL(runtime: runtime) else { return nil }
        return try read(at: url, fileManager: fileManager)
    }

    /// At launch, before the data model exists: in a fresh acceptance copy
    /// started with the option, writes the run's holdings into the copy's own
    /// `defaults` and switches Folync off there. A copy that already has a
    /// portfolio, Core Data's or one waiting to move there, is left as it is.
    ///
    /// - Returns: True when the holdings were written.
    @discardableResult
    static func seedIfRequested(options: StockbarAcceptanceLaunchOptions, runtime: StockbarAcceptanceRuntime,
                                defaults: @autoclosure () -> UserDefaults,
                                fileManager: FileManager = .default) throws -> Bool {
        guard let fixture = try load(options: options, runtime: runtime, fileManager: fileManager) else { return false }
        let defaults = defaults()
        guard !defaults.bool(forKey: DataModel.coreDataPortfolioEstablishedKey),
              defaults.object(forKey: legacyTradesKey) == nil else { return false }
        defaults.set(try JSONEncoder().encode(fixture.trades), forKey: legacyTradesKey)
        FolyncSettingsStore(defaults: defaults).setEnabled(false)
        return true
    }
}
