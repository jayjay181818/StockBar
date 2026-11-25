import Foundation

// What the Income page estimates for a local or Trading 212 portfolio.
//
// Stockbar has no record of what was paid to the user for these portfolios.
// It has Yahoo's record of each holding's dividends over the last twelve
// months (`InstrumentEventsService`) and the units held today. The estimate
// is the one sum those allow: each payment Yahoo lists, times today's units,
// and the same payments repeated a year on for the next twelve months. Every
// figure is labelled as an estimate, and never as received.
//
// Yahoo's dividend dates are ex-dividend dates. Where Yahoo gives a real
// upcoming ex-dividend date, it replaces the estimated date of the nearest
// repeated payment; the amount stays an estimate.

/// A holding the estimate is for: its symbol and the units held today.
struct LocalIncomeHolding: Equatable, Sendable {
    let symbol: String
    let units: Double
}

/// Where a payment's date comes from.
enum LocalIncomeDateSource: Equatable, Sendable {
    /// A dividend Yahoo lists in the last twelve months: Yahoo's date.
    case yahooRecord
    /// Last year's date, a year on: an estimate.
    case estimated
    /// Yahoo's own upcoming ex-dividend date, in place of an estimated one.
    case yahooUpcoming
}

/// One payment of the estimate, in the last twelve months or the next.
struct LocalIncomePayment: Identifiable, Equatable, Sendable {
    let id: String
    let holding: String
    /// The ex-dividend date: Yahoo's, or last year's a year on.
    let date: FolyncLedgerDay
    let dateSource: LocalIncomeDateSource
    /// Yahoo's pay date, when it gives one on or after `date`.
    let payDay: FolyncLedgerDay?
    /// Per unit, in `ownCurrency`; nil for a Yahoo date with no payment behind it.
    let perUnit: Double?
    let units: Double
    /// Per unit times today's units, in `ownCurrency`; nil when `perUnit` is.
    let ownAmount: Double?
    /// The currency Yahoo gives the holding's dividends in; empty when it names none.
    let ownCurrency: String
    /// `ownAmount` in the page's currency, with a loaded rate only; nil when
    /// there is no amount, no currency or no rate.
    let amount: Double?
}

/// One holding's line in "By holding".
struct LocalIncomeHoldingRow: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Yahoo lists payments in the last twelve months.
        case paying
        /// Yahoo answered and lists no payment in the last twelve months.
        case none
        /// Yahoo could not answer for the holding.
        case unknown
    }

    enum DateKind: Equatable, Sendable {
        case exDividend
        case payment
    }

    let symbol: String
    let state: State
    /// In the page's currency; nil when not known or not converted.
    let lastYear: Double?
    let nextYear: Double?
    /// The same sums in the holding's own currency, for a holding with payments.
    let ownLastYear: Double?
    let ownNextYear: Double?
    let ownCurrency: String
    /// The holding has payments that could not be converted: it is not in the totals.
    let isLeftOut: Bool
    /// Yahoo's own next ex-dividend or pay date, today or later, if it gives one.
    let nextDate: (day: FolyncLedgerDay, kind: DateKind)?

    var id: String { symbol }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.symbol == rhs.symbol && lhs.state == rhs.state && lhs.lastYear == rhs.lastYear
            && lhs.nextYear == rhs.nextYear && lhs.ownLastYear == rhs.ownLastYear
            && lhs.ownNextYear == rhs.ownNextYear && lhs.ownCurrency == rhs.ownCurrency
            && lhs.isLeftOut == rhs.isLeftOut && lhs.nextDate?.day == rhs.nextDate?.day
            && lhs.nextDate?.kind == rhs.nextDate?.kind
    }
}

/// One month of the estimate's chart.
struct LocalIncomeChartMonth: Identifiable, Equatable, Sendable {
    let month: IncomeMonth
    /// Payments Yahoo lists, at today's units, dated today or earlier.
    var lastYear: Double = 0
    /// The estimate for the next twelve months, dated after today.
    var nextYear: Double = 0

    var id: IncomeMonth { month }
    var total: Double { lastYear + nextYear }
}

/// The chart: the twelve months before this one, this one, and the twelve after.
struct LocalIncomeChart: Equatable, Sendable {
    let months: [LocalIncomeChartMonth]
    let currentMonth: IncomeMonth
    let currency: String

    var maximum: Double { months.map(\.total).max() ?? 0 }
}

/// A holding with payments the totals leave out, because no rate to the
/// page's currency is loaded or Yahoo names no currency for it.
struct LocalIncomeLeftOut: Equatable, Sendable {
    let symbol: String
    /// Empty when Yahoo names no currency.
    let currency: String
}

