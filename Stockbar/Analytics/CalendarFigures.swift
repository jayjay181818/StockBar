import Foundation

// What the Calendar page and "Next up" show: one row per dated event, built
// from answers the app already has.
//
// - A Folync portfolio's dividends come from Folync's dividends answer, the
//   one the Income page asks for (`IncomeFigures.query(today:)`).
// - A local or Trading 212 portfolio's dividends come from the Income page's
//   own estimate (`LocalIncomeEstimate`), never from a second one.
// - Earnings dates come from Yahoo (`InstrumentEvents`), for either portfolio.
//
// Every date is a calendar day (`FolyncLedgerDay`), read straight from the
// answer, and every sum of days is done in UTC on noon of the day, so no date
// moves to the day before or after in the user's time zone.

/// What a row is.
enum CalendarEventKind: Int, Comparable, Sendable {
    case exDividend
    case payment
    case earnings

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The label beside a row that says how sure its date is.
enum CalendarPill: String, Equatable, Sendable {
    /// Folync: the date is published by the company.
    case declared = "Declared"
    /// Folync's estimate, Stockbar's estimate from last year's payments, or a
    /// range of earnings dates from Yahoo.
    case estimated = "Estimated"
    /// Folync lists the payment as still to come and says nothing about how
    /// sure its date is.
    case upcoming = "Upcoming"

    var title: String { rawValue }
}

/// The page's two views.
enum CalendarMode: String, CaseIterable, Hashable, Sendable {
    case upcoming
    case past

    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .past: "Past"
        }
    }
}

/// Which rows the page shows.
enum CalendarFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case dividends
    case earnings

    var title: String {
        switch self {
        case .all: "All"
        case .dividends: "Dividends"
        case .earnings: "Earnings"
        }
    }
}

/// Where a holding's dividend rows come from, for the footer and the wording.
enum CalendarDividendSource: Equatable, Sendable {
    /// Folync's dividends answer: amounts in the portfolio's currency, as given.
    case folync
    /// The Income page's estimate from Yahoo's record: every amount is "about".
    case yahooEstimate
}

/// A holding as Calendar asks about it.
struct CalendarHolding: Equatable, Sendable {
    /// The symbol shown on the row.
    let symbol: String
    /// The symbol Yahoo is asked about for earnings dates; nil when the app
    /// has none for the holding, which then gets no earnings rows.
    let yahooSymbol: String?
}

/// One dated event: a line of the list and an entry in the grid.
struct CalendarRow: Identifiable, Equatable, Sendable {
    let id: String
    let kind: CalendarEventKind
    let day: FolyncLedgerDay
    let symbol: String
    /// An ex-dividend row's pay day, when it is known.
    let payDay: FolyncLedgerDay?
    /// The last day of an earnings range; nil for a single date.
    let endDay: FolyncLedgerDay?
    /// In `currency`; nil when not known.
    let amount: Double?
    /// Empty when no currency is named; the amount is then shown without a symbol.
    let currency: String
    /// Stockbar's estimate, written "about £X".
    let amountIsEstimate: Bool
    /// Folync marks the amount partial.
    let amountIsPartial: Bool
    let pill: CalendarPill?

    var isDividend: Bool { kind != .earnings }
    var isEstimated: Bool { pill == .estimated }

    /// Soonest first; on one day an ex-dividend date, then a payment, then
    /// earnings, then by symbol.
    static func soonestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.symbol != rhs.symbol { return lhs.symbol < rhs.symbol }
        return lhs.id < rhs.id
    }

    /// Newest first, the same order within a day.
    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.day != rhs.day { return lhs.day > rhs.day }
        return soonestFirst(lhs, rhs)
    }
}

/// The rows of a portfolio, split at today.
struct CalendarRows: Equatable, Sendable {
    /// Today and later, soonest first.
    var upcoming: [CalendarRow] = []
    /// Before today, dividends only, newest first.
    var past: [CalendarRow] = []

    static let empty = CalendarRows()
}

/// The months the month bar can show.
struct CalendarMonthRange: Equatable, Sendable {
    let first: IncomeMonth
    let last: IncomeMonth

