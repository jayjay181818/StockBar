import Foundation
import Observation

// The Activity page's figures, query and loading. The page itself is in
// `StockbarActivityView.swift`.
//
// Every figure comes from Folync's transactions route as given. Stockbar
// derives only the direction of an amount (from the action), the month a row
// is listed under (from its own calendar day), and the wording of each row.

// MARK: - Controls

/// The kind switch. Each kind is a set of the route's actions; All sends no
/// action filter, so it also lists actions this build does not know.
enum StockbarActivityKind: String, CaseIterable, Hashable, Sendable {
    case all
    case trades
    case dividends
    case cash

    var title: String {
        switch self {
        case .all: "All"
        case .trades: "Trades"
        case .dividends: "Dividends"
        case .cash: "Cash"
        }
    }

    /// The actions this kind asks for. Every known action is in exactly one of
    /// Trades, Dividends and Cash.
    var actions: Set<FolyncTransactionAction> {
        switch self {
        case .all: []
        case .trades: [.buy, .sell, .split, .corporateAction]
        case .dividends: [.dividend, .stockDividend]
        case .cash: [.deposit, .withdraw, .interest, .fee, .tax, .transfer, .note]
        }
    }
}

/// The mode switch: the route's `input` and `adjusted` modes.
enum StockbarActivityMode: String, CaseIterable, Hashable, Sendable {
    case asEntered
    case adjusted

    var title: String {
        switch self {
        case .asEntered: "As entered"
        case .adjusted: "Adjusted"
        }
    }

    var routeMode: FolyncTransactionsMode {
        switch self {
        case .asEntered: .input
        case .adjusted: .adjusted
        }
    }
}

enum StockbarActivityQuery {
    /// The route takes a ticker of 1 to 40 characters.
    static let maximumTickerLength = 40

    /// The query for the controls. The mode is always sent and the ticker is
    /// trimmed and upper-cased, so the same choice is always the same query
    /// (and the same saved copy). An empty search sends no ticker.
    static func make(kind: StockbarActivityKind, mode: StockbarActivityMode, holding: String) -> FolyncTransactionsQuery {
        let ticker = String(holding.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTickerLength)).uppercased()
        return FolyncTransactionsQuery(
            mode: mode.routeMode,
            instrument: ticker.isEmpty ? nil : .ticker(ticker),
            actions: kind.actions
        )
    }
}

// MARK: - Rows

/// Which way an amount moves money, decided by the action.
enum StockbarActivityDirection: Equatable, Sendable {
    /// Money in: green, written with "+".
    case moneyIn
    /// Money out: red, written with "−".
    case moneyOut
    /// No fixed direction (a transfer, a split, a note, an action this build
    /// does not know): neutral, shown as Folync gives it.
    case neutral

    init(_ action: FolyncOpenEnum<FolyncTransactionAction>) {
        switch action.knownValue {
        case .sell, .dividend, .deposit, .interest: self = .moneyIn
        case .buy, .withdraw, .fee, .tax: self = .moneyOut
        case .transfer, .stockDividend, .split, .corporateAction, .note, nil: self = .neutral
        }
    }
}

/// The glyph beside an action's name.
enum StockbarActivityGlyph: Equatable, Sendable {
    case buy, sell, dividend, cashIn, cashOut, interest, charge, holdingChange, transfer, note, unknown

    init(_ action: FolyncOpenEnum<FolyncTransactionAction>) {
        switch action.knownValue {
        case .buy: self = .buy
        case .sell: self = .sell
        case .dividend, .stockDividend: self = .dividend
        case .deposit: self = .cashIn
        case .withdraw: self = .cashOut
        case .interest: self = .interest
        case .fee, .tax: self = .charge
        case .split, .corporateAction: self = .holdingChange
        case .transfer: self = .transfer
        case .note: self = .note
        case nil: self = .unknown
        }
    }

    var systemImage: String {
        switch self {
        case .buy: "arrowtriangle.up.fill"
        case .sell: "arrowtriangle.down.fill"
        case .dividend: "circle.fill"
        case .cashIn: "plus.circle"
        case .cashOut: "minus.circle"
        case .interest: "circle.fill"
        case .charge: "minus.square"
        case .holdingChange: "arrow.triangle.branch"
        case .transfer: "arrow.left.arrow.right"
        case .note: "note.text"
        case .unknown: "questionmark.circle"
        }
    }
}

