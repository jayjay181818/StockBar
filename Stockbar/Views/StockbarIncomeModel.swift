import Foundation
import Observation

/// What the Income page asks of Folync. `FolyncSupplementalCoordinator` is the
/// real one; tests stand in for it.
protocol StockbarIncomeRouting: Sendable {
    func routeDividends(_ query: FolyncDividendsQuery, forceRefresh: Bool) async -> FolyncRoutedDividendsResult
    func loadMoreDividends(_ query: FolyncDividendsQuery, after continuation: FolyncLedgerContinuation) async
        -> FolyncRoutedDividendsResult
}

extension FolyncSupplementalCoordinator: StockbarIncomeRouting {}

/// The Income page's state, and the only place it asks Folync for anything.
///
/// The load rule: one request when the page becomes the selected page, and one
/// on each explicit refresh (with `forceRefresh`). Nothing else asks: no timer,
/// no background work, and switching between Outlook, History and By holding
/// reuses the one answer. Opening the page again within five minutes is
/// answered by `FolyncLedgerFetchPolicy` from its reuse window; this model
/// keeps no copy of its own beyond the rows on screen. "Load more" asks for
/// the next page of the same query. A newer request cancels the one before it,
/// and a result that arrives for a cancelled or superseded request is dropped.
@MainActor
@Observable
final class StockbarIncomeModel {
    enum Phase: Equatable {
        /// Not opened yet.
        case idle
        /// The portfolio is not Folync's: nothing to ask.
        case needsFolync
        /// The first answer is on its way and nothing is shown yet.
        case loading
        /// Folync's answer, current or partial.
        case loaded
        /// Folync did not answer; its saved copy, from `savedAt`, is shown.
        case saved(savedAt: Date?)
        /// Folync did not answer and nothing is saved.
        case unreachable
        /// This Folync server does not provide dividends, or not yet.
        case unavailable
        /// Folync is not connected, or dividends are switched off in Settings.
        case switchedOff
    }

    enum View: String, CaseIterable, Hashable {
        case outlook
        case history
        case byHolding

        var title: String {
            switch self {
            case .outlook: "Outlook"
            case .history: "History"
            case .byHolding: "By holding"
            }
        }
    }

    static let needsFolyncReason = "Needs a Folync portfolio"

    private(set) var phase: Phase = .idle
    /// The answer whose whole-scope figures are shown: the latest page.
    private(set) var response: FolyncDividendsResponse?
    /// Every event gathered for `query`, page one onwards.
    private(set) var events: [FolyncDividendEvent] = []
    /// Where the next page starts, or nil when every event is loaded.
    private(set) var continuation: FolyncLedgerContinuation?
    /// The query the rows on screen answer; "Load more" reuses it.
    private(set) var query: FolyncDividendsQuery?
    /// The day the rows on screen were asked for, in the user's time zone.
    private(set) var today: FolyncLedgerDay
    /// A request for page one is in flight.
    private(set) var isLoading = false
    /// That request was an explicit refresh.
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    /// The last "Load more" got nothing; the rows gathered stay.
    private(set) var loadMoreFailed = false
    var view: View = .outlook

    private let router: any StockbarIncomeRouting
    private let now: () -> Date
    private let timeZone: TimeZone
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isActive = false

    init(router: any StockbarIncomeRouting, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.router = router
        self.now = now
        self.timeZone = timeZone
        self.today = FolyncLedgerDay(now(), in: timeZone)
    }

    var hasContent: Bool { response != nil }

    // MARK: The load rule

    /// The page became the selected page. Asks once, without forcing, so an
    /// answer from the last five minutes is reused by the fetch policy. A
    /// second call while the page stays selected does nothing.
    func activate(isFolyncPortfolio: Bool) {
        guard !isActive else { return }
        isActive = true
        guard isFolyncPortfolio else {
            clear(to: .needsFolync)
            return
        }
        load(forceRefresh: false)
    }

    /// The page is no longer selected: stop listening for anything in flight.
    func deactivate() {
        isActive = false
        cancelTask()
    }

    /// The portfolio source changed while the page is selected.
    func portfolioSourceChanged(isFolyncPortfolio: Bool) {
        guard isActive else { return }
        if !isFolyncPortfolio {
            cancelTask()
            clear(to: .needsFolync)
        } else if phase == .needsFolync {
            load(forceRefresh: false)
        }
    }

