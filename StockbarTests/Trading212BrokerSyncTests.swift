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
