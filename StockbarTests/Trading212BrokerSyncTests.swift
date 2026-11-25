import Combine
import CoreData
import XCTest
@testable import Stockbar

final class Trading212BrokerSyncTests: XCTestCase {
    func testFolyncPollingAlignsToMinuteBoundaryAndBoundsCatchUp() {
        let minute = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(FolyncRefreshSchedule.nextRegularCheck(after: minute), minute.addingTimeInterval(5))
        XCTAssertEqual(FolyncRefreshSchedule.nextRegularCheck(after: minute.addingTimeInterval(4)), minute.addingTimeInterval(5))
        XCTAssertEqual(FolyncRefreshSchedule.nextRegularCheck(after: minute.addingTimeInterval(5)), minute.addingTimeInterval(65))
        XCTAssertEqual(FolyncRefreshSchedule.nextRegularCheck(after: minute.addingTimeInterval(47)), minute.addingTimeInterval(65))
        let start = minute.addingTimeInterval(5)
        let end = minute.addingTimeInterval(6)
        XCTAssertTrue(FolyncRefreshSchedule.needsCatchUp(
            providerSyncAt: minute.addingTimeInterval(-59), checkStartedAt: start, completedAt: end
        ))
        for sync in [nil, minute.addingTimeInterval(1), minute.addingTimeInterval(60), minute.addingTimeInterval(-600)] as [Date?] {
            XCTAssertFalse(FolyncRefreshSchedule.needsCatchUp(providerSyncAt: sync, checkStartedAt: start, completedAt: end))
        }
        XCTAssertFalse(FolyncRefreshSchedule.needsCatchUp(
            providerSyncAt: minute.addingTimeInterval(-59), checkStartedAt: start,
            completedAt: minute.addingTimeInterval(58)
        ), "A slow request must not trigger a retry alongside the next regular check")
        XCTAssertEqual(FolyncRefreshSchedule.nextRegularCheck(after: minute.addingTimeInterval(347)), minute.addingTimeInterval(365),
                       "After sleep, use the next minute boundary without replaying missed polls")
    }

    func testDictionaryFirstValuesForKeepsFirstValueInsteadOfTrapping() {
        let values = Dictionary(firstValuesFor: [("AV.L", 1), ("", 2), ("AV.L", 3), ("", 4)])
        XCTAssertEqual(values, ["AV.L": 1, "": 2], "Duplicate symbols (including blank rows) must not crash")
    }