/// One row as the page draws it and VoiceOver reads it.
struct StockbarActivityRow: Identifiable, Equatable {
    let id: String
    /// "12 Nov".
    let day: String
    /// "12 November", for VoiceOver.
    let spokenDay: String
    let glyph: StockbarActivityGlyph
    /// "Buy", or the raw name of an action this build does not know.
    let actionTitle: String
    /// The holding's ticker, or "–".
    let ticker: String
    /// "4 shares at $412.30 · commission $1.00", or "–".
    let detail: String
    /// "−£1,318.60", "+£41.02", "£0.00", or "–" when Folync does not give it.
    let amount: String
    /// The value to colour by: positive for money in, negative for money out,
    /// nil (neutral) otherwise.
    let colourSign: Double?
    /// "partial" or "unavailable" beside the amount, as Folync marks it.
    let qualityNote: String?
    /// Folync's reason codes for the amount, readable.
    let reasons: String
    let accessibilityLabel: String
}

/// One month of rows, newest first, under its heading. No sums: a month may
/// be only partly loaded.
struct StockbarActivityMonth: Identifiable, Equatable {
    let id: String
    /// "November 2026".
    let title: String
    let rows: [StockbarActivityRow]
}

enum StockbarActivityFormat {
    static let unknownFigure = "–"
    static let minus = "\u{2212}"

    /// The calendar day a row's own `yyyy-MM-dd` names; nil if it does not parse.
    static func day(_ value: String) -> FolyncLedgerDay? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return FolyncLedgerDay(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Rows grouped by the month of their own day, newest month first, rows in
    /// the order Folync sent them. A row whose day does not parse is kept,
    /// under "Date not given" at the end.
    static func months(_ transactions: [FolyncTransaction], names: (FolyncTransaction) -> String? = { _ in nil },
                       locale: Locale = .current) -> [StockbarActivityMonth] {
        var order: [String] = []
        var grouped: [String: (title: String, sort: Int, rows: [StockbarActivityRow])] = [:]
        for transaction in transactions {
            let day = day(transaction.date)
            let key = day.map { String(format: "%04d-%02d", $0.year, $0.month) } ?? "undated"
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (day.map { monthTitle($0, locale: locale) } ?? "Date not given",
                                day.map { $0.year * 100 + $0.month } ?? Int.min, [])
            }
            grouped[key]?.rows.append(row(transaction, name: names(transaction), locale: locale))
        }
        return order
            .compactMap { key in grouped[key].map { (key, $0) } }
            .sorted { $0.1.sort > $1.1.sort }
            .map { StockbarActivityMonth(id: $0.0, title: $0.1.title, rows: $0.1.rows) }
    }

    static func row(_ transaction: FolyncTransaction, name: String? = nil, locale: Locale = .current) -> StockbarActivityRow {
        let day = day(transaction.date)
        let ticker = transaction.identity?.displayTicker ?? unknownFigure
        let detail = detail(transaction)
        let amount = amount(transaction)
        let quality = transaction.portfolioAmount.quality
        let qualityNote: String? = switch quality {
        case .complete: nil
        case .partial: "partial"
        case .unavailable: "unavailable"
        }
        return StockbarActivityRow(
            id: transaction.id,
            day: day.map { dayText($0, month: .abbreviated, locale: locale) } ?? unknownFigure,
            spokenDay: day.map { dayText($0, month: .wide, locale: locale) } ?? "Date not given",
            glyph: StockbarActivityGlyph(transaction.action),
            actionTitle: actionTitle(transaction.action),
            ticker: ticker,
            detail: detail,
            amount: amount,
            colourSign: colourSign(transaction),
            qualityNote: qualityNote,
            reasons: FolyncConnectionState.readable(reasons: transaction.portfolioAmount.reasonCodes),
            accessibilityLabel: accessibilityLabel(transaction, name: name, locale: locale)
        )
    }

    static func actionTitle(_ action: FolyncOpenEnum<FolyncTransactionAction>) -> String {
        switch action {
        case .unknown(let raw): raw
        case .known(let known):
            switch known {
            case .buy: "Buy"
            case .sell: "Sell"
            case .deposit: "Deposit"
            case .withdraw: "Withdrawal"
            case .fee: "Fee"
            case .dividend: "Dividend"
            case .stockDividend: "Stock dividend"
            case .tax: "Tax"
            case .interest: "Interest"
            case .split: "Split"
            case .transfer: "Transfer"
            case .corporateAction: "Corporate action"
            case .note: "Note"
            }
        }
    }

