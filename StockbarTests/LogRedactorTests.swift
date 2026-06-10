import XCTest
import Security
@testable import Stockbar

final class LogRedactorTests: XCTestCase {
    func testRedactsAPIKeysInURLQueryStrings() {
        // Given: A Python/requests style URL error with secrets in query parameters.
        let input = """
        403 Client Error: Forbidden for url: https://financialmodelingprep.com/api/v3/historical-price-full/AAPL?from=2026-01-01&apikey=secret-fmp-key&access_token=secret-token
        """

        // When: The message is sanitized for logging.
        let redacted = LogRedactor.redact(input)

        // Then: Secret values are removed while useful context remains.
        XCTAssertFalse(redacted.contains("secret-fmp-key"))
        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertTrue(redacted.contains("apikey=[REDACTED]"))
        XCTAssertTrue(redacted.contains("access_token=[REDACTED]"))
        XCTAssertTrue(redacted.contains("historical-price-full/AAPL"))
    }

    func testRedactsBearerAndEnvironmentStyleTokens() {
        // Given: Common credential formats that can appear in stderr or exceptions.
        let input = "Authorization: Bearer abc.def.ghi FMP_API_KEY=topsecret TWELVE_DATA_API_KEY: othersecret"

        // When: The message is sanitized for logging.
        let redacted = LogRedactor.redact(input)

        // Then: No raw credential material remains.
        XCTAssertFalse(redacted.contains("abc.def.ghi"))
        XCTAssertFalse(redacted.contains("topsecret"))
        XCTAssertFalse(redacted.contains("othersecret"))
        XCTAssertTrue(redacted.contains("Bearer [REDACTED]"))
        XCTAssertTrue(redacted.contains("FMP_API_KEY=[REDACTED]"))
        XCTAssertTrue(redacted.contains("TWELVE_DATA_API_KEY: [REDACTED]"))
    }

    func testRedactsRawPythonStderrAndExceptionText() {
        // Given: Python stderr containing nested exception text and provider URLs.
        let input = """
        requests.exceptions.HTTPError: 403 Client Error for url: https://financialmodelingprep.com/api/v3/quote/MU?apikey=secret-from-stderr
        RuntimeError: fallback failed with API_KEY: nested-secret and token=nested-token
        """

        // When: The stderr block is sanitized as a single log message.
        let redacted = LogRedactor.redact(input)

        // Then: Secret material is removed without hiding the useful provider/error context.
        XCTAssertFalse(redacted.contains("secret-from-stderr"))
        XCTAssertFalse(redacted.contains("nested-secret"))
        XCTAssertFalse(redacted.contains("nested-token"))
        XCTAssertTrue(redacted.contains("apikey=[REDACTED]"))
        XCTAssertTrue(redacted.contains("API_KEY: [REDACTED]"))
        XCTAssertTrue(redacted.contains("token=[REDACTED]"))
        XCTAssertTrue(redacted.contains("requests.exceptions.HTTPError"))
    }

    func testDetectsUnredactedSecretsWithoutFlaggingRedactedValues() {
        // Given: One raw credential and one already-sanitized credential.
        let raw = "https://financialmodelingprep.com/api/v3/quote/MU?apikey=secret-from-log"
        let safe = "https://financialmodelingprep.com/api/v3/quote/MU?apikey=[REDACTED]"

        // When/Then: Only the raw value is treated as a leak.
        XCTAssertTrue(LogRedactor.containsUnredactedSecret(raw))
        XCTAssertFalse(LogRedactor.containsUnredactedSecret(safe))
    }

