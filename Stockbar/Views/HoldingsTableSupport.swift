import CoreGraphics
import Foundation
import SwiftUI

/// The editing table's column widths. There are two sets: `regular`, used
/// whenever the table has room for it, and `compact`, narrow enough for the
/// Holdings card at the window's minimum size so the row actions stay in view.
/// The header and the rows are given the same value, so their columns line up.
struct HoldingsTableLayout: Equatable, Sendable {
    var spacing: CGFloat
    var horizontalPadding: CGFloat

    var visibleWidth: CGFloat
    var symbolWidth: CGFloat
    var unitsWidth: CGFloat
    var averageCostWidth: CGFloat
    var currencyWidth: CGFloat
    var currentWidth: CGFloat
    var valueWidth: CGFloat
    var actionsWidth: CGFloat
    /// Space between the row's action buttons.
    var actionSpacing: CGFloat

    /// The widths the table has always had.
    static let regular = HoldingsTableLayout(
        spacing: 10,
        horizontalPadding: 14,
        visibleWidth: 66,
        symbolWidth: 130,
        unitsWidth: 110,
        averageCostWidth: 110,
        currencyWidth: 100,
        currentWidth: 115,
        valueWidth: 130,
        actionsWidth: 110,
        actionSpacing: 8
    )

    /// For a table narrower than `regular`: fits the card at the window's
    /// minimum size with a typical entry in every field.
    static let compact = HoldingsTableLayout(
        spacing: 8,
        horizontalPadding: 12,
        visibleWidth: 66,
        symbolWidth: 100,
        unitsWidth: 86,
        averageCostWidth: 90,
        currencyWidth: 84,
        currentWidth: 84,
        valueWidth: 96,
        actionsWidth: 88,
        actionSpacing: 6
    )

    /// The regular set whenever it fits, the compact one otherwise. Below the
    /// compact set's width the table still scrolls sideways.
    static func fitting(availableWidth: CGFloat) -> HoldingsTableLayout {
        availableWidth >= regular.contentWidth ? regular : compact
    }

    var columnWidths: [CGFloat] {
        [visibleWidth, symbolWidth, unitsWidth, averageCostWidth,
         currencyWidth, currentWidth, valueWidth, actionsWidth]
    }

    var contentWidth: CGFloat {
        columnWidths.reduce(0, +)
            + spacing * CGFloat(columnWidths.count - 1)
            + horizontalPadding * 2
    }
}

