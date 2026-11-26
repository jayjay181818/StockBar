import Foundation
import Observation

/// What Calendar is shown for, read from `DataModel` by the view.
struct StockbarCalendarInputs: Equatable {
    /// Folync is enabled: dividends are Folync's, as on the Income page.
    let isFolyncEnabled: Bool
    let isFolyncPortfolio: Bool
    /// The holdings, each with the symbol Yahoo is asked about for earnings.
    let holdings: [CalendarHolding]
    /// The same holdings with their units, for the local estimate.
    let localHoldings: [LocalIncomeHolding]
}

/// The Calendar page's state, and the only place it asks for anything.
///
/// Calendar asks for nothing the Income page does not, plus Yahoo's earnings
/// dates. It is built from the Income page's own models:
/// - for Folync, `StockbarIncomeModel`, which sends Income's one dividends
///   query, so the fetch policy answers both pages from one request within
///   five minutes;
/// - for a local or Trading 212 portfolio, `StockbarLocalIncomeModel`, whose
///   one events call gives both the dividend estimate and the earnings dates.
/// For a Folync portfolio the earnings dates take one events call of their own.
///
/// Past earnings take a second kind of call (`earningsHistory(for:)`), made
/// only while the Past view is chosen: when it is chosen, when the page opens
/// on it, on the refresh control and when a holding comes or goes. Upcoming,
/// "Next up", the popover and the Overview never make it.
///
/// The load rule is Income's: ask when the page becomes the selected page and
/// on the refresh control; never on a timer, from the popover or the
/// Overview, or because another page changed.
@MainActor
@Observable
final class StockbarCalendarModel {
    enum Source: Equatable {
        /// Not opened yet.
        case none
        /// Folync is enabled: Folync's dividends.
        case folync
        /// Stockbar's estimate from Yahoo's record.
        case local
    }

    let folync: StockbarIncomeModel
    let local: StockbarLocalIncomeModel
    private(set) var source: Source = .none
    /// A Folync portfolio's earnings answers, keyed by the symbol asked.
    private(set) var earningsResults: [String: InstrumentEventsResult] = [:]
    private(set) var isLoadingEarnings = false
    /// Yahoo cannot be asked for a Folync portfolio's earnings (live market
    /// data is off and no acceptance fixture answers).
    private(set) var earningsNotAllowed = false
    /// Past earnings answers, keyed by the symbol asked; asked for only in Past.
    private(set) var historyResults: [String: InstrumentEarningsHistoryResult] = [:]
    private(set) var isLoadingHistory = false
    /// Yahoo cannot be asked for past earnings.
    private(set) var historyNotAllowed = false

    var mode: CalendarMode = .upcoming {
        didSet {
            guard mode != oldValue else { return }
            month = CalendarMonthRange.start(mode: mode, today: today)
            if !CalendarFigures.filters(for: mode).contains(filter) { filter = .all }
            selectedDay = nil
            if mode == .past, isActive, let inputs = lastInputs { loadHistory(inputs, forceRefresh: false) }
        }
    }
    var filter: CalendarFilter = .all
    /// The month the grid shows.
    private(set) var month: IncomeMonth
    /// The day chosen in the grid, whose rows the list marks.
    var selectedDay: FolyncLedgerDay?

    private let provider: any InstrumentEventsProviding
    private let historyProvider: any InstrumentEarningsHistoryProviding
    private let isAllowed: () -> Bool
    private let now: () -> Date
    private let timeZone: TimeZone
    private var earningsTask: Task<Void, Never>?
    private var earningsGeneration = 0
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    /// The symbols the last past-earnings call asked for.
    private var historySymbols: [String]?
    /// What the page was last shown for, so choosing Past can ask.
    @ObservationIgnored private var lastInputs: StockbarCalendarInputs?
    private var isActive = false

    init(router: any StockbarIncomeRouting, provider: any InstrumentEventsProviding,
         historyProvider: any InstrumentEarningsHistoryProviding, isAllowed: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.provider = provider
        self.historyProvider = historyProvider
        self.isAllowed = isAllowed
        self.now = now
        self.timeZone = timeZone
        folync = StockbarIncomeModel(router: router, now: now, timeZone: timeZone)
        local = StockbarLocalIncomeModel(provider: provider, isAllowed: isAllowed, now: now, timeZone: timeZone)
        month = FolyncLedgerDay(now(), in: timeZone).incomeMonth
    }

    /// The day the rows were worked out for, in the user's time zone.
    var today: FolyncLedgerDay {
        switch source {
        case .folync: folync.today
        case .local: local.today
        case .none: FolyncLedgerDay(now(), in: timeZone)
        }
    }

    var monthRange: CalendarMonthRange { CalendarMonthRange(mode: mode, today: today) }

    // MARK: The load rule

