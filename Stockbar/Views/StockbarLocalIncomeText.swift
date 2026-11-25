import Foundation

/// What the Income page writes for a local or Trading 212 portfolio. Every
/// figure is an estimate, and each label says so.
@MainActor
enum LocalIncomeText {
    static let unknownFigure = IncomeText.unknownFigure

    /// The notice at the top of the page.
    static let estimateNotice = "These figures are an estimate from Yahoo's record of each holding's payments "
        + "over the last year, at the units you hold today. They are not a record of what was paid to you."

    static let subtitle = "An estimate from Yahoo's record of your holdings' dividends."
    static let headlineTitle = "Estimated for the next 12 months"
    static let lastYearTitle = "Last 12 months, at today's units (estimate)"
    static let nextYearTitle = "Next 12 months (estimate)"
    static let estimatePill = "Estimate"
    static let yahooDatePill = "Yahoo's date, amount estimated"

    /// The chart's two parts.
    static let chartLastYear = "Last 12 months, at today's units"
    static let chartNextYear = "Next 12 months, estimate"

    /// "3 of 5 holdings paid dividends in the last year, by Yahoo's record".
    static func holdingsLine(_ estimate: LocalIncomeEstimate) -> String {
        let total = estimate.holdings.count
        let paying = estimate.holdings.filter { $0.state == .paying }.count
        guard total > 0 else { return subtitle }
        return "\(paying) of \(total) \(total == 1 ? "holding" : "holdings") paid dividends in the last year, by Yahoo's record"
    }

    /// The figure lines beside the headline.
    static func figureLines(_ estimate: LocalIncomeEstimate) -> [IncomeFigureLine] {
        [IncomeFigureLine(title: lastYearTitle, value: IncomeText.amount(estimate.lastYearTotal, currency: estimate.currency))]
    }

    // MARK: Notices

    /// "The totals leave out FAKEEU (EUR): no exchange rate to GBP is loaded."
    static func leftOutNotice(_ estimate: LocalIncomeEstimate) -> String? {
        guard !estimate.leftOut.isEmpty else { return nil }
        let withRate = estimate.leftOut.filter { !$0.currency.isEmpty }
        let withoutCurrency = estimate.leftOut.filter { $0.currency.isEmpty }
        var reasons: [String] = []
        if !withRate.isEmpty {
            let names = withRate.map { "\($0.symbol) (\($0.currency))" }
            let target = estimate.currency.isEmpty ? "" : " to \(estimate.currency)"
            reasons.append("\(joinedList(names)): no exchange rate\(target) is loaded")
        }
        if !withoutCurrency.isEmpty {
            reasons.append("\(joinedList(withoutCurrency.map(\.symbol))): Yahoo names no currency")
        }
        return "The totals leave out " + reasons.joined(separator: "; ") + ". Their own figures are shown on their rows."
    }

    /// "Yahoo had no answer for FAKENA, so it shows as –."
    static func unknownNotice(_ estimate: LocalIncomeEstimate) -> String? {
        guard !estimate.unknown.isEmpty else { return nil }
        let names = joinedList(estimate.unknown)
        let verb = estimate.unknown.count == 1 ? "it shows" : "they show"
        return "Yahoo had no answer for \(names), so \(verb) as \(unknownFigure) and \(estimate.unknown.count == 1 ? "is" : "are") not in the totals."
    }

    /// While Yahoo is limiting requests.
    static func rateLimitNotice(until: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
        return "Yahoo is limiting requests, so Stockbar won't ask it again until \(until.formatted(style))."
    }

    /// When some holdings are shown from an older saved copy.
    static func staleNotice(count: Int, oldest: Date?, now: Date = Date(), locale: Locale = .current,
                            timeZone: TimeZone = .current) -> String? {
        guard count > 0 else { return nil }
        let holdings = count == 1 ? "1 holding" : "\(count) holdings"
        guard let oldest else { return "Couldn't get new figures from Yahoo for \(holdings). Showing the copy saved earlier." }
        let time = StockbarOverviewView.savedTime(oldest, now: now, locale: locale, timeZone: timeZone)
        return "Couldn't get new figures from Yahoo for \(holdings). Showing the copy saved \(time)."
    }

    /// When Yahoo did not answer and nothing is saved for some holdings.
    static func failedNotice(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "Couldn't reach Yahoo for 1 holding, and nothing is saved for it yet."
            : "Couldn't reach Yahoo for \(count) holdings, and nothing is saved for them yet."
    }

    // MARK: Captions

    static func chartCaption(_ chart: LocalIncomeChart) -> String {
        let inCurrency = chart.currency.isEmpty ? "" : " in \(chart.currency)"
        return "Monthly sums\(inCurrency) by ex-dividend date: Yahoo's payments of the last 12 months at today's units, "
            + "then the same payments a year on as the estimate."
    }

    static let lastYearCaption = "Each payment Yahoo lists for the last 12 months, times the units you hold today, "
        + "newest first. Dates are Yahoo's ex-dividend dates. Stockbar doesn't know what you held on each date, so "
        + "this is not what you received."

