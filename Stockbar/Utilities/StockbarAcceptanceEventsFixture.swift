import Foundation

enum StockbarAcceptanceEventsFixtureError: Error, Equatable, LocalizedError {
    case notARegularFile
    case notOwnerOnly
    case tooLarge
    case unreadable(String)
    case notMadeUp(String)

    var errorDescription: String? {
        switch self {
        case .notARegularFile: "the instrument events fixture is not a regular file"
        case .notOwnerOnly: "the instrument events fixture must be owned by this user and readable by no one else"
        case .tooLarge: "the instrument events fixture is too large"
        case .unreadable(let message): "the instrument events fixture could not be read: \(message)"
        case .notMadeUp(let symbol): "the instrument events fixture names \(symbol), which is not a made-up symbol"
        }
    }
}

/// Made-up dividend and date answers for the acceptance copy, in place of Yahoo.
///
/// An acceptance run denies Yahoo, so the Income estimate for a local
/// portfolio could not be looked at there. With `STOCKBAR_ACCEPTANCE_EVENTS`
/// naming a fixture file, `--acceptance-bootstrap` checks it and copies it,
/// owner-only, into the run's root; the app then reads only that copy, checks
/// it again, and `InstrumentEventsService` answers from it instead of running
/// the helper. Both steps happen only in an explicit acceptance run
/// (`StockbarAcceptanceRuntime.isExplicitAcceptanceRun`), never in a normal
/// run or under the automatic XCTest isolation.
///
/// The file must be a regular file, owned by this user and readable by no one
/// else, and every symbol in it must be made up: it starts with `FAKE`.
/// Dates are given in days from today, so the fixture does not go stale.
struct StockbarAcceptanceEventsFixture: Codable, Equatable, Sendable {
    struct Dividend: Codable, Equatable, Sendable {
        let daysFromToday: Int
        let amount: Double
    }

    struct Holding: Codable, Equatable, Sendable {
        let symbol: String
        let instrumentType: String?
        /// The currency Yahoo would give the dividends in.
        let currency: String?
        /// Nil gives no dividend answer, as Yahoo can.
        let dividends: [Dividend]?
        let exDividendInDays: Int?
        let payInDays: Int?
        let earningsInDays: Int?
    }

    static let fileName = "instrument-events-fixture.json"
    static let madeUpPrefix = "FAKE"
    static let maximumSize = 64 * 1024

    let version: Int
    let holdings: [Holding]

    /// Whether `symbol` is one the fixture may name: the made-up prefix, then
    /// at least one more character, and a symbol the Python bridge accepts.
    static func isMadeUp(_ symbol: String) -> Bool {
        symbol.hasPrefix(madeUpPrefix) && symbol.count > madeUpPrefix.count
            && symbol == symbol.uppercased() && PythonConfiguration.validateSymbol(symbol)
    }