    /// The page became the selected page: asks once, without forcing. A
    /// second call while the page stays selected does nothing.
    func activate(_ inputs: StockbarCalendarInputs) {
        guard !isActive else { return }
        isActive = true
        lastInputs = inputs
        start(inputs)
        month = monthRange.clamped(CalendarMonthRange.start(mode: mode, today: today))
        if mode == .past { loadHistory(inputs, forceRefresh: false) }
    }

    /// The page is no longer selected: stop listening for anything in flight.
    func deactivate() {
        isActive = false
        folync.deactivate()
        local.deactivate()
        cancelEarnings()
        cancelHistory()
    }

    /// The refresh control: asks Folync (or Yahoo, for the estimate) and Yahoo
    /// for earnings afresh, both forced; in Past, past earnings too.
    func refresh(_ inputs: StockbarCalendarInputs) {
        guard isActive else { return }
        lastInputs = inputs
        if mode == .past { loadHistory(inputs, forceRefresh: true) }
        switch source {
        case .folync:
            folync.refresh()
            if inputs.isFolyncPortfolio { loadEarnings(inputs.holdings, forceRefresh: true) }
        case .local:
            local.refresh(holdings: inputs.localHoldings)
        case .none:
            break
        }
    }

    /// The portfolio source changed while the page is selected.
    func inputsChanged(from old: StockbarCalendarInputs, to new: StockbarCalendarInputs) {
        guard isActive else { return }
        lastInputs = new
        if mode == .past, Self.historySymbols(new) != historySymbols {
            // A holding came or went, or the portfolio changed: the service's
            // day-long copies mean only new symbols reach Yahoo.
            loadHistory(new, forceRefresh: false)
        }
        if old.isFolyncEnabled != new.isFolyncEnabled {
            folync.deactivate()
            local.deactivate()
            cancelEarnings()
            earningsResults = [:]
            start(new)
            return
        }
        switch source {
        case .folync where old.isFolyncPortfolio != new.isFolyncPortfolio:
            folync.portfolioSourceChanged(isFolyncPortfolio: new.isFolyncPortfolio)
            if new.isFolyncPortfolio {
                loadEarnings(new.holdings, forceRefresh: false)
            } else {
                cancelEarnings()
                earningsResults = [:]
            }
        case .folync where new.isFolyncPortfolio
            && Set(old.holdings.compactMap(\.yahooSymbol)) != Set(new.holdings.compactMap(\.yahooSymbol)):
            // A holding came or went: ask for the earnings again. The service's
            // day-long copies mean only new symbols reach Yahoo.
            loadEarnings(new.holdings, forceRefresh: false)
        case .local where old.localHoldings.isEmpty:
            local.holdingsAppeared(new.localHoldings)
        default:
            break
        }
    }

    private func start(_ inputs: StockbarCalendarInputs) {
        if inputs.isFolyncEnabled {
            source = .folync
            folync.activate(isFolyncPortfolio: inputs.isFolyncPortfolio)
            if inputs.isFolyncPortfolio { loadEarnings(inputs.holdings, forceRefresh: false) }
        } else {
            source = .local
            local.activate(holdings: inputs.localHoldings)
        }
    }

    // MARK: Earnings for a Folync portfolio

