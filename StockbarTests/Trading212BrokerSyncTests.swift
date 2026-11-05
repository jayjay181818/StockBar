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
        let suiteName = "FolyncSettingsMigrationTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
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
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        // When settings are loaded
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then auto-sync runs on the same 300s cadence as market-data refresh,
        // rather than the old 30s (~2,880 broker calls/day).
        XCTAssertTrue(settings.autoSyncEnabled)
        XCTAssertEqual(settings.syncIntervalSeconds, 300)
    }

    func testLegacyThirtySecondSyncIntervalIsMigratedToNewDefault() {
        // Given an install still carrying the old 30s default
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")

        // When the store is constructed
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then it is raised to the new default
        XCTAssertEqual(settings.syncIntervalSeconds, 300)
    }

    func testDeliberateSyncIntervalSurvivesTheDefaultMigration() {
        // Given a user who deliberately picked a non-default cadence
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(900, forKey: "trading212.syncIntervalSeconds")

        // When the store is constructed
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then their choice is untouched — only the exact legacy default moves
        XCTAssertEqual(settings.syncIntervalSeconds, 900)
    }

    func testSyncIntervalDefaultMigrationRunsOnlyOnce() {
        // Given an install migrated off the legacy default
        let suiteName = "Trading212SyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")
        _ = Trading212SettingsStore(defaults: defaults)

        // When the user deliberately selects 30s afterwards
        defaults.set(30, forKey: "trading212.syncIntervalSeconds")
        let settings = Trading212SettingsStore(defaults: defaults).load()

        // Then the migration does not fire again and overwrite them
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
        let suiteName = "folync-alias-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let suiteName = "folync-isin-preview-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
        let suiteName = "instrument-alias-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
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

final class FolyncPortfolioSourceTests: XCTestCase {
    /// These tests drive Folync through a stubbed URLProtocol, so no live request
    /// is ever made. The real `.current` policy denies `.folync` under XCTest,
    /// which is the behaviour we want in production — so inject a permissive
    /// policy here rather than weakening the gate.
    private static let testProviderPolicy = StockbarProviderAccessPolicy(liveRequestsAllowed: true)