/// The whole estimate, in one currency.
struct LocalIncomeEstimate: Equatable, Sendable {
    let currency: String
    let today: FolyncLedgerDay
    /// Newest first.
    let lastYear: [LocalIncomePayment]
    /// Soonest first.
    let nextYear: [LocalIncomePayment]
    let holdings: [LocalIncomeHoldingRow]
    let chart: LocalIncomeChart
    /// Sums of the converted amounts; nil when no holding gave one and some
    /// holding is unknown or left out, so nothing is known.
    let lastYearTotal: Double?
    let nextYearTotal: Double?
    let leftOut: [LocalIncomeLeftOut]
    /// Holdings Yahoo could not answer for.
    let unknown: [String]
}

enum LocalIncomeFigures {
    /// How far an upcoming date from Yahoo may be from an estimated date and
    /// still be taken as the same payment.
    static let matchingWindowDays = 45

    /// The holdings to estimate for: one per symbol, with the units of every
    /// row that holds it added up. Watchlist rows, benchmarks, and rows with
    /// no units are left out.
    static func holdings(from trades: [RealTimeTrade]) -> [LocalIncomeHolding] {
        var order: [String] = []
        var units: [String: Double] = [:]
        for row in trades {
            let symbol = row.trade.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let held = row.trade.position.unitSize
            guard !row.trade.isWatchlistOnly, !symbol.isEmpty, !SymbolMetadata.isBenchmarkSymbol(symbol),
                  held.isFinite, held > 0 else { continue }
            if units[symbol] == nil { order.append(symbol) }
            units[symbol, default: 0] += held
        }
        return order.map { LocalIncomeHolding(symbol: $0, units: units[$0] ?? 0) }
    }

    static func day(_ day: InstrumentEventDay) -> FolyncLedgerDay {
        FolyncLedgerDay(year: day.year, month: day.month, day: day.day)
    }

    static func chartMonths(around today: FolyncLedgerDay) -> [IncomeMonth] {
        (-12...12).map { today.incomeMonth.adding($0) }
    }

    private static func days(from start: FolyncLedgerDay, to end: FolyncLedgerDay) -> Int {
        Int((end.formattingDate.timeIntervalSince(start.formattingDate) / 86_400).rounded())
    }

