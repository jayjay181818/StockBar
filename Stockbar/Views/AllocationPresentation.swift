//
//  AllocationPresentation.swift
//  Stockbar
//
//  What the Allocation page shows, worked out from figures it already has:
//  the three donut views, folding small slices into "Other", stable slice
//  colours, and the correlation grid's cells. Grouping is a plain sum of
//  values the page already holds; no figure is recalculated here.
//

import Foundation

/// The donut's three views.
enum AllocationGrouping: String, CaseIterable, Hashable, Sendable {
    case sector = "Sector"
    case holding = "Holding"
    case currency = "Currency"

    /// What one member of an "Other" group is called.
    func memberNoun(_ count: Int) -> String {
        switch self {
        case .sector: return count == 1 ? "sector" : "sectors"
        case .holding: return count == 1 ? "holding" : "holdings"
        case .currency: return count == 1 ? "currency" : "currencies"
        }
    }
}

/// One valued holding: its value in the display currency and the currency it is priced in.
struct AllocationHolding: Equatable, Sendable {
    let symbol: String
    let value: Double
    let currency: String
}

/// The cash beside the holdings, in the display currency. It comes from the source
/// that gives Holdings its total (`DataModel.holdingsWeightBasis()`), never worked out here.
enum AllocationCash: Equatable, Sendable {
    /// Not known, left out (see `AllocationCashOmission`), or zero as displayed: no Cash
    /// row, and the page is about the holdings alone.
    case none
    /// Above zero: a row and a slice of its own, and every share is of holdings plus cash.
    case held(Double)
    /// Below zero (borrowing): no slice, shares stay of the holdings, and a line says so.
    case borrowing(Double)

    /// Sorts a known figure into one of the three; nil or a figure that is not finite is `.none`.
    init(_ amount: Double?) {
        guard let amount, amount.isFinite, amount != 0 else { self = .none; return }
        self = amount > 0 ? .held(amount) : .borrowing(amount)
    }

    /// The figure that a Cash slice adds to the total; zero unless cash is held.
    var heldAmount: Double {
        if case .held(let amount) = self { return amount }
        return 0
    }
}

/// Why the page leaves out cash that its source does give, so its percentages are of the
/// holdings alone. The page says so rather than show a Cash row that would not match
/// Holdings' weights.
enum AllocationCashOmission: Equatable, Sendable {
    /// Some holdings have no value yet, so cash would take too large a share.
    case partialCoverage
    /// No loaded exchange rate for the cash, for the total it belongs to, or for a holding's
    /// value into the total's currency, so the check against the total cannot be made.
    case noExchangeRate
    /// Folync gives the holdings but no total value.
    case folyncWithoutTotal
    /// Holdings kept outside the Trading 212 account, whose value Holdings' weights are of.
    case holdingsOutsideBrokerAccount
    /// The holdings and cash do not add up to the source's total.
    case totalDiffers
}

extension AllocationCashOmission {
    /// The reason for a Holdings total that does not cover the holdings it weighs.
    init(_ mismatch: HoldingsWeightBasis.Mismatch) {
        switch mismatch {
        case .folyncWithoutTotal: self = .folyncWithoutTotal
        case .holdingsOutsideBrokerAccount: self = .holdingsOutsideBrokerAccount
        }
    }
}

/// What the page's percentages are of, for the notes that give one.
enum AllocationShareBasis: Equatable, Sendable {
    /// The holdings, and there is no cash beside them to speak of.
    case portfolio
    /// The holdings and the cash in the Cash row.
    case portfolioWithCash
    /// The holdings alone, although there is cash: below zero, or left out.
    case holdings

    init(cash: AllocationCash, omission: AllocationCashOmission?) {
        switch cash {
        case .held: self = .portfolioWithCash
        case .borrowing: self = .holdings
        case .none: self = omission == nil ? .portfolio : .holdings
        }
    }
}

