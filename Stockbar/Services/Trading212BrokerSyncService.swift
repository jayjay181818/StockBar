import Foundation

struct Trading212BrokerSyncOptions: Equatable {
    let deleteMissingLinkedHoldings: Bool
}

struct Trading212BrokerTradeUpdate {
    let manualSymbol: String
    let trade: Trade
    let tradingInfo: TradingInfo
}

struct Trading212BrokerSyncPlan {
    let tradeUpdates: [Trading212BrokerTradeUpdate]
    let deletedManualSymbols: [String]
    let deletedLinkIDs: [String]
    let missingLinkedSymbols: [String]
    let brokerOnlyCount: Int
    let valuationSnapshot: Trading212BrokerValuationSnapshot?

    var changedCount: Int {
        tradeUpdates.count + deletedManualSymbols.count
    }
}

struct Trading212BrokerSyncResult: Equatable {
    let updatedCount: Int
    let deletedCount: Int
    let missingCount: Int
    let brokerOnlyCount: Int
    let skippedReason: String?

    var userMessage: String {
        if let skippedReason {
            return skippedReason
        }
        var message = "Synced \(updatedCount) linked holdings. Deleted \(deletedCount). Missing \(missingCount). Broker-only \(brokerOnlyCount)."
        if brokerOnlyCount > 0 {
            message += " Run Preview Import to import or link new Trading 212 holdings."
        }
        return message
    }
}

struct Trading212HoldingReconciliationResult: Equatable {
    let syncedCount: Int
    let importedCount: Int
    let deletedCount: Int
    let missingCount: Int
    let brokerOnlyCount: Int
    let skippedReason: String?

    var userMessage: String {
        if let skippedReason {
            return skippedReason
        }
        return "Reconciled Trading 212 holdings hourly. Synced \(syncedCount). Imported \(importedCount). Deleted \(deletedCount). Missing \(missingCount). Broker-only \(brokerOnlyCount)."
    }
}

struct Trading212BrokerOnlyImportRecord {
    let manualSymbol: String
    let trade: Trade
    let tradingInfo: TradingInfo
    let linkedPosition: BrokerLinkedPosition
}

struct Trading212BrokerOnlyImportPlan {
    let records: [Trading212BrokerOnlyImportRecord]
    let skippedRows: [String]

    var importedCount: Int { records.count }
    var skippedCount: Int { skippedRows.count }
}

struct Trading212BrokerOnlyImportResult: Equatable {
    let importedCount: Int
    let linkedCount: Int
    let skippedCount: Int
    let importedSymbols: [String]
    let skippedRows: [String]

    var userMessage: String {
        guard importedCount > 0 else {
            if skippedCount > 0 {
                return "No broker-only holdings were imported. \(skippedCount) row(s) need review before import."
            }
            return "No broker-only Trading 212 holdings were available to import."
        }
        let symbols = importedSymbols.joined(separator: ", ")
        var message = "Imported \(importedCount) broker-only Trading 212 holding"
        message += importedCount == 1 ? "" : "s"
        message += " and saved \(linkedCount) broker link"
        message += linkedCount == 1 ? "" : "s"
        message += symbols.isEmpty ? "." : ": \(symbols)."
        if skippedCount > 0 {
            message += " \(skippedCount) row(s) still need review."
        }
        return message
    }
}

