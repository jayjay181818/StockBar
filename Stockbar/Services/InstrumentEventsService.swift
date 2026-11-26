//
//  InstrumentEventsService.swift
//  Stockbar
//
//  Instrument type, dividend and earnings dates from Yahoo, through
//  `get_instrument_events.py`, kept for a day per symbol; and, asked for
//  separately, each symbol's past earnings with their EPS.
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

/// One earnings report of the last twelve months, as Yahoo lists it. The
/// figures are exactly as Yahoo gives them; nil where it gives none.
struct InstrumentPastEarnings: Sendable, Equatable, Codable {
    let date: InstrumentEventDay
    let reportedEPS: Double?
    let estimatedEPS: Double?
    /// Yahoo's surprise, in percent.
    let surprisePercent: Double?
}

/// What Yahoo gave for one symbol's past earnings.
struct InstrumentEarningsHistory: Sendable, Equatable, Codable {
    let symbol: String
    /// The earnings dates of the twelve months up to `fetchedAt`, oldest
    /// first. Empty when Yahoo's earnings page lists none.
    /// The figures are in the company's reporting currency, which Yahoo does
    /// not name, so no currency is kept with them. A copy saved before this
    /// still carries an `epsCurrency` key; decoding ignores it.
    let earnings: [InstrumentPastEarnings]
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

/// One symbol's earnings history from Yahoo, or why there is none.
struct InstrumentEarningsHistoryResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        case history(InstrumentEarningsHistory, InstrumentEventsResult.Freshness)
        case failed(InstrumentEventsFailure)
    }

    let symbol: String
    let source: InstrumentEventsSource
    let outcome: Outcome

    var history: InstrumentEarningsHistory? {
        if case .history(let history, _) = outcome { return history }
        return nil
    }

    var isStale: Bool {
        if case .history(_, .stale) = outcome { return true }
        return false
    }

    var fetchedAt: Date? { history?.fetchedAt }

    var failure: InstrumentEventsFailure? {
        switch outcome {
        case .history(_, .current): nil
        case .history(_, .stale(let failure)): failure
        case .failed(let failure): failure
        }
    }
}

/// An answer from Yahoo of either kind, as the notices read it.
protocol InstrumentYahooAnswer {
    var failure: InstrumentEventsFailure? { get }
    var isStale: Bool { get }
    var fetchedAt: Date? { get }
    /// Something is shown for the symbol, current or saved.
    var hasAnswer: Bool { get }
}

/// An answer's state alone, so answers of both kinds can be read together.
struct InstrumentAnswerState: InstrumentYahooAnswer, Sendable, Equatable {
    let failure: InstrumentEventsFailure?
    let isStale: Bool
    let fetchedAt: Date?
    let hasAnswer: Bool
}

extension InstrumentYahooAnswer {
    var answerState: InstrumentAnswerState {
        InstrumentAnswerState(failure: failure, isStale: isStale, fetchedAt: fetchedAt, hasAnswer: hasAnswer)
    }
}

extension InstrumentEventsResult: InstrumentYahooAnswer {
    var hasAnswer: Bool { events != nil }
}

extension InstrumentEarningsHistoryResult: InstrumentYahooAnswer {
    var hasAnswer: Bool { history != nil }
}

/// What a set of answers says about Yahoo, for the pages that show them.
enum InstrumentEventsAnswers {
    /// When Yahoo is rate-limiting: the latest time the service will ask again.
    static func rateLimitedUntil<Results: Sequence>(_ results: Results) -> Date?
    where Results.Element: InstrumentYahooAnswer {
        results.compactMap { result -> Date? in
            if case .rateLimited(let until) = result.failure { return until }
            return nil
        }.max()
    }

    /// Answers shown from an older saved copy because Yahoo did not answer,
    /// with the oldest copy's time.
    static func staleCopies<Results: Sequence>(_ results: Results) -> (count: Int, oldest: Date?)
    where Results.Element: InstrumentYahooAnswer {
        let stale = results.filter(\.isStale)
        return (stale.count, stale.compactMap(\.fetchedAt).min())
    }