    func testFolyncFailedPollBackoffSlowsRejectedTokensAndHonoursRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(5)
        XCTAssertEqual(FolyncRefreshSchedule.backoff(after: FolyncPortfolioSourceError.unauthorized, at: now),
                       now.addingTimeInterval(15 * 60), "A rejected token must not be re-sent every minute")
        XCTAssertEqual(FolyncRefreshSchedule.backoff(after: FolyncPortfolioSourceError.rateLimited(retryAfter: 120), at: now),
                       now.addingTimeInterval(120))
        XCTAssertEqual(FolyncRefreshSchedule.backoff(after: FolyncPortfolioSourceError.rateLimited(retryAfter: 30), at: now),
                       FolyncRefreshSchedule.nextRegularCheck(after: now), "A short Retry-After never polls faster than normal")
        XCTAssertEqual(FolyncRefreshSchedule.backoff(after: FolyncPortfolioSourceError.rateLimited(retryAfter: nil), at: now),
                       FolyncRefreshSchedule.nextRegularCheck(after: now))
        XCTAssertNil(FolyncRefreshSchedule.backoff(after: FolyncPortfolioSourceError.unavailable(503), at: now))
        XCTAssertNil(FolyncRefreshSchedule.backoff(after: URLError(.notConnectedToInternet), at: now),
                     "Being off the network or tailnet keeps the regular cadence")
    }

    func testFolyncStatusMappingReadsRetryAfterForRateLimits() {
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(401, retryAfter: nil), .unauthorized)
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(429, retryAfter: "42"), .rateLimited(retryAfter: 42))
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(429, retryAfter: " 7 "), .rateLimited(retryAfter: 7))
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(429, retryAfter: "0"), .rateLimited(retryAfter: 1))
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(429, retryAfter: "999999"), .rateLimited(retryAfter: 3600))
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(429, retryAfter: "Wed, 04 Nov 2026 00:00:00 GMT"),
                       .rateLimited(retryAfter: nil), "HTTP-date Retry-After falls back to the regular cadence")
        XCTAssertEqual(FolyncPortfolioSourceError.forStatus(503, retryAfter: "30"), .unavailable(503))
    }

    func testSharedCoreDataStackUsesInMemoryStoreUnderXCTest() {
        XCTAssertEqual(
            CoreDataStack.shared.persistentContainer.persistentStoreDescriptions.first?.type,
            NSInMemoryStoreType
        )
    }

    func testExistingFolyncV1SettingsMigrateWithSupplementalRoutesDisabled() throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncSettingsMigrationTests-")
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let legacy = """
        {"isEnabled":true,"baseURL":"https://folync.example.test","scopeID":"all","pollingIntervalSeconds":60}
        """.data(using: .utf8)!
        suite.set(legacy, forKey: "folync.portfolio-source.settings.v1")

        let settings = FolyncSettingsStore(defaults: suite).load()

        XCTAssertEqual(settings.schemaVersion, 2)
        XCTAssertEqual(settings.baseURL, "https://folync.example.test")
        XCTAssertEqual(settings.scopeID, "all")
        XCTAssertEqual(settings.supplemental, .disabled)
        XCTAssertNotNil(suite.data(forKey: "folync.portfolio-source.settings.v2"))
    }

    /// The exact shape an earlier build stored: the five supplemental keys only.
    private static let olderBuildStoredSettings = """
    {"schemaVersion":2,"isEnabled":true,"baseURL":"https://folync.example.test","scopeID":"pf_isa",\
    "pollingIntervalSeconds":60,"supplemental":{"historicalLineCharts":true,"candlestickCharts":false,\
    "benchmarkMarketData":true,"exchangeRates":false,"allowLegacyFallback":true}}
    """

    func testFolyncSettingsStoredByAnOlderBuildKeepTheirSupplementalChoices() throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncOlderSettings-")
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        suite.set(Data(Self.olderBuildStoredSettings.utf8), forKey: "folync.portfolio-source.settings.v2")

        let settings = FolyncSettingsStore(defaults: suite).load()

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.baseURL, "https://folync.example.test")
        XCTAssertEqual(settings.scopeID, "pf_isa")
        XCTAssertNotEqual(settings.supplemental, .disabled, "An older stored configuration must not reset to disabled")
        XCTAssertTrue(settings.supplemental.historicalLineCharts)
        XCTAssertFalse(settings.supplemental.candlestickCharts)
        XCTAssertTrue(settings.supplemental.benchmarkMarketData)
        XCTAssertFalse(settings.supplemental.exchangeRates)
        XCTAssertTrue(settings.supplemental.allowLegacyFallback)
        XCTAssertTrue(settings.supplemental.dividends, "Ledger routes added later start on for an existing connection")
        XCTAssertTrue(settings.supplemental.tradeAnalysis)
        XCTAssertTrue(settings.supplemental.transactions)
        XCTAssertTrue(settings.isLedgerRouteActive(.dividends))
    }

    func testDisabledSupplementalSettingsSwitchOffTheLedgerRoutes() {
        for route in FolyncLedgerRoute.allCases {
            XCTAssertFalse(FolyncSupplementalSettings.disabled.isEnabled(route))
        }
        var settings = FolyncSupplementalSettings.disabled
        settings.transactions = true
        let connection = FolyncStoredSettings(
            isEnabled: false, baseURL: "https://folync.example.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: settings
        )
        XCTAssertTrue(settings.isEnabled(.transactions))
        XCTAssertFalse(connection.isLedgerRouteActive(.transactions), "A disconnected Folync never enables a ledger route")
    }

    func testNewFolyncConnectionEnablesOnlyUsableLedgerRoutes() throws {
        let without = FolyncSupplementalSettings.newConnectionDefaults(capabilities: .fixture(
            lineHistory: true, candlesticks: true, benchmarks: true, exchangeRates: true
        ))
        XCTAssertFalse(without.dividends, "An absent capability leaves its route off")
        XCTAssertFalse(without.tradeAnalysis)
        XCTAssertFalse(without.transactions)

        let fixture = FolyncCapabilities.fixture(lineHistory: true, candlesticks: true, benchmarks: true, exchangeRates: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? [String: Any])
        var resources = try XCTUnwrap(json["resources"] as? [String: Any])
        resources["dividends"] = ["supported": true, "ready": true, "reasonCodes": []]
        resources["tradeAnalysis"] = ["supported": true, "ready": false, "reasonCodes": ["not_ready"]]
        resources["transactions"] = ["supported": false, "ready": true, "reasonCodes": []]
        json["resources"] = resources
        let with = try JSONDecoder().decode(FolyncCapabilities.self, from: JSONSerialization.data(withJSONObject: json))
        let settings = FolyncSupplementalSettings.newConnectionDefaults(capabilities: with)
        XCTAssertTrue(settings.dividends)
        XCTAssertFalse(settings.tradeAnalysis, "Not ready")
        XCTAssertFalse(settings.transactions, "Unsupported")
        XCTAssertFalse(FolyncSupplementalSettings.newConnectionDefaults(capabilities: nil).dividends)
    }

    func testFolyncCapabilitiesDecodeWithAndWithoutLedgerResources() throws {
        let fixture = FolyncCapabilities.fixture(lineHistory: true, candlesticks: false, benchmarks: true, exchangeRates: true)
        let withoutKeys = try JSONEncoder().encode(fixture)
        XCTAssertFalse(String(decoding: withoutKeys, as: UTF8.self).contains("tradeAnalysis"))
        let decoded = try JSONDecoder().decode(FolyncCapabilities.self, from: withoutKeys)
        XCTAssertEqual(decoded, fixture)
        XCTAssertNil(decoded.resources.dividends)
        XCTAssertNil(decoded.resources.capability(for: .transactions))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: withoutKeys) as? [String: Any])
        var resources = try XCTUnwrap(json["resources"] as? [String: Any])
        for key in ["dividends", "tradeAnalysis", "transactions"] {
            resources[key] = ["supported": true, "ready": key != "transactions", "reasonCodes": []]
        }
        json["resources"] = resources
        let withKeys = try JSONDecoder().decode(FolyncCapabilities.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(withKeys.resources.dividends, FolyncCapability(supported: true, ready: true, reasonCodes: []))
        XCTAssertEqual(withKeys.resources.capability(for: .transactions)?.isUsable, false)
        XCTAssertNotEqual(withKeys, fixture)
        XCTAssertEqual(try JSONDecoder().decode(FolyncCapabilities.self, from: JSONEncoder().encode(withKeys)), withKeys)
    }

    func testFolyncSupplementalSettingsWithMissingKeysDecodeMissingOnesAsOff() throws {
        let partial = try JSONDecoder().decode(
            FolyncSupplementalSettings.self,
            from: Data(#"{"historicalLineCharts":true,"unknownFutureKey":1}"#.utf8)
        )
        XCTAssertTrue(partial.historicalLineCharts)
        XCTAssertFalse(partial.candlestickCharts)
        XCTAssertFalse(partial.benchmarkMarketData)
        XCTAssertFalse(partial.exchangeRates)
        XCTAssertFalse(partial.allowLegacyFallback)
        XCTAssertTrue(partial.dividends)
        XCTAssertTrue(partial.tradeAnalysis)
        XCTAssertTrue(partial.transactions)

        let stored = try JSONDecoder().decode(
            FolyncStoredSettings.self,
            from: Data(#"{"isEnabled":true,"baseURL":"https://folync.example.test","scopeID":"all","pollingIntervalSeconds":60,"supplemental":{"exchangeRates":true}}"#.utf8)
        )
        XCTAssertTrue(stored.isEnabled)
        XCTAssertTrue(stored.supplemental.exchangeRates)
        XCTAssertFalse(stored.supplemental.historicalLineCharts)
    }

    func testFolyncSupplementalSettingsRoundTripThroughStorage() throws {
        let original = FolyncSupplementalSettings(
            historicalLineCharts: false,
            candlestickCharts: true,
            benchmarkMarketData: false,
            exchangeRates: true,
            allowLegacyFallback: true
        )
        let decoded = try JSONDecoder().decode(FolyncSupplementalSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        var ledgerOff = original
        ledgerOff.dividends = false
        ledgerOff.transactions = false
        XCTAssertEqual(
            try JSONDecoder().decode(FolyncSupplementalSettings.self, from: JSONEncoder().encode(ledgerOff)), ledgerOff,
            "A ledger route switched off stays off"
        )

        let stored = FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.example.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: original
        )
        XCTAssertEqual(try JSONDecoder().decode(FolyncStoredSettings.self, from: JSONEncoder().encode(stored)), stored)
    }

    func testNewFolyncConnectionEnablesOnlyReadySupplementalRoutes() {
        let capabilities = FolyncCapabilities.fixture(
            lineHistory: true,
            candlesticks: false,
            benchmarks: true,
            exchangeRates: true
        )

        let settings = FolyncSupplementalSettings.newConnectionDefaults(capabilities: capabilities)

        XCTAssertTrue(settings.historicalLineCharts)
        XCTAssertFalse(settings.candlestickCharts)
        XCTAssertTrue(settings.benchmarkMarketData)
        XCTAssertTrue(settings.exchangeRates)
        XCTAssertFalse(settings.allowLegacyFallback)
    }

    func testFolyncSupplementalRoutesRequireThePortfolioConnectionToRemainEnabled() {
        let supplemental = FolyncSupplementalSettings(
            historicalLineCharts: true,
            candlestickCharts: true,
            benchmarkMarketData: true,
            exchangeRates: true,
            allowLegacyFallback: true
        )
        let disabledConnection = FolyncStoredSettings(
            isEnabled: false,
            baseURL: "https://folync.example.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: supplemental
        )
        let enabledConnection = FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: supplemental
        )

        for route in FolyncSupplementalRoute.allCases {
            XCTAssertFalse(disabledConnection.isSupplementalRouteActive(route))
            XCTAssertTrue(enabledConnection.isSupplementalRouteActive(route))
        }
    }

    func testEveryChartRangeMapsToTheFolyncContract() {
        XCTAssertEqual(
            ChartTimeRange.allCases.map { "\($0.folyncRange)|\($0.suggestedInterval)" },
            [
                "1d|5m", "1w|15m", "1m|1h", "3m|1d",
                "6m|1d", "1y|1d", "all|1d", "custom|1d",
            ]
        )
    }

    func testFolyncBenchmarkOverlayRestorationIsInMemoryAndReversible() {
        var baseline = TradingInfo()
        baseline.currentPrice = 6_250
        baseline.previousClose = 6_240
        baseline.prevClosePrice = 6_240
        let benchmark = RealTimeTrade(
            trade: Trade(
                name: "^GSPC",
                position: Position(unitSize: "1", positionAvgCost: "0", currency: "USD", costCurrency: "USD"),
                isWatchlistOnly: true
            ),
            realTimeInfo: baseline
        )
        var baselines = ["^GSPC": baseline]
        benchmark.realTimeInfo.currentPrice = 6_300

        restoreFolyncBenchmarkValues(&baselines, in: [benchmark])

        XCTAssertEqual(benchmark.realTimeInfo.currentPrice, 6_250)
        XCTAssertEqual(benchmark.realTimeInfo.previousClose, 6_240)
        XCTAssertTrue(baselines.isEmpty)
    }

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
        let missing = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let held = makeLink(
            instrumentId: "LSE:SSE",
            providerTicker: "SSEl_EQ",
            manualSymbol: "SSE.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [missing, held]
        )
        let trades = ["AV.L", "SSE.L"].map {
            Trade(name: $0, position: Position(unitSize: "500", positionAvgCost: "486.26", currency: "GBX", costCurrency: "GBX"))
        }
        let preview = makePreview(
            instrumentId: "LSE:SSE",
            providerTicker: "SSEl_EQ",
            manualSymbol: "SSE.L",
            quantity: 500,
            averagePrice: 486.26,
            brokerPrice: 620,
            currentValue: 3_100
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: trades,
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(plan.deletedManualSymbols, ["AV.L"])
        XCTAssertEqual(plan.deletedLinkIDs, [missing.id])
        XCTAssertTrue(plan.missingLinkedSymbols.isEmpty)
    }

    func testARenamedBrokerTickerIsReportedMissingNotDeleted() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let renamed = makeLink(
            instrumentId: "LSE:AV", providerTicker: "AVI_EQ", manualSymbol: "AV.L", manualCurrency: "GBX", linkedAt: linkedAt
        )
        let held = makeLink(
            instrumentId: "LSE:SSE", providerTicker: "SSEl_EQ", manualSymbol: "SSE.L", manualCurrency: "GBX", linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 1, updatedAt: linkedAt, accounts: [makeLinkedAccount(linkedAt: linkedAt)], positions: [renamed, held]
        )
        let trades = [("AV.L", "300"), ("SSE.L", "500")].map {
            Trade(name: $0.0, position: Position(unitSize: $0.1, positionAvgCost: "486.26", currency: "GBX", costCurrency: "GBX"))
        }
        let heldRow = makePreview(
            instrumentId: "LSE:SSE", providerTicker: "SSEl_EQ", manualSymbol: "SSE.L",
            quantity: 500, averagePrice: 486.26, brokerPrice: 620, currentValue: 3_100
        ).rows[0]
        // The broker now reports the same 300 shares under a new ticker.
        let newTicker = makeBrokerOnlyRow(
            instrumentId: "LSE:AVV", providerTicker: "AVVl_EQ", displaySymbol: "AVV", displayName: "Aviva",
            quantity: 300, averagePrice: 486.26, brokerPrice: 620, currentValue: 1_860
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: trades,
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: makePreview(rows: [heldRow, newTicker]),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
        XCTAssertEqual(plan.missingLinkedSymbols, ["AV.L"])
    }

    func testARenamedTickerWithTheSameISINIsNotDeletedEvenWhenTheQuantityChanged() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        var renamed = makeLink(
            instrumentId: "LSE:AV", providerTicker: "AVI_EQ", manualSymbol: "AV.L", manualCurrency: "GBX", linkedAt: linkedAt
        )
        renamed.isin = "GB00BPQY8M80"
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 2, updatedAt: linkedAt, accounts: [makeLinkedAccount(linkedAt: linkedAt)], positions: [renamed]
        )
        let trades = [Trade(name: "AV.L", position: Position(unitSize: "300", positionAvgCost: "486.26", currency: "GBX", costCurrency: "GBX"))]
        // Same instrument under a new ticker, and more shares than before.
        var newTicker = makeBrokerOnlyRow(
            instrumentId: "LSE:AVV", providerTicker: "AVVl_EQ", displaySymbol: "AVV", displayName: "Aviva",
            quantity: 450, averagePrice: 486.26, brokerPrice: 620, currentValue: 2_790
        )
        newTicker.isin = " gb00bpqy8m80 "

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: trades,
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: makePreview(rows: [newTicker]),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
        XCTAssertEqual(plan.missingLinkedSymbols, ["AV.L"])
    }

    func testALinkSavedWithoutAnISINStillLoadsAndIsFilledInFromTheBrokerRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("broker_links.json")
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "LSE:AV", providerTicker: "AVI_EQ", manualSymbol: "AV.L", manualCurrency: "GBX", linkedAt: linkedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(BrokerLinkStoreSnapshot(
            schemaVersion: 2, updatedAt: linkedAt, accounts: [makeLinkedAccount(linkedAt: linkedAt)], positions: [link]
        ))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("isin"), "a link without an ISIN is saved as before")
        try data.write(to: fileURL)

        let store = BrokerLinkStore(fileURL: fileURL)
        var row = makeBrokerOnlyRow(
            instrumentId: "LSE:AV", providerTicker: "AVI_EQ", displaySymbol: "AV", displayName: "Aviva",
            quantity: 500, averagePrice: 486.26, brokerPrice: 620, currentValue: 3_100
        )
        row.isin = "GB00BPQY8M80"

        let changed = try await store.recordISINs(from: [row])
        let secondPass = try await store.recordISINs(from: [row])
        let saved = try await store.loadSnapshot()

        XCTAssertTrue(changed)
        XCTAssertFalse(secondPass)
        XCTAssertEqual(saved.positions.first?.isin, "GB00BPQY8M80")
    }

    func testRekeyedMovesLinksWhenAccountLabelOrAPIKeyChanges() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "LSE:AV",
            providerTicker: "AVI_EQ",
            manualSymbol: "AV.L",
            manualCurrency: "GBX",
            linkedAt: linkedAt
        )
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        // Same account id; new label hash and API key fingerprint.
        let renamed = BrokerAccountIdentity(
            broker: "Trading212",
            brokerAccountKey: "Trading212|live|isa|newlabel|newcredential|account",
            apiAccountIdHash: "account",
            accountLabel: "My ISA",
            accountType: .stocksAndSharesISA,
            taxWrapper: "ISA",
            environment: .live,
            credentialFingerprint: "newcredential"
        )

        let moved = try XCTUnwrap(snapshot.rekeyed(to: renamed, now: Date(timeIntervalSince1970: 300)))

        XCTAssertEqual(moved.positions.map(\.brokerAccountKey), [renamed.brokerAccountKey])
        XCTAssertEqual(moved.positions.first?.manualSymbol, "AV.L")
        XCTAssertEqual(moved.accounts.map(\.brokerAccountKey), [renamed.brokerAccountKey])
        XCTAssertEqual(moved.accounts.first?.accountLabel, "My ISA")
        XCTAssertEqual(moved.accounts.first?.linkedAt, linkedAt, "The original link date is kept")
        XCTAssertNil(moved.rekeyed(to: renamed), "Re-keying twice is a no-op")
    }

    func testRekeyedLeavesOtherAccountsAndKeysWithoutAccountIDAlone() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let snapshot = BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [makeLink(instrumentId: "LSE:AV", providerTicker: "AVI_EQ", manualSymbol: "AV.L", manualCurrency: "GBX", linkedAt: linkedAt)]
        )
        func identity(_ key: String) -> BrokerAccountIdentity {
            BrokerAccountIdentity(
                broker: "Trading212", brokerAccountKey: key, apiAccountIdHash: nil, accountLabel: "ISA",
                accountType: .stocksAndSharesISA, taxWrapper: "ISA", environment: .live, credentialFingerprint: "x"
            )
        }

        XCTAssertNil(snapshot.rekeyed(to: identity("Trading212|live|isa|newlabel|newcredential|other-account")))
        XCTAssertNil(snapshot.rekeyed(to: identity("Trading212|demo|isa|newlabel|newcredential|account")))
        XCTAssertNil(snapshot.rekeyed(to: identity("Trading212|live|isa|newlabel|newcredential|no-account-id")))
    }

    func testEmptyBrokerResponseNeverDeletesLinkedHoldings() {
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

        XCTAssertTrue(plan.deletedManualSymbols.isEmpty, "An empty positions list is treated as an outage, not a sell-off")
        XCTAssertTrue(plan.deletedLinkIDs.isEmpty)
        XCTAssertEqual(plan.missingLinkedSymbols, ["AV.L"])
    }

    func testBrokerResponseMatchingNoLinkedHoldingNeverDeletes() {
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
        let unrelated = makeBrokerOnlyRow(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            displaySymbol: "MNMD",
            displayName: "Definium Therapeutics",
            quantity: 50,
            averagePrice: 25,
            brokerPrice: 30,
            currentValue: 1_500
        )

        let plan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [Trade(name: "AV.L", position: Position(unitSize: "500", positionAvgCost: "486.26", currency: "GBX"))],
            tradingInfoBySymbol: [:],
            links: snapshot,
            preview: makePreview(rows: [unrelated]),
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            syncedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(plan.deletedManualSymbols.isEmpty)
        XCTAssertEqual(plan.missingLinkedSymbols, ["AV.L"])
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

    @MainActor
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

    func testTrading212SyncSettingsDefaultToFiveMinuteAutoSync() {
        // Given a fresh install
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)

        // When settings are loaded
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then auto-sync runs on the same 300s cadence as market-data refresh,
        // rather than the old 30s (~2,880 broker calls/day).
        XCTAssertTrue(settings.autoSyncEnabled)
        XCTAssertEqual(settings.syncIntervalSeconds, 300)
    }

    func testLegacyThirtySecondSyncIntervalIsMigratedToNewDefault() {
        // Given an install still carrying the old 30s default
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")

        // When the store is constructed
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then it is raised to the new default
        XCTAssertEqual(settings.syncIntervalSeconds, 300)
    }

    func testDeliberateSyncIntervalSurvivesTheDefaultMigration() {
        // Given a user who deliberately picked a non-default cadence
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)
        defaults.set(900, forKey: "trading212.syncIntervalSeconds")

        // When the store is constructed
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then their choice is untouched — only the exact legacy default moves
        XCTAssertEqual(settings.syncIntervalSeconds, 900)
    }

    func testSyncIntervalDefaultMigrationRunsOnlyOnce() {
        // Given an install migrated off the legacy default
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")
        _ = Trading212SettingsStore(defaults: defaults)

        // When the user deliberately selects 30s afterwards
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then the migration does not fire again and overwrite them
        XCTAssertEqual(settings.syncIntervalSeconds, 30)
    }

    func testTrading212SettingsDefaultToManualHoldingReconciliation() {
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)
        let settings = Trading212SettingsStore(defaults: defaults).load()

        XCTAssertFalse(settings.autoReconcileHoldingsEnabled)
        XCTAssertFalse(settings.autoImportBrokerOnlyHoldings)
        XCTAssertEqual(settings.holdingReconciliationIntervalSeconds, 3_600)
    }

    func testTrading212SettingsStorePersistsHourlyHoldingReconciliation() {
        let suiteName = TestDefaultsSuite.makeName("Trading212SyncSettingsTests.")
        let defaults = UserDefaults(suiteName: suiteName)!
        TestDefaultsSuite.remove(suiteName)
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
        let defaults = UserDefaults(suiteName: TestDefaultsSuite.makeName("Trading212SyncSettingsTests."))!
        defaults.set(5, forKey: "trading212.syncIntervalMinutes")
        let settings = Trading212SettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.syncIntervalSeconds, 300)
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

    func testBrokerOnlyImportPlannerSkipsProviderTickerAlreadyLinkedUnderAlias() {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let existingLink = makeLink(
            instrumentId: "US:DFTX",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "DFTX",
            manualCurrency: "USD",
            linkedAt: linkedAt
        )
        let row = makeBrokerOnlyRow(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            displaySymbol: "MNMD",
            displayName: "Definium Therapeutics",
            quantity: 50,
            averagePrice: 25.2294,
            brokerPrice: 25,
            currentValue: 1_250
        )

        let plan = Trading212BrokerOnlyImportPlanner().plan(
            existingTrades: [
                Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD"))
            ],
            existingLinks: BrokerLinkStoreSnapshot(
                schemaVersion: 1,
                updatedAt: linkedAt,
                accounts: [makeLinkedAccount(linkedAt: linkedAt)],
                positions: [existingLink]
            ),
            preview: makePreview(rows: [row]),
            importedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(plan.records.isEmpty)
        XCTAssertEqual(plan.skippedRows, ["MNMD_US_EQ: provider position already linked as DFTX"])
    }

    func testBrokerLinkStoreCollapsesRenamedInstrumentByProviderTicker() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broker-alias-tests-\(UUID().uuidString)")
            .appendingPathComponent("broker_links.json")
        let store = BrokerLinkStore(fileURL: fileURL)
        let account = makeAccount()
        let first = BrokerLinkedPosition(
            brokerAccountKey: account.brokerAccountKey,
            instrumentId: "US:DFTX",
            displaySymbol: "DFTX",
            displayName: "Definium Therapeutics",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "DFTX",
            manualQuantityAtLink: 50,
            brokerQuantityAtLink: 50,
            manualAverageCostAtLink: 25.2294,
            manualCurrency: "USD",
            linkedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let renamed = BrokerLinkedPosition(
            brokerAccountKey: account.brokerAccountKey,
            instrumentId: "US:MNMD",
            displaySymbol: "MNMD",
            displayName: "Definium Therapeutics",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "MNMD",
            manualQuantityAtLink: 50,
            brokerQuantityAtLink: 50,
            manualAverageCostAtLink: 25.2294,
            manualCurrency: "USD",
            linkedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        _ = try await store.upsertImportedPositions(account: account, positions: [first], linkedAt: first.linkedAt)
        _ = try await store.upsertImportedPositions(account: account, positions: [renamed], linkedAt: renamed.linkedAt)
        let snapshot = try await store.loadSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, 2)
        XCTAssertEqual(snapshot.positions.count, 1)
        XCTAssertEqual(snapshot.positions[0].manualSymbol, "DFTX")
        XCTAssertEqual(snapshot.positions[0].instrumentId, "US:MNMD")
        XCTAssertEqual(snapshot.positions[0].linkedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.positions[0].updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testPreviewReconcilesRenamedDisplaySymbolThroughExistingProviderLink() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "US:DFTX",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "DFTX",
            manualCurrency: "USD",
            linkedAt: linkedAt
        )
        let row = makeBrokerOnlyRow(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            displaySymbol: "MNMD",
            displayName: "Definium Therapeutics",
            quantity: 50,
            averagePrice: 25.2294,
            brokerPrice: 25,
            currentValue: 1_250
        )
        let holding = Trading212ManualHoldingSnapshot(
            symbol: "DFTX",
            displayName: "Definium Therapeutics",
            quantity: 50,
            averageCost: 25.2294,
            currency: "USD",
            isWatchlistOnly: false
        )

        let reconciled = row.reconciledWithExistingProviderLink(
            links: BrokerLinkStoreSnapshot(
                schemaVersion: 1,
                updatedAt: linkedAt,
                accounts: [makeLinkedAccount(linkedAt: linkedAt)],
                positions: [link]
            ),
            existingManualHoldings: [holding]
        )

        XCTAssertEqual(reconciled.manualMatch?.symbol, "DFTX")
        XCTAssertEqual(reconciled.conflictStatus, .manualHoldingMatch)
        XCTAssertTrue(reconciled.warnings.contains("Matched existing Trading 212 provider identity to DFTX."))
    }

    func testPreviewMatchesManualHoldingThroughKnownFolyncAlias() throws {
        let suiteName = TestDefaultsSuite.makeName("folync-alias-preview-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let identityStore = InstrumentAliasStore(defaults: defaults)
        identityStore.merge(["MNMD": "DFTX"])

        let row = Trading212ImportPreviewRow.make(
            account: makeAccount(),
            position: makeRawPosition(ticker: "MNMD_US_EQ", isin: nil),
            resolution: makeResolution(displaySymbol: "MNMD", isin: nil),
            existingManualHoldings: [makeManualHolding(symbol: "DFTX")],
            identityStore: identityStore
        )

        XCTAssertEqual(row.manualMatch?.symbol, "DFTX")
        XCTAssertEqual(row.conflictStatus, .manualHoldingMatch)
    }

    func testPreviewMatchesManualHoldingThroughFolyncISIN() throws {
        let suiteName = TestDefaultsSuite.makeName("folync-isin-preview-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let identityStore = InstrumentAliasStore(defaults: defaults)
        identityStore.mergeISIN("CA60255C8850", displaySymbol: "DFTX")

        let row = Trading212ImportPreviewRow.make(
            account: makeAccount(),
            position: makeRawPosition(ticker: "MNMD_US_EQ", isin: "CA60255C8850"),
            resolution: makeResolution(displaySymbol: "MNMD", isin: "CA60255C8850"),
            existingManualHoldings: [makeManualHolding(symbol: "DFTX")],
            identityStore: identityStore
        )

        XCTAssertEqual(row.manualMatch?.symbol, "DFTX")
        XCTAssertEqual(row.conflictStatus, .manualHoldingMatch)
    }

    func testAliasMigrationKeepsOneEconomicPositionAndRemapsDependentState() throws {
        let links = makeAliasDuplicateLinks()
        let alerts = [
            AliasMigrationAlert(id: UUID(), symbol: "DFTX", alertType: "price", condition: "Above", threshold: 30, isEnabled: true, createdAt: Date(timeIntervalSince1970: 1), lastTriggered: nil),
            AliasMigrationAlert(id: UUID(), symbol: "MNMD", alertType: "price", condition: "Above", threshold: 30, isEnabled: true, createdAt: Date(timeIntervalSince1970: 2), lastTriggered: Date(timeIntervalSince1970: 3))
        ]
        let trades = [
            Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD", costCurrency: "USD"), showInMenuBar: false),
            Trade(name: "MNMD", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD", costCurrency: "USD")),
            Trade(name: "HELP", position: Position(unitSize: "113", positionAvgCost: "5.39238938", currency: "USD", costCurrency: "USD"), showInMenuBar: false),
            Trade(name: "CYBN", position: Position(unitSize: "113", positionAvgCost: "5.39238938", currency: "USD", costCurrency: "USD"))
        ]

        let result = InstrumentAliasRepairPlanner().plan(
            trades: trades,
            tradingInfoBySymbol: ["DFTX": TradingInfo(), "MNMD": TradingInfo(), "HELP": TradingInfo(), "CYBN": TradingInfo()],
            links: links,
            displayOrder: ["MNMD", "DFTX", "CYBN", "HELP"],
            alerts: alerts
        )

        XCTAssertEqual(result.repairedTrades.map(\.name), ["DFTX", "HELP"])
        XCTAssertEqual(result.repairedTrades.map(\.position.unitSize), [50, 113])
        XCTAssertEqual(result.repairedTrades.map(\.showInMenuBar), [false, false])
        XCTAssertEqual(result.repairedLinks.schemaVersion, 2)
        XCTAssertEqual(result.repairedLinks.positions.count, 2)
        XCTAssertEqual(Set(result.repairedLinks.positions.map(\.manualSymbol)), Set(["DFTX", "HELP"]))
        XCTAssertEqual(result.displayOrder, ["DFTX", "HELP"])
        XCTAssertEqual(result.aliases, ["CYBN": "HELP", "MNMD": "DFTX"])
        XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(result.alerts[0].symbol, "DFTX")
        XCTAssertEqual(result.alerts[0].lastTriggered, Date(timeIntervalSince1970: 3))
        XCTAssertTrue(result.quarantinedProviderKeys.isEmpty)

        let second = InstrumentAliasRepairPlanner().plan(
            trades: result.repairedTrades,
            tradingInfoBySymbol: result.tradingInfoBySymbol,
            links: result.repairedLinks,
            displayOrder: result.displayOrder,
            alerts: result.alerts
        )
        XCTAssertFalse(second.didChange)
    }

    func testAliasMigrationQuarantinesEconomicallyDifferentPositions() {
        let links = makeAliasDuplicateLinks().positions.filter { $0.providerTicker == "MNMD_US_EQ" }
        let snapshot = BrokerLinkStoreSnapshot(schemaVersion: 1, updatedAt: Date(), accounts: [], positions: links)
        let trades = [
            Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD")),
            Trade(name: "MNMD", position: Position(unitSize: "51", positionAvgCost: "25.2294", currency: "USD"))
        ]

        let result = InstrumentAliasRepairPlanner().plan(
            trades: trades,
            tradingInfoBySymbol: [:],
            links: snapshot,
            displayOrder: ["DFTX", "MNMD"],
            alerts: []
        )

        XCTAssertFalse(result.didChange)
        XCTAssertEqual(result.repairedTrades.map(\.name), ["DFTX", "MNMD"])
        XCTAssertEqual(result.quarantinedProviderKeys.count, 1)
    }

    func testAliasMigrationUsesCachedFolyncDisplayIdentityOverEarliestLinkSymbol() {
        let earlyCanonical = makeLink(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "MNMD",
            manualCurrency: "USD",
            linkedAt: Date(timeIntervalSince1970: 1)
        )
        let laterDisplay = makeLink(
            instrumentId: "US:DFTX",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "DFTX",
            manualCurrency: "USD",
            linkedAt: Date(timeIntervalSince1970: 2)
        )
        let result = InstrumentAliasRepairPlanner().plan(
            trades: [
                Trade(name: "MNMD", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD")),
                Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD"))
            ],
            tradingInfoBySymbol: ["MNMD": TradingInfo(), "DFTX": TradingInfo()],
            links: BrokerLinkStoreSnapshot(
                schemaVersion: 1,
                updatedAt: Date(timeIntervalSince1970: 2),
                accounts: [makeLinkedAccount(linkedAt: Date(timeIntervalSince1970: 1))],
                positions: [earlyCanonical, laterDisplay]
            ),
            displayOrder: ["MNMD", "DFTX"],
            alerts: [],
            preferredAliases: ["MNMD": "DFTX"]
        )

        XCTAssertEqual(result.repairedTrades.map(\.name), ["DFTX"])
        XCTAssertEqual(result.repairedLinks.positions.map(\.manualSymbol), ["DFTX"])
        XCTAssertEqual(result.aliases, ["MNMD": "DFTX"])
    }

    func testBrokerLinkStorePreservesAmbiguousProviderDuplicatesForMigrationReview() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broker-ambiguous-tests-\(UUID().uuidString)")
            .appendingPathComponent("broker_links.json")
        let store = BrokerLinkStore(fileURL: fileURL)
        var snapshot = makeAliasDuplicateLinks()
        let firstGroup = snapshot.positions.filter { $0.providerTicker == "MNMD_US_EQ" }
        let mismatched = BrokerLinkedPosition(
            brokerAccountKey: firstGroup[1].brokerAccountKey,
            instrumentId: firstGroup[1].instrumentId,
            displaySymbol: firstGroup[1].displaySymbol,
            displayName: firstGroup[1].displayName,
            providerTicker: firstGroup[1].providerTicker,
            manualSymbol: firstGroup[1].manualSymbol,
            manualQuantityAtLink: 51,
            brokerQuantityAtLink: firstGroup[1].brokerQuantityAtLink,
            manualAverageCostAtLink: firstGroup[1].manualAverageCostAtLink,
            manualCurrency: firstGroup[1].manualCurrency,
            linkedAt: firstGroup[1].linkedAt,
            updatedAt: firstGroup[1].updatedAt
        )
        snapshot.positions = [firstGroup[0], mismatched]

        try await store.replaceSnapshot(snapshot)

        let raw = try await store.loadSnapshotPreservingDuplicates()
        let normalized = try await store.loadSnapshot()
        XCTAssertEqual(raw.positions.count, 2)
        XCTAssertEqual(normalized.positions.count, 2)
    }

    func testAliasRecoveryBundleIsWrittenAndDecodedBeforeMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        let bundle = AliasIdentityRecoveryBundle(
            migrationVersion: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            trades: [Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD"))],
            tradingInfoBySymbol: ["DFTX": TradingInfo()],
            brokerLinks: makeAliasDuplicateLinks(),
            displayOrder: ["DFTX", "MNMD"],
            alerts: []
        )
        let store = AliasIdentityRecoveryStore(rootDirectory: root)

        let url = try store.writeAndValidate(bundle)
        let decoded = try store.load(from: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(decoded.migrationVersion, 1)
        XCTAssertEqual(decoded.trades, bundle.trades)
        XCTAssertEqual(decoded.brokerLinks, bundle.brokerLinks)
        XCTAssertEqual(Set(decoded.tradingInfoBySymbol.keys), ["DFTX"])
    }

    func testAnUnreadablePendingRecoveryNamesItsFileAndCanBeSetAside() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-unreadable-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AliasIdentityRecoveryStore(rootDirectory: root)
        XCTAssertNil(try store.pendingBundle())
        let missing = root.appendingPathComponent("gone.json")
        try store.markPending(recoveryURL: missing)

        XCTAssertThrowsError(try store.pendingBundle()) { error in
            guard case AliasIdentityMigrationError.pendingRecoveryUnreadable(let path, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
        store.setAsideUnreadablePending()

        XCTAssertNil(try store.pendingBundle())
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("pending-recovery-manifest.unreadable-") })
    }

    func testAliasRecoveryStorePublishesAndClearsDurablePendingManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-pending-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        let bundle = AliasIdentityRecoveryBundle(
            migrationVersion: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            trades: [Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD"))],
            tradingInfoBySymbol: ["DFTX": TradingInfo()],
            brokerLinks: makeAliasDuplicateLinks(),
            displayOrder: ["DFTX", "MNMD"],
            alerts: []
        )
        let store = AliasIdentityRecoveryStore(rootDirectory: root)
        let recoveryURL = try store.writeAndValidate(bundle)

        try store.markPending(recoveryURL: recoveryURL)

        XCTAssertEqual(try store.pendingRecoveryURL(), recoveryURL)
        XCTAssertEqual(try store.load(from: XCTUnwrap(store.pendingRecoveryURL())).trades, bundle.trades)
        try store.clearPending()
        XCTAssertNil(try store.pendingRecoveryURL())
    }

    func testQuarantinedProviderIdentityIsExcludedFromSyncValuationAndImport() throws {
        let linkedAt = Date(timeIntervalSince1970: 100)
        let link = makeLink(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            manualSymbol: "DFTX",
            manualCurrency: "USD",
            linkedAt: linkedAt
        )
        let links = BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: linkedAt,
            accounts: [makeLinkedAccount(linkedAt: linkedAt)],
            positions: [link]
        )
        let row = makeBrokerOnlyRow(
            instrumentId: "US:MNMD",
            providerTicker: "MNMD_US_EQ",
            displaySymbol: "MNMD",
            displayName: "Definium Therapeutics",
            quantity: 50,
            averagePrice: 25.2294,
            brokerPrice: 30,
            currentValue: 1_500
        )
        let preview = makePreview(
            rows: [row],
            accountSummary: Trading212AccountSummary(
                cash: nil,
                currency: "USD",
                id: 123,
                investments: Trading212Investments(
                    currentValue: 1_500,
                    realizedProfitLoss: nil,
                    totalCost: 1_261.47,
                    unrealizedProfitLoss: 238.53
                ),
                totalValue: 1_500
            )
        )
        let quarantine = Set([link.id])

        let syncPlan = Trading212BrokerSyncPlanner().plan(
            existingTrades: [Trade(name: "DFTX", position: Position(unitSize: "50", positionAvgCost: "25.2294", currency: "USD"))],
            tradingInfoBySymbol: ["DFTX": TradingInfo()],
            links: links,
            preview: preview,
            options: Trading212BrokerSyncOptions(deleteMissingLinkedHoldings: true),
            quarantinedProviderKeys: quarantine,
            syncedAt: Date(timeIntervalSince1970: 200)
        )
        let importPlan = Trading212BrokerOnlyImportPlanner().plan(
            existingTrades: [],
            existingLinks: .empty(),
            preview: preview,
            quarantinedProviderKeys: quarantine,
            importedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(syncPlan.tradeUpdates.isEmpty)
        XCTAssertTrue(syncPlan.deletedManualSymbols.isEmpty)
        XCTAssertEqual(syncPlan.brokerOnlyCount, 0)
        XCTAssertNil(syncPlan.valuationSnapshot)
        XCTAssertTrue(importPlan.records.isEmpty)
        XCTAssertEqual(importPlan.skippedRows.count, 1)
    }

    func testAliasAwareHistoryKeepsRawSeriesAndPrefersRequestedDisplaySymbolAtCollision() throws {
        let suiteName = TestDefaultsSuite.makeName("instrument-alias-history-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let store = InstrumentAliasStore(defaults: defaults)
        store.merge(["MNMD": "DFTX"])
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let stored: [String: [PriceSnapshot]] = [
            "MNMD": [
                PriceSnapshot(timestamp: firstDate, price: 9, previousClose: 8, symbol: "MNMD"),
                PriceSnapshot(timestamp: secondDate, price: 10, previousClose: 9, symbol: "MNMD")
            ],
            "DFTX": [
                PriceSnapshot(timestamp: secondDate, price: 11, previousClose: 10, symbol: "DFTX")
            ]
        ]

        let combined = InstrumentAliasHistoryLookup.combinedSnapshots(
            for: "DFTX",
            aliases: store.aliases(for: "DFTX"),
            storedBySymbol: stored,
            liveBySymbol: [:]
        )

        XCTAssertEqual(Set(stored.keys), ["MNMD", "DFTX"])
        XCTAssertEqual(combined.map(\.timestamp), [firstDate, secondDate])
        XCTAssertEqual(combined.map(\.price), [9, 11])
        XCTAssertEqual(combined.last?.symbol, "DFTX")
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

    private func makeRawPosition(ticker: String, isin: String?) -> Trading212Position {
        Trading212Position(
            averagePricePaid: 25.2294,
            currentPrice: 25,
            instrument: Trading212Instrument(currency: "USD", isin: isin, name: "Definium Therapeutics", ticker: ticker),
            quantity: 50,
            quantityAvailableForTrading: 50,
            quantityInPies: 0,
            walletImpact: nil
        )
    }

    private func makeResolution(displaySymbol: String, isin: String?) -> InstrumentResolutionResult {
        InstrumentResolutionResult(
            identity: InstrumentIdentity(
                instrumentId: "US:\(displaySymbol)",
                displaySymbol: displaySymbol,
                displayName: "Definium Therapeutics",
                exchange: "US",
                currency: "USD",
                isin: isin,
                providerSymbols: ["trading212": "MNMD_US_EQ"],
                legacySymbols: []
            ),
            confidence: .high,
            warnings: []
        )
    }

    private func makeManualHolding(symbol: String) -> Trading212ManualHoldingSnapshot {
        Trading212ManualHoldingSnapshot(
            symbol: symbol,
            displayName: "Definium Therapeutics",
            quantity: 50,
            averageCost: 25.2294,
            currency: "USD",
            isWatchlistOnly: false
        )
    }

    private func makeAliasDuplicateLinks() -> BrokerLinkStoreSnapshot {
        let account = makeLinkedAccount(linkedAt: Date(timeIntervalSince1970: 1))
        func link(_ instrument: String, _ provider: String, _ manual: String, _ timestamp: TimeInterval) -> BrokerLinkedPosition {
            BrokerLinkedPosition(
                brokerAccountKey: account.brokerAccountKey,
                instrumentId: instrument,
                displaySymbol: manual,
                displayName: manual == "DFTX" || manual == "MNMD" ? "Definium Therapeutics" : "Cybin",
                providerTicker: provider,
                manualSymbol: manual,
                manualQuantityAtLink: manual == "DFTX" || manual == "MNMD" ? 50 : 113,
                brokerQuantityAtLink: manual == "DFTX" || manual == "MNMD" ? 50 : 113,
                manualAverageCostAtLink: manual == "DFTX" || manual == "MNMD" ? 25.2294 : 5.39238938,
                manualCurrency: "USD",
                linkedAt: Date(timeIntervalSince1970: timestamp),
                updatedAt: Date(timeIntervalSince1970: timestamp)
            )
        }
        return BrokerLinkStoreSnapshot(
            schemaVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 4),
            accounts: [account],
            positions: [
                link("US:DFTX", "MNMD_US_EQ", "DFTX", 1),
                link("US:MNMD", "MNMD_US_EQ", "MNMD", 2),
                link("US:HELP", "CYBN_US_EQ", "HELP", 1),
                link("US:CYBN", "CYBN_US_EQ", "CYBN", 2)
            ]
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

    func testActionCredentialsUseTypedValuesWithoutTouchingStorage() throws {
        var loadCalls = 0
        let resolved = try Trading212ActionCredentials.resolve(apiKey: " key ", apiSecret: "secret") {
            loadCalls += 1
            return Trading212AuthConfiguration(apiKey: "stored", apiSecret: "stored")
        }

        XCTAssertEqual(loadCalls, 0, "typed credentials must be used from memory")
        XCTAssertTrue(resolved.isUnsaved)
        XCTAssertEqual(resolved.credentials, Trading212AuthConfiguration(apiKey: "key", apiSecret: "secret"))
    }

    func testActionCredentialsFallBackToStoredAndRejectIncompleteTypedValues() throws {
        let stored = Trading212AuthConfiguration(apiKey: "stored-key", apiSecret: "stored-secret")
        let fromStore = try Trading212ActionCredentials.resolve(apiKey: "  ", apiSecret: "") { stored }
        XCTAssertFalse(fromStore.isUnsaved)
        XCTAssertEqual(fromStore.credentials, stored)

        var loadCalls = 0
        XCTAssertThrowsError(try Trading212ActionCredentials.resolve(apiKey: "only-a-key", apiSecret: "") {
            loadCalls += 1
            return stored
        })
        XCTAssertEqual(loadCalls, 0, "a half-typed pair is an error, not a silent fallback to stored credentials")
    }

    func testLinkSelectionSeparatesExactMatchesFromQuantityMismatches() throws {
        let exactPreview = makePreview(
            instrumentId: "AV_EQ", providerTicker: "AVl_EQ", manualSymbol: "AV.L",
            quantity: 10, averagePrice: 400, brokerPrice: 450, currentValue: 4500)
        let exactRow = try XCTUnwrap(exactPreview.rows.first)
        let mismatchRow = Trading212ImportPreviewRow(
            id: exactRow.id + "-mismatch", account: exactRow.account, providerTicker: "BP_EQ",
            instrumentId: "BP_EQ", displaySymbol: "BP", displayName: "BP", quantity: 12,
            averagePrice: exactRow.averagePrice, brokerProvidedPrice: exactRow.brokerProvidedPrice,
            currentValue: exactRow.currentValue, totalCost: exactRow.totalCost,
            unrealizedProfitLoss: exactRow.unrealizedProfitLoss, fxImpact: nil,
            mappingConfidence: .high,
            manualMatch: Trading212ManualHoldingMatch(
                symbol: "BP.L", instrumentId: "BP_EQ", displayName: "BP", quantity: 10, averageCost: 400,
                currency: "GBX", isWatchlistOnly: false, resolutionConfidence: .high),
            additionalManualMatchCount: 0, conflictStatus: .manualQuantityMismatch,
            valueSource: .brokerProvidedLivePositionData, warnings: [])
        let preview = Trading212ImportPreview(
            account: exactPreview.account, accountSummary: nil, rows: [exactRow, mismatchRow],
            metadataAvailable: true, generatedAt: exactPreview.generatedAt, warnings: [])

        let selection = Trading212LinkSelection(preview: preview)

        XCTAssertEqual(selection.exactMatches.map(\.id), [exactRow.id])
        XCTAssertEqual(selection.mismatches.map(\.id), [mismatchRow.id])
        XCTAssertEqual(selection.exactMatchesOnlyPreview.rows.map(\.id), [exactRow.id],
                       "the default link action must not include differing quantities")
        XCTAssertEqual(selection.exactMatchesOnlyPreview.account, preview.account)
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

// MARK: - The ordinary sync through the app, against a fake broker

/// The ordinary Trading 212 sync (`DataModel.syncLinkedTrading212Holdings`) for an account
/// with nothing linked, driven through the app's own code against `FakeTrading212Account`.
@MainActor
final class Trading212UnlinkedAccountSyncTests: XCTestCase {
    private static let cashOnlySummary = """
    { "cash": { "availableToTrade": 2400.5, "inPies": 0, "reservedForOrders": 100 }, "currency": "GBP", "id": 42,
      "investments": { "currentValue": 0, "realizedProfitLoss": 0, "totalCost": 0, "unrealizedProfitLoss": 0 },
      "totalValue": 2500.5 }
    """

    func testACashOnlyAccountIsValuedAsItsCashWithOneSummaryRequest() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        model.realTimeTrades = [FakeTrading212Account.watchlistRow("WTCH")]
        XCTAssertNil(model.trading212BrokerValuationSnapshot)

        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")

        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.valuedAccountOnly)
        XCTAssertEqual(result.updatedCount + result.deletedCount + result.missingCount + result.brokerOnlyCount, 0)
        XCTAssertEqual(result.userMessage,
                       "No linked Trading 212 holdings, so the account is valued from its summary: its cash and anything not linked. "
                       + "To track holdings one by one, run Preview Import and Link Matched Holdings.")
        XCTAssertEqual(account.requestedRoutes, ["/equity/account/summary"], "one summary, no positions, no metadata")

        let snapshot = try XCTUnwrap(model.trading212BrokerValuationSnapshot)
        XCTAssertTrue(snapshot.isAccountOnly)
        XCTAssertTrue(snapshot.positionsByManualSymbol.isEmpty)
        XCTAssertEqual(snapshot.currency, "GBP")
        XCTAssertEqual(snapshot.cashValue ?? .nan, 2_500.5, accuracy: 1e-9, "available, in pies and reserved")
        XCTAssertEqual(snapshot.accountValue, 2_500.5, accuracy: 1e-9)
        XCTAssertTrue(snapshot.accountKey.hasPrefix("Trading212|demo|stocksAndSharesISA|"))
        XCTAssertTrue(snapshot.accountKey.hasSuffix(Trading212Hashing.sha256Hex("42")), "keyed on the account's id")

        // What Holdings, the menu bar and the popover read: the cash is the whole portfolio.
        let netValue = model.calculateNetValue()
        XCTAssertEqual(netValue.amount, 2_500.5, accuracy: 1e-9)
        XCTAssertEqual(netValue.currency, "GBP")
        XCTAssertEqual(model.netGainsSource, .trading212)
        XCTAssertEqual(model.calculateNetGains().amount, 0, accuracy: 1e-9)
        let summary = model.calculateDisplayPortfolioSummary()
        XCTAssertEqual(summary.valuationSource, .brokerProvided)
        XCTAssertEqual(summary.totalValue, 2_500.5, accuracy: 1e-9)
        XCTAssertEqual(summary.totalGain, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.totalGainPct, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.dayGain, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.dayGainPct, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.totalCost, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.ownedPositionCount, 0)
        XCTAssertEqual(model.displayValuationSource, .brokerProvided)
        XCTAssertNil(model.calculatePositionWeight(for: model.realTimeTrades[0], netValue: netValue),
                     "a watchlist row has no weight")

        // The next ordinary sync asks again, once, and stores a new valuation.
        account.answer(summary: Self.cashOnlySummary.replacingOccurrences(of: "2400.5", with: "2600.5")
            .replacingOccurrences(of: "2500.5", with: "2700.5"))
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertEqual(account.requestedRoutes, ["/equity/account/summary", "/equity/account/summary"])
        XCTAssertEqual(model.trading212BrokerValuationSnapshot?.cashValue ?? .nan, 2_700.5, accuracy: 1e-9)
        XCTAssertEqual(model.calculateNetValue().amount, 2_700.5, accuracy: 1e-9)
    }

    func testASummaryWithoutAValueOrCurrencyValuesNothingAndSaysSo() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        let model = account.makeDataModel()
        account.answer(summary: Self.cashOnlySummary)
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertNotNil(model.trading212BrokerValuationSnapshot)

        for summary in [Self.cashOnlySummary.replacingOccurrences(of: "\"currency\": \"GBP\", ", with: ""),
                        """
                        { "cash": { "availableToTrade": 10 }, "currency": "GBP", "id": 42, "investments": null, "totalValue": null }
                        """] {
            account.answer(summary: summary)
            let result = try await model.syncLinkedTrading212Holdings(reason: "auto")
            XCTAssertEqual(result.skippedReason, DataModel.trading212AccountNotValuedReason)
            XCTAssertFalse(result.valuedAccountOnly)
            XCTAssertNil(model.trading212BrokerValuationSnapshot, "an earlier valuation does not stand in")
        }
        XCTAssertEqual(account.requestedRoutes, Array(repeating: "/equity/account/summary", count: 3))
    }

    func testASummaryWithoutInvestmentsIsValuedFromItsTotal() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: """
        { "cash": { "availableToTrade": 75.25 }, "currency": "GBP", "id": 42, "investments": null, "totalValue": 75.25 }
        """)
        let model = account.makeDataModel()
        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertTrue(result.valuedAccountOnly)
        let snapshot = try XCTUnwrap(model.trading212BrokerValuationSnapshot)
        XCTAssertEqual(snapshot.cashValue ?? .nan, 75.25, accuracy: 1e-9)
        XCTAssertEqual(snapshot.accountValue, 75.25, accuracy: 1e-9)
        XCTAssertNil(snapshot.totalUnrealizedProfitLoss)
        XCTAssertEqual(model.calculateNetValue().amount, 75.25, accuracy: 1e-9)
        // With no gain from the broker, Holdings' gains are its own sum over no holdings.
        XCTAssertEqual(model.netGainsSource, .averageCost)
        XCTAssertEqual(model.calculateNetGains().amount, 0, accuracy: 1e-9)
    }

    func testANewAccountOnlyValuationTellsTheMenuBarAndPopover() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        // What the menu bar's title, the popover's chart and the Overview redraw on.
        let told = expectation(description: "content changed")
        told.assertForOverFulfill = false
        let subscription = model.tradeContentPublisher.sink { told.fulfill() }
        defer { subscription.cancel() }

        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")

        await fulfillment(of: [told], timeout: 5)
    }

    func testAUserWithoutTrading212MakesNoRequestAndKeepsTheSkippedReason() async throws {
        let account = try FakeTrading212Account(enabled: false)
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()

        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")

        XCTAssertEqual(result.skippedReason, "Trading 212 is not enabled.")
        XCTAssertFalse(result.valuedAccountOnly)
        XCTAssertEqual(account.requestedRoutes, [])
        XCTAssertNil(model.trading212BrokerValuationSnapshot)
        XCTAssertEqual(model.displayValuationSource, .localCalculationFallback)
    }

    func testEnabledWithoutCredentialsMakesNoRequestAndFailsAsBefore() async throws {
        let account = try FakeTrading212Account(storesCredentials: false)
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()

        do {
            _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
            XCTFail("Expected the missing credentials to be reported")
        } catch {
            XCTAssertEqual((error as? Trading212CredentialStoreError).map { "\($0)" }, "missingCredentials")
        }
        XCTAssertEqual(account.requestedRoutes, [])
        XCTAssertNil(model.trading212BrokerValuationSnapshot)
    }

    func testBesideHoldingsOfItsOwnNothingIsAskedAndTheLocalFiguresStand() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        model.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 40, units: "10"),
                                FakeTrading212Account.row("BRVO", price: 60, units: "10")]

        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")

        XCTAssertEqual(result.skippedReason, DataModel.trading212NoLinkedHoldingsReason)
        XCTAssertEqual(result.skippedReason,
                       "No linked Trading 212 holdings found. Run Preview Import and Link Matched Holdings first.")
        XCTAssertEqual(account.requestedRoutes, [])
        XCTAssertNil(model.trading212BrokerValuationSnapshot)
        // Read after the sync: the local figures stand.
        let netAfter = model.calculateNetValue()
        XCTAssertEqual(netAfter.amount, 1_000, accuracy: 1e-9)
        XCTAssertEqual(model.realTimeTrades.map { model.calculatePositionWeight(for: $0, netValue: netAfter) ?? .nan },
                       [40, 60])
        XCTAssertEqual(model.displayValuationSource, .localCalculationFallback)
    }

    func testAnAccountOnlyValuationGivesWayToAHoldingAddedLater() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertEqual(model.calculateNetValue().amount, 2_500.5, accuracy: 1e-9)

        // A holding entered by hand before the next sync: the account's cash no longer
        // stands for the portfolio, so Holdings weighs the holding as it did before the fix.
        model.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 40, units: "10")]
        let netValue = model.calculateNetValue()
        XCTAssertEqual(netValue.amount, 400, accuracy: 1e-9)
        XCTAssertEqual(model.calculatePositionWeight(for: model.realTimeTrades[0], netValue: netValue) ?? .nan,
                       100, accuracy: 1e-9)
        XCTAssertEqual(model.displayValuationSource, .localCalculationFallback)
        XCTAssertEqual(model.netGainsSource, .averageCost)
        XCTAssertEqual(model.holdingsWeightBasis().source, .local)
    }

    func testAnAccountWithLinkedPositionsSyncsAsBefore() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(
            summary: """
            { "cash": { "availableToTrade": 100, "inPies": 0, "reservedForOrders": 0 }, "currency": "GBP", "id": 42,
              "investments": { "currentValue": 900, "realizedProfitLoss": 0, "totalCost": 800, "unrealizedProfitLoss": 100 },
              "totalValue": 1000 }
            """,
            // No quantity or prices, so the sync has nothing to write to the holding: a test
            // model must not save the portfolio. The broker's value still comes through.
            positions: """
            [{ "averagePricePaid": null, "currentPrice": null, "quantity": null, "quantityAvailableForTrading": null, "quantityInPies": null,
               "instrument": { "currency": "GBP", "isin": "GB00ALFA0001", "name": "Alfa", "ticker": "ALFAl_EQ" },
               "walletImpact": { "currency": "GBP", "currentValue": 900, "fxImpact": 0, "totalCost": 800, "unrealizedProfitLoss": 100 } }]
            """
        )
        try await account.link(providerTicker: "ALFAl_EQ", manualSymbol: "ALFA")
        let model = account.makeDataModel()
        model.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 85, units: "10")]

        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")

        XCTAssertNil(result.skippedReason)
        XCTAssertFalse(result.valuedAccountOnly)
        // With nothing to write, the holding is reported missing, as before.
        XCTAssertEqual(result.missingCount, 1)
        XCTAssertEqual(result.updatedCount, 0)
        XCTAssertEqual(result.userMessage, "Synced 0 linked holdings. Deleted 0. Missing 1. Broker-only 0.")
        XCTAssertEqual(account.requestedRoutes.sorted(), ["/equity/account/summary", "/equity/positions"],
                       "the summary and the positions, as before, and no metadata")
        let snapshot = try XCTUnwrap(model.trading212BrokerValuationSnapshot)
        XCTAssertFalse(snapshot.isAccountOnly)
        XCTAssertEqual(snapshot.accountValue, 1_000, accuracy: 1e-9)
        XCTAssertEqual(snapshot.cashValue ?? .nan, 100, accuracy: 1e-9)
        XCTAssertEqual(snapshot.position(for: "ALFA")?.brokerCurrentValue ?? .nan, 900, accuracy: 1e-9)
        XCTAssertEqual(snapshot.totalUnrealizedProfitLoss ?? .nan, 100, accuracy: 1e-9)
        // Holdings weighs the linked holding by the broker's value against the account's.
        let netValue = model.calculateNetValue()
        XCTAssertEqual(netValue.amount, 1_000, accuracy: 1e-9)
        XCTAssertEqual(model.calculatePositionWeight(for: model.realTimeTrades[0], netValue: netValue) ?? .nan,
                       90, accuracy: 1e-9)
        XCTAssertEqual(model.holdingsWeightBasis().source, .trading212)
    }
}

