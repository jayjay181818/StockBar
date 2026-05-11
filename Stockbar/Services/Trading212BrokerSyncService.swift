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
        return "Synced \(updatedCount) linked holdings. Deleted \(deletedCount). Missing \(missingCount). Broker-only \(brokerOnlyCount)."
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

        return Trading212BrokerSyncPlan(
            tradeUpdates: updates,
            deletedManualSymbols: deletedSymbols,
            deletedLinkIDs: deletedLinkIDs,
            missingLinkedSymbols: missingSymbols,
            brokerOnlyCount: brokerOnlyCount
        )
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
        guard let rawPrice = row.brokerProvidedPrice, rawPrice.isFinite, rawPrice > 0 else {
            return nil
        }

        if isPencePriced(row: row, link: link) {
            return (rawPrice / 100.0, "GBP")
        }

        let currency = normalizedManualCurrency(link.manualCurrency)
            ?? (link.instrumentId.hasPrefix("LSE:") ? "GBP" : "USD")
        return (rawPrice, currency == "GBX" ? "GBP" : currency)
    }

    private func normalizedBrokerAveragePrice(
        row: Trading212ImportPreviewRow,
        link: BrokerLinkedPosition
    ) -> (amount: Double, currency: String)? {
        guard let rawAveragePrice = row.averagePrice, rawAveragePrice.isFinite, rawAveragePrice > 0 else {
            return nil
        }

        if isPencePriced(row: row, link: link) {
            return (rawAveragePrice / 100.0, "GBP")
        }

        let currency = normalizedManualCurrency(link.manualCurrency)
            ?? (link.instrumentId.hasPrefix("LSE:") ? "GBP" : "USD")
        return (rawAveragePrice, currency == "GBX" ? "GBP" : currency)
    }

    private func isPencePriced(row: Trading212ImportPreviewRow, link: BrokerLinkedPosition) -> Bool {
        if normalizedManualCurrency(link.manualCurrency) == "GBX" {
            return true
        }
        guard link.instrumentId.hasPrefix("LSE:"),
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

    private func normalizedManualCurrency(_ currency: String?) -> String? {
        guard let currency = currency?.trimmingCharacters(in: .whitespacesAndNewlines), !currency.isEmpty else {
            return nil
        }
        return currency.uppercased()
    }

    private func format(_ value: Double) -> String {
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
}
