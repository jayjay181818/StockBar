//
//  MenuBarFormattingService.swift
//  Stockbar
//
//  Created by Development Team on 2025-10-02.
//  UI/UX Enhancement - Menu Bar Formatting Service
//

import Foundation
import AppKit

/// Thread-safe service for formatting stock data for menu bar display
actor MenuBarFormattingService {

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let symbol: String
        let price: Double
        let change: Double
        let changePct: Double
        let settingsHash: Int
    }

    private struct CacheEntry {
        let formatted: NSAttributedString
        let timestamp: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 5.0  // 5 seconds
    private let logger = Logger.shared

    // MARK: - Initialization

    init() {
        Task {
            await logger.debug("MenuBarFormattingService initialized")
        }
    }

    // MARK: - Public Methods

    /// Formats a stock for menu bar display
    /// - Parameters:
    ///   - symbol: Stock symbol
    ///   - price: Current price
    ///   - change: Dollar change
    ///   - changePct: Percentage change
    ///   - currency: Currency code
    ///   - settings: Display settings
    ///   - useColorCoding: Whether to apply color coding
    /// - Returns: Formatted NSAttributedString
    func formatStockTitle(
        symbol: String,
        price: Double,
        change: Double,
        changePct: Double,
        currency: String,
        settings: MenuBarDisplaySettings,
        useColorCoding: Bool
    ) -> NSAttributedString {
        // Check cache first
        let cacheKey = CacheKey(
            symbol: symbol,
            price: price,
            change: change,
            changePct: changePct,
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
        Task {
            await logger.debug("MenuBarFormattingService cache cleared")
        }
    }

    // MARK: - Private Methods

    private func generateFormattedString(
        symbol: String,
        price: Double,
        change: Double,
        changePct: Double,
        currency: String,
        settings: MenuBarDisplaySettings,
        useColorCoding: Bool
    ) -> NSAttributedString {
        let isPositive = change > 0
        let isNegative = change < 0

        // Get the template
        var template = settings.effectiveTemplate

        // Prepare formatted values
        let formattedPrice = formatPrice(price, currency: currency, settings: settings)
        let formattedChange = formatChange(change, currency: currency, settings: settings)
        let formattedChangePct = formatChangePercent(changePct, settings: settings)
        let arrow = isPositive ? settings.arrowStyle.upArrow() :
                    isNegative ? settings.arrowStyle.downArrow() : ""

        // Replace placeholders
        template = template.replacingOccurrences(of: "{symbol}", with: symbol)
        template = template.replacingOccurrences(of: "{price}", with: formattedPrice)
        template = template.replacingOccurrences(of: "{change}", with: formattedChange)
        template = template.replacingOccurrences(of: "{changePct}", with: formattedChangePct)
        template = template.replacingOccurrences(of: "{currency}", with: currency)
        template = template.replacingOccurrences(of: "{arrow}", with: arrow)

        // Handle arrow before/after symbol for non-custom modes
        if settings.displayMode != .custom && settings.arrowStyle != .none && !arrow.isEmpty {
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

        // Apply color coding if enabled
        if useColorCoding {
            return createAttributedString(
                template,
                isPositive: isPositive,
                isNegative: isNegative
            )
        } else {
            return NSAttributedString(string: template)
        }
    }

    private func formatPrice(_ price: Double, currency: String, settings: MenuBarDisplaySettings) -> String {
        guard !price.isNaN && price.isFinite else {
            return "N/A"
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
        guard !change.isNaN && change.isFinite else {
            return "N/A"
        }

        let formatted = String(format: "%+.\(settings.decimalPlaces)f", change)

        if settings.showCurrency {
            if let symbol = currencySymbol(for: currency) {
                return "\(formatted.hasPrefix("+") ? "+" : "")\(symbol)\(abs(change).formatted(decimalPlaces: settings.decimalPlaces))"
            } else {
                return "\(currency) \(formatted)"
            }
        } else {
            return formatted
        }
    }

    private func formatChangePercent(_ percent: Double, settings: MenuBarDisplaySettings) -> String {
        guard !percent.isNaN && percent.isFinite else {
            return "N/A"
        }

        return String(format: "%+.\(settings.decimalPlaces)f%%", percent)
    }

    private func currencySymbol(for currencyCode: String) -> String? {
        let locale = NSLocale(localeIdentifier: "en_US")
        return locale.displayName(forKey: .currencySymbol, value: currencyCode)
    }

    private func createAttributedString(
        _ text: String,
        isPositive: Bool,
        isNegative: Bool
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)

        // Apply color based on change
        let color: NSColor = if isPositive {
            .systemGreen
        } else if isNegative {
            .systemRed
        } else {
            .labelColor  // Default system color
        }

        attributed.addAttribute(.foregroundColor, value: color, range: range)

        // Use system font
        attributed.addAttribute(.font, value: NSFont.menuBarFont(ofSize: 0), range: range)

        return attributed
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