    static let nextYearCaption = "Last year's payments repeated a year on, at today's units. Where Yahoo gives a "
        + "real upcoming ex-dividend date, that date is shown instead."

    static func byHoldingCaption(currency: String) -> String {
        let inCurrency = currency.isEmpty ? "" : ", in \(currency)"
        return "Each holding's payments by Yahoo's record, at today's units\(inCurrency). "
            + "\(unknownFigure) means Yahoo had no answer."
    }

    // MARK: Figures

    /// A payment's amount: in the page's currency, or its own when not converted.
    static func amount(_ payment: LocalIncomePayment, currency: String) -> String {
        if let amount = payment.amount { return IncomeText.amount(amount, currency: currency) }
        return IncomeText.amount(payment.ownAmount, currency: payment.ownCurrency)
    }

    /// A holding's sum: in the page's currency, its own when left out, "None"
    /// when it paid nothing, "–" when unknown.
    static func holdingFigure(_ row: LocalIncomeHoldingRow, nextYear: Bool, currency: String) -> String {
        switch row.state {
        case .unknown: return unknownFigure
        case .none where (nextYear ? row.ownNextYear : row.ownLastYear) == nil: return "None"
        case .none, .paying:
            if row.isLeftOut {
                return IncomeText.amount(nextYear ? row.ownNextYear : row.ownLastYear, currency: row.ownCurrency)
            }
            return IncomeText.amount(nextYear ? row.nextYear : row.lastYear, currency: currency)
        }
    }

    static func nextDate(_ row: LocalIncomeHoldingRow, today: FolyncLedgerDay, locale: Locale = .current) -> String {
        guard let next = row.nextDate else { return unknownFigure }
        let day = IncomeText.dayLabel(next.day, today: today, locale: locale)
        return next.kind == .exDividend ? "Ex-dividend \(day)" : "Pays \(day)"
    }

    static func pill(_ payment: LocalIncomePayment) -> String {
        payment.dateSource == .yahooUpcoming ? yahooDatePill : estimatePill
    }

    // MARK: What VoiceOver reads

    /// "November 2026: £12.40 in the last 12 months at today's units and £8.10 estimated for the next 12 months."
    static func accessibilitySentence(_ month: LocalIncomeChartMonth, currency: String, locale: Locale = .current) -> String {
        var clauses: [String] = []
        if month.lastYear > 0 {
            clauses.append("\(IncomeText.amount(month.lastYear, currency: currency)) in the last 12 months at today's units")
        }
        if month.nextYear > 0 {
            clauses.append("\(IncomeText.amount(month.nextYear, currency: currency)) estimated for the next 12 months")
        }
        let body = clauses.isEmpty ? "no payments" : joinedList(clauses)
        return "\(IncomeText.monthLong(month.month, locale: locale)): \(body)."
    }

    /// "Fri 13 Nov 2026, FAKEUS, ex-dividend, £5.20, estimate at today's units."
    static func accessibilitySentence(lastYear payment: LocalIncomePayment, currency: String,
                                      locale: Locale = .current) -> String {
        var parts = [IncomeText.shortDay(payment.date, locale: locale, withYear: true), payment.holding, "ex-dividend",
                     amount(payment, currency: currency)]
        if payment.amount == nil, payment.ownAmount != nil { parts.append("not in the totals") }
        parts.append("estimate at today's units")
        return parts.joined(separator: ", ") + "."
    }

    /// "Tue 1 Dec, FAKEUS, ex-dividend, pays 15 Dec, £5.20, Yahoo's date, amount estimated."
    static func accessibilitySentence(nextYear payment: LocalIncomePayment, currency: String, today: FolyncLedgerDay,
                                      locale: Locale = .current) -> String {
        var parts = [IncomeText.upcomingDayLabel(payment.date, today: today, locale: locale), payment.holding, "ex-dividend"]
        if let pays = payment.payDay { parts.append("pays \(IncomeText.dayMonth(pays, locale: locale))") }
        parts.append(payment.ownAmount == nil ? "amount not known" : amount(payment, currency: currency))
        if payment.amount == nil, payment.ownAmount != nil { parts.append("not in the totals") }
        parts.append(payment.dateSource == .yahooUpcoming ? yahooDatePill : estimatePill.lowercased())
        return parts.joined(separator: ", ") + "."
    }

    /// "FAKEUS: £20.80 in the last 12 months and £20.80 estimated for the next 12 months; next date Ex-dividend Tue 1 Dec."
    static func accessibilitySentence(_ row: LocalIncomeHoldingRow, currency: String, today: FolyncLedgerDay,
                                      locale: Locale = .current) -> String {
        switch row.state {
        case .unknown:
            return "\(row.symbol): not known, Yahoo had no answer."
        case .none, .paying:
            var sentence = "\(row.symbol): \(holdingFigure(row, nextYear: false, currency: currency)) in the last 12 months and "
                + "\(holdingFigure(row, nextYear: true, currency: currency)) estimated for the next 12 months"
            if row.isLeftOut { sentence += ", not in the totals" }
            if row.nextDate != nil { sentence += "; next date \(nextDate(row, today: today, locale: locale))" }
            return sentence + "."
        }
    }

    private static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
