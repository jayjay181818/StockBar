import Foundation

// What the Income page derives from Folync's dividends answer.
//
// Folync's own figures (the projection, declared and estimated income, the
// yield, the income received) are shown as given and never worked out here.
// The only sums of the page's own are a chart bar (the payments listed for one
// month) and a holding's total (the payments listed for it over the months
// the chart shows). Both are over the events in the answer, and the page says so.
//
// Dates are calendar days as Folync writes them ("2026-11-24"), read straight
// into year, month and day: a day never goes through a `Date` in a time zone,
// so it cannot move to the day before.

extension FolyncLedgerDay: Comparable {
    /// The day in a "yyyy-MM-dd" string, or nil when it is not one. Anything
    /// after the tenth character (a time) is ignored.
    init?(string: String) {
        let parts = string.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    var incomeMonth: IncomeMonth { IncomeMonth(year: year, month: month) }

    /// `months` calendar months later (earlier when negative), on the same day
    /// or the last day of a shorter month.
    func adding(months: Int) -> FolyncLedgerDay {
        let target = incomeMonth.adding(months)
        return FolyncLedgerDay(year: target.year, month: target.month, day: min(day, target.dayCount))
    }

    /// The next calendar day.
    var next: FolyncLedgerDay {
        if day < incomeMonth.dayCount { return FolyncLedgerDay(year: year, month: month, day: day + 1) }
        let following = incomeMonth.adding(1)
        return FolyncLedgerDay(year: following.year, month: following.month, day: 1)
    }

    /// Noon UTC on this day, for formatting only, in UTC.
    var formattingDate: Date {
        IncomeFigures.utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }
}

/// A calendar month.
struct IncomeMonth: Hashable, Comparable, Sendable {
    let year: Int
    let month: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    func adding(_ months: Int) -> IncomeMonth {
        let index = year * 12 + (month - 1) + months
        return IncomeMonth(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1)
    }

    var dayCount: Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    var formattingDate: Date { FolyncLedgerDay(year: year, month: month, day: 1).formattingDate }
}

/// Which part of a month's bar an event adds to.
enum IncomePart: CaseIterable, Equatable, Sendable {
    /// Paid, by Folync's status.
    case received
    /// Still to come, and Folync gives the amount as published by the company.
    case declared
    /// Still to come, and Folync gives the amount as its estimate.
    case estimated
    /// Still to come, and Folync's answer does not say whether the amount is
    /// published or estimated (no discovery detail, or an unknown certainty).
    case toCome

    var title: String {
        switch self {
        case .received: "Received"
        case .declared: "Declared"
        case .estimated: "Estimated"
        case .toCome: "To come"
        }
    }
}

/// One month of the chart: the sums of the payments listed for it.
struct IncomeChartMonth: Identifiable, Equatable, Sendable {
    let month: IncomeMonth
    var received: Double = 0
    var declared: Double = 0
    var estimated: Double = 0
    var toCome: Double = 0
    /// Payments listed for the month whose amount is not known, in the
    /// portfolio's currency. They add nothing to the bar.
    var missingAmounts = 0
    /// Payments added to the bar whose amount Folync marks partial.
    var partialAmounts = 0
    /// Any payment is listed for the month.
    var hasPayments = false

    var id: IncomeMonth { month }
    var total: Double { received + declared + estimated + toCome }

    func amount(_ part: IncomePart) -> Double {
        switch part {
        case .received: received
        case .declared: declared
        case .estimated: estimated
        case .toCome: toCome
        }
    }

    mutating func add(_ value: Double, to part: IncomePart) {
        switch part {
        case .received: received += value
        case .declared: declared += value
        case .estimated: estimated += value
        case .toCome: toCome += value
        }
    }
}

/// The twelve months the chart shows: the six up to and including this one,
/// and the six after it.
struct IncomeChart: Equatable, Sendable {
    let months: [IncomeChartMonth]
    let currentMonth: IncomeMonth
    let currency: String
    /// Folync has more events than the pages loaded: the bars may be short.
    let isIncomplete: Bool