enum HoldingsCurrencyFormatter {
    static func signedAmount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "-" }
        let magnitude = formattedMagnitude(abs(amount), currency: currency)
        // An amount that rounds to nothing is shown as plain zero: "+£0.00" and
        // "-£0.00" both suggest a movement that is not there.
        guard showsNonZeroDigit(magnitude) else { return magnitude }
        return (amount < 0 ? "-" : "+") + magnitude
    }

    /// The sign goes before the currency symbol: "-£5.00", never "£-5.00".
    static func amount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "-" }
        let magnitude = formattedMagnitude(abs(amount), currency: currency)
        guard amount < 0, showsNonZeroDigit(magnitude) else { return magnitude }
        return "-" + magnitude
    }

    /// False when the formatted figure is all zeros, as "£0.00" is.
    static func showsNonZeroDigit(_ formatted: String) -> Bool {
        formatted.contains { $0.isNumber && $0 != "0" }
    }

    /// The value to colour by: zero when the figure displays as zero, so a
    /// loss of a fraction of a penny is not drawn in red beside "£0.00".
    static func displayedSign(of amount: Double, currency: String) -> Double {
        guard amount.isFinite else { return 0 }
        return showsNonZeroDigit(formattedMagnitude(abs(amount), currency: currency)) ? amount : 0
    }

    static func compactAmount(_ amount: Double?, currency: String, includeSign: Bool = false) -> String {
        guard let amount, amount.isFinite else { return "-" }

        let normalizedCurrency = normalizedCurrency(currency)
        let displayCurrency = normalizedCurrency == "GBX" ? "GBP" : normalizedCurrency
        let displayAmount = normalizedCurrency == "GBX" ? amount / 100.0 : amount
        let absoluteAmount = abs(displayAmount)
        let fractionDigits: Int

        if absoluteAmount >= 10_000 {
            fractionDigits = 0
        } else if absoluteAmount >= 1_000 {
            fractionDigits = 1
        } else {
            fractionDigits = 2
        }

        let formattedNumber = makeDecimalFormatter(
            minimumFractionDigits: fractionDigits,
            maximumFractionDigits: fractionDigits
        ).string(from: NSNumber(value: absoluteAmount)) ?? String(format: "%.\(fractionDigits)f", absoluteAmount)

        let sign: String
        if !showsNonZeroDigit(formattedNumber) {
            sign = ""
        } else if displayAmount < 0 {
            sign = "-"
        } else {
            sign = includeSign ? "+" : ""
        }

        if let symbol = currencySymbol(for: displayCurrency) {
            return "\(sign)\(symbol)\(formattedNumber)"
        }

        guard !displayCurrency.isEmpty else { return "\(sign)\(formattedNumber)" }
        return "\(sign)\(formattedNumber) \(displayCurrency)"
    }

    static func amountWithUSDSecondary(
        _ amount: Double,
        currency: String,
        usdAmount: Double?
    ) -> String {
        let primary = self.amount(amount, currency: currency)
        guard shouldShowUSDSecondary(for: currency),
              let usdAmount,
              usdAmount.isFinite
        else { return primary }
        return "\(primary) (\(self.amount(usdAmount, currency: "USD")))"
    }

    static func signedAmountWithUSDSecondary(
        _ amount: Double,
        currency: String,
        usdAmount: Double?
    ) -> String {
        let primary = signedAmount(amount, currency: currency)
        guard shouldShowUSDSecondary(for: currency),
              let usdAmount,
              usdAmount.isFinite
        else { return primary }
        return "\(primary) (\(signedAmount(usdAmount, currency: "USD")))"
    }

    private static func formattedMagnitude(_ amount: Double, currency: String) -> String {
        let normalizedCurrency = normalizedCurrency(currency)
        let formattedNumber = makeDecimalFormatter().string(from: NSNumber(value: amount))
            ?? String(format: "%.2f", amount)

        if let symbol = currencySymbol(for: normalizedCurrency) {
            return "\(symbol)\(formattedNumber)"
        }

        guard !normalizedCurrency.isEmpty else { return formattedNumber }
        return "\(formattedNumber) \(normalizedCurrency)"
    }

    private static func shouldShowUSDSecondary(for currency: String) -> Bool {
        normalizedCurrency(currency) != "USD"
    }

    private static func normalizedCurrency(_ currency: String) -> String {
        let trimmedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrency == "GBp" {
            return "GBX"
        }
        return trimmedCurrency.uppercased()
    }

    static func currencySymbol(for currency: String) -> String? {
        switch currency {
        case "USD": "$"
        case "GBP", "GBX": "£"
        case "EUR": "€"
        case "JPY": "¥"
        case "CAD": "C$"
        case "AUD": "A$"
        default: nil
        }
    }

    private static func makeDecimalFormatter(
        minimumFractionDigits: Int = 2,
        maximumFractionDigits: Int = 2
    ) -> NumberFormatter {
        // One formatter per thread and precision: a table redraw formats
        // hundreds of cells, and building a NumberFormatter each time is slow.
        let key = "HoldingsCurrencyFormatter.decimal.\(minimumFractionDigits).\(maximumFractionDigits)"
        let cache = Thread.current.threadDictionary
        if let cached = cache[key] as? NumberFormatter { return cached }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        cache[key] = formatter
        return formatter
    }
}

@MainActor
enum HoldingsSummaryAmountFormatter {
    static func format(
        _ amount: (amount: Double, currency: String),
        dataModel: DataModel,
        signed: Bool = false
    ) -> String {
        let usdAmount = usdSecondaryAmount(for: amount, dataModel: dataModel)
        if signed {
            return HoldingsCurrencyFormatter.signedAmountWithUSDSecondary(
                amount.amount,
                currency: amount.currency,
                usdAmount: usdAmount
            )
        }
        return HoldingsCurrencyFormatter.amountWithUSDSecondary(
            amount.amount,
            currency: amount.currency,
            usdAmount: usdAmount
        )
    }

    static func usdSecondaryAmount(
        for amount: (amount: Double, currency: String),
        dataModel: DataModel
    ) -> Double? {
        let currency = amount.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard currency != "USD", amount.amount.isFinite else { return nil }
        return dataModel.currencyConverter.convert(amount: amount.amount, from: currency, to: "USD")
    }
}