    /// Upcoming: this month to twelve months ahead. Past: twelve months back to this month.
    init(mode: CalendarMode, today: FolyncLedgerDay) {
        let current = today.incomeMonth
        switch mode {
        case .upcoming:
            first = current
            last = current.adding(12)
        case .past:
            first = current.adding(-12)
            last = current
        }
    }

    /// The month a view opens on: this month, in both views.
    static func start(mode: CalendarMode, today: FolyncLedgerDay) -> IncomeMonth { today.incomeMonth }

    func canGoBack(from month: IncomeMonth) -> Bool { month > first }
    func canGoForward(from month: IncomeMonth) -> Bool { month < last }

    func clamped(_ month: IncomeMonth) -> IncomeMonth { min(max(month, first), last) }
}

/// One day of the month grid.
struct CalendarGridDay: Identifiable, Equatable, Sendable {
    let day: FolyncLedgerDay
    /// In the month shown; other days are dimmed.
    let isInMonth: Bool
    let isToday: Bool
    /// The day's rows, in list order.
    let rows: [CalendarRow]
    /// The rows drawn in the cell; the rest are counted in `overflow`.
    let shown: [CalendarRow]
    let overflow: Int

    var id: String { day.string }
}

/// A heading of the list and its rows.
struct CalendarGroup: Identifiable, Equatable, Sendable {
    enum Key: Hashable, Sendable {
        case thisWeek
        case nextWeek
        case month(IncomeMonth)
    }

    let key: Key
    let rows: [CalendarRow]

    var id: Key { key }
}

/// What the earnings answers left unsaid, for the page's footer and notices.
struct CalendarEarningsCoverage: Equatable, Sendable {
    /// Holdings the app has no Yahoo symbol for.
    let withoutSymbol: Int
    /// Holdings with a symbol whose answer gives no earnings date (or no answer).
    let withoutDate: Int

    /// Holdings with no earnings date at all, for whatever reason.
    var total: Int { withoutSymbol + withoutDate }
}

enum CalendarFigures {
    /// "Next up" looks this many days ahead, today included.
    static let nextUpDays = 14
    /// "Next up" shows at most this many events.
    static let nextUpLimit = 3
    /// A grid cell shows at most this many lines; more become "+N".
    static let gridLines = 3

    // MARK: Days

    /// `days` calendar days later (earlier when negative).
    static func adding(days: Int, to day: FolyncLedgerDay) -> FolyncLedgerDay {
        guard let date = IncomeFigures.utcCalendar.date(byAdding: .day, value: days, to: day.formattingDate) else {
            return day
        }
        return FolyncLedgerDay(date, in: IncomeFigures.utcCalendar.timeZone)
    }

    /// 0 for Monday to 6 for Sunday.
    static func weekdayIndex(_ day: FolyncLedgerDay) -> Int {
        let weekday = IncomeFigures.utcCalendar.component(.weekday, from: day.formattingDate)
        return (weekday + 5) % 7
    }

    /// The Monday of the week `day` falls in.
    static func monday(of day: FolyncLedgerDay) -> FolyncLedgerDay {
        adding(days: -weekdayIndex(day), to: day)
    }

    static func day(_ day: InstrumentEventDay) -> FolyncLedgerDay {
        LocalIncomeFigures.day(day)
    }

    // MARK: Holdings

    /// Calendar's holdings: one per symbol, as the Income estimate counts them
    /// (watchlist rows, benchmarks and rows with no units left out), each with
    /// the symbol Yahoo is asked about for its earnings.
    ///
    /// For a local or Trading 212 portfolio that is the symbol the app asks
    /// Yahoo for the holding's price. A Folync portfolio's prices come from
    /// Folync, so its holdings use the quote symbol Folync gives for each
    /// (`FolyncHolding.quoteSymbol`); a holding without one gets no earnings.
    static func holdings(local: [LocalIncomeHolding], folyncHoldings: [FolyncHolding]?) -> [CalendarHolding] {
        func asked(_ symbol: String?) -> String? {
            guard let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  !symbol.isEmpty, PythonConfiguration.validateSymbol(symbol) else { return nil }
            return symbol
        }
        guard let folyncHoldings else {
            return local.map { CalendarHolding(symbol: $0.symbol, yahooSymbol: asked($0.symbol)) }
        }
        var quotes: [String: String] = [:]
        for holding in folyncHoldings {
            let key = holding.resolvedDisplayTicker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if quotes[key] == nil, let quote = asked(holding.quoteSymbol) { quotes[key] = quote }
        }
        return local.map { CalendarHolding(symbol: $0.symbol, yahooSymbol: quotes[$0.symbol]) }
    }