/// One slice of the donut and its row.
struct AllocationGroup: Equatable, Identifiable, Sendable {
    /// Stable identity: the sector's raw value, the symbol or the currency code; "Other" for the
    /// fold and "Cash" for cash, both with a leading NUL so no ticker or code can take them.
    let key: String
    let label: String
    let value: Double
    /// Percent of the valued portfolio.
    let share: Double
    /// Today's change in percent; nil where unknown or not shown (holdings, currencies, "Other").
    let dayChangePercent: Double?
    /// Groups folded into "Other"; 0 for an ordinary group.
    let foldedCount: Int

    var id: String { key }
    var isOther: Bool { foldedCount > 0 }
    var isCash: Bool { key == Self.cashKey }

    static let otherKey = "\u{0}Other"
    static let cashKey = "\u{0}Cash"
}

enum AllocationPresentation {
    /// The holdings' groups never make more slices than this; a Cash slice comes on top.
    static let maximumSlices = 8

    // MARK: Groups

    /// The sector view: the service's allocations, largest first.
    static func sectorGroups(_ allocations: [SectorAnalysisService.SectorAllocation],
                             showsDayChange: Bool) -> [AllocationGroup] {
        allocations
            .map {
                AllocationGroup(key: $0.sector.rawValue, label: sectorLabel($0.sector), value: $0.totalValue,
                                share: $0.percentageOfPortfolio,
                                dayChangePercent: showsDayChange ? $0.dayChangePercent : nil, foldedCount: 0)
            }
            .sorted(by: largestFirst)
    }

    /// The holding view: each holding's value and share as the sector service worked them out.
    static func holdingGroups(_ allocations: [SectorAnalysisService.SectorAllocation]) -> [AllocationGroup] {
        allocations
            .flatMap(\.positions)
            .map {
                AllocationGroup(key: $0.symbol, label: $0.symbol, value: $0.value,
                                share: $0.percentageOfPortfolio, dayChangePercent: nil, foldedCount: 0)
            }
            .sorted(by: largestFirst)
    }

    /// The currency view: holdings' display-currency values summed by the currency each is
    /// priced in, pence counted as pounds. A holding with no usable value or currency is left out.
    static func currencyGroups(_ holdings: [AllocationHolding]) -> [AllocationGroup] {
        var totals: [String: Double] = [:]
        for holding in holdings {
            guard holding.value.isFinite, holding.value > 0,
                  let currency = SymbolMetadata.normalizeCurrency(holding.currency) else { continue }
            totals[currency, default: 0] += holding.value
        }
        let total = totals.values.reduce(0, +)
        guard total > 0, total.isFinite else { return [] }
        return totals
            .map {
                AllocationGroup(key: $0.key, label: $0.key, value: $0.value, share: $0.value / total * 100,
                                dayChangePercent: nil, foldedCount: 0)
            }
            .sorted(by: largestFirst)
    }

    /// Past `maximumSlices`, the smallest groups become one "Other" group. Its value and share
    /// are the plain sums of what it holds; its day change is unknown.
    static func folded(_ groups: [AllocationGroup]) -> [AllocationGroup] {
        guard groups.count > maximumSlices else { return groups }
        let kept = Array(groups.prefix(maximumSlices - 1))
        let rest = groups.dropFirst(maximumSlices - 1)
        let other = AllocationGroup(key: AllocationGroup.otherKey, label: "Other",
                                    value: rest.reduce(0) { $0 + $1.value },
                                    share: rest.reduce(0) { $0 + $1.share },
                                    dayChangePercent: nil, foldedCount: rest.count)
        return kept + [other]
    }

    /// What the donut and its list show: the groups folded as `folded(_:)` does, then, when
    /// cash is held, every share taken again as a share of the total and a Cash row last.
    /// That total is `sourceTotal` when given (Holdings' own, which the holdings and cash
    /// add up to), otherwise holdings plus cash. Cash is never folded into "Other". Without
    /// held cash the groups are as given.
    static func displayed(_ groups: [AllocationGroup], cash: AllocationCash,
                          sourceTotal: Double? = nil) -> [AllocationGroup] {
        guard case .held(let amount) = cash else { return folded(groups) }
        let total = shareTotal(holdingsTotal: groups.reduce(0) { $0 + $1.value }, cash: cash, sourceTotal: sourceTotal)
        guard total.isFinite, total > 0 else { return folded(groups) }
        let rescaled = groups.map {
            AllocationGroup(key: $0.key, label: $0.label, value: $0.value, share: $0.value / total * 100,
                            dayChangePercent: $0.dayChangePercent, foldedCount: $0.foldedCount)
        }
        let cashRow = AllocationGroup(key: AllocationGroup.cashKey, label: "Cash", value: amount,
                                      share: amount / total * 100, dayChangePercent: nil, foldedCount: 0)
        return folded(rescaled) + [cashRow]
    }