struct Trading212BrokerOnlyImportPlanner {
    func plan(
        existingTrades: [Trade],
        preview: Trading212ImportPreview,
        importedAt: Date = Date()
    ) -> Trading212BrokerOnlyImportPlan {
        let existingSymbols = Set(existingTrades.map { $0.name.uppercased() })
        var plannedSymbols = Set<String>()
        var records: [Trading212BrokerOnlyImportRecord] = []
        var skippedRows: [String] = []

        for row in preview.rows where row.conflictStatus == .none {
            guard let instrumentId = row.instrumentId else {
                skippedRows.append("\(row.providerTicker): unresolved instrument")
                continue
            }
            guard let quantity = row.quantity, quantity > 0 else {
                skippedRows.append("\(row.providerTicker): no positive quantity")
                continue
            }
            let manualSymbol = manualSymbol(for: instrumentId, fallback: row.displaySymbol)
            let symbolKey = manualSymbol.uppercased()
            guard !existingSymbols.contains(symbolKey), !plannedSymbols.contains(symbolKey) else {
                skippedRows.append("\(row.providerTicker): \(manualSymbol) already exists")
                continue
            }

            let price = Trading212BrokerValueNormalizer.normalizedBrokerPrice(row: row, instrumentId: instrumentId, manualCurrency: nil)
            let average = Trading212BrokerValueNormalizer.normalizedBrokerAveragePrice(row: row, instrumentId: instrumentId, manualCurrency: nil)
            let positionCurrency = average?.currency
                ?? price?.currency
                ?? defaultCurrency(for: instrumentId)

            let trade = Trade(
                name: manualSymbol,
                position: Position(
                    unitSize: Trading212BrokerValueNormalizer.format(quantity),
                    positionAvgCost: Trading212BrokerValueNormalizer.format(average?.amount ?? 0),
                    currency: positionCurrency,
                    costCurrency: positionCurrency
                )
            )

            var tradingInfo = TradingInfo()
            tradingInfo.shortName = row.displayName ?? row.displaySymbol
            tradingInfo.currency = price?.currency ?? positionCurrency
            if let price {
                tradingInfo.currentPrice = price.amount
                tradingInfo.previousClose = price.amount
                tradingInfo.prevClosePrice = price.amount
            }
            let timestamp = Int(importedAt.timeIntervalSince1970)
            tradingInfo.lastUpdateTime = timestamp
            tradingInfo.regularMarketTime = timestamp

            let linkedPosition = BrokerLinkedPosition(
                brokerAccountKey: row.account.brokerAccountKey,
                instrumentId: instrumentId,
                displaySymbol: row.displaySymbol,
                displayName: row.displayName,
                providerTicker: row.providerTicker,
                manualSymbol: manualSymbol,
                manualQuantityAtLink: quantity,
                brokerQuantityAtLink: quantity,
                manualAverageCostAtLink: average?.amount,
                manualCurrency: positionCurrency,
                linkedAt: importedAt,
                updatedAt: importedAt
            )

            records.append(Trading212BrokerOnlyImportRecord(
                manualSymbol: manualSymbol,
                trade: trade,
                tradingInfo: tradingInfo,
                linkedPosition: linkedPosition
            ))
            plannedSymbols.insert(symbolKey)
        }

        return Trading212BrokerOnlyImportPlan(records: records, skippedRows: skippedRows)
    }

    private func manualSymbol(for instrumentId: String, fallback: String) -> String {
        let parts = instrumentId.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return fallback.uppercased()
        }
        let exchange = parts[0].uppercased()
        let symbol = parts[1].uppercased()
        switch exchange {
        case "LSE":
            return "\(symbol).L"
        case "US", "NASDAQ", "NYSE", "AMEX":
            return symbol
        default:
            return fallback.uppercased()
        }
    }

    private func defaultCurrency(for instrumentId: String) -> String {
        instrumentId.uppercased().hasPrefix("LSE:") ? "GBP" : "USD"
    }
}

enum Trading212BrokerValueNormalizer {
    static func normalizedBrokerPrice(
        row: Trading212ImportPreviewRow,
        instrumentId: String,
        manualCurrency: String?
    ) -> (amount: Double, currency: String)? {
        guard let rawPrice = row.brokerProvidedPrice, rawPrice.isFinite, rawPrice > 0 else {
            return nil
        }

        if isPencePriced(row: row, instrumentId: instrumentId, manualCurrency: manualCurrency) {
            return (rawPrice / 100.0, "GBP")
        }

        let currency = normalizedCurrency(manualCurrency)
            ?? (instrumentId.hasPrefix("LSE:") ? "GBP" : "USD")
        return (rawPrice, currency == "GBX" ? "GBP" : currency)
    }