    // MARK: A Folync portfolio's dividends

    /// The pill for an event still to come, from Folync's date certainty alone:
    /// "Declared" when published, "Estimated" when estimated, and "Upcoming"
    /// when Folync gives no discovery detail or does not know.
    static func pill(for discovery: FolyncDividendEventDiscovery?) -> CalendarPill {
        switch discovery?.dateCertainty.knownValue {
        case .published: .declared
        case .estimated: .estimated
        case .unknown, nil: .upcoming
        }
    }

    /// Rows from Folync's dividends answer.
    ///
    /// - An event not yet received gives a payment row on its pay day, and an
    ///   ex-dividend row on its ex-dividend day when that is before the pay
    ///   day. Rows from today on are upcoming. A payment Folync has not marked
    ///   received whose pay day has passed goes to Past, with its pill.
    /// - A received event gives a payment row in Past with no pill.
    /// - Past holds payments only, from twelve months back.
    static func folyncRows(events: [FolyncDividendEvent], currency: String, today: FolyncLedgerDay) -> CalendarRows {
        let pastStart = today.adding(months: -12)
        let upcomingEnd = CalendarMonthRange(mode: .upcoming, today: today).last
        var rows = CalendarRows()
        for event in events {
            guard let pay = IncomeFigures.payDay(of: event) else { continue }
            let amount = IncomeFigures.portfolioAmount(of: event, currency: currency)
            let partial = amount != nil && event.portfolioAmount.quality == .partial
            let symbol = IncomeFigures.holding(of: event)
            let received = IncomeFigures.isReceived(event)
            let pill: CalendarPill? = received ? nil : pill(for: event.discovery)
            func row(_ kind: CalendarEventKind, on day: FolyncLedgerDay, payDay: FolyncLedgerDay? = nil) -> CalendarRow {
                CalendarRow(id: "\(event.eventId)#\(kind == .exDividend ? "ex" : "pay")", kind: kind, day: day,
                            symbol: symbol, payDay: payDay, endDay: nil, amount: amount, currency: currency,
                            amountIsEstimate: false, amountIsPartial: partial, pill: pill)
            }
            if !received, pay >= today {
                if pay.incomeMonth <= upcomingEnd { rows.upcoming.append(row(.payment, on: pay)) }
                if let ex = IncomeFigures.exDay(of: event), ex >= today, ex < pay, ex.incomeMonth <= upcomingEnd {
                    rows.upcoming.append(row(.exDividend, on: ex, payDay: pay))
                }
            } else if pay >= pastStart, pay <= today || received {
                rows.past.append(row(.payment, on: pay))
            }
        }
        rows.upcoming.sort(by: CalendarRow.soonestFirst)
        rows.past.sort(by: CalendarRow.newestFirst)
        return rows
    }

    // MARK: A local or Trading 212 portfolio's dividends