    /// Whether the page has an allocation to show: a holding to value (even one without a
    /// price yet, which the card then explains), or cash on its own.
    static func hasContent(eligibleHoldings: Int, cash: AllocationCash) -> Bool {
        eligibleHoldings > 0 || cash.heldAmount > 0
    }

    /// The total every share on the page is of: the holdings' values, or with held cash
    /// Holdings' own total (`sourceTotal`) when given, else holdings plus cash.
    static func shareTotal(holdingsTotal: Double, cash: AllocationCash, sourceTotal: Double? = nil) -> Double {
        guard cash.heldAmount > 0 else { return holdingsTotal }
        if let sourceTotal, sourceTotal.isFinite, sourceTotal > 0 { return sourceTotal }
        return holdingsTotal + cash.heldAmount
    }

    /// The Unclassified sector's share of the same total as the rows, so the note under the
    /// chart gives the figure its row shows. Nil when no holding is unclassified.
    static func unclassifiedShare(_ allocations: [SectorAnalysisService.SectorAllocation],
                                  cash: AllocationCash, sourceTotal: Double? = nil) -> Double? {
        let holdingsTotal = allocations.reduce(0) { $0 + $1.totalValue }
        let unclassified = allocations.filter { $0.sector == .unknown }.reduce(0) { $0 + $1.totalValue }
        let total = shareTotal(holdingsTotal: holdingsTotal, cash: cash, sourceTotal: sourceTotal)
        guard unclassified > 0, total.isFinite, total > 0 else { return nil }
        return unclassified / total * 100
    }

    private static func largestFirst(_ lhs: AllocationGroup, _ rhs: AllocationGroup) -> Bool {
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
    }

    static func sectorLabel(_ sector: SectorAnalysisService.Sector) -> String {
        sector == .unknown ? "Unclassified" : sector.displayName
    }

    // MARK: Text

    /// A row's name: "Other (3 holdings)" for the fold.
    static func rowLabel(_ group: AllocationGroup, grouping: AllocationGrouping) -> String {
        group.isOther ? "Other (\(group.foldedCount) \(grouping.memberNoun(group.foldedCount)))" : group.label
    }

    static func shareText(_ share: Double) -> String {
        String(format: "%.1f%%", share)
    }

    /// What this page's day-change cells show when there is no figure.
    static let unknownDayChangeText = "—"

    /// The day-change cell: signed percent, or a dash when unknown. Cash has no day's
    /// change, so its cell is the same dash as every other unknown day change here.
    static func dayChangeText(_ group: AllocationGroup) -> String {
        if group.isCash { return unknownDayChangeText }
        return group.dayChangePercent.map(AttributionFormat.signedPercent) ?? unknownDayChangeText
    }

    /// The row as VoiceOver reads it. Cash has no day's change to speak of, so its row
    /// never says "day change unavailable".
    static func spokenRow(_ group: AllocationGroup, grouping: AllocationGrouping, currency: String) -> String {
        var parts = [rowLabel(group, grouping: grouping),
                     HoldingsCurrencyFormatter.amount(group.value, currency: currency),
                     String(format: "%.1f percent", group.share)]
        if grouping == .sector, !group.isCash {
            parts.append(group.dayChangePercent
                .map { "day change \(AttributionFormat.spokenPercent($0))" } ?? "day change unavailable")
        }
        return parts.joined(separator: ", ")
    }

