//
//  MenuBarDisplaySettings.swift
//  Stockbar
//
//  Created by Development Team on 2025-10-02.
//  UI/UX Enhancement - Menu Bar Display Customization
//

import Foundation

/// Configuration for menu bar stock display formatting
struct MenuBarDisplaySettings: Codable, Equatable {

    // MARK: - Display Mode

    /// Display mode for menu bar items
    enum DisplayMode: String, Codable, CaseIterable {
        case compact    // Symbol + % change only (e.g., "AAPL +2.45%")
        case expanded   // Symbol + Price + % change (e.g., "AAPL $175.23 +2.45%")
        case minimal    // Symbol + Indicator only (e.g., "AAPL ▲")
        case custom     // User-defined template

        var description: String {
            switch self {
            case .compact:
                return "Compact (Symbol + %)"
            case .expanded:
                return "Expanded (Symbol + Price + %)"
            case .minimal:
                return "Minimal (Symbol + ↑/↓)"
            case .custom:
                return "Custom Template"
            }
        }

        var example: String {
            switch self {
            case .compact:
                return "AAPL +2.45%"
            case .expanded:
                return "AAPL $175.23 +2.45%"
            case .minimal:
                return "AAPL ▲"
            case .custom:
                return "{symbol}: {changePct}"
            }
        }
    }

    // MARK: - Change Format

    /// Format for displaying price changes
    enum ChangeFormat: String, Codable, CaseIterable {
        case percentage     // Show as percentage (e.g., "+2.45%")
        case dollar         // Show per-share change (e.g., "+$4.29")
        case both           // Show both (e.g., "+$4.29 (2.45%)")
        case positionPL     // Show position P&L + per-share change (e.g., "+$429.00 (+$4.29)")
        case positionPLPct  // Show position P&L + percentage (e.g., "+$429.00 (+2.45%)")

        var description: String {
            switch self {
            case .percentage:
                return "Percentage (%)"
            case .dollar:
                return "Dollar ($)"
            case .both:
                return "Both ($ and %)"
            case .positionPL:
                return "Position P&L + $ per share"
            case .positionPLPct:
                return "Position P&L + % gain"
            }
        }

        var example: String {
            switch self {
            case .percentage:
                return "+2.45%"
            case .dollar:
                return "+$4.29"
            case .both:
                return "+$4.29 (2.45%)"
            case .positionPL:
                return "+$429.00 (+$4.29)"
            case .positionPLPct:
                return "+$429.00 (+2.45%)"
            }
        }
    }

    // MARK: - Arrow Style

    /// Visual style for arrow indicators
    enum ArrowStyle: String, Codable, CaseIterable {
        case none           // No arrows
        case simple         // ▲ ▼
        case bold           // ⬆ ⬇
        case emoji          // 🔺 🔻

        var description: String {
            switch self {
            case .none:
                return "No Arrows"
            case .simple:
                return "Simple (▲ ▼)"
            case .bold:
                return "Bold (⬆ ⬇)"
            case .emoji:
                return "Emoji (🔺 🔻)"
            }
        }

        func upArrow() -> String {
            switch self {
            case .none: return ""
            case .simple: return "▲"
            case .bold: return "⬆"
            case .emoji: return "🔺"
            }
        }

        func downArrow() -> String {
            switch self {
            case .none: return ""
            case .simple: return "▼"
            case .bold: return "⬇"
            case .emoji: return "🔻"
            }
        }
    }

    // MARK: - Properties

    var displayMode: DisplayMode
    var changeFormat: ChangeFormat
    var customTemplate: String?
    var showCurrency: Bool
    var decimalPlaces: Int
    var arrowStyle: ArrowStyle
    var showArrowBeforeSymbol: Bool  // True: ▲ AAPL, False: AAPL ▲

    // MARK: - Initialization