    /// Rows from the Income page's estimate.
    ///
    /// - Past: Yahoo's payments of the last twelve months, as ex-dividend rows
    ///   (Yahoo's dividend dates are ex-dividend dates) at today's units.
    /// - Upcoming: each estimated payment as an ex-dividend row with the
    ///   "Estimated" pill; each of Yahoo's own upcoming dates with no pill
    ///   (Yahoo does not say whether a date is declared). Where Yahoo gives a
    ///   pay date, the ex-dividend row names it and a payment row is added.
    /// Every amount is the estimate's, written "about".
    static func localRows(estimate: LocalIncomeEstimate) -> CalendarRows {
        let today = estimate.today
        var rows = CalendarRows()
        func amount(_ payment: LocalIncomePayment) -> (Double?, String) {
            if let converted = payment.amount { return (converted, estimate.currency) }
            return (payment.ownAmount, payment.ownAmount == nil ? estimate.currency : payment.ownCurrency)
        }
        for payment in estimate.lastYear where payment.date < today {
            let (value, currency) = amount(payment)
            rows.past.append(CalendarRow(id: "\(payment.id)#ex", kind: .exDividend, day: payment.date,
                                         symbol: payment.holding, payDay: nil, endDay: nil, amount: value,
                                         currency: currency, amountIsEstimate: true, amountIsPartial: false, pill: nil))
        }
        for payment in estimate.nextYear where payment.date >= today {
            let (value, currency) = amount(payment)
            let pill: CalendarPill? = payment.dateSource == .estimated ? .estimated : nil
            let pays = payment.payDay.flatMap { $0 >= payment.date ? $0 : nil }
            rows.upcoming.append(CalendarRow(id: "\(payment.id)#ex", kind: .exDividend, day: payment.date,
                                             symbol: payment.holding, payDay: pays, endDay: nil, amount: value,
                                             currency: currency, amountIsEstimate: true, amountIsPartial: false,
                                             pill: pill))
            if let pays {
                rows.upcoming.append(CalendarRow(id: "\(payment.id)#pay", kind: .payment, day: pays,
                                                 symbol: payment.holding, payDay: nil, endDay: nil, amount: value,
                                                 currency: currency, amountIsEstimate: true, amountIsPartial: false,
                                                 pill: pill))
            }
        }
        rows.upcoming.sort(by: CalendarRow.soonestFirst)
        rows.past.sort(by: CalendarRow.newestFirst)
        return rows
    }

    // MARK: Earnings

    /// Earnings rows from Yahoo's answers, keyed by the symbol asked.
    ///
    /// A single date is "Earnings" with no pill: Yahoo does not say whether it
    /// is confirmed. A range is one row on its first day with the "Estimated"
    /// pill. A date before today is not shown, nor a range whose first day has
    /// passed. A holding with no Yahoo symbol gets no row.
    static func earningsRows(holdings: [CalendarHolding], answers: [String: InstrumentEvents],
                             today: FolyncLedgerDay) -> [CalendarRow] {
        let upcomingEnd = CalendarMonthRange(mode: .upcoming, today: today).last
        var seen = Set<String>()
        var rows: [CalendarRow] = []
        for holding in holdings {
            guard let asked = holding.yahooSymbol?.uppercased(), seen.insert(asked).inserted,
                  let events = answers[asked], let start = events.earningsDate.map(day) else { continue }
            guard start >= today, start.incomeMonth <= upcomingEnd else { continue }
            let end = events.earningsDateEnd.map(day).flatMap { $0 > start ? $0 : nil }
            rows.append(CalendarRow(id: "\(asked)#earnings", kind: .earnings, day: start, symbol: holding.symbol,
                                    payDay: nil, endDay: end, amount: nil, currency: "", amountIsEstimate: false,
                                    amountIsPartial: false, pill: end == nil ? nil : .estimated))
        }
        return rows.sorted(by: CalendarRow.soonestFirst)
    }

    /// How many holdings have no earnings date shown, and why.
    static func earningsCoverage(holdings: [CalendarHolding], answers: [String: InstrumentEvents],
                                 today: FolyncLedgerDay) -> CalendarEarningsCoverage {
        let shown = Set(earningsRows(holdings: holdings, answers: answers, today: today).map(\.symbol))
        var withoutSymbol = 0
        var withoutDate = 0
        for holding in holdings where !shown.contains(holding.symbol) {
            if holding.yahooSymbol == nil { withoutSymbol += 1 } else { withoutDate += 1 }
        }
        return CalendarEarningsCoverage(withoutSymbol: withoutSymbol, withoutDate: withoutDate)
    }

    /// Dividend rows and earnings rows together. Earnings are upcoming only.
    static func combined(dividends: CalendarRows, earnings: [CalendarRow]) -> CalendarRows {
        CalendarRows(upcoming: (dividends.upcoming + earnings).sorted(by: CalendarRow.soonestFirst),
                     past: dividends.past)
    }