    /// The Cash row's tooltip: what the figure is and why it has no sector or day's change.
    static func cashTooltip(_ group: AllocationGroup, currency: String) -> String {
        "Cash, \(HoldingsCurrencyFormatter.amount(group.value, currency: currency)), \(shareText(group.share)). "
            + "Cash has no sector and no day's change."
    }

    /// The donut's centre: the total and how many holdings make it up, "and cash" when cash
    /// is in it, or "Cash only" when nothing else is.
    static func centreText(total: Double, holdingCount: Int, currency: String,
                           includesCash: Bool = false) -> (total: String, count: String) {
        let holdings = "\(holdingCount) \(holdingCount == 1 ? "holding" : "holdings")"
        let count = includesCash ? (holdingCount == 0 ? "Cash only" : holdings + " and cash") : holdings
        return (HoldingsCurrencyFormatter.compactAmount(total, currency: currency), count)
    }

    /// The warning when not every holding could be valued. With cash left out for that
    /// reason, it says so.
    static func coverageNotice(covered: Int, eligible: Int, leavesOutCash: Bool) -> String {
        let start = "Based on \(covered) of \(eligible) holdings. The rest have no price or exchange rate yet, "
        return leavesOutCash
            ? start + "so the percentages are of the valued holdings only, without cash."
            : start + "so the percentages are of the valued part only."
    }

    /// The line under the chart when cash is left out for any reason but partial coverage,
    /// which the coverage notice words. Nil when nothing is left out.
    static func omissionLine(_ omission: AllocationCashOmission?) -> String? {
        let tail = "these percentages are of the holdings alone, without cash."
        switch omission {
        case nil, .partialCoverage?:
            return nil
        case .noExchangeRate?:
            return "There is no exchange rate for the cash yet, so " + tail
        case .folyncWithoutTotal?:
            return "Folync gives no total value for this portfolio, so " + tail
        case .holdingsOutsideBrokerAccount?:
            return "Holdings' weights are of the Trading 212 account's value, which leaves out the holdings "
                + "kept outside it. So " + tail
        case .totalDiffers?:
            return "The holdings and cash do not add up to the portfolio's total value, so " + tail
        }
    }

    /// The line under the chart when cash is below zero: there is no slice for it, so the
    /// shares are of the holdings alone. Nil in every other case.
    static func borrowingLine(_ cash: AllocationCash, currency: String) -> String? {
        guard case .borrowing(let amount) = cash else { return nil }
        return "Cash is below zero (\(HoldingsCurrencyFormatter.amount(amount, currency: currency))), so it has no slice "
            + "and the percentages are of the holdings alone."
    }

    /// The note under the Sector view: the Unclassified row's share of the same total as the
    /// rows. With cash in that total, the note says so; with cash below zero or left out,
    /// the share is of the holdings, and the note says that instead.
    static func unclassifiedNote(share: Double, basis: AllocationShareBasis) -> String {
        let figure = String(format: "%.1f", share)
        switch basis {
        case .portfolio:
            return "\(figure)% of the portfolio is in holdings with no known sector (shown as Unclassified)."
        case .portfolioWithCash:
            return "\(figure)% of the portfolio, cash included, is in holdings with no known sector (shown as Unclassified)."
        case .holdings:
            return "\(figure)% of the holdings' value is in holdings with no known sector (shown as Unclassified)."
        }
    }

    /// Diversification's note on holdings with no known sector. The score is of the holdings
    /// alone, so whenever there is cash the share is said to be of the holdings.
    static func diversificationUnclassifiedNote(share: Double, basis: AllocationShareBasis) -> String {
        let figure = String(format: "%.1f", share)
        return basis == .portfolio
            ? "\(figure)% of the portfolio has no known sector and is excluded from this score."
            : "\(figure)% of the holdings' value has no known sector and is excluded from this score."
    }

    /// Diversification when most of it is unclassified.
    static func diversificationUnavailableNote(share: Double, basis: AllocationShareBasis) -> String {
        let figure = String(format: "%.0f", share)
        return basis == .portfolio
            ? "Diversification unavailable: \(figure)% of the portfolio has no known sector."
            : "Diversification unavailable: \(figure)% of the holdings' value has no known sector."
    }

