import Foundation

struct InstrumentResolver {
    func resolveLegacySymbol(_ symbol: String, displayName: String? = nil, currency: String? = nil) -> InstrumentResolutionResult {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            return InstrumentResolutionResult(identity: nil, confidence: .unresolved, warnings: ["Symbol is empty."])
        }

        if let base = londonBaseSymbol(from: normalized) {
            var warnings: [String] = []
            if normalized.hasSuffix(".XC") {
                warnings.append("Resolved by local legacy .XC UK suffix rule.")
            }
            return InstrumentResolutionResult(
                identity: makeIdentity(
                    exchange: "LSE",
                    displaySymbol: base,
                    displayName: displayName,
                    currency: "GBP",
                    isin: nil,
                    trading212Symbol: nil,
                    legacySymbols: [symbol]
                ),
                confidence: .high,
                warnings: warnings
            )
        }

        let normalizedCurrency = SymbolMetadata.normalizeCurrency(currency)
        if normalizedCurrency == "GBP" || normalizedCurrency == "GBX" {
            return InstrumentResolutionResult(
                identity: makeIdentity(
                    exchange: "LSE",
                    displaySymbol: normalized,
                    displayName: displayName,
                    currency: "GBP",
                    isin: nil,
                    trading212Symbol: nil,
                    legacySymbols: [symbol]
                ),
                confidence: .medium,
                warnings: ["Bare symbol inferred as LSE from GBP/GBX currency."]
            )
        }

        if normalizedCurrency == "USD" {
            return InstrumentResolutionResult(
                identity: makeIdentity(
                    exchange: "US",
                    displaySymbol: normalized,
                    displayName: displayName,
                    currency: "USD",
                    isin: nil,
                    trading212Symbol: nil,
                    legacySymbols: [symbol]
                ),
                confidence: .medium,
                warnings: ["Bare symbol kept as US market identity until exchange metadata is known."]
            )
        }

        return InstrumentResolutionResult(
            identity: nil,
            confidence: .unresolved,
            warnings: ["Bare symbol requires exchange or currency metadata."]
        )
    }

    func resolveTrading212Position(
        _ position: Trading212Position,
        metadata: Trading212InstrumentMetadata?,
        exchangeName: String?
    ) -> InstrumentResolutionResult {
        let providerTicker = position.instrument.ticker
        let displaySymbol = displaySymbol(fromTrading212Ticker: providerTicker, metadata: metadata)
        let currency = SymbolMetadata.normalizeCurrency(metadata?.currencyCode ?? position.instrument.currency)
        let name = metadata?.name ?? position.instrument.name
        let isin = metadata?.isin ?? position.instrument.isin
        let exchange = exchangeCode(from: exchangeName, providerTicker: providerTicker, currency: currency)

        guard let resolvedExchange = exchange else {
            return InstrumentResolutionResult(
                identity: nil,
                confidence: .low,
                warnings: ["Trading 212 position lacks enough metadata for a canonical exchange mapping."]
            )
        }

        let confidence: InstrumentResolutionConfidence
        let warnings: [String]
        if exchangeName != nil || metadata?.workingScheduleId != nil {
            confidence = .high
            warnings = []
        } else if resolvedExchange == "LSE", currency == "GBP" {
            confidence = .medium
            warnings = ["Resolved from Trading 212 account-position currency without Metadata permission."]
        } else if resolvedExchange == "US" {
            confidence = .medium
            warnings = ["US instrument unresolved to NASDAQ/NYSE without Metadata exchange detail."]
        } else {
            confidence = .low
            warnings = ["Resolved from limited Trading 212 account-position fields."]
        }

        return InstrumentResolutionResult(
            identity: makeIdentity(
                exchange: resolvedExchange,
                displaySymbol: displaySymbol,
                displayName: name,
                currency: currency,
                isin: isin,
                trading212Symbol: providerTicker,
                legacySymbols: []
            ),
            confidence: confidence,
            warnings: warnings
        )
    }

    private func londonBaseSymbol(from symbol: String) -> String? {
        for suffix in [".LON", ".L", ".XC"] where symbol.hasSuffix(suffix) {
            return String(symbol.dropLast(suffix.count))
        }
        return nil
    }

    private func displaySymbol(fromTrading212Ticker ticker: String, metadata: Trading212InstrumentMetadata?) -> String {
        if let metadataSymbol = normalizedMetadataSymbol(metadata?.shortName) {
            return metadataSymbol
        }

        let trimmed = ticker.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.components(separatedBy: "_").first ?? trimmed
        let venueStrippedBase: String
        if let last = base.unicodeScalars.last,
           CharacterSet.lowercaseLetters.contains(last),
           base.dropLast().contains(where: { $0.isLetter || $0.isNumber }) {
            venueStrippedBase = String(base.dropLast())
        } else {
            venueStrippedBase = base
        }
        return normalizeSymbolToken(venueStrippedBase.uppercased())
    }

    private func normalizedMetadataSymbol(_ symbol: String?) -> String? {
        guard let symbol else {
            return nil
        }
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == trimmed.uppercased() else {
            return nil
        }

        let normalized = normalizeSymbolToken(trimmed)
        guard !normalized.isEmpty,
              normalized.count <= 12,
              normalized.contains(where: { $0.isLetter }) else {
            return nil
        }
        return normalized
    }

    private func normalizeSymbolToken(_ symbol: String) -> String {
        symbol
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: " ", with: "")
    }

    private func exchangeCode(from exchangeName: String?, providerTicker: String, currency: String?) -> String? {
        let upperName = exchangeName?.uppercased() ?? ""
        let upperTicker = providerTicker.uppercased()

        if upperName.contains("LONDON") || upperName.contains("LSE") || upperName.contains("XLON") {
            return "LSE"
        }
        if upperName.contains("NASDAQ") {
            return "NASDAQ"
        }
        if upperName.contains("NEW YORK") || upperName.contains("NYSE") {
            return "NYSE"
        }
        if upperTicker.contains("_GB_") || currency == "GBP" || currency == "GBX" {
            return "LSE"
        }
        if upperTicker.contains("_US_") || currency == "USD" {
            return "US"
        }
        return nil
    }

    private func makeIdentity(
        exchange: String,
        displaySymbol: String,
        displayName: String?,
        currency: String?,
        isin: String?,
        trading212Symbol: String?,
        legacySymbols: [String]
    ) -> InstrumentIdentity {
        let normalizedSymbol = displaySymbol.uppercased()
        var providerSymbols: [String: String] = [:]

        if exchange == "LSE" {
            providerSymbols["yfinance"] = "\(normalizedSymbol).L"
            providerSymbols["fmp"] = "\(normalizedSymbol).L"
            providerSymbols["stooq"] = "\(normalizedSymbol).UK"
        } else {
            providerSymbols["yfinance"] = normalizedSymbol
            providerSymbols["fmp"] = normalizedSymbol
        }

        if let trading212Symbol {
            providerSymbols["trading212"] = trading212Symbol
        }

        return InstrumentIdentity(
            instrumentId: "\(exchange):\(normalizedSymbol)",
            displaySymbol: normalizedSymbol,
            displayName: displayName,
            exchange: exchange,
            currency: currency,
            isin: isin,
            providerSymbols: providerSymbols,
            legacySymbols: legacySymbols
        )
    }
}