    func testRedactsTrading212BasicAuthAndAccountIdentifiers() {
        // Given: Trading 212 auth and account identifiers that must never land in logs.
        let input = """
        Authorization: Basic YXBpLWtleTpzZWNyZXQ=
        TRADING212_API_KEY=public-key TRADING212_API_SECRET: private-secret
        accountId: 123456789
        """

        // When: The message is sanitized.
        let redacted = LogRedactor.redact(input)

        // Then: Credentials and account numbers are removed.
        XCTAssertFalse(redacted.contains("YXBpLWtleTpzZWNyZXQ="))
        XCTAssertFalse(redacted.contains("public-key"))
        XCTAssertFalse(redacted.contains("private-secret"))
        XCTAssertFalse(redacted.contains("123456789"))
        XCTAssertTrue(redacted.contains("Authorization: Basic [REDACTED]"))
        XCTAssertTrue(redacted.contains("TRADING212_API_KEY=[REDACTED]"))
        XCTAssertTrue(redacted.contains("TRADING212_API_SECRET: [REDACTED]"))
        XCTAssertTrue(redacted.contains("accountId: [REDACTED]"))
    }
}

final class RuntimeIssueMonitorTests: XCTestCase {
    func testScanFlagsSecretLeaksAsCritical() {
        // Given: Recent logs contain an unredacted provider URL.
        let logs = [
            "INFO refresh started",
            "ERROR 403 url=https://financialmodelingprep.com/api/v3/quote/MU?apikey=raw-secret"
        ]

        // When: The monitor scans recent logs.
        let snapshot = RuntimeIssueMonitor.scan(logs: logs)

        // Then: The issue is surfaced as critical and counted separately from normal errors.
        XCTAssertEqual(snapshot.secretLeakCount, 1)
        XCTAssertEqual(snapshot.errorCount, 1)
        XCTAssertEqual(snapshot.severity, .critical)
    }

    func testScanCountsRecoveryAndTimeoutEventsWithoutFlaggingRedactedProviderErrors() {
        // Given: Recent logs contain operational failures but no raw secrets.
        let logs = [
            "ERROR Core Data store load failed and was preserved at /tmp/recovery. Original store was not deleted.",
            "WARNING Python process timed out after 120 seconds",
            "ERROR 403 url=https://financialmodelingprep.com/api/v3/quote/MU?apikey=[REDACTED]"
        ]

        // When: The monitor scans recent logs.
        let snapshot = RuntimeIssueMonitor.scan(logs: logs)

        // Then: Recovery and timeout signals are visible, with warning severity.
        XCTAssertEqual(snapshot.secretLeakCount, 0)
        XCTAssertEqual(snapshot.recoveryEventCount, 1)
        XCTAssertEqual(snapshot.timeoutCount, 1)
        XCTAssertEqual(snapshot.errorCount, 2)
        XCTAssertEqual(snapshot.severity, .warning)
    }
}

final class Trading212AuthTests: XCTestCase {
    func testBuildsBasicAuthHeaderFromVerifiedCredentialPair() throws {
        // Given: Trading 212's verified API key + API secret credential shape.
        let credentials = Trading212AuthConfiguration(apiKey: "api-key-123", apiSecret: "secret-456")

        // When: StockBar builds the HTTP Authorization header.
        let header = try Trading212AuthHeaderBuilder().authorizationHeader(for: credentials)

        // Then: The header uses HTTP Basic auth with the exact key:secret bytes.
        let expected = "api-key-123:secret-456".data(using: .utf8)!.base64EncodedString()
        XCTAssertEqual(header.name, "Authorization")
        XCTAssertEqual(header.value, "Basic \(expected)")
    }

    func testRejectsBlankTrading212CredentialParts() {
        // Given: A generated credential pair with a missing secret.
        let credentials = Trading212AuthConfiguration(apiKey: "api-key-123", apiSecret: " ")

        // When/Then: The auth builder fails before any network request is made.
        XCTAssertThrowsError(try Trading212AuthHeaderBuilder().authorizationHeader(for: credentials))
    }

    func testCredentialStoreRejectsBlankSaveBeforeWritingKeychain() throws {
        // Given: A test-only Keychain namespace.
        let service = "com.fhl43211.Stockbar.tests.trading212.\(UUID().uuidString)"
        let store = Trading212CredentialStore(service: service)

        // When: Attempting to save blank credential data.
        let credentials = Trading212AuthConfiguration(apiKey: "", apiSecret: "")

        // Then: The store rejects the save and does not report usable credentials.
        XCTAssertThrowsError(try store.save(credentials, environment: .demo))
        XCTAssertFalse(store.hasCredentials(environment: .demo))
    }