    /// Reads a fixture: a regular file (not a link), owned by this user and
    /// readable by no one else, small, and naming made-up symbols only.
    static func read(at url: URL, fileManager: FileManager = .default) throws -> Self {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw StockbarAcceptanceEventsFixtureError.unreadable(error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StockbarAcceptanceEventsFixtureError.notARegularFile
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard permissions & 0o077 == 0, owner == getuid() else {
            throw StockbarAcceptanceEventsFixtureError.notOwnerOnly
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maximumSize else {
            throw StockbarAcceptanceEventsFixtureError.tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StockbarAcceptanceEventsFixtureError.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        let fixture: Self
        do {
            fixture = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw StockbarAcceptanceEventsFixtureError.unreadable(error.localizedDescription)
        }
        guard fixture.version == 1 else {
            throw StockbarAcceptanceEventsFixtureError.unreadable("unknown version \(fixture.version)")
        }
        if let real = fixture.holdings.first(where: { !isMadeUp($0.symbol) }) {
            throw StockbarAcceptanceEventsFixtureError.notMadeUp(real.symbol)
        }
        return fixture
    }

    // MARK: The run's copy

    /// The copy the app reads, in an explicit acceptance run's root, or nil.
    static func copyURL(runtime: StockbarAcceptanceRuntime) -> URL? {
        guard runtime.isExplicitAcceptanceRun else { return nil }
        return runtime.root?.appendingPathComponent(fileName)
    }

    /// For `--acceptance-bootstrap`: checks the fixture `STOCKBAR_ACCEPTANCE_EVENTS`
    /// names and writes an owner-only copy into the run's root. Does nothing
    /// unless this is an explicit acceptance run and the option is given.
    ///
    /// - Returns: True when a copy was written.
    @discardableResult
    static func installCopy(environment: [String: String], runtime: StockbarAcceptanceRuntime,
                            fileManager: FileManager = .default) throws -> Bool {
        let options = StockbarAcceptanceLaunchOptions.resolve(environment: environment, runtime: runtime)
        guard options.usesInstrumentEventsFixture, let destination = copyURL(runtime: runtime),
              let source = environment[StockbarAcceptanceLaunchOptions.eventsKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let fixture = try read(at: URL(fileURLWithPath: source), fileManager: fileManager)
        let data = try JSONEncoder().encode(fixture)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw StockbarAcceptanceEventsFixtureError.unreadable("the run's copy could not be written")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw StockbarAcceptanceEventsFixtureError.unreadable("the run's copy could not be written")
        }
        return true
    }

    /// The run's copy, read and checked, when the option is on in an explicit
    /// acceptance run; nil otherwise. Throws when the option is on and the
    /// copy is missing or fails a check.
    static func load(options: StockbarAcceptanceLaunchOptions, runtime: StockbarAcceptanceRuntime,
                     fileManager: FileManager = .default) throws -> Self? {
        guard runtime.isExplicitAcceptanceRun, options.usesInstrumentEventsFixture,
              let url = copyURL(runtime: runtime) else { return nil }
        return try read(at: url, fileManager: fileManager)
    }

    /// This process's fixture: only in an explicit acceptance run started
    /// with the option. `main.swift` checks it at launch and stops the copy
    /// if it fails, so nil here means no fixture was asked for.
    static let current: Self? = try? load(options: .current, runtime: StockbarRuntimeStorage.acceptance)

    // MARK: Answering

    /// What `get_instrument_events.py --json` would print for `symbols`,
    /// from the fixture: each symbol it names answered, any other "no data".
    func answer(for symbols: [String], now: Date, timeZone: TimeZone = .current) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int?) -> Any {
            guard let offset, let date = calendar.date(byAdding: .day, value: offset, to: today) else { return NSNull() }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let bySymbol = Dictionary(holdings.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let envelopes: [[String: Any]] = symbols.map { symbol in
            guard let holding = bySymbol[symbol] else {
                return ["symbol": symbol, "success": false,
                        "error": ["error_code": "NO_DATA", "message": "No data in the acceptance fixture"]]
            }
            let dividends: Any = holding.dividends.map { list in
                list.filter { $0.amount.isFinite }.map { ["date": day($0.daysFromToday), "amount": $0.amount] as [String: Any] }
            } ?? NSNull()
            let events: [String: Any] = [
                "symbol": symbol,
                "instrumentType": holding.instrumentType ?? NSNull(),
                "exDividendDate": day(holding.exDividendInDays),
                "dividendPayDate": day(holding.payInDays),
                "earningsDate": day(holding.earningsInDays),
                "earningsDateEnd": NSNull(),
                "dividends": dividends,
                "dividendCurrency": holding.currency ?? NSNull(),
                "fetchedAt": now.timeIntervalSince1970
            ]
            return ["symbol": symbol, "success": true, "events": events]
        }
        return (try? JSONSerialization.data(withJSONObject: envelopes)) ?? Data("[]".utf8)
    }
}