    /// Symbols Yahoo did not answer for and nothing is saved, for a reason
    /// other than having no record (network, timeout, the helper failing).
    static func failedWithoutCopy<Results: Sequence>(_ results: Results) -> Int
    where Results.Element: InstrumentYahooAnswer {
        results.filter { result in
            guard !result.hasAnswer, let failure = result.failure else { return false }
            switch failure {
            case .noData, .invalidSymbol, .rateLimited, .providerDisabled: return false
            default: return true
            }
        }.count
    }

    /// Every answer is "live market data is off" with nothing saved.
    static func allRefused<Results: Collection>(_ results: Results) -> Bool
    where Results.Element: InstrumentYahooAnswer {
        !results.isEmpty && results.allSatisfy { $0.failure == .providerDisabled && !$0.hasAnswer }
    }
}

// MARK: - Service

/// What asks for instrument events: `InstrumentEventsService`, or a stand-in in tests.
protocol InstrumentEventsProviding: Sendable {
    func events(for symbols: [String], forceRefresh: Bool) async -> [InstrumentEventsResult]
}

extension InstrumentEventsService: InstrumentEventsProviding {}

/// What asks for past earnings: `InstrumentEventsService`, or a stand-in in tests.
protocol InstrumentEarningsHistoryProviding: Sendable {
    func earningsHistory(for symbols: [String], forceRefresh: Bool) async -> [InstrumentEarningsHistoryResult]
}

extension InstrumentEventsService: InstrumentEarningsHistoryProviding {}

/// What reads the saved copies only: `InstrumentEventsService`, or a stand-in in tests.
protocol InstrumentEventsSavedReading: Sendable {
    func savedEvents(for symbols: [String]) async -> [String: InstrumentEvents]
}

extension InstrumentEventsService: InstrumentEventsSavedReading {}

/// What the service saves for a symbol: either kind of answer.
private protocol InstrumentYahooPayload: Codable, Sendable {
    var symbol: String { get }
}

extension InstrumentEvents: InstrumentYahooPayload {}
extension InstrumentEarningsHistory: InstrumentYahooPayload {}