    @MainActor
    func testPortfolioMenuLoadsFolyncDayHistoryAndUsesReferenceOnlyWhenSparse() async throws {
        let suiteName = "FolyncMenuHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/client/v2/scopes/all/history")
            let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "range" }?.value ?? ""
            let sparse = range == "1d" && stub.isOffline
            let series = sparse
                ? "[{\"date\":\"2026-09-10T09:00:00Z\",\"value\":164447}]"
                : "[{\"date\":\"2026-09-10T08:55:00Z\",\"value\":165000},{\"date\":\"2026-09-10T09:00:00Z\",\"value\":164447}]"
            return Self.httpResponse(request, status: 200, body: """
            {"schemaVersion":2,"sourceRevision":"menu-test",
             "scope":{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"},
             "range":"\(range)","interval":"5m","generatedAt":"2026-09-10T09:01:00Z","currency":"GBP",
             "quality":"partial","reasonCodes":["insufficient_observations"],
             "coverage":{"pointCount":\(sparse ? 1 : 2),"complete":false},
             "portfolioSeries":\(series),"cashSeries":\(series),"holdingsSeries":\(series),
             "netContributionSeries":\(series),"gainSeries":\(series),"twrSeries":\(series)}
            """)
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy, tokenProvider: { "test-token" }
        )
        let model = PortfolioMenuChartViewModel(
            currentValue: 170000, currentTrades: [], preferredCurrency: "GBP", valuationSource: .folyncProvided,
            folyncCoordinator: coordinator, folyncSettingsStore: settingsStore
        )

        defer { model.deactivate() }
        XCTAssertTrue(stub.requests.isEmpty, "A hidden chart must not request history")

        func load(_ range: MenuChartTimeRange) async {
            let loaded = expectation(description: "Loaded \(range)")
            loaded.assertForOverFulfill = false
            let subscription = model.$isLoading.dropFirst().filter { !$0 }.sink { _ in loaded.fulfill() }
            model.activate()
            model.setTimeRange(range)
            model.loadChartData() // Explicit refresh also works when the range is unchanged.
            XCTAssertFalse(model.showsDayReference, "Do not cover a loading chart with the daily reference")
            await fulfillment(of: [loaded], timeout: 5)
            subscription.cancel()
        }

        await load(.day)
        XCTAssertEqual(model.chartData.map(\.price), [165000, 164447], "Never append the current snapshot to provider history")
        XCTAssertFalse(model.showsDayReference, "Partial but drawable history must still show its graph")
        XCTAssertTrue(model.coverageLabel.contains("Past 24 hours"))
        XCTAssertFalse(model.hasRangeCoverage)

        await load(.week)
        XCTAssertEqual(model.chartData.count, 2)
        XCTAssertFalse(model.showsDayReference)
        XCTAssertFalse(model.coverageLabel.contains("Past 24 hours"))

        stub.isOffline = true // Return only one intraday observation.
        await load(.day)
        XCTAssertEqual(model.chartData.count, 1)
        XCTAssertTrue(model.showsDayReference)

        stub.isOffline = false
        await load(.day)
        XCTAssertEqual(model.chartData.count, 2)
        XCTAssertFalse(model.showsDayReference, "New history must replace the fallback marker")
        XCTAssertEqual(model.loadGeneration, 4)
        XCTAssertEqual(stub.requests.count, 4, "Each presentation/range/refresh action should issue one request")
    }

    func testFolyncLineSeriesKeysSeparateRangesAndCustomBounds() {
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let firstEnd = firstStart.addingTimeInterval(86_400)
        let secondEnd = firstEnd.addingTimeInterval(86_400)

        let day = FolyncLineSeriesKey(symbol: " dftx ", timeRange: .day)
        let month = FolyncLineSeriesKey(symbol: "DFTX", timeRange: .month)
        let firstCustom = FolyncLineSeriesKey(
            symbol: "DFTX", timeRange: .custom, customFrom: firstStart, customTo: firstEnd
        )
        let secondCustom = FolyncLineSeriesKey(
            symbol: "DFTX", timeRange: .custom, customFrom: firstStart, customTo: secondEnd
        )

        XCTAssertEqual(day.symbol, "DFTX")
        XCTAssertNotEqual(day.storageKey, month.storageKey)
        XCTAssertNotEqual(firstCustom.storageKey, secondCustom.storageKey)
    }

    func testPortfolioHistoryDoesNotRequireSupplementalMarketCharts() async throws {
        let suiteName = "FolyncPortfolioHistory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let series = "[{\"date\":\"2026-08-29\",\"value\":160000},{\"date\":\"2026-09-04\",\"value\":165525}]"
        let body = """
        {"schemaVersion":2,"sourceRevision":"history-test",
         "scope":{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"},
         "range":"1w","interval":"1d","generatedAt":"2026-09-05T12:00:00Z","currency":"GBP",
         "quality":"partial","reasonCodes":["insufficient_observations"],
         "coverage":{"requestedFrom":"2026-08-29","requestedTo":"2026-09-05",
         "availableFrom":"2026-08-29","availableTo":"2026-09-04","pointCount":2,"complete":false},
         "portfolioSeries":\(series),"cashSeries":\(series),"holdingsSeries":\(series),
         "netContributionSeries":\(series),"gainSeries":\(series),"twrSeries":\(series)}
        """
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if stub.isOffline { throw URLError(.notConnectedToInternet) }
            XCTAssertEqual(request.url?.path, "/api/client/v2/scopes/all/history")
            return Self.httpResponse(request, status: 200, body: body)
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )
        guard case .folync(let history, let status) = await coordinator.routePortfolioHistory(range: "1w") else {
            return XCTFail("Authoritative portfolio history must work with all market routes disabled")
        }
        XCTAssertEqual(status, .partial)
        XCTAssertEqual(history.coverage.complete, false)
        let points = try XCTUnwrap(PortfolioMenuChartDataBuilder.providerPoints(
            history, scopeID: "all", currency: "GBP", range: .week
        ))
        XCTAssertEqual(points.map(\.price), [160000, 165525])
        XCTAssertEqual(points.last?.date, FolyncSupplementalDateParser.day("2026-09-04"))
        XCTAssertNil(PortfolioMenuChartDataBuilder.providerPoints(history, scopeID: "other", currency: "GBP", range: .week))
        XCTAssertNil(PortfolioMenuChartDataBuilder.providerPoints(history, scopeID: "all", currency: "USD", range: .week))
        XCTAssertNil(PortfolioMenuChartDataBuilder.providerPoints(history, scopeID: "all", currency: "GBP", range: .month))
        stub.isOffline = true
        guard case .folync(let cached, let cachedStatus) = await coordinator.routePortfolioHistory(range: "1w") else {
            return XCTFail("Expected separate Folync history cache while offline")
        }
        XCTAssertEqual(cachedStatus, .stale)
        XCTAssertEqual(cached, history)
    }

    func testOlderVersionTwoServerWithoutCapabilitiesRemainsPortfolioCompatible() async throws {
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if request.url?.path == "/api/client/v2/portfolios" {
                return Self.httpResponse(
                    request,
                    status: 200,
                    body: """
                    {"schemaVersion":2,"portfolios":[{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"}]}
                    """
                )
            }
            if request.url?.path == "/api/client/v2/capabilities" {
                return Self.httpResponse(request, status: 404, body: "{}")
            }
            return Self.httpResponse(request, status: 500, body: "{}")
        }
        let source = try FolyncPortfolioSource(
            baseURL: URL(string: "https://folync.test")!,
            token: "test-token",
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy
        )

        let portfolios = try await source.listPortfolios()
        let capabilities = try await source.fetchCapabilities()

        XCTAssertEqual(portfolios.map(\.id), ["all"])
        XCTAssertNil(capabilities)
    }

    func testSupplementalAliasRoutingUsesETagsStaleCacheAndNeverStoresToken() async throws {
        let suiteName = "FolyncSupplementalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-supplemental-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: true,
                candlestickCharts: true,
                benchmarkMarketData: false,
                exchangeRates: false,
                allowLegacyFallback: false
            )
        ))

        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if stub.isOffline { throw URLError(.notConnectedToInternet) }
            if request.url?.path == "/api/client/v2/capabilities" {
                return Self.httpResponse(
                    request,
                    status: request.value(forHTTPHeaderField: "If-None-Match") == "\"c1\"" ? 304 : 200,
                    body: Self.capabilitiesJSON,
                    etag: "\"c1\""
                )
            }
            if request.url?.path == "/api/client/v2/market/symbols/DFTX/history" {
                return Self.httpResponse(
                    request,
                    status: request.value(forHTTPHeaderField: "If-None-Match") == "\"h1\"" ? 304 : 200,
                    body: Self.historyJSON,
                    etag: "\"h1\""
                )
            }
            return Self.httpResponse(request, status: 404, body: "{}")
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token-never-cache" }
        )

        let first = try await coordinator.routeOHLC(symbol: "MNMD", period: "1mo", interval: "1d")
        guard case .folync(let firstPoints, let firstStatus, let firstMetadata) = first else {
            return XCTFail("Expected Folync OHLC response")
        }
        XCTAssertEqual(firstPoints.first?.symbol, "DFTX")
        XCTAssertNil(firstPoints.first?.volume, "Missing Folync volume must not be converted to a valid zero")
        XCTAssertEqual(firstStatus, .current)
        XCTAssertEqual(firstMetadata.pointCount, 1)
        XCTAssertFalse(firstMetadata.coverageComplete)
        let capabilities = await coordinator.capabilitiesForCurrentSettings()
        XCTAssertEqual(capabilities?.marketIdentities?.first?.identity.quoteSymbol, "DFTX")
        XCTAssertEqual(capabilities?.marketIdentities?.first?.intervals["1h"]?.pointCount, 1)

        let second = try await coordinator.routeOHLC(symbol: "DFTX", period: "1mo", interval: "1d")
        guard case .folync(_, let secondStatus, _) = second else {
            return XCTFail("Expected ETag-backed Folync response")
        }
        XCTAssertEqual(secondStatus, .current)
        XCTAssertTrue(stub.requests.contains {
            $0.url?.path.contains("/DFTX/history") == true
                && $0.value(forHTTPHeaderField: "If-None-Match") == "\"h1\""
        })

        let customFrom = try XCTUnwrap(FolyncSupplementalDateParser.day("2026-06-01"))
        let customTo = try XCTUnwrap(FolyncSupplementalDateParser.day("2026-06-30"))
        _ = try await coordinator.routeOHLC(
            symbol: "DFTX",
            period: "1mo",
            interval: "1d",
            from: customFrom,
            to: customTo
        )
        let customRequest = try XCTUnwrap(stub.requests.last {
            $0.url?.path == "/api/client/v2/market/symbols/DFTX/history"
                && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(URLQueryItem(name: "range", value: "custom")) == true
        })
        let customQuery = try XCTUnwrap(
            URLComponents(url: customRequest.url!, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertTrue(customQuery.contains(URLQueryItem(name: "from", value: "2026-06-01")))
        XCTAssertTrue(customQuery.contains(URLQueryItem(name: "to", value: "2026-06-30")))

        stub.isOffline = true
        let offline = try await coordinator.routeOHLC(symbol: "MNMD", period: "1mo", interval: "1d")
        guard case .folync(_, let offlineStatus, _) = offline else {
            return XCTFail("Expected last valid Folync cache")
        }
        XCTAssertEqual(offlineStatus, .stale)

        stub.isOffline = false
        let invalidVolume = Self.historyJSON.replacingOccurrences(of: "\"volume\":null", with: "\"volume\":-1")
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/capabilities" {
                return Self.httpResponse(request, status: 304, body: "", etag: "\"c1\"")
            }
            if request.url?.path == "/api/client/v2/market/symbols/DFTX/history" {
                return Self.httpResponse(request, status: 200, body: invalidVolume, etag: "\"h2\"")
            }
            return Self.httpResponse(request, status: 404, body: "{}")
        }
        guard case .folync(_, let invalidStatus, _) = try await coordinator.routeOHLC(
            symbol: "DFTX", period: "1mo", interval: "1d"
        ) else {
            return XCTFail("An invalid 200 volume must preserve the last valid Folync cache")
        }
        XCTAssertEqual(invalidStatus, .stale)

        let localOnly = try await coordinator.routeOHLC(symbol: "AAPL", period: "1mo", interval: "1d")
        guard case .legacy = localOnly else {
            return XCTFail("Untracked Stockbar-only watchlist symbols must stay local")
        }

        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        )
        let cacheBytes = try cacheFiles.reduce(into: Data()) { result, url in
            result.append(try Data(contentsOf: url))
        }
        XCTAssertNil(String(data: cacheBytes, encoding: .utf8)?.range(of: "test-token-never-cache"))
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-never-cache"
        })
    }

    func testSupplementalFallbackPrecedenceForDisabledAndUnsupportedRoutes() async throws {
        let suiteName = "FolyncFallbackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in Self.httpResponse(request, status: 404, body: "{}") }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )

        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: .disabled
        ))
        guard case .legacy = try await coordinator.routeOHLC(symbol: "DFTX", period: "1mo", interval: "1d") else {
            return XCTFail("A disabled route must use the local provider")
        }
        XCTAssertTrue(stub.requests.isEmpty)

        settingsStore.setSupplemental(FolyncSupplementalSettings(
            historicalLineCharts: false,
            candlestickCharts: true,
            benchmarkMarketData: false,
            exchangeRates: false,
            allowLegacyFallback: false
        ))
        guard case .unavailable = try await coordinator.routeOHLC(symbol: "DFTX", period: "1mo", interval: "1d") else {
            return XCTFail("An unsupported route without fallback must be unavailable")
        }

        settingsStore.setSupplemental(FolyncSupplementalSettings(
            historicalLineCharts: false,
            candlestickCharts: true,
            benchmarkMarketData: false,
            exchangeRates: false,
            allowLegacyFallback: true
        ))
        guard case .legacy = try await coordinator.routeOHLC(symbol: "DFTX", period: "1mo", interval: "1d") else {
            return XCTFail("An unsupported route with fallback must use one complete local series")
        }
    }

    func testCapabilitiesRemainDiscoverableWhenMigratedSupplementalRoutesAreDisabled() async throws {
        let suiteName = "FolyncCapabilityDiscoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-capability-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: .disabled
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            guard request.url?.path == "/api/client/v2/capabilities" else {
                return Self.httpResponse(request, status: 599, body: "{}")
            }
            return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON, etag: "\"c1\"")
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )

        let capabilities = await coordinator.capabilitiesForCurrentSettings()

        XCTAssertEqual(capabilities?.resources.lineHistory.ready, true)
        XCTAssertEqual(stub.requests.map(\.url?.path), ["/api/client/v2/capabilities"])
        XCTAssertEqual(settingsStore.load().supplemental, .disabled)

        let refreshed = await coordinator.capabilitiesForCurrentSettings(refresh: true)
        XCTAssertEqual(refreshed?.sourceRevision, capabilities?.sourceRevision)
        XCTAssertEqual(stub.requests.map(\.url?.path), [
            "/api/client/v2/capabilities", "/api/client/v2/capabilities"
        ])
        XCTAssertEqual(stub.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"c1\"")
    }

    func testExplicitMarketIdentityReadinessCannotBeBypassedByTrackedSymbol() async throws {
        let suiteName = "FolyncMissingIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-missing-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: false,
                candlestickCharts: true,
                benchmarkMarketData: false,
                exchangeRates: false,
                allowLegacyFallback: false
            )
        ))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(Self.readyMarketCapabilitiesJSON.utf8)) as? [String: Any]
        )
        object["marketIdentities"] = []
        let body = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            guard request.url?.path == "/api/client/v2/capabilities" else {
                return Self.httpResponse(request, status: 599, body: "{}")
            }
            return Self.httpResponse(request, status: 200, body: body)
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )

        guard case .unavailable = try await coordinator.routeOHLC(
            symbol: "DFTX", period: "1mo", interval: "1d"
        ) else {
            return XCTFail("An explicit capability list without DFTX must not inherit global readiness")
        }
        XCTAssertFalse(stub.requests.contains { $0.url?.path.contains("/history") == true })
    }

    func testSupplementalBenchmarkAndFXRoutesUseFolyncWithoutLegacyRequests() async throws {
        let suiteName = "FolyncBenchmarkFXTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-benchmark-fx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.test",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: false,
                candlestickCharts: false,
                benchmarkMarketData: true,
                exchangeRates: true,
                allowLegacyFallback: false
            )
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            case "/api/client/v2/market/benchmarks":
                return Self.httpResponse(request, status: 200, body: Self.benchmarksJSON, etag: "\"b1\"")
            case "/api/client/v2/market/fx":
                return Self.httpResponse(request, status: 200, body: Self.fxJSON, etag: "\"fx1\"")
            default:
                return Self.httpResponse(request, status: 599, body: "{}")
            }
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )

        guard case .folync(let benchmarks, let benchmarkStatus) = await coordinator.routeBenchmarks() else {
            return XCTFail("Expected Folync benchmark overlay data")
        }
        XCTAssertEqual(benchmarkStatus, .current)
        XCTAssertEqual(benchmarks.map(\.symbol), ["^GSPC", "^FTSE"])
        XCTAssertEqual(benchmarks.first?.current.last, 6_300)

        guard case .folync(let rates, _, let fxStatus) = await coordinator.routeFX() else {
            return XCTFail("Expected Folync USD-base FX data")
        }
        XCTAssertEqual(fxStatus, .current)
        XCTAssertEqual(rates["USD"], 1)
        XCTAssertEqual(rates["GBP"], 0.79)
        XCTAssertEqual(rates["JPY"], 159.2)
        XCTAssertEqual(stub.requests.filter { $0.url?.path == "/api/client/v2/market/benchmarks" }.count, 1)
        XCTAssertEqual(stub.requests.filter { $0.url?.path == "/api/client/v2/market/fx" }.count, 1)
        XCTAssertTrue(stub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        })

        let unusableBenchmarks = Self.benchmarksJSON
            .replacingOccurrences(of: "\"last\":6300", with: "\"last\":null")
            .replacingOccurrences(of: "\"last\":9200", with: "\"last\":null")
        let incompleteFX = Self.fxJSON.replacingOccurrences(
            of: "{\"quote\":\"AUD\",\"rate\":1.52,\"asOf\":\"2026-07-13\",\"quality\":\"complete\",\"reasonCodes\":[]}",
            with: "{\"quote\":\"AUD\",\"rate\":null,\"asOf\":null,\"quality\":\"unavailable\",\"reasonCodes\":[\"missing_fx\"]}"
        )
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            case "/api/client/v2/market/benchmarks":
                return Self.httpResponse(request, status: 200, body: unusableBenchmarks, etag: "\"b2\"")
            case "/api/client/v2/market/fx":
                return Self.httpResponse(request, status: 200, body: incompleteFX, etag: "\"fx2\"")
            default:
                return Self.httpResponse(request, status: 599, body: "{}")
            }
        }

        guard case .folync(let cachedBenchmarks, let cachedBenchmarkStatus) = await coordinator.routeBenchmarks() else {
            return XCTFail("An unusable 200 response must fall back to the last valid Folync benchmark cache")
        }
        XCTAssertEqual(cachedBenchmarkStatus, .stale)
        XCTAssertEqual(cachedBenchmarks.first?.current.last, 6_300)

        guard case .folync(let cachedRates, _, let cachedFXStatus) = await coordinator.routeFX() else {
            return XCTFail("A partial FX table must fall back to the complete last valid Folync cache")
        }
        XCTAssertEqual(cachedFXStatus, .stale)
        XCTAssertEqual(cachedRates["AUD"], 1.52)
    }

    func testTransportPolicyRequiresHTTPSExceptForLoopback() throws {
        XCTAssertNoThrow(try FolyncEndpointPolicy.validate(URL(string: "https://folync.example.com")!))
        XCTAssertNoThrow(try FolyncEndpointPolicy.validate(URL(string: "http://127.0.0.1:3000")!))
        XCTAssertNoThrow(try FolyncEndpointPolicy.validate(URL(string: "http://localhost:3000")!))
        XCTAssertThrowsError(try FolyncEndpointPolicy.validate(URL(string: "http://192.168.0.10:3000")!))
    }

    func testFolyncBaseURLWithPortKeepsPortAndSurfacesRateLimit() async throws {
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            XCTAssertEqual(request.url?.host, "folync.test")
            XCTAssertEqual(request.url?.port, 13000)
            XCTAssertEqual(request.url?.path, "/api/client/v2/scopes/all/snapshot")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Retry-After": "42"]
            )!
            let body = #"{"statusCode":429,"data":{"code":"too_many_failed_attempts","retryable":true}}"#
            return (response, Data(body.utf8))
        }
        let source = try FolyncPortfolioSource(
            baseURL: URL(string: "https://folync.test:13000")!, token: "test-token",
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy
        )
        do {
            _ = try await source.fetchSnapshot(scopeID: "all", etag: nil)
            XCTFail("A 429 must not decode as a snapshot")
        } catch {
            XCTAssertEqual(error as? FolyncPortfolioSourceError, .rateLimited(retryAfter: 42))
        }
        XCTAssertEqual(stub.requests.count, 1, "A 429 must not trigger the v1 fallback")
    }

    func testDecodesVersionOneSnapshotIntoReadOnlyDisplayTrades() throws {
        let data = Data(snapshotJSON.utf8)
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(data)

        XCTAssertEqual(snapshot.scope.id, "pf_isa")
        XCTAssertEqual(snapshot.totalValue.value, 1100)
        XCTAssertEqual(snapshot.holdings.count, 1)

        let trades = snapshot.makeDisplayTrades(overlays: [:])
        let trade = try XCTUnwrap(trades.first)
        XCTAssertEqual(trade.trade.name, "VOD")
        XCTAssertEqual(trade.trade.position.unitSize, 100)
        XCTAssertEqual(trade.trade.position.positionAvgCost, 2.01)
        XCTAssertEqual(trade.realTimeInfo.currentPrice, 3)
        XCTAssertEqual(trade.realTimeInfo.previousClose, 2)
        XCTAssertEqual(trade.realTimeInfo.currency, "GBP")
        XCTAssertEqual(trade.sourceIdentity, "pf_isa|pf_isa|asset_vod")
    }

    func testDecodesVersionTwoIdentityAndUsesQuoteSymbolForAggregateDisplay() throws {
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(versionTwoSnapshotJSON.utf8))
        let holding = try XCTUnwrap(snapshot.holdings.first)

        XCTAssertEqual(holding.resolvedCanonicalTicker, "MNMD")
        XCTAssertEqual(holding.resolvedDisplayTicker, "DFTX")
        XCTAssertEqual(holding.resolvedAliases, ["MNMD", "DFTX"])
        XCTAssertEqual(snapshot.preferredAliasMap, ["MNMD": "DFTX"])

        let trade = try XCTUnwrap(snapshot.makeDisplayTrades(overlays: [:]).first)
        XCTAssertEqual(trade.trade.name, "DFTX")
        XCTAssertEqual(trade.realTimeInfo.shortName, "Definium Therapeutics · ISA")
        XCTAssertEqual(trade.sourceIdentity, "all|pf_isa|asset_mnmd")
        XCTAssertEqual(trade.displayLabel, "DFTX · ISA")
    }

    func testFolyncHoldingKeepsPriceAndCostUnitsSeparateFromPortfolioValueUnits() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(versionTwoSnapshotJSON.utf8)) as? [String: Any]
        )
        var holdings = try XCTUnwrap(object["holdings"] as? [[String: Any]])
        holdings[0]["currency"] = "USD"
        holdings[0]["averageCost"] = 76.794867
        holdings[0]["averageCostCurrency"] = "USD"
        holdings[0]["averageCostSource"] = "broker_position"
        holdings[0]["valueCurrency"] = "GBP"
        holdings[0]["currentPrice"] = 978.41
        holdings[0]["costValue"] = 8_863.55
        object["holdings"] = holdings

        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(
            JSONSerialization.data(withJSONObject: object)
        )
        let holding = try XCTUnwrap(snapshot.holdings.first)
        let trade = try XCTUnwrap(snapshot.makeDisplayTrades(overlays: [:]).first)

        XCTAssertEqual(holding.resolvedAverageCostCurrency, "USD")
        XCTAssertEqual(holding.resolvedValueCurrency, "GBP")
        XCTAssertEqual(trade.trade.position.positionAvgCost, 76.794867, accuracy: 0.000001)
        XCTAssertEqual(trade.trade.position.currency, "USD")
        XCTAssertEqual(trade.trade.position.costCurrency, "USD")
        XCTAssertEqual(trade.realTimeInfo.currentPrice, 978.41, accuracy: 0.000001)
        XCTAssertEqual(trade.realTimeInfo.currency, "USD")
    }

    func testAggregateSameAssetRowsKeepDistinctPortfolioIdentityAndLabels() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(versionTwoSnapshotJSON.utf8)) as? [String: Any]
        )
        var holdings = try XCTUnwrap(object["holdings"] as? [[String: Any]])
        var giaHolding = try XCTUnwrap(holdings.first)
        giaHolding["portfolioId"] = "pf_gia"
        giaHolding["portfolioName"] = "GIA"
        giaHolding["shares"] = 10
        giaHolding["averageCost"] = 9
        holdings.append(giaHolding)
        object["holdings"] = holdings
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(
            JSONSerialization.data(withJSONObject: object)
        )

        let trades = snapshot.makeDisplayTrades(overlays: [:])
        XCTAssertEqual(trades.map(\.trade.name), ["DFTX", "DFTX"])
        XCTAssertEqual(Set(trades.compactMap(\.sourceIdentity)), Set([
            "all|pf_isa|asset_mnmd",
            "all|pf_gia|asset_mnmd"
        ]))
        XCTAssertEqual(Set(trades.compactMap(\.displayLabel)), Set(["DFTX · ISA", "DFTX · GIA"]))
    }

    func testAggregateTrading212FullHistoryUsesShortFolyncDisplayLabel() throws {
        let json = versionTwoSnapshotJSON.replacingOccurrences(
            of: "\"portfolioName\": \"ISA\"",
            with: "\"portfolioName\": \"Trading 212 Live Full History\""
        )
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(json.utf8))
        let trade = try XCTUnwrap(snapshot.makeDisplayTrades(overlays: [:]).first)

        XCTAssertEqual(trade.displayLabel, "DFTX · T212 Folync")
        XCTAssertEqual(trade.realTimeInfo.shortName, "Definium Therapeutics · T212 Folync")
    }

    func testFolyncDisplayHidesHoldingsBelowMinimumUnitThreshold() throws {
        let json = snapshotJSON.replacingOccurrences(
            of: "\"shares\": 100",
            with: "\"shares\": 0.00009"
        )
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(json.utf8))

        XCTAssertEqual(snapshot.holdings.count, 1)
        XCTAssertTrue(snapshot.displayHoldings.isEmpty)
        XCTAssertTrue(snapshot.makeDisplayTrades(overlays: [:]).isEmpty)
    }

    func testFolyncDisplayIncludesHoldingsAtMinimumUnitThreshold() throws {
        let json = snapshotJSON.replacingOccurrences(
            of: "\"shares\": 100",
            with: "\"shares\": 0.0001"
        )
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(json.utf8))

        XCTAssertEqual(snapshot.displayHoldings.count, 1)
        XCTAssertEqual(snapshot.makeDisplayTrades(overlays: [:]).first?.trade.position.unitSize, 0.0001)
    }

    func testRejectsUnsupportedSchemaAndNonFiniteFinancialValues() throws {
        XCTAssertThrowsError(try FolyncPortfolioDecoder().decodeSnapshot(Data(snapshotJSON.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 3").utf8)))
        XCTAssertThrowsError(try FolyncPortfolioDecoder().decodeSnapshot(Data(snapshotJSON.replacingOccurrences(of: "\"shares\": 100", with: "\"shares\": 1e999").utf8)))
    }

    func testFolyncPortfolioProjectionPreservesLegacyPortfolioAndWatchlists() throws {
        let legacyHolding = RealTimeTrade(
            trade: Trade(name: "AAPL", position: Position(unitSize: "2", positionAvgCost: "100", currency: "USD")),
            realTimeInfo: TradingInfo()
        )
        let watchlist = RealTimeTrade(
            trade: Trade(
                name: "MSFT",
                position: Position(unitSize: "0", positionAvgCost: "0", currency: "USD"),
                isWatchlistOnly: true
            ),
            realTimeInfo: TradingInfo()
        )
        let legacy = [legacyHolding, watchlist]
        let snapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(snapshotJSON.utf8))

        let projected = makeFolyncPortfolioTrades(snapshot: snapshot, preserving: legacy, overlays: [:])

        XCTAssertEqual(projected.map(\.trade.name), ["VOD", "MSFT"])
        XCTAssertEqual(legacy.map(\.trade.name), ["AAPL", "MSFT"])
        XCTAssertTrue(projected.last?.trade.isWatchlistOnly == true)
    }

    @MainActor
    func testSlowKeychainReadIsReportedAsWaitingForKeychainAccess() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        // The token read blocks, as it does while macOS shows its Keychain prompt.
        let (prompt, answer) = AsyncStream<Void>.makeStream()
        var dependencies = env.dependencies
        dependencies.keychainWaitNoticeDelay = 0.01
        dependencies.loadToken = {
            for await _ in prompt { break }
            return "test-token"
        }
        let dataModel = makeTestDataModel(dependencies: dependencies)
        XCTAssertEqual(dataModel.folyncConnectionState, .notConfigured)

        let generation = dataModel.folyncRefreshGeneration
        let reading = Task { @MainActor in
            await dataModel.waitForStoredFolyncCredentials(generation: generation)
        }
        for _ in 0..<200 where dataModel.folyncConnectionState != .waitingForKeychain {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(dataModel.folyncConnectionState, .waitingForKeychain)
        XCTAssertTrue(dataModel.folyncConnectionState.message.contains("Always Allow"))

        answer.yield()
        answer.finish()
        await reading.value
        XCTAssertEqual(dataModel.folyncConnectionState, .connecting)
    }

    func testBlockedKeychainReadDoesNotBlockTheSupplementalCoordinator() async throws {
        let suiteName = "FolyncKeychainActor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in Self.httpResponse(request, status: 404, body: "{}") }
        // The token read blocks, as it does while macOS shows its Keychain prompt.
        let readStarted = expectation(description: "Token read started")
        let answer = DispatchSemaphore(value: 0)
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy,
            tokenProvider: {
                readStarted.fulfill()
                answer.wait()
                return "test-token"
            }
        )

        let reading = Task { await coordinator.capabilitiesForCurrentSettings() }
        await fulfillment(of: [readStarted], timeout: 2)

        let cleared = expectation(description: "Backoff cleared while the token read waits")
        Task {
            await coordinator.clearBackoff()
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2)

        answer.signal()
        _ = await reading.value
    }

    @MainActor
    func testFastKeychainReadDoesNotShowTheWaitingNotice() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        var dependencies = env.dependencies
        dependencies.keychainWaitNoticeDelay = 5
        let dataModel = makeTestDataModel(dependencies: dependencies)

        await dataModel.waitForStoredFolyncCredentials(generation: dataModel.folyncRefreshGeneration)
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(dataModel.folyncConnectionState, .notConfigured)
    }

    @MainActor
    func testCorruptFolyncSnapshotCacheIsRemovedAndDoesNotBlockPolling() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }

        let endpoint = "https://folync.example.invalid"
        let scopeID = "all"
        let validSnapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(versionTwoSnapshotJSON.utf8))
        try await env.snapshotCache.save(FolyncCachedSnapshot(
            endpoint: endpoint,
            scopeID: scopeID,
            etag: "\"old\"",
            snapshot: validSnapshot
        ))
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: env.cacheDirectory, includingPropertiesForKeys: nil)
        let cacheFile = try XCTUnwrap(cacheFiles.first)
        try Data("not-valid-json".utf8).write(to: cacheFile, options: .atomic)

        await XCTAssertThrowsErrorAsync(
            try await env.snapshotCache.load(endpoint: endpoint, scopeID: scopeID)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))

        // Write corrupt bytes again so refreshFolyncPortfolio also hits the corrupt preload path.
        try Data("still-corrupt-json".utf8).write(to: cacheFile, options: .atomic)

        let snapshotBody = versionTwoSnapshotJSON
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/scopes/all/snapshot" {
                return Self.httpResponse(request, status: 200, body: snapshotBody, etag: "\"fresh\"")
            }
            return Self.httpResponse(request, status: 404, body: "{}")
        }

        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: endpoint,
            scopeID: scopeID,
            pollingIntervalSeconds: 60
        ))
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }

        await dataModel.refreshFolyncPortfolio()

        XCTAssertEqual(dataModel.folyncPortfolioSnapshot?.scope.id, "all")
        XCTAssertEqual(dataModel.folyncETag, "\"fresh\"")
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))
        let reloaded = try await env.snapshotCache.load(endpoint: endpoint, scopeID: scopeID)
        XCTAssertEqual(reloaded?.etag, "\"fresh\"")
    }

    func testSupplementalRoutesShareAndEnforceBackoffOn401And429() async throws {
        let suiteName = "FolyncBackoffSupplemental-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: true,
                candlestickCharts: true,
                benchmarkMarketData: true,
                exchangeRates: true,
                allowLegacyFallback: false
            )
        ))
        let backoff = FolyncBackoffCoordinator()
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/capabilities" {
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            }
            if request.url?.path == "/api/client/v2/market/fx" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "Retry-After": "180"]
                )!
                return (response, Data("{}".utf8))
            }
            return Self.httpResponse(request, status: 200, body: "{}")
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            backoff: backoff,
            tokenProvider: { "test-token" }
        )

        _ = await coordinator.capabilitiesForCurrentSettings()
        let fxResult = await coordinator.routeFX()
        guard case .unavailable = fxResult else {
            return XCTFail("Expected 429 FX response to return unavailable when no cache exists")
        }
        let isBackingOff = await coordinator.isBackingOff()
        XCTAssertTrue(isBackingOff, "429 from FX route must record shared Folync backoff")
        let requestCountAfter429 = stub.requests.count

        // All on-demand and supplemental routes must skip network calls while backing off.
        _ = await coordinator.routePortfolioHistory(range: "1w")
        _ = try await coordinator.routeOHLC(symbol: "DFTX", period: "1mo", interval: "1d")
        _ = await coordinator.routeLineHistory(symbol: "DFTX", range: "1m")
        _ = await coordinator.routeBenchmarks()
        _ = await coordinator.routeFX()
        XCTAssertEqual(stub.requests.count, requestCountAfter429, "No supplemental route may make network requests during backoff")

        // Clearing backoff and receiving 401 on portfolio history must also trigger backoff.
        await coordinator.clearBackoff()
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/scopes/all/history" {
                return Self.httpResponse(request, status: 401, body: "{}")
            }
            return Self.httpResponse(request, status: 200, body: Self.fxJSON)
        }
        _ = await coordinator.routePortfolioHistory(range: "1w")
        let backingOffAfter401 = await coordinator.isBackingOff()
        XCTAssertTrue(backingOffAfter401, "401 from portfolio history route must record shared Folync backoff")
        let countAfter401 = stub.requests.count
        _ = await coordinator.routeFX()
        XCTAssertEqual(stub.requests.count, countAfter401, "FX route must skip network while 401 backoff is active")
    }

    @MainActor
    func testTestConnectionAndPreviewDoNotMutateActiveSessionStateAndRestoreOnFailure() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }

        let activeSnapshot = try FolyncPortfolioDecoder().decodeSnapshot(Data(versionTwoSnapshotJSON.utf8))
        let activeCaps = FolyncCapabilities.fixture(lineHistory: true, candlesticks: true, benchmarks: false, exchangeRates: false)
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }
        dataModel.applyFolyncSnapshot(activeSnapshot)
        dataModel.folyncCapabilities = activeCaps
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))

        let previewSnapshotBody = snapshotJSON
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/portfolios":
                return Self.httpResponse(
                    request,
                    status: 200,
                    body: #"{"schemaVersion":2,"portfolios":[{"id":"pf_isa","name":"ISA","kind":"portfolio","currency":"GBP"}]}"#
                )
            case "/api/client/v2/scopes/pf_isa/snapshot":
                return Self.httpResponse(request, status: 200, body: previewSnapshotBody)
            default:
                return Self.httpResponse(request, status: 404, body: "{}")
            }
        }

        let portfolios = try await dataModel.testFolyncConnection(
            baseURL: URL(string: "https://folync.example.invalid")!,
            token: "test-token"
        )
        XCTAssertEqual(portfolios.map(\.id), ["pf_isa"])
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))
        XCTAssertEqual(dataModel.folyncCapabilities, activeCaps)

        let preview = try await dataModel.previewFolyncPortfolio(
            baseURL: URL(string: "https://folync.example.invalid")!,
            token: "test-token",
            scopeID: "pf_isa"
        )
        XCTAssertEqual(preview.scope.id, "pf_isa")
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))
        XCTAssertEqual(dataModel.folyncPortfolioSnapshot?.scope.id, "all")

        // Now force failures on test, preview, and activate and verify active state is preserved.
        stub.handler = { request in
            Self.httpResponse(request, status: 401, body: "{}")
        }
        await XCTAssertThrowsErrorAsync(
            try await dataModel.testFolyncConnection(baseURL: URL(string: "https://folync.example.invalid")!, token: "bad-token")
        )
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))
        XCTAssertEqual(dataModel.folyncCapabilities, activeCaps)

        await XCTAssertThrowsErrorAsync(
            try await dataModel.previewFolyncPortfolio(
                baseURL: URL(string: "https://folync.example.invalid")!,
                token: "bad-token",
                scopeID: "pf_isa"
            )
        )
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))

        await XCTAssertThrowsErrorAsync(
            try await dataModel.activateFolyncPortfolio(
                baseURL: URL(string: "https://folync.example.invalid")!,
                token: "bad-token",
                scopeID: "pf_isa"
            )
        )
        XCTAssertEqual(dataModel.folyncConnectionState, .current(asOf: "2026-07-11"))
    }

    @MainActor
    func testOverlappingSupplementalRestartsAndInFlightDeactivationDoNotLeakOrResurrectState() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }

        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "all",
            pollingIntervalSeconds: 60
        ))
        let snapshotBody = versionTwoSnapshotJSON
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/capabilities" {
                Thread.sleep(forTimeInterval: 0.05)
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            }
            if request.url?.path == "/api/client/v2/scopes/all/snapshot" {
                Thread.sleep(forTimeInterval: 0.05)
                return Self.httpResponse(request, status: 200, body: snapshotBody, etag: "\"e1\"")
            }
            return Self.httpResponse(request, status: 404, body: "{}")
        }

        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }

        // F68: Overlapping supplemental scheduler restarts must only keep the latest timer.
        async let firstRestart: Void = dataModel.restartFolyncSupplementalScheduler(runImmediately: true)
        async let secondRestart: Void = dataModel.restartFolyncSupplementalScheduler(runImmediately: true)
        _ = await (firstRestart, secondRestart)
        let activeTimer = try XCTUnwrap(dataModel.folyncSupplementalRefreshTimer)
        XCTAssertTrue(activeTimer.isValid)

        // F69: Deactivating while a portfolio refresh is in-flight must not apply results after deactivation.
        let refreshTask = Task { @MainActor in
            await dataModel.refreshFolyncPortfolio()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        dataModel.deactivateFolyncPortfolio()
        await refreshTask.value

        XCTAssertNil(dataModel.folyncPortfolioSnapshot)
        XCTAssertFalse(dataModel.isFolyncPortfolioActive)
        XCTAssertFalse(dataModel.isFolyncEnabled)
        XCTAssertEqual(dataModel.folyncConnectionState, .notConfigured)
        XCTAssertNil(dataModel.folyncRefreshTimer)
        XCTAssertNil(dataModel.folyncSupplementalRefreshTimer)
        XCTAssertFalse(activeTimer.isValid)
    }

    func testExtraAdvertisedFXQuotesAreRequestedAndAccepted() async throws {
        let suiteName = "FolyncExtraFXQuotes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: false,
                candlestickCharts: false,
                benchmarkMarketData: false,
                exchangeRates: true,
                allowLegacyFallback: false
            )
        ))
        let extraCaps = Self.readyMarketCapabilitiesJSON.replacingOccurrences(
            of: "\"quotes\":[\"GBP\",\"EUR\",\"JPY\",\"CAD\",\"AUD\"]",
            with: "\"quotes\":[\"GBP\",\"EUR\",\"JPY\",\"CAD\",\"AUD\",\"CHF\"]"
        )
        let extraFX = Self.fxJSON.replacingOccurrences(
            of: "{\"quote\":\"AUD\",\"rate\":1.52,\"asOf\":\"2026-07-13\",\"quality\":\"complete\",\"reasonCodes\":[]}",
            with: """
            {"quote":"AUD","rate":1.52,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]},
            {"quote":"CHF","rate":0.88,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]}
            """
        )
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: extraCaps)
            case "/api/client/v2/market/fx":
                let quotesQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "quotes" })?.value
                XCTAssertEqual(quotesQuery, "GBP,EUR,JPY,CAD,AUD,CHF")
                return Self.httpResponse(request, status: 200, body: extraFX, etag: "\"fx-extra\"")
            default:
                return Self.httpResponse(request, status: 404, body: "{}")
            }
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: { "test-token" }
        )

        guard case .folync(let rates, _, let status) = await coordinator.routeFX() else {
            return XCTFail("Expected FX route to succeed when extra quotes are advertised by capabilities")
        }
        XCTAssertEqual(status, .current)
        XCTAssertEqual(rates["CHF"], 0.88)
        XCTAssertEqual(rates["GBP"], 0.79)
    }

    @MainActor
    func testEnabledButInactiveSessionMapsRateLimitAndServerErrorsAndCanBeDisabled() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }

        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "all",
            pollingIntervalSeconds: 60
        ))
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }

        XCTAssertFalse(dataModel.isFolyncPortfolioActive)
        XCTAssertTrue(dataModel.isFolyncEnabled)

        dataModel.markFolyncRefreshFailure(FolyncPortfolioSourceError.rateLimited(retryAfter: 60))
        XCTAssertEqual(dataModel.folyncConnectionState, .rateLimited(retryAfter: 60))
        XCTAssertTrue(dataModel.folyncConnectionState.message.contains("Retrying after 60 seconds"))

        dataModel.markFolyncRefreshFailure(FolyncPortfolioSourceError.unavailable(503))
        XCTAssertEqual(dataModel.folyncConnectionState, .unavailable(message: "Folync request failed with HTTP 503."))

        dataModel.markFolyncRefreshFailure(FolyncPortfolioSourceError.unauthorized)
        XCTAssertEqual(dataModel.folyncConnectionState, .unauthorized)

        dataModel.deactivateFolyncPortfolio()
        XCTAssertFalse(dataModel.isFolyncEnabled)
        XCTAssertEqual(dataModel.folyncConnectionState, .notConfigured)
    }

    @MainActor
    func testSetupMistakesSurfaceSpecificErrorsAndTokenFallbackAndUnwritableCacheStillPolls() async throws {
        XCTAssertThrowsError(try FolyncEndpointPolicy.validate(URL(string: "folync.example.invalid")!)) { error in
            XCTAssertEqual(error as? FolyncPortfolioSourceError, .invalidEndpoint)
        }
        XCTAssertThrowsError(
            try FolyncPortfolioSource(
                baseURL: URL(string: "https://folync.example.invalid")!,
                token: "   ",
                session: Self.stubSession(),
                providerPolicy: Self.testProviderPolicy
            )
        ) { error in
            XCTAssertEqual(error as? FolyncPortfolioSourceError, .missingToken)
        }
        XCTAssertThrowsError(try FolyncPortfolioSource.validateScopeComponent("../bad")) { error in
            XCTAssertEqual(
                error as? FolyncPortfolioSourceError,
                .invalidScope("Scope identifier is not a valid path component")
            )
        }

        let env = try makeIsolatedSessionEnvironment(storedToken: "keychain-fallback-token")
        defer { env.cleanup() }
        // Make a file at the snapshot cache directory path so snapshotCache.save fails, testing F75.
        let blockingCachePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-blocking-file-\(UUID().uuidString)")
        try Data("file".utf8).write(to: blockingCachePath)
        defer { try? FileManager.default.removeItem(at: blockingCachePath) }

        var deps = env.dependencies
        deps.snapshotCache = FolyncSnapshotCache(directory: blockingCachePath)
        let dataModel = makeTestDataModel(dependencies: deps)
        defer { dataModel.deactivateFolyncPortfolio() }

        let snapshotBody = versionTwoSnapshotJSON
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer keychain-fallback-token")
            switch request.url?.path {
            case "/api/client/v2/portfolios":
                return Self.httpResponse(
                    request,
                    status: 200,
                    body: #"{"schemaVersion":2,"portfolios":[{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"}]}"#
                )
            case "/api/client/v2/scopes/all/snapshot":
                return Self.httpResponse(request, status: 200, body: snapshotBody, etag: "\"e-act\"")
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            default:
                return Self.httpResponse(request, status: 404, body: "{}")
            }
        }

        // Empty token falls back to stored token for testConnection, preview, and activate.
        let portfolios = try await dataModel.testFolyncConnection(
            baseURL: URL(string: "https://folync.example.invalid")!,
            token: ""
        )
        XCTAssertEqual(portfolios.map(\.id), ["all"])

        let preview = try await dataModel.previewFolyncPortfolio(
            baseURL: URL(string: "https://folync.example.invalid")!,
            token: "",
            scopeID: "all"
        )
        XCTAssertEqual(preview.scope.id, "all")

        // F75: Even when snapshotCache.save throws, activateFolyncPortfolio commits and starts polling.
        try await dataModel.activateFolyncPortfolio(
            baseURL: URL(string: "https://folync.example.invalid")!,
            token: "",
            scopeID: "all"
        )
        XCTAssertTrue(dataModel.isFolyncPortfolioActive)
        XCTAssertNotNil(dataModel.folyncNextCheckAt)
        XCTAssertEqual(dataModel.folyncRefreshTimer?.isValid, true)
    }

    @MainActor
    func testPartialBenchmarkResponseAppliesUsableBenchmarksAndMarksUnavailablePerSymbol() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "all",
            pollingIntervalSeconds: 60,
            supplemental: FolyncSupplementalSettings(
                historicalLineCharts: false,
                candlestickCharts: false,
                benchmarkMarketData: true,
                exchangeRates: false,
                allowLegacyFallback: false
            )
        ))
        let partialBenchmarks = Self.benchmarksJSON
            .replacingOccurrences(
                of: """
                      "id":"sp500","symbol":"^GSPC","name":"S&P 500","currency":"USD","provider":"yahoo-cache",
                      "current":{"last":6300,"previousClose":6240,"change":60,"changePct":0.961538,"asOf":"2026-07-13T10:00:00.000Z"},
                      "quality":"complete","stale":false,"reasonCodes":[],
                """,
                with: """
                      "id":"sp500","symbol":"^GSPC","name":"S&P 500","currency":"USD","provider":"yahoo-cache",
                      "current":{"last":null,"previousClose":6240,"change":null,"changePct":null,"asOf":"2026-07-13T10:00:00.000Z"},
                      "quality":"unavailable","stale":false,"reasonCodes":["provider_timeout"],
                """
            )
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            case "/api/client/v2/market/benchmarks":
                return Self.httpResponse(request, status: 200, body: partialBenchmarks, etag: "\"b-partial\"")
            default:
                return Self.httpResponse(request, status: 404, body: "{}")
            }
        }

        guard case .folync(let benchmarks, let status) = await env.supplementalCoordinator.routeBenchmarks() else {
            return XCTFail("Expected partial benchmark response to be accepted when at least one benchmark is usable")
        }
        XCTAssertEqual(status, .partial)

        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        let gspc = RealTimeTrade(
            trade: Trade(name: "^GSPC", position: Position(unitSize: "0", positionAvgCost: "0"), isWatchlistOnly: true),
            realTimeInfo: TradingInfo()
        )
        let ftse = RealTimeTrade(
            trade: Trade(name: "^FTSE", position: Position(unitSize: "0", positionAvgCost: "0"), isWatchlistOnly: true),
            realTimeInfo: TradingInfo()
        )
        dataModel.realTimeTrades = [gspc, ftse]
        dataModel.applyFolyncBenchmarkOverlays(benchmarks)

        XCTAssertTrue(gspc.realTimeInfo.currentPrice.isNaN)
        XCTAssertEqual(gspc.realTimeInfo.errorMessage, "Folync benchmark unavailable: provider_timeout")
        XCTAssertEqual(ftse.realTimeInfo.currentPrice, 9_200)
        XCTAssertNil(ftse.realTimeInfo.errorMessage)
    }

    @MainActor
    private func makeTestDataModel(dependencies: FolyncSessionDependencies) -> DataModel {
        let model = DataModel(
            currencyConverter: CurrencyConverter(refreshOnInit: false, loadHistoryOnInit: false),
            startRuntimeServices: false
        )
        model.folyncSessionDependencies = dependencies
        return model
    }

    private struct IsolatedSessionEnvironment {
        let settingsStore: FolyncSettingsStore
        let snapshotCache: FolyncSnapshotCache
        let overlayStore: FolyncOverlayStore
        let supplementalCoordinator: FolyncSupplementalCoordinator
        let cacheDirectory: URL
        let dependencies: FolyncSessionDependencies
        let cleanup: () -> Void
    }

    private func makeIsolatedSessionEnvironment(storedToken: String = "test-token") throws -> IsolatedSessionEnvironment {
        let suiteName = "FolyncSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        let supplementalCacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName)-supp", isDirectory: true)
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        let snapshotCache = FolyncSnapshotCache(directory: cacheDirectory)
        let overlayStore = FolyncOverlayStore(defaults: defaults)
        let backoff = FolyncBackoffCoordinator()
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: supplementalCacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            backoff: backoff,
            tokenProvider: { storedToken }
        )
        let dependencies = FolyncSessionDependencies(
            settingsStore: settingsStore,
            snapshotCache: snapshotCache,
            overlayStore: overlayStore,
            supplementalCoordinator: coordinator,
            urlSession: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            loadToken: { storedToken },
            saveToken: { _ in },
            hasToken: { !storedToken.isEmpty }
        )
        return IsolatedSessionEnvironment(
            settingsStore: settingsStore,
            snapshotCache: snapshotCache,
            overlayStore: overlayStore,
            supplementalCoordinator: coordinator,
            cacheDirectory: cacheDirectory,
            dependencies: dependencies,
            cleanup: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: cacheDirectory)
                try? FileManager.default.removeItem(at: supplementalCacheDirectory)
            }
        )
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw an error", file: file, line: line)
        } catch {}
    }


    private var snapshotJSON: String {
        """
        {
          "schemaVersion": 1,
          "sourceRevision": "revision-1",
          "generatedAt": "2026-07-12T12:00:00.000Z",
          "scope": { "id": "pf_isa", "name": "ISA", "kind": "portfolio", "currency": "GBP" },
          "freshness": {
            "responseGeneratedAt": "2026-07-12T12:00:00.000Z", "asOf": "2026-07-11", "status": "current", "reasonCodes": [],
            "sources": {
              "snapshots": { "asOfDate": "2026-07-11", "status": "clean", "generation": 1, "dirtySince": null, "rebuildStartedAt": null, "failedAt": null, "completedAt": "2026-07-12T11:55:00.000Z" },
              "prices": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "fx": { "asOfDate": "2026-07-11", "ageSeconds": 60, "missingCount": 0 },
              "provider": { "lastSuccessfulSyncAt": "2026-07-12T11:55:00.000Z", "ageSeconds": 300 }
            }
          },
          "totalValue": { "value": 1100, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" },
          "cash": { "value": 800, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" },
          "profitLoss": {
            "unrealized": { "value": 99, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" },
            "realized": { "value": 0, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" },
            "day": { "value": 100, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" }
          },
          "holdings": [{
            "portfolioId": "pf_isa", "assetId": "asset_vod", "ticker": "VOD", "name": "Vodafone", "currency": "GBP",
            "shares": 100, "averageCost": 2.01, "currentPrice": 3, "previousClose": 2, "marketValue": 300, "costValue": 201,
            "dayGain": 100, "dayGainPct": 50, "totalGain": 99, "totalGainPct": 49.25, "allocationPct": 27.05,
            "valuation": { "value": 300, "currency": "GBP", "quality": "complete", "reasonCodes": [], "asOfDate": "2026-07-11" }
          }]
        }
        """
    }

    private var versionTwoSnapshotJSON: String {
        snapshotJSON
            .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
            .replacingOccurrences(
                of: "\"scope\": { \"id\": \"pf_isa\", \"name\": \"ISA\", \"kind\": \"portfolio\", \"currency\": \"GBP\" }",
                with: "\"scope\": { \"id\": \"all\", \"name\": \"All portfolios\", \"kind\": \"aggregate\", \"currency\": \"GBP\" }"
            )
            .replacingOccurrences(
                of: "\"portfolioId\": \"pf_isa\", \"assetId\": \"asset_vod\", \"ticker\": \"VOD\", \"name\": \"Vodafone\"",
                with: "\"portfolioId\": \"pf_isa\", \"portfolioName\": \"ISA\", \"assetId\": \"asset_mnmd\", \"ticker\": \"MNMD\", \"canonicalTicker\": \"MNMD\", \"displayTicker\": \"DFTX\", \"quoteSymbol\": \"DFTX\", \"aliases\": [\"MNMD\", \"DFTX\"], \"isin\": \"CA60255C8850\", \"name\": \"Definium Therapeutics\""
            )
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolyncURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(
        _ request: URLRequest,
        status: Int,
        body: String,
        etag: String? = nil
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": "application/json"]
        if let etag { headers["ETag"] = etag }
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            Data(body.utf8)
        )
    }

    private static let capabilitiesJSON = """
    {
      "schemaVersion": 2,
      "sourceRevision": "caps-1",
      "generatedAt": "2026-07-13T10:00:00.000Z",
      "resources": {
        "lineHistory": {"supported":true,"ready":true,"reasonCodes":[]},
        "candlesticks": {"supported":true,"ready":true,"reasonCodes":[]},
        "benchmarks": {"supported":true,"ready":false,"reasonCodes":["not_ready"]},
        "exchangeRates": {"supported":true,"ready":false,"reasonCodes":["not_ready"]}
      },
      "ranges": ["1d","1w","1m","3m","6m","1y","all","custom"],
      "intervals": ["5m","15m","1h","1d"],
      "retentionDays": {"5m":7,"15m":31,"1h":365,"1d":3653},
      "benchmarks": [],
      "fx": {"base":"USD","quotes":["GBP","EUR","JPY","CAD","AUD"]},
      "trackedAssets": [{
        "assetId":"asset_mnmd",
        "canonicalTicker":"MNMD",
        "displayTicker":"DFTX",
        "quoteSymbol":"DFTX",
        "aliases":["MNMD","DFTX"],
        "isin":"CA60255C8850"
      }],
      "trackedSymbols": ["DFTX"],
      "marketIdentities": [{
        "identity": {
          "assetId":"asset_mnmd",
          "canonicalTicker":"MNMD",
          "displayTicker":"DFTX",
          "quoteSymbol":"DFTX",
          "aliases":["MNMD","DFTX"],
          "isin":"CA60255C8850"
        },
        "resources": {
          "lineHistory":{"supported":true,"ready":true,"reasonCodes":[]},
          "candlesticks":{"supported":true,"ready":true,"reasonCodes":[]}
        },
        "intervals": {
          "1h":{"availableFrom":"2026-07-13T09:00:00.000Z","availableTo":"2026-07-13T10:00:00.000Z","pointCount":1}
        }
      }]
    }
    """

    private static let historyJSON = """
    {
      "schemaVersion": 2,
      "sourceRevision": "history-1",
      "generatedAt": "2026-07-13T10:00:00.000Z",
      "resource": "marketSymbolHistory",
      "identity": {
        "assetId":"asset_mnmd",
        "canonicalTicker":"MNMD",
        "displayTicker":"DFTX",
        "quoteSymbol":"DFTX",
        "aliases":["MNMD","DFTX"],
        "isin":"CA60255C8850"
      },
      "range":"1m",
      "interval":"1h",
      "currency":"USD",
      "adjustment":"provider",
      "quality":"complete",
      "stale":false,
      "reasonCodes":[],
      "coverage":{
        "requestedFrom":"2026-06-13T10:00:00.000Z",
        "requestedTo":"2026-07-13T10:00:00.000Z",
        "availableFrom":"2026-07-13T09:00:00.000Z",
        "availableTo":"2026-07-13T10:00:00.000Z",
        "pointCount":1,
        "complete":false
      },
      "bars":[{
        "timestamp":"2026-07-13T10:00:00.000Z",
        "open":10,
        "high":11,
        "low":9,
        "close":10.5,
        "volume":null
      }]
    }
    """

    private static let readyMarketCapabilitiesJSON = capabilitiesJSON
        .replacingOccurrences(
            of: "\"benchmarks\": {\"supported\":true,\"ready\":false,\"reasonCodes\":[\"not_ready\"]}",
            with: "\"benchmarks\": {\"supported\":true,\"ready\":true,\"reasonCodes\":[]}"
        )
        .replacingOccurrences(
            of: "\"exchangeRates\": {\"supported\":true,\"ready\":false,\"reasonCodes\":[\"not_ready\"]}",
            with: "\"exchangeRates\": {\"supported\":true,\"ready\":true,\"reasonCodes\":[]}"
        )

    private static let benchmarksJSON = """
    {
      "schemaVersion":2,
      "sourceRevision":"benchmarks-1",
      "generatedAt":"2026-07-13T10:00:00.000Z",
      "range":"1d",
      "interval":"5m",
      "benchmarks":[
        {
          "id":"sp500","symbol":"^GSPC","name":"S&P 500","currency":"USD","provider":"yahoo-cache",
          "current":{"last":6300,"previousClose":6240,"change":60,"changePct":0.961538,"asOf":"2026-07-13T10:00:00.000Z"},
          "quality":"complete","stale":false,"reasonCodes":[],
          "coverage":{"requestedFrom":"2026-07-13T00:00:00.000Z","requestedTo":"2026-07-13T10:00:00.000Z","availableFrom":"2026-07-13T10:00:00.000Z","availableTo":"2026-07-13T10:00:00.000Z","pointCount":1,"complete":false},
          "bars":[{"timestamp":"2026-07-13T10:00:00.000Z","open":6290,"high":6310,"low":6280,"close":6300,"volume":1000}]
        },
        {
          "id":"ftse100","symbol":"^FTSE","name":"FTSE 100","currency":"GBP","provider":"yahoo-cache",
          "current":{"last":9200,"previousClose":9150,"change":50,"changePct":0.546448,"asOf":"2026-07-13T10:00:00.000Z"},
          "quality":"complete","stale":false,"reasonCodes":[],
          "coverage":{"requestedFrom":"2026-07-13T00:00:00.000Z","requestedTo":"2026-07-13T10:00:00.000Z","availableFrom":"2026-07-13T10:00:00.000Z","availableTo":"2026-07-13T10:00:00.000Z","pointCount":1,"complete":false},
          "bars":[{"timestamp":"2026-07-13T10:00:00.000Z","open":9180,"high":9210,"low":9170,"close":9200,"volume":2000}]
        }
      ]
    }
    """

    private static let fxJSON = """
    {
      "schemaVersion":2,
      "sourceRevision":"fx-1",
      "generatedAt":"2026-07-13T10:00:00.000Z",
      "base":"USD",
      "quality":"complete",
      "stale":false,
      "reasonCodes":[],
      "coverage":{"requestedFrom":"2026-06-12","requestedTo":"2026-07-13","availableFrom":"2026-07-12","availableTo":"2026-07-13"},
      "rates":[
        {"quote":"GBP","rate":0.79,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]},
        {"quote":"EUR","rate":0.86,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]},
        {"quote":"JPY","rate":159.2,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]},
        {"quote":"CAD","rate":1.37,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]},
        {"quote":"AUD","rate":1.52,"asOf":"2026-07-13","quality":"complete","reasonCodes":[]}
      ],
      "series":{
        "GBP":[{"date":"2026-07-13","rate":0.79,"source":"frankfurter"}],
        "EUR":[{"date":"2026-07-13","rate":0.86,"source":"frankfurter"}],
        "JPY":[{"date":"2026-07-13","rate":159.2,"source":"frankfurter"}],
        "CAD":[{"date":"2026-07-13","rate":1.37,"source":"frankfurter"}],
        "AUD":[{"date":"2026-07-13","rate":1.52,"source":"frankfurter"}]
      }
    }
    """
}

private final class FolyncHTTPStub: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var storedOffline = false
    private var storedHandler: Handler?

    var handler: Handler? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var isOffline: Bool {
        get { lock.withLock { storedOffline } }
        set { lock.withLock { storedOffline = newValue } }
    }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let handler = lock.withLock { () -> Handler? in
            storedRequests.append(request)
            return storedHandler
        }
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }
}

private final class FolyncURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var stub = FolyncHTTPStub()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.stub.respond(to: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