    func testCredentialStoreSavesAndLoadsCurrentSingleKeychainItem() throws {
        // Given: A test-only Keychain namespace and valid fake credentials.
        let service = "com.fhl43211.Stockbar.tests.trading212.\(UUID().uuidString)"
        let store = Trading212CredentialStore(service: service)
        let credentials = Trading212AuthConfiguration(apiKey: "api-key-123", apiSecret: "secret-456")

        // When: StockBar saves credentials.
        try store.save(credentials, environment: .live)

        // Then: The store reports the current single-item format and can load credentials.
        XCTAssertEqual(store.storageState(environment: .live), .currentSingleItem)
        XCTAssertTrue(store.hasCredentials(environment: .live))
        XCTAssertEqual(try store.load(environment: .live), credentials)

        try store.delete(environment: .live)
        XCTAssertEqual(store.storageState(environment: .live), .notStored)
    }

    func testCredentialStoreUsesSessionCacheAfterFirstSuccessfulLoad() throws {
        // Given: A test-only Keychain namespace and valid fake credentials.
        let service = "com.fhl43211.Stockbar.tests.trading212.\(UUID().uuidString)"
        let store = Trading212CredentialStore(service: service)
        let credentials = Trading212AuthConfiguration(apiKey: "api-key-123", apiSecret: "secret-456")
        try store.save(credentials, environment: .live)

        // When: The credential has already been loaded once and the Keychain item disappears externally.
        XCTAssertEqual(try store.load(environment: .live), credentials)
        deleteKeychainValue(service: service, account: "live.credentials.v2")

        // Then: The same app session can keep syncing without another Keychain read.
        XCTAssertEqual(try store.load(environment: .live, allowUserInteraction: false), credentials)

        // And: Clearing the session cache returns to the durable Keychain state.
        store.clearSessionCache(environment: .live)
        XCTAssertThrowsError(try store.load(environment: .live, allowUserInteraction: false))
    }

    func testCredentialStoreMigratesLegacySplitItemsOnlyOnExplicitLoad() throws {
        // Given: Fake credentials saved in the old two-item Keychain layout.
        let service = "com.fhl43211.Stockbar.tests.trading212.\(UUID().uuidString)"
        let store = Trading212CredentialStore(service: service)
        try saveLegacyKeychainValue("legacy-key", service: service, account: "demo.apiKey")
        try saveLegacyKeychainValue("legacy-secret", service: service, account: "demo.apiSecret")

        // When: StockBar checks status without requesting the secret data.
        XCTAssertEqual(store.storageState(environment: .demo), .legacySplitItems)
        XCTAssertTrue(store.hasCredentials(environment: .demo))

        // Then: An explicit load returns the credentials and upgrades storage to one item.
        XCTAssertEqual(
            try store.load(environment: .demo),
            Trading212AuthConfiguration(apiKey: "legacy-key", apiSecret: "legacy-secret")
        )
        XCTAssertEqual(store.storageState(environment: .demo), .currentSingleItem)

        try store.delete(environment: .demo)
        XCTAssertEqual(store.storageState(environment: .demo), .notStored)
    }

    func testPermissionPolicyRequiresAccountDataAndNeverExecuteOrders() {
        // Given: The MVP Trading 212 permission policy.
        let rows = Trading212PermissionPolicy.mvpRows

        // When: Looking up key permission areas.
        let accountData = rows.first { $0.area == .accountData }
        let metadata = rows.first { $0.area == .metadata }
        let execute = rows.first { $0.area == .ordersExecute }

        // Then: Account data is required, Metadata is recommended, and order execution is never requested.
        XCTAssertEqual(accountData?.requirement, .required)
        XCTAssertEqual(metadata?.requirement, .recommended)
        XCTAssertEqual(execute?.requirement, .neverRequired)
    }

