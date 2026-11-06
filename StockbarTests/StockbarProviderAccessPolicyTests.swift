import XCTest
@testable import Stockbar

final class StockbarProviderAccessPolicyTests: XCTestCase {
    func testAcceptancePolicyDeniesEveryLiveProvider() {
        let policy = StockbarProviderAccessPolicy(liveRequestsAllowed: false)

        for provider in StockbarProvider.allCases {
            XCTAssertThrowsError(try policy.authorize(provider)) { error in
                XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(provider))
            }
        }
    }

    func testProductionPolicyAllowsEveryLiveProvider() {
        let policy = StockbarProviderAccessPolicy(liveRequestsAllowed: true)

        for provider in StockbarProvider.allCases {
            XCTAssertNoThrow(try policy.authorize(provider))
        }
    }

    func testPolicyDerivedFromAcceptanceRuntimeIsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarProviderPolicyTests-(UUID().uuidString)")
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])

        let policy = StockbarProviderAccessPolicy(runtime: runtime)

        XCTAssertThrowsError(try policy.authorize(.python))
    }

    func testPythonRunnerDeniesBeforeLaunchingAProcess() async {
        let runner = PythonProcessRunner(
            config: PythonConfiguration(interpreterPath: "/path/that/must/not/run"),
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false)
        )

        do {
            _ = try await runner.run(arguments: ["--version"], timeoutSeconds: 1, logContext: "acceptance test")
            XCTFail("Expected provider denial")
        } catch {
            XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.python))
        }
    }

    func testAcceptanceModeSkipsPythonDependencyCheckAndPrompt() {
        let policy = StockbarProviderAccessPolicy(liveRequestsAllowed: false)

        XCTAssertFalse(AppDelegate.shouldCheckPythonDependencies(hasChecked: false, providerPolicy: policy))
    }

    func testProductionModeChecksPythonDependenciesOnlyOnce() {
        let policy = StockbarProviderAccessPolicy(liveRequestsAllowed: true)

        XCTAssertTrue(AppDelegate.shouldCheckPythonDependencies(hasChecked: false, providerPolicy: policy))
        XCTAssertFalse(AppDelegate.shouldCheckPythonDependencies(hasChecked: true, providerPolicy: policy))
    }

    func testPythonInstallCommandUsesAbsoluteQuotedPaths() {
        let command = AppDelegate.pythonInstallCommand(
            interpreterPath: "/opt/homebrew/bin/python3",
            requirementsPath: "/Applications/Stock's Bar.app/Contents/Resources/requirements.txt"
        )

        XCTAssertEqual(
            command,
            "'/opt/homebrew/bin/python3' -m pip install -r '/Applications/Stock'\\''s Bar.app/Contents/Resources/requirements.txt'"
        )
    }

    func testPythonDependencyAlertOffersPipCommandOnlyForAnExistingCustomInterpreter() {
        let managed = "/Users/me/Library/Application Support/Stockbar/python-env/bin/python3"

        // Stockbar's own environment has no pip; Set Up Automatically rebuilds it.
        XCTAssertFalse(AppDelegate.offersManualPythonInstall(
            interpreterPath: managed, managedInterpreterPath: managed, interpreterExists: true
        ))
        XCTAssertFalse(AppDelegate.offersManualPythonInstall(
            interpreterPath: managed, managedInterpreterPath: managed, interpreterExists: false
        ))
        XCTAssertTrue(AppDelegate.offersManualPythonInstall(
            interpreterPath: "/opt/homebrew/bin/python3", managedInterpreterPath: managed, interpreterExists: true
        ))
        XCTAssertFalse(AppDelegate.offersManualPythonInstall(
            interpreterPath: "/opt/homebrew/bin/python3", managedInterpreterPath: managed, interpreterExists: false
        ))
    }

    func testEnabledFolyncBenchmarkRouteSuppressesLegacyRefreshBeforeFirstOverlay() {
        let symbols = ["AAPL", "^FTSE", "^GSPC"]

        XCTAssertEqual(
            RefreshService.filterFolyncRoutedBenchmarks(
                from: symbols,
                routeActive: true,
                sourceStatus: nil
            ),
            ["AAPL"]
        )
    }

    func testFolyncBenchmarkLegacyFallbackRestoresLocalRefresh() {
        let symbols = ["AAPL", "^FTSE", "^GSPC"]

        XCTAssertEqual(
            RefreshService.filterFolyncRoutedBenchmarks(
                from: symbols,
                routeActive: true,
                sourceStatus: .legacy
            ),
            symbols
        )
    }

    func testEnabledFolyncHistoryRoutesSuppressOnlyRepresentedLegacyBackfills() {
        let symbols = ["DFTX", "HELP", "AAPL", "^FTSE", "^GSPC"]

        XCTAssertEqual(
            DataModel.filterFolyncRoutedHistoryBackfills(
                from: symbols,
                lineHistoryActive: true,
                benchmarkDataActive: true,
                folyncHistorySymbols: ["DFTX", "MNMD", "HELP", "CYBN"],
                folyncBenchmarkSymbols: ["^FTSE", "^GSPC"]
            ),
            ["AAPL"]
        )
    }

    func testDisabledFolyncHistoryRoutesPreserveLegacyBackfills() {
        let symbols = ["DFTX", "AAPL", "^FTSE"]

        XCTAssertEqual(
            DataModel.filterFolyncRoutedHistoryBackfills(
                from: symbols,
                lineHistoryActive: false,
                benchmarkDataActive: false,
                folyncHistorySymbols: ["DFTX"],
                folyncBenchmarkSymbols: ["^FTSE"]
            ),
            symbols
        )
    }

    func testTrading212ProviderDeniesBeforeBuildingOrSendingRequest() async {
        let provider = Trading212Provider(
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false)
        )

        do {
            _ = try await provider.accountSummary(
                credentials: Trading212AuthConfiguration(apiKey: "not-used", apiSecret: "not-used"),
                environment: .demo
            )
            XCTFail("Expected provider denial")
        } catch {
            XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.trading212))
        }
    }

    func testFolyncPortfolioSourceDeniesBeforeSendingRequest() async throws {
        // Given a Folync source built under a policy that disables live providers
        let source = try FolyncPortfolioSource(
            baseURL: XCTUnwrap(URL(string: "https://folync.invalid")),
            token: "not-used",
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false)
        )

        // When any request is attempted
        do {
            _ = try await source.listPortfolios()
            XCTFail("Expected provider denial")
        } catch {
            // Then it is refused before the URLSession is ever touched
            XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.folync))
        }
    }

    func testFolyncSupplementalCoordinatorDeniesBeforeSendingRequest() async {
        // Given a supplemental coordinator under an acceptance policy
        let coordinator = FolyncSupplementalCoordinator(
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
            tokenProvider: { "not-used" }
        )

        // When capabilities are requested
        do {
            _ = try await coordinator.fetchCapabilities(
                baseURL: XCTUnwrap(URL(string: "https://folync.invalid")),
                token: "not-used"
            )
            XCTFail("Expected provider denial")
        } catch {
            // Then the request is refused rather than reaching the network
            XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.folync))
        }
    }

    func testFolyncScopeIdentifiersRejectPathSeparators() {
        // Given scope identifiers that would escape their URL path segment
        // Then they are refused
        XCTAssertThrowsError(try FolyncPortfolioSource.validateScopeComponent(""))
        XCTAssertThrowsError(try FolyncPortfolioSource.validateScopeComponent(".."))
        XCTAssertThrowsError(try FolyncPortfolioSource.validateScopeComponent("a/b"))
        XCTAssertThrowsError(try FolyncPortfolioSource.validateScopeComponent("a\\b"))

        // And ordinary scope identifiers are accepted
        XCTAssertNoThrow(try FolyncPortfolioSource.validateScopeComponent("all"))
        XCTAssertNoThrow(try FolyncPortfolioSource.validateScopeComponent("portfolio-1"))
    }

    func testTrading212BackoffUsesConfiguredFloorRetryAfterAndDeterministicJitter() {
        let policy = Trading212BackoffPolicy(configuredInterval: 90, jitterFraction: 0.10)

        XCTAssertEqual(policy.delay(failureCount: 1, randomUnit: 0), 90)
        XCTAssertEqual(policy.delay(failureCount: 3, randomUnit: 0), 300)
        XCTAssertEqual(policy.delay(failureCount: 6, retryAfter: 7_200, randomUnit: 0), 7_200)
        XCTAssertEqual(policy.delay(failureCount: 1, randomUnit: 1), 99, accuracy: 0.001)
    }

    func testRateLimitedErrorCarriesRetryAfter() {
        let error = Trading212ProviderError.rateLimited(retryAfter: 75)

        XCTAssertTrue(error.localizedDescription.contains("75"))
    }

    @MainActor
    func testCurrencyConverterDoesNotBeginLegacyRefreshWhenDirectFXIsDenied() async {
        let observer = InvocationCounter()
        let suiteName = TestDefaultsSuite.makeName("StockbarProviderPolicyTests-")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { TestDefaultsSuite.remove(suiteName) }
        let converter = CurrencyConverter(
            refreshOnInit: false,
            loadHistoryOnInit: false,
            supplementalRouter: LegacyFXRouter(),
            legacyRefreshObserver: { observer.increment() },
            defaults: defaults,
            providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false)
        )

        await converter.refreshRatesFromConfiguredSource(force: true)

        XCTAssertEqual(observer.value, 0)
    }
}

private actor LegacyFXRouter: FolyncSupplementalFXRouting {
    func routeFX() async -> FolyncRoutedFXResult { .legacy }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