    /// The refresh control, and "Try now". Cancels anything in flight and asks
    /// Folync afresh. Ignored while a refresh is already on its way.
    func refresh() {
        guard isActive, phase != .needsFolync, !isRefreshing else { return }
        load(forceRefresh: true)
    }

    /// "Load more": the page after the last one loaded, for the same query.
    func loadMore() {
        guard isActive, !isLoading, !isLoadingMore, let query, let continuation else { return }
        cancelTask()
        generation += 1
        let generation = generation
        isLoadingMore = true
        loadMoreFailed = false
        let router = router
        task = Task { [weak self] in
            let result = await router.loadMoreDividends(query, after: continuation)
            guard !Task.isCancelled else { return }
            self?.applyMore(result, query: query, generation: generation)
        }
    }

    private func load(forceRefresh: Bool) {
        cancelTask()
        generation += 1
        let generation = generation
        let today = FolyncLedgerDay(now(), in: timeZone)
        let query = IncomeFigures.query(today: today)
        isLoading = true
        isRefreshing = forceRefresh
        if !hasContent { phase = .loading }
        let router = router
        task = Task { [weak self] in
            let result = await router.routeDividends(query, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            self?.applyFirst(result, query: query, today: today, generation: generation)
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation += 1
        isLoading = false
        isRefreshing = false
        isLoadingMore = false
    }

    // MARK: Applying answers

    private func applyFirst(_ result: FolyncRoutedDividendsResult, query: FolyncDividendsQuery,
                            today: FolyncLedgerDay, generation: Int) {
        guard isActive, generation == self.generation else { return }
        task = nil
        isLoading = false
        isRefreshing = false
        switch result {
        case .folync(let response, let status, _):
            show(response, status: status, query: query, today: today)
        case .disabled:
            clear(to: .switchedOff)
        case .unavailable:
            clear(to: .unavailable)
        case .unreachable:
            clear(to: .unreachable)
        }
    }

    private func applyMore(_ result: FolyncRoutedDividendsResult, query: FolyncDividendsQuery, generation: Int) {
        guard isActive, generation == self.generation else { return }
        task = nil
        isLoadingMore = false
        switch result {
        case .folync(let response, let status, .nextPage):
            let known = Set(events.map(\.eventId))
            events += response.events.filter { !known.contains($0.eventId) }
            self.response = response
            continuation = response.page.continuation
            if status == .stale { phase = .saved(savedAt: Self.savedAt(response)) }
        case .folync(let response, let status, .firstPage), .folync(let response, let status, .restarted):
            // Paging started again: what was gathered is dropped.
            show(response, status: status, query: query, today: today)
        case .disabled, .unavailable, .unreachable:
            loadMoreFailed = true
        }
    }

    private func show(_ response: FolyncDividendsResponse, status: FolyncSupplementalSourceStatus,
                      query: FolyncDividendsQuery, today: FolyncLedgerDay) {
        self.response = response
        events = response.events
        continuation = response.page.continuation
        self.query = query
        self.today = today
        loadMoreFailed = false
        phase = status == .stale ? .saved(savedAt: Self.savedAt(response)) : .loaded
    }

    private func clear(to phase: Phase) {
        response = nil
        events = []
        continuation = nil
        query = nil
        loadMoreFailed = false
        self.phase = phase
    }

    private static func savedAt(_ response: FolyncDividendsResponse) -> Date? {
        FolyncSupplementalDateParser.instant(response.generatedAt)
    }

    // MARK: What the page shows

    var currency: String { response.map(IncomeFigures.portfolioCurrency) ?? "" }

    var chart: IncomeChart? {
        guard response != nil else { return nil }
        return IncomeFigures.chart(events: events, currency: currency, today: today, isIncomplete: continuation != nil)
    }

    var upcoming: [IncomeUpcomingRow] {
        IncomeFigures.upcoming(events: events, currency: currency, today: today)
    }

    var history: [IncomeHistoryRow] {
        IncomeFigures.history(events: events, currency: currency)
    }

    var byHolding: [IncomeHoldingRow] {
        IncomeFigures.byHolding(events: events, currency: currency, today: today)
    }
}