    // MARK: Amount

    /// The amount in the portfolio's currency: Folync's `portfolioAmount` as
    /// given, with a written sign for money in or out. Nil is "–", never zero.
    static func amount(_ transaction: FolyncTransaction) -> String {
        guard let value = transaction.portfolioAmount.value, value.isFinite else { return unknownFigure }
        let currency = transaction.portfolioAmount.currency ?? transaction.portfolioCurrency
        let magnitude = money(abs(value), currency: currency)
        guard HoldingsCurrencyFormatter.showsNonZeroDigit(magnitude) else { return magnitude }
        switch StockbarActivityDirection(transaction.action) {
        case .moneyIn: return "+" + magnitude
        case .moneyOut: return minus + magnitude
        case .neutral: return value < 0 ? minus + magnitude : magnitude
        }
    }

    /// Positive for money in, negative for money out, nil when the amount is
    /// unknown, shows as zero, or has no fixed direction.
    static func colourSign(_ transaction: FolyncTransaction) -> Double? {
        guard let value = transaction.portfolioAmount.value, value.isFinite,
              HoldingsCurrencyFormatter.showsNonZeroDigit(money(abs(value), currency: transaction.portfolioAmount.currency ?? transaction.portfolioCurrency))
        else { return nil }
        switch StockbarActivityDirection(transaction.action) {
        case .moneyIn: return 1
        case .moneyOut: return -1
        case .neutral: return nil
        }
    }

    // MARK: Detail

    /// "4 shares at $412.30", then commission and tax when present and not
    /// zero, then the adjustment Folync names. Quantity and price are in the
    /// transaction's own currency, as Folync gives them; a zero quantity or
    /// price is a transaction without one (a deposit), not a figure to show.
    /// A cash row in another currency shows its gross amount in that currency.
    static func detail(_ transaction: FolyncTransaction) -> String {
        var parts: [String] = []
        if let trade = quantityAndPrice(transaction) {
            parts.append(trade)
        } else if transaction.currency.uppercased() != transaction.portfolioCurrency.uppercased(),
                  transaction.grossAmount.isFinite, transaction.grossAmount != 0 {
            parts.append(money(transaction.grossAmount, currency: transaction.currency))
        }
        if transaction.commission.isFinite, transaction.commission != 0 {
            parts.append("commission " + money(transaction.commission, currency: transaction.currency))
        }
        if transaction.tax.isFinite, transaction.tax != 0 {
            parts.append("tax " + money(transaction.tax, currency: transaction.currency))
        }
        if transaction.adjusted == true {
            parts.append(transaction.adjustedReason.map { "adjusted: \($0)" } ?? "adjusted")
        }
        return parts.isEmpty ? unknownFigure : parts.joined(separator: " · ")
    }

    /// "4 shares at $412.30", "4 shares", "at $412.30", or nil.
    static func quantityAndPrice(_ transaction: FolyncTransaction) -> String? {
        let hasQuantity = transaction.quantity.isFinite && transaction.quantity != 0
        let hasPrice = transaction.price.isFinite && transaction.price != 0
        let shares = hasQuantity ? sharesText(transaction.quantity) : nil
        let price = hasPrice ? "at " + priceText(transaction.price, currency: transaction.priceCurrency ?? transaction.currency) : nil
        let parts = [shares, price].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "4 shares", "1 share", "2.5 shares".
    static func sharesText(_ quantity: Double) -> String {
        let number = decimal(quantity, minimumFractionDigits: 0, maximumFractionDigits: 6)
        return abs(quantity) == 1 ? "\(number) share" : "\(number) shares"
    }

    /// A price as Folync gives it, to at least two and at most four decimals;
    /// pence as "29.3p".
    static func priceText(_ price: Double, currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespaces)
        if code == "GBp" || code.uppercased() == "GBX" {
            return decimal(price, minimumFractionDigits: 0, maximumFractionDigits: 4) + "p"
        }
        return withSymbol(decimal(abs(price), minimumFractionDigits: 2, maximumFractionDigits: 4),
                          negative: price < 0, currency: code)
    }