    var missingAmounts: Int { months.reduce(0) { $0 + $1.missingAmounts } }
    var partialAmounts: Int { months.reduce(0) { $0 + $1.partialAmounts } }
    var maximum: Double { months.map(\.total).max() ?? 0 }
    /// Parts drawn in at least one month, in drawing order.
    var partsShown: [IncomePart] { IncomePart.allCases.filter { part in months.contains { $0.amount(part) > 0 } } }
    var currentIndex: Int? { months.firstIndex { $0.month == currentMonth } }
}

/// One line of "what is coming": an ex-dividend date or a payment.
struct IncomeUpcomingRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The ex-dividend date; the payment follows on `payDay`.
        case exDividend(payDay: FolyncLedgerDay)
        case payment
    }

    let eventID: String
    let kind: Kind
    let date: FolyncLedgerDay
    let holding: String
    /// In the portfolio's currency; nil when not known.
    let amount: Double?
    let amountIsPartial: Bool
    /// "Declared", "Estimated", "Amount declared, date estimated", or nil
    /// when Folync's answer carries no discovery detail for the event.
    let pill: String?

    var id: String {
        switch kind {
        case .exDividend: "\(eventID)#ex"
        case .payment: "\(eventID)#pay"
        }
    }
}

/// One received payment.
struct IncomeHistoryRow: Identifiable, Equatable, Sendable {
    let eventID: String
    let date: FolyncLedgerDay
    let holding: String
    /// In the portfolio's currency; nil when not known.
    let amount: Double?
    let amountIsPartial: Bool
    /// The amount in the payment's own currency, when that differs from the
    /// portfolio's: (amount, currency).
    let ownAmount: (value: Double, currency: String)?

    var id: String { eventID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.eventID == rhs.eventID && lhs.date == rhs.date && lhs.holding == rhs.holding
            && lhs.amount == rhs.amount && lhs.amountIsPartial == rhs.amountIsPartial
            && lhs.ownAmount?.value == rhs.ownAmount?.value && lhs.ownAmount?.currency == rhs.ownAmount?.currency
    }
}

/// One holding that pays, over the months the chart shows.
struct IncomeHoldingRow: Identifiable, Equatable, Sendable {
    let assetID: String
    let holding: String
    /// Received in the chart's months, from the payments listed. Nil when
    /// payments are listed there but none has a known amount: unknown, not zero.
    let received: Double?
    /// Still to come in the chart's months, from the payments listed; nil as above.
    let toCome: Double?
    /// Payments in the chart's months with no amount; they add nothing.
    let missingAmounts: Int
    /// The soonest payment still to come, if one is listed.
    let nextPayment: (date: FolyncLedgerDay, amount: Double?)?

    var id: String { assetID }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.assetID == rhs.assetID && lhs.holding == rhs.holding && lhs.received == rhs.received
            && lhs.toCome == rhs.toCome && lhs.missingAmounts == rhs.missingAmounts
            && lhs.nextPayment?.date == rhs.nextPayment?.date && lhs.nextPayment?.amount == rhs.nextPayment?.amount
    }
}

/// A labelled figure beside the headline, as Folync gives it.
struct IncomeFigureLine: Equatable, Sendable {
    let title: String
    let value: String
}

enum IncomeFigures {
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    // MARK: The query

    /// The one request that serves all three views: received and upcoming
    /// events with pay dates from twelve months back to twelve months ahead,
    /// at the route's largest page.
    static func query(today: FolyncLedgerDay) -> FolyncDividendsQuery {
        FolyncDividendsQuery(status: .all, from: today.adding(months: -12), to: today.adding(months: 12),
                             limit: FolyncDividendsQuery.maximumLimit)
    }

    // MARK: Events

    /// The currency the page sums in: the answer's, else the scope's.
    static func portfolioCurrency(_ response: FolyncDividendsResponse) -> String {
        response.currency ?? response.scope.currency ?? response.valuation.currency ?? "GBP"
    }

    static func isReceived(_ event: FolyncDividendEvent) -> Bool {
        event.status.knownValue == .received
    }

