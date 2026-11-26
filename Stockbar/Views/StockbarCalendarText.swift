import Foundation

/// What Calendar and "Next up" write: each row's words, the list's headings,
/// the footer, and the sentence each row and each grid day gives VoiceOver.
@MainActor
enum CalendarText {
    static let unknownFigure = IncomeText.unknownFigure
    static let estimatedDatesNote = "Estimated dates can move."
    static let folyncSource = "Dividends from Folync"
    static let estimateSource = "Estimated from Yahoo's record"
    static let earningsSource = "Earnings from Yahoo"
    static let pastEarningsNote = "Past lists dividends only."

    /// The notice near the top for a local or Trading 212 portfolio.
    static let estimateNotice = "Dividend dates and amounts for this portfolio are Stockbar's estimate from Yahoo's "
        + "record of each holding's payments, at the units you hold today, as on the Income page."

    /// "Dividends and earnings for your 9 holdings".
    static func subtitle(holdings: Int) -> String {
        switch holdings {
        case 0: "Dividends and earnings for your holdings"
        case 1: "Dividends and earnings for your 1 holding"
        default: "Dividends and earnings for your \(holdings) holdings"
        }
    }

    // MARK: A row's words

    /// "Ex-dividend", "Dividend", "Earnings".
    static func title(_ row: CalendarRow) -> String {
        switch row.kind {
        case .exDividend: "Ex-dividend"
        case .payment: "Dividend"
        case .earnings: "Earnings"
        }
    }

    /// The amount as the row writes it: "£58.40", "about £96.20", or "–".
    static func amount(_ row: CalendarRow) -> String {
        guard row.amount != nil else { return unknownFigure }
        let figure = IncomeText.amount(row.amount, currency: row.currency)
        return row.amountIsEstimate ? "about \(figure)" : figure
    }

    /// Whether the amount has a column of its own: a Folync payment.
    static func hasAmountColumn(_ row: CalendarRow) -> Bool {
        row.kind == .payment && !row.amountIsEstimate
    }