/// Instrument events from Yahoo, saved for a day per symbol.
///
/// Two kinds of answer, asked for separately:
/// - `events(for:)`: each symbol's type, dividend and earnings dates.
/// - `earningsHistory(for:)`: each symbol's earnings of the last twelve
///   months, with their EPS. Only the Calendar's Past view asks for it.
///
/// For each kind, symbols that are missing or older than a day are fetched
/// together in one script run, and callers asking at the same time share it.
/// Runs never overlap, of either kind. When Yahoo does not answer, a saved
/// copy of any age is returned marked stale. After a rate-limit answer of
/// either kind no run of either kind is made for an hour, forced or not. A
/// symbol Yahoo has nothing for is not asked for again that day unless
/// forced. The script runs only when `StockbarProviderAccessPolicy` allows
/// the Python bridge.
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
    /// The script's argument for the earnings-history mode.
    static let earningsHistoryFlag = "--earnings-history"
    static let freshnessInterval: TimeInterval = 24 * 60 * 60
    static let maximumEntryAge: TimeInterval = 30 * 24 * 60 * 60
    static let rateLimitPause: TimeInterval = 60 * 60

    /// The two kinds of answer.
    private enum Kind: Sendable, Equatable {
        case events
        case earningsHistory

        /// The saved copies' file names start with this.
        var filePrefix: String {
            switch self {
            case .events: "events-"
            case .earningsHistory: "earnings-history-"
            }
        }

        /// The key of a success envelope's answer.
        var answerKey: String {
            switch self {
            case .events: "events"
            case .earningsHistory: "earningsHistory"
            }
        }

        var scriptArguments: [String] {
            switch self {
            case .events: []
            case .earningsHistory: [InstrumentEventsService.earningsHistoryFlag]
            }
        }

        var logName: String {
            switch self {
            case .events: "Instrument events"
            case .earningsHistory: "Earnings history"
            }
        }
    }

    /// A saved copy. Both kinds keep their answer under `events`, so the
    /// copies written before the second kind existed still read.
    private struct SavedEntry<Payload: Codable>: Codable {
        let version: Int
        let receivedAt: Date
        let events: Payload
    }

    /// One kind's saved copies and the symbols Yahoo had nothing for.
    private final class Copies<Payload: InstrumentYahooPayload> {
        let kind: Kind
        var saved: [String: SavedEntry<Payload>] = [:]
        var lookedOnDisk: Set<String> = []
        /// Symbols Yahoo had nothing for, and until when they are not asked
        /// for again. In memory only: after a relaunch each is asked for once more.
        var unanswered: [String: Date] = [:]

        init(kind: Kind) {
            self.kind = kind
        }
    }

    /// One symbol's answer, before it becomes a result of its kind.
    private enum Settled<Payload> {
        case invalidSymbol
        case answer(Payload, InstrumentEventsResult.Freshness)
        case failed(InstrumentEventsFailure)
    }

    private struct RunOutcome: Sendable {
        /// Symbols the run did not answer, and why. Every other symbol was saved.
        let failures: [String: InstrumentEventsFailure]
    }

    private struct InFlightRun {
        let id: UUID
        let kind: Kind
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

    private let eventCopies = Copies<InstrumentEvents>(kind: .events)
    private let historyCopies = Copies<InstrumentEarningsHistory>(kind: .earningsHistory)
    private var hasRemovedOldEntries = false
    /// Shared by both kinds: a rate limit on either pauses both.
    private var pausedUntil: Date?
    private var inFlight: InFlightRun?
    /// How many callers waited on a run another caller started (for tests).
    private(set) var sharedRunWaits = 0
    /// How many runs of each kind were started, the fixture's included (for tests).
    private(set) var eventsRuns = 0
    private(set) var earningsHistoryRuns = 0

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
        await answers(for: symbols, forceRefresh: forceRefresh, copies: eventCopies).map { symbol, settled in
            switch settled {
            case .invalidSymbol: InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .failed(.invalidSymbol))
            case .answer(let events, let freshness):
                InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .events(events, freshness))
            case .failed(let failure): InstrumentEventsResult(symbol: symbol, source: .yahoo, outcome: .failed(failure))
            }
        }
    }

    /// Each distinct symbol's earnings of the last twelve months, in the order
    /// first asked, with its own day-long copies. Asked for only by the
    /// Calendar's Past view. Otherwise as `events(for:)`: one run for every
    /// symbol, the same refusals, and the same rate-limit pause.
    func earningsHistory(for symbols: [String], forceRefresh: Bool = false) async -> [InstrumentEarningsHistoryResult] {
        await answers(for: symbols, forceRefresh: forceRefresh, copies: historyCopies).map { symbol, settled in
            switch settled {
            case .invalidSymbol:
                InstrumentEarningsHistoryResult(symbol: symbol, source: .yahoo, outcome: .failed(.invalidSymbol))
            case .answer(let history, let freshness):
                InstrumentEarningsHistoryResult(symbol: symbol, source: .yahoo, outcome: .history(history, freshness))
            case .failed(let failure):
                InstrumentEarningsHistoryResult(symbol: symbol, source: .yahoo, outcome: .failed(failure))
            }
        }
    }

    /// The copies already saved for `symbols`, of any age, keyed by symbol.
    /// Never runs the script, never asks Yahoo and never starts a pause: for
    /// "Next up", which shows only what is already known.
    func savedEvents(for symbols: [String]) -> [String: InstrumentEvents] {
        var answers: [String: InstrumentEvents] = [:]
        for raw in symbols {
            let symbol = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard answers[symbol] == nil, PythonConfiguration.validateSymbol(symbol),
                  let entry = savedEntry(symbol, in: eventCopies) else { continue }
            answers[symbol] = entry.events
        }
        return answers
    }

    // MARK: Asking

    private func answers<Payload>(for symbols: [String], forceRefresh: Bool,
                                  copies: Copies<Payload>) async -> [(String, Settled<Payload>)] {
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
                "Skipping \(order.count - valid.count) invalid symbol(s) for \(copies.kind.logName.lowercased())"
            )
        }

        var settled = Set<String>()
        var failures: [String: InstrumentEventsFailure] = [:]
        while true {
            let needed = valid.filter {
                !settled.contains($0)
                    && (forceRefresh || (!isFresh($0, in: copies) && !isKnownUnanswered($0, in: copies)))
            }
            guard !needed.isEmpty else { break }

            if let current = inFlight {
                // Share a run of this kind already under way, or wait for one
                // of the other kind to end; runs never overlap.
                sharedRunWaits += 1
                let outcome = await current.task.value
                guard current.kind == copies.kind else { continue }
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

            let run = startRun(needed, kind: copies.kind)
            let outcome = await run.task.value
            for symbol in needed {
                settled.insert(symbol)
                if let failure = outcome.failures[symbol] { failures[symbol] = failure }
            }
        }

        return order.map { symbol in
            guard valid.contains(symbol) else { return (symbol, .invalidSymbol) }
            let entry = savedEntry(symbol, in: copies)
            if let failure = failures[symbol] {
                if let entry { return (symbol, .answer(entry.events, .stale(failure))) }
                return (symbol, .failed(failure))
            }
            if let entry {
                let freshness: InstrumentEventsResult.Freshness = isFresh(symbol, in: copies) ? .current : .stale(.noData)
                return (symbol, .answer(entry.events, freshness))
            }
            return (symbol, .failed(.noData))
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

    private func startRun(_ symbols: [String], kind: Kind) -> InFlightRun {
        let id = UUID()
        switch kind {
        case .events: eventsRuns += 1
        case .earningsHistory: earningsHistoryRuns += 1
        }
        // The task starts on this actor only after this method returns, so
        // `inFlight` is set before anyone else can look at it.
        let task = Task { await self.perform(symbols, kind: kind, runID: id) }
        let run = InFlightRun(id: id, kind: kind, symbols: Set(symbols), task: task)
        inFlight = run
        return run
    }

    private func perform(_ symbols: [String], kind: Kind, runID: UUID) async -> RunOutcome {
        let outcome: RunOutcome
        switch kind {
        case .events: outcome = await runScript(symbols, copies: eventCopies)
        case .earningsHistory: outcome = await runScript(symbols, copies: historyCopies)
        }
        if inFlight?.id == runID { inFlight = nil }
        return outcome
    }

    private func runScript<Payload>(_ symbols: [String], copies: Copies<Payload>) async -> RunOutcome {
        let kind = copies.kind
        if let fixture {
            let answer = switch kind {
            case .events: fixture.answer(for: symbols, now: now())
            case .earningsHistory: fixture.earningsHistoryAnswer(for: symbols, now: now())
            }
            return readAnswer(answer, for: symbols, copies: copies)
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
                arguments: [scriptPath, "--json"] + kind.scriptArguments + ["--deadline-seconds", String(budget)] + symbols,
                timeoutSeconds: timeout,
                logContext: "\(kind.logName) (\(symbols.count) symbols)"
            )
            return readAnswer(result.stdout, for: symbols, copies: copies)
        } catch is ProviderAccessError {
            return RunOutcome(failures: Self.all(symbols, .providerDisabled))
        } catch NetworkError.timeout {
            await Logger.shared.warning("\(kind.logName) run timed out for \(symbols.count) symbol(s)")
            return RunOutcome(failures: Self.all(symbols, .timedOut))
        } catch {
            await Logger.shared.warning("\(kind.logName) run failed: \(error.localizedDescription)")
            return RunOutcome(failures: Self.all(symbols, .scriptFailed(error.localizedDescription)))
        }
    }

    private func readAnswer<Payload>(_ stdout: Data, for symbols: [String], copies: Copies<Payload>) -> RunOutcome {
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
                guard let payload: Payload = Self.decode(envelope[copies.kind.answerKey]),
                      payload.symbol.uppercased() == symbol else {
                    failures[symbol] = .scriptFailed("Unreadable answer for \(symbol)")
                    continue
                }
                save(payload, symbol: symbol, receivedAt: receivedAt, in: copies)
                copies.unanswered[symbol] = nil
                continue
            }
            let message = (envelope["error"] as? [String: Any])?["message"] as? String ?? "No data"
            let code = Self.errorCode(of: envelope)
            // A symbol Yahoo does not know stays unknown for the day; asking
            // on every call would only spend requests.
            if code == "NO_DATA" { copies.unanswered[symbol] = receivedAt.addingTimeInterval(Self.freshnessInterval) }
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

    private static func decode<Payload: Decodable>(_ value: Any?) -> Payload? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? decoder.decode(Payload.self, from: data)
    }

    private static func all(_ symbols: [String], _ failure: InstrumentEventsFailure) -> [String: InstrumentEventsFailure] {
        Dictionary(firstValuesFor: symbols.map { ($0, failure) })
    }

    // MARK: Saved copies

    private func isFresh<Payload>(_ symbol: String, in copies: Copies<Payload>) -> Bool {
        guard let entry = savedEntry(symbol, in: copies) else { return false }
        let age = now().timeIntervalSince(entry.receivedAt)
        guard age >= 0 && age < Self.freshnessInterval else { return false }
        // Past earnings gain their reported figures the evening a company
        // reports, so a history copy is fresh only on the day it was fetched:
        // still at most one run per symbol a day.
        if copies.kind == .earningsHistory {
            return InstrumentEventDay.on(entry.receivedAt) == InstrumentEventDay.on(now())
        }
        return true
    }

    private func isKnownUnanswered<Payload>(_ symbol: String, in copies: Copies<Payload>) -> Bool {
        guard let until = copies.unanswered[symbol] else { return false }
        if now() < until { return true }
        copies.unanswered[symbol] = nil
        return false
    }

    private func savedEntry<Payload>(_ symbol: String, in copies: Copies<Payload>) -> SavedEntry<Payload>? {
        if let entry = copies.saved[symbol] { return entry }
        guard copies.lookedOnDisk.insert(symbol).inserted else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: symbol, kind: copies.kind)),
              let entry = try? Self.decoder.decode(SavedEntry<Payload>.self, from: data),
              entry.events.symbol.uppercased() == symbol else { return nil }
        copies.saved[symbol] = entry
        return entry
    }

    private func save<Payload>(_ payload: Payload, symbol: String, receivedAt: Date, in copies: Copies<Payload>) {
        let entry = SavedEntry(version: 1, receivedAt: receivedAt, events: payload)
        copies.saved[symbol] = entry
        copies.lookedOnDisk.insert(symbol)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(entry).write(to: fileURL(for: symbol, kind: copies.kind), options: .atomic)
        } catch {
            let name = copies.kind.logName.lowercased()
            Task { await Logger.shared.warning("Could not save \(name) for \(symbol): \(error.localizedDescription)") }
        }
    }

    /// Removes saved copies of either kind older than thirty days, once per
    /// launch. Symbols no longer held are never asked for again, so nothing
    /// else would.
    private func removeOldEntriesOnce() {
        guard !hasRemovedOldEntries else { return }
        hasRemovedOldEntries = true
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let current = now()
        func keep<Payload: InstrumentYahooPayload>(_ file: URL, as _: Payload.Type) -> Bool {
            let entry = (try? Data(contentsOf: file)).flatMap { try? Self.decoder.decode(SavedEntry<Payload>.self, from: $0) }
            guard let entry else { return false }
            return current.timeIntervalSince(entry.receivedAt) <= Self.maximumEntryAge
        }
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent
            let kept: Bool
            if name.hasPrefix(Kind.events.filePrefix) {
                kept = keep(file, as: InstrumentEvents.self)
            } else if name.hasPrefix(Kind.earningsHistory.filePrefix) {
                kept = keep(file, as: InstrumentEarningsHistory.self)
            } else {
                continue
            }
            if !kept { try? fileManager.removeItem(at: file) }
        }
    }

    /// Symbols are validated (`A-Z0-9.^=-`, no leading `-`) before they get here.
    private func fileURL(for symbol: String, kind: Kind) -> URL {
        directory.appendingPathComponent("\(kind.filePrefix)\(symbol).json")
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