    /// The part of a bar the event adds to. An event is received only when
    /// Folync says so; any other status, including one this build does not
    /// know, is still to come.
    static func part(of event: FolyncDividendEvent) -> IncomePart {
        if isReceived(event) { return .received }
        switch event.discovery?.amountCertainty.knownValue {
        case .published: return .declared
        case .estimated: return .estimated
        case .unknown, nil: return .toCome
        }
    }

    /// The event's amount in the portfolio's currency, or nil when Folync does
    /// not give one: no value, marked unavailable, or in another currency.
    static func portfolioAmount(of event: FolyncDividendEvent, currency: String) -> Double? {
        let metric = event.portfolioAmount
        guard metric.quality != .unavailable, let value = metric.value, value.isFinite else { return nil }
        if let metricCurrency = metric.currency, metricCurrency.uppercased() != currency.uppercased() { return nil }
        return value
    }

    static func payDay(of event: FolyncDividendEvent) -> FolyncLedgerDay? {
        FolyncLedgerDay(string: event.payDate)
    }

    static func exDay(of event: FolyncDividendEvent) -> FolyncLedgerDay? {
        (event.exDate ?? event.discovery?.exDate).flatMap(FolyncLedgerDay.init(string:))
    }

    static func holding(of event: FolyncDividendEvent) -> String {
        let ticker = event.identity.displayTicker
        return ticker.isEmpty ? event.identity.canonicalTicker : ticker
    }

    // MARK: The chart

    static func chartMonths(around today: FolyncLedgerDay) -> [IncomeMonth] {
        (-5...6).map { today.incomeMonth.adding($0) }
    }

    /// Sums the events listed into the twelve months around `today`, by pay
    /// date. Events outside those months, or with a pay date that is not a
    /// date, are left out.
    static func chart(events: [FolyncDividendEvent], currency: String, today: FolyncLedgerDay,
                      isIncomplete: Bool) -> IncomeChart {
        var months = chartMonths(around: today).map { IncomeChartMonth(month: $0) }
        let index = Dictionary(months.enumerated().map { ($1.month, $0) }, uniquingKeysWith: { first, _ in first })
        for event in events {
            guard let day = payDay(of: event), let position = index[day.incomeMonth] else { continue }
            months[position].hasPayments = true
            guard let amount = portfolioAmount(of: event, currency: currency) else {
                months[position].missingAmounts += 1
                continue
            }
            months[position].add(amount, to: part(of: event))
            if event.portfolioAmount.quality == .partial { months[position].partialAmounts += 1 }
        }
        return IncomeChart(months: months, currentMonth: today.incomeMonth, currency: currency, isIncomplete: isIncomplete)
    }

    // MARK: What is coming

