import Foundation
import Observation

// The Trades page's view model and the text it shows.
//
// Every figure is Folync's own, from the trade-analysis route: the page formats
// them and never works one out. An unknown figure is "–", never zero.
//
// The load rule (each request makes Folync rebuild the whole report):
// - one request when the page is opened, and one on the page's refresh control;
// - more rows only from "Load more";
// - a change of the All / Open / Closed switch waits 400 ms and cancels the
//   query it replaces;
// - nothing on a timer or in the background, and no copy kept here beyond the
//   page's life: reusing an answer for five minutes is the fetch policy's job.

/// What the Trades page asks of Folync. The coordinator in the app; a stand-in in tests.
protocol StockbarTradeAnalysisRouting: Sendable {
    func routeTradeAnalysis(
        _ query: FolyncTradeAnalysisQuery,
        forceRefresh: Bool
    ) async -> FolyncRoutedTradeAnalysisResult

    func loadMoreTradeAnalysis(
        _ query: FolyncTradeAnalysisQuery,
        after continuation: FolyncLedgerContinuation
    ) async -> FolyncRoutedTradeAnalysisResult
}

extension FolyncSupplementalCoordinator: StockbarTradeAnalysisRouting {}

@MainActor
@Observable
final class StockbarTradesViewModel {
    /// The page's switch. It is the route's status filter.
    enum Filter: String, CaseIterable, Hashable, Sendable {
        case all
        case open
        /// Partly sold and still held. Folync filters it as a status of its
        /// own, so "Open" alone would leave these positions out.
        case partial
        case closed