    static func normalizedBrokerAveragePrice(
        row: Trading212ImportPreviewRow,
        instrumentId: String,
        manualCurrency: String?
    ) -> (amount: Double, currency: String)? {
        guard let rawAveragePrice = row.averagePrice, rawAveragePrice.isFinite, rawAveragePrice > 0 else {
            return nil
        }

        if isPencePriced(row: row, instrumentId: instrumentId, manualCurrency: manualCurrency) {
            return (rawAveragePrice / 100.0, "GBP")
        }

        let currency = normalizedCurrency(manualCurrency)
            ?? (instrumentId.hasPrefix("LSE:") ? "GBP" : "USD")
        return (rawAveragePrice, currency == "GBX" ? "GBP" : currency)
    }

    static func normalizedCurrency(_ currency: String?) -> String? {
        guard let currency = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !currency.isEmpty else {
            return nil
        }
        return currency.uppercased()
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        var text = String(format: "%.8f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private static func isPencePriced(
        row: Trading212ImportPreviewRow,
        instrumentId: String,
        manualCurrency: String?
    ) -> Bool {
        if normalizedCurrency(manualCurrency) == "GBX" {
            return true
        }
        guard instrumentId.hasPrefix("LSE:"),
              let price = row.brokerProvidedPrice,
              let quantity = row.quantity,
              let currentValue = row.currentValue,
              quantity > 0
        else {
            return false
        }
        let penceValue = price * quantity / 100.0
        let poundValue = price * quantity
        return abs(penceValue - currentValue) < abs(poundValue - currentValue)
    }
}

struct Trading212BrokerSyncPlanner {
    func plan(
        existingTrades: [Trade],
        tradingInfoBySymbol: [String: TradingInfo],
        links: BrokerLinkStoreSnapshot,
        preview: Trading212ImportPreview,
        options: Trading212BrokerSyncOptions,
        syncedAt: Date = Date()
    ) -> Trading212BrokerSyncPlan {
        let linkedPositions = links.positions.filter { $0.brokerAccountKey == preview.account.brokerAccountKey }
        let linkedIDs = Set(linkedPositions.map(\.id))
        let rowsByInstrumentLinkID = Dictionary(uniqueKeysWithValues: preview.rows.compactMap { row -> (String, Trading212ImportPreviewRow)? in
            guard let instrumentId = row.instrumentId else { return nil }
            return ("\(row.account.brokerAccountKey)|\(instrumentId)", row)
        })
        let rowsByProviderTicker = Dictionary(grouping: preview.rows) { row in
            "\(row.account.brokerAccountKey)|\(row.providerTicker.uppercased())"
        }
        let linkedProviderTickerIDs = Set(linkedPositions.map {
            "\($0.brokerAccountKey)|\($0.providerTicker.uppercased())"
        })
        let existingSymbols = Set(existingTrades.map { $0.name.uppercased() })

        var updates: [Trading212BrokerTradeUpdate] = []
        var deletedSymbols: [String] = []
        var deletedLinkIDs: [String] = []
        var missingSymbols: [String] = []

        for link in linkedPositions.sorted(by: { $0.manualSymbol < $1.manualSymbol }) {
            guard existingSymbols.contains(link.manualSymbol.uppercased()) else {
                deletedLinkIDs.append(link.id)
                continue
            }

            let row = rowsByInstrumentLinkID[link.id]
                ?? rowsByProviderTicker["\(link.brokerAccountKey)|\(link.providerTicker.uppercased())"]?.first

            guard let row else {
                if options.deleteMissingLinkedHoldings {
                    deletedSymbols.append(link.manualSymbol)
                    deletedLinkIDs.append(link.id)
                } else {
                    missingSymbols.append(link.manualSymbol)
                }
                continue
            }

            guard let existingTrade = existingTrades.first(where: { $0.name.uppercased() == link.manualSymbol.uppercased() }),
                  let update = makeUpdate(
                    existingTrade: existingTrade,
                    existingInfo: tradingInfoBySymbol[link.manualSymbol.uppercased()] ?? TradingInfo(),
                    link: link,
                    row: row,
                    syncedAt: syncedAt
                  ) else {
                missingSymbols.append(link.manualSymbol)
                continue
            }
            updates.append(update)
        }

        let brokerOnlyCount = preview.rows.filter { row in
            let providerTickerID = "\(row.account.brokerAccountKey)|\(row.providerTicker.uppercased())"
            guard let instrumentId = row.instrumentId else {
                return !linkedProviderTickerIDs.contains(providerTickerID)
            }
            let instrumentLinkID = "\(row.account.brokerAccountKey)|\(instrumentId)"
            return !linkedIDs.contains(instrumentLinkID) && !linkedProviderTickerIDs.contains(providerTickerID)
        }.count
        let valuationSnapshot = makeValuationSnapshot(
            preview: preview,
            linkedPositions: linkedPositions,
            rowsByInstrumentLinkID: rowsByInstrumentLinkID,
            rowsByProviderTicker: rowsByProviderTicker,
            syncedAt: syncedAt
        )

        return Trading212BrokerSyncPlan(
            tradeUpdates: updates,
            deletedManualSymbols: deletedSymbols,
            deletedLinkIDs: deletedLinkIDs,
            missingLinkedSymbols: missingSymbols,
            brokerOnlyCount: brokerOnlyCount,
            valuationSnapshot: valuationSnapshot
        )
    }