    /// Every event not yet received, as its payment, and as its ex-dividend
    /// date too while that is today or later. Soonest first; on the same day
    /// an ex-dividend date comes before a payment, then by holding.
    static func upcoming(events: [FolyncDividendEvent], currency: String, today: FolyncLedgerDay) -> [IncomeUpcomingRow] {
        var rows: [IncomeUpcomingRow] = []
        for event in events where !isReceived(event) {
            guard let pay = payDay(of: event) else { continue }
            let amount = portfolioAmount(of: event, currency: currency)
            let partial = amount != nil && event.portfolioAmount.quality == .partial
            let pill = pill(for: event.discovery)
            if let ex = exDay(of: event), ex >= today, ex < pay {
                rows.append(IncomeUpcomingRow(eventID: event.eventId, kind: .exDividend(payDay: pay), date: ex,
                                              holding: holding(of: event), amount: amount, amountIsPartial: partial,
                                              pill: pill))
            }
            rows.append(IncomeUpcomingRow(eventID: event.eventId, kind: .payment, date: pay,
                                          holding: holding(of: event), amount: amount, amountIsPartial: partial,
                                          pill: pill))
        }
        return rows.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            let lhsEx = lhs.kind != .payment, rhsEx = rhs.kind != .payment
            if lhsEx != rhsEx { return lhsEx }
            if lhs.holding != rhs.holding { return lhs.holding < rhs.holding }
            return lhs.eventID < rhs.eventID
        }
    }

    /// The pill for an event, from Folync's discovery detail only: "Declared"
    /// when both the amount and the date are published, "Estimated" when both
    /// are estimated, and which is which when they differ. No detail, or
    /// nothing known about either, gives no pill.
    static func pill(for discovery: FolyncDividendEventDiscovery?) -> String? {
        guard let discovery else { return nil }
        let amount = certaintyWord(discovery.amountCertainty)
        let date = certaintyWord(discovery.dateCertainty)
        if amount == date {
            switch amount {
            case "declared": return "Declared"
            case "estimated": return "Estimated"
            default: return nil
            }
        }
        return "Amount \(amount), date \(date)"
    }

    private static func certaintyWord(_ certainty: FolyncOpenEnum<FolyncDividendCertainty>) -> String {
        switch certainty.knownValue {
        case .published: "declared"
        case .estimated: "estimated"
        case .unknown, nil: "unknown"
        }
    }

    // MARK: History

    /// Received payments, newest first.
    static func history(events: [FolyncDividendEvent], currency: String) -> [IncomeHistoryRow] {
        events.compactMap { event -> IncomeHistoryRow? in
            guard isReceived(event), let day = payDay(of: event) else { return nil }
            let amount = portfolioAmount(of: event, currency: currency)
            let own: (value: Double, currency: String)? = event.amount.flatMap { value in
                guard value.isFinite, event.currency.uppercased() != currency.uppercased() else { return nil }
                return (value, event.currency)
            }
            return IncomeHistoryRow(eventID: event.eventId, date: day, holding: holding(of: event), amount: amount,
                                    amountIsPartial: amount != nil && event.portfolioAmount.quality == .partial,
                                    ownAmount: own)
        }
        .sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            if lhs.holding != rhs.holding { return lhs.holding < rhs.holding }
            return lhs.eventID > rhs.eventID
        }
    }

    // MARK: By holding

    /// One row per holding with a payment listed: what it received and has to
    /// come in the chart's months, and its soonest payment still to come.
    /// Largest total first. Holdings with no payment listed are not shown.
    static func byHolding(events: [FolyncDividendEvent], currency: String, today: FolyncLedgerDay) -> [IncomeHoldingRow] {
        let months = Set(chartMonths(around: today))
        struct Totals {
            var holding: String
            var received = 0.0
            var toCome = 0.0
            var receivedKnown = 0
            var receivedMissing = 0
            var toComeKnown = 0
            var toComeMissing = 0
            var missing: Int { receivedMissing + toComeMissing }
            var next: (date: FolyncLedgerDay, amount: Double?)?
        }
        var byAsset: [String: Totals] = [:]
        for event in events {
            guard let day = payDay(of: event) else { continue }
            var totals = byAsset[event.assetId] ?? Totals(holding: holding(of: event))
            let amount = portfolioAmount(of: event, currency: currency)
            if months.contains(day.incomeMonth) {
                switch (isReceived(event), amount) {
                case (true, let amount?): totals.received += amount; totals.receivedKnown += 1
                case (true, nil): totals.receivedMissing += 1
                case (false, let amount?): totals.toCome += amount; totals.toComeKnown += 1
                case (false, nil): totals.toComeMissing += 1
                }
            }
            if !isReceived(event), day >= today, totals.next.map({ day < $0.date }) ?? true {
                totals.next = (day, amount)
            }
            byAsset[event.assetId] = totals
        }
        return byAsset.map { asset, totals in
            IncomeHoldingRow(assetID: asset, holding: totals.holding,
                             received: totals.receivedKnown == 0 && totals.receivedMissing > 0 ? nil : totals.received,
                             toCome: totals.toComeKnown == 0 && totals.toComeMissing > 0 ? nil : totals.toCome,
                             missingAmounts: totals.missing, nextPayment: totals.next)
        }
        .sorted { lhs, rhs in
            let lhsTotal = (lhs.received ?? 0) + (lhs.toCome ?? 0), rhsTotal = (rhs.received ?? 0) + (rhs.toCome ?? 0)
            if lhsTotal != rhsTotal { return lhsTotal > rhsTotal }
            return lhs.holding < rhs.holding
        }
    }
}