    private func saveLegacyKeychainValue(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Trading212CredentialStoreError.keychainStatus(status)
        }
    }

    private func deleteKeychainValue(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class Trading212ResolverTests: XCTestCase {
    func testLegacyLondonSuffixMapsToLSEIdentity() {
        // Given: An existing StockBar yfinance London symbol.
        let resolver = InstrumentResolver()

        // When: Resolving the legacy symbol.
        let result = resolver.resolveLegacySymbol("AV.L", displayName: "Aviva", currency: "GBP")

        // Then: The canonical identity keeps provider symbols separate from the instrument id.
        XCTAssertEqual(result.identity?.instrumentId, "LSE:AV")
        XCTAssertEqual(result.identity?.providerSymbols["yfinance"], "AV.L")
        XCTAssertEqual(result.identity?.providerSymbols["stooq"], "AV.UK")
        XCTAssertEqual(result.confidence, .high)
    }

    func testLocalLegacyXCSuffixMapsToLSEIdentity() {
        // Given: StockBar's existing local .XC UK suffix convention.
        let resolver = InstrumentResolver()

        // When: Resolving that legacy symbol.
        let result = resolver.resolveLegacySymbol("AV.XC", displayName: "Aviva", currency: "GBP")

        // Then: It is retained as a documented local legacy rule.
        XCTAssertEqual(result.identity?.instrumentId, "LSE:AV")
        XCTAssertTrue(result.warnings.contains { $0.contains("legacy .XC") })
    }

    func testBareMUSymbolDoesNotDefaultToLSE() {
        // Given: A bare US ticker with no UK metadata.
        let resolver = InstrumentResolver()

        // When: Resolving the symbol.
        let result = resolver.resolveLegacySymbol("MU", displayName: "Micron", currency: "USD")

        // Then: It does not become a London Stock Exchange instrument by default.
        XCTAssertNotEqual(result.identity?.instrumentId, "LSE:MU")
        XCTAssertEqual(result.identity?.instrumentId, "US:MU")
    }

    func testTrading212LondonPositionMapsToSameLSEIdentityAsLegacySymbol() {
        // Given: Trading 212 position data with London/currency hints.
        let resolver = InstrumentResolver()
        let position = Trading212Position(
            averagePricePaid: 4.86,
            currentPrice: 6.20,
            instrument: Trading212Instrument(currency: "GBP", isin: "GB0002162385", name: "Aviva", ticker: "AV_GB_EQ"),
            quantity: 500,
            quantityAvailableForTrading: 500,
            quantityInPies: 0,
            walletImpact: Trading212PositionWalletImpact(
                currency: "GBP",
                currentValue: 3100,
                fxImpact: 0,
                totalCost: 2430,
                unrealizedProfitLoss: 670
            )
        )
        let metadata = Trading212InstrumentMetadata(
            currencyCode: "GBP",
            isin: "GB0002162385",
            name: "Aviva",
            shortName: "Aviva",
            ticker: "AV_GB_EQ",
            type: "STOCK",
            workingScheduleId: 100
        )

        // When: Resolving the broker position.
        let result = resolver.resolveTrading212Position(
            position,
            metadata: metadata,
            exchangeName: "London Stock Exchange"
        )

        // Then: It maps to the same canonical instrument id as AV.L.
        XCTAssertEqual(result.identity?.instrumentId, "LSE:AV")
        XCTAssertEqual(result.identity?.providerSymbols["trading212"], "AV_GB_EQ")
        XCTAssertEqual(result.identity?.providerSymbols["yfinance"], "AV.L")
        XCTAssertEqual(result.confidence, .high)
    }

    func testTrading212LowercaseLondonVenueSuffixIsNotPartOfSymbol() {
        // Given: Trading 212's venue-encoded London ticker form.
        let resolver = InstrumentResolver()
        let position = Trading212Position(
            averagePricePaid: nil,
            currentPrice: nil,
            instrument: Trading212Instrument(currency: "GBX", isin: nil, name: "Aviva", ticker: "AVl_EQ"),
            quantity: nil,
            quantityAvailableForTrading: nil,
            quantityInPies: nil,
            walletImpact: nil
        )
        let metadata = Trading212InstrumentMetadata(
            currencyCode: "GBX",
            isin: "GB0002162385",
            name: "Aviva",
            shortName: "Aviva",
            ticker: "AVl_EQ",
            type: "STOCK",
            workingScheduleId: 100
        )

        // When: Resolving the broker ticker.
        let result = resolver.resolveTrading212Position(position, metadata: metadata, exchangeName: nil)

        // Then: The lowercase venue suffix is stripped before canonical identity construction.
        XCTAssertEqual(result.identity?.instrumentId, "LSE:AV")
        XCTAssertEqual(result.identity?.providerSymbols["yfinance"], "AV.L")
        XCTAssertEqual(result.identity?.providerSymbols["trading212"], "AVl_EQ")
    }

    func testTrading212LegacyProviderTickerUsesMetadataShortNameForHims() {
        // Given: Trading 212 still exposes Hims & Hers through a legacy OAC provider ticker.
        let resolver = InstrumentResolver()
        let position = Trading212Position(
            averagePricePaid: nil,
            currentPrice: nil,
            instrument: Trading212Instrument(currency: "USD", isin: "US4330001060", name: "Hims & Hers Health", ticker: "OAC_US_EQ"),
            quantity: nil,
            quantityAvailableForTrading: nil,
            quantityInPies: nil,
            walletImpact: nil
        )
        let metadata = Trading212InstrumentMetadata(
            currencyCode: "USD",
            isin: "US4330001060",
            name: "Hims & Hers Health",
            shortName: "HIMS",
            ticker: "OAC_US_EQ",
            type: "STOCK",
            workingScheduleId: 200
        )

        // When: Resolving the broker position.
        let result = resolver.resolveTrading212Position(position, metadata: metadata, exchangeName: nil)

        // Then: The canonical identity follows the active display symbol while preserving the broker alias.
        XCTAssertEqual(result.identity?.instrumentId, "US:HIMS")
        XCTAssertEqual(result.identity?.displaySymbol, "HIMS")
        XCTAssertEqual(result.identity?.displayName, "Hims & Hers Health")
        XCTAssertEqual(result.identity?.providerSymbols["yfinance"], "HIMS")
        XCTAssertEqual(result.identity?.providerSymbols["trading212"], "OAC_US_EQ")
    }
}

final class Trading212PreviewTests: XCTestCase {
    func testPreviewMarksManualHoldingConflictWithoutMutatingHoldings() {
        // Given: An existing manual AV.L holding and a proposed Trading 212 AV position.
        let resolver = InstrumentResolver()
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .demo,
            accountType: .stocksAndSharesISA,
            accountLabel: "Trading 212 ISA",
            credentialFingerprint: "fingerprint",
            apiAccountId: 123456789
        )
        let position = Trading212Position(
            averagePricePaid: 4.86,
            currentPrice: 6.20,
            instrument: Trading212Instrument(currency: "GBP", isin: nil, name: "Aviva", ticker: "AV_GB_EQ"),
            quantity: 500,
            quantityAvailableForTrading: 500,
            quantityInPies: 0,
            walletImpact: Trading212PositionWalletImpact(
                currency: "GBP",
                currentValue: 3100,
                fxImpact: 0,
                totalCost: 2430,
                unrealizedProfitLoss: 670
            )
        )

        // When: Building a read-only preview row.
        let manualHolding = Trading212ManualHoldingSnapshot(
            symbol: "AV.L",
            displayName: "Aviva",
            quantity: 500,
            averageCost: 4.86,
            currency: "GBP",
            isWatchlistOnly: false
        )
        let row = Trading212ImportPreviewRow.make(
            account: account,
            position: position,
            resolution: resolver.resolveTrading212Position(position, metadata: nil, exchangeName: nil),
            existingManualHoldings: [manualHolding]
        )

        // Then: The row reports the conflict without creating or changing holdings.
        XCTAssertEqual(row.instrumentId, "LSE:AV")
        XCTAssertEqual(row.conflictStatus, .manualHoldingMatch)
        XCTAssertEqual(row.manualMatch?.symbol, "AV.L")
        XCTAssertEqual(row.quantityDelta ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(row.valueSource, .brokerProvidedLivePositionData)
        XCTAssertEqual(row.account.environment, .demo)
    }

    func testPreviewMatchesBareManualHimsUsingStoredCurrencyAndBrokerMetadataAlias() {
        // Given: A manually entered HIMS holding and Trading 212's legacy OAC provider ticker.
        let resolver = InstrumentResolver()
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .live,
            accountType: .stocksAndSharesISA,
            accountLabel: "Trading 212 ISA",
            credentialFingerprint: "fingerprint",
            apiAccountId: 123456789
        )
        let position = Trading212Position(
            averagePricePaid: 46.47,
            currentPrice: 29.07,
            instrument: Trading212Instrument(currency: "USD", isin: "US4330001060", name: "Hims & Hers Health", ticker: "OAC_US_EQ"),
            quantity: 50,
            quantityAvailableForTrading: 50,
            quantityInPies: 0,
            walletImpact: nil
        )
        let metadata = Trading212InstrumentMetadata(
            currencyCode: "USD",
            isin: "US4330001060",
            name: "Hims & Hers Health",
            shortName: "HIMS",
            ticker: "OAC_US_EQ",
            type: "STOCK",
            workingScheduleId: 200
        )
        let manualHolding = Trading212ManualHoldingSnapshot(
            symbol: "HIMS",
            displayName: "Hims & Hers Health",
            quantity: 50,
            averageCost: 46.47,
            currency: "USD",
            isWatchlistOnly: false
        )

        // When: Building a preview row.
        let row = Trading212ImportPreviewRow.make(
            account: account,
            position: position,
            resolution: resolver.resolveTrading212Position(position, metadata: metadata, exchangeName: nil),
            existingManualHoldings: [manualHolding]
        )

        // Then: The manual holding is matched to the broker alias by canonical identity.
        XCTAssertEqual(row.instrumentId, "US:HIMS")
        XCTAssertEqual(row.conflictStatus, .manualHoldingMatch)
        XCTAssertEqual(row.manualMatch?.symbol, "HIMS")
        XCTAssertEqual(row.quantityDelta ?? .nan, 0, accuracy: 0.001)
    }

    func testPreviewMatchesBareUkManualSymbolUsingCurrencyHint() {
        // Given: A manually entered bare UK symbol and Trading 212's London venue ticker.
        let resolver = InstrumentResolver()
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .live,
            accountType: .stocksAndSharesISA,
            accountLabel: "Trading 212 ISA",
            credentialFingerprint: "fingerprint",
            apiAccountId: 123456789
        )
        let position = Trading212Position(
            averagePricePaid: 66.38,
            currentPrice: 67.30,
            instrument: Trading212Instrument(currency: "GBX", isin: "GB00BLY2F708", name: "Card Factory", ticker: "CARDl_EQ"),
            quantity: 7500,
            quantityAvailableForTrading: 7500,
            quantityInPies: 0,
            walletImpact: nil
        )
        let manualHolding = Trading212ManualHoldingSnapshot(
            symbol: "CARD",
            displayName: "Card Factory",
            quantity: 7500,
            averageCost: 66.4,
            currency: "GBX",
            isWatchlistOnly: false
        )

        // When: Building a preview row.
        let row = Trading212ImportPreviewRow.make(
            account: account,
            position: position,
            resolution: resolver.resolveTrading212Position(position, metadata: nil, exchangeName: nil),
            existingManualHoldings: [manualHolding]
        )

        // Then: The currency hint prevents CARD from being treated as an unrelated US ticker.
        XCTAssertEqual(row.instrumentId, "LSE:CARD")
        XCTAssertEqual(row.conflictStatus, .manualHoldingMatch)
        XCTAssertEqual(row.manualMatch?.symbol, "CARD")
        XCTAssertEqual(row.quantityDelta ?? .nan, 0, accuracy: 0.001)
    }

    func testPreviewFlagsQuantityMismatchForMatchedManualHolding() {
        // Given: The same instrument exists manually, but the broker quantity differs.
        let resolver = InstrumentResolver()
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .live,
            accountType: .stocksAndSharesISA,
            accountLabel: "Trading 212 ISA",
            credentialFingerprint: "fingerprint",
            apiAccountId: 123456789
        )
        let position = Trading212Position(
            averagePricePaid: 486.28,
            currentPrice: 619.80,
            instrument: Trading212Instrument(currency: "GBX", isin: "GB0002162385", name: "Aviva", ticker: "AVl_EQ"),
            quantity: 500,
            quantityAvailableForTrading: 500,
            quantityInPies: 0,
            walletImpact: nil
        )
        let manualHolding = Trading212ManualHoldingSnapshot(
            symbol: "AV.L",
            displayName: "Aviva",
            quantity: 490,
            averageCost: 486.28,
            currency: "GBX",
            isWatchlistOnly: false
        )

        // When: Building a preview row.
        let row = Trading212ImportPreviewRow.make(
            account: account,
            position: position,
            resolution: resolver.resolveTrading212Position(position, metadata: nil, exchangeName: nil),
            existingManualHoldings: [manualHolding]
        )

        // Then: It is still matched, but clearly marked for review before any future merge.
        XCTAssertEqual(row.instrumentId, "LSE:AV")
        XCTAssertEqual(row.conflictStatus, .manualQuantityMismatch)
        XCTAssertEqual(row.manualMatch?.symbol, "AV.L")
        XCTAssertEqual(row.quantityDelta ?? .nan, 10, accuracy: 0.001)
    }

    func testMemoryPreviewCacheSeparatesLiveAndDemoNamespaces() async {
        // Given: Separate preview snapshots for demo and live environments.
        let cache = Trading212PreviewCache(ttl: 60)
        let demoAccount = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .demo,
            accountType: .invest,
            accountLabel: "Demo",
            credentialFingerprint: "fingerprint",
            apiAccountId: nil
        )
        let liveAccount = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .live,
            accountType: .invest,
            accountLabel: "Live",
            credentialFingerprint: "fingerprint",
            apiAccountId: nil
        )
        let snapshot = Trading212PreviewSnapshot(account: demoAccount, accountSummary: nil, positions: [], metadataAvailable: false)

        // When: Storing only the demo snapshot.
        await cache.store(snapshot, for: demoAccount.brokerAccountKey)

        // Then: Demo can be read back, but live cannot collide with it.
        let cachedDemo = await cache.snapshot(for: demoAccount.brokerAccountKey)
        let cachedLive = await cache.snapshot(for: liveAccount.brokerAccountKey)
        XCTAssertNotNil(cachedDemo)
        XCTAssertNil(cachedLive)
    }
}