// MARK: - Which account a valuation belongs to, and when it stops applying

/// The stored Trading 212 valuation against the account it was made for: links of other
/// accounts, Folync, a change of account or credentials, a request overtaken while in
/// flight, and reconciliation. Driven through the app's own code against
/// `FakeTrading212Account`; no request leaves the process.
@MainActor
final class Trading212ValuationAccountTests: XCTestCase {
    private static let cashOnlySummary = """
    { "cash": { "availableToTrade": 2400.5, "inPies": 0, "reservedForOrders": 100 }, "currency": "GBP", "id": 42,
      "investments": { "currentValue": 0, "realizedProfitLoss": 0, "totalCost": 0, "unrealizedProfitLoss": 0 },
      "totalValue": 2500.5 }
    """

    /// Two holdings of the app's own, £400 and £600.
    private func holdOwnHoldings(_ model: DataModel) {
        model.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 40, units: "10"),
                                FakeTrading212Account.row("BRVO", price: 60, units: "10")]
    }

    /// What Holdings, the menu bar and the Overview show for the two holdings when no
    /// Trading 212 valuation applies, read now.
    private func assertOwnFiguresStand(_ model: DataModel, file: StaticString = #filePath, line: UInt = #line) {
        let net = model.calculateNetValue()
        XCTAssertEqual(net.amount, 1_000, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(model.realTimeTrades.map { model.calculatePositionWeight(for: $0, netValue: net) ?? .nan },
                       [40, 60], file: file, line: line)
        XCTAssertEqual(model.displayValuationSource, .localCalculationFallback, file: file, line: line)
        XCTAssertEqual(model.netGainsSource, .averageCost, file: file, line: line)
        XCTAssertEqual(model.holdingsWeightBasis().source, .local, file: file, line: line)
        let summary = model.calculateDisplayPortfolioSummary()
        XCTAssertEqual(summary.valuationSource, .localCalculationFallback, file: file, line: line)
        XCTAssertEqual(summary.totalValue, 1_000, accuracy: 1e-9, file: file, line: line)
        XCTAssertNil(model.freshTrading212BrokerValuationSnapshot(), file: file, line: line)
    }

    /// Runs the ordinary sync with the broker's answer to `route` held back, makes `change`
    /// while it is in flight, then lets the answer through.
    private func sync(_ model: DataModel, holding route: String = FakeTrading212Account.summaryRoute,
                      during change: () throws -> Void) async throws -> Trading212BrokerSyncResult {
        let arrived = expectation(description: "request in flight")
        Trading212BrokerStub.hold(route) { arrived.fulfill() }
        let sync = Task { try await model.syncLinkedTrading212Holdings(reason: "auto") }
        await fulfillment(of: [arrived], timeout: 10)
        try change()
        Trading212BrokerStub.release()
        return try await sync.value
    }

    private func folyncSnapshot() throws -> FolyncPortfolioSnapshot {
        func metric(_ value: String) -> String {
            "{ \"value\": \(value), \"currency\": \"GBP\", \"quality\": \"complete\", \"reasonCodes\": [], \"asOfDate\": \"2026-07-11\" }"
        }
        func holding(_ asset: String, price: Int) -> String {
            let ticker = asset.uppercased()
            return """
            { "portfolioId": "pf_demo", "portfolioName": "Demo", "assetId": "\(asset)", "ticker": "\(ticker)",
              "canonicalTicker": "\(ticker)", "displayTicker": "\(ticker)", "quoteSymbol": "\(ticker)",
              "aliases": ["\(ticker)"], "name": "Fund \(asset)", "currency": "GBP", "valueCurrency": "GBP",
              "shares": 10, "averageCost": 1, "currentPrice": \(price), "previousClose": \(price),
              "marketValue": \(price * 10), "costValue": 10, "dayGain": 0, "dayGainPct": 0, "totalGain": 1, "totalGainPct": 1,
              "allocationPct": null, "valuation": \(metric("\(price * 10)")) }
            """
        }
        // Folync gives no total and no unrealised gain.
        let json = """
        {
          "schemaVersion": 2, "sourceRevision": "revision-1", "generatedAt": "2026-07-12T12:00:00.000Z",
          "scope": { "id": "all", "name": "All portfolios", "kind": "aggregate", "currency": "GBP" },
          "freshness": {
            "responseGeneratedAt": "2026-07-12T12:00:00.000Z", "asOf": "2026-07-11", "status": "current", "reasonCodes": [],
            "sources": {
              "snapshots": { "asOfDate": "2026-07-11", "status": "clean", "generation": 1, "dirtySince": null, "rebuildStartedAt": null, "failedAt": null, "completedAt": "2026-07-12T11:55:00.000Z" },
              "prices": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "fx": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "provider": { "lastSuccessfulSyncAt": "2026-07-12T11:55:00.000Z", "ageSeconds": 300 }
            }
          },
          "totalValue": \(metric("null")),
          "cash": \(metric("null")),
          "profitLoss": { "unrealized": \(metric("null")), "realized": \(metric("0")), "day": \(metric("null")) },
          "holdings": [\(holding("a", price: 30)), \(holding("b", price: 7))]
        }
        """
        return try FolyncPortfolioDecoder().decodeSnapshot(Data(json.utf8))
    }

    // MARK: 1. Links in another account

    func testLinksInAnotherEnvironmentLeaveTheActiveAccountUnlinked() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        // Linked in Live; the account in use is the Demo one, with nothing linked.
        try await account.link(providerTicker: "ALFAl_EQ", manualSymbol: "ALFA", environment: .live)

        let owner = account.makeDataModel()
        holdOwnHoldings(owner)
        let skipped = try await owner.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertEqual(skipped.skippedReason, DataModel.trading212NoLinkedHoldingsReason)
        XCTAssertEqual(account.requestedRoutes, [], "beside holdings of the app's own, nothing is asked")
        XCTAssertNil(owner.trading212BrokerValuationSnapshot)
        assertOwnFiguresStand(owner)

        let cashOnly = account.makeDataModel()
        let valued = try await cashOnly.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertTrue(valued.valuedAccountOnly)
        XCTAssertEqual(account.requestedRoutes, ["/equity/account/summary"], "the summary alone, not the positions")
        XCTAssertEqual(cashOnly.trading212BrokerValuationSnapshot?.isAccountOnly, true)
        XCTAssertEqual(cashOnly.calculateNetValue().amount, 2_500.5, accuracy: 1e-9)
    }

    func testLinksUnderAnotherAccountOfTheSameTypeLeaveTheValuationAccountOnly() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary, positions: "[]")
        // Same environment and account type, another account (id 7): its key is known only
        // once the broker answers with this account's id (42).
        try await account.link(providerTicker: "ALFAl_EQ", manualSymbol: "ALFA", apiAccountId: 7)
        let model = account.makeDataModel()
        holdOwnHoldings(model)

        let result = try await model.syncLinkedTrading212Holdings(reason: "auto")

        XCTAssertNil(result.skippedReason)
        XCTAssertEqual(account.requestedRoutes.sorted(), ["/equity/account/summary", "/equity/positions"])
        let snapshot = try XCTUnwrap(model.trading212BrokerValuationSnapshot)
        XCTAssertTrue(snapshot.isAccountOnly, "no position linked in this account")
        XCTAssertTrue(snapshot.positionsByManualSymbol.isEmpty)
        XCTAssertEqual(snapshot.accountValue, 2_500.5, accuracy: 1e-9)
        // So the holdings' own figures stand, read after the sync.
        assertOwnFiguresStand(model)
        // Without them, the account is the portfolio.
        model.realTimeTrades = []
        XCTAssertEqual(model.calculateNetValue().amount, 2_500.5, accuracy: 1e-9)
    }

    func testReconcilingAnAccountWithNothingLinkedLeavesTheHoldingsFiguresAlone() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.change {
            $0.autoReconcileHoldingsEnabled = true
            $0.autoImportBrokerOnlyHoldings = false
        }
        account.answer(summary: Self.cashOnlySummary, positions: "[]")
        try await account.link(providerTicker: "ALFAl_EQ", manualSymbol: "ALFA", environment: .live)
        let model = account.makeDataModel()
        holdOwnHoldings(model)

        let result = try await model.reconcileTrading212Holdings(reason: "manual-reconcile")

        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(account.requestedRoutes.contains("/equity/account/summary"))
        XCTAssertTrue(account.requestedRoutes.contains("/equity/positions"))
        let snapshot = try XCTUnwrap(model.trading212BrokerValuationSnapshot)
        XCTAssertTrue(snapshot.isAccountOnly, "Reconcile Holdings Now stores an account-only valuation too")
        assertOwnFiguresStand(model)
        model.realTimeTrades = []
        XCTAssertEqual(model.calculateNetValue().amount, 2_500.5, accuracy: 1e-9)
        XCTAssertEqual(model.displayValuationSource, .brokerProvided)
    }

    // MARK: 2. Folync active

    func testWhileFolyncIsActiveNoTrading212ValuationApplies() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: """
        { "cash": { "availableToTrade": 2500.5 }, "currency": "GBP", "id": 42,
          "investments": { "currentValue": 500, "realizedProfitLoss": 0, "totalCost": 450, "unrealizedProfitLoss": 50 },
          "totalValue": 3000.5 }
        """)
        let model = account.makeDataModel()
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertNotNil(model.freshTrading212BrokerValuationSnapshot())

        // Folync takes over, with no total and no unrealised gain; the valuation is left behind.
        let folync = try folyncSnapshot()
        model.folyncPortfolioSnapshot = folync
        model.realTimeTrades = folync.makeDisplayTrades(overlays: [:])
        XCTAssertNotNil(model.trading212BrokerValuationSnapshot)
        XCTAssertNil(model.freshTrading212BrokerValuationSnapshot())

        // Each reader gives Folync's holdings at their prices: £300 and £70, and no account's figure.
        let net = model.calculateNetValue()
        XCTAssertEqual(net.amount, 370, accuracy: 1e-9)
        XCTAssertEqual(net.currency, "GBP")
        XCTAssertEqual(model.netGainsSource, .averageCost)
        let gains = model.calculateNetGains()
        XCTAssertNotEqual(gains.amount, 50, "not the Trading 212 account's gain")
        XCTAssertEqual(model.displayValuationSource, .localCalculationFallback)
        let summary = model.calculateDisplayPortfolioSummary()
        XCTAssertEqual(summary.valuationSource, .localCalculationFallback)
        XCTAssertEqual(summary.totalValue, 370, accuracy: 1e-9)
        XCTAssertEqual(model.holdingsWeightBasis(),
                       HoldingsWeightBasis(source: .folync, total: nil, cash: nil, mismatch: .folyncWithoutTotal))

        // The same as with no Trading 212 valuation at all.
        model.setTrading212BrokerValuationSnapshotForTesting(nil)
        XCTAssertEqual(model.calculateNetValue().amount, net.amount, accuracy: 1e-9)
        XCTAssertEqual(model.calculateNetGains().amount, gains.amount, accuracy: 1e-9)
        XCTAssertEqual(model.calculateDisplayPortfolioSummary().totalGain, summary.totalGain, accuracy: 1e-9)
        XCTAssertEqual(model.calculateDisplayPortfolioSummary().totalCost, summary.totalCost, accuracy: 1e-9)
    }

    // MARK: 3. The account changes

    func testChangingTheAccountClearsTheValuationAtOnceAndTellsTheMenuBar() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        let saved = account.settings.load()

        // Another sync interval is not another account: the valuation stands.
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        var interval = saved
        interval.syncIntervalSeconds = saved.syncIntervalSeconds * 2
        interval.accountLabel = "Renamed"
        model.trading212SettingsDidChange(from: saved, to: interval)
        XCTAssertNotNil(model.trading212BrokerValuationSnapshot)

        var off = saved
        off.isEnabled = false
        var live = saved
        live.environment = .live
        var invest = saved
        invest.accountType = saved.accountType == .invest ? .stocksAndSharesISA : .invest
        let changes: [(String, () -> Void)] = [
            ("turned off", { model.trading212SettingsDidChange(from: saved, to: off) }),
            ("another environment", { model.trading212SettingsDidChange(from: saved, to: live) }),
            ("another account type", { model.trading212SettingsDidChange(from: saved, to: invest) }),
            ("credentials saved, replaced or cleared", { model.trading212AccountDidChange() })
        ]
        for (name, change) in changes {
            _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
            XCTAssertEqual(model.calculateNetValue().amount, 2_500.5, accuracy: 1e-9, name)
            let told = expectation(description: "content changed: \(name)")
            told.assertForOverFulfill = false
            let subscription = model.tradeContentPublisher.sink { told.fulfill() }

            change()

            XCTAssertNil(model.trading212BrokerValuationSnapshot, name)
            XCTAssertEqual(model.calculateNetValue().amount, 0, accuracy: 1e-9, name)
            XCTAssertEqual(model.displayValuationSource, .localCalculationFallback, name)
            await fulfillment(of: [told], timeout: 5)
            subscription.cancel()
        }
    }

    // MARK: 4. A request overtaken while in flight

    func testASummaryOvertakenInFlightStoresNothing() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let saved = account.settings.load()
        let cases: [(name: String, reason: String, change: (DataModel) throws -> Void)] = [
            ("Folync took over", DataModel.trading212SkippedForFolyncReason, { model in
                model.folyncPortfolioSnapshot = try self.folyncSnapshot()
            }),
            ("Trading 212 turned off", DataModel.trading212AccountChangedReason, { _ in
                account.change { $0.isEnabled = false }
            }),
            ("another environment", DataModel.trading212AccountChangedReason, { _ in
                account.change { $0.environment = .live }
            }),
            ("another account type", DataModel.trading212AccountChangedReason, { _ in
                account.change { $0.accountType = saved.accountType == .invest ? .stocksAndSharesISA : .invest }
            }),
            ("credentials removed", DataModel.trading212AccountChangedReason, { _ in
                try account.credentials.delete(environment: saved.environment)
            }),
            ("credentials replaced", DataModel.trading212AccountChangedReason, { model in
                model.trading212AccountDidChange()
            })
        ]
        for testCase in cases {
            account.settings.save(saved)
            try account.credentials.save(Trading212AuthConfiguration(apiKey: "fake-key-for-tests", apiSecret: "fake-secret"),
                                         environment: saved.environment)
            Trading212BrokerStub.reset(bodies: [FakeTrading212Account.summaryRoute: Self.cashOnlySummary])
            let model = account.makeDataModel()

            let result = try await sync(model) { try testCase.change(model) }

            XCTAssertEqual(result.skippedReason, testCase.reason, testCase.name)
            XCTAssertFalse(result.valuedAccountOnly, testCase.name)
            XCTAssertNil(model.trading212BrokerValuationSnapshot, testCase.name)
            XCTAssertEqual(account.requestedRoutes, ["/equity/account/summary"], testCase.name)
        }
    }

    func testACancelledSyncStoresNothing() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let model = account.makeDataModel()
        let arrived = expectation(description: "request in flight")
        Trading212BrokerStub.hold(FakeTrading212Account.summaryRoute) { arrived.fulfill() }
        let sync = Task { try await model.syncLinkedTrading212Holdings(reason: "auto") }
        await fulfillment(of: [arrived], timeout: 10)

        sync.cancel()
        Trading212BrokerStub.release()

        do {
            _ = try await sync.value
            XCTFail("a cancelled sync reports its cancellation")
        } catch {}
        XCTAssertNil(model.trading212BrokerValuationSnapshot)
    }

    func testALinkedSyncOvertakenInFlightStoresNothing() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(
            summary: """
            { "cash": { "availableToTrade": 100 }, "currency": "GBP", "id": 42,
              "investments": { "currentValue": 900, "realizedProfitLoss": 0, "totalCost": 800, "unrealizedProfitLoss": 100 },
              "totalValue": 1000 }
            """,
            positions: """
            [{ "averagePricePaid": null, "currentPrice": null, "quantity": null, "quantityAvailableForTrading": null, "quantityInPies": null,
               "instrument": { "currency": "GBP", "isin": "GB00ALFA0001", "name": "Alfa", "ticker": "ALFAl_EQ" },
               "walletImpact": { "currency": "GBP", "currentValue": 900, "fxImpact": 0, "totalCost": 800, "unrealizedProfitLoss": 100 } }]
            """
        )
        try await account.link(providerTicker: "ALFAl_EQ", manualSymbol: "ALFA")
        for change in ["Folync", "turned off"] {
            let model = account.makeDataModel()
            model.realTimeTrades = [FakeTrading212Account.row("ALFA", price: 85, units: "10")]

            let result = try await sync(model, holding: FakeTrading212Account.positionsRoute) {
                if change == "Folync" {
                    model.folyncPortfolioSnapshot = try self.folyncSnapshot()
                } else {
                    account.change { $0.isEnabled = false }
                }
            }

            XCTAssertEqual(result.skippedReason, change == "Folync"
                           ? DataModel.trading212SkippedForFolyncReason : DataModel.trading212AccountChangedReason)
            XCTAssertNil(model.trading212BrokerValuationSnapshot, change)
            account.change { $0.isEnabled = true }
        }
    }

    func testAReconciliationOvertakenInFlightStoresNothing() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.change {
            $0.autoReconcileHoldingsEnabled = true
            $0.autoImportBrokerOnlyHoldings = false
        }
        account.answer(summary: Self.cashOnlySummary, positions: "[]")
        let model = account.makeDataModel()
        let arrived = expectation(description: "request in flight")
        Trading212BrokerStub.hold(FakeTrading212Account.positionsRoute) { arrived.fulfill() }
        let reconcile = Task { try await model.reconcileTrading212Holdings(reason: "manual-reconcile") }
        await fulfillment(of: [arrived], timeout: 10)

        model.trading212AccountDidChange()
        Trading212BrokerStub.release()

        let result = try await reconcile.value
        XCTAssertEqual(result.skippedReason, DataModel.trading212AccountChangedReason)
        XCTAssertNil(model.trading212BrokerValuationSnapshot)
    }

    // MARK: Holdings not known yet

    func testAPortfolioNotReadYetOrUnreadableCountsAsHoldings() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: Self.cashOnlySummary)
        let states: [(name: String, requires: Bool, completed: Bool, failed: Bool)] = [
            ("not read yet", true, false, false),
            ("could not be read", true, true, true)
        ]
        for state in states {
            // A valuation stored while the portfolio was known to be empty no longer applies.
            let model = account.makeDataModel()
            _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
            XCTAssertEqual(model.calculateNetValue().amount, 2_500.5, accuracy: 1e-9, state.name)
            model.setPortfolioLoadStateForTesting(requiresInitialLoad: state.requires, completed: state.completed,
                                                  failed: state.failed)
            XCTAssertNil(model.freshTrading212BrokerValuationSnapshot(), state.name)
            XCTAssertEqual(model.displayValuationSource, .localCalculationFallback, state.name)
            XCTAssertFalse(model.isValuedFromTrading212AccountAlone, state.name)

            // And the next sync asks nothing.
            let before = account.requestedRoutes.count
            let result = try await model.syncLinkedTrading212Holdings(reason: "auto")
            XCTAssertEqual(result.skippedReason, DataModel.trading212NoLinkedHoldingsReason, state.name)
            XCTAssertEqual(account.requestedRoutes.count, before, state.name)
        }
    }

    // MARK: 7. Cost basis

    func testAnAccountOnlyValuationWithoutInvestmentsHasNoCostBasisOrGain() async throws {
        let account = try FakeTrading212Account()
        defer { account.cleanUp() }
        account.answer(summary: """
        { "cash": { "availableToTrade": 75.25 }, "currency": "GBP", "id": 42, "investments": null, "totalValue": 75.25 }
        """)
        let model = account.makeDataModel()
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")

        let summary = model.calculateDisplayPortfolioSummary()
        XCTAssertEqual(summary.valuationSource, .brokerProvided)
        XCTAssertEqual(summary.totalValue, 75.25, accuracy: 1e-9)
        XCTAssertTrue(summary.totalCost.isNaN, "not the cash passed off as a cost: \(summary.totalCost)")
        XCTAssertTrue(summary.totalGain.isNaN, "\(summary.totalGain)")
        XCTAssertTrue(summary.totalGainPct.isNaN, "\(summary.totalGainPct)")
        // The Overview's Cost basis row, as it formats it: the unknown mark.
        XCTAssertEqual(HoldingsCurrencyFormatter.amount(summary.totalCost, currency: summary.currency), "-")

        // With an investments figure, the summary's own cost and gain.
        account.answer(summary: """
        { "cash": { "availableToTrade": 2500.5 }, "currency": "GBP", "id": 42,
          "investments": { "currentValue": 500, "realizedProfitLoss": 0, "totalCost": 450, "unrealizedProfitLoss": 50 },
          "totalValue": 3000.5 }
        """)
        _ = try await model.syncLinkedTrading212Holdings(reason: "auto")
        let invested = model.calculateDisplayPortfolioSummary()
        XCTAssertEqual(invested.totalCost, 450, accuracy: 1e-9)
        XCTAssertEqual(invested.totalGain, 50, accuracy: 1e-9)
        XCTAssertEqual(invested.totalGainPct, 50.0 / 450.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(HoldingsCurrencyFormatter.amount(invested.totalCost, currency: invested.currency), "£450.00")
    }
}