/// Pure helpers for the holdings editor.
enum HoldingsEditing {
    /// The row to swap with when moving `index` up (`offset < 0`) or down (`offset > 0`), among
    /// the rows currently visible. Hidden rows are skipped; nil when there is no visible neighbour.
    static func moveDestination(from index: Int, by offset: Int, visibleIndices: [Int]) -> Int? {
        guard offset != 0, let position = visibleIndices.firstIndex(of: index) else { return nil }
        let target = position + (offset > 0 ? 1 : -1)
        guard visibleIndices.indices.contains(target) else { return nil }
        return visibleIndices[target]
    }

    /// Pence plus every supported currency, keeping an unrecognised stored code selectable.
    static func currencyOptions(current: String?) -> [String] {
        var options = ["GBX"] + DataModel.supportedCurrencies
        if let current, !current.isEmpty, !options.contains(current) {
            options.append(current)
        }
        return options
    }
}

/// Where the Holdings strip's total gains come from (`DataModel.netGainsSource`).
enum PortfolioGainsSource: Equatable {
    /// Folync's unrealised profit and loss for the whole portfolio.
    case folync
    /// Trading 212's unrealised profit and loss for the account.
    case trading212
    /// Stockbar's own sum: each priced holding's value less its average cost.
    case averageCost
}

/// Whether the Today and Total gain columns show amounts or percentages.
/// One choice for both columns, remembered between launches.
enum HoldingsGainDisplayMode: String, CaseIterable {
    case amounts
    case percent

    static let storageKey = "holdings.gainDisplayMode"
    static let defaultValue = HoldingsGainDisplayMode.amounts

    var title: String {
        switch self {
        case .amounts: "Amounts"
        case .percent: "Percent"
        }
    }

    /// The stored choice; anything unreadable falls back to amounts.
    static func stored(in defaults: UserDefaults) -> HoldingsGainDisplayMode {
        defaults.string(forKey: storageKey).flatMap(HoldingsGainDisplayMode.init(rawValue:)) ?? defaultValue
    }
}

/// A holding's weight: its share of the portfolio, in percent.
enum HoldingsWeight {
    /// What a cell shows for a figure that is not known. Every unknown figure
    /// in a Holdings row uses it, as the app's other pages do.
    static let unknownText = "–"

    /// A figure given by the portfolio source, used as it is.
    static func given(_ percent: Double?) -> Double? {
        guard let percent, percent.isFinite else { return nil }
        return percent
    }

    /// `value` as a share of `total`, after converting it into the total's currency.
    /// Nil when either is not known, a currency is missing, there is no exchange
    /// rate, or the total is not positive.
    static func share(value: Double, currency valueCurrency: String,
                      of total: Double, currency totalCurrency: String,
                      convert: (Double, String, String) -> Double) -> Double? {
        let from = valueCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = totalCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isFinite, value >= 0, total.isFinite, total > 0, !from.isEmpty, !to.isEmpty else { return nil }
        let converted = from == to ? value : convert(value, from, to)
        guard converted.isFinite else { return nil }
        return converted / total * 100
    }

    /// "25.5%", or "–".
    static func text(_ percent: Double?) -> String {
        guard let percent, percent.isFinite else { return unknownText }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), percent)
    }

    /// Sorts known weights by size, with unknown ones below every known one.
    static func sortKey(_ percent: Double?) -> Double {
        guard let percent, percent.isFinite else { return -.infinity }
        return percent
    }
}

/// One row of the read-only Holdings table: the holding and its weight, worked
/// out once per redraw so the Weight column can sort.
struct HoldingsTableRow: Identifiable {
    let trade: RealTimeTrade
    let weight: Double?
    var id: UUID { trade.id }
    var weightSortKey: Double { HoldingsWeight.sortKey(weight) }
}

/// The words on the Holdings page that depend on its figures.
enum HoldingsText {
    /// The Today or Total gain cell, in the chosen mode. "–" when not known.
    static func gain(amount: Double, percent: Double, currency: String, mode: HoldingsGainDisplayMode) -> String {
        switch mode {
        case .amounts:
            guard amount.isFinite else { return HoldingsWeight.unknownText }
            return HoldingsCurrencyFormatter.signedAmount(amount, currency: currency)
        case .percent:
            guard percent.isFinite else { return HoldingsWeight.unknownText }
            return String(format: "%+.2f%%", locale: Locale(identifier: "en_US_POSIX"), percent)
        }
    }

