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

/// One slice of the donut and its row.
struct AllocationGroup: Equatable, Identifiable, Sendable {
    /// Stable identity: the sector's raw value, the symbol or the currency code; "Other" for the fold.
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

    static let otherKey = "\u{0}Other"
}

enum AllocationPresentation {
    /// The donut never has more slices than this.
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

    /// The day-change cell: signed percent, or a dash when unknown.
    static func dayChangeText(_ group: AllocationGroup) -> String {
        group.dayChangePercent.map(AttributionFormat.signedPercent) ?? "—"
    }

    /// The row as VoiceOver reads it.
    static func spokenRow(_ group: AllocationGroup, grouping: AllocationGrouping, currency: String) -> String {
        var parts = [rowLabel(group, grouping: grouping),
                     HoldingsCurrencyFormatter.amount(group.value, currency: currency),
                     String(format: "%.1f percent", group.share)]
        if grouping == .sector {
            parts.append(group.dayChangePercent
                .map { "day change \(AttributionFormat.spokenPercent($0))" } ?? "day change unavailable")
        }
        return parts.joined(separator: ", ")
    }

    /// The donut's centre: the total and how many holdings make it up.
    static func centreText(total: Double, holdingCount: Int, currency: String) -> (total: String, count: String) {
        (HoldingsCurrencyFormatter.compactAmount(total, currency: currency),
         "\(holdingCount) \(holdingCount == 1 ? "holding" : "holdings")")
    }

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