    /// Money to two decimals; pence as "41p".
    static func money(_ value: Double, currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespaces)
        if code == "GBp" || code.uppercased() == "GBX" {
            return decimal(value, minimumFractionDigits: 0, maximumFractionDigits: 2) + "p"
        }
        return withSymbol(decimal(abs(value), minimumFractionDigits: 2, maximumFractionDigits: 2),
                          negative: value < 0, currency: code)
    }

    private static func withSymbol(_ number: String, negative: Bool, currency: String) -> String {
        let sign = negative && HoldingsCurrencyFormatter.showsNonZeroDigit(number) ? minus : ""
        if let symbol = HoldingsCurrencyFormatter.currencySymbol(for: currency.uppercased()) {
            return "\(sign)\(symbol)\(number)"
        }
        return currency.isEmpty ? "\(sign)\(number)" : "\(sign)\(number) \(currency.uppercased())"
    }

    private static func decimal(_ value: Double, minimumFractionDigits: Int, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return text.replacingOccurrences(of: "-", with: minus)
    }

    // MARK: Dates

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// The day as written, built from its own parts in UTC, so no time zone can
    /// move it to the day before.
    private static func date(_ day: FolyncLedgerDay) -> Date? {
        calendar().date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }

    /// "November 2026".
    static func monthTitle(_ day: FolyncLedgerDay, locale: Locale = .current) -> String {
        guard let date = date(day) else { return String(format: "%04d-%02d", day.year, day.month) }
        var style = Date.FormatStyle(locale: locale, calendar: calendar()).month(.wide).year()
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return date.formatted(style)
    }

    /// "12 Nov", or "12 November" with `.wide`.
    static func dayText(_ day: FolyncLedgerDay, month: Date.FormatStyle.Symbol.Month, locale: Locale = .current) -> String {
        guard let date = date(day) else { return day.string }
        var style = Date.FormatStyle(locale: locale, calendar: calendar()).day().month(month)
        style.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return date.formatted(style)
    }

    // MARK: VoiceOver

    /// One sentence: "12 November, bought 4 Microsoft shares at $412.30, £1,318.60 out".
    /// `name` is the holding's name when Stockbar already knows it; otherwise
    /// the ticker is read.
    static func accessibilityLabel(_ transaction: FolyncTransaction, name: String? = nil, locale: Locale = .current) -> String {
        let spokenDay = day(transaction.date).map { dayText($0, month: .wide, locale: locale) } ?? "Date not given"
        let holding = name ?? transaction.identity?.displayTicker
        var phrase: String
        switch transaction.action.knownValue {
        case .buy, .sell:
            let verb = transaction.action.knownValue == .buy ? "bought" : "sold"
            let hasQuantity = transaction.quantity.isFinite && transaction.quantity != 0
            let hasPrice = transaction.price.isFinite && transaction.price != 0
            phrase = verb
            if hasQuantity {
                let number = decimal(transaction.quantity, minimumFractionDigits: 0, maximumFractionDigits: 6)
                let noun = abs(transaction.quantity) == 1 ? "share" : "shares"
                phrase += " \(number) \(holding.map { "\($0) " } ?? "")\(noun)"
            } else if let holding {
                phrase += " \(holding)"
            }
            if hasPrice {
                phrase += " at " + priceText(transaction.price, currency: transaction.priceCurrency ?? transaction.currency)
            }
            let extras = detailExtras(transaction)
            if !extras.isEmpty { phrase += ", " + extras.joined(separator: ", ") }
        default:
            phrase = actionTitle(transaction.action).lowercased()
            if case .unknown = transaction.action { phrase = "\(actionTitle(transaction.action)), an action Stockbar does not know" }
            if let holding { phrase += ", \(holding)" }
            let detail = detail(transaction)
            if detail != unknownFigure { phrase += ", " + detail.replacingOccurrences(of: " · ", with: ", ") }
        }
        return "\(spokenDay), \(phrase), \(spokenAmount(transaction))"
    }

    /// A holding's name as VoiceOver reads it in a row: the name without the
    /// " · portfolio" label an aggregate scope adds. Nil when there is none.
    static func spokenName(_ shortName: String) -> String? {
        let name = shortName.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Commission, tax and adjustment, as in the detail line.
    private static func detailExtras(_ transaction: FolyncTransaction) -> [String] {
        let detail = detail(transaction)
        guard detail != unknownFigure else { return [] }
        let parts = detail.components(separatedBy: " · ")
        return quantityAndPrice(transaction) == nil ? parts : Array(parts.dropFirst())
    }

    /// "£1,318.60 out", "£41.02 in", "£0.00", "amount not given"; then
    /// "partial" or "unavailable" as Folync marks it.
    static func spokenAmount(_ transaction: FolyncTransaction) -> String {
        var text: String
        if let value = transaction.portfolioAmount.value, value.isFinite {
            let magnitude = money(abs(value), currency: transaction.portfolioAmount.currency ?? transaction.portfolioCurrency)
            switch StockbarActivityDirection(transaction.action) {
            case .moneyIn: text = "\(magnitude) in"
            case .moneyOut: text = "\(magnitude) out"
            case .neutral: text = value < 0 ? "minus \(magnitude)" : magnitude
            }
        } else {
            text = "amount not given"
        }
        switch transaction.portfolioAmount.quality {
        case .complete: break
        case .partial: text += ", partial"
        case .unavailable: text += ", unavailable"
        }
        return text
    }
}