    /// What follows the title: ", pays 11 Dec, £58.40", ", about £96.20",
    /// ", expected between 27 Jan and 3 Feb". Empty when nothing follows.
    static func detail(_ row: CalendarRow, locale: Locale = .current) -> String {
        var parts: [String] = []
        switch row.kind {
        case .exDividend:
            if let pay = row.payDay { parts.append("pays \(IncomeText.dayMonth(pay, locale: locale))") }
            if row.amount != nil || !row.amountIsEstimate { parts.append(amount(row)) }
        case .payment:
            if row.amountIsEstimate, row.amount != nil { parts.append(amount(row)) }
        case .earnings:
            if let end = row.endDay {
                parts.append("expected between \(IncomeText.dayMonth(row.day, locale: locale)) "
                             + "and \(IncomeText.dayMonth(end, locale: locale))")
            }
        }
        if row.amountIsPartial, row.kind == .exDividend { parts.append("partial") }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    /// The amount column: a Folync payment's amount, or nil.
    static func amountColumn(_ row: CalendarRow) -> String? {
        guard hasAmountColumn(row) else { return nil }
        return amount(row) + (row.amountIsPartial ? " partial" : "")
    }

    /// "Tomorrow", "Tue 24 Nov"; the year once it is more than six months away.
    static func dayLabel(_ day: FolyncLedgerDay, today: FolyncLedgerDay, locale: Locale = .current) -> String {
        let far = day > today.adding(months: 6) || day < today.adding(months: -6)
        return IncomeText.dayLabel(day, today: today, locale: locale, withYear: far)
    }

    // MARK: The list

    /// "This week", "Next week", "December", or "January 2027" outside this year.
    static func groupTitle(_ key: CalendarGroup.Key, today: FolyncLedgerDay, locale: Locale = .current) -> String {
        switch key {
        case .thisWeek: return "This week"
        case .nextWeek: return "Next week"
        case .month(let month):
            if month.year == today.year {
                return month.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar,
                                                                       timeZone: IncomeFigures.utcCalendar.timeZone)
                    .month(.wide))
            }
            return IncomeText.monthLong(month, locale: locale)
        }
    }

    /// One line when the view and filter show nothing.
    static func emptyLine(mode: CalendarMode, filter: CalendarFilter) -> String {
        switch (mode, filter) {
        case (.upcoming, .earnings): "No earnings dates in the next 12 months."
        case (.upcoming, .dividends): "No dividend dates in the next 12 months."
        case (.upcoming, .all): "No dividend or earnings dates in the next 12 months."
        case (.past, _): "No dividends in the last 12 months."
        }
    }

    /// The grid's VoiceOver note for the month: how many days have events.
    static func monthSummary(_ weeks: [[CalendarGridDay]], month: IncomeMonth, locale: Locale = .current) -> String {
        let days = weeks.joined().filter { $0.isInMonth && !$0.rows.isEmpty }.count
        let name = IncomeText.monthLong(month, locale: locale)
        switch days {
        case 0: return "\(name): no events."
        case 1: return "\(name): events on 1 day."
        default: return "\(name): events on \(days) days."
        }
    }

    // MARK: Footer

    /// "Dividends from Folync · Earnings from Yahoo".
    static func sourceLine(_ source: CalendarDividendSource) -> String {
        let dividends = source == .folync ? folyncSource : estimateSource
        return "\(dividends) · \(earningsSource)"
    }

    /// "2 holdings have no earnings dates."
    static func earningsCoverageLine(_ coverage: CalendarEarningsCoverage) -> String? {
        switch coverage.total {
        case 0: nil
        case 1: "1 holding has no earnings dates."
        default: "\(coverage.total) holdings have no earnings dates."
        }
    }

    /// Why a Folync portfolio shows no earnings: Yahoo cannot be asked.
    static let earningsNotAllowedNotice = "Earnings dates come from Yahoo, and live market data is off, "
        + "so Calendar shows dividends only."

    // MARK: What VoiceOver reads

    /// "Tomorrow, ULVR, ex-dividend, pays 11 Dec, £58.40, declared."
    static func accessibilitySentence(_ row: CalendarRow, today: FolyncLedgerDay, locale: Locale = .current) -> String {
        var parts = [dayLabel(row.day, today: today, locale: locale), row.symbol, phrase(row, locale: locale)]
        if let pill = row.pill { parts.append(pill.title.lowercased()) }
        return parts.joined(separator: ", ") + "."
    }

    /// "Tuesday 24 November: HSBA dividend, £38.20, declared; NVDA earnings."
    static func daySentence(_ day: CalendarGridDay, locale: Locale = .current) -> String {
        let name = day.day.formattingDate.formatted(Date.FormatStyle(locale: locale, calendar: IncomeFigures.utcCalendar,
                                                                     timeZone: IncomeFigures.utcCalendar.timeZone)
            .weekday(.wide).day().month(.wide)).replacingOccurrences(of: ",", with: "")
        guard !day.rows.isEmpty else { return name }
        let events = day.rows.map { row -> String in
            var parts = ["\(row.symbol) \(phrase(row, locale: locale))"]
            if let pill = row.pill { parts.append(pill.title.lowercased()) }
            return parts.joined(separator: ", ")
        }
        return "\(name): " + events.joined(separator: "; ")
    }

    /// The row's words in lower case, with its amount: "dividend, £38.20".
    private static func phrase(_ row: CalendarRow, locale: Locale) -> String {
        // "–" is for the eye; VoiceOver hears "amount not known" instead.
        var words = title(row).lowercased() + detail(row, locale: locale).replacingOccurrences(of: ", \(unknownFigure)", with: "")
        if row.isDividend, row.amount == nil {
            words += ", amount not known"
        } else if let column = amountColumn(row) {
            words += ", \(column)"
        }
        return words
    }

    // MARK: Next up

    /// "ULVR goes ex-dividend", "HSBA pays £38.20", "NVDA reports earnings".
    static func nextUpPhrase(_ row: CalendarRow) -> String {
        switch row.kind {
        case .exDividend: return "\(row.symbol) goes ex-dividend"
        case .payment:
            return row.amount == nil ? "\(row.symbol) pays a dividend" : "\(row.symbol) pays \(amount(row))"
        case .earnings: return "\(row.symbol) reports earnings"
        }
    }

    /// "Tomorrow, ULVR goes ex-dividend, declared."
    static func nextUpSentence(_ row: CalendarRow, today: FolyncLedgerDay, locale: Locale = .current) -> String {
        var parts = [dayLabel(row.day, today: today, locale: locale), nextUpPhrase(row)]
        if let pill = row.pill { parts.append(pill.title.lowercased()) }
        return parts.joined(separator: ", ") + "."
    }
}