    init(
        displayMode: DisplayMode = .expanded,
        changeFormat: ChangeFormat = .percentage,
        customTemplate: String? = nil,
        showCurrency: Bool = true,
        decimalPlaces: Int = 2,
        arrowStyle: ArrowStyle = .none,
        showArrowBeforeSymbol: Bool = false
    ) {
        self.displayMode = displayMode
        self.changeFormat = changeFormat
        self.customTemplate = customTemplate
        self.showCurrency = showCurrency
        self.decimalPlaces = decimalPlaces
        self.arrowStyle = arrowStyle
        self.showArrowBeforeSymbol = showArrowBeforeSymbol
    }

    // MARK: - Template Validation

    /// Valid placeholders for custom templates
    static let validPlaceholders: Set<String> = [
        "{symbol}",
        "{price}",
        "{change}",
        "{changePct}",
        "{currency}",
        "{arrow}",
        "{dayPL}"
    ]

    /// Validates a custom template string
    /// - Parameter template: The template string to validate
    /// - Returns: Tuple of (isValid, errorMessage)
    static func validateTemplate(_ template: String) -> (isValid: Bool, errorMessage: String?) {
        guard !template.isEmpty else {
            return (false, "Template cannot be empty")
        }

        // Extract placeholders from template
        let placeholderPattern = "\\{[^}]+\\}"
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern, options: []) else {
            return (false, "Invalid template format")
        }

        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = regex.matches(in: template, options: [], range: range)

        // Check if at least one valid placeholder exists
        var hasValidPlaceholder = false

        for match in matches {
            guard let matchRange = Range(match.range, in: template) else { continue }
            let placeholder = String(template[matchRange])

            if validPlaceholders.contains(placeholder) {
                hasValidPlaceholder = true
            } else {
                return (false, "Invalid placeholder: \(placeholder)")
            }
        }

        if !hasValidPlaceholder {
            return (false, "Template must contain at least one valid placeholder")
        }

        return (true, nil)
    }

    /// Returns the effective template based on display mode
    var effectiveTemplate: String {
        // Determine change placeholder based on changeFormat setting
        let changePlaceholder: String
        switch changeFormat {
        case .percentage:
            changePlaceholder = "{changePct}"
        case .dollar:
            changePlaceholder = "{change}"
        case .both:
            changePlaceholder = "{change} ({changePct})"
        case .positionPL:
            changePlaceholder = "{dayPL} ({change})"
        case .positionPLPct:
            changePlaceholder = "{dayPL} ({changePct})"
        }

        switch displayMode {
        case .compact:
            return "{symbol} \(changePlaceholder)"
        case .expanded:
            return "{symbol} {price} \(changePlaceholder)"
        case .minimal:
            return "{symbol} {arrow}"
        case .custom:
            return customTemplate ?? "{symbol} {changePct}"
        }
    }

    // MARK: - UserDefaults Keys

    enum UserDefaultsKey {
        static let displayMode = "menuBarDisplayMode"
        static let changeFormat = "menuBarChangeFormat"
        static let customTemplate = "menuBarCustomTemplate"
        static let showCurrency = "menuBarShowCurrency"
        static let decimalPlaces = "menuBarDecimalPlaces"
        static let arrowStyle = "menuBarArrowStyle"
        static let showArrowBeforeSymbol = "menuBarShowArrowBeforeSymbol"
    }

    // MARK: - Persistence

    /// Loads settings from UserDefaults
    static func load() -> MenuBarDisplaySettings {
        let defaults = UserDefaults.standard

        let displayModeRaw = defaults.string(forKey: UserDefaultsKey.displayMode) ?? DisplayMode.expanded.rawValue
        let changeFormatRaw = defaults.string(forKey: UserDefaultsKey.changeFormat) ?? ChangeFormat.percentage.rawValue
        let arrowStyleRaw = defaults.string(forKey: UserDefaultsKey.arrowStyle) ?? ArrowStyle.none.rawValue

        return MenuBarDisplaySettings(
            displayMode: DisplayMode(rawValue: displayModeRaw) ?? .expanded,
            changeFormat: ChangeFormat(rawValue: changeFormatRaw) ?? .percentage,
            customTemplate: defaults.string(forKey: UserDefaultsKey.customTemplate),
            showCurrency: defaults.object(forKey: UserDefaultsKey.showCurrency) as? Bool ?? true,
            decimalPlaces: defaults.object(forKey: UserDefaultsKey.decimalPlaces) as? Int ?? 2,
            arrowStyle: ArrowStyle(rawValue: arrowStyleRaw) ?? .none,
            showArrowBeforeSymbol: defaults.bool(forKey: UserDefaultsKey.showArrowBeforeSymbol)
        )
    }

    /// Saves settings to UserDefaults
    func save() {
        let defaults = UserDefaults.standard

        defaults.set(displayMode.rawValue, forKey: UserDefaultsKey.displayMode)
        defaults.set(changeFormat.rawValue, forKey: UserDefaultsKey.changeFormat)
        defaults.set(customTemplate, forKey: UserDefaultsKey.customTemplate)
        defaults.set(showCurrency, forKey: UserDefaultsKey.showCurrency)
        defaults.set(decimalPlaces, forKey: UserDefaultsKey.decimalPlaces)
        defaults.set(arrowStyle.rawValue, forKey: UserDefaultsKey.arrowStyle)
        defaults.set(showArrowBeforeSymbol, forKey: UserDefaultsKey.showArrowBeforeSymbol)
    }

    // MARK: - Equatable

    static func == (lhs: MenuBarDisplaySettings, rhs: MenuBarDisplaySettings) -> Bool {
        return lhs.displayMode == rhs.displayMode &&
               lhs.changeFormat == rhs.changeFormat &&
               lhs.customTemplate == rhs.customTemplate &&
               lhs.showCurrency == rhs.showCurrency &&
               lhs.decimalPlaces == rhs.decimalPlaces &&
               lhs.arrowStyle == rhs.arrowStyle &&
               lhs.showArrowBeforeSymbol == rhs.showArrowBeforeSymbol
    }
}