    /// The estimate for `holdings` from Yahoo's answers. A holding with no
    /// answer, or an answer with no dividend list, is unknown. `convert`
    /// turns an amount in a currency into the page's currency with loaded
    /// rates only, or gives nil.
    static func estimate(holdings: [LocalIncomeHolding], answers: [String: InstrumentEvents], currency: String,
                         today: FolyncLedgerDay, convert: (Double, String) -> Double?) -> LocalIncomeEstimate {
        let lastStart = today.adding(months: -12)
        let nextEnd = today.adding(months: 12)
        var lastYear: [LocalIncomePayment] = []
        var nextYear: [LocalIncomePayment] = []
        var rows: [LocalIncomeHoldingRow] = []
        var leftOut: [LocalIncomeLeftOut] = []
        var unknown: [String] = []

        for holding in holdings {
            guard let events = answers[holding.symbol], let dividends = events.dividends else {
                unknown.append(holding.symbol)
                rows.append(LocalIncomeHoldingRow(symbol: holding.symbol, state: .unknown, lastYear: nil, nextYear: nil,
                                                  ownLastYear: nil, ownNextYear: nil, ownCurrency: "",
                                                  isLeftOut: false, nextDate: nil))
                continue
            }
            let ownCurrency = events.dividendCurrency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            func payment(_ id: String, date: FolyncLedgerDay, source: LocalIncomeDateSource,
                         perUnit: Double?, payDay: FolyncLedgerDay? = nil) -> LocalIncomePayment {
                let own = perUnit.map { $0 * holding.units }
                let converted = own.flatMap { value in ownCurrency.isEmpty ? nil : convert(value, ownCurrency) }
                return LocalIncomePayment(id: id, holding: holding.symbol, date: date, dateSource: source,
                                          payDay: payDay, perUnit: perUnit, units: holding.units, ownAmount: own,
                                          ownCurrency: ownCurrency, amount: converted)
            }

            var past: [LocalIncomePayment] = []
            var coming: [LocalIncomePayment] = []
            for (index, dividend) in dividends.enumerated() where dividend.amount.isFinite {
                let date = day(dividend.date)
                let id = "\(holding.symbol)#\(index)"
                if date > today {
                    // Yahoo lists one still to come: its own date and amount.
                    if date <= nextEnd {
                        coming.append(payment("\(id)#listed", date: date, source: .yahooUpcoming, perUnit: dividend.amount))
                    }
                } else if date > lastStart {
                    past.append(payment(id, date: date, source: .yahooRecord, perUnit: dividend.amount))
                    let repeated = date.adding(months: 12)
                    if repeated > today, repeated <= nextEnd {
                        coming.append(payment("\(id)#next", date: repeated, source: .estimated, perUnit: dividend.amount))
                    }
                }
            }

            // A payment Yahoo already lists as still to come is the one that last
            // year's repeat stands for (the helper's day can be ahead of the
            // user's), so the nearest repeat goes rather than counting it twice.
            for listed in coming where listed.id.hasSuffix("#listed") {
                let nearest = coming.indices
                    .filter { coming[$0].dateSource == .estimated }
                    .min { abs(days(from: coming[$0].date, to: listed.date)) < abs(days(from: coming[$1].date, to: listed.date)) }
                if let nearest, abs(days(from: coming[nearest].date, to: listed.date)) <= matchingWindowDays {
                    coming.remove(at: nearest)
                }
            }

            // Yahoo's own upcoming ex-dividend date takes the place of the
            // nearest estimated date, within the matching window; an estimate
            // already on that very day is matched too, and takes Yahoo's pay date.
            let exDay = events.exDividendDate.map(day)
            let payDay = events.dividendPayDate.map(day)
            if let exDay, exDay > today, exDay <= nextEnd,
               !coming.contains(where: { $0.date == exDay && $0.dateSource == .yahooUpcoming }) {
                let pays = payDay.flatMap { $0 >= exDay ? $0 : nil }
                let nearest = coming.indices
                    .filter { coming[$0].dateSource == .estimated }
                    .min { abs(days(from: coming[$0].date, to: exDay)) < abs(days(from: coming[$1].date, to: exDay)) }
                if let nearest, abs(days(from: coming[nearest].date, to: exDay)) <= matchingWindowDays {
                    let old = coming[nearest]
                    coming[nearest] = payment(old.id, date: exDay, source: .yahooUpcoming, perUnit: old.perUnit, payDay: pays)
                } else {
                    coming.append(payment("\(holding.symbol)#yahoo", date: exDay, source: .yahooUpcoming,
                                          perUnit: nil, payDay: pays))
                }
            }

            let paying = !past.isEmpty
            let hasAmounts = (past + coming).contains { $0.ownAmount != nil }
            let converted = (past + coming).allSatisfy { $0.ownAmount == nil || $0.amount != nil }
            let isLeftOut = hasAmounts && !converted
            if isLeftOut { leftOut.append(LocalIncomeLeftOut(symbol: holding.symbol, currency: ownCurrency)) }
            func sum(_ payments: [LocalIncomePayment], _ value: (LocalIncomePayment) -> Double?) -> Double {
                payments.compactMap(value).reduce(0, +)
            }
            let next: (day: FolyncLedgerDay, kind: LocalIncomeHoldingRow.DateKind)? = {
                let candidates: [(FolyncLedgerDay, LocalIncomeHoldingRow.DateKind)] =
                    [exDay.map { ($0, .exDividend) }, payDay.map { ($0, .payment) }].compactMap { $0 }
                        .filter { $0.0 >= today }
                return candidates.min { $0.0 < $1.0 }.map { (day: $0.0, kind: $0.1) }
            }()
            rows.append(LocalIncomeHoldingRow(
                symbol: holding.symbol, state: paying ? .paying : .none,
                lastYear: isLeftOut ? nil : sum(past, \.amount),
                nextYear: isLeftOut ? nil : sum(coming, \.amount),
                ownLastYear: paying ? sum(past, \.ownAmount) : nil,
                ownNextYear: coming.contains { $0.ownAmount != nil } ? sum(coming, \.ownAmount) : nil,
                ownCurrency: ownCurrency, isLeftOut: isLeftOut, nextDate: next
            ))
            lastYear += past
            nextYear += coming
        }

        lastYear.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.holding < rhs.holding
        }
        nextYear.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.holding < rhs.holding
        }

        var months = chartMonths(around: today).map { LocalIncomeChartMonth(month: $0) }
        let index = Dictionary(months.enumerated().map { ($1.month, $0) }, uniquingKeysWith: { first, _ in first })
        for payment in lastYear {
            guard let amount = payment.amount, let position = index[payment.date.incomeMonth] else { continue }
            months[position].lastYear += amount
        }
        for payment in nextYear {
            guard let amount = payment.amount, let position = index[payment.date.incomeMonth] else { continue }
            months[position].nextYear += amount
        }

        let known = rows.filter { $0.state != .unknown && !$0.isLeftOut }
        let nothingKnown = known.isEmpty && rows.contains { $0.state == .unknown || $0.isLeftOut }
        rows.sort { lhs, rhs in
            func rank(_ row: LocalIncomeHoldingRow) -> Int {
                switch row.state {
                case .paying: row.isLeftOut ? 1 : 0
                case .none: 2
                case .unknown: 3
                }
            }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            let lhsNext = lhs.nextYear ?? 0, rhsNext = rhs.nextYear ?? 0
            if lhsNext != rhsNext { return lhsNext > rhsNext }
            return lhs.symbol < rhs.symbol
        }

        return LocalIncomeEstimate(
            currency: currency, today: today, lastYear: lastYear, nextYear: nextYear, holdings: rows,
            chart: LocalIncomeChart(months: months, currentMonth: today.incomeMonth, currency: currency),
            lastYearTotal: nothingKnown ? nil : known.compactMap(\.lastYear).reduce(0, +),
            nextYearTotal: nothingKnown ? nil : known.compactMap(\.nextYear).reduce(0, +),
            leftOut: leftOut, unknown: unknown
        )
    }
}