// MARK: - Loading

/// The coordinator's transactions route, as the page needs it. Tests stand in for it.
protocol StockbarActivityTransactionsRouting: Sendable {
    func routeTransactions(_ query: FolyncTransactionsQuery, forceRefresh: Bool) async -> FolyncRoutedTransactionsResult
    func loadMoreTransactions(_ query: FolyncTransactionsQuery, after continuation: FolyncLedgerContinuation) async
        -> FolyncRoutedTransactionsResult
}

extension FolyncSupplementalCoordinator: StockbarActivityTransactionsRouting {}

/// The Activity page's state and its one task.
///
/// The load rule: it asks the route only when the page is activated and on
/// an explicit refresh (`forceRefresh: true`); more rows only on `loadMore()`.
/// A change of kind, mode or holding is debounced, cancels the task for the
/// superseded query and starts again from page one. Reopening the page asks
/// with `forceRefresh: false`, so `FolyncLedgerFetchPolicy` answers from its
/// five-minute reuse; there is no second cache here. A result that arrives for
/// a cancelled task is never applied.
@MainActor
@Observable
final class StockbarActivityViewModel {
    enum Phase: Equatable {
        /// Not activated yet.
        case idle
        /// The portfolio is not a Folync one: no request is made.
        case needsFolync
        /// Loading page one, with nothing to show yet.
        case loading
        case loaded
        /// Folync did not answer; a saved copy from `savedAt` is shown.
        case stale(savedAt: Date?)
        /// Folync did not answer and nothing is saved.
        case unreachable
        /// The server does not offer transactions, or they are not ready.
        case unavailable
        /// Folync is not connected, or the transactions route is switched off.
        case disabled
    }

    private(set) var phase: Phase = .idle
    private(set) var transactions: [FolyncTransaction] = []
    /// Folync's quality and reason codes for the whole answer.
    private(set) var quality: FolyncFinancialQuality = .complete
    private(set) var reasonCodes: [String] = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    /// The last "Load more" failed; the rows gathered are kept.
    private(set) var loadMoreFailed = false
    /// A change of the controls is waiting out its debounce or loading.
    private(set) var isQueryPending = false

    var kind: StockbarActivityKind = .all {
        didSet { if kind != oldValue { controlsChanged() } }
    }
    var mode: StockbarActivityMode = .asEntered {
        didSet { if mode != oldValue { controlsChanged() } }
    }
    var holding = "" {
        didSet { if holding != oldValue { controlsChanged() } }
    }

    /// The query the controls ask for.
    var query: FolyncTransactionsQuery {
        StockbarActivityQuery.make(kind: kind, mode: mode, holding: holding)
    }

    var canLoadMore: Bool {
        continuation != nil && task == nil && !isQueryPending && (phase == .loaded || isStale)
    }

    var isStale: Bool {
        if case .stale = phase { return true }
        return false
    }

    /// The query the rows on screen answer.
    private(set) var appliedQuery: FolyncTransactionsQuery?
    private(set) var continuation: FolyncLedgerContinuation?
    private(set) var task: Task<Void, Never>?
    @ObservationIgnored private(set) var isActive = false
    @ObservationIgnored private var isFolyncPortfolio = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let router: any StockbarActivityTransactionsRouting
    @ObservationIgnored private let debounce: @Sendable () async throws -> Void

    static let debounceInterval = Duration.milliseconds(400)

