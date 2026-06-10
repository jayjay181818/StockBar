import CoreGraphics
import Foundation

enum HoldingsTableLayout {
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 14

    static let visibleWidth: CGFloat = 58
    static let symbolWidth: CGFloat = 150
    static let unitsWidth: CGFloat = 130
    static let averageCostWidth: CGFloat = 140
    static let currencyWidth: CGFloat = 120
    static let currentWidth: CGFloat = 130
    static let valueWidth: CGFloat = 145
    static let dayProfitLossWidth: CGFloat = 140
    static let totalProfitLossWidth: CGFloat = 145
    static let actionsWidth: CGFloat = 105

    static let contentWidth: CGFloat = {
        let columnWidths = [
            visibleWidth,
            symbolWidth,
            unitsWidth,
            averageCostWidth,
            currencyWidth,
            currentWidth,
            valueWidth,
            dayProfitLossWidth,
            totalProfitLossWidth,
            actionsWidth
        ].reduce(0, +)
        return columnWidths + (spacing * 9) + (horizontalPadding * 2)
    }()
}

enum HoldingsCurrencyFormatter {
    static func signedAmount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "-" }
        let sign = amount < 0 ? "-" : "+"
        return sign + formattedMagnitude(abs(amount), currency: currency)
    }

    static func amount(_ amount: Double, currency: String) -> String {
        guard amount.isFinite else { return "-" }
        return formattedMagnitude(amount, currency: currency)
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
        if displayAmount < 0 {
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
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
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