final class Trading212BrokerLinkStoreTests: XCTestCase {
    func testPersistsExactManualBrokerLinksWithoutRawAccountIdOrBrokerValues() async throws {
        // Given: A clean preview where the broker row exactly matches the existing manual holding.
        let fileURL = temporaryLinkStoreURL()
        let store = BrokerLinkStore(fileURL: fileURL)
        let preview = makePreview(
            manualQuantity: 500,
            brokerQuantity: 500
        )
        let linkedAt = Date(timeIntervalSince1970: 1_800_000_000)

        // When: Persisting the explicit broker link.
        let result = try await store.linkExactMatches(from: preview, linkedAt: linkedAt)
        let snapshot = try await store.loadSnapshot()
        let rawJSON = try String(contentsOf: fileURL, encoding: .utf8)

        // Then: The link is keyed by broker account + instrument, without raw account numbers or live values.
        XCTAssertEqual(result.linkedCount, 1)
        XCTAssertEqual(snapshot.accounts.count, 1)
        XCTAssertEqual(snapshot.positions.count, 1)
        XCTAssertEqual(snapshot.positions[0].instrumentId, "LSE:AV")
        XCTAssertEqual(snapshot.positions[0].manualSymbol, "AV.L")
        XCTAssertEqual(snapshot.positions[0].providerTicker, "AVl_EQ")
        XCTAssertEqual(snapshot.positions[0].brokerQuantityAtLink, 500)
        XCTAssertEqual(snapshot.positions[0].linkedAt, linkedAt)
        XCTAssertFalse(rawJSON.contains("123456789"))
        XCTAssertFalse(rawJSON.contains("currentValue"))
        XCTAssertFalse(rawJSON.contains("unrealizedProfitLoss"))
        XCTAssertFalse(rawJSON.contains("Authorization"))
    }