// MARK: - Preview Helpers

extension MenuBarDisplaySettings {
    /// Returns a sample formatted string for preview purposes
    /// - Returns: Sample formatted string using current settings
    func samplePreview() -> String {
        let sampleSymbol = "AAPL"
        let samplePrice = 175.23
        let sampleChange = 4.29
        let sampleChangePct = 2.45
        let sampleUnits = 100.0
        let sampleDayPL = sampleChange * sampleUnits  // 429.00
        let sampleCurrency = "USD"
        let isPositive = sampleChange > 0

        var result = effectiveTemplate

        // Replace placeholders
        result = result.replacingOccurrences(of: "{symbol}", with: sampleSymbol)
        result = result.replacingOccurrences(of: "{price}", with: formatPrice(samplePrice, currency: sampleCurrency))
        result = result.replacingOccurrences(of: "{change}", with: formatChange(sampleChange, currency: sampleCurrency))
        result = result.replacingOccurrences(of: "{changePct}", with: formatChangePercent(sampleChangePct))
        result = result.replacingOccurrences(of: "{dayPL}", with: formatChange(sampleDayPL, currency: sampleCurrency))
        result = result.replacingOccurrences(of: "{currency}", with: sampleCurrency)
        result = result.replacingOccurrences(of: "{arrow}", with: isPositive ? arrowStyle.upArrow() : arrowStyle.downArrow())

        return result
    }

    private func formatPrice(_ price: Double, currency: String) -> String {
        let formatted = String(format: "%.\(decimalPlaces)f", price)
        return showCurrency ? "\(currency) \(formatted)" : formatted
    }

    private func formatChange(_ change: Double, currency: String) -> String {
        let formatted = String(format: "%+.\(decimalPlaces)f", change)
        return showCurrency ? "\(currency) \(formatted)" : formatted
    }

    private func formatChangePercent(_ percent: Double) -> String {
        return String(format: "%+.\(decimalPlaces)f%%", percent)
    }
}
