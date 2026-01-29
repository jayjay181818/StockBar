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
}
