import Foundation

/// What the Risk page writes. The figures come from `RiskMetricsService` unchanged;
/// this only formats them, with the precision the page has always used (two decimals
/// for a percentage, three for a ratio), and words the sentences around them.
enum RiskText {
    /// A figure that could not be worked out, as everywhere in the app.
    static let unknownFigure = "–"

    /// Falls smaller than this are not listed (`findDrawdownPeriods`' threshold).
    static let fallThreshold = 0.05

    // MARK: Figures

    /// "13.96%", or "–".
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return unknownFigure }
        return String(format: "%.2f%%", fraction * 100)
    }

    /// "1.084", or "–" when the ratio is not defined.
    static func ratio(_ ratio: Double?) -> String {
        guard let ratio, ratio.isFinite else { return unknownFigure }
        return String(format: "%.3f", ratio)
    }

    /// An amount in the display currency, as the holdings table writes it, or "–".
    static func amount(_ value: Double, currency: String) -> String {
        guard value.isFinite else { return unknownFigure }
        return HoldingsCurrencyFormatter.amount(value, currency: currency)
    }

    /// A fall from the peak as a negative percentage: "-11.31%". A fall that rounds
    /// to nothing is "0.00%", never "-0.00%"; an unknown one is "–".
    /// - Parameter fall: the size of the fall as a positive fraction, as the service gives it.
    static func fall(_ fall: Double) -> String {
        guard fall.isFinite else { return unknownFigure }
        let magnitude = String(format: "%.2f%%", abs(fall) * 100)
        guard fall > 0, HoldingsCurrencyFormatter.showsNonZeroDigit(magnitude) else { return magnitude }
        return "-" + magnitude
    }

    // MARK: The strip

    /// The page's long-standing reading of annual volatility, thresholds unchanged.
    /// Nil when volatility is not known.
    static func volatilityReading(_ volatility: Double) -> String? {
        guard volatility.isFinite else { return nil }
        if volatility > 0.30 { return "Very high" } else if volatility > 0.20 { return "High" } else if volatility > 0.15 { return "Moderate" } else if volatility > 0.10 { return "Low" } else { return "Very low" }
    }

    /// The page's long-standing reading of the Sharpe ratio, thresholds unchanged.
    /// Nil when the ratio is not defined.
    static func sharpeReading(_ sharpe: Double?) -> String? {
        guard let sharpe, sharpe.isFinite else { return nil }
        if sharpe > 3.0 { return "Exceptional" } else if sharpe > 2.0 { return "Very good" } else if sharpe > 1.0 { return "Good" } else if sharpe > 0.5 { return "Adequate" } else if sharpe > 0 { return "Below average" } else { return "Poor" }
    }

    /// "Low, over a year" under volatility: the reading, and that the figure is annual.
    static func volatilityDetail(_ volatility: Double) -> String? {
        volatilityReading(volatility).map { "\($0), over a year" }
    }

    /// "Good, return for the risk taken" under the Sharpe ratio.
    static func sharpeDetail(_ sharpe: Double?) -> String? {
        sharpeReading(sharpe).map { "\($0), return for the risk taken" }
    }

    /// A plain description, or why there is no ratio.
    static func sortinoDetail(_ sortino: Double?) -> String {
        sortino == nil ? "No falling days" : "Counts only the falls"
    }

    /// "55 days, peak to low" under the worst fall; "Never below its peak"
    /// when there was no fall; nil when the fall is not known. The service
    /// counts calendar days from the peak to the low when it has the dates,
    /// as the page always gives it, so these are not called trading days.
    static func worstFallDetail(fall: Double, duration: Int) -> String? {
        guard fall.isFinite else { return nil }
        guard fall > 0 else { return "Never below its peak" }
        return "\(duration) \(duration == 1 ? "day" : "days"), peak to low"
    }

    /// Under the chart: what the worst fall's length counts.
    static let recoveryNote = "The worst fall's length runs from the peak to the lowest point; the time to recover is not counted."

    /// One tile of the strip.
    struct Tile: Equatable {
        let title: String
        let value: String
        let detail: String?
        /// True for a fall, drawn in the loss colour beside its minus sign.
        let isLoss: Bool
    }

    /// The strip, in order: volatility, Sharpe, Sortino and the worst fall.
    static func tiles(_ metrics: RiskMetricsService.RiskMetrics) -> [Tile] {
        [
            Tile(title: "Volatility", value: percent(metrics.volatility),
                 detail: volatilityDetail(metrics.volatility), isLoss: false),
            Tile(title: "Sharpe ratio", value: ratio(metrics.sharpeRatio),
                 detail: sharpeDetail(metrics.sharpeRatio), isLoss: false),
            Tile(title: "Sortino ratio", value: ratio(metrics.sortinoRatio),
                 detail: sortinoDetail(metrics.sortinoRatio), isLoss: false),
            Tile(title: "Worst fall", value: fall(metrics.maxDrawdown),
                 detail: worstFallDetail(fall: metrics.maxDrawdown, duration: metrics.maxDrawdownDuration),
                 isLoss: fall(metrics.maxDrawdown).hasPrefix("-"))
        ]
    }

    // MARK: On a bad day

    /// One value-at-risk figure in words.
    struct BadDayFigure: Equatable {
        let lead: String
        let amount: String
        let caption: String

        var accessibility: String { RiskText.badDaySentence(lead: lead, amount: amount, caption: caption) }
    }

    /// The 95% figure, then the 99% figure, in the display currency.
    static func badDayFigures(_ metrics: RiskMetricsService.RiskMetrics, currency: String) -> [BadDayFigure] {
        [
            BadDayFigure(lead: oneDayIn20, amount: amount(metrics.valueAtRisk95, currency: currency), caption: valueAtRisk95),
            BadDayFigure(lead: oneDayIn100, amount: amount(metrics.valueAtRisk99, currency: currency), caption: valueAtRisk99)
        ]
    }

    static let oneDayIn20 = "On 1 day in 20, expect to lose more than"
    static let oneDayIn100 = "On 1 day in 100, more than"
    static let valueAtRisk95 = "95% value at risk"
    static let valueAtRisk99 = "99% value at risk"

    /// The sentence VoiceOver reads for one value-at-risk figure.
    static func badDaySentence(lead: String, amount: String, caption: String) -> String {
        "\(lead) \(amount). \(caption)."
    }

    // MARK: Falls of more than 5%

    static let fallsTitle = "Falls of more than 5%"
    static let noFalls = "No falls of more than 5% in this range."

    /// "Showing 5 of 7." when the list is cut short, otherwise nil.
    static func fallsShownNote(shown: Int, total: Int) -> String? {
        total > shown ? "Showing the \(shown) largest of \(total)." : nil
    }

    /// "26 Jan to 15 May"; each date carries its year when the two years differ
    /// or the fall did not end this year.
    static func dateRange(_ start: Date, _ end: Date, now: Date = Date(), locale: Locale = .current,
                          timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let endYear = calendar.component(.year, from: end)
        let withYear = calendar.component(.year, from: start) != endYear
            || endYear != calendar.component(.year, from: now)
        return "\(shortDate(start, withYear: withYear, locale: locale, timeZone: timeZone)) to "
            + shortDate(end, withYear: withYear, locale: locale, timeZone: timeZone)
    }

    /// "42 days, peak to low". The service counts calendar days for a fall.
    static func fallLength(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days"), peak to low"
    }

    /// What VoiceOver reads for one row of the list.
    static func fallAccessibility(_ period: RiskMetricsService.DrawdownPeriod, now: Date = Date(),
                                  locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Fell \(percent(abs(period.drawdownPercent))), \(dateRange(period.startDate, period.endDate, now: now, locale: locale, timeZone: timeZone)), "
            + fallLength(period.durationDays)
    }

    // MARK: How far below its peak

    /// "-11.31%, 15 May", the label beside the lowest point.
    static func lowestPointLabel(_ point: RiskMetricsService.DrawdownPoint, locale: Locale = .current,
                                 timeZone: TimeZone = .current) -> String {
        "\(fall(-point.drawdown)), \(shortDate(point.date, withYear: false, locale: locale, timeZone: timeZone))"
    }

    /// The chart's text for VoiceOver: the lowest point, its date and where it stands now.
    static func chartAccessibility(_ series: [RiskMetricsService.DrawdownPoint], locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String {
        guard let lowest = RiskMetricsService.lowestPoint(of: series), let latest = series.last else {
            return "No values in this range."
        }
        guard lowest.drawdown < 0 else { return "Never below its peak in this range." }
        let lowestText = "Lowest point \(percent(abs(lowest.drawdown))) below its peak, on "
            + longDate(lowest.date, locale: locale, timeZone: timeZone) + "."
        let nowText = latest.drawdown < 0
            ? "Now \(percent(abs(latest.drawdown))) below its peak."
            : "Now at its peak."
        return "\(lowestText) \(nowText)"
    }

    // MARK: Footnote

    /// "Based on 59 trading days, 6 Jan to 27 Mar 2026, from Stockbar's own stored history,
    /// not Folync's. Historical VaR, annualized from daily returns that leave out buys and
    /// sells. Risk-free rate 4.0% a year, used by the Sharpe and Sortino ratios."
    static func footnote(tradingDays: Int, first: Date?, last: Date?, isFolyncPortfolio: Bool,
                         riskFreeRate: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var span = ""
        if let first, let last {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let sameYear = calendar.component(.year, from: first) == calendar.component(.year, from: last)
            span = ", \(shortDate(first, withYear: !sameYear, locale: locale, timeZone: timeZone)) to "
                + shortDate(last, withYear: true, locale: locale, timeZone: timeZone)
        }
        let source = isFolyncPortfolio
            ? "from Stockbar's own stored history, not Folync's"
            : "from Stockbar's own stored history"
        return "Based on \(tradingDays) trading \(tradingDays == 1 ? "day" : "days")\(span), \(source). "
            + "Historical VaR, annualized from daily returns that leave out buys and sells. "
            + String(format: "Risk-free rate %.1f%% a year, used by the Sharpe and Sortino ratios.", riskFreeRate * 100)
    }

    /// The downside deviation, kept from the old grid as a small figure by the footnote.
    static let downsideDeviationTitle = "Downside deviation"
    static let downsideDeviationNote = "a year, from the falling days only"

    // MARK: Dates

    private static func shortDate(_ date: Date, withYear: Bool, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.abbreviated)
        if withYear { style = style.year() }
        return date.formatted(style)
    }

    private static func longDate(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).day().month(.wide).year())
    }
}