    private func makeValuationSnapshot(
        preview: Trading212ImportPreview,
        linkedPositions: [BrokerLinkedPosition],
        rowsByInstrumentLinkID: [String: Trading212ImportPreviewRow],
        rowsByProviderTicker: [String: [Trading212ImportPreviewRow]],
        syncedAt: Date
    ) -> Trading212BrokerValuationSnapshot? {
        guard let accountSummary = preview.accountSummary,
              let currency = Trading212BrokerValueNormalizer.normalizedCurrency(accountSummary.currency) else {
            return nil
        }

        var positionsByManualSymbol: [String: Trading212BrokerPositionValuation] = [:]
        var linkedCurrentValueTotal = 0.0
        var linkedUnrealizedTotal = 0.0
        var linkedTotalCost = 0.0
        var hasLinkedCurrentValue = false
        var hasLinkedUnrealized = false
        var hasLinkedTotalCost = false

        for link in linkedPositions {
            let row = rowsByInstrumentLinkID[link.id]
                ?? rowsByProviderTicker["\(link.brokerAccountKey)|\(link.providerTicker.uppercased())"]?.first
            guard let row,
                  let currentValue = finite(row.currentValue),
                  let instrumentId = row.instrumentId ?? Optional(link.instrumentId) else {
                continue
            }

            let totalCost = finite(row.totalCost)
                ?? finite(row.currentValue.flatMap { currentValue in
                    row.unrealizedProfitLoss.map { currentValue - $0 }
                })
            let unrealizedProfitLoss = finite(row.unrealizedProfitLoss)

            linkedCurrentValueTotal += currentValue
            hasLinkedCurrentValue = true
            if let unrealizedProfitLoss {
                linkedUnrealizedTotal += unrealizedProfitLoss
                hasLinkedUnrealized = true
            }
            if let totalCost {
                linkedTotalCost += totalCost
                hasLinkedTotalCost = true
            }

            positionsByManualSymbol[link.manualSymbol.uppercased()] = Trading212BrokerPositionValuation(
                manualSymbol: link.manualSymbol,
                instrumentId: instrumentId,
                brokerCurrentValue: currentValue,
                brokerTotalCost: totalCost,
                brokerUnrealizedProfitLoss: unrealizedProfitLoss,
                fxImpact: finite(row.fxImpact),
                currency: currency,
                updatedAt: syncedAt
            )
        }

        let cashValue = cashValue(from: accountSummary.cash)
        let investmentsValue = finite(accountSummary.investments?.currentValue)
            ?? (hasLinkedCurrentValue ? linkedCurrentValueTotal : nil)
        let accountValue = finite(accountSummary.totalValue)
            ?? investmentsValue.flatMap { investments in
                (cashValue ?? 0).isFinite ? investments + (cashValue ?? 0) : nil
            }
        guard let accountValue, accountValue.isFinite, accountValue >= 0 else {
            return nil
        }

        return Trading212BrokerValuationSnapshot(
            accountKey: preview.account.brokerAccountKey,
            currency: currency,
            accountValue: accountValue,
            investmentsValue: investmentsValue,
            cashValue: cashValue,
            totalUnrealizedProfitLoss: finite(accountSummary.investments?.unrealizedProfitLoss)
                ?? (hasLinkedUnrealized ? linkedUnrealizedTotal : nil),
            totalCost: finite(accountSummary.investments?.totalCost)
                ?? (hasLinkedTotalCost ? linkedTotalCost : nil),
            positionsByManualSymbol: positionsByManualSymbol,
            updatedAt: syncedAt
        )
    }

