import CoreGraphics
import Foundation

enum HoldingsTableLayout {
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 14

    static let visibleWidth: CGFloat = 66
    static let symbolWidth: CGFloat = 130
    static let unitsWidth: CGFloat = 110
    static let averageCostWidth: CGFloat = 110
    static let currencyWidth: CGFloat = 100
    static let currentWidth: CGFloat = 115
    static let valueWidth: CGFloat = 130
    static let actionsWidth: CGFloat = 110

    static let contentWidth: CGFloat = {
        let columnWidths = [
            visibleWidth,
            symbolWidth,
            unitsWidth,
            averageCostWidth,
            currencyWidth,
            currentWidth,
            valueWidth,
            actionsWidth
        ]
        return columnWidths.reduce(0, +)
            + spacing * CGFloat(columnWidths.count - 1)
            + horizontalPadding * 2
    }()
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

    private static func currencySymbol(for currency: String) -> String? {
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

    private static func usdSecondaryAmount(
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
