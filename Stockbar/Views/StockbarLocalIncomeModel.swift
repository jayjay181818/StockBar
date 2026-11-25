import Foundation
import Observation

/// The Income page's state for a local or Trading 212 portfolio, and the only
/// place that page asks Yahoo for anything.
///
/// The load rule: one request when the page becomes the selected page, and
/// one on each explicit refresh (with `forceRefresh`). Nothing else asks: no
/// timer, and the popover and the Overview never make this model. The events
/// service makes one helper run for every symbol, keeps a day-long copy per
/// symbol, and pauses for an hour after a rate limit; this model only shows
/// what it gives. A newer request cancels the one before it, and a result for
/// a cancelled request is dropped.
@MainActor
@Observable
final class StockbarLocalIncomeModel {
    enum Phase: Equatable {
        /// Not opened yet.
        case idle
        /// Live market data is off and no acceptance fixture answers.
        case notAllowed
        /// No holdings to estimate for: nothing is asked.
        case noHoldings
        /// The first answer is on its way and nothing is shown yet.
        case loading
        /// Yahoo's answers, or the saved copies, are shown.
        case loaded
    }

    /// Why the page is not available, in the sidebar and on the page.
    nonisolated static let notAllowedReason = "Needs live market data, which is off"

    private(set) var phase: Phase = .idle
    /// The last answer for each symbol asked.
    private(set) var results: [String: InstrumentEventsResult] = [:]
    /// The day the figures were worked out for, in the user's time zone.
    private(set) var today: FolyncLedgerDay
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    var view: StockbarIncomeModel.View = .outlook

    private let provider: any InstrumentEventsProviding
    private let isAllowed: () -> Bool
    private let now: () -> Date
    private let timeZone: TimeZone
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isActive = false
    private var symbols: [String] = []

    init(provider: any InstrumentEventsProviding, isAllowed: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.provider = provider
        self.isAllowed = isAllowed
        self.now = now
        self.timeZone = timeZone
        self.today = FolyncLedgerDay(now(), in: timeZone)
    }

    // MARK: The load rule

    /// The page became the selected page: asks once, without forcing, so the
    /// service's day-long copies answer. A second call while the page stays
    /// selected does nothing.
    func activate(holdings: [LocalIncomeHolding]) {
        guard !isActive else { return }
        isActive = true
        load(holdings: holdings, forceRefresh: false)
    }

    /// The page is no longer selected: stop listening for anything in flight.
    func deactivate() {
        isActive = false
        cancelTask()
    }

    /// The refresh control. Asks Yahoo afresh for today's holdings, which the
    /// service still refuses during a rate-limit pause. Ignored while a
    /// refresh is on its way.
    func refresh(holdings: [LocalIncomeHolding]) {
        guard isActive, !isRefreshing else { return }
        load(holdings: holdings, forceRefresh: true)
    }

    private func load(holdings: [LocalIncomeHolding], forceRefresh: Bool) {
        cancelTask()
        today = FolyncLedgerDay(now(), in: timeZone)
        guard isAllowed() else {
            results = [:]
            phase = .notAllowed
            return
        }
        let symbols = holdings.map(\.symbol)
        guard !symbols.isEmpty else {
            results = [:]
            phase = .noHoldings
            return
        }
        self.symbols = symbols
        generation += 1
        let generation = generation
        isLoading = true
        isRefreshing = forceRefresh
        if results.isEmpty || phase != .loaded { phase = .loading }
        let provider = provider
        task = Task { [weak self] in
            let answers = await provider.events(for: symbols, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            self?.apply(answers, generation: generation)
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        generation += 1
        isLoading = false
        isRefreshing = false
    }

    private func apply(_ answers: [InstrumentEventsResult], generation: Int) {
        guard isActive, generation == self.generation else { return }
        task = nil
        isLoading = false
        isRefreshing = false
        if !answers.isEmpty, answers.allSatisfy({ $0.failure == .providerDisabled && $0.events == nil }) {
            results = [:]
            phase = .notAllowed
            return
        }
        results = Dictionary(answers.map { ($0.symbol, $0) }, uniquingKeysWith: { _, last in last })
        phase = .loaded
    }

    // MARK: What the page shows

    /// The estimate for `holdings` from the answers held. A holding asked for
    /// since the last answer counts as unknown until the next one.
    func estimate(holdings: [LocalIncomeHolding], currency: String,
                  convert: (Double, String) -> Double?) -> LocalIncomeEstimate {
        let answers = results.compactMapValues(\.events)
        return LocalIncomeFigures.estimate(holdings: holdings, answers: answers, currency: currency,
                                           today: today, convert: convert)
    }

    /// When Yahoo is rate-limiting: the latest time the service will ask again.
    var rateLimitedUntil: Date? {
        results.values.compactMap { result -> Date? in
            if case .rateLimited(let until) = result.failure { return until }
            return nil
        }.max()
    }

    /// Holdings shown from an older saved copy because Yahoo did not answer,
    /// with the oldest copy's time.
    var staleCopies: (count: Int, oldest: Date?) {
        let stale = results.values.filter(\.isStale)
        return (stale.count, stale.compactMap(\.fetchedAt).min())
    }

    /// Holdings Yahoo did not answer for and nothing is saved, for a reason
    /// other than having no record (network, timeout, the helper failing).
    var failedWithoutCopy: Int {
        results.values.filter { result in
            guard result.events == nil, let failure = result.failure else { return false }
            switch failure {
            case .noData, .invalidSymbol, .rateLimited, .providerDisabled: return false
            default: return true
            }
        }.count
    }
}
