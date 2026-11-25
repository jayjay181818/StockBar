//
//  InstrumentEventsService.swift
//  Stockbar
//
//  Instrument type, dividend and earnings dates from Yahoo, through
//  `get_instrument_events.py`, kept for a day per symbol.
//

import Foundation

// MARK: - Models

/// Yahoo's `quoteType` for an instrument. A type this build does not know
/// keeps Yahoo's string in `.other`.
enum InstrumentType: Sendable, Equatable, Hashable, Codable {
    case equity
    case etf
    case mutualFund
    case moneyMarket
    case index
    case currency
    case cryptocurrency
    case future
    case option
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "EQUITY": self = .equity
        case "ETF": self = .etf
        case "MUTUALFUND": self = .mutualFund
        case "MONEYMARKET": self = .moneyMarket
        case "INDEX": self = .index
        case "CURRENCY": self = .currency
        case "CRYPTOCURRENCY": self = .cryptocurrency
        case "FUTURE": self = .future
        case "OPTION": self = .option
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .equity: "EQUITY"
        case .etf: "ETF"
        case .mutualFund: "MUTUALFUND"
        case .moneyMarket: "MONEYMARKET"
        case .index: "INDEX"
        case .currency: "CURRENCY"
        case .cryptocurrency: "CRYPTOCURRENCY"
        case .future: "FUTURE"
        case .option: "OPTION"
        case .other(let raw): raw
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A calendar day as Yahoo gives it (`YYYY-MM-DD`), with no time of day or
/// time zone. Whether it is still to come is for the caller to decide with
/// the clock: Yahoo often gives a date that has already passed.
struct InstrumentEventDay: Sendable, Equatable, Hashable, Comparable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(year: year, month: month, day: day)
        guard (1...9999).contains(year),
              components.isValidDate(in: Self.gregorian) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Accepts exactly `YYYY-MM-DD`.
    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The day `date` falls on in `timeZone`.
    static func on(_ date: Date, in timeZone: TimeZone = .current) -> InstrumentEventDay? {
        var calendar = gregorian
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return InstrumentEventDay(year: year, month: month, day: day)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = InstrumentEventDay(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a YYYY-MM-DD date: \(text)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}

/// One dividend Yahoo lists, in the major currency unit (pence already
/// converted to pounds by the script).
struct InstrumentDividend: Sendable, Equatable, Codable {
    let date: InstrumentEventDay
    let amount: Double
}

/// What Yahoo gave for one symbol. Every field Yahoo did not give is nil.
struct InstrumentEvents: Sendable, Equatable, Codable {
    let symbol: String
    let instrumentType: InstrumentType?
    let exDividendDate: InstrumentEventDay?
    let dividendPayDate: InstrumentEventDay?
    /// The earnings date, or the start of Yahoo's range.
    let earningsDate: InstrumentEventDay?
    /// The end of Yahoo's earnings range; nil for a single date.
    let earningsDateEnd: InstrumentEventDay?
    /// Dividends of the twelve months up to `fetchedAt`. Empty when Yahoo
    /// listed none; nil when Yahoo gave no dividend answer.
    let dividends: [InstrumentDividend]?
    let dividendCurrency: String?
    /// When the script asked Yahoo.
    let fetchedAt: Date
}

/// Where the dates came from, so a screen can label them.
enum InstrumentEventsSource: String, Sendable, Equatable, Codable {
    case yahoo
}

enum InstrumentEventsFailure: Sendable, Equatable {
    /// The symbol would not be passed to the script.
    case invalidSymbol
    /// Live providers are off (an acceptance run or XCTest isolation).
    case providerDisabled
    /// Yahoo is limiting requests; no run is made before `retryAfter`.
    case rateLimited(retryAfter: Date)
    case timedOut
    case network
    /// Yahoo had nothing for the symbol.
    case noData
    case providerError(String)
    /// The script could not be run, or its answer could not be read.
    case scriptFailed(String)
}

struct InstrumentEventsResult: Sendable, Equatable {
    enum Freshness: Sendable, Equatable {
        /// Asked for within the last day.
        case current
        /// An older saved copy, kept because Yahoo did not answer.
        case stale(InstrumentEventsFailure)
    }

    enum Outcome: Sendable, Equatable {
        case events(InstrumentEvents, Freshness)
        case failed(InstrumentEventsFailure)
    }

    let symbol: String
    let source: InstrumentEventsSource
    let outcome: Outcome

    var events: InstrumentEvents? {
        if case .events(let events, _) = outcome { return events }
        return nil
    }

    var isStale: Bool {
        if case .events(_, .stale) = outcome { return true }
        return false
    }

    /// When Yahoo gave these dates.
    var fetchedAt: Date? { events?.fetchedAt }

    var failure: InstrumentEventsFailure? {
        switch outcome {
        case .events(_, .current): nil
        case .events(_, .stale(let failure)): failure
        case .failed(let failure): failure
        }
    }
}

// MARK: - Service

/// What asks for instrument events: `InstrumentEventsService`, or a stand-in in tests.
protocol InstrumentEventsProviding: Sendable {
    func events(for symbols: [String], forceRefresh: Bool) async -> [InstrumentEventsResult]
}

extension InstrumentEventsService: InstrumentEventsProviding {}

/// Instrument events from Yahoo, saved for a day per symbol.
///
/// Symbols that are missing or older than a day are fetched together in one
/// script run, and callers asking at the same time share it. When Yahoo does
/// not answer, a saved copy of any age is returned marked stale. After a
/// rate-limit answer no run is made for an hour, forced or not. A symbol
/// Yahoo has nothing for is not asked for again that day unless forced. The script
/// runs only when `StockbarProviderAccessPolicy` allows the Python bridge.
///
/// In an explicit acceptance run started with the events fixture
/// (`StockbarAcceptanceEventsFixture`), the fixture answers in place of the
/// script, through the same reading, saving and pausing, and the script is
/// never run.
actor InstrumentEventsService {
    static let shared = InstrumentEventsService(fixture: StockbarAcceptanceEventsFixture.current)

    /// Whether events can be had in this run: live providers are on, or the
    /// acceptance fixture answers. Read without asking anything.
    static var canAnswer: Bool {
        StockbarProviderAccessPolicy.current.liveRequestsAllowed || StockbarAcceptanceEventsFixture.current != nil
    }

    static let scriptName = "get_instrument_events.py"
    static let freshnessInterval: TimeInterval = 24 * 60 * 60
    static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60
    static let rateLimitPause: TimeInterval = 60 * 60

    private struct SavedEntry: Codable {
        let version: Int
        let receivedAt: Date
        let events: InstrumentEvents
    }

    private struct RunOutcome: Sendable {
        /// Symbols the run did not answer, and why. Every other symbol was saved.
        let failures: [String: InstrumentEventsFailure]
    }

    private struct InFlightRun {
        let id: UUID
        let symbols: Set<String>
        let task: Task<RunOutcome, Never>
    }

    private let scriptPath: String?
    private let processRunner: any PythonProcessRunning
    private let providerPolicy: StockbarProviderAccessPolicy
    private let directory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let fixture: StockbarAcceptanceEventsFixture?

    private var saved: [String: SavedEntry] = [:]
    private var lookedOnDisk: Set<String> = []
    private var hasRemovedOldEntries = false
    private var pausedUntil: Date?
    /// Symbols Yahoo had nothing for, and until when they are not asked for
    /// again. In memory only: after a relaunch each is asked for once more.
    private var unanswered: [String: Date] = [:]
    private var inFlight: InFlightRun?
    /// How many callers waited on a run another caller started (for tests).
    private(set) var sharedRunWaits = 0

    init(
        scriptPath: String? = nil,
        processRunner: (any PythonProcessRunning)? = nil,
        providerPolicy: StockbarProviderAccessPolicy = .current,
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        fixture: StockbarAcceptanceEventsFixture? = nil
    ) {
        self.scriptPath = scriptPath ?? Bundle.main.path(forResource: "get_instrument_events", ofType: "py")
        self.processRunner = processRunner ?? PythonProcessRunner()
        self.providerPolicy = providerPolicy
        self.fileManager = fileManager
        self.directory = directory ?? StockbarRuntimeStorage
            .stockbarApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("InstrumentEvents", isDirectory: true)
        self.now = now
        self.fixture = fixture
    }

    /// One result for each distinct symbol, in the order first asked.
    /// `forceRefresh` asks Yahoo again even inside the day, but never during
    /// a rate-limit pause or when live providers are off.
    func events(for symbols: [String], forceRefresh: Bool = false) async -> [InstrumentEventsResult] {
        removeOldEntriesOnce()

        var order: [String] = []
        var seen = Set<String>()
        for raw in symbols {
            let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if seen.insert(symbol).inserted { order.append(symbol) }
        }
        let valid = order.filter { PythonConfiguration.validateSymbol($0) }
        if valid.count != order.count {
            await Logger.shared.warning(
                "Skipping \(order.count - valid.count) invalid symbol(s) for instrument events"
            )
        }

        var settled = Set<String>()
        var failures: [String: InstrumentEventsFailure] = [:]
        while true {
            let needed = valid.filter {
                !settled.contains($0) && (forceRefresh || (!isFresh($0) && !isKnownUnanswered($0)))
            }
            guard !needed.isEmpty else { break }

            if let current = inFlight {
                // Share a run already under way; runs never overlap.
                sharedRunWaits += 1
                let outcome = await current.task.value
                for symbol in needed where current.symbols.contains(symbol) {
                    settled.insert(symbol)
                    if let failure = outcome.failures[symbol] { failures[symbol] = failure }
                }
                continue
            }

            if let refusal = refusal() {
                for symbol in needed {
                    settled.insert(symbol)
                    failures[symbol] = refusal
                }
                break
            }

            let run = startRun(needed)
            let outcome = await run.task.value
            for symbol in needed {
                settled.insert(symbol)
                if let failure = outcome.failures[symbol] { failures[symbol] = failure }
            }
        }

        return order.map { symbol in
            guard valid.contains(symbol) else {
                return InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .failed(.invalidSymbol))
            }
            let entry = savedEntry(symbol)
            if let failure = failures[symbol] {
                if let entry {
                    return InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .events(entry.events, .stale(failure)))
                }
                return InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .failed(failure))
            }
            if let entry {
                let freshness: InstrumentEventsResult.Freshness = isFresh(symbol) ? .current : .stale(.noData)
                return InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .events(entry.events, freshness))
            }
            return InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .failed(.noData))
        }
    }

    // MARK: Running the script

    private func refusal() -> InstrumentEventsFailure? {
        if fixture != nil {
            // The acceptance fixture answers; no provider is asked.
            if let pausedUntil, now() < pausedUntil { return .rateLimited(retryAfter: pausedUntil) }
            return nil
        }
        do {
            try providerPolicy.authorize(.python)
        } catch {
            return .providerDisabled
        }
        if let pausedUntil, now() < pausedUntil {
            return .rateLimited(retryAfter: pausedUntil)
        }
        guard let scriptPath, !scriptPath.isEmpty else {
            return .scriptFailed("\(Self.scriptName) is missing from the app")
        }
        return nil
    }

    private func startRun(_ symbols: [String]) -> InFlightRun {
        let id = UUID()
        // The task starts on this actor only after this method returns, so
        // `inFlight` is set before anyone else can look at it.
        let task = Task { await self.perform(symbols, runID: id) }
        let run = InFlightRun(id: id, symbols: Set(symbols), task: task)
        inFlight = run
        return run
    }

    private func perform(_ symbols: [String], runID: UUID) async -> RunOutcome {
        let outcome = await runScript(symbols)
        if inFlight?.id == runID { inFlight = nil }
        return outcome
    }

    private func runScript(_ symbols: [String]) async -> RunOutcome {
        if let fixture {
            return readAnswer(fixture.answer(for: symbols, now: now()), for: symbols)
        }
        guard let scriptPath else {
            return RunOutcome(failures: Self.all(symbols, .scriptFailed("\(Self.scriptName) is missing from the app")))
        }
        // As for quote batches: the script stops starting symbols when its own
        // budget runs out; the process timeout is the backstop.
        let timeout = min(300, max(45, 30 + Double(symbols.count) * 5))
        let budget = Int(timeout - 15)
        do {
            let result = try await processRunner.run(
                arguments: [scriptPath, "--json", "--deadline-seconds", String(budget)] + symbols,
                timeoutSeconds: timeout,
                logContext: "Instrument events (\(symbols.count) symbols)"
            )
            return readAnswer(result.stdout, for: symbols)
        } catch is ProviderAccessError {
            return RunOutcome(failures: Self.all(symbols, .providerDisabled))
        } catch NetworkError.timeout {
            await Logger.shared.warning("Instrument events run timed out for \(symbols.count) symbol(s)")
            return RunOutcome(failures: Self.all(symbols, .timedOut))
        } catch {
            await Logger.shared.warning("Instrument events run failed: \(error.localizedDescription)")
            return RunOutcome(failures: Self.all(symbols, .scriptFailed(error.localizedDescription)))
        }
    }

    private func readAnswer(_ stdout: Data, for symbols: [String]) -> RunOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) else {
            return RunOutcome(failures: Self.all(symbols, .scriptFailed("The script's answer was not JSON")))
        }
        if let error = object as? [String: Any] {
            let code = error["error_code"] as? String
            let message = error["message"] as? String ?? "The script failed"
            if code == "RATE_LIMIT" {
                return RunOutcome(failures: Self.all(symbols, startPause()))
            }
            return RunOutcome(failures: Self.all(symbols, .scriptFailed(message)))
        }
        guard let envelopes = object as? [[String: Any]] else {
            return RunOutcome(failures: Self.all(symbols, .scriptFailed("The script's answer was not a list")))
        }

        var bySymbol: [String: [String: Any]] = [:]
        for envelope in envelopes {
            guard let symbol = (envelope["symbol"] as? String)?.uppercased(), bySymbol[symbol] == nil else { continue }
            bySymbol[symbol] = envelope
        }
        if envelopes.contains(where: { Self.errorCode(of: $0) == "RATE_LIMIT" }) {
            _ = startPause()
        }

        let receivedAt = now()
        var failures: [String: InstrumentEventsFailure] = [:]
        for symbol in symbols {
            guard let envelope = bySymbol[symbol] else {
                failures[symbol] = .scriptFailed("No answer for \(symbol)")
                continue
            }
            if envelope["success"] as? Bool == true {
                guard let events = Self.decodeEvents(envelope["events"]), events.symbol.uppercased() == symbol else {
                    failures[symbol] = .scriptFailed("Unreadable answer for \(symbol)")
                    continue
                }
                save(events, symbol: symbol, receivedAt: receivedAt)
                unanswered[symbol] = nil
                continue
            }
            let message = (envelope["error"] as? [String: Any])?["message"] as? String ?? "No data"
            let code = Self.errorCode(of: envelope)
            // A symbol Yahoo does not know stays unknown for the day; asking
            // on every call would only spend requests.
            if code == "NO_DATA" { unanswered[symbol] = receivedAt.addingTimeInterval(Self.freshnessInterval) }
            failures[symbol] = failure(code: code, message: message)
        }
        return RunOutcome(failures: failures)
    }

    private func failure(code: String?, message: String) -> InstrumentEventsFailure {
        switch code {
        case "RATE_LIMIT": .rateLimited(retryAfter: pausedUntil ?? now().addingTimeInterval(Self.rateLimitPause))
        case "TIMEOUT": .timedOut
        case "NETWORK_ERROR": .network
        case "NO_DATA": .noData
        default: .providerError(message)
        }
    }

    private func startPause() -> InstrumentEventsFailure {
        let until = now().addingTimeInterval(Self.rateLimitPause)
        pausedUntil = max(pausedUntil ?? until, until)
        Task { await Logger.shared.warning("Yahoo rate-limited instrument events; pausing them for an hour") }
        return .rateLimited(retryAfter: pausedUntil ?? until)
    }

    private static func errorCode(of envelope: [String: Any]) -> String? {
        (envelope["error"] as? [String: Any])?["error_code"] as? String
    }

    private static func decodeEvents(_ value: Any?) -> InstrumentEvents? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? decoder.decode(InstrumentEvents.self, from: data)
    }

    private static func all(_ symbols: [String], _ failure: InstrumentEventsFailure) -> [String: InstrumentEventsFailure] {
        Dictionary(firstValuesFor: symbols.map { ($0, failure) })
    }

    // MARK: Saved copies

    private func isFresh(_ symbol: String) -> Bool {
        guard let entry = savedEntry(symbol) else { return false }
        let age = now().timeIntervalSince(entry.receivedAt)
        return age >= 0 && age < Self.freshnessInterval
    }

    private func isKnownUnanswered(_ symbol: String) -> Bool {
        guard let until = unanswered[symbol] else { return false }
        if now() < until { return true }
        unanswered[symbol] = nil
        return false
    }

    private func savedEntry(_ symbol: String) -> SavedEntry? {
        if let entry = saved[symbol] { return entry }
        guard lookedOnDisk.insert(symbol).inserted else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: symbol)),
              let entry = try? Self.decoder.decode(SavedEntry.self, from: data),
              entry.events.symbol.uppercased() == symbol else { return nil }
        saved[symbol] = entry
        return entry
    }

    private func save(_ events: InstrumentEvents, symbol: String, receivedAt: Date) {
        let entry = SavedEntry(version: 1, receivedAt: receivedAt, events: events)
        saved[symbol] = entry
        lookedOnDisk.insert(symbol)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entry).write(to: fileURL(for: symbol), options: .atomic)
        } catch {
            Task { await Logger.shared.warning("Could not save instrument events for \(symbol): \(error.localizedDescription)") }
        }
    }

    /// Removes saved copies older than thirty days, once per launch. Symbols
    /// no longer held are never asked for again, so nothing else would.
    private func removeOldEntriesOnce() {
        guard !hasRemovedOldEntries else { return }
        hasRemovedOldEntries = true
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let current = now()
        for file in files where file.lastPathComponent.hasPrefix("events-") && file.pathExtension == "json" {
            let entry = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(SavedEntry.self, from: $0) }
            if let entry, current.timeIntervalSince(entry.receivedAt) <= Self.maximumEntryAge { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    /// Symbols are validated (`A-Z0-9.^=-`, no leading `-`) before they get here.
    private func fileURL(for symbol: String) -> URL {
        directory.appendingPathComponent("events-\(symbol).json")
    }

    /// Reads the script's answer and saved copies (dates as epoch seconds).
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
