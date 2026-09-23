import Foundation

struct SymbolMetadata {
    private static let ukSuffixes: [String] = [".L", ".LON", ".XC"]
    private static let benchmarkSymbolSet: Set<String> = ["^GSPC", "^FTSE"]

    static func isUKSymbol(_ symbol: String) -> Bool {
        let uppercased = symbol.uppercased()
        return ukSuffixes.contains { uppercased.hasSuffix($0) }
    }

    static var benchmarkSymbols: Set<String> {
        benchmarkSymbolSet
    }

    static func isBenchmarkSymbol(_ symbol: String) -> Bool {
        benchmarkSymbolSet.contains(symbol.uppercased())
    }

    static func defaultCurrency(for symbol: String) -> String {
        isUKSymbol(symbol) ? "GBP" : "USD"
    }

    static func defaultTimezone(for symbol: String) -> String {
        isUKSymbol(symbol) ? "Europe/London" : "America/New_York"
    }

    static func normalizeCurrency(_ currency: String?) -> String? {
        guard let raw = currency?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if raw == "GBp" || raw == "GBX" {
            return "GBP"
        }

        return raw.uppercased()
    }

    /// Human-readable market for the popover subtitle, derived from the
    /// provider suffix. Unknown suffixes fall back to a generic label.
    static func exchangeDisplayName(for symbol: String) -> String {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if isBenchmarkSymbol(upper) || upper.hasPrefix("^") { return "Index" }
        if isUKSymbol(upper) { return "London Stock Exchange" }
        if upper.hasSuffix("-USD") || upper.hasSuffix("-GBP") || upper.hasSuffix("-EUR") { return "Crypto" }
        guard let dot = upper.lastIndex(of: ".") else { return "US Market" }
        switch upper[upper.index(after: dot)...] {
        case "TO", "V": return "Toronto Stock Exchange"
        case "AX": return "ASX"
        case "DE", "F": return "Deutsche Börse"
        case "PA": return "Euronext Paris"
        case "AS": return "Euronext Amsterdam"
        case "MI": return "Borsa Italiana"
        case "SW": return "SIX Swiss Exchange"
        case "T": return "Tokyo Stock Exchange"
        case "HK": return "Hong Kong Exchange"
        default: return "Market"
        }
    }
}