    /// Said under Diversification's heading when the donut has a Cash slice.
    static let holdingsOnlyCaption =
        "Holdings only: cash is left out of this score and of the correlation below, as it does not move with anything."

    // MARK: Diversification

    static func scoreText(_ score: Double) -> String {
        String(format: "%.1f of 100", score)
    }

    // MARK: Correlation grid

    /// The grid shows at most this many holdings.
    static let maximumGridHoldings = 12

    /// The grid's holdings: the largest by value first, at most `maximumGridHoldings`.
    /// A holding with no known value goes after those with one.
    static func gridSymbols(_ symbols: [String], values: [String: Double]) -> [String] {
        let ordered = symbols.sorted { lhs, rhs in
            let left = values[lhs].flatMap { $0.isFinite ? $0 : nil }
            let right = values[rhs].flatMap { $0.isFinite ? $0 : nil }
            switch (left, right) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs < rhs
            }
        }
        return Array(ordered.prefix(maximumGridHoldings))
    }

    /// Said under the grid when it leaves holdings out.
    static func gridNote(totalHoldings: Int) -> String? {
        totalHoldings > maximumGridHoldings
            ? "The \(maximumGridHoldings) largest of \(totalHoldings) holdings."
            : nil
    }

    /// A cell's figure to two decimals without the leading zero (".73", "-.12", "1.00");
    /// a dash where the correlation is undefined.
    static func cellText(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        var text = String(format: "%.2f", value)
        if text == "-0.00" { text = "0.00" }
        if text.hasPrefix("0.") { text.removeFirst() }
        if text.hasPrefix("-0.") { text = "-" + text.dropFirst(2) }
        return text
    }

    /// "0.73", never "-0.00".
    static func pairFigure(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text == "-0.00" ? "0.00" : text
    }

    /// A cell's tooltip and VoiceOver label: "VUSA and NVDA, 0.73".
    static func cellLabel(_ row: String, _ column: String, value: Double?) -> String {
        guard let value, value.isFinite else { return "\(row) and \(column), no figure" }
        return "\(row) and \(column), \(pairFigure(value))"
    }

    static func shade(_ value: Double?) -> CorrelationShade {
        guard let value, value.isFinite, value != 0 else { return .none }
        let strength = min(1, abs(value))
        return value > 0 ? .positive(strength) : .negative(strength)
    }

    /// "Most alike: VUSA and MSFT, 0.78. Least alike: AAPL and LGEN, 0.09."
    /// With a single pair there is nothing to contrast, so only "Most alike" is said.
    static func pairsLine(top: [CorrelationMatrixService.CorrelationPair],
                          bottom: [CorrelationMatrixService.CorrelationPair]) -> String? {
        guard let most = top.first else { return nil }
        var line = "Most alike: \(most.symbol1) and \(most.symbol2), \(pairFigure(most.correlation))."
        if let least = bottom.first, !(least.symbol1 == most.symbol1 && least.symbol2 == most.symbol2) {
            line += " Least alike: \(least.symbol1) and \(least.symbol2), \(pairFigure(least.correlation))."
        }
        return line
    }
}

/// How strongly a correlation cell is shaded, and in which hue.
enum CorrelationShade: Equatable, Sendable {
    case none
    case positive(Double)
    case negative(Double)
}

/// Gives each holding or currency a colour the first time it appears and keeps it
/// while the page is open, so adding or removing a group never repaints the others.
struct AllocationColourBook: Equatable, Sendable {
    private(set) var assignments: [String: Int] = [:]
    let paletteCount: Int

    init(paletteCount: Int) {
        self.paletteCount = max(1, paletteCount)
    }

    mutating func assign(_ keys: [String]) {
        for key in keys where assignments[key] == nil {
            let used = Set(assignments.values)
            assignments[key] = (0..<paletteCount).first { !used.contains($0) } ?? assignments.count % paletteCount
        }
    }

    func index(for key: String) -> Int? {
        assignments[key]
    }
}