    private func cashValue(from cash: Trading212Cash?) -> Double? {
        guard let cash else { return nil }
        let values = [cash.availableToTrade, cash.inPies, cash.reservedForOrders].compactMap(finite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func makeUpdate(
        existingTrade: Trade,
        existingInfo: TradingInfo,
        link: BrokerLinkedPosition,
        row: Trading212ImportPreviewRow,
        syncedAt: Date
    ) -> Trading212BrokerTradeUpdate? {
        guard row.quantity != nil || row.averagePrice != nil || row.brokerProvidedPrice != nil else {
            return nil
        }

        var updatedTrade = existingTrade
        if let quantity = row.quantity {
            updatedTrade.position.unitSizeString = format(quantity)
        }
        var syncedCostCurrency: String?
        if let averagePrice = normalizedBrokerAveragePrice(row: row, link: link) {
            updatedTrade.position.positionAvgCostString = format(averagePrice.amount)
            syncedCostCurrency = averagePrice.currency
        }

        var updatedInfo = existingInfo
        var syncedPriceCurrency: String?
        if let price = normalizedBrokerPrice(row: row, link: link) {
            updatedInfo.currentPrice = price.amount
            updatedInfo.currency = price.currency
            syncedPriceCurrency = price.currency
            if !updatedInfo.prevClosePrice.isFinite || updatedInfo.prevClosePrice <= 0 {
                updatedInfo.prevClosePrice = price.amount
                updatedInfo.previousClose = price.amount
            }
        }
        if let positionCurrency = syncedCostCurrency ?? syncedPriceCurrency ?? normalizedManualCurrency(link.manualCurrency) {
            updatedTrade.position.costCurrency = positionCurrency
            updatedTrade.position.currency = positionCurrency
        }
        updatedInfo.shortName = row.displayName ?? link.displayName ?? existingInfo.shortName
        updatedInfo.lastUpdateTime = Int(syncedAt.timeIntervalSince1970)
        updatedInfo.regularMarketTime = Int(syncedAt.timeIntervalSince1970)

        return Trading212BrokerTradeUpdate(
            manualSymbol: link.manualSymbol,
            trade: updatedTrade,
            tradingInfo: updatedInfo
        )
    }

    private func normalizedBrokerPrice(
        row: Trading212ImportPreviewRow,
        link: BrokerLinkedPosition
    ) -> (amount: Double, currency: String)? {
        Trading212BrokerValueNormalizer.normalizedBrokerPrice(
            row: row,
            instrumentId: link.instrumentId,
            manualCurrency: link.manualCurrency
        )
    }

    private func normalizedBrokerAveragePrice(
        row: Trading212ImportPreviewRow,
        link: BrokerLinkedPosition
    ) -> (amount: Double, currency: String)? {
        Trading212BrokerValueNormalizer.normalizedBrokerAveragePrice(
            row: row,
            instrumentId: link.instrumentId,
            manualCurrency: link.manualCurrency
        )
    }

    private func normalizedManualCurrency(_ currency: String?) -> String? {
        Trading212BrokerValueNormalizer.normalizedCurrency(currency)
    }

    private func format(_ value: Double) -> String {
        Trading212BrokerValueNormalizer.format(value)
    }
}