// MARK: - A fake Trading 212 account

/// Stands in for Trading 212's API: answers each route from memory and records the path
/// of every request. Installed only on the ephemeral session `FakeTrading212Account` gives
/// its provider, so nothing else is answered by it and no request leaves the process.
final class Trading212BrokerStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: String] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var heldRoute: String?
    nonisolated(unsafe) private static var held: [Trading212BrokerStub] = []
    nonisolated(unsafe) private static var onHeld: (@Sendable () -> Void)?

    static func reset(bodies newBodies: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        bodies = newBodies
        paths = []
        heldRoute = nil
        held = []
        onHeld = nil
    }

    /// Holds every request for `route` unanswered until `release()`, calling `arrived` as
    /// each one comes in: a request in flight for as long as a test needs, with no waiting
    /// on time.
    static func hold(_ route: String, arrived: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        heldRoute = route
        onHeld = arrived
    }

    /// Answers the held requests with what the broker answers now, and holds no more.
    static func release() {
        let waiting: [Trading212BrokerStub] = {
            lock.lock(); defer { lock.unlock() }
            heldRoute = nil
            onHeld = nil
            defer { held = [] }
            return held
        }()
        for request in waiting { request.answer() }
    }

    static func setBody(_ body: String, for route: String) {
        lock.lock(); defer { lock.unlock() }
        bodies[route] = body
    }

    static var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let arrived: (@Sendable () -> Void)? = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            Self.paths.append(path)
            guard let route = Self.heldRoute, path.hasSuffix(route) else { return nil }
            Self.held.append(self)
            return Self.onHeld
        }()
        if let arrived {
            arrived()
            return
        }
        answer()
    }

    private func answer() {
        let path = request.url?.path ?? ""
        let body: String? = {
            Self.lock.lock(); defer { Self.lock.unlock() }
            return Self.bodies.first { path.hasSuffix($0.key) }?.value
        }()
        let status = body == nil ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.held.removeAll { $0 === self }
    }
}