    init(router: any StockbarActivityTransactionsRouting = FolyncSupplementalCoordinator.shared,
         debounce: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: StockbarActivityViewModel.debounceInterval) }) {
        self.router = router
        self.debounce = debounce
    }

    /// The page became the selected page, or the portfolio source changed
    /// while it is. Asks once; a second call while the rows answer the current
    /// query asks nothing.
    func activate(isFolyncPortfolio: Bool) {
        isActive = true
        self.isFolyncPortfolio = isFolyncPortfolio
        guard isFolyncPortfolio else {
            cancelTask()
            clearRows()
            appliedQuery = nil
            phase = .needsFolync
            return
        }
        if task != nil { return }
        if appliedQuery == query, phase != .idle, phase != .needsFolync { return }
        startFirstPage(query, forceRefresh: false, debounced: false)
    }

    /// The page is no longer selected: stop whatever is in flight.
    func deactivate() {
        isActive = false
        cancelTask()
    }

    /// The refresh control: page one again, asked of Folync afresh.
    func refresh() {
        guard isActive, isFolyncPortfolio else { return }
        startFirstPage(query, forceRefresh: true, debounced: false)
    }

    /// "Load more": the page after the last one, for the query on screen.
    func loadMore() {
        guard isActive, canLoadMore, let continuation, let query = appliedQuery else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let generation = nextGeneration()
        task = Task { [weak self, router] in
            let result = await router.loadMoreTransactions(query, after: continuation)
            guard !Task.isCancelled, let self else { return }
            self.applyMore(result)
            self.finish(generation)
        }
    }

    private func controlsChanged() {
        guard isActive, isFolyncPortfolio else { return }
        let next = query
        if next == appliedQuery, phase != .idle, phase != .needsFolync {
            // Back to the query on screen: drop the pending one and ask nothing.
            cancelTask()
            return
        }
        startFirstPage(next, forceRefresh: false, debounced: true)
    }

    private func startFirstPage(_ query: FolyncTransactionsQuery, forceRefresh: Bool, debounced: Bool) {
        cancelTask()
        isQueryPending = debounced
        isRefreshing = forceRefresh
        let generation = nextGeneration()
        let debounce = debounce
        task = Task { [weak self, router] in
            if debounced {
                do { try await debounce() } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            if query != self.appliedQuery {
                // Other rows answered another query: show loading, not them.
                self.clearRows()
                self.phase = .loading
            }
            let result = await router.routeTransactions(query, forceRefresh: forceRefresh)
            // A cancelled caller is answered `.unavailable`: never apply it.
            guard !Task.isCancelled else { return }
            self.applyFirstPage(result, query: query)
            self.finish(generation)
        }
    }

    private func applyFirstPage(_ result: FolyncRoutedTransactionsResult, query: FolyncTransactionsQuery) {
        appliedQuery = query
        isQueryPending = false
        isRefreshing = false
        loadMoreFailed = false
        switch result {
        case .folync(let response, let status, _):
            show(response, status: status)
        case .disabled:
            clearRows()
            phase = .disabled
        case .unavailable:
            clearRows()
            phase = .unavailable
        case .unreachable:
            clearRows()
            phase = .unreachable
        }
    }

    private func applyMore(_ result: FolyncRoutedTransactionsResult) {
        isLoadingMore = false
        switch result {
        case .folync(let response, let status, .nextPage):
            let known = Set(transactions.map(\.id))
            transactions += response.transactions.filter { !known.contains($0.id) }
            continuation = response.page.continuation
            if response.quality != .complete, quality == .complete { quality = response.quality }
            reasonCodes += response.reasonCodes.filter { !reasonCodes.contains($0) }
            if status == .stale { phase = .stale(savedAt: FolyncSupplementalDateParser.instant(response.generatedAt)) }
        case .folync(let response, let status, _):
            // Paging started again: drop the rows gathered and show page one.
            show(response, status: status)
        case .disabled, .unavailable, .unreachable:
            loadMoreFailed = true
        }
    }

    private func show(_ response: FolyncTransactionsResponse, status: FolyncSupplementalSourceStatus) {
        var seen = Set<String>()
        transactions = response.transactions.filter { seen.insert($0.id).inserted }
        continuation = response.page.continuation
        quality = response.quality
        reasonCodes = response.reasonCodes
        phase = status == .stale ? .stale(savedAt: FolyncSupplementalDateParser.instant(response.generatedAt)) : .loaded
    }

    private func clearRows() {
        transactions = []
        continuation = nil
        quality = .complete
        reasonCodes = []
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        isQueryPending = false
        isRefreshing = false
        isLoadingMore = false
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func finish(_ generation: Int) {
        guard generation == self.generation else { return }
        task = nil
    }
}
