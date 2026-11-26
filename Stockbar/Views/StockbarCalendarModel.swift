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

    var mode: CalendarMode = .upcoming {
        didSet {
            guard mode != oldValue else { return }
            month = CalendarMonthRange.start(mode: mode, today: today)
            if !CalendarFigures.filters(for: mode).contains(filter) { filter = .all }
            selectedDay = nil
        }
    }
    var filter: CalendarFilter = .all
    /// The month the grid shows.
    private(set) var month: IncomeMonth
    /// The day chosen in the grid, whose rows the list marks.
    var selectedDay: FolyncLedgerDay?

    private let provider: any InstrumentEventsProviding
    private let isAllowed: () -> Bool
    private let now: () -> Date
    private let timeZone: TimeZone
    private var earningsTask: Task<Void, Never>?
    private var earningsGeneration = 0
    private var isActive = false

    init(router: any StockbarIncomeRouting, provider: any InstrumentEventsProviding, isAllowed: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.provider = provider
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
        start(inputs)
        month = monthRange.clamped(CalendarMonthRange.start(mode: mode, today: today))
    }

    /// The page is no longer selected: stop listening for anything in flight.
    func deactivate() {
        isActive = false
        folync.deactivate()
        local.deactivate()
        cancelEarnings()
    }

    /// The refresh control: asks Folync (or Yahoo, for the estimate) and Yahoo
    /// for earnings afresh, both forced.
    func refresh(_ inputs: StockbarCalendarInputs) {
        guard isActive else { return }
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
        switch source {
        case .folync: folync.isLoading || isLoadingEarnings
        case .local: local.isLoading
        case .none: false
        }
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
        return CalendarFigures.combined(dividends: dividends, earnings: earnings)
    }

    /// The rows the list and the grid show, under the view and filter chosen.
    func shown(_ rows: CalendarRows) -> [CalendarRow] {
        CalendarFigures.rows(rows, mode: mode, filter: filter)
    }

    /// The grid's rows: the month's rows of both views, so a past payment in
    /// this month still shows in Upcoming's grid. Past shows dividends only.
    func gridRows(_ rows: CalendarRows) -> [CalendarRow] {
        let both = CalendarRows(upcoming: rows.upcoming + rows.past, past: rows.past)
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