        var title: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .partial: "Partial"
            case .closed: "Closed"
            }
        }

        var status: FolyncTradeAnalysisQuery.Status {
            switch self {
            case .all: .all
            case .open: .open
            case .partial: .partial
            case .closed: .closed
            }
        }
    }

    enum State: Equatable {
        /// Not opened yet.
        case idle
        /// The portfolio is not Folync's, so there is nothing to ask for.
        case needsFolync
        /// Asking for the first time, with nothing to show.
        case loading
        /// Folync's answer.
        case loaded
        /// Folync did not answer; its saved copy is shown.
        case stale
        /// Folync did not answer and nothing is saved.
        case unreachable
        /// This Folync server cannot give trade analysis.
        case unavailable
        /// Folync is not connected, or trade analysis is switched off in Settings.
        case disabled
    }

    /// The route's largest page.
    static let pageSize = FolyncTradeAnalysisQuery.maximumLimit
    static let filterDebounce: Duration = .milliseconds(400)

    static func query(for filter: Filter) -> FolyncTradeAnalysisQuery {
        FolyncTradeAnalysisQuery(status: filter.status, limit: pageSize)
    }

    private(set) var state: State = .idle
    /// The latest page Folync gave: its stats, activity and paging.
    private(set) var answer: FolyncTradeAnalysisResponse?
    /// Every lot loaded for the current filter, in Folync's order.
    private(set) var lots: [FolyncTradeLot] = []
    private(set) var filter: Filter = .all
    /// Rows for the switch's new position are being asked for.
    private(set) var isLoadingRows = false
    /// The refresh control's request is in flight.
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    /// The last "Load more" got no answer; the rows already shown stay.
    private(set) var loadMoreFailed = false
    private(set) var isFolyncPortfolio: Bool

    private let router: any StockbarTradeAnalysisRouting
    private let sleep: @Sendable (Duration) async throws -> Void
    private var isActive = false
    private var task: Task<Void, Never>?

    init(
        router: any StockbarTradeAnalysisRouting = FolyncSupplementalCoordinator.shared,
        isFolyncPortfolio: Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.router = router
        self.isFolyncPortfolio = isFolyncPortfolio
        self.sleep = sleep
    }

    var hasMore: Bool { answer?.page.continuation != nil }
    var savedAt: Date? {
        guard state == .stale, let answer else { return nil }
        return FolyncSupplementalDateParser.instant(answer.generatedAt)
    }

    // MARK: Events

    /// The page became the selected page. A second call while it is open asks nothing.
    func activate() {
        guard !isActive else { return }
        isActive = true
        guard isFolyncPortfolio else {
            state = .needsFolync
            return
        }
        startFirstPage(forceRefresh: false, debounce: false)
    }

    /// The page is no longer shown: stop whatever is in flight.
    func deactivate() {
        isActive = false
        cancelTask()
    }

    /// The page's refresh control.
    func refresh() {
        guard isActive, isFolyncPortfolio else { return }
        startFirstPage(forceRefresh: true, debounce: false)
    }

    func select(_ filter: Filter) {
        guard filter != self.filter else { return }
        self.filter = filter
        guard isActive, isFolyncPortfolio else { return }
        // The rows shown were for the old position; the strip and costs are
        // whole-portfolio figures and stay.
        lots = []
        startFirstPage(forceRefresh: false, debounce: true)
    }

    func loadMore() {
        guard isActive, isFolyncPortfolio, task == nil,
              state == .loaded || state == .stale,
              let continuation = answer?.page.continuation else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let query = Self.query(for: filter)
        task = Task { [weak self, router] in
            let result = await router.loadMoreTradeAnalysis(query, after: continuation)
            // A cancelled caller is answered `.unavailable`: never show it.
            guard !Task.isCancelled else { return }
            self?.applyMore(result, for: query)
        }
    }

    /// The portfolio's source changed. Only a Folync portfolio has trades.
    func setFolyncPortfolio(_ isFolync: Bool) {
        guard isFolync != isFolyncPortfolio else { return }
        isFolyncPortfolio = isFolync
        guard isFolync else {
            cancelTask()
            answer = nil
            lots = []
            state = .needsFolync
            return
        }
        // The page is open and could not ask before: ask now, once.
        if isActive, state == .needsFolync {
            startFirstPage(forceRefresh: false, debounce: false)
        } else if !isActive {
            state = .idle
        }
    }

    // MARK: Requests

    private func startFirstPage(forceRefresh: Bool, debounce: Bool) {
        cancelTask()
        loadMoreFailed = false
        if answer == nil {
            state = .loading
        } else if debounce {
            isLoadingRows = true
        } else {
            isRefreshing = true
        }
        let query = Self.query(for: filter)
        task = Task { [weak self, router, sleep] in
            if debounce {
                do { try await sleep(Self.filterDebounce) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = await router.routeTradeAnalysis(query, forceRefresh: forceRefresh)
            // A cancelled caller is answered `.unavailable`: never show it.
            guard !Task.isCancelled else { return }
            self?.applyFirst(result, for: query)
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        isLoadingRows = false
        isRefreshing = false
        isLoadingMore = false
    }

    private func finishTask() {
        task = nil
        isLoadingRows = false
        isRefreshing = false
        isLoadingMore = false
    }

    private func applyFirst(_ result: FolyncRoutedTradeAnalysisResult, for query: FolyncTradeAnalysisQuery) {
        guard isActive, query == Self.query(for: filter) else { return }
        finishTask()
        switch result {
        case .folync(let response, let status, _):
            show(response, status: status)
        case .disabled:
            clear(.disabled)
        case .unavailable:
            clear(.unavailable)
        case .unreachable:
            clear(.unreachable)
        }
    }

    private func applyMore(_ result: FolyncRoutedTradeAnalysisResult, for query: FolyncTradeAnalysisQuery) {
        guard isActive, query == Self.query(for: filter) else { return }
        finishTask()
        switch result {
        case .folync(let response, _, .nextPage):
            lots += response.lots
            answer = response
        case .folync(let response, let status, .restarted), .folync(let response, let status, .firstPage):
            // Paging started again: drop the rows gathered and take page one.
            show(response, status: status)
        case .disabled:
            clear(.disabled)
        case .unavailable, .unreachable:
            // Keep what is shown; say the next rows did not come.
            loadMoreFailed = true
        }
    }

    private func show(_ response: FolyncTradeAnalysisResponse, status: FolyncSupplementalSourceStatus) {
        answer = response
        lots = response.lots
        state = status == .stale ? .stale : .loaded
    }

    private func clear(_ state: State) {
        answer = nil
        lots = []
        self.state = state
    }
}

// MARK: - Text

/// How a figure reads: its text, the sign that colours it, and what VoiceOver says.
struct StockbarTradesFigure: Equatable {
    enum Tone: Equatable {
        case gain, loss, neutral
    }

    let text: String
    let tone: Tone
    let spoken: String

    static let unknown = StockbarTradesFigure(text: StockbarTradesText.unknown, tone: .neutral, spoken: "not given")
}

/// The Trades page's derived text. Formatting only: no figure is worked out here.
enum StockbarTradesText {
    static let unknown = "–"

    // MARK: Strip

    /// "9 of 14 trades made money", from Folync's counts of wins and losses.
    static func winRateCaption(wins: Int?, losses: Int?) -> String? {
        guard let wins, let losses, wins >= 0, losses >= 0, wins + losses > 0 else { return nil }
        let total = wins + losses
        return "\(wins) of \(total) \(total == 1 ? "trade" : "trades") made money"
    }

    /// "8 of 14, over the same days", from Folync's counts against the S&P 500.
    static func beatIndexCaption(wins: Int?, losses: Int?) -> String? {
        guard let wins, let losses, wins >= 0, losses >= 0, wins + losses > 0 else { return nil }
        return "\(wins) of \(wins + losses), over the same days"
    }

    /// A whole percentage, as the strip shows it: "64%".
    static func wholePercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        return "\(Int(value.rounded()))%"
    }

    // MARK: Rows

    struct Pill: Equatable {
        enum Kind: Equatable {
            case open, partial, closed, other
        }

        let title: String
        let kind: Kind
    }

    static func pill(_ status: FolyncOpenEnum<FolyncTradeLotStatus>) -> Pill {
        switch status {
        case .known(.open): Pill(title: "Open", kind: .open)
        case .known(.partial): Pill(title: "Partial", kind: .partial)
        case .known(.closed): Pill(title: "Closed", kind: .closed)
        case .unknown(let raw):
            // A status this build does not know is shown as Folync sends it.
            Pill(title: raw.isEmpty ? unknown : raw, kind: .other)
        }
    }

    /// "646 d", and "646 days" read aloud. Folync's own count.
    static func heldFor(days: Int) -> (text: String, spoken: String) {
        guard days >= 0 else { return (unknown, "not given") }
        return ("\(days) d", "\(days) \(days == 1 ? "day" : "days")")
    }

    /// "11 Feb 2025" from Folync's "2025-02-11", the same day in every time zone.
    static func openedOn(_ day: String, locale: Locale = .current) -> String {
        guard let date = FolyncSupplementalDateParser.day(day) else { return day }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return date.formatted(style)
    }

    static func amount(_ value: Double?, currency: String?) -> String {
        guard let value, value.isFinite else { return unknown }
        return HoldingsCurrencyFormatter.amount(value, currency: currency ?? "")
    }

    /// A gain with a written sign, coloured by the sign it shows.
    static func signedAmount(_ value: Double?, currency: String?) -> StockbarTradesFigure {
        guard let value, value.isFinite else { return .unknown }
        let code = currency ?? ""
        let text = HoldingsCurrencyFormatter.signedAmount(value, currency: code)
        let shown = HoldingsCurrencyFormatter.displayedSign(of: value, currency: code)
        return StockbarTradesFigure(text: text, tone: tone(shown), spoken: text)
    }

    /// A return with a written sign and one decimal: "+74.7%".
    static func signedPercent(_ value: Double?) -> StockbarTradesFigure {
        guard let value, value.isFinite else { return .unknown }
        let (text, shown) = signed(value, suffix: "%")
        return StockbarTradesFigure(text: text, tone: tone(shown), spoken: text.replacingOccurrences(of: "%", with: " percent"))
    }

    /// Percentage points against the lot's index over the same days: "+53.4".
    static func signedPoints(_ value: Double?, index: String) -> StockbarTradesFigure {
        guard let value, value.isFinite else {
            return StockbarTradesFigure(text: unknown, tone: .neutral, spoken: "no comparison with the \(index)")
        }
        let (text, shown) = signed(value, suffix: "")
        let magnitude = String(format: "%.1f", abs(shown))
        let spoken = shown == 0
            ? "level with the \(index)"
            : "\(magnitude) points \(shown > 0 ? "ahead of" : "behind") the \(index)"
        return StockbarTradesFigure(text: text, tone: tone(shown), spoken: spoken)
    }

    /// One decimal with a written sign. A value that shows as zero has no sign.
    private static func signed(_ value: Double, suffix: String) -> (text: String, shown: Double) {
        let shown = (value * 10).rounded() / 10
        let magnitude = String(format: "%.1f", abs(shown)) + suffix
        guard shown != 0 else { return (magnitude, 0) }
        return ((shown > 0 ? "+" : "-") + magnitude, shown)
    }

    private static func tone(_ shown: Double) -> StockbarTradesFigure.Tone {
        shown > 0 ? .gain : shown < 0 ? .loss : .neutral
    }

    /// The holding's ticker as Folync shows it.
    static func holding(_ lot: FolyncTradeLot) -> String {
        let display = lot.identity.displayTicker.trimmingCharacters(in: .whitespaces)
        return display.isEmpty ? lot.ticker : display
    }

    /// The index a lot is compared with, as Folync names it.
    static func indexName(_ lot: FolyncTradeLot) -> String {
        lot.benchmarkName.isEmpty ? "index" : lot.benchmarkName
    }

    /// The row as one sentence for VoiceOver.
    static func rowSentence(_ lot: FolyncTradeLot, locale: Locale = .current) -> String {
        let held = heldFor(days: lot.holdingDays).spoken
        let gain = signedAmount(lot.totalGain, currency: lot.currency).spoken
        let returned = signedPercent(lot.totalReturnPct).spoken
        let versus = signedPoints(lot.alphaPct, index: indexName(lot)).spoken
        var parts = [
            "\(holding(lot)), \(pill(lot.status).title.lowercased())",
            "opened \(openedOn(lot.openDate, locale: locale))",
            "held \(held)",
            "cost \(amount(lot.costBasis, currency: lot.currency))",
            "gain \(gain)",
            "return \(returned)",
            versus
        ]
        if lot.valuation.quality != .complete {
            parts.append("value \(lot.valuation.quality.rawValue)")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// The last column's heading: the index's name when every row shares one.
    static func comparisonHeading(_ lots: [FolyncTradeLot]) -> String {
        let names = Set(lots.map(indexName))
        guard names.count == 1, let name = names.first else { return "vs index" }
        return name == "S&P 500" ? "vs S&P" : "vs \(name)"
    }

    /// The note under the table.
    static func tableNote(lots: [FolyncTradeLot], method: FolyncOpenEnum<FolyncCostBasisMethod>?) -> String {
        let names = orderedIndexNames(lots)
        let comparison: String = switch names.count {
        case 0: "The last column is points ahead of or behind the index over the same days."
        case 1: "The last column is points ahead of or behind the \(names[0]) over the same days."
        default:
            "The last column is points ahead of or behind each trade's index over the same days (\(names.joined(separator: " or ")), as Folync compares them)."
        }
        let matching = method.map { "Trades are matched by \(methodName($0)), as Folync reports; these are not tax lots." }
            ?? "Folync does not say how trades are matched; these are not tax lots."
        return "\(comparison) \(matching)"
    }

    static func methodName(_ method: FolyncOpenEnum<FolyncCostBasisMethod>) -> String {
        switch method {
        case .known(.fifo): "first in, first out"
        case .known(.lifo): "last in, first out"
        case .known(.average): "average cost"
        case .unknown(let raw): raw
        }
    }

    private static func orderedIndexNames(_ lots: [FolyncTradeLot]) -> [String] {
        var seen = Set<String>()
        return lots.map(indexName).filter { seen.insert($0).inserted }
    }

    /// "Showing 7 trades".
    static func shownCount(_ count: Int) -> String {
        "Showing \(count) \(count == 1 ? "trade" : "trades")"
    }

    // MARK: Costs

    /// The years the costs card offers, newest first, and the one it starts on:
    /// this calendar year when Folync gives it, else the newest it gives.
    static func costYears(_ activity: [FolyncActivityPeriod], currentYear: Int) -> (offered: [String], chosen: String?) {
        var seen = Set<String>()
        let periods = activity.map(\.period).filter { !$0.isEmpty && seen.insert($0).inserted }
        let offered = periods.sorted { lhs, rhs in
            switch (Int(lhs), Int(rhs)) {
            case let (left?, right?): left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs > rhs
            }
        }
        let current = String(currentYear)
        return (offered, offered.contains(current) ? current : offered.first)
    }

    /// This calendar year's activity, or nil when Folync gives none.
    static func activity(_ activity: [FolyncActivityPeriod], year: Int) -> FolyncActivityPeriod? {
        activity.first { $0.period == String(year) }
    }

    /// A percentage as Folync gives it, to one decimal: "9.4%".
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unknown }
        return String(format: "%.1f%%", value)
    }

    /// "0.06% of average value".
    static func percentOfAverageValue(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        let digits = abs(value) < 1 ? 2 : 1
        return String(format: "%.\(digits)f%% of average value", value)
    }
}
