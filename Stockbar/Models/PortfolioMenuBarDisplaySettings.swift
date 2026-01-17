import Foundation

struct PortfolioMenuBarDisplaySettings: Codable, Equatable {
    enum DayGainFormat: String, Codable, CaseIterable {
        case currency
        case percentage

        var description: String {
            switch self {
            case .currency:
                return "Currency"
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
        dayGainFormat: DayGainFormat = .currency,
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
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: UserDefaultsKey.isEnabled) as? Bool ?? false
        let currency = defaults.string(forKey: UserDefaultsKey.currencyCode) ?? defaultCurrency
        let formatRaw = defaults.string(forKey: UserDefaultsKey.dayGainFormat) ?? DayGainFormat.currency.rawValue
        let decimals = defaults.object(forKey: UserDefaultsKey.decimalPlaces) as? Int ?? 2

        return PortfolioMenuBarDisplaySettings(
            isEnabled: enabled,
            currencyCode: currency,
            dayGainFormat: DayGainFormat(rawValue: formatRaw) ?? .currency,
            decimalPlaces: decimals
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: UserDefaultsKey.isEnabled)
        defaults.set(currencyCode, forKey: UserDefaultsKey.currencyCode)
        defaults.set(dayGainFormat.rawValue, forKey: UserDefaultsKey.dayGainFormat)
        defaults.set(decimalPlaces, forKey: UserDefaultsKey.decimalPlaces)
    }

    func samplePreview() -> String {
        let currency = currencyCode.isEmpty ? "USD" : currencyCode
        let totalValue = format(amount: 10234.56, currency: currency, decimals: decimalPlaces)
        let dayGain = format(amount: 123.45, currency: currency, decimals: decimalPlaces)
        let dayGainPercent = String(format: "%+.2f%%", 1.21)

        switch dayGainFormat {
        case .currency:
            return "\(currency) \(totalValue) (Day: \(currency) \(dayGain))"
        case .percentage:
            return "\(currency) \(totalValue) (Day: \(dayGainPercent))"
        }
    }

    private func format(amount: Double, currency: String, decimals: Int) -> String {
        let formatted = String(format: "%+.\(decimals)f", amount)
        return formatted.replacingOccurrences(of: "+", with: "")
    }
}
