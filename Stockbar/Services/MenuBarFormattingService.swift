//
//  MenuBarFormattingService.swift
//  Stockbar
//
//  Created by Development Team on 2025-10-02.
//  UI/UX Enhancement - Menu Bar Formatting Service
//

import AppKit
import Foundation

/// Formats stock data for menu bar display.
///
/// Main-actor and synchronous: the titles are built for AppKit and only ever
/// used there, so nothing has to cross an actor boundary.
@MainActor
final class MenuBarFormattingService {

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let symbol: String
        let price: Double
        let change: Double
        let changePct: Double
        let dayPL: Double
        let currency: String
        let useColorCoding: Bool
        let settingsHash: Int
    }

    private struct CacheEntry {
        let formatted: NSAttributedString
        let timestamp: Date
    }

    /// Shown instead of a number that is unknown (never "0.00" or "N/A").
    nonisolated static let missingValue = "—"

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 5.0  // 5 seconds

    nonisolated init() {}

    // MARK: - Public Methods

    /// Formats a stock for menu bar display
    /// - Parameters:
    ///   - symbol: Stock symbol
    ///   - price: Current price
    ///   - change: Dollar change per share
    ///   - changePct: Percentage change
    ///   - dayPL: Day P&L for entire position
    ///   - currency: Currency code
    ///   - settings: Display settings
    ///   - useColorCoding: Whether to apply color coding
    /// - Returns: Formatted NSAttributedString
    func formatStockTitle(
        symbol: String,
        price: Double,
        change: Double,
        changePct: Double,
        dayPL: Double,
        currency: String,
        settings: MenuBarDisplaySettings,
        useColorCoding: Bool
    ) -> NSAttributedString {
        // Check cache first
        // NaN != NaN, so unknown values share one sentinel to keep cache lookups stable.
        func keyed(_ value: Double) -> Double { value.isNaN ? -.infinity : value }
        let cacheKey = CacheKey(
            symbol: symbol,
            price: keyed(price),
            change: keyed(change),
            changePct: keyed(changePct),
            dayPL: keyed(dayPL),
            currency: currency,
            useColorCoding: useColorCoding,
            settingsHash: settings.hashValue
        )

        if let cached = cache[cacheKey],
           Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            return cached.formatted
        }

        // Generate formatted string
        let formatted = generateFormattedString(
            symbol: symbol,
            price: price,
            change: change,
            changePct: changePct,
            dayPL: dayPL,
            currency: currency,
            settings: settings,
            useColorCoding: useColorCoding
        )

        // Cache result
        cache[cacheKey] = CacheEntry(formatted: formatted, timestamp: Date())

        // Cleanup old cache entries periodically
        cleanupCache()

        return formatted
    }

    /// Clears the formatting cache
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private Methods

    private func generateFormattedString(
        symbol: String,
        price: Double,
        change: Double,
        changePct: Double,
        dayPL: Double,
        currency: String,
        settings: MenuBarDisplaySettings,
        useColorCoding: Bool
    ) -> NSAttributedString {
        // Zero (and unknown) change is neutral: no arrow, no green. So is a change
        // too small to show at the chosen precision: "+0.00%" in green says nothing.
        let shownChange = Self.roundedForDisplay(change, decimalPlaces: settings.decimalPlaces)
        let shownChangePct = Self.roundedForDisplay(changePct, decimalPlaces: settings.decimalPlaces)
        let direction = shownChange != 0 ? shownChange : shownChangePct
        let isPositive = direction > 0
        let isNegative = direction < 0

        // Get the template
        var template = settings.effectiveTemplate
        let templateHasArrow = template.contains("{arrow}")

        // Prepare formatted values
        let formattedPrice = formatPrice(price, currency: currency, settings: settings)
        let formattedChange = formatChange(change, currency: currency, settings: settings)
        let formattedChangePct = formatChangePercent(changePct, settings: settings)
        let formattedDayPL = formatChange(dayPL, currency: currency, settings: settings)
        let arrow = isPositive ? settings.arrowStyle.upArrow() :
                    isNegative ? settings.arrowStyle.downArrow() : ""

        // Replace placeholders
        template = template.replacingOccurrences(of: "{symbol}", with: symbol)
        template = template.replacingOccurrences(of: "{price}", with: formattedPrice)
        template = template.replacingOccurrences(of: "{change}", with: formattedChange)
        template = template.replacingOccurrences(of: "{changePct}", with: formattedChangePct)
        template = template.replacingOccurrences(of: "{dayPL}", with: formattedDayPL)
        template = template.replacingOccurrences(of: "{currency}", with: currency)
        template = template.replacingOccurrences(of: "{arrow}", with: arrow)

        // Handle arrow before/after symbol for non-custom modes
        if settings.displayMode != .custom && settings.arrowStyle != .none && !arrow.isEmpty && !templateHasArrow {
            if settings.showArrowBeforeSymbol {
                // Arrow before symbol
                if template.hasPrefix(symbol) {
                    template = "\(arrow) \(template)"
                }
            } else {
                // Arrow after symbol (replace first occurrence only)
                if let range = template.range(of: symbol) {
                    let endIndex = template.index(range.upperBound, offsetBy: 0)
                    template.replaceSubrange(endIndex..<endIndex, with: " \(arrow)")
                }
            }
        }

        // Without colour coding the title is still neutral, but keeps the same font.
        return createAttributedString(
            template,
            isPositive: isPositive,
            isNegative: isNegative,
            colored: useColorCoding
        )
    }

    /// The value as it will be printed, so "-0.004" at two places is zero, not negative.
    nonisolated static func roundedForDisplay(_ value: Double, decimalPlaces: Int) -> Double {
        guard value.isFinite else { return 0 }
        let scale = pow(10, Double(max(0, decimalPlaces)))
        let rounded = (value * scale).rounded() / scale
        return rounded == 0 ? 0 : rounded
    }

    /// Digits of equal width, so the item does not change width as prices tick.
    nonisolated static var titleFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    private func formatPrice(_ price: Double, currency: String, settings: MenuBarDisplaySettings) -> String {
        // A missing price is not a price of zero.
        guard price.isFinite, price > 0 else {
            return Self.missingValue
        }

        let formatted = String(format: "%.\(settings.decimalPlaces)f", price)

        if settings.showCurrency {
            // Use currency symbol if available
            if let symbol = currencySymbol(for: currency) {
                return "\(symbol)\(formatted)"
            } else {
                return "\(currency) \(formatted)"
            }
        } else {
            return formatted
        }
    }

    private func formatChange(_ change: Double, currency: String, settings: MenuBarDisplaySettings) -> String {
        guard change.isFinite else {
            return Self.missingValue
        }

        // A change that rounds to zero carries no sign.
        let change = Self.roundedForDisplay(change, decimalPlaces: settings.decimalPlaces)
        let formatted = String(format: change == 0 ? "%.\(settings.decimalPlaces)f" : "%+.\(settings.decimalPlaces)f", change)

        if settings.showCurrency {
            if let symbol = currencySymbol(for: currency) {
                let sign = change < 0 ? "-" : (change > 0 ? "+" : "")
                return "\(sign)\(symbol)\(abs(change).formatted(decimalPlaces: settings.decimalPlaces))"
            } else {
                return "\(currency) \(formatted)"
            }
        } else {
            return formatted
        }
    }

    private func formatChangePercent(_ percent: Double, settings: MenuBarDisplaySettings) -> String {
        guard percent.isFinite else {
            return Self.missingValue
        }

        let percent = Self.roundedForDisplay(percent, decimalPlaces: settings.decimalPlaces)
        return String(format: percent == 0 ? "%.\(settings.decimalPlaces)f%%" : "%+.\(settings.decimalPlaces)f%%", percent)
    }

    private func currencySymbol(for currencyCode: String) -> String? {
        let locale = NSLocale(localeIdentifier: "en_US")
        return locale.displayName(forKey: .currencySymbol, value: currencyCode)
    }

    private func createAttributedString(
        _ text: String,
        isPositive: Bool,
        isNegative: Bool,
        colored: Bool
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)

        // Digits of equal width whether or not the title is coloured.
        attributed.addAttribute(.font, value: Self.titleFont, range: range)
        guard colored else {
            return attributed.copy() as? NSAttributedString ?? NSAttributedString(attributedString: attributed)
        }

        // Apply color based on change
        let color: NSColor = if isPositive {
            .systemGreen
        } else if isNegative {
            .systemRed
        } else {
            .labelColor  // Default system color
        }

        attributed.addAttribute(.foregroundColor, value: color, range: range)

        return attributed.copy() as? NSAttributedString ?? NSAttributedString(attributedString: attributed)
    }

    private func cleanupCache() {
        let now = Date()
        cache = cache.filter { _, entry in
            now.timeIntervalSince(entry.timestamp) < cacheTTL
        }
    }
}

// MARK: - Helper Extensions

extension Double {
    func formatted(decimalPlaces: Int) -> String {
        return String(format: "%.\(decimalPlaces)f", self)
    }
}

extension MenuBarDisplaySettings: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(displayMode)
        hasher.combine(changeFormat)
        hasher.combine(customTemplate)
        hasher.combine(showCurrency)
        hasher.combine(decimalPlaces)
        hasher.combine(arrowStyle)
        hasher.combine(showArrowBeforeSymbol)
    }
}
