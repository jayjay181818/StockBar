import XCTest
@testable import Stockbar

final class Trading212BrokerSyncTests: XCTestCase {
    func testUpdatesLinkedManualHoldingWithBrokerQuantityCostAndPrice() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 200)
        let link = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let existingTrade = Trade(
            name: "AV.L",
            position: Position(unitSize: "500", positionAvgCost: "486.26", currency: "GBX", costCurrency: "GBX")
        )
        let preview = makePreview(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            quantity: 525,
            averagePrice: 490.5,
            brokerPrice: 640.0,
            currentValue: 3360.0
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [existingTrade],
            tradingInfoBySymbol: ["AV.L": TradingInfo()],
            links: snapshot,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: false),
            syncedAt: now
        )

        XCTAssertEqual(plan.tradeUpdates.count, 1)
        let update = try XCTUnwrap(plan.tradeUpdates.first)
        XCTAssertEqual(update.trade.name, "AV.L")
        XCTAssertEqual(update.trade.position.unitSizeString, "525")
        XCTAssertEqual(update.trade.position.positionAvgCostString, "4.905")
        XCTAssertEqual(update.trade.position.costCurrency, "GBP")
        XCTAssertEqual(update.tradingInfo.currentPrice, 6.4, accuracy: 0.0001)
        XCTAssertEqual(update.tradingInfo.currency, "GBP")
        XCTAssertEqual(update.tradingInfo.shortName, "Aviva")
        XCTAssertEqual(update.tradingInfo.lastUpdateTime, Int(now.timeIntervalSince1970))
        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
    }

    func testLinkedSyncPlanCarriesBrokerValuationSnapshotFromAccountSummary() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 200)
        let link = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBP",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let existingTrade = Trade(
            name: "AV.L",
            position: Position(unitSize: "500", positionAvgCost: "4.8626", currency: "GBP", costCurrency: "GBP")
        )
        let row = makePreview(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            quantity: 500,
            averagePrice: 486.28,
            brokerPrice: 619.80,
            currentValue: 3_099.00
        ).rows[0]
        let preview = makePreview(
            rows: [row],
            accountSummary: Trading212AccountSummary(
                cash: Trading212Cash(availableToTrade: 1.39, inPies: nil, reservedForOrders: nil),
                currency: "GBP",
                id: 123,
                investments: Trading212Investments(
                    currentValue: 171_343.22,
                    realizedProfitLoss: nil,
                    totalCost: 91_066.02,
                    unrealizedProfitLoss: 80_277.20
                ),
                totalValue: 171_344.61
            )
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [existingTrade],
            tradingInfoBySymbol: ["AV.L": TradingInfo()],
            links: snapshot,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: false),
            syncedAt: now
        )

        let valuation = try XCTUnwrap(plan.valuationSnapshot)
        XCTAssertEqual(valuation.accountValue, 171_344.61, accuracy: 0.01)
        XCTAssertEqual(valuation.investmentsValue ?? .nan, 171_343.22, accuracy: 0.01)
        XCTAssertEqual(valuation.cashValue ?? .nan, 1.39, accuracy: 0.01)
        XCTAssertEqual(valuation.totalUnrealizedProfitLoss ?? .nan, 80_277.20, accuracy: 0.01)
        XCTAssertEqual(valuation.totalCost ?? .nan, 91_066.02, accuracy: 0.01)
        let position = try XCTUnwrap(valuation.position(for: "AV.L"))
        XCTAssertEqual(position.brokerCurrentValue, 3_099.00, accuracy: 0.01)
        XCTAssertEqual(position.brokerUnrealizedProfitLoss ?? .nan, 150, accuracy: 0.01)
        XCTAssertEqual(position.currency, "GBP")
    }

    func testDeletesLinkedHoldingAndLinkWhenBrokerPositionIsMissingAndDeletionEnabled() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let existingTrade = Trade(
            name: "AV.L",
            position: Position(unitSize: "500", positionAvgCost: "486.26", currency: "GBX", costCurrency: "GBX")
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [existingTrade],
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: makePreview(rows: []),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(plan.deletedManualSymbols, ["AV.L"])
        XCTAssertEqual(plan.deletedLinkIDs, [link.id])
        XCTAssertTrue(plan.tradeUpdates.isEmpty)
        XCTAssertTrue(plan.missingLinkedSymbols.isEmpty)
    }

    func testMissingBrokerPositionIsReportedButNotDeletedWhenDeletionDisabled() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [
                Trade(name: "AV.L", position: Position(unitSize: "500", positionAvgCost: "486.26")),
                Trade(name: "GOOGL", position: Position(unitSize: "10", positionAvgCost: "171.25"))
            ],
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: makePreview(rows: []),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: false),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
        XCTAssertTrue(plan.deletedLinkIDs.isEmpty)
        XCTAssertEqual(plan.missingLinkedSymbols, ["AV.L"])
    }

    func testProviderTickerFallbackPreventsFalseDeletionWhenMetadataIsSkipped() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "US:HIMS",
            providerTicker: "OAC_US_EQ",
            manualSymbol: "HIMS",
            manualCurrency: "USD",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let row = Trading212ImportPreviewRow(
            id: "Trading212|live|isa|hash|credential|account|US:OAC",
            account: makeAccount(),
            providerTicker: "OAC_US_EQ",
            instrumentId: "US:OAC",
            displaySymbol: "OAC",
            displayName: "Oscar Health",
            quantity: 50,
            averagePrice: 46.47,
            brokerProvidedPrice: 29.07,
            currentValue: 1_065.62,
            totalCost: 1_710.90,
            unrealizedProfitLoss: -645.28,
            fxImpact: nil,
            mappingConfidence: .medium,
            manualMatch: nil,
            additionalManualMatchCount: 0,
            conflictStatus: .none,
            valueSource: .brokerProvidedLivePositionData,
            warnings: ["US instrument unresolved to NASDAQ/NYSE without Metadata exchange detail."]
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [
                Trade(name: "HIMS", position: Position(unitSize: "50", positionAvgCost: "46.47", currency: "USD"))
            ],
            tradingInfoBySymbol: ["HIMS": TradingInfo()],
            links: snapshot,
            preview: makePreview(rows: [row]),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(plan.tradeUpdates.count, 1)
        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
        XCTAssertTrue(plan.deletedLinkIDs.isEmpty)
        XCTAssertEqual(plan.brokerOnlyCount, 0)
    }

    func testPencePricedLSEBrokerSyncNormalizesAverageCostWhenLinkedHoldingUsesGBP() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 200)
        let link = makeLink(
            instrumentId: "LSE:TW",
            providerTicker: "TWI_EQ",
            manualSymbol: "TW.L",
            manualCurrency: "GBP",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let existingTrade = Trade(
            name: "TW.L",
            position: Position(unitSize: "10000", positionAvgCost: "109.03", currency: "GBP", costCurrency: "GBP")
        )
        let preview = makePreview(
            instrumentId: "LSE:TW",
            providerTicker: "TWI_EQ",
            manualSymbol: "TW.L",
            quantity: 10000,
            averagePrice: 109.02634,
            brokerPrice: 82.82,
            currentValue: 8282.0
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [existingTrade],
            tradingInfoBySymbol: ["TW.L": TradingInfo()],
            links: snapshot,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: false),
            syncedAt: now
        )

        let update = try XCTUnwrap(plan.tradeUpdates.first)
        XCTAssertEqual(update.trade.position.positionAvgCostString, "1.0902634")
        XCTAssertEqual(update.trade.position.costCurrency, "GBP")
        XCTAssertEqual(update.tradingInfo.currentPrice, 0.8282, accuracy: 0.000001)

        let service = PortfolioCalculationService(currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false))
        let gains = service.calculateNetGains(
            trades: [RealTimeTrade(trade: update.trade, realTimeInfo: update.tradingInfo)],
            preferredCurrency: "GBP"
        )
        XCTAssertEqual(gains.amount, -2620.634, accuracy: 0.01)
    }

    func testTrading212SyncSettingsDefaultToThirtySecondAutoSync() {
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = Trading212SettingsStore(defaults: defaults).load()

        XCTAssertTrue(settings.autoSyncEnabled)
        XCTAssertEqual(settings.syncIntervalSeconds, 30)
    }

    func testTrading212SettingsDefaultToManualHoldingReconciliation() {
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = Trading212SettingsStore(defaults: defaults).load()

        XCTAssertFalse(settings.autoReconcileHoldingsEnabled)
        XCTAssertFalse(settings.autoImportBrokerOnlyHoldings)
        XCTAssertEqual(settings.holdingReconciliationIntervalSeconds, 3_600)
    }

    func testTrading212SettingsStorePersistsHourlyHoldingReconciliation() {
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = Trading212SettingsStore(defaults: defaults)

        var settings = Trading212StoredSettings.defaults
        settings.autoReconcileHoldingsEnabled = true
        settings.autoImportBrokerOnlyHoldings = true
        settings.holdingReconciliationIntervalSeconds = 3_600
        store.save(settings)

        let reloaded = store.load()
        XCTAssertTrue(reloaded.autoReconcileHoldingsEnabled)
        XCTAssertTrue(reloaded.autoImportBrokerOnlyHoldings)
        XCTAssertEqual(reloaded.holdingReconciliationIntervalSeconds, 3_600)
    }

    func testTrading212SettingsStoreIgnoresLegacyMinuteIntervalForBrokerSyncDefault() {
        let defaults = UserDefaults(suiteName: "Trading212SyncSettingsTests.\(UUID().uuidString)")!
        defaults.set(5, forKey: "trading212.syncIntervalMinutes")
        let settings = Trading212SettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.syncIntervalSeconds, 30)
    }

    func testLinkedBrokerHoldingAllowsMarketRefreshDuringUSPreMarket() {
        let preMarket = makeDate(year: 2026, month: 5, day: 13, hour: 8, minute: 0, timeZone: "America/New_York")

        let shouldSkip = BrokerLinkedMarketDataRefreshPolicy.shouldSkipMarketRefresh(
            symbol: "MU",
            tradingInfo: TradingInfo(),
            now: preMarket
        )

        XCTAssertFalse(shouldSkip)
    }

    func testLinkedBrokerHoldingAllowsMarketRefreshDuringUSPostMarket() {
        let postMarket = makeDate(year: 2026, month: 5, day: 13, hour: 17, minute: 0, timeZone: "America/New_York")

        let shouldSkip = BrokerLinkedMarketDataRefreshPolicy.shouldSkipMarketRefresh(
            symbol: "MU",
            tradingInfo: TradingInfo(),
            now: postMarket
        )

        XCTAssertFalse(shouldSkip)
    }

    func testLinkedBrokerHoldingSkipsMarketRefreshDuringRegularSession() {
        let regularSession = makeDate(year: 2026, month: 5, day: 13, hour: 10, minute: 0, timeZone: "America/New_York")

        let shouldSkip = BrokerLinkedMarketDataRefreshPolicy.shouldSkipMarketRefresh(
            symbol: "MU",
            tradingInfo: TradingInfo(),
            now: regularSession
        )

        XCTAssertTrue(shouldSkip)
    }

    func testBrokerOnlyImportPlannerCreatesLSEHoldingAndLinkWithPenceNormalization() throws {
        let importedAt = Date(timeIntervalSince1970: 300)
        let row = makeBrokerOnlyRow(
            instrumentId: "LSE:COPG",
            providerTicker: "COPGl_EQ",
            displaySymbol: "COPG",
            displayName: "Global X Copper Miners",
            quantity: 80.89145669,
            averagePrice: 4_940.8,
            brokerPrice: 4_893.6,
            currentValue: 3_958.50
        )

        let plan = Trading212BrokerOnlyImportPlanner().plan(
            existingTrades: [],
            preview: makePreview(rows: [row]),
            importedAt: importedAt
        )

        XCTAssertEqual(plan.importedCount, 1)
        XCTAssertTrue(plan.skippedRows.isEmpty)
        let record = try XCTUnwrap(plan.records.first)
        XCTAssertEqual(record.manualSymbol, "COPG.L")
        XCTAssertEqual(record.trade.name, "COPG.L")
        XCTAssertEqual(record.trade.position.unitSizeString, "80.89145669")
        XCTAssertEqual(record.trade.position.positionAvgCostString, "49.408")
        XCTAssertEqual(record.trade.position.currency, "GBP")
        XCTAssertEqual(record.trade.position.costCurrency, "GBP")
        XCTAssertEqual(record.tradingInfo.currentPrice, 48.936, accuracy: 0.0001)
        XCTAssertEqual(record.tradingInfo.currency, "GBP")
        XCTAssertEqual(record.linkedPosition.instrumentId, "LSE:COPG")
        XCTAssertEqual(record.linkedPosition.providerTicker, "COPGl_EQ")
        XCTAssertEqual(record.linkedPosition.manualSymbol, "COPG.L")
    }

    func testBrokerOnlyImportPlannerSkipsDuplicateManualSymbol() {
        let row = makeBrokerOnlyRow(
            instrumentId: "US:HIMS",
            providerTicker: "OAC_US_EQ",
            displaySymbol: "HIMS",
            displayName: "Hims & Hers Health",
            quantity: 25,
            averagePrice: 42,
            brokerPrice: 50,
            currentValue: 1_250
        )

        let plan = Trading212BrokerOnlyImportPlanner().plan(
            existingTrades: [
                Trade(name: "HIMS", position: Position(unitSize: "50", positionAvgCost: "46.47", currency: "USD"))
            ],
            preview: makePreview(rows: [row]),
            importedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(plan.records.isEmpty)
        XCTAssertEqual(plan.skippedRows, ["OAC_US_EQ: HIMS already exists"])
    }

    func testLinkMatchedHoldingsAllowsBrokerOnlyRowsInSamePreview() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broker-link-tests-\(UUID().uuidString)")
            .appendingPathComponent("broker_links.json")
        let store = BrokerLinkStore(fileURL: fileURL)
        let matched = makePreview(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            quantity: 500,
            averagePrice: 486.26,
            brokerPrice: 620,
            currentValue: 3_100
        ).rows[0]
        let brokerOnly = makeBrokerOnlyRow(
            instrumentId: "US:HIMS",
            providerTicker: "OAC_US_EQ",
            displaySymbol: "HIMS",
            displayName: "Hims & Hers Health",
            quantity: 25,
            averagePrice: 42,
            brokerPrice: 50,
            currentValue: 1_250
        )
        let preview = makePreview(rows: [matched, brokerOnly])

        let result = try await store.linkMatchedHoldings(from: preview, linkedAt: Date(timeIntervalSince1970: 400))
        let snapshot = try await store.loadSnapshot()

        XCTAssertEqual(result.linkedCount, 1)
        XCTAssertEqual(snapshot.positions.map(\.manualSymbol), ["AV.L"])
    }

    private func makeLinkedAccount(linkedAt: Date) -> BrokerLinkedAccount {
        BrokerLinkedAccount(
            brokerAccountKey: "Trading212|live|isa|hash|credential|account",
            broker: "Trading212",
            accountLabel: "Trading 212 ISA",
            accountType: .stocksAndSharesISA,
            taxWrapper: "ISA",
            environment: .live,
            linkedAt: linkedAt,
            updatedAt: linkedAt
        )
    }

    private func makeLink(
        instrumentId: String,
        providerTicker: String,
        manualSymbol: String,
        manualCurrency: String,
        linkedAt: Date
    ) -> BrokerLinkedPosition {
        BrokerLinkedPosition(
            brokerAccountKey: "Trading212|live|isa|hash|credential|account",
            instrumentId: instrumentId,
            displaySymbol: "AV",
            displayName: "Aviva",
            providerTicker: providerTicker,
            manualSymbol: manualSymbol,
            manualQuantityAtLink: 500,
            brokerQuantityAtLink: 500,
            manualAverageCostAtLink: 486.26,
            manualCurrency: manualCurrency,
            linkedAt: linkedAt,
            updatedAt: linkedAt
        )
    }

    private func makePreview(
        instrumentId: String,
        providerTicker: String,
        manualSymbol: String,
        quantity: Double,
        averagePrice: Double,
        brokerPrice: Double,
        currentValue: Double
    ) -> Trading212ImportPreview {
        let row = Trading212ImportPreviewRow(
            id: "Trading212|live|isa|hash|credential|account|\(instrumentId)",
            account: makeAccount(),
            providerTicker: providerTicker,
            instrumentId: instrumentId,
            displaySymbol: "AV",
            displayName: "Aviva",
            quantity: quantity,
            averagePrice: averagePrice,
            brokerProvidedPrice: brokerPrice,
            currentValue: currentValue,
            totalCost: currentValue - 150,
            unrealizedProfitLoss: 150,
            fxImpact: nil,
            mappingConfidence: .high,
            manualMatch: Trading212ManualHoldingMatch(
                symbol: manualSymbol,
                instrumentId: instrumentId,
                displayName: "Aviva",
                quantity: quantity,
                averageCost: averagePrice,
                currency: "GBX",
                isWatchlistOnly: false,
                resolutionConfidence: .high
            ),
            additionalManualMatchCount: 0,
            conflictStatus: .manualHoldingMatch,
            valueSource: .brokerProvidedLivePositionData,
            warnings: []
        )
        return makePreview(rows: [row])
    }

    private func makePreview(
        rows: [Trading212ImportPreviewRow],
        accountSummary: Trading212AccountSummary? = nil
    ) -> Trading212ImportPreview {
        Trading212ImportPreview(
            account: makeAccount(),
            accountSummary: accountSummary,
            rows: rows,
            metadataAvailable: true,
            generatedAt: Date(timeIntervalSince1970: 200),
            warnings: []
        )
    }

    private func makeBrokerOnlyRow(
        instrumentId: String,
        providerTicker: String,
        displaySymbol: String,
        displayName: String,
        quantity: Double,
        averagePrice: Double,
        brokerPrice: Double,
        currentValue: Double
    ) -> Trading212ImportPreviewRow {
        Trading212ImportPreviewRow(
            id: "Trading212|live|isa|hash|credential|account|\(instrumentId)",
            account: makeAccount(),
            providerTicker: providerTicker,
            instrumentId: instrumentId,
            displaySymbol: displaySymbol,
            displayName: displayName,
            quantity: quantity,
            averagePrice: averagePrice,
            brokerProvidedPrice: brokerPrice,
            currentValue: currentValue,
            totalCost: nil,
            unrealizedProfitLoss: nil,
            fxImpact: nil,
            mappingConfidence: .high,
            manualMatch: nil,
            additionalManualMatchCount: 0,
            conflictStatus: .none,
            valueSource: .brokerProvidedLivePositionData,
            warnings: []
        )
    }

    private func makeAccount() -> BrokerAccountIdentity {
        BrokerAccountIdentity(
            broker: "Trading212",
            brokerAccountKey: "Trading212|live|isa|hash|credential|account",
            apiAccountIdHash: nil,
            accountLabel: "Trading 212 ISA",
            accountType: .stocksAndSharesISA,
            taxWrapper: "ISA",
            environment: .live,
            credentialFingerprint: "credential"
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        timeZone: String
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
