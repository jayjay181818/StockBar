import Foundation

/// What the Income page writes: Folync's figures as given, formatted, and the
/// sentence each row and each month of the chart gives VoiceOver.
@MainActor
enum IncomeText {
    /// An unknown figure, as everywhere in the app.
    static let unknownFigure = "–"

    /// "2 payments with no amount yet", or nil.
    static func missingAmountsNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 payment with no amount yet" : "\(count) payments with no amount yet"
    }

    // MARK: Folync's figures, as given

    /// "8 of 9 holdings pay dividends".
    static func holdingsLine(_ response: FolyncDividendsResponse) -> String {
        let paying = response.summary.dividendPayingAssets
        let total = response.holdingCoverage.totalHoldings
        guard total > 0, paying <= total else {
            return paying == 1 ? "1 holding pays dividends" : "\(paying) holdings pay dividends"
        }
        if paying == total { return total == 1 ? "Your 1 holding pays dividends" : "All \(total) holdings pay dividends" }
        return "\(paying) of \(total) \(total == 1 ? "holding" : "holdings") \(paying == 1 ? "pays" : "pay") dividends"
    }

    /// Folync's projected annual income, or "–".
    static func projected(_ response: FolyncDividendsResponse) -> String {
        amount(response.summary.projectedAnnualIncome, currency: IncomeFigures.portfolioCurrency(response))
    }

    /// The lines beside the headline, each only when Folync gives the figure.
    static func figureLines(_ response: FolyncDividendsResponse) -> [IncomeFigureLine] {
        let summary = response.summary
        let currency = IncomeFigures.portfolioCurrency(response)
        let candidates: [(String, String?)] = [
            ("Declared", summary.declaredIncome.flatMap(finite).map { amount($0, currency: currency) }),
            ("Estimated from past payments", summary.estimatedIncome.flatMap(finite).map { amount($0, currency: currency) }),
            ("Yield, last 12 months, on today's value", summary.portfolioYieldTTMPct.flatMap(finite).map(percent)),
            ("Yield, last 12 months, on cost", summary.yieldOnCostTTMPct.flatMap(finite).map(percent)),
            ("Received in the last 12 months", summary.receivedIncome.flatMap(finite).map { amount($0, currency: currency) })
        ]
        return candidates.compactMap { title, value in value.map { IncomeFigureLine(title: title, value: $0) } }
    }

    private static func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    // MARK: Notices and captions

    /// The amber notice while Folync's saved copy is shown.
    static func savedNotice(savedAt: Date?, now: Date = Date(), locale: Locale = .current,
                            timeZone: TimeZone = .current) -> String {
        let lead = "Couldn't get new figures from Folync."
        guard let savedAt else { return "\(lead) Showing the income saved earlier." }
        let time = StockbarOverviewView.savedTime(savedAt, now: now, locale: locale, timeZone: timeZone)
        return "\(lead) Showing the income saved \(time)."
    }

    /// What Folync says when it marks its answer partial, with its reasons.
    static func partialNotice(_ response: FolyncDividendsResponse) -> String? {
        guard response.quality != .complete else { return nil }
        let lead = response.quality == .partial
            ? "Folync marks these figures partial"
            : "Folync marks these figures unavailable"
        let reasons = FolyncConnectionState.readable(reasons: response.reasonCodes)
        return reasons.isEmpty ? "\(lead)." : "\(lead): \(reasons)."
    }

    /// "Monthly sums in GBP from the payments listed. 1 payment with no amount yet."
    static func chartCaption(_ chart: IncomeChart) -> String {
        var parts = ["Monthly sums in \(chart.currency) from the payments listed, by pay date."]
        if let note = missingAmountsNote(chart.missingAmounts) { parts.append(note.prefix(1).uppercased() + note.dropFirst() + ".") }
        if chart.partialAmounts > 0 {
            parts.append(chart.partialAmounts == 1
                ? "1 amount is one Folync marks partial."
                : "\(chart.partialAmounts) amounts are ones Folync marks partial.")
        }
        return parts.joined(separator: " ")
    }

    /// "20 Nov 2025": where the query's pay dates start.
    static func queryStart(_ query: FolyncDividendsQuery?, locale: Locale = .current) -> String {
        guard let from = query?.from else { return "twelve months ago" }
        return from.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar,
                                                              timeZone: IncomeFigures.utcCalendar.timeZone)
            .day().month(.abbreviated).year())
    }

    // MARK: Formatting

    static func amount(_ value: Double?, currency: String) -> String {
        guard let value, value.isFinite else { return unknownFigure }
        return HoldingsCurrencyFormatter.amount(value, currency: currency)
    }

    /// A bar's label in whole units: "£148".
    static func wholeAmount(_ value: Double, currency: String) -> String {
        let rounded = HoldingsCurrencyFormatter.amount(value.rounded(), currency: currency)
        let parts = StockbarHeroFigure.split(rounded)
        return parts.whole + parts.fraction.drop { $0 == "." || $0.isNumber }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    /// "Today", "Tomorrow", or "Tue 24 Nov"; with the year when `withYear`.
    static func dayLabel(_ day: FolyncLedgerDay, today: FolyncLedgerDay, locale: Locale = .current,
                         withYear: Bool = false) -> String {
        if day == today { return "Today" }
        if day == today.next { return "Tomorrow" }
        return shortDay(day, locale: locale, withYear: withYear)
    }

    /// "Tue 24 Nov", "Tue 24 Nov 2026".
    static func shortDay(_ day: FolyncLedgerDay, locale: Locale = .current, withYear: Bool = false) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar, timeZone: IncomeFigures.utcCalendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if withYear { style = style.year() }
        return day.formattingDate.formatted(style).replacingOccurrences(of: ",", with: "")
    }

    /// "11 Dec".
    static func dayMonth(_ day: FolyncLedgerDay, locale: Locale = .current) -> String {
        day.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar, timeZone: IncomeFigures.utcCalendar.timeZone)
            .day().month(.abbreviated))
    }

    /// "Nov".
    static func monthShort(_ month: IncomeMonth, locale: Locale = .current) -> String {
        month.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar, timeZone: IncomeFigures.utcCalendar.timeZone)
            .month(.abbreviated))
    }

    /// "November 2026".
    static func monthLong(_ month: IncomeMonth, locale: Locale = .current) -> String {
        month.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar, timeZone: IncomeFigures.utcCalendar.timeZone)
            .month(.wide).year())
    }

    /// "Jun 2026 to May 2027": the chart's months.
    static func monthsSpan(around today: FolyncLedgerDay, locale: Locale = .current) -> String {
        let months = IncomeFigures.chartMonths(around: today)
        guard let first = months.first, let last = months.last else { return "" }
        let style = Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar, timeZone: IncomeFigures.utcCalendar.timeZone)
            .month(.abbreviated).year()
        return "\(first.formattingDate.formatted(style)) to \(last.formattingDate.formatted(style))"
    }

    // MARK: What VoiceOver reads

    /// One sentence for a month of the chart: "November 2026: £135.00 received
    /// and £38.20 declared, still to come."
    static func accessibilitySentence(_ month: IncomeChartMonth, currency: String, locale: Locale = .current) -> String {
        var received: [String] = []
        var coming: [String] = []
        for part in IncomePart.allCases where month.amount(part) > 0 {
            let figure = amount(month.amount(part), currency: currency)
            switch part {
            case .received: received.append("\(figure) received")
            case .declared: coming.append("\(figure) declared")
            case .estimated: coming.append("\(figure) estimated")
            case .toCome: coming.append("\(figure) not marked declared or estimated")
            }
        }
        var clauses: [String] = []
        if !received.isEmpty { clauses.append(received.joined()) }
        if !coming.isEmpty { clauses.append(joinedList(coming) + ", still to come") }
        var sentence = "\(monthLong(month.month, locale: locale)): "
        sentence += clauses.isEmpty ? (month.hasPayments ? "no amounts known" : "no payments listed") : joinedList(clauses)
        if let note = missingAmountsNote(month.missingAmounts) { sentence += "; \(note)" }
        return sentence + "."
    }

    /// "Tomorrow, ULVR, ex-dividend, pays 11 Dec, £58.40, declared."
    static func accessibilitySentence(_ row: IncomeUpcomingRow, currency: String, today: FolyncLedgerDay,
                                      locale: Locale = .current) -> String {
        var parts = [dayLabel(row.date, today: today, locale: locale), row.holding]
        switch row.kind {
        case .exDividend(let payDay):
            parts.append("ex-dividend, pays \(dayMonth(payDay, locale: locale))")
        case .payment:
            parts.append("dividend")
        }
        parts.append(row.amount == nil ? "amount not known yet" : amount(row.amount, currency: currency)
                     + (row.amountIsPartial ? ", partial" : ""))
        if let pill = row.pill { parts.append(pill.lowercased()) }
        return parts.joined(separator: ", ") + "."
    }

    /// "Fri 13 Nov 2026, SHEL, received £41.02, US$54.00."
    static func accessibilitySentence(_ row: IncomeHistoryRow, currency: String, locale: Locale = .current) -> String {
        var sentence = "\(shortDay(row.date, locale: locale, withYear: true)), \(row.holding), received "
        sentence += row.amount == nil ? "an amount not known" : amount(row.amount, currency: currency)
        if row.amountIsPartial { sentence += ", partial" }
        if let own = row.ownAmount { sentence += ", \(amount(own.value, currency: own.currency))" }
        return sentence + "."
    }

    /// "ULVR: £120.00 received and £58.40 to come; next payment Fri 11 Dec, £58.40."
    static func accessibilitySentence(_ row: IncomeHoldingRow, currency: String, locale: Locale = .current) -> String {
        var sentence = "\(row.holding): \(amount(row.received, currency: currency)) received and "
            + "\(amount(row.toCome, currency: currency)) to come"
        if let note = missingAmountsNote(row.missingAmounts) { sentence += ", \(note)" }
        if let next = row.nextPayment {
            sentence += "; next payment \(shortDay(next.date, locale: locale)), \(amount(next.amount, currency: currency))"
        } else {
            sentence += "; no payment listed still to come"
        }
        return sentence + "."
    }

    private static func joinedList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}