/// A Trading 212 account set up as the app sets one up, kept apart from the user's: its
/// settings in a defaults suite of its own, its credentials (made up) in a Keychain service
/// of its own, its links in a temporary file, and its broker `Trading212BrokerStub`.
/// `cleanUp()` removes all of them.
@MainActor
final class FakeTrading212Account {
    static let summaryRoute = "/equity/account/summary"
    static let positionsRoute = "/equity/positions"

    let settings: Trading212SettingsStore
    let credentials: Trading212CredentialStore
    let links: BrokerLinkStore
    let coordinator: Trading212PreviewCoordinator
    private let suite: String
    private let service: String
    private let storedPreferredCurrency = StockbarRuntimeStorage.userDefaults.object(forKey: "preferredCurrency")
    private let directory: URL
    private static let apiKey = "fake-key-for-tests"

    init(enabled: Bool = true, storesCredentials: Bool = true) throws {
        suite = "FakeTrading212Account.\(UUID().uuidString)"
        settings = Trading212SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        var stored = settings.load()
        stored.isEnabled = enabled
        settings.save(stored)

        service = "com.stockbar.tests.trading212.\(UUID().uuidString)"
        credentials = Trading212CredentialStore(service: service)
        if storesCredentials {
            try credentials.save(Trading212AuthConfiguration(apiKey: Self.apiKey, apiSecret: "fake-secret"),
                                 environment: stored.environment)
        }

        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeTrading212Account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        links = BrokerLinkStore(fileURL: directory.appendingPathComponent("links.json"))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Trading212BrokerStub.self]
        coordinator = Trading212PreviewCoordinator(provider: Trading212Provider(
            session: URLSession(configuration: configuration),
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: true)
        ))
        Trading212BrokerStub.reset(bodies: [:])
    }

    /// What the broker answers from now on. Routes without an answer get a 404.
    func answer(summary: String, positions: String? = nil) {
        Trading212BrokerStub.setBody(summary, for: Self.summaryRoute)
        if let positions { Trading212BrokerStub.setBody(positions, for: Self.positionsRoute) }
    }

    /// The route of each request so far, in order, without the API's base path.
    var requestedRoutes: [String] {
        Trading212BrokerStub.requestedPaths.map { path in
            [Self.summaryRoute, Self.positionsRoute].first { path.hasSuffix($0) } ?? path
        }
    }

    /// A model on this account, showing pounds. The display currency is the one setting the
    /// model saves itself; `cleanUp()` puts back what was there.
    func makeDataModel(converter: CurrencyConverter? = nil) -> DataModel {
        let model = DataModel(
            currencyConverter: converter ?? CurrencyConverter(exchangeRates: ["USD": 1.0, "GBP": 0.8],
                                                              refreshOnInit: false, loadHistoryOnInit: false),
            startRuntimeServices: false,
            trading212SettingsStore: settings,
            trading212CredentialStore: credentials,
            trading212PreviewCoordinator: coordinator,
            trading212BrokerLinkStore: links
        )
        model.preferredCurrency = "GBP"
        return model
    }

    /// Changes the account's stored settings, as saving them in Settings does.
    func change(_ edit: (inout Trading212StoredSettings) -> Void) {
        var stored = settings.load()
        edit(&stored)
        settings.save(stored)
    }

    /// Links the broker's `providerTicker` to the holding `manualSymbol`, as Link Matched
    /// Holdings saves it, under the key the next sync gives this account (id 42), or under
    /// another account's key: another `environment`, or another account id.
    func link(providerTicker: String, manualSymbol: String,
              environment: Trading212Environment? = nil, apiAccountId: Int64 = 42) async throws {
        let stored = settings.load()
        let key = BrokerAccountIdentity.preview(
            broker: "Trading212", environment: environment ?? stored.environment, accountType: stored.accountType,
            accountLabel: stored.accountLabel,
            credentialFingerprint: Trading212AuthConfiguration(apiKey: Self.apiKey, apiSecret: "fake-secret")
                .credentialFingerprint,
            apiAccountId: apiAccountId
        ).brokerAccountKey
        let linkedAt = Date(timeIntervalSince1970: 1_000)
        try await links.replaceSnapshot(BrokerLinkStoreSnapshot(
            schemaVersion: 2,
            updatedAt: linkedAt,
            accounts: [BrokerLinkedAccount(
                brokerAccountKey: key, broker: "Trading212", accountLabel: stored.accountLabel,
                accountType: stored.accountType, taxWrapper: stored.accountType.taxWrapper,
                environment: environment ?? stored.environment, linkedAt: linkedAt, updatedAt: linkedAt)],
            positions: [BrokerLinkedPosition(
                brokerAccountKey: key, instrumentId: "LSE:\(manualSymbol)", displaySymbol: manualSymbol,
                displayName: manualSymbol, providerTicker: providerTicker, manualSymbol: manualSymbol,
                manualQuantityAtLink: 10, brokerQuantityAtLink: 10, manualAverageCostAtLink: 80,
                manualCurrency: "GBP", linkedAt: linkedAt, updatedAt: linkedAt)]
        ))
    }

    func cleanUp() {
        StockbarRuntimeStorage.userDefaults.set(storedPreferredCurrency, forKey: "preferredCurrency")
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        for environment in [Trading212Environment.live, .demo] {
            try? credentials.delete(environment: environment)
        }
        try? CredentialVault.named("\(service).combined").deleteItem()
        try? FileManager.default.removeItem(at: directory)
        Trading212BrokerStub.reset(bodies: [:])
    }

    /// A holding of the app's own, priced in pounds.
    static func row(_ symbol: String, price: Double, units: String) -> RealTimeTrade {
        var info = TradingInfo()
        info.currentPrice = price
        info.prevClosePrice = price
        info.currency = "GBP"
        return RealTimeTrade(trade: Trade(name: symbol, position: Position(unitSize: units, positionAvgCost: "1", currency: "GBP")),
                             realTimeInfo: info)
    }

    static func watchlistRow(_ symbol: String) -> RealTimeTrade {
        let row = row(symbol, price: 5, units: "0")
        row.trade.isWatchlistOnly = true
        return row
    }
}