    private func loadEarnings(_ holdings: [CalendarHolding], forceRefresh: Bool) {
        cancelEarnings()
        guard isAllowed() else {
            earningsResults = [:]
            earningsNotAllowed = true
            return
        }
        earningsNotAllowed = false
        var seen = Set<String>()
        let symbols = holdings.compactMap(\.yahooSymbol).filter { seen.insert($0.uppercased()).inserted }
        guard !symbols.isEmpty else {
            earningsResults = [:]
            return
        }
        earningsGeneration += 1
        let generation = earningsGeneration
        isLoadingEarnings = true
        let provider = provider
        earningsTask = Task { [weak self] in
            let answers = await provider.events(for: symbols, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            self?.applyEarnings(answers, generation: generation)
        }
    }

    private func cancelEarnings() {
        earningsTask?.cancel()
        earningsTask = nil
        earningsGeneration += 1
        isLoadingEarnings = false
    }

    private func applyEarnings(_ answers: [InstrumentEventsResult], generation: Int) {
        guard isActive, generation == earningsGeneration else { return }
        earningsTask = nil
        isLoadingEarnings = false
        if InstrumentEventsAnswers.allRefused(answers) {
            earningsResults = [:]
            earningsNotAllowed = true
            return
        }
        earningsResults = Dictionary(answers.map { ($0.symbol, $0) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Past earnings

    /// The symbols past earnings are asked for: the ones upcoming earnings
    /// use. None for a Folync connection whose portfolio is not loaded.
    private static func historySymbols(_ inputs: StockbarCalendarInputs) -> [String] {
        guard !inputs.isFolyncEnabled || inputs.isFolyncPortfolio else { return [] }
        var seen = Set<String>()
        return inputs.holdings.compactMap(\.yahooSymbol).filter { seen.insert($0.uppercased()).inserted }
    }

    private func loadHistory(_ inputs: StockbarCalendarInputs, forceRefresh: Bool) {
        cancelHistory()
        let symbols = Self.historySymbols(inputs)
        historySymbols = symbols
        guard isAllowed() else {
            historyResults = [:]
            historyNotAllowed = true
            return
        }
        historyNotAllowed = false
        guard !symbols.isEmpty else {
            historyResults = [:]
            return
        }
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = true
        let provider = historyProvider
        historyTask = Task { [weak self] in
            let answers = await provider.earningsHistory(for: symbols, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            self?.applyHistory(answers, generation: generation)
        }
    }

    private func cancelHistory() {
        historyTask?.cancel()
        historyTask = nil
        historyGeneration += 1
        isLoadingHistory = false
    }

    private func applyHistory(_ answers: [InstrumentEarningsHistoryResult], generation: Int) {
        guard isActive, generation == historyGeneration else { return }
        historyTask = nil
        isLoadingHistory = false
        if InstrumentEventsAnswers.allRefused(answers) {
            historyResults = [:]
            historyNotAllowed = true
            return
        }
        historyResults = Dictionary(answers.map { ($0.symbol, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Past earnings by symbol asked.
    var historyAnswers: [String: InstrumentEarningsHistory] { historyResults.compactMapValues(\.history) }

    // MARK: Month bar

    func showPreviousMonth() {
        guard monthRange.canGoBack(from: month) else { return }
        month = month.adding(-1)
    }

    func showNextMonth() {
        guard monthRange.canGoForward(from: month) else { return }
        month = month.adding(1)
    }

    // MARK: What the page shows

    /// Every answer from Yahoo the page shows: the estimate's for a local
    /// portfolio, the earnings call's for a Folync one.
    var yahooResults: [InstrumentEventsResult] {
        switch source {
        case .folync: Array(earningsResults.values)
        case .local: Array(local.results.values)
        case .none: []
        }
    }

    /// Yahoo's answers by symbol asked.
    var earningsAnswers: [String: InstrumentEvents] {
        switch source {
        case .folync: earningsResults.compactMapValues(\.events)
        case .local: local.results.compactMapValues(\.events)
        case .none: [:]
        }
    }

    var isLoading: Bool {
        let history = mode == .past && isLoadingHistory
        switch source {
        case .folync: return folync.isLoading || isLoadingEarnings || history
        case .local: return local.isLoading || history
        case .none: return false
        }
    }

    /// Yahoo's answers whose state the notices report: in Past, the past
    /// earnings answers too.
    var yahooAnswerStates: [InstrumentAnswerState] {
        yahooResults.map(\.answerState) + (mode == .past ? historyResults.values.map(\.answerState) : [])
    }

    var isRefreshing: Bool {
        switch source {
        case .folync: folync.isRefreshing
        case .local: local.isRefreshing
        case .none: false
        }
    }

    /// Every row, from the answers held.
    func rows(_ inputs: StockbarCalendarInputs, currency: String, convert: (Double, String) -> Double?) -> CalendarRows {
        let dividends: CalendarRows
        switch source {
        case .folync:
            dividends = folync.response == nil ? .empty
                : CalendarFigures.folyncRows(events: folync.events, currency: folync.currency, today: today)
        case .local:
            guard local.phase == .loaded else { return .empty }
            dividends = CalendarFigures.localRows(
                estimate: local.estimate(holdings: inputs.localHoldings, currency: currency, convert: convert))
        case .none:
            return .empty
        }
        let earnings = CalendarFigures.earningsRows(holdings: inputs.holdings, answers: earningsAnswers, today: today)
        let pastEarnings = CalendarFigures.pastEarningsRows(holdings: inputs.holdings, histories: historyAnswers,
                                                            today: today)
        return CalendarFigures.combined(dividends: dividends, earnings: earnings, pastEarnings: pastEarnings)
    }

    /// The rows the list and the grid show, under the view and filter chosen.
    func shown(_ rows: CalendarRows) -> [CalendarRow] {
        CalendarFigures.rows(rows, mode: mode, filter: filter)
    }

    /// The grid's rows. Upcoming's grid also has this month's past dividends,
    /// so a past payment in this month still shows there; past earnings show
    /// in Past only.
    func gridRows(_ rows: CalendarRows) -> [CalendarRow] {
        let both = CalendarRows(upcoming: rows.upcoming + rows.past.filter(\.isDividend), past: rows.past)
        return mode == .upcoming
            ? CalendarFigures.rows(both, mode: .upcoming, filter: filter)
            : CalendarFigures.rows(rows, mode: .past, filter: filter)
    }
}

// MARK: - Next up

/// What reads Folync's dividends as already held: the coordinator, or a
/// stand-in in tests. It never makes a request.
protocol StockbarSavedDividendsReading: Sendable {
    func savedDividends(_ query: FolyncDividendsQuery) async -> FolyncDividendsResponse?
}

extension FolyncSupplementalCoordinator: StockbarSavedDividendsReading {}

/// "Next up" in the popover and on the Overview: up to three events in the
/// next fourteen days, from saved data only.
///
/// It reads the dividends page the fetch policy keeps (or Folync's copy on
/// disk) and the events service's saved copies. It never asks Folync or
/// Yahoo, so opening the popover or the Overview makes no request. With
/// nothing saved, `rows` is empty and "Next up" is not drawn.
@MainActor
@Observable
final class StockbarNextUpModel {
    /// A saved dividends copy from up to this many days back is still read:
    /// Income's query names today's dates, so a copy from yesterday is under
    /// yesterday's query.
    static let savedQueryDaysBack = 6

    private(set) var rows: [CalendarRow] = []
    private(set) var today: FolyncLedgerDay

    private let dividends: any StockbarSavedDividendsReading
    private let events: any InstrumentEventsSavedReading
    private let now: () -> Date
    private let timeZone: TimeZone
    private var task: Task<Void, Never>?
    private var generation = 0
    /// What the last reload was for, so a quote update alone reads nothing again.
    @ObservationIgnored private var lastRead: (inputs: StockbarCalendarInputs, currency: String, day: FolyncLedgerDay)?

    init(dividends: any StockbarSavedDividendsReading = FolyncSupplementalCoordinator.shared,
         events: any InstrumentEventsSavedReading = InstrumentEventsService.shared,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.dividends = dividends
        self.events = events
        self.now = now
        self.timeZone = timeZone
        self.today = FolyncLedgerDay(now(), in: timeZone)
    }

    /// Reads what is saved and works out "Next up" again. Called when the
    /// popover or the Overview appears and when the holdings change.
    func reload(_ inputs: StockbarCalendarInputs, currency: String,
                convert: @escaping @MainActor (Double, String) -> Double?) {
        task?.cancel()
        generation += 1
        let generation = generation
        let today = FolyncLedgerDay(now(), in: timeZone)
        lastRead = (inputs, currency, today)
        let dividends = dividends
        let events = events
        task = Task { [weak self] in
            let rows = await Self.read(inputs, today: today, currency: currency, convert: convert,
                                       dividends: dividends, events: events)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.today = today
            self.rows = rows
        }
    }

    /// Reloads only when the holdings, the currency or the day differ from the
    /// last reload. Quote updates arrive every refresh while the popover or the
    /// Overview is open; "Next up" does not depend on prices, so they read
    /// nothing from disk.
    func reloadIfChanged(_ inputs: StockbarCalendarInputs, currency: String,
                         convert: @escaping @MainActor (Double, String) -> Double?) {
        let today = FolyncLedgerDay(now(), in: timeZone)
        if let lastRead, lastRead.inputs == inputs, lastRead.currency == currency, lastRead.day == today { return }
        reload(inputs, currency: currency, convert: convert)
    }

    /// The rows from saved data, for `today`.
    static func read(_ inputs: StockbarCalendarInputs, today: FolyncLedgerDay, currency: String,
                     convert: @MainActor (Double, String) -> Double?,
                     dividends: any StockbarSavedDividendsReading,
                     events: any InstrumentEventsSavedReading) async -> [CalendarRow] {
        var dividendRows = CalendarRows.empty
        var answers: [String: InstrumentEvents] = [:]
        if inputs.isFolyncEnabled {
            guard inputs.isFolyncPortfolio else { return [] }
            for back in 0...savedQueryDaysBack {
                let day = CalendarFigures.adding(days: -back, to: today)
                if let response = await dividends.savedDividends(IncomeFigures.query(today: day)) {
                    dividendRows = CalendarFigures.folyncRows(events: response.events,
                                                              currency: IncomeFigures.portfolioCurrency(response),
                                                              today: today)
                    break
                }
            }
            answers = await events.savedEvents(for: inputs.holdings.compactMap(\.yahooSymbol))
        } else {
            answers = await events.savedEvents(for: inputs.localHoldings.map(\.symbol))
            let estimate = LocalIncomeFigures.estimate(holdings: inputs.localHoldings, answers: answers,
                                                       currency: currency, today: today, convert: convert)
            dividendRows = CalendarFigures.localRows(estimate: estimate)
        }
        let earnings = CalendarFigures.earningsRows(holdings: inputs.holdings, answers: answers, today: today)
        return CalendarFigures.nextUp(CalendarFigures.combined(dividends: dividendRows, earnings: earnings).upcoming,
                                      today: today)
    }
}