    /// The Net value tile's second line: the total in US dollars when the
    /// display currency is another one and the figure can be converted.
    static func netValueDetail(currency: String, usdAmount: Double?) -> String? {
        guard let usd = usdText(currency: currency, usdAmount: usdAmount, signed: false) else { return nil }
        return "\(usd) in US dollars"
    }

    /// The Total gains tile's second line: what the figure is, then the same
    /// total in US dollars when the display currency is another one.
    static func gainsDetail(source: PortfolioGainsSource, currency: String, usdAmount: Double?) -> String {
        let meaning = switch source {
        case .folync: "Unrealised, as Folync reports it"
        case .trading212: "Unrealised, as Trading 212 reports it"
        case .averageCost: "Unrealised, against average cost"
        }
        guard let usd = usdText(currency: currency, usdAmount: usdAmount, signed: true) else { return meaning }
        return "\(meaning). \(usd) in US dollars"
    }

    private static func usdText(currency: String, usdAmount: Double?, signed: Bool) -> String? {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code != "USD", let usdAmount, usdAmount.isFinite else { return nil }
        return signed
            ? HoldingsCurrencyFormatter.signedAmount(usdAmount, currency: "USD")
            : HoldingsCurrencyFormatter.amount(usdAmount, currency: "USD")
    }

    /// The line in the empty table, before any search. With a Trading 212 account valued
    /// from its summary alone, the total above is that account's value, though no row
    /// makes it up, so the line says where the figure comes from.
    static func emptyTableDescription(valuedFromTrading212Account: Bool) -> String {
        valuedFromTrading212Account
            ? "The total is your Trading 212 account's value: its cash and any holdings not linked here. "
                + "Link or add holdings to list them."
            : "Add a holding, or connect a portfolio in Settings → Connections."
    }

    /// The line under the table: how many holdings and watchlist symbols there are,
    /// and, where the Weight column shows, what a weight is. Nil when there is nothing.
    static func footer(held: Int, watchlist: Int, weightIsFolyncs: Bool?) -> String? {
        guard held + watchlist > 0 else { return nil }
        var counts = held == 0 ? "No holdings" : "\(held) \(held == 1 ? "holding" : "holdings")"
        if watchlist > 0 {
            counts += " and \(watchlist) watchlist \(watchlist == 1 ? "symbol" : "symbols")"
        }
        counts += "."
        guard let weightIsFolyncs else { return counts }
        let weight = weightIsFolyncs
            ? "Weight is Folync's figure."
            : "Weight is each holding's value as a share of the net value."
        return "\(counts) \(weight)"
    }

    /// The figures one row of the read-only table shows, as text, in the chosen mode.
    /// `todaySign` and `totalSign` are the figures' displayed signs (see
    /// `HoldingsCurrencyFormatter.displayedSign`), read as gain, loss or unchanged.
    struct RowFigures {
        var symbol: String
        var name: String?
        var isWatchlist: Bool
        var price: String
        var value: String
        var weight: Double?
        var today: String
        var todaySign: Double
        var totalGain: String
        var totalSign: Double
    }

    /// What VoiceOver reads for one row of the read-only table: one sentence
    /// with every figure the row shows.
    static func rowSentence(_ row: RowFigures) -> String {
        var parts = [row.symbol]
        if let name = row.name, !name.isEmpty, name != row.symbol { parts.append(name) }
        if row.isWatchlist {
            parts.append("watchlist only")
            parts.append("price \(spoken(row.price))")
        } else {
            parts.append("price \(spoken(row.price))")
            parts.append("value \(spoken(row.value))")
            parts.append("weight \(row.weight == nil ? "not known" : HoldingsWeight.text(row.weight))")
            parts.append("today \(movement(row.today, sign: row.todaySign))")
            parts.append("total gain \(movement(row.totalGain, sign: row.totalSign))")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// "a gain of +£89.84", "a loss of -1.23%", "unchanged at £0.00" or "not known".
    private static func movement(_ text: String, sign: Double) -> String {
        let figure = spoken(text)
        guard figure != "not known" else { return figure }
        if sign > 0 { return "a gain of \(figure)" }
        if sign < 0 { return "a loss of \(figure)" }
        return "unchanged at \(figure)"
    }

    /// A dash read aloud is "dash", not "not known".
    private static func spoken(_ text: String) -> String {
        ["—", "–", "-", ""].contains(text) ? "not known" : text
    }
}
