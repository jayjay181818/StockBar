import Foundation

struct PortfolioMenuBarDisplaySettings: Codable, Equatable {
    enum DayGainFormat: String, Codable, CaseIterable {
        case both
        case currency
        case percentage

        var description: String {
            switch self {
            case .both:
                return "Amount and Percentage"
            case .currency:
                return "Amount"
            case .percentage:
                return "Percentage"
            }
        }
    }

    var isEnabled: Bool
    var currencyCode: String
    var dayGainFormat: DayGainFormat
    var decimalPlaces: Int

    init(
        isEnabled: Bool = false,
        currencyCode: String = "USD",
        dayGainFormat: DayGainFormat = .both,
        decimalPlaces: Int = 2
    ) {
        self.isEnabled = isEnabled
        self.currencyCode = currencyCode
        self.dayGainFormat = dayGainFormat
        self.decimalPlaces = decimalPlaces
    }

    enum UserDefaultsKey {
        static let isEnabled = "portfolioMenuBarIsEnabled"
        static let currencyCode = "portfolioMenuBarCurrency"
        static let dayGainFormat = "portfolioMenuBarDayGainFormat"
        static let decimalPlaces = "portfolioMenuBarDecimalPlaces"
    }

    static func load(defaultCurrency: String) -> PortfolioMenuBarDisplaySettings {
        let defaults = StockbarRuntimeStorage.userDefaults
        let enabled = defaults.object(forKey: UserDefaultsKey.isEnabled) as? Bool ?? false
        let currency = defaults.string(forKey: UserDefaultsKey.currencyCode) ?? defaultCurrency
        // `.both` matches what the status item always displayed before this
        // setting was honoured, so users who never chose see no change.
        let formatRaw = defaults.string(forKey: UserDefaultsKey.dayGainFormat) ?? DayGainFormat.both.rawValue
        let decimals = defaults.object(forKey: UserDefaultsKey.decimalPlaces) as? Int ?? 2

        return PortfolioMenuBarDisplaySettings(
            isEnabled: enabled,
            currencyCode: currency,
            dayGainFormat: DayGainFormat(rawValue: formatRaw) ?? .both,
            decimalPlaces: decimals
        )
    }

    func save() {
        let defaults = StockbarRuntimeStorage.userDefaults
        defaults.set(isEnabled, forKey: UserDefaultsKey.isEnabled)
        defaults.set(currencyCode, forKey: UserDefaultsKey.currencyCode)
        defaults.set(dayGainFormat.rawValue, forKey: UserDefaultsKey.dayGainFormat)
        defaults.set(decimalPlaces, forKey: UserDefaultsKey.decimalPlaces)
    }

    func samplePreview(locale: Locale = .current) -> String {
        PortfolioMenuBarTitleFormatter.title(
            totalValue: 10_234.56,
            dayGain: 123.45,
            dayGainPercent: 1.21,
            settings: self,
            locale: locale
        )
    }
}

/// Builds the portfolio status-item title. Shared by the menu bar and the
/// Settings preview so the preview always matches what is displayed.
enum PortfolioMenuBarTitleFormatter {
    static func title(
        totalValue: Double,
        dayGain: Double,
        dayGainPercent: Double,
        settings: PortfolioMenuBarDisplaySettings,
        locale: Locale = .current
    ) -> String {
        let decimals = max(0, min(settings.decimalPlaces, 4))
        let symbol = currencySymbol(for: settings.currencyCode)
        let value = "\(symbol)\(number(totalValue, decimals: decimals, locale: locale))"
        // A change that prints as zero carries no sign: "+£0.00" and "-0.00%" say nothing.
        let shownGain = MenuBarFormattingService.roundedForDisplay(dayGain, decimalPlaces: decimals)
        let sign = shownGain < 0 ? "-" : (shownGain > 0 ? "+" : "")
        let amount = "\(sign)\(symbol)\(number(abs(shownGain), decimals: decimals, locale: locale))"
        let percent = signedPercent(
            MenuBarFormattingService.roundedForDisplay(dayGainPercent, decimalPlaces: 2), locale: locale
        )

        switch settings.dayGainFormat {
        case .both:
            return "\(value) \(amount) (\(percent))"
        case .currency:
            return "\(value) \(amount)"
        case .percentage:
            return "\(value) \(percent)"
        }
    }

    static func currencySymbol(for currency: String) -> String {
        switch currency {
        case "GBP", "GBX", "GBp": return "£"
        case "USD": return "$"
        case "EUR": return "€"
        case "JPY": return "¥"
        case "CAD": return "C$"
        case "AUD": return "A$"
        default: return currency + " "
        }
    }

    private static func number(_ value: Double, decimals: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.*f", decimals, value)
    }

    private static func signedPercent(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = value == 0 ? "" : "+"
        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%+.2f", value)
        return text + "%"
    }
}