    func testRejectsPreviewWithQuantityMismatchBeforePersistingLinks() async throws {
        // Given: A preview that matched identity but not quantity.
        let fileURL = temporaryLinkStoreURL()
        let store = BrokerLinkStore(fileURL: fileURL)
        let preview = makePreview(
            manualQuantity: 490,
            brokerQuantity: 500
        )

        // When/Then: Persisting is rejected and no link file is created.
        do {
            _ = try await store.linkExactMatches(from: preview, linkedAt: Date())
            XCTFail("Expected quantity mismatch to prevent linking.")
        } catch BrokerLinkStoreError.previewNotReady(let reason) {
            XCTAssertTrue(reason.contains("not ready"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUpsertUsesBrokerAccountKeyAndInstrumentIdWithoutDuplicatingLinks() async throws {
        // Given: The same exact preview is linked twice.
        let fileURL = temporaryLinkStoreURL()
        let store = BrokerLinkStore(fileURL: fileURL)
        let firstPreview = makePreview(
            manualQuantity: 500,
            brokerQuantity: 500
        )
        let secondPreview = makePreview(
            manualQuantity: 500,
            brokerQuantity: 500
        )

        // When: Both saves run.
        _ = try await store.linkExactMatches(from: firstPreview, linkedAt: Date(timeIntervalSince1970: 1))
        let result = try await store.linkExactMatches(from: secondPreview, linkedAt: Date(timeIntervalSince1970: 2))
        let snapshot = try await store.loadSnapshot()

        // Then: It updates the existing brokerAccountKey + instrumentId record instead of duplicating.
        XCTAssertEqual(result.linkedCount, 1)
        XCTAssertEqual(snapshot.positions.count, 1)
        XCTAssertEqual(snapshot.positions[0].linkedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.positions[0].updatedAt, Date(timeIntervalSince1970: 2))
    }

    private func makePreview(
        manualQuantity: Double,
        brokerQuantity: Double
    ) -> Trading212ImportPreview {
        let resolver = InstrumentResolver()
        let account = BrokerAccountIdentity.preview(
            broker: "Trading212",
            environment: .live,
            accountType: .stocksAndSharesISA,
            accountLabel: "Trading 212 ISA",
            credentialFingerprint: "credential-hash",
            apiAccountId: 123456789
        )
        let position = Trading212Position(
            averagePricePaid: 486.28,
            currentPrice: 619.80,
            instrument: Trading212Instrument(currency: "GBX", isin: "GB0002162385", name: "Aviva", ticker: "AVl_EQ"),
            quantity: brokerQuantity,
            quantityAvailableForTrading: brokerQuantity,
            quantityInPies: 0,
            walletImpact: Trading212PositionWalletImpact(
                currency: "GBP",
                currentValue: 3099,
                fxImpact: 0,
                totalCost: 2431.40,
                unrealizedProfitLoss: 667.60
            )
        )
        let manualHolding = Trading212ManualHoldingSnapshot(
            symbol: "AV.L",
            displayName: "Aviva",
            quantity: manualQuantity,
            averageCost: 486.28,
            currency: "GBX",
            isWatchlistOnly: false
        )
        let row = Trading212ImportPreviewRow.make(
            account: account,
            position: position,
            resolution: resolver.resolveTrading212Position(position, metadata: nil, exchangeName: nil),
            existingManualHoldings: [manualHolding]
        )
        return Trading212ImportPreview(
            account: account,
            accountSummary: nil,
            rows: [row],
            metadataAvailable: true,
            generatedAt: Date(),
            warnings: []
        )
    }

    private func temporaryLinkStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-broker-links-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }
}