    // MARK: Filters

    /// The filters a view offers. Past lists dividends only, so it has no
    /// Earnings filter.
    static func filters(for mode: CalendarMode) -> [CalendarFilter] {
        switch mode {
        case .upcoming: CalendarFilter.allCases
        case .past: [.all, .dividends]
        }
    }

    /// The rows a view shows under a filter.
    static func rows(_ rows: CalendarRows, mode: CalendarMode, filter: CalendarFilter) -> [CalendarRow] {
        let list = mode == .upcoming ? rows.upcoming : rows.past.filter(\.isDividend)
        switch filter {
        case .all: return list
        case .dividends: return list.filter(\.isDividend)
        case .earnings: return mode == .upcoming ? list.filter { !$0.isDividend } : []
        }
    }

    // MARK: The list

    /// Upcoming rows under "This week" (today to Sunday), "Next week", then
    /// one heading per month. Groups with no rows are left out.
    static func upcomingGroups(_ rows: [CalendarRow], today: FolyncLedgerDay) -> [CalendarGroup] {
        let thisSunday = adding(days: 6, to: monday(of: today))
        let nextSunday = adding(days: 7, to: thisSunday)
        var order: [CalendarGroup.Key] = []
        var grouped: [CalendarGroup.Key: [CalendarRow]] = [:]
        for row in rows.sorted(by: CalendarRow.soonestFirst) {
            let key: CalendarGroup.Key = row.day <= thisSunday ? .thisWeek
                : row.day <= nextSunday ? .nextWeek : .month(row.day.incomeMonth)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        return order.map { CalendarGroup(key: $0, rows: grouped[$0] ?? []) }
    }

    /// Past rows by month, newest first.
    static func pastGroups(_ rows: [CalendarRow]) -> [CalendarGroup] {
        var order: [CalendarGroup.Key] = []
        var grouped: [CalendarGroup.Key: [CalendarRow]] = [:]
        for row in rows.sorted(by: CalendarRow.newestFirst) {
            let key = CalendarGroup.Key.month(row.day.incomeMonth)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        return order.map { CalendarGroup(key: $0, rows: grouped[$0] ?? []) }
    }

    // MARK: The grid

    /// The weeks that show `month`, Monday first, each day with its rows.
    /// Days of the months before and after fill the first and last weeks.
    static func grid(month: IncomeMonth, rows: [CalendarRow], today: FolyncLedgerDay,
                     lines: Int = gridLines) -> [[CalendarGridDay]] {
        let first = FolyncLedgerDay(year: month.year, month: month.month, day: 1)
        let last = FolyncLedgerDay(year: month.year, month: month.month, day: month.dayCount)
        let start = monday(of: first)
        let end = adding(days: 6, to: monday(of: last))
        var byDay: [FolyncLedgerDay: [CalendarRow]] = [:]
        for row in rows where row.day >= start && row.day <= end {
            byDay[row.day, default: []].append(row)
        }
        var weeks: [[CalendarGridDay]] = []
        var day = start
        while day <= end {
            var week: [CalendarGridDay] = []
            for _ in 0..<7 {
                let dayRows = (byDay[day] ?? []).sorted(by: CalendarRow.soonestFirst)
                let fits = dayRows.count <= lines
                let shown = fits ? dayRows : Array(dayRows.prefix(max(lines - 1, 0)))
                week.append(CalendarGridDay(day: day, isInMonth: day.incomeMonth == month, isToday: day == today,
                                            rows: dayRows, shown: shown, overflow: dayRows.count - shown.count))
                day = day.next
            }
            weeks.append(week)
        }
        return weeks
    }

    // MARK: Next up

    /// Up to three events from today to fourteen days ahead, soonest first.
    static func nextUp(_ rows: [CalendarRow], today: FolyncLedgerDay) -> [CalendarRow] {
        let end = adding(days: nextUpDays, to: today)
        return Array(rows.filter { $0.day >= today && $0.day <= end }
            .sorted(by: CalendarRow.soonestFirst)
            .prefix(nextUpLimit))
    }
}
