import Combine
import CoreData
import XCTest
@testable import Stockbar

final class FolyncPortfolioSourceTests: XCTestCase {
    /// These tests drive Folync through a stubbed URLProtocol, so no live request
    /// is ever made. The real `.current` policy denies `.folync` under XCTest,
    /// which is the behaviour we want in production — so inject a permissive
    /// policy here rather than weakening the gate.
    private static let testProviderPolicy = StockbarProviderAccessPolicy(liveRequestsAllowed: true)

    @MainActor
    func testPortfolioMenuLoadsFolyncDayHistoryAndUsesReferenceOnlyWhenSparse() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncMenuHistory-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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

    /// Opening the popover draws the history saved from Folync's last answer
    /// at once, then replaces it with what the request returns.
    @MainActor
    func testPortfolioMenuShowsSavedFolyncHistoryWhileTheRequestRuns() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncMenuSavedHistory-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let body: @Sendable (String, [Int]) -> String = { range, values in
            let series = "[" + values.enumerated().map { index, value in
                "{\"date\":\"2026-09-10T09:0\(index):00Z\",\"value\":\(value)}"
            }.joined(separator: ",") + "]"
            return """
            {"schemaVersion":2,"sourceRevision":"saved-test",
             "scope":{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"},
             "range":"\(range)","interval":"5m","generatedAt":"2026-09-10T09:10:00Z","currency":"GBP",
             "quality":"complete","reasonCodes":[],
             "coverage":{"pointCount":\(values.count),"complete":true},
             "portfolioSeries":\(series),"cashSeries":\(series),"holdingsSeries":\(series),
             "netContributionSeries":\(series),"gainSeries":\(series),"twrSeries":\(series)}
            """
        }
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        let release = DispatchSemaphore(value: 0)
        stub.handler = { request in
            let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "range" }?.value ?? ""
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"w1\"" {
                return Self.httpResponse(request, status: 304, body: "")
            }
            if stub.isOffline {
                // Hold the request open until the test has looked at the chart.
                _ = release.wait(timeout: .now() + 10)
                return Self.httpResponse(request, status: 200, body: body(range, [300, 310, 320]))
            }
            return Self.httpResponse(request, status: 200, body: body(range, [100, 110]))
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy, tokenProvider: { "test-token" }
        )

        let nothingSaved = await coordinator.savedPortfolioHistory(range: "1d")
        XCTAssertNil(nothingSaved)
        guard case .folync = await coordinator.routePortfolioHistory(range: "1d") else {
            return XCTFail("Expected the first answer to be saved")
        }
        let requestsBefore = stub.requests.count
        let saved = await coordinator.savedPortfolioHistory(range: "1d")
        XCTAssertEqual(saved?.portfolioSeries.map(\.value), [100, 110])
        XCTAssertEqual(stub.requests.count, requestsBefore, "Reading the saved history makes no request")
        let otherRange = await coordinator.savedPortfolioHistory(range: "1w")
        XCTAssertNil(otherRange, "Only the range asked for")
        let tooOld = await coordinator.savedPortfolioHistory(range: "1d", now: Date().addingTimeInterval(2 * 24 * 60 * 60))
        XCTAssertNil(tooOld, "Not when it was received more than a day ago")

        let model = PortfolioMenuChartViewModel(
            currentValue: 170000, currentTrades: [], preferredCurrency: "GBP", valuationSource: .folyncProvided,
            folyncCoordinator: coordinator, folyncSettingsStore: settingsStore
        )
        defer { model.deactivate() }
        stub.isOffline = true
        let shownSaved = expectation(description: "Saved history shown")
        shownSaved.assertForOverFulfill = false
        let savedSubscription = model.$chartData.filter { !$0.isEmpty }.sink { _ in shownSaved.fulfill() }
        model.activate()
        await fulfillment(of: [shownSaved], timeout: 5)
        savedSubscription.cancel()
        XCTAssertEqual(model.chartData.map(\.price), [100, 110], "The saved history is drawn before Folync answers")
        XCTAssertTrue(model.isLoading, "The request is still running")
        XCTAssertTrue(model.coverageLabel.hasPrefix("Past 24 hours · Checking Folync"), model.coverageLabel)
        XCTAssertFalse(model.hasRangeCoverage)

        let loaded = expectation(description: "Folync answered")
        loaded.assertForOverFulfill = false
        let loadedSubscription = model.$isLoading.filter { !$0 }.sink { _ in loaded.fulfill() }
        release.signal()
        await fulfillment(of: [loaded], timeout: 5)
        loadedSubscription.cancel()
        XCTAssertEqual(model.chartData.map(\.price), [300, 310, 320], "Folync's answer replaces the saved history")
        XCTAssertFalse(model.coverageLabel.contains("Checking"), model.coverageLabel)
        XCTAssertTrue(model.hasRangeCoverage)
        XCTAssertEqual(stub.requests.count, requestsBefore + 1, "Still one request per load")

        // A 304 confirms a saved history whose file is not rewritten, so it
        // still counts as recent although it was received two days ago.
        let cache = FolyncSupplementalCache(directory: cacheDirectory)
        let weekPayload = try JSONDecoder().decode(FolyncPortfolioHistory.self, from: Data(body("1w", [200, 210]).utf8))
        try await cache.save(
            weekPayload, endpoint: "https://folync.test", scopeID: "all", resource: "portfolio-history",
            identity: "all", range: "range=1w", etag: "\"w1\"", receiptTime: Date().addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let weekBeforeCheck = await coordinator.savedPortfolioHistory(range: "1w")
        XCTAssertNil(weekBeforeCheck, "Received two days ago and not confirmed since")
        guard case .folync = await coordinator.routePortfolioHistory(range: "1w") else {
            return XCTFail("Expected the 304 to return the saved week")
        }
        let weekAfterCheck = await coordinator.savedPortfolioHistory(range: "1w")
        XCTAssertEqual(weekAfterCheck?.portfolioSeries.map(\.value), [200, 210], "A 304 confirms it")

        // When Folync cannot be used, the saved chart shown meanwhile is cleared.
        stub.isOffline = false
        let lockedOut = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy,
            tokenProvider: { throw URLError(.userAuthenticationRequired) }
        )
        let unusable = PortfolioMenuChartViewModel(
            currentValue: 170000, currentTrades: [], preferredCurrency: "GBP", valuationSource: .folyncProvided,
            folyncCoordinator: lockedOut, folyncSettingsStore: settingsStore
        )
        defer { unusable.deactivate() }
        var shownBeforeAnswer: [Double] = []
        let settled = expectation(description: "Settled without Folync")
        settled.assertForOverFulfill = false
        let shownSubscription = unusable.$chartData.filter { !$0.isEmpty }.sink { shownBeforeAnswer = $0.map(\.price) }
        let settledSubscription = unusable.$isLoading.dropFirst().filter { !$0 }.sink { _ in settled.fulfill() }
        unusable.activate()
        await fulfillment(of: [settled], timeout: 5)
        shownSubscription.cancel()
        settledSubscription.cancel()
        XCTAssertEqual(shownBeforeAnswer, [300, 310, 320], "The saved day was shown first")
        XCTAssertTrue(unusable.chartData.isEmpty, "and is not left on screen when Folync cannot be used")
        XCTAssertTrue(unusable.coverageLabel.contains("unavailable"), unusable.coverageLabel)

        // Switched off, Folync's saved history is not shown.
        settingsStore.save(FolyncStoredSettings(
            isEnabled: false, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let whenOff = await coordinator.savedPortfolioHistory(range: "1d")
        XCTAssertNil(whenOff)
    }

    /// The Performance tab's portfolio charts say Folync couldn't be reached,
    /// beside the "Unavailable" badge, only for the series it didn't answer.
    @MainActor
    func testPerformancePortfolioChartSaysWhenFolyncCannotBeReached() {
        let manager = HistoricalDataManager.shared
        manager.clearFolyncSupplementalOverlays()
        defer { manager.clearFolyncSupplementalOverlays() }

        func state(_ kind: String, _ range: ChartTimeRange) -> (FolyncSupplementalSourceStatus?, Bool, String?) {
            (manager.folyncPortfolioSourceStatus(kind: kind, timeRange: range),
             manager.folyncPortfolioUnreachable(kind: kind, timeRange: range),
             manager.folyncPortfolioCoverage(kind: kind, timeRange: range))
        }

        manager.applyFolyncPortfolioHistory(.unreachable, timeRange: .week, customFrom: nil, customTo: nil)
        for kind in ["portfolio-value", "portfolio-gain"] {
            let (status, unreachable, coverage) = state(kind, .week)
            XCTAssertEqual(status, .unavailable, kind)
            XCTAssertTrue(unreachable, kind)
            XCTAssertEqual(coverage, "Couldn't reach Folync", kind)
        }
        XCTAssertFalse(manager.folyncPortfolioUnreachable(kind: "portfolio-value", timeRange: .month))

        // Folync answered with an error or unusable data: unavailable, no reason given.
        manager.applyFolyncPortfolioHistory(.unavailable, timeRange: .week, customFrom: nil, customTo: nil)
        var (status, unreachable, coverage) = state("portfolio-value", .week)
        XCTAssertEqual(status, .unavailable)
        XCTAssertFalse(unreachable)
        XCTAssertNil(coverage)

        manager.applyFolyncPortfolioHistory(.unreachable, timeRange: .week, customFrom: nil, customTo: nil)
        manager.applyFolyncPortfolioHistory(.legacy, timeRange: .week, customFrom: nil, customTo: nil)
        (status, unreachable, coverage) = state("portfolio-gain", .week)
        XCTAssertEqual(status, .legacy)
        XCTAssertFalse(unreachable)
        XCTAssertNil(coverage)

        manager.applyFolyncPortfolioHistory(.unreachable, timeRange: .month, customFrom: nil, customTo: nil)
        manager.clearFolyncSupplementalOverlays()
        XCTAssertFalse(manager.folyncPortfolioUnreachable(kind: "portfolio-value", timeRange: .month))
    }

    /// When Folync does not answer and nothing is saved, the chart says
    /// Folync could not be reached rather than asking for more history.
    @MainActor
    func testPortfolioMenuSaysWhenFolyncCannotBeReached() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncMenuUnreachable-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let series = "[{\"date\":\"2026-09-10T09:00:00Z\",\"value\":100},{\"date\":\"2026-09-10T09:05:00Z\",\"value\":110}]"
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        // nil: time out; negative: fail with that URLError code; otherwise this HTTP status.
        let answer = LockedBox<Int?>(nil)
        stub.handler = { request in
            guard let status = answer.value else { throw URLError(.timedOut) }
            if status < 0 { throw URLError(URLError.Code(rawValue: status)) }
            let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "range" }?.value ?? ""
            let body = status == 200 && !stub.isOffline ? """
            {"schemaVersion":2,"sourceRevision":"unreachable-test",
             "scope":{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"},
             "range":"\(range)","interval":"1h","generatedAt":"2026-09-10T09:10:00Z","currency":"GBP",
             "quality":"complete","reasonCodes":[],"coverage":{"pointCount":2,"complete":true},
             "portfolioSeries":\(series),"cashSeries":\(series),"holdingsSeries":\(series),
             "netContributionSeries":\(series),"gainSeries":\(series),"twrSeries":\(series)}
            """ : "{}"
            return Self.httpResponse(request, status: status, body: body)
        }
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore, cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(), providerPolicy: Self.testProviderPolicy, tokenProvider: { "test-token" }
        )

        // Folync did not answer: a timeout, any other connection failure such
        // as TLS, or the server in front of it saying so.
        for status in [nil, URLError.Code.secureConnectionFailed.rawValue, 502, 503, 504] as [Int?] {
            answer.value = status
            guard case .unreachable = await coordinator.routePortfolioHistory(range: "1w") else {
                return XCTFail("Expected unreachable for \(status.map(String.init) ?? "a timeout")")
            }
        }
        // Folync answered, but with an error or data Stockbar cannot use.
        answer.value = 500
        guard case .unavailable = await coordinator.routePortfolioHistory(range: "1w") else {
            return XCTFail("A 500 is an answer, not an unreachable server")
        }
        answer.value = 200
        stub.isOffline = true // Answer 200 with an empty object.
        guard case .unavailable = await coordinator.routePortfolioHistory(range: "1w") else {
            return XCTFail("Unusable data is not an unreachable server")
        }

        let model = PortfolioMenuChartViewModel(
            currentValue: 170000, currentTrades: [], preferredCurrency: "GBP", valuationSource: .folyncProvided,
            folyncCoordinator: coordinator, folyncSettingsStore: settingsStore
        )
        defer { model.deactivate() }
        func load(_ range: MenuChartTimeRange) async {
            let loaded = expectation(description: "Loaded \(range)")
            loaded.assertForOverFulfill = false
            let subscription = model.$isLoading.dropFirst().filter { !$0 }.sink { _ in loaded.fulfill() }
            model.activate()
            model.setTimeRange(range)
            model.loadChartData()
            await fulfillment(of: [loaded], timeout: 5)
            subscription.cancel()
        }

        answer.value = nil
        await load(.week)
        XCTAssertTrue(model.folyncUnreachable)
        XCTAssertFalse(model.folyncStale)
        XCTAssertTrue(model.chartData.isEmpty)
        XCTAssertTrue(model.coverageLabel.hasPrefix("Couldn't reach Folync"), model.coverageLabel)

        // Once Folync answers, the week is saved and the state clears.
        answer.value = 200
        stub.isOffline = false
        await load(.week)
        XCTAssertFalse(model.folyncUnreachable)
        XCTAssertFalse(model.folyncStale)
        XCTAssertEqual(model.chartData.map(\.price), [100, 110])

        // A saved copy is shown, marked stale, rather than "couldn't reach".
        answer.value = nil
        await load(.week)
        XCTAssertFalse(model.folyncUnreachable)
        XCTAssertTrue(model.folyncStale, "The Overview says there is no current history, not that the period is partial")
        XCTAssertEqual(model.chartData.map(\.price), [100, 110])
        XCTAssertTrue(model.coverageLabel.hasPrefix(FolyncSupplementalSourceStatus.stale.label), model.coverageLabel)

        // A range with nothing saved still says so, and switching away clears it.
        await load(.month)
        XCTAssertTrue(model.folyncUnreachable)
        XCTAssertFalse(model.folyncStale)
        answer.value = 500
        await load(.day)
        XCTAssertFalse(model.folyncUnreachable)
        XCTAssertTrue(model.coverageLabel.contains("unavailable"), model.coverageLabel)
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
        let suiteName = TestDefaultsSuite.makeName("FolyncPortfolioHistory-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncSupplementalTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncFallbackTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncCapabilityDiscoveryTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncMissingIdentityTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncBenchmarkFXTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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

    // MARK: - Acceptance run: Folync on this Mac only

    /// The policy an explicit acceptance run gets, built the way the app builds it.
    private static func explicitAcceptancePolicy() throws -> StockbarProviderAccessPolicy {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolyncAcceptancePolicyTests-\(UUID().uuidString)", isDirectory: true)
        let runtime = try StockbarAcceptanceRuntime.resolve(environment: [
            "STOCKBAR_ACCEPTANCE_ROOT": root.path,
            "STOCKBAR_ACCEPTANCE_RUN_ID": "acceptance-12345678",
            "STOCKBAR_DISABLE_LIVE_PROVIDERS": "1"
        ])
        return StockbarProviderAccessPolicy(runtime: runtime)
    }

    func testAcceptanceRunReachesFolyncSourceOnThisMac() async throws {
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            guard request.url?.path == "/api/client/v2/portfolios" else {
                return Self.httpResponse(request, status: 500, body: "{}")
            }
            return Self.httpResponse(
                request,
                status: 200,
                body: """
                {"schemaVersion":2,"portfolios":[{"id":"all","name":"All portfolios","kind":"aggregate","currency":"GBP"}]}
                """
            )
        }
        let source = try FolyncPortfolioSource(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:49152")),
            token: "test-token",
            session: Self.stubSession(),
            providerPolicy: Self.explicitAcceptancePolicy()
        )

        let portfolios = try await source.listPortfolios()

        XCTAssertEqual(portfolios.map(\.id), ["all"])
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(stub.requests.first?.url?.host, "127.0.0.1")
        XCTAssertEqual(stub.requests.first?.url?.port, 49152)
    }

    func testAcceptanceRunRefusesFolyncSourceElsewhereBeforeSending() async throws {
        // `http://192.168.1.10:4100` is refused earlier, by the endpoint policy
        // when the source is made, so HTTPS forms isolate the provider policy.
        XCTAssertThrowsError(try FolyncPortfolioSource(
            baseURL: XCTUnwrap(URL(string: "http://192.168.1.10:4100")),
            token: "test-token",
            session: Self.stubSession(),
            providerPolicy: Self.explicitAcceptancePolicy()
        )) { error in
            XCTAssertEqual(error as? FolyncPortfolioSourceError, .insecureTransport)
        }

        for endpoint in ["https://folync.invalid", "https://192.168.1.10:4100", "https://127.0.0.1.example.com"] {
            let stub = FolyncHTTPStub()
            FolyncURLProtocolStub.stub = stub
            stub.handler = { request in Self.httpResponse(request, status: 200, body: "{}") }
            let source = try FolyncPortfolioSource(
                baseURL: XCTUnwrap(URL(string: endpoint)),
                token: "test-token",
                session: Self.stubSession(),
                providerPolicy: Self.explicitAcceptancePolicy()
            )

            do {
                _ = try await source.listPortfolios()
                XCTFail("Expected provider denial for \(endpoint)")
            } catch {
                XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.folync), endpoint)
            }
            XCTAssertTrue(stub.requests.isEmpty, "No request may be sent to \(endpoint)")
        }
    }

    func testAcceptanceRunReachesSupplementalFolyncOnThisMac() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncAcceptanceLoopbackTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-acceptance-loopback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            guard request.url?.path == "/api/client/v2/capabilities" else {
                return Self.httpResponse(request, status: 500, body: "{}")
            }
            return Self.httpResponse(request, status: 200, body: Self.capabilitiesJSON)
        }
        let coordinator = try FolyncSupplementalCoordinator(
            settingsStore: FolyncSettingsStore(defaults: defaults),
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.explicitAcceptancePolicy(),
            tokenProvider: { "test-token" }
        )

        let capabilities = try await coordinator.fetchCapabilities(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:49152")),
            token: "test-token"
        )

        XCTAssertEqual(capabilities?.sourceRevision, "caps-1")
        XCTAssertEqual(stub.requests.map(\.url?.path), ["/api/client/v2/capabilities"])
        XCTAssertEqual(stub.requests.first?.url?.host, "127.0.0.1")
    }

    func testAcceptanceRunRefusesSupplementalFolyncElsewhereBeforeSending() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncAcceptanceLoopbackTests-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-acceptance-loopback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in Self.httpResponse(request, status: 200, body: Self.capabilitiesJSON) }
        let coordinator = try FolyncSupplementalCoordinator(
            settingsStore: FolyncSettingsStore(defaults: defaults),
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.explicitAcceptancePolicy(),
            tokenProvider: { "test-token" }
        )

        // The provider policy runs before the endpoint policy here, so the
        // plain-HTTP address on the network is refused by it too.
        for endpoint in ["https://folync.invalid", "http://192.168.1.10:4100", "https://192.168.1.10:4100"] {
            do {
                _ = try await coordinator.fetchCapabilities(
                    baseURL: XCTUnwrap(URL(string: endpoint)),
                    token: "test-token"
                )
                XCTFail("Expected provider denial for \(endpoint)")
            } catch {
                XCTAssertEqual(error as? ProviderAccessError, .disabledForAcceptance(.folync), endpoint)
            }
        }
        XCTAssertTrue(stub.requests.isEmpty, "No request may leave this Mac")
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

    func testAPenceCostCurrencyStaysPenceWhenNormalised() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(versionTwoSnapshotJSON.utf8)) as? [String: Any]
        )
        var holdings = try XCTUnwrap(object["holdings"] as? [[String: Any]])
        holdings[0]["averageCostCurrency"] = "GBp"
        holdings[0]["valueCurrency"] = " gbp "
        object["holdings"] = holdings

        let holding = try XCTUnwrap(FolyncPortfolioDecoder().decodeSnapshot(
            JSONSerialization.data(withJSONObject: object)
        ).holdings.first)

        // Upper-casing "GBp" would have read a cost in pence as pounds.
        XCTAssertEqual(holding.resolvedAverageCostCurrency, "GBX")
        XCTAssertEqual(holding.resolvedValueCurrency, "GBP")
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
        let suiteName = TestDefaultsSuite.makeName("FolyncKeychainActor-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let suiteName = TestDefaultsSuite.makeName("FolyncBackoffSupplemental-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
    func testTrading212SyncIsSkippedWhileFolyncSuppliesThePortfolio() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }
        dataModel.applyFolyncSnapshot(try FolyncPortfolioDecoder().decodeSnapshot(Data(versionTwoSnapshotJSON.utf8)))

        let sync = try await dataModel.syncLinkedTrading212Holdings(reason: "auto")
        XCTAssertEqual(sync.skippedReason, DataModel.trading212SkippedForFolyncReason)
        XCTAssertEqual(sync.deletedCount, 0)
        let reconcile = try await dataModel.reconcileTrading212Holdings(reason: "auto-reconcile")
        XCTAssertEqual(reconcile.skippedReason, DataModel.trading212SkippedForFolyncReason)
        XCTAssertEqual(reconcile.deletedCount, 0)
    }

    func testCachedFolyncDataIsNotCalledOfflineWhenTheServerAnswered() {
        let rejected = FolyncConnectionState.offlineCached(message: "Folync access token was rejected.")
        XCTAssertEqual(rejected.message, "Showing the last Folync data. Folync access token was rejected.")
        XCTAssertFalse(rejected.message.contains("Offline"))
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

    func testFXRatesDatedADayApartAreUsedAndDatedByTheOldest() async throws {
        let dayBehind = Self.fxJSON.replacingOccurrences(
            of: "{\"quote\":\"JPY\",\"rate\":159.2,\"asOf\":\"2026-07-13\"",
            with: "{\"quote\":\"JPY\",\"rate\":159.2,\"asOf\":\"2026-07-10\""
        )
        let weekBehind = dayBehind.replacingOccurrences(of: "\"asOf\":\"2026-07-10\"", with: "\"asOf\":\"2026-07-03\"")

        guard case .folync(let rates, let asOf, _) = try await routeFX(servingFX: dayBehind) else {
            return XCTFail("Rates a few days apart should be accepted")
        }
        XCTAssertEqual(rates["JPY"], 159.2)
        XCTAssertEqual(asOf, FolyncSupplementalDateParser.day("2026-07-10"))
        if case .folync = try await routeFX(servingFX: weekBehind) {
            XCTFail("Rates ten days apart should not be used as one set")
        }
    }

    private func routeFX(servingFX body: String) async throws -> FolyncRoutedFXResult {
        let suiteName = TestDefaultsSuite.makeName("FolyncFXDays-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            switch request.url?.path {
            case "/api/client/v2/capabilities":
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            case "/api/client/v2/market/fx":
                return Self.httpResponse(request, status: 200, body: body, etag: "\"fx-days\"")
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
        return await coordinator.routeFX()
    }

    func testExtraAdvertisedFXQuotesAreRequestedAndAccepted() async throws {
        let suiteName = TestDefaultsSuite.makeName("FolyncExtraFXQuotes-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
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

        // The stored token is never offered to a server it was not saved for.
        do {
            _ = try await dataModel.testFolyncConnection(
                baseURL: URL(string: "https://folync.example.invalid")!,
                token: ""
            )
            XCTFail("A blank token must not fall back to the stored one before a server is saved")
        } catch {
            XCTAssertEqual(error as? FolyncPortfolioSourceError, .missingToken)
        }
        XCTAssertTrue(stub.requests.isEmpty, "Nothing is sent without a token for this server")
        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: false, baseURL: "https://folync.example.invalid", scopeID: "all", pollingIntervalSeconds: 60
        ))
        XCTAssertFalse(dataModel.storedFolyncTokenApplies(to: URL(string: "https://other.example.invalid")))
        XCTAssertFalse(dataModel.storedFolyncTokenApplies(to: URL(string: "http://folync.example.invalid")))
        XCTAssertTrue(dataModel.storedFolyncTokenApplies(to: URL(string: "https://folync.example.invalid/base")))

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

    func testTheSupplementalCacheDropsOnlyOldResponses() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FolyncSupplementalCache(directory: directory)
        for identity in ["OLD", "NEW"] {
            try await cache.save(
                ["value": 1], endpoint: "https://folync.example.test", scopeID: "all",
                resource: "chart", identity: identity, range: "1m", etag: nil
            )
        }
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("response-") }
        XCTAssertEqual(files.count, 2)
        let longAgo = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: files[0].path)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: unrelated.path)

        let removed = await cache.removeEntries()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
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
    func testNetDepositsFromTheThreeMonthHistorySetTheTotalReturn() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true, baseURL: "https://folync.test", scopeID: "all",
            pollingIntervalSeconds: 60, supplemental: .disabled
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        let historyPath = "/api/client/v2/scopes/all/history"
        let snapshotBody = versionTwoSnapshotJSON
        func answer(netDeposits: Double) -> FolyncHTTPStub.Handler {
            let body = Self.portfolioHistoryJSON(netContribution: [500, netDeposits])
            return { request in
                switch request.url?.path {
                case "/api/client/v2/capabilities":
                    return Self.httpResponse(request, status: 200, body: Self.capabilitiesJSON)
                case "/api/client/v2/scopes/all/snapshot":
                    return Self.httpResponse(request, status: 200, body: snapshotBody)
                case historyPath:
                    let range = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "range" }?.value
                    XCTAssertEqual(range, "3m", "the cheapest history range, from Folync's stored daily snapshots")
                    return Self.httpResponse(request, status: 200, body: body)
                default:
                    XCTFail("unexpected request \(request.url?.path ?? "")")
                    return Self.httpResponse(request, status: 404, body: "{}")
                }
            }
        }
        func historyReads() -> Int { stub.requests.filter { $0.url?.path == historyPath }.count }
        stub.handler = answer(netDeposits: 600)
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        // Value 1,100 with 800 of it cash; holdings cost 201 with an unrealised gain of 99.
        dataModel.folyncPortfolioSnapshot = try JSONDecoder().decode(
            FolyncPortfolioSnapshot.self, from: Data(snapshotBody.utf8)
        )

        // The minute-by-minute supplemental refresh reads it, with every route switched off.
        await dataModel.refreshFolyncSupplementalMarketData()
        let start = Date()
        XCTAssertEqual(dataModel.folyncNetDeposits?.amount, 600)
        let summary = dataModel.calculateDisplayPortfolioSummary()
        XCTAssertEqual(summary.netDeposits, 600)
        let againstDeposits = summary.totalReturn(measuredAgainst: .netDeposits)
        XCTAssertTrue(againstDeposits.isMeasuredAgainstNetDeposits)
        XCTAssertEqual(againstDeposits.gain, 500, "the whole account's value less the money paid in")
        XCTAssertEqual(againstDeposits.percent, 500.0 / 600.0 * 100, accuracy: 0.000_001)
        XCTAssertEqual(againstDeposits.basisAmount, 600)
        XCTAssertEqual(againstDeposits.basisLabel, "Net Deposits")
        let againstCost = summary.totalReturn(measuredAgainst: .holdingsCost)
        XCTAssertFalse(againstCost.isMeasuredAgainstNetDeposits)
        XCTAssertEqual(againstCost.gain, 99)
        XCTAssertEqual(againstCost.basisAmount, 201)
        XCTAssertEqual(againstCost.basisLabel, "Cost Basis")
        XCTAssertEqual(summary.totalGain, 99, "the recorded gain keeps its meaning")

        stub.handler = answer(netDeposits: 700)
        await dataModel.refreshFolyncNetDeposits(now: start.addingTimeInterval(60))
        XCTAssertEqual(dataModel.folyncNetDeposits?.amount, 600, "not read again within five minutes")
        await dataModel.refreshFolyncNetDeposits(now: start.addingTimeInterval(301))
        XCTAssertEqual(dataModel.folyncNetDeposits?.amount, 700)
        XCTAssertEqual(historyReads(), 2)
        stub.handler = answer(netDeposits: 750)
        await dataModel.refreshFolyncPortfolio()
        XCTAssertEqual(dataModel.folyncNetDeposits?.amount, 750, "Refresh Now reads it at once")

        // Net deposits read for one scope never measure another.
        dataModel.folyncPortfolioSnapshot = try JSONDecoder().decode(
            FolyncPortfolioSnapshot.self, from: Data(snapshotJSON.utf8)
        )
        XCTAssertNil(dataModel.calculateDisplayPortfolioSummary().netDeposits)

        // When Folync's answer cannot be used, the route serves the history it
        // cached earlier, marked stale. That may be from an earlier day, so it
        // is not taken: the figure already read is kept while it is recent,
        // and the next refresh tries again rather than waiting five minutes.
        stub.handler = { request in
            Self.httpResponse(request, status: 200, body: Self.portfolioHistoryJSON(
                netContribution: [500, 900], quality: "unavailable"
            ))
        }
        // The manual refresh read it just after `start`.
        let readsBeforeFailure = historyReads()
        await dataModel.refreshFolyncNetDeposits(now: start.addingTimeInterval(603))
        XCTAssertEqual(dataModel.folyncNetDeposits?.amount, 750, "a figure read ten minutes ago is kept")
        await dataModel.refreshFolyncNetDeposits(now: start.addingTimeInterval(663))
        XCTAssertEqual(historyReads(), readsBeforeFailure + 2, "tried again a minute later")
        await dataModel.refreshFolyncNetDeposits(now: start.addingTimeInterval(910))
        XCTAssertNil(dataModel.folyncNetDeposits, "neither kept past fifteen minutes nor taken from the cached history")

        dataModel.deactivateFolyncPortfolio(persistSetting: false)
        XCTAssertNil(dataModel.folyncNetDeposits)
    }

    func testNetDepositsAreOnlyTakenFromAHistoryThatCanGiveThem() throws {
        func netDeposits(_ json: String) throws -> FolyncNetDeposits? {
            FolyncNetDeposits(history: try JSONDecoder().decode(FolyncPortfolioHistory.self, from: Data(json.utf8)))
        }
        let snapshot = try JSONDecoder().decode(FolyncPortfolioSnapshot.self, from: Data(versionTwoSnapshotJSON.utf8))

        let usable = try XCTUnwrap(netDeposits(Self.portfolioHistoryJSON(netContribution: [500, 600], quality: "partial")))
        XCTAssertEqual(usable.amount, 600, "partial quality does not make net deposits wrong")
        XCTAssertEqual(usable.asOf, "2026-07-11")
        XCTAssertEqual(usable.amount(for: snapshot), 600)

        XCTAssertNil(try netDeposits(Self.portfolioHistoryJSON(
            netContribution: [500, 600], reasonCodes: ["missing_transaction_fx"]
        )), "a deposit without an exchange rate stops the series early")
        XCTAssertNil(try netDeposits(Self.portfolioHistoryJSON(
            netContribution: [500, 600], netContributionDates: ["2026-07-09", "2026-07-10"]
        )), "a series that ends before the value series is out of date")
        XCTAssertNil(try netDeposits(Self.portfolioHistoryJSON(netContribution: [0, 0])),
                     "no deposit records at all, as for a broker account imported without its cash history")
        XCTAssertNil(try netDeposits(Self.portfolioHistoryJSON(netContribution: [500, 600], quality: "unavailable")))

        let otherCurrency = try XCTUnwrap(netDeposits(Self.portfolioHistoryJSON(netContribution: [500, 600], currency: "USD")))
        XCTAssertNil(otherCurrency.amount(for: snapshot), "net deposits in another currency than the value")
        let otherScope = try XCTUnwrap(netDeposits(Self.portfolioHistoryJSON(netContribution: [500, 600], scopeID: "pf_isa")))
        XCTAssertNil(otherScope.amount(for: snapshot), "net deposits of another portfolio")
    }

    /// A three-month portfolio history worth 1,000 and then 1,100.
    private static func portfolioHistoryJSON(
        netContribution: [Double],
        netContributionDates: [String] = ["2026-07-10", "2026-07-11"],
        quality: String = "complete",
        reasonCodes: [String] = [],
        currency: String = "GBP",
        scopeID: String = "all"
    ) -> String {
        func series(_ values: [Double], dates: [String]) -> String {
            "[" + zip(dates, values).map { "{\"date\":\"\($0)\",\"value\":\($1)}" }.joined(separator: ",") + "]"
        }
        let dates = ["2026-07-10", "2026-07-11"]
        let values = series([1_000, 1_100], dates: dates)
        let reasons = "[" + reasonCodes.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return """
        {"schemaVersion":2,"sourceRevision":"history-test",
         "scope":{"id":"\(scopeID)","name":"All portfolios","kind":"aggregate","currency":"\(currency)"},
         "range":"3m","interval":"1d","generatedAt":"2026-07-12T12:00:00Z","currency":"\(currency)",
         "quality":"\(quality)","reasonCodes":\(reasons),
         "coverage":{"requestedFrom":"2026-04-12","requestedTo":"2026-07-12",
         "availableFrom":"2026-07-10","availableTo":"2026-07-11","pointCount":2,"complete":false},
         "portfolioSeries":\(values),"cashSeries":\(values),"holdingsSeries":\(values),
         "netContributionSeries":\(series(netContribution, dates: netContributionDates)),
         "gainSeries":\(values),"twrSeries":\(values)}
        """
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
        let suiteName = TestDefaultsSuite.makeName("FolyncSessionTests-")
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
            saveToken: { _, _ in },
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
                TestDefaultsSuite.remove(suiteName)
                try? FileManager.default.removeItem(at: cacheDirectory)
                try? FileManager.default.removeItem(at: supplementalCacheDirectory)
            }
        )
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        isolation: isolated (any Actor)? = #isolation,
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

// MARK: - Ledger routes

extension FolyncPortfolioSourceTests {
    /// The capabilities fixture with the three ledger resources, each usable
    /// unless named in `notReady` or `unsupported`, or left out in `absent`.
    fileprivate static func ledgerCapabilitiesJSON(
        notReady: Set<String> = [],
        unsupported: Set<String> = [],
        absent: Set<String> = []
    ) -> String {
        let entries = ["dividends", "tradeAnalysis", "transactions"].filter { !absent.contains($0) }.map { key in
            "\"\(key)\": {\"supported\":\(!unsupported.contains(key)),\"ready\":\(!notReady.contains(key)),\"reasonCodes\":[]},"
        }
        // Only the top-level resources; the market identities have their own.
        var json = capabilitiesJSON
        guard let range = json.range(of: "\"resources\": {\n") else { return json }
        json.replaceSubrange(range, with: "\"resources\": {\n" + entries.joined(separator: "\n") + "\n")
        return json
    }

    func testCapabilitiesSavedWithoutLedgerResourcesAreAskedForInFull() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-ledger-caps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = FolyncSupplementalCache(directory: cacheDirectory)
        // Saved by a build that did not know the ledger resources.
        try await cache.save(
            FolyncCapabilities.fixture(lineHistory: true, candlesticks: true, benchmarks: true, exchangeRates: true),
            endpoint: "https://folync.test", scopeID: "-", resource: "capabilities", identity: "-", range: "-",
            etag: "W/\"saved-before\""
        )
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        let body = Self.ledgerCapabilitiesJSON()
        stub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/client/v2/capabilities")
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                return Self.httpResponse(request, status: 304, body: "")
            }
            return Self.httpResponse(request, status: 200, body: body, etag: "W/\"with-ledger\"")
        }
        let coordinator = FolyncSupplementalCoordinator(
            cache: cache, session: Self.stubSession(), providerPolicy: Self.testProviderPolicy, tokenProvider: { "test-token" }
        )
        let baseURL = try XCTUnwrap(URL(string: "https://folync.test"))

        let first = try await coordinator.fetchCapabilities(baseURL: baseURL, token: "test-token")
        XCTAssertNil(stub.requests.first?.value(forHTTPHeaderField: "If-None-Match"),
                     "A document saved without the ledger resources must not be confirmed by a 304")
        XCTAssertEqual(first?.resources.dividends?.isUsable, true)

        let second = try await coordinator.fetchCapabilities(baseURL: baseURL, token: "test-token")
        XCTAssertEqual(stub.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"with-ledger\"")
        XCTAssertEqual(second?.resources.transactions?.isUsable, true, "The 304 returns the saved document with its ledger resources")
    }

    // MARK: Ledger harness

    fileprivate typealias LedgerResponder = @Sendable (URLRequest) throws -> (status: Int, body: String, etag: String?)

    fileprivate struct LedgerHarness: Sendable {
        let coordinator: FolyncSupplementalCoordinator
        let stub: FolyncHTTPStub
        let settingsStore: FolyncSettingsStore
        let clock: LockedBox<Date>
        let responder: LockedBox<LedgerResponder?>
        let cacheDirectory: URL

        /// Requests to the ledger routes only; the capabilities request is left out.
        var ledgerRequests: [URLRequest] {
            stub.requests.filter { $0.url?.path.hasPrefix("/api/client/v2/scopes/") == true }
        }

        func respond(_ responder: @escaping LedgerResponder) {
            self.responder.value = responder
        }

        func advance(_ seconds: TimeInterval) {
            clock.value = clock.value.addingTimeInterval(seconds)
        }
    }

    fileprivate static let ledgerSettingsOn = FolyncSupplementalSettings(
        historicalLineCharts: false,
        candlestickCharts: false,
        benchmarkMarketData: false,
        exchangeRates: false,
        allowLegacyFallback: false
    )

    fileprivate func makeLedgerHarness(
        scopeID: String = "all",
        supplemental: FolyncSupplementalSettings = ledgerSettingsOn,
        folyncEnabled: Bool = true,
        capabilities: String? = ledgerCapabilitiesJSON(),
        providerPolicy: StockbarProviderAccessPolicy = testProviderPolicy
    ) throws -> LedgerHarness {
        let suiteName = TestDefaultsSuite.makeName("FolyncLedger-")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { TestDefaultsSuite.remove(suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folync-ledger-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheDirectory) }
        let settingsStore = FolyncSettingsStore(defaults: defaults)
        settingsStore.save(FolyncStoredSettings(
            isEnabled: folyncEnabled, baseURL: "https://folync.test", scopeID: scopeID,
            pollingIntervalSeconds: 60, supplemental: supplemental
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        let responder = LockedBox<LedgerResponder?>(nil)
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/capabilities" {
                guard let capabilities else { return Self.httpResponse(request, status: 404, body: "{}") }
                return Self.httpResponse(request, status: 200, body: capabilities, etag: "W/\"caps\"")
            }
            guard let respond = responder.value else { throw URLError(.badServerResponse) }
            let (status, body, etag) = try respond(request)
            return Self.httpResponse(request, status: status, body: body, etag: etag)
        }
        let clock = LockedBox(Date(timeIntervalSince1970: 1_780_000_000))
        let coordinator = FolyncSupplementalCoordinator(
            settingsStore: settingsStore,
            cache: FolyncSupplementalCache(directory: cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: providerPolicy,
            ledgerPolicy: FolyncLedgerFetchPolicy(now: { clock.value }),
            tokenProvider: { "test-token" }
        )
        return LedgerHarness(
            coordinator: coordinator, stub: stub, settingsStore: settingsStore, clock: clock, responder: responder,
            cacheDirectory: cacheDirectory
        )
    }

    /// A route's result reduced to what the tests compare.
    fileprivate enum LedgerOutcome: Equatable {
        case folync(FolyncSupplementalSourceStatus, FolyncLedgerPaging, rows: [String], next: FolyncLedgerContinuation?)
        case disabled
        case unavailable
        case unreachable

        var continuation: FolyncLedgerContinuation? {
            if case .folync(_, _, _, let next) = self { return next }
            return nil
        }
    }

    fileprivate static func outcome<Response: FolyncLedgerResponse>(
        _ result: FolyncRoutedLedgerResult<Response>,
        rows: (Response) -> [String]
    ) -> LedgerOutcome {
        switch result {
        case .folync(let response, let status, let paging):
            return .folync(status, paging, rows: rows(response), next: response.page.continuation)
        case .disabled: return .disabled
        case .unavailable: return .unavailable
        case .unreachable: return .unreachable
        }
    }

    /// Page one of `route` with its default query, or the page after `continuation`.
    fileprivate static func ledger(
        _ route: FolyncLedgerRoute,
        _ harness: LedgerHarness,
        forceRefresh: Bool = false,
        after continuation: FolyncLedgerContinuation? = nil
    ) async -> LedgerOutcome {
        let coordinator = harness.coordinator
        switch route {
        case .dividends:
            let query = FolyncDividendsQuery()
            var result = await coordinator.routeDividends(query, forceRefresh: forceRefresh)
            if let continuation { result = await coordinator.loadMoreDividends(query, after: continuation) }
            return Self.outcome(result) { $0.events.map(\.eventId) }
        case .tradeAnalysis:
            let query = FolyncTradeAnalysisQuery()
            var result = await coordinator.routeTradeAnalysis(query, forceRefresh: forceRefresh)
            if let continuation { result = await coordinator.loadMoreTradeAnalysis(query, after: continuation) }
            return Self.outcome(result) { $0.lots.map(\.id) }
        case .transactions:
            let query = FolyncTransactionsQuery()
            var result = await coordinator.routeTransactions(query, forceRefresh: forceRefresh)
            if let continuation { result = await coordinator.loadMoreTransactions(query, after: continuation) }
            return Self.outcome(result) { $0.transactions.map(\.id) }
        }
    }

    fileprivate static func queryValue(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: Ledger fixtures (invented figures)

    fileprivate static func ledgerRevision(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    fileprivate static func rowPrefix(_ route: FolyncLedgerRoute) -> String {
        switch route {
        case .dividends: "div"
        case .tradeAnalysis: "lot"
        case .transactions: "tx"
        }
    }

    private static let ledgerIdentity = """
    {"assetId":"asset_alpha","canonicalTicker":"ALPHA","displayTicker":"ALPHA","quoteSymbol":"ALPHA.L","aliases":["ALPHA"],"isin":null}
    """

    private static func ledgerMetric(_ value: String, quality: String = "complete") -> String {
        "{\"value\":\(value),\"currency\":\"GBP\",\"quality\":\"\(quality)\",\"reasonCodes\":[],\"asOfDate\":\"2026-03-02\"}"
    }

    private static let ledgerFreshness = """
    {"responseGeneratedAt":"2026-03-02T09:00:00.000Z","asOf":"2026-03-02","status":"current","reasonCodes":[],
     "sources":{"snapshots":{"asOfDate":"2026-03-02","status":"clean","generation":7,"dirtySince":null,
     "rebuildStartedAt":null,"failedAt":null,"completedAt":"2026-03-02T08:59:00.000Z"},
     "prices":{"asOfDate":"2026-03-02","ageSeconds":60,"missingCount":0},
     "fx":{"asOfDate":"2026-03-02","ageSeconds":60,"missingCount":0},
     "provider":{"lastSuccessfulSyncAt":"2026-03-02T08:58:00.000Z","ageSeconds":120,"requiredCount":3,"coveredCount":3,"missingCount":0}}}
    """

    private static func dividendRows(_ rowID: String) -> String {
        """
        "events":[{"eventId":"div-\(rowID)","portfolioId":"pf_one","portfolioName":"Example","assetId":"asset_alpha",
         "identity":\(ledgerIdentity),"transactionId":null,"exDate":"2026-02-10","payDate":"2026-03-01","status":"received",
         "amount":12.5,"currency":"GBP","portfolioAmount":\(ledgerMetric("12.5")),"futureField":{"nested":true},
         "discovery":{"eventId":"div-\(rowID)","exDate":"2026-02-10","declarationDate":null,"recordDate":null,
          "amountCertainty":"published","dateCertainty":"estimated","source":"example","sourceUrl":null,"lastCheckedAt":null,
          "entitlementBasis":"current_holdings","quantity":10,"originalCurrency":"GBP","perShare":1.25,"fxAsOfDate":null,
          "fxEstimated":false,"receiptStatus":"received","issues":[]}},
         {"eventId":"div-\(rowID)b","portfolioId":"pf_one","portfolioName":"Example","assetId":"asset_alpha",
         "identity":\(ledgerIdentity),"transactionId":null,"exDate":null,"payDate":"2026-06-01","status":"announced_later",
         "amount":null,"currency":"GBP","portfolioAmount":\(ledgerMetric("null", quality: "unavailable"))}],
        "holdingCoverage":{"totalHoldings":2,"valuedHoldings":1,"missingHoldings":1,"marketValue":\(ledgerMetric("1000"))},
        "liabilityCoverage":{"scope":"current_open_positions","status":"not_applicable","shortHoldingCount":0},
        "valuation":\(ledgerMetric("1000")),
        "summary":{"receivedIncome":120.5,"grossIncome":130,"withholdingTax":9.5,"fees":0,"netIncome":120.5,
         "withholdingProvenance":"actual","declaredIncome":null,"estimatedIncome":40,"knownProjectedIncome":40,
         "incomplete":false,"projectedAnnualIncome":null,"yoyChangePct":null,"portfolioYieldTTMPct":2.1,
         "yieldOnCostTTMPct":2.4,"avgMonthlyIncome":10.04,"avgDailyIncome":0.33,"dividendPayingAssets":2},
        "discovery":{"undatedAnnouncements":[],"coverage":[],"issues":[],"knownDeclaredIncome":null,
         "knownEstimatedIncome":40,"incomplete":true}
        """
    }

    private static func tradeRows(_ rowID: String) -> String {
        """
        "costBasisMethod":"fifo",
        "stats":{"attributionLots":3,"closedAttributionLots":1,"winRatePct":66.7,"wins":2,"losses":1,
         "winRateVsSp500Pct":null,"winsVsSp500":1,"lossesVsSp500":1,"comparisonScope":"configured_benchmarks",
         "benchmarkWinRatePct":50,"benchmarkWins":1,"benchmarkLosses":1,"unavailableBenchmarkComparisons":1,
         "openLotComparisonDate":"2026-03-01","benchmarkBreakdown":[{"benchmarkId":"bench-1","benchmarkName":"Example index",
         "wins":1,"losses":1,"unavailable":1,"winRatePct":50}],"totalTradeGain":42.5,"unavailableAttributionLots":0},
        "activity":[{"period":"2025","fees":3.5,"feesPctOfAvgValue":0.1,"buyCount":4,"sellCount":1,"tradeCount":5,
         "buyValue":800,"sellValue":150,"tradeValue":950,"turnoverPct":null}],
        "lots":[{"id":"lot-\(rowID)","ticker":"ALPHA","side":"Long","openDate":"2025-06-02","price":10.5,"currency":"GBP",
         "shares":10,"openedShares":10,"costBasis":105,"totalGain":null,"totalReturnPct":null,"comparisonReturnPct":null,
         "alphaPct":null,"benchmarkId":"bench-1","benchmarkName":"Example index","benchmarkReturnPct":3.2,
         "benchmarkComparison":{"quality":"complete","reasonCodes":[],"requestedStartDate":"2025-06-02",
          "requestedEndDate":"2026-03-01","startPriceDate":"2025-06-02","endPriceDate":"2026-02-27",
          "holdingPriceDate":"2026-02-27","awaitingHoldingClose":false,"awaitedHoldingCloseDate":null,"holdingPriceFinal":false},
         "holdingDays":272,"status":"Reopened","valuation":\(ledgerMetric("110")),"portfolioId":"pf_one",
         "assetId":"asset_alpha","identity":\(ledgerIdentity)}]
        """
    }

    private static func transactionRows(_ rowID: String) -> String {
        """
        "mode":"input",
        "transactions":[{"id":"tx-\(rowID)","portfolioId":"pf_one","portfolioName":"Example","assetId":"asset_alpha",
         "identity":\(ledgerIdentity),"date":"2026-02-03","action":"buy","quantity":10,"price":10.5,"priceCurrency":"GBP",
         "grossAmount":105,"commission":1,"tax":0.5,"currency":"GBP","portfolioCurrency":"GBP",
         "fxRateToPortfolioCurrency":1,"fxRateSource":"same_currency","fxRateBasis":"settlement_currency_to_portfolio_currency",
         "portfolioAmount":\(ledgerMetric("105")),"source":"manual","importOwned":false},
         {"id":"tx-\(rowID)b","portfolioId":"pf_one","portfolioName":"Example","assetId":null,"identity":null,
         "date":"2026-01-15","action":"gift_received","quantity":0,"price":0,"priceCurrency":null,"grossAmount":250,
         "commission":0,"tax":0,"currency":"USD","portfolioCurrency":"GBP","fxRateToPortfolioCurrency":null,
         "fxRateSource":"unresolved","fxRateBasis":"settlement_currency_to_portfolio_currency",
         "portfolioAmount":\(ledgerMetric("null", quality: "unavailable")),"source":"manual","importOwned":false,
         "adjusted":true,"adjustedReason":"example"}]
        """
    }

    /// One page of `route`, built to the pinned contract's shape with made-up values.
    fileprivate static func ledgerJSON(
        _ route: FolyncLedgerRoute,
        scopeID: String = "all",
        rowID: String = "1",
        revision: String = ledgerRevision("a"),
        hasMore: Bool = false,
        nextCursor: String? = nil,
        schemaVersion: Int = 2
    ) -> String {
        let rows = switch route {
        case .dividends: dividendRows(rowID)
        case .tradeAnalysis: tradeRows(rowID)
        case .transactions: transactionRows(rowID)
        }
        let kind = scopeID == "all" ? "aggregate" : "portfolio"
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        return """
        {"schemaVersion":\(schemaVersion),"sourceRevision":"\(ledgerRevision("f"))","generatedAt":"2026-03-02T09:00:00.000Z",
         "scope":{"id":"\(scopeID)","name":"Example","kind":"\(kind)","currency":"GBP"},"currency":"GBP",
         "quality":"complete","reasonCodes":[],"freshness":\(ledgerFreshness),"unknownTopLevelKey":[1,2,3],
         \(rows),
         "page":{"limit":50,"hasMore":\(hasMore),"nextCursor":\(cursor),"collectionRevision":"\(revision)"}}
        """
    }

    // MARK: Ledger tests

    func testLedgerRoutesReturnPageOneFromTheirOwnPaths() async throws {
        for route in FolyncLedgerRoute.allCases {
            let harness = try makeLedgerHarness()
            harness.respond { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                XCTAssertNil(Self.queryValue(request, "cursor"), "Page one carries no cursor")
                return (200, Self.ledgerJSON(route), "W/\"one\"")
            }

            let result = await Self.ledger(route, harness)

            let rows = route == .tradeAnalysis ? ["lot-1"] : ["\(Self.rowPrefix(route))-1", "\(Self.rowPrefix(route))-1b"]
            XCTAssertEqual(result, .folync(.current, .firstPage, rows: rows, next: nil), "\(route)")
            XCTAssertEqual(harness.ledgerRequests.map { $0.url?.path }, ["/api/client/v2/scopes/all/\(route.pathComponent)"])
        }
    }

    func testLedgerQueriesUseTheContractParameterNamesAndLimits() throws {
        let day = FolyncLedgerDay(year: 2026, month: 1, day: 31)
        let later = FolyncLedgerDay(year: 2026, month: 3, day: 2)
        // Midnight on 1 July in London is still 30 June in UTC; the day asked
        // for is the one the user chose.
        let londonMidnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-30T23:00:00Z"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(FolyncLedgerDay(londonMidnight, in: london).string, "2026-07-01")
        XCTAssertEqual(FolyncLedgerDay(londonMidnight, in: try XCTUnwrap(TimeZone(secondsFromGMT: 0))).string, "2026-06-30")
        XCTAssertEqual(
            FolyncDividendsQuery(status: .upcoming, from: day, to: later, limit: 900).queryItems,
            [URLQueryItem(name: "status", value: "upcoming"), URLQueryItem(name: "from", value: "2026-01-31"),
             URLQueryItem(name: "to", value: "2026-03-02"), URLQueryItem(name: "limit", value: "200")]
        )
        XCTAssertEqual(
            FolyncTradeAnalysisQuery(status: .closed, assetId: "asset_alpha", limit: 0).queryItems,
            [URLQueryItem(name: "status", value: "closed"), URLQueryItem(name: "assetId", value: "asset_alpha"),
             URLQueryItem(name: "limit", value: "1")]
        )
        let transactions = FolyncTransactionsQuery(
            mode: .adjusted, instrument: .ticker("ALPHA"), actions: [.sell, .buy, .dividend], limit: 9_999
        )
        XCTAssertEqual(transactions.queryItems, [
            URLQueryItem(name: "mode", value: "adjusted"), URLQueryItem(name: "ticker", value: "ALPHA"),
            URLQueryItem(name: "actions", value: "buy,sell,dividend"), URLQueryItem(name: "limit", value: "500")
        ])
        XCTAssertEqual(FolyncTransactionsQuery(instrument: .assetId("asset_alpha")).queryItems,
                       [URLQueryItem(name: "assetId", value: "asset_alpha")])
        XCTAssertEqual(transactions.queryItems(cursor: "next").last, URLQueryItem(name: "cursor", value: "next"))
        XCTAssertFalse(transactions.cacheKey.contains("cursor"), "Saved copies are keyed without the cursor")
        XCTAssertEqual(FolyncDividendsQuery().queryItems, [], "Unset parameters are left to Folync's defaults")
    }

    func testLedgerResponsesKeepNullFiguresAndTolerateUnknownValuesAndKeys() throws {
        let dividends = try JSONDecoder().decode(
            FolyncDividendsResponse.self, from: Data(Self.ledgerJSON(.dividends).utf8)
        )
        XCTAssertNil(dividends.summary.projectedAnnualIncome, "A null figure stays unknown, never zero")
        XCTAssertNil(dividends.summary.declaredIncome)
        XCTAssertEqual(try XCTUnwrap(dividends.summary.receivedIncome), 120.5, accuracy: 0.0001)
        XCTAssertEqual(dividends.summary.withholdingProvenance, .known(.actual))
        XCTAssertNil(dividends.events[1].amount)
        XCTAssertNil(dividends.events[1].portfolioAmount.value)
        XCTAssertEqual(dividends.events[1].portfolioAmount.quality, .unavailable)
        XCTAssertEqual(dividends.events[0].status, .known(.received))
        XCTAssertEqual(dividends.events[1].status, .unknown("announced_later"), "An unknown status is kept, not a failure")
        XCTAssertEqual(dividends.events[0].discovery?.dateCertainty, .known(.estimated))
        XCTAssertNil(dividends.events[1].discovery)
        XCTAssertNil(dividends.discovery?.knownDeclaredIncome)
        XCTAssertEqual(dividends.discovery?.incomplete, true)

        let trades = try JSONDecoder().decode(
            FolyncTradeAnalysisResponse.self, from: Data(Self.ledgerJSON(.tradeAnalysis).utf8)
        )
        XCTAssertNil(trades.lots[0].totalGain)
        XCTAssertNil(trades.lots[0].alphaPct)
        XCTAssertNil(trades.stats.winRateVsSp500Pct)
        XCTAssertNil(trades.activity[0].turnoverPct)
        XCTAssertEqual(try XCTUnwrap(trades.stats.totalTradeGain), 42.5, accuracy: 0.0001)
        XCTAssertEqual(trades.lots[0].status, .unknown("Reopened"))
        XCTAssertEqual(trades.lots[0].side, .known(.long))
        XCTAssertEqual(trades.costBasisMethod, .known(.fifo))

        let transactions = try JSONDecoder().decode(
            FolyncTransactionsResponse.self, from: Data(Self.ledgerJSON(.transactions).utf8)
        )
        XCTAssertEqual(transactions.transactions[0].action, .known(.buy))
        XCTAssertEqual(transactions.transactions[1].action, .unknown("gift_received"))
        XCTAssertNil(transactions.transactions[1].fxRateToPortfolioCurrency)
        XCTAssertNil(transactions.transactions[1].portfolioAmount.value)
        XCTAssertNil(transactions.transactions[1].identity)
        XCTAssertEqual(transactions.transactions[1].adjusted, true)
        XCTAssertNil(transactions.transactions[0].adjusted)

        // The saved copy is the re-encoded model: nulls and unknown values survive it.
        let resaved = try JSONDecoder().decode(FolyncDividendsResponse.self, from: JSONEncoder().encode(dividends))
        XCTAssertEqual(resaved, dividends)
        XCTAssertNil(resaved.events[1].amount)
        let resavedTrades = try JSONDecoder().decode(FolyncTradeAnalysisResponse.self, from: JSONEncoder().encode(trades))
        XCTAssertNil(resavedTrades.lots[0].totalGain)
        XCTAssertEqual(resavedTrades.lots[0].status, .unknown("Reopened"))
    }

    func testSavedDividendsReadTheKeptPageOrTheDiskCopyWithoutARequestOrACredential() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { _ in (200, Self.ledgerJSON(.dividends), "W/\"one\"") }
        let query = FolyncDividendsQuery(status: .all, from: FolyncLedgerDay(year: 2025, month: 11, day: 20),
                                         to: FolyncLedgerDay(year: 2027, month: 11, day: 20), limit: 200)

        let nothing = await harness.coordinator.savedDividends(query)
        XCTAssertNil(nothing, "nothing saved, nothing shown")
        XCTAssertTrue(harness.ledgerRequests.isEmpty, "reading what is saved asks nothing")

        _ = await harness.coordinator.routeDividends(query)
        XCTAssertEqual(harness.ledgerRequests.count, 1)
        let kept = await harness.coordinator.savedDividends(query)
        XCTAssertEqual(kept?.events.isEmpty, false, "the page the fetch policy keeps")
        XCTAssertEqual(harness.ledgerRequests.count, 1)

        // Past the reuse window, a coordinator that has never asked reads the copy on
        // disk, and never reads the credential (which could raise a Keychain prompt).
        let credentialReads = LockedBox(0)
        let cold = FolyncSupplementalCoordinator(
            settingsStore: harness.settingsStore,
            cache: FolyncSupplementalCache(directory: harness.cacheDirectory),
            session: Self.stubSession(),
            providerPolicy: Self.testProviderPolicy,
            tokenProvider: {
                credentialReads.value += 1
                throw URLError(.userAuthenticationRequired)
            }
        )
        let fromDisk = await cold.savedDividends(query)
        XCTAssertEqual(fromDisk?.events.map { $0.eventId }, kept?.events.map { $0.eventId })
        XCTAssertEqual(credentialReads.value, 0)
        XCTAssertEqual(harness.ledgerRequests.count, 1, "still the one request")

        let otherQuery = await cold.savedDividends(FolyncDividendsQuery(status: .received))
        XCTAssertNil(otherQuery, "a copy answers only the query it was saved for")

        var settings = harness.settingsStore.load()
        settings.supplemental = FolyncSupplementalSettings(
            historicalLineCharts: false, candlestickCharts: false, benchmarkMarketData: false, exchangeRates: false,
            allowLegacyFallback: false, dividends: false, tradeAnalysis: true, transactions: true
        )
        harness.settingsStore.save(settings)
        let switchedOff = await cold.savedDividends(query)
        XCTAssertNil(switchedOff, "dividends switched off show nothing, saved or not")
        XCTAssertEqual(harness.ledgerRequests.count, 1)
    }

    func testLedgerSavedCopyKeepsNullFiguresWhenFolyncDoesNotAnswer() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { _ in (200, Self.ledgerJSON(.dividends), "W/\"one\"") }
        _ = await harness.coordinator.routeDividends()
        harness.respond { _ in throw URLError(.notConnectedToInternet) }

        let result = await harness.coordinator.routeDividends(forceRefresh: true)

        guard case .folync(let saved, .stale, .firstPage) = result else { return XCTFail("Expected the saved copy, got \(result)") }
        XCTAssertNil(saved.summary.projectedAnnualIncome)
        XCTAssertNil(saved.events[1].amount)
        XCTAssertNil(saved.events[1].portfolioAmount.value)
    }

    func testLedger304ReturnsTheSavedPageOne() async throws {
        for route in FolyncLedgerRoute.allCases {
            let harness = try makeLedgerHarness()
            harness.respond { request in
                if request.value(forHTTPHeaderField: "If-None-Match") == "W/\"one\"" { return (304, "", "W/\"one\"") }
                return (200, Self.ledgerJSON(route), "W/\"one\"")
            }
            let first = await Self.ledger(route, harness)

            let second = await Self.ledger(route, harness, forceRefresh: true)

            XCTAssertEqual(second, first, "\(route)")
            XCTAssertEqual(harness.ledgerRequests.count, 2)
            XCTAssertEqual(harness.ledgerRequests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"one\"")
        }
    }

    func testLedgerBodyThatDoesNotDecodeOrHasAnotherSchemaIsUnavailableOrStale() async throws {
        for route in FolyncLedgerRoute.allCases {
            for body in ["{\"schemaVersion\":2}", "not json", Self.ledgerJSON(route, schemaVersion: 3),
                         Self.ledgerJSON(route, scopeID: "pf_other")] {
                let harness = try makeLedgerHarness()
                harness.respond { _ in (200, body, nil) }
                let unusable = await Self.ledger(route, harness)
                XCTAssertEqual(unusable, .unavailable, "\(route): \(body.prefix(40))")

                harness.respond { _ in (200, Self.ledgerJSON(route), "W/\"one\"") }
                guard case .folync = await Self.ledger(route, harness, forceRefresh: true) else { return XCTFail("\(route)") }
                harness.respond { _ in (200, body, nil) }
                guard case .folync(.stale, .firstPage, _, _) = await Self.ledger(route, harness, forceRefresh: true) else {
                    return XCTFail("\(route): an unusable answer falls back to the saved copy")
                }
            }
        }
    }

    func testLedgerOfflineShowsTheSavedCopyOrReportsUnreachable() async throws {
        for route in FolyncLedgerRoute.allCases {
            let empty = try makeLedgerHarness()
            empty.respond { _ in throw URLError(.notConnectedToInternet) }
            let nothingSaved = await Self.ledger(route, empty)
            XCTAssertEqual(nothingSaved, .unreachable, "\(route)")

            let saved = try makeLedgerHarness()
            saved.respond { _ in (200, Self.ledgerJSON(route), nil) }
            _ = await Self.ledger(route, saved)
            saved.respond { _ in throw URLError(.timedOut) }
            guard case .folync(.stale, .firstPage, let rows, _) = await Self.ledger(route, saved, forceRefresh: true) else {
                return XCTFail("\(route): expected the saved copy")
            }
            XCTAssertEqual(rows.first, "\(Self.rowPrefix(route))-1")
        }
    }

    func testLedgerGatewayErrorsAreUnreachableAndOtherErrorsUnavailable() async throws {
        let expectations: [(Int, LedgerOutcome)] = [(502, .unreachable), (503, .unreachable), (500, .unavailable), (404, .unavailable)]
        for route in FolyncLedgerRoute.allCases {
            for (status, expected) in expectations {
                let empty = try makeLedgerHarness()
                empty.respond { _ in (status, "{}", nil) }
                let result = await Self.ledger(route, empty)
                XCTAssertEqual(result, expected, "\(route) HTTP \(status) with nothing saved")
                let backingOff = await empty.coordinator.isBackingOff()
                XCTAssertFalse(backingOff, "\(route) HTTP \(status) must not start the shared backoff")

                let saved = try makeLedgerHarness()
                saved.respond { _ in (200, Self.ledgerJSON(route), nil) }
                _ = await Self.ledger(route, saved)
                saved.respond { _ in (status, "{}", nil) }
                let withSaved = await Self.ledger(route, saved, forceRefresh: true)
                if status == 404 {
                    XCTAssertEqual(withSaved, .unavailable, "\(route): 404 means the server has no such route")
                } else {
                    guard case .folync(.stale, _, _, _) = withSaved else {
                        return XCTFail("\(route) HTTP \(status): expected the saved copy, got \(withSaved)")
                    }
                }
            }
        }
    }

    func testLedgerRouteSwitchedOffOrFolyncOffSendsNothing() async throws {
        for route in FolyncLedgerRoute.allCases {
            var off = Self.ledgerSettingsOn
            switch route {
            case .dividends: off.dividends = false
            case .tradeAnalysis: off.tradeAnalysis = false
            case .transactions: off.transactions = false
            }
            let switchedOff = try makeLedgerHarness(supplemental: off)
            switchedOff.respond { _ in (200, Self.ledgerJSON(route), nil) }
            let disabled = await Self.ledger(route, switchedOff)
            XCTAssertEqual(disabled, .disabled, "\(route)")
            XCTAssertTrue(switchedOff.stub.requests.isEmpty, "\(route): no request, not even for capabilities")

            let folyncOff = try makeLedgerHarness(folyncEnabled: false)
            let disconnected = await Self.ledger(route, folyncOff)
            XCTAssertEqual(disconnected, .disabled)
            XCTAssertTrue(folyncOff.stub.requests.isEmpty)

            // Switching a route off also hides a page one still in the reuse window.
            let kept = try makeLedgerHarness()
            kept.respond { _ in (200, Self.ledgerJSON(route), nil) }
            guard case .folync = await Self.ledger(route, kept) else { return XCTFail("\(route)") }
            var stored = kept.settingsStore.load()
            stored.supplemental = off
            kept.settingsStore.save(stored)
            let afterSwitchingOff = await Self.ledger(route, kept)
            XCTAssertEqual(afterSwitchingOff, .disabled)
        }
    }

    func testLedgerCapabilityAbsentUnsupportedOrNotReadyIsUnavailable() async throws {
        for route in FolyncLedgerRoute.allCases {
            let key = route.rawValue
            for capabilities in [
                Self.ledgerCapabilitiesJSON(absent: [key]),
                Self.ledgerCapabilitiesJSON(unsupported: [key]),
                Self.ledgerCapabilitiesJSON(notReady: [key]),
                nil
            ] {
                let harness = try makeLedgerHarness(capabilities: capabilities)
                harness.respond { _ in (200, Self.ledgerJSON(route), nil) }
                let result = await Self.ledger(route, harness)
                XCTAssertEqual(result, .unavailable, "\(route)")
                XCTAssertTrue(harness.ledgerRequests.isEmpty, "\(route): no ledger request without a usable capability")
            }
        }
    }

    func testLedgerRejectedTokenOrRateLimitStartsTheSharedBackoff() async throws {
        for (status, retryAfter) in [(401, nil), (429, "120")] as [(Int, String?)] {
            let harness = try makeLedgerHarness()
            harness.stub.handler = { request in
                if request.url?.path == "/api/client/v2/capabilities" {
                    return Self.httpResponse(request, status: 200, body: Self.ledgerCapabilitiesJSON())
                }
                var headers = ["Content-Type": "application/json"]
                headers["Retry-After"] = retryAfter
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                        Data("{}".utf8))
            }

            let refused = await Self.ledger(.transactions, harness)
            XCTAssertEqual(refused, .unavailable, "HTTP \(status)")
            let backingOff = await harness.coordinator.isBackingOff()
            XCTAssertTrue(backingOff, "HTTP \(status) starts the backoff every Folync request shares")

            let during = await Self.ledger(.dividends, harness, forceRefresh: true)
            XCTAssertEqual(during, .unavailable)
            XCTAssertEqual(harness.ledgerRequests.count, 1, "HTTP \(status): nothing is sent while backing off")
        }
    }

    func testLedgerProviderPolicyOffSendsNoRequest() async throws {
        for route in FolyncLedgerRoute.allCases {
            // Saved capabilities and a saved page one, so the request itself is reached.
            let harness = try makeLedgerHarness()
            harness.respond { _ in (200, Self.ledgerJSON(route), nil) }
            _ = await Self.ledger(route, harness)
            let sentBefore = harness.stub.requests.count
            let refused = FolyncSupplementalCoordinator(
                settingsStore: harness.settingsStore,
                cache: FolyncSupplementalCache(directory: harness.cacheDirectory),
                session: Self.stubSession(),
                providerPolicy: StockbarProviderAccessPolicy(liveRequestsAllowed: false),
                tokenProvider: { "test-token" }
            )

            let result: LedgerOutcome = switch route {
            case .dividends: Self.outcome(await refused.routeDividends()) { $0.events.map(\.eventId) }
            case .tradeAnalysis: Self.outcome(await refused.routeTradeAnalysis()) { $0.lots.map(\.id) }
            case .transactions: Self.outcome(await refused.routeTransactions()) { $0.transactions.map(\.id) }
            }

            guard case .folync(.stale, .firstPage, _, _) = result else {
                return XCTFail("\(route): a refused request shows the saved copy, got \(result)")
            }
            XCTAssertEqual(harness.stub.requests.count, sentBefore, "\(route): the provider policy refuses before anything is sent")
        }
    }

    func testLedgerInvalidScopeSendsNoRequest() async throws {
        for scopeID in ["a/b", "..", ""] {
            let harness = try makeLedgerHarness(scopeID: scopeID)
            harness.respond { _ in (200, Self.ledgerJSON(.dividends), nil) }
            let result = await Self.ledger(.dividends, harness)
            XCTAssertEqual(result, .unavailable, scopeID)
            XCTAssertTrue(harness.ledgerRequests.isEmpty, scopeID)
        }
    }

    func testLedgerSavedCopiesAreKeptApartByRouteScopeAndQuery() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { request in
            let route = FolyncLedgerRoute.allCases.first { request.url?.path.hasSuffix($0.pathComponent) == true }!
            let scope = request.url!.pathComponents[5]
            let rowID = "\(scope)-\(Self.queryValue(request, "status") ?? "any")"
            return (200, Self.ledgerJSON(route, scopeID: scope, rowID: rowID), nil)
        }
        let coordinator = harness.coordinator
        _ = await coordinator.routeDividends(FolyncDividendsQuery(status: .received))
        _ = await coordinator.routeDividends(FolyncDividendsQuery(status: .upcoming))
        XCTAssertEqual(harness.ledgerRequests.count, 2, "Another filter is another request")

        harness.respond { _ in throw URLError(.notConnectedToInternet) }
        let received = Self.outcome(await coordinator.routeDividends(FolyncDividendsQuery(status: .received), forceRefresh: true)) {
            $0.events.map(\.eventId)
        }
        let upcoming = Self.outcome(await coordinator.routeDividends(FolyncDividendsQuery(status: .upcoming), forceRefresh: true)) {
            $0.events.map(\.eventId)
        }
        XCTAssertEqual(received, .folync(.stale, .firstPage, rows: ["div-all-received", "div-all-receivedb"], next: nil))
        XCTAssertEqual(upcoming, .folync(.stale, .firstPage, rows: ["div-all-upcoming", "div-all-upcomingb"], next: nil))
        let otherRoute = await Self.ledger(.transactions, harness)
        XCTAssertEqual(otherRoute, .unreachable, "Dividends saved for this scope are never shown as transactions")
        let unfiltered = await Self.ledger(.dividends, harness)
        XCTAssertEqual(unfiltered, .unreachable, "A filtered copy is never shown for another filter")

        var settings = harness.settingsStore.load()
        settings.scopeID = "pf_two"
        harness.settingsStore.save(settings)
        let otherScope = Self.outcome(await coordinator.routeDividends(FolyncDividendsQuery(status: .received))) {
            $0.events.map(\.eventId)
        }
        XCTAssertEqual(otherScope, .unreachable, "Another portfolio's rows are never shown, saved or reused")
        XCTAssertEqual(harness.ledgerRequests.last?.url?.path, "/api/client/v2/scopes/pf_two/dividends")
    }

    func testLedgerLoadMoreAsksForTheNextPageAndKeepsItNowhere() async throws {
        for route in FolyncLedgerRoute.allCases {
            let harness = try makeLedgerHarness()
            harness.respond { request in
                if Self.queryValue(request, "cursor") == "cursor-2" {
                    return (200, Self.ledgerJSON(route, rowID: "2"), nil)
                }
                return (200, Self.ledgerJSON(route, hasMore: true, nextCursor: "cursor-2"), "W/\"one\"")
            }
            let first = await Self.ledger(route, harness)
            let continuation = try XCTUnwrap(first.continuation, "\(route)")
            XCTAssertEqual(continuation, FolyncLedgerContinuation(cursor: "cursor-2", collectionRevision: Self.ledgerRevision("a")))

            let second = await Self.ledger(route, harness, after: continuation)
            guard case .folync(.current, .nextPage, let rows, nil) = second else { return XCTFail("\(route): \(second)") }
            XCTAssertEqual(rows.first, "\(Self.rowPrefix(route))-2")
            XCTAssertNil(harness.ledgerRequests.last?.value(forHTTPHeaderField: "If-None-Match"))

            _ = await Self.ledger(route, harness, after: continuation)
            XCTAssertEqual(harness.ledgerRequests.count, 3, "\(route): load more is explicit, so it is never answered from the reuse window")
            let reusedFirst = await Self.ledger(route, harness)
            XCTAssertEqual(reusedFirst, first, "\(route): page one is still the kept answer, not the later page")
            XCTAssertEqual(harness.ledgerRequests.count, 3)

            harness.respond { _ in throw URLError(.notConnectedToInternet) }
            guard case .folync(.stale, .firstPage, let savedRows, _) = await Self.ledger(route, harness, forceRefresh: true) else {
                return XCTFail("\(route)")
            }
            XCTAssertEqual(savedRows.first, "\(Self.rowPrefix(route))-1", "\(route): only page one is saved")
            let laterOffline = await Self.ledger(route, harness, after: continuation)
            XCTAssertEqual(laterOffline, .unreachable, "\(route): a failed later page is not replaced by page one")
        }
    }

    /// Serves page one (with "cursor-2"), then answers page two with `pageTwo`,
    /// then page one again with fresh rows.
    private func assertPagingRestarts(
        _ description: String,
        pageTwo: @escaping @Sendable (FolyncLedgerRoute) -> (status: Int, body: String, etag: String?)
    ) async throws {
        for route in FolyncLedgerRoute.allCases {
            let harness = try makeLedgerHarness()
            let pageOneServed = LockedBox(0)
            harness.respond { request in
                if Self.queryValue(request, "cursor") == "cursor-2" { return pageTwo(route) }
                pageOneServed.value += 1
                let rowID = pageOneServed.value == 1 ? "1" : "fresh"
                let revision = Self.ledgerRevision(pageOneServed.value == 1 ? "a" : "b")
                return (200, Self.ledgerJSON(route, rowID: rowID, revision: revision, hasMore: true, nextCursor: "cursor-2"), nil)
            }
            let pageOne = await Self.ledger(route, harness)
            let continuation = try XCTUnwrap(pageOne.continuation)

            let restarted = await Self.ledger(route, harness, after: continuation)

            guard case .folync(.current, .restarted, let rows, _) = restarted else {
                return XCTFail("\(description), \(route): \(restarted)")
            }
            XCTAssertEqual(rows.first, "\(Self.rowPrefix(route))-fresh", "\(description), \(route)")
            XCTAssertEqual(harness.ledgerRequests.map { Self.queryValue($0, "cursor") }, [nil, "cursor-2", nil])
            let reused = await Self.ledger(route, harness)
            guard case .folync(_, .firstPage, let reusedRows, _) = reused else { return XCTFail("\(route)") }
            XCTAssertEqual(reusedRows, rows, "\(description), \(route): the fresh page one is kept for reuse")
            XCTAssertEqual(harness.ledgerRequests.count, 3)
        }
    }

    func testLedgerPageInvalidatedRestartsFromPageOne() async throws {
        try await assertPagingRestarts("409") { _ in
            (409, #"{"statusCode":409,"statusMessage":"Start again","data":{"code":"page_invalidated","retryable":true}}"#, nil)
        }
    }

    func testLedgerRefusedCursorRestartsFromPageOne() async throws {
        try await assertPagingRestarts("invalid_cursor") { _ in
            (400, #"{"statusCode":400,"statusMessage":"Cursor refused","data":{"code":"invalid_cursor","retryable":false}}"#, nil)
        }
        try await assertPagingRestarts("cursor field error") { _ in
            (400, #"{"statusCode":400,"statusMessage":"Cursor refused","data":{"code":"invalid_request","retryable":false,"fieldErrors":{"cursor":["unknown cursor"]}}}"#, nil)
        }
    }

    func testLedgerOtherBadRequestOnALaterPageDoesNotRestart() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { request in
            if Self.queryValue(request, "cursor") == "cursor-2" {
                return (400, #"{"statusCode":400,"statusMessage":"Limit refused","data":{"code":"invalid_request","retryable":false,"fieldErrors":{"limit":["too large"]}}}"#, nil)
            }
            return (200, Self.ledgerJSON(.dividends, hasMore: true, nextCursor: "cursor-2"), nil)
        }
        let pageOne = await Self.ledger(.dividends, harness)
        let continuation = try XCTUnwrap(pageOne.continuation)
        let result = await Self.ledger(.dividends, harness, after: continuation)
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(harness.ledgerRequests.count, 2)
    }

    func testLedgerChangedCollectionRevisionRestartsFromPageOne() async throws {
        try await assertPagingRestarts("changed revision") { route in
            (200, Self.ledgerJSON(route, rowID: "2", revision: Self.ledgerRevision("c")), "W/\"changed\"")
        }
    }

    func testLedgerPolicyReusesPageOneForFiveMinutes() async throws {
        for route in FolyncLedgerRoute.allCases {
            let harness = try makeLedgerHarness()
            harness.respond { _ in (200, Self.ledgerJSON(route), "W/\"one\"") }

            let first = await Self.ledger(route, harness)
            harness.advance(299)
            let reused = await Self.ledger(route, harness)
            XCTAssertEqual(reused, first)
            XCTAssertEqual(harness.ledgerRequests.count, 1, "\(route): no request inside five minutes")

            harness.advance(2)
            _ = await Self.ledger(route, harness)
            XCTAssertEqual(harness.ledgerRequests.count, 2, "\(route): asked again after five minutes")

            _ = await Self.ledger(route, harness, forceRefresh: true)
            XCTAssertEqual(harness.ledgerRequests.count, 3, "\(route): an explicit refresh skips the reuse")
        }
    }

    func testLedgerPolicyDoesNotReuseAFailedOrStaleAnswer() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { _ in (200, Self.ledgerJSON(.dividends), nil) }
        _ = await Self.ledger(.dividends, harness)
        harness.advance(FolyncLedgerFetchPolicy.defaultReuseInterval + 1)
        harness.respond { _ in (503, "{}", nil) }
        _ = await Self.ledger(.dividends, harness, forceRefresh: true)
        harness.respond { _ in (200, Self.ledgerJSON(.dividends, rowID: "2"), nil) }

        let next = await Self.ledger(.dividends, harness)

        guard case .folync(.current, .firstPage, let rows, _) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(rows.first, "div-2", "A stale copy shown during an outage is not kept for reuse")
        XCTAssertEqual(harness.ledgerRequests.count, 3)
    }

    func testLedgerRequestsNeverOverlapAcrossRoutes() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { request in
            let route = FolyncLedgerRoute.allCases.first { request.url?.path.hasSuffix($0.pathComponent) == true }!
            return (200, Self.ledgerJSON(route), nil)
        }
        _ = await harness.coordinator.capabilitiesForCurrentSettings()
        harness.stub.delay = 0.15

        async let dividends = Self.ledger(.dividends, harness)
        async let trades = Self.ledger(.tradeAnalysis, harness)
        async let transactions = Self.ledger(.transactions, harness)
        async let filtered = Self.outcome(
            await harness.coordinator.routeDividends(FolyncDividendsQuery(status: .upcoming))
        ) { $0.events.map(\.eventId) }
        let results = await [dividends, trades, transactions, filtered]

        XCTAssertEqual(harness.ledgerRequests.count, 4)
        XCTAssertEqual(harness.stub.mostInFlight, 1, "Ledger requests take turns, never two at once")
        for result in results {
            guard case .folync(.current, .firstPage, _, _) = result else { return XCTFail("\(result)") }
        }
    }

    func testLedgerIdenticalConcurrentCallsShareOneRequest() async throws {
        let harness = try makeLedgerHarness()
        harness.respond { _ in (200, Self.ledgerJSON(.transactions), nil) }
        _ = await harness.coordinator.capabilitiesForCurrentSettings()
        harness.stub.delay = 0.2

        // Refreshes, so the reuse window cannot stand in for sharing.
        async let first = Self.ledger(.transactions, harness, forceRefresh: true)
        async let second = Self.ledger(.transactions, harness, forceRefresh: true)
        async let third = Self.ledger(.transactions, harness, forceRefresh: true)
        let results = await [first, second, third]

        XCTAssertEqual(harness.ledgerRequests.count, 1, "Callers asking for the same thing share one request")
        XCTAssertEqual(Set(results.map { "\($0)" }).count, 1)
    }

    /// Waits, for at most five seconds, until `condition` holds.
    private static func waitForLedgerPolicy(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The fetch policy did not reach the expected state in time", file: file, line: line)
    }

    func testLedgerFetchPolicyRefreshDoesNotJoinARequestThatMayReuse() async throws {
        let policy = FolyncLedgerFetchPolicy()
        let key = FolyncLedgerFetchPolicy.Key(
            route: .transactions, endpoint: "https://folync.test", scopeID: "all", query: "", cursor: nil
        )
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let ran = LockedBox<[String]>([])
        let held = Task {
            await policy.perform(key) {
                ran.value.append("held")
                for await _ in release { break }
                return .init(result: "held", firstPageToKeep: nil)
            }
        }
        // Each step waits for the policy to have registered the caller before
        // the next begins. Fixed sleeps let the two later callers arrive in
        // either order on a busy Mac, and the joiner then joined the refresh.
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 1 && ran.value == ["held"] }
        let joining = Task {
            await policy.perform(key) {
                ran.value.append("joining")
                return .init(result: "joining", firstPageToKeep: nil)
            }
        }
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 2 }
        let refreshing = Task {
            await policy.perform(key, forceRefresh: true) {
                ran.value.append("refreshing")
                return .init(result: "refreshing", firstPageToKeep: nil)
            }
        }
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 3 }
        releaser.yield()
        releaser.finish()

        let heldResult = await held.value
        let joiningResult = await joining.value
        let refreshingResult = await refreshing.value
        XCTAssertEqual(heldResult, "held")
        XCTAssertEqual(joiningResult, "held", "The same request under way is shared")
        XCTAssertEqual(refreshingResult, "refreshing", "A refresh asks again, in its own turn")
        XCTAssertEqual(ran.value, ["held", "refreshing"])
    }

    func testLedgerFetchPolicyRunsOperationsOneAtATimeInOrder() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_780_000_000))
        let policy = FolyncLedgerFetchPolicy(now: { clock.value })
        let log = LockedBox<[String]>([])
        func key(_ query: String) -> FolyncLedgerFetchPolicy.Key {
            .init(route: .dividends, endpoint: "https://folync.test", scopeID: "all", query: query, cursor: nil)
        }
        func run(_ name: String) async -> String? {
            await policy.perform(key(name)) {
                log.value.append("start \(name)")
                try? await Task.sleep(nanoseconds: 50_000_000)
                log.value.append("end \(name)")
                return .init(result: name, firstPageToKeep: name)
            }
        }

        async let first = run("a")
        async let second = run("b")
        let names = await [first, second]

        XCTAssertEqual(names, ["a", "b"])
        let entries = log.value
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries == ["start a", "end a", "start b", "end b"] || entries == ["start b", "end b", "start a", "end a"],
                      "Operations never interleave: \(entries)")

        let reused: String? = await policy.perform(key("a")) { .init(result: "not reused", firstPageToKeep: nil) }
        XCTAssertEqual(reused, "a")
        clock.value = clock.value.addingTimeInterval(FolyncLedgerFetchPolicy.defaultReuseInterval)
        let expired: String? = await policy.perform(key("a")) { .init(result: "fresh", firstPageToKeep: nil) }
        XCTAssertEqual(expired, "fresh")
    }

    func testLedgerFetchPolicyDropsAQueuedRequestOnceItsCallersAreCancelled() async throws {
        let policy = FolyncLedgerFetchPolicy()
        func key(_ query: String) -> FolyncLedgerFetchPolicy.Key {
            .init(route: .transactions, endpoint: "https://folync.test", scopeID: "all", query: query, cursor: nil)
        }
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let ran = LockedBox<[String]>([])
        func ask(_ name: String, answering answer: String? = nil) -> Task<String?, Never> {
            Task {
                await policy.perform(key(name)) {
                    ran.value.append(answer ?? name)
                    return .init(result: answer ?? name, firstPageToKeep: nil)
                }
            }
        }
        let held = Task {
            await policy.perform(key("held")) {
                ran.value.append("held")
                for await _ in release { break }
                return .init(result: "held", firstPageToKeep: nil)
            }
        }
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 1 && ran.value == ["held"] }
        // Behind it: a request nobody will want, one two callers share, and
        // one that is wanted. Each is registered before the next is started.
        let superseded = ask("superseded")
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 2 }
        let leaving = ask("shared")
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 3 }
        let staying = ask("shared", answering: "asked twice")
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 4 }
        let wanted = ask("wanted")
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 5 }
        superseded.cancel()
        leaving.cancel()
        // Both cancellations have been counted out before the turn passes on.
        await Self.waitForLedgerPolicy { await policy.waitingCallerCount == 3 }
        releaser.yield()
        releaser.finish()

        let heldResult = await held.value
        let supersededResult = await superseded.value
        let leavingResult = await leaving.value
        let stayingResult = await staying.value
        let wantedResult = await wanted.value
        XCTAssertEqual(heldResult, "held")
        XCTAssertNil(supersededResult, "Nobody waits for it any more, so it is never asked for")
        XCTAssertEqual(leavingResult, "shared", "A cancelled caller still gets an answer made for someone else")
        XCTAssertEqual(stayingResult, "shared", "A request one caller still waits for is made")
        XCTAssertEqual(wantedResult, "wanted")
        XCTAssertEqual(ran.value, ["held", "shared", "wanted"])
    }

    func testLedgerFetchPolicyMakesNoRequestForACallerAlreadyCancelled() async {
        let policy = FolyncLedgerFetchPolicy()
        let key = FolyncLedgerFetchPolicy.Key(
            route: .dividends, endpoint: "https://folync.test", scopeID: "all", query: "", cursor: nil
        )
        let ran = LockedBox(false)
        let cancelled = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await policy.perform(key) {
                ran.value = true
                return .init(result: "asked", firstPageToKeep: nil)
            }
        }
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertFalse(ran.value)
    }

    func testLedgerFetchPolicyForgetsPagesPastTheReuseWindow() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_780_000_000))
        let policy = FolyncLedgerFetchPolicy(now: { clock.value })
        func keep(_ name: String) async {
            let key = FolyncLedgerFetchPolicy.Key(
                route: .transactions, endpoint: "https://folync.test", scopeID: "all", query: name, cursor: nil
            )
            let _: String? = await policy.perform(key) { .init(result: name, firstPageToKeep: name) }
        }
        for name in ["a", "b", "c"] { await keep(name) }
        let held = await policy.keptPageCount
        XCTAssertEqual(held, 3)

        clock.value = clock.value.addingTimeInterval(FolyncLedgerFetchPolicy.defaultReuseInterval)
        await keep("d")
        let heldLater = await policy.keptPageCount
        XCTAssertEqual(heldLater, 1, "Pages that can no longer be reused are dropped when a new one is kept")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class FolyncHTTPStub: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var storedOffline = false
    private var storedHandler: Handler?
    private var storedDelay: TimeInterval = 0
    private var storedInFlight = 0
    private var storedMostInFlight = 0

    /// When above zero, each answer is sent this long after the request
    /// starts, without blocking the loading thread, so requests sent together
    /// are in flight together.
    var delay: TimeInterval {
        get { lock.withLock { storedDelay } }
        set { lock.withLock { storedDelay = newValue } }
    }

    /// The most delayed requests that were in flight at once.
    var mostInFlight: Int {
        lock.withLock { storedMostInFlight }
    }

    func began() {
        lock.withLock {
            storedInFlight += 1
            storedMostInFlight = max(storedMostInFlight, storedInFlight)
        }
    }

    func ended() {
        lock.withLock { storedInFlight -= 1 }
    }

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
        let stub = Self.stub
        guard stub.delay > 0 else { return finishLoading(with: stub) }
        stub.began()
        DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay) { [self] in
            stub.ended()
            finishLoading(with: stub)
        }
    }

    private func finishLoading(with stub: FolyncHTTPStub) {
        do {
            let (response, data) = try stub.respond(to: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Trades page

/// Stands in for the coordinator's trade-analysis routes. Records every call;
/// answers from queues, and can hold a call until the test lets it go.
private actor TradesRouterStandIn: StockbarTradeAnalysisRouting {
    struct Call: Equatable {
        let query: FolyncTradeAnalysisQuery
        let forceRefresh: Bool
        let cursor: String?
    }

    private(set) var calls: [Call] = []
    private var firstAnswers: [FolyncRoutedTradeAnalysisResult] = []
    private var moreAnswers: [FolyncRoutedTradeAnalysisResult] = []
    private var holdsNext = false
    private var held: CheckedContinuation<FolyncRoutedTradeAnalysisResult, Never>?

    func answerFirst(_ results: FolyncRoutedTradeAnalysisResult...) { firstAnswers += results }
    func answerMore(_ results: FolyncRoutedTradeAnalysisResult...) { moreAnswers += results }
    func holdNextCall() { holdsNext = true }
    var isHolding: Bool { held != nil }

    /// Lets the held call return `result`.
    func release(with result: FolyncRoutedTradeAnalysisResult) {
        held?.resume(returning: result)
        held = nil
    }

    func routeTradeAnalysis(_ query: FolyncTradeAnalysisQuery, forceRefresh: Bool) async -> FolyncRoutedTradeAnalysisResult {
        calls.append(Call(query: query, forceRefresh: forceRefresh, cursor: nil))
        if holdsNext {
            holdsNext = false
            return await withCheckedContinuation { held = $0 }
        }
        return firstAnswers.isEmpty ? .unavailable : firstAnswers.removeFirst()
    }

    func loadMoreTradeAnalysis(
        _ query: FolyncTradeAnalysisQuery,
        after continuation: FolyncLedgerContinuation
    ) async -> FolyncRoutedTradeAnalysisResult {
        calls.append(Call(query: query, forceRefresh: true, cursor: continuation.cursor))
        return moreAnswers.isEmpty ? .unavailable : moreAnswers.removeFirst()
    }
}

/// The debounce durations the Trades view model asked to wait.
/// A hold-back that ends when the test says so. A waiter whose task is
/// cancelled stops waiting at once, as `Task.sleep` does.
private actor DebounceGate {
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isOpen = false

    func wait() async throws {
        if isOpen { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func open() {
        isOpen = true
        waiting.values.forEach { $0.resume() }
        waiting.removeAll()
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor DebounceRecorder {
    private(set) var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }
}

@MainActor
final class StockbarTradesPageTests: XCTestCase {
    /// Waits, for at most five seconds, until `condition` holds.
    private static func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: @Sendable () async -> Bool) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The expected state was not reached in time", file: file, line: line)
    }

    private typealias Model = StockbarTradesViewModel
    private typealias Text = StockbarTradesText
    private let britain = Locale(identifier: "en_GB")

    // MARK: Fixtures (invented figures)

    private static let identity = """
    {"assetId":"asset_a","canonicalTicker":"NVDA","displayTicker":"NVDA","quoteSymbol":"NVDA","aliases":[],"isin":null}
    """

    private static let freshness = """
    {"responseGeneratedAt":"2026-03-02T09:00:00.000Z","asOf":"2026-03-02","status":"current","reasonCodes":[],
     "sources":{"snapshots":{"asOfDate":"2026-03-02","status":"clean","generation":7,"dirtySince":null,
     "rebuildStartedAt":null,"failedAt":null,"completedAt":"2026-03-02T08:59:00.000Z"},
     "prices":{"asOfDate":"2026-03-02","ageSeconds":60,"missingCount":0},
     "fx":{"asOfDate":"2026-03-02","ageSeconds":60,"missingCount":0},
     "provider":{"lastSuccessfulSyncAt":"2026-03-02T08:58:00.000Z","ageSeconds":120,"requiredCount":3,"coveredCount":3,"missingCount":0}}}
    """

    private static func number(_ value: Double?) -> String {
        value.map { "\($0)" } ?? "null"
    }

    private static func lotJSON(
        id: String, ticker: String = "NVDA", status: String = "Open", openDate: String = "2025-02-11",
        cost: Double = 7420, gain: Double? = 5540.35, returnPct: Double? = 74.66, alpha: Double? = 53.4,
        index: String = "S&P 500", days: Int = 646, valuationQuality: String = "complete"
    ) -> String {
        let identity = identity.replacingOccurrences(of: "NVDA", with: ticker)
        let comparison = alpha == nil
            ? """
              {"quality":"unavailable","reasonCodes":["missing_benchmark_price"],"requestedStartDate":"\(openDate)",
               "requestedEndDate":null,"startPriceDate":null,"endPriceDate":null,"holdingPriceDate":null,
               "awaitingHoldingClose":false,"awaitedHoldingCloseDate":null,"holdingPriceFinal":false}
              """
            : "null"
        return """
        {"id":"\(id)","ticker":"\(ticker)","side":"Long","openDate":"\(openDate)","price":10,"currency":"GBP",
         "shares":10,"openedShares":10,"costBasis":\(cost),"totalGain":\(number(gain)),"totalReturnPct":\(number(returnPct)),
         "comparisonReturnPct":null,"alphaPct":\(number(alpha)),"benchmarkId":"b","benchmarkName":"\(index)",
         "benchmarkReturnPct":null,"benchmarkComparison":\(comparison),"holdingDays":\(days),"status":"\(status)",
         "valuation":{"value":1,"currency":"GBP","quality":"\(valuationQuality)","reasonCodes":[],"asOfDate":null},
         "portfolioId":"pf","assetId":"asset_a","identity":\(identity)}
        """
    }

    private static func response(
        lots: [String], cursor: String? = nil, revision: String = "rev-a", quality: String = "complete",
        method: String = "\"average\"", activity: String = """
        {"period":"2026","fees":48.2,"feesPctOfAvgValue":0.06,"buyCount":7,"sellCount":3,"tradeCount":10,
         "buyValue":6840,"sellValue":2410,"tradeValue":9250,"turnoverPct":9.4}
        """
    ) throws -> FolyncTradeAnalysisResponse {
        let next = cursor.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schemaVersion":2,"sourceRevision":"src","generatedAt":"2026-03-02T09:00:00.000Z",
         "scope":{"id":"all","name":"Example","kind":"aggregate","currency":"GBP"},"currency":"GBP",
         "quality":"\(quality)","reasonCodes":\(quality == "complete" ? "[]" : "[\"prices_stale\"]"),"freshness":\(freshness),
         "costBasisMethod":\(method),
         "stats":{"attributionLots":14,"closedAttributionLots":5,"winRatePct":64.3,"wins":9,"losses":5,
          "winRateVsSp500Pct":57.1,"winsVsSp500":8,"lossesVsSp500":6,"comparisonScope":"configured_benchmarks",
          "benchmarkWinRatePct":57.1,"benchmarkWins":8,"benchmarkLosses":6,"unavailableBenchmarkComparisons":0,
          "openLotComparisonDate":"2026-03-01","benchmarkBreakdown":[],"totalTradeGain":1611.86,"unavailableAttributionLots":0},
         "activity":[\(activity)],
         "lots":[\(lots.joined(separator: ","))],
         "page":{"limit":200,"hasMore":\(cursor != nil),"nextCursor":\(next),"collectionRevision":"\(revision)"}}
        """
        return try JSONDecoder().decode(FolyncTradeAnalysisResponse.self, from: Data(json.utf8))
    }

    private static func lot(_ json: String) throws -> FolyncTradeLot {
        try JSONDecoder().decode(FolyncTradeLot.self, from: Data(json.utf8))
    }

    private func makeModel(_ router: TradesRouterStandIn, folync: Bool = true,
                           debounce: Duration = .milliseconds(30)) -> Model {
        Model(router: router, isFolyncPortfolio: folync, sleep: { _ in try await Task.sleep(for: debounce) })
    }

    /// Waits, briefly, for the model's tasks to reach `condition`.
    private func settle(_ condition: @MainActor () async -> Bool = { false }, timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: States

    func testANonFolyncPortfolioExplainsItselfAndAsksNothing() async {
        let router = TradesRouterStandIn()
        let model = makeModel(router, folync: false)

        model.activate()
        model.refresh()
        model.select(.closed)
        model.loadMore()
        await settle(timeout: .milliseconds(150))

        XCTAssertEqual(model.state, .needsFolync)
        let calls = await router.calls
        XCTAssertTrue(calls.isEmpty, "no request for a portfolio that is not Folync's")
    }

    func testNothingIsAskedUntilThePageIsSelected() async {
        let router = TradesRouterStandIn()
        let model = makeModel(router)

        model.refresh()
        model.select(.open)
        model.loadMore()
        await settle(timeout: .milliseconds(150))

        XCTAssertEqual(model.state, .idle)
        let calls = await router.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testEachAnswerGivesItsState() async throws {
        let page = try Self.response(lots: [Self.lotJSON(id: "lot-1")])
        let cases: [(FolyncRoutedTradeAnalysisResult, Model.State)] = [
            (.folync(page, status: .current, paging: .firstPage), .loaded),
            (.folync(page, status: .partial, paging: .firstPage), .loaded),
            (.folync(page, status: .stale, paging: .firstPage), .stale),
            (.unreachable, .unreachable),
            (.unavailable, .unavailable),
            (.disabled, .disabled)
        ]
        for (result, expected) in cases {
            let router = TradesRouterStandIn()
            await router.answerFirst(result)
            let model = makeModel(router)
            model.activate()
            await settle { model.state != .loading }

            XCTAssertEqual(model.state, expected, "\(expected)")
            switch expected {
            case .loaded, .stale:
                XCTAssertEqual(model.lots.map(\.id), ["lot-1"])
            default:
                XCTAssertTrue(model.lots.isEmpty)
                XCTAssertNil(model.answer)
            }
            if expected == .stale {
                XCTAssertEqual(model.savedAt, FolyncSupplementalDateParser.instant("2026-03-02T09:00:00.000Z"),
                               "the saved copy's time is shown")
            } else {
                XCTAssertNil(model.savedAt)
            }
        }
    }

    func testTheFirstLoadShowsLoading() async throws {
        let router = TradesRouterStandIn()
        await router.holdNextCall()
        let model = makeModel(router)

        model.activate()
        await settle { await router.isHolding }
        XCTAssertEqual(model.state, .loading)

        await router.release(with: .folync(try Self.response(lots: []), status: .current, paging: .firstPage))
        await settle { model.state != .loading }
        XCTAssertEqual(model.state, .loaded)
    }

    // MARK: The load rule

    func testOpeningAsksOnceAndLeavesReuseToThePolicy() async throws {
        let router = TradesRouterStandIn()
        let page = try Self.response(lots: [Self.lotJSON(id: "lot-1")])
        await router.answerFirst(.folync(page, status: .current, paging: .firstPage),
                                 .folync(page, status: .current, paging: .firstPage))
        let model = makeModel(router)

        model.activate()
        model.activate()
        await settle { model.state == .loaded }
        model.activate()
        await settle(timeout: .milliseconds(100))
        var calls = await router.calls
        XCTAssertEqual(calls, [.init(query: Model.query(for: .all), forceRefresh: false, cursor: nil)],
                       "one request on opening, none on a second activate")

        // Opened again: asked without forcing, so the fetch policy's five-minute reuse applies.
        model.deactivate()
        model.activate()
        await settle { await router.calls.count == 2 }
        calls = await router.calls
        XCTAssertEqual(calls.last, .init(query: Model.query(for: .all), forceRefresh: false, cursor: nil))
    }

    func testTheRefreshControlForcesARequest() async throws {
        let router = TradesRouterStandIn()
        let page = try Self.response(lots: [Self.lotJSON(id: "lot-1")])
        await router.answerFirst(.folync(page, status: .current, paging: .firstPage),
                                 .folync(page, status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate()
        await settle { model.state == .loaded }

        model.refresh()
        await settle { await router.calls.count == 2 }
        await settle { !model.isRefreshing }

        let calls = await router.calls
        XCTAssertEqual(calls.map(\.forceRefresh), [false, true])
        XCTAssertEqual(model.state, .loaded)
    }

    func testLoadMoreAppendsAndARestartDropsTheRowsGathered() async throws {
        let router = TradesRouterStandIn()
        let first = try Self.response(lots: [Self.lotJSON(id: "lot-1")], cursor: "c1")
        let second = try Self.response(lots: [Self.lotJSON(id: "lot-2")], cursor: "c2")
        let restarted = try Self.response(lots: [Self.lotJSON(id: "lot-9")], cursor: "c9", revision: "rev-b")
        await router.answerFirst(.folync(first, status: .current, paging: .firstPage))
        await router.answerMore(.folync(second, status: .current, paging: .nextPage),
                                .unreachable,
                                .folync(restarted, status: .current, paging: .restarted))
        let model = makeModel(router)
        model.activate()
        await settle { model.state == .loaded }
        XCTAssertTrue(model.hasMore)

        model.loadMore()
        await settle { model.lots.count == 2 }
        XCTAssertEqual(model.lots.map(\.id), ["lot-1", "lot-2"])

        model.loadMore()
        await settle { model.loadMoreFailed }
        XCTAssertEqual(model.lots.map(\.id), ["lot-1", "lot-2"], "a failed load more keeps the rows")
        XCTAssertEqual(model.state, .loaded)

        model.loadMore()
        await settle { model.lots.first?.id == "lot-9" }
        XCTAssertEqual(model.lots.map(\.id), ["lot-9"], "a restart drops the rows gathered")
        XCTAssertFalse(model.loadMoreFailed)

        let calls = await router.calls
        XCTAssertEqual(calls.map(\.cursor), [nil, "c1", "c2", "c2"])
        XCTAssertTrue(calls.allSatisfy { $0.query == Model.query(for: .all) })
    }

    func testNoLoadMoreWithoutAContinuation() async throws {
        let router = TradesRouterStandIn()
        await router.answerFirst(.folync(try Self.response(lots: [Self.lotJSON(id: "lot-1")]),
                                         status: .current, paging: .firstPage))
        let model = makeModel(router)
        model.activate()
        await settle { model.state == .loaded }

        model.loadMore()
        await settle(timeout: .milliseconds(100))
        let calls = await router.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testASupersededSwitchChangeIsCancelled() async throws {
        let router = TradesRouterStandIn()
        let all = try Self.response(lots: [Self.lotJSON(id: "lot-1")])
        let closed = try Self.response(lots: [Self.lotJSON(id: "lot-c", status: "Closed")])
        await router.answerFirst(.folync(all, status: .current, paging: .firstPage),
                                 .folync(closed, status: .current, paging: .firstPage))
        let asked = DebounceRecorder()
        let gate = DebounceGate()
        let model = Model(router: router, isFolyncPortfolio: true) { duration in
            await asked.record(duration)
            // The hold-back ends when the test opens the gate, not after a
            // real 400 ms, so a busy Mac cannot change what is seen.
            try await gate.wait()
        }
        model.activate()
        await settle { model.state == .loaded }

        model.select(.open)
        XCTAssertTrue(model.lots.isEmpty, "the old position's rows are not shown under the new one")
        await Self.waitUntil { await asked.durations.count == 1 }
        let whileWaiting = await router.calls.count
        XCTAssertEqual(whileWaiting, 1, "a switch change waits before asking")
        let durations = await asked.durations
        XCTAssertEqual(durations, [Model.filterDebounce])
        model.select(.closed)
        await Self.waitUntil { await asked.durations.count == 2 }
        await gate.open()
        await settle { model.lots.first?.id == "lot-c" }

        let calls = await router.calls
        XCTAssertEqual(calls.map(\.query.status), [.all, .closed], "the superseded Open query was never asked")
        XCTAssertEqual(model.filter, .closed)
        XCTAssertEqual(model.lots.map(\.id), ["lot-c"])
    }

    func testACancelledAnswerIsNeverApplied() async throws {
        // Closed while the first request is out: the coordinator answers a
        // cancelled caller `.unavailable`, which must not reach the page.
        let router = TradesRouterStandIn()
        await router.holdNextCall()
        let model = makeModel(router)
        model.activate()
        await settle { await router.isHolding }

        model.deactivate()
        await router.release(with: .unavailable)
        await settle(timeout: .milliseconds(100))
        XCTAssertEqual(model.state, .loading)
        XCTAssertNil(model.answer)

        // A request overtaken by a switch change is ignored too, whatever it says.
        let second = TradesRouterStandIn()
        await second.holdNextCall()
        let closed = try Self.response(lots: [Self.lotJSON(id: "lot-c", status: "Closed")])
        await second.answerFirst(.folync(closed, status: .current, paging: .firstPage))
        let switched = makeModel(second)
        switched.activate()
        await settle { await second.isHolding }
        switched.select(.closed)
        await settle { switched.state == .loaded }
        await second.release(with: .folync(try Self.response(lots: [Self.lotJSON(id: "lot-old")]),
                                           status: .current, paging: .firstPage))
        await settle(timeout: .milliseconds(100))
        XCTAssertEqual(switched.lots.map(\.id), ["lot-c"])
    }

    func testBecomingAFolyncPortfolioWhileOpenAsksOnce() async throws {
        let router = TradesRouterStandIn()
        await router.answerFirst(.folync(try Self.response(lots: []), status: .current, paging: .firstPage))
        let model = makeModel(router, folync: false)
        model.activate()
        XCTAssertEqual(model.state, .needsFolync)

        model.setFolyncPortfolio(true)
        await settle { model.state == .loaded }
        model.setFolyncPortfolio(false)
        XCTAssertEqual(model.state, .needsFolync)
        XCTAssertNil(model.answer)
        let calls = await router.calls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: Derived values

    func testTheQueryForEachSwitchPosition() {
        XCTAssertEqual(Model.query(for: .all).cacheKey, "status=all&limit=200")
        XCTAssertEqual(Model.query(for: .open).cacheKey, "status=open&limit=200")
        XCTAssertEqual(Model.query(for: .partial).cacheKey, "status=partial&limit=200")
        XCTAssertEqual(Model.query(for: .closed).cacheKey, "status=closed&limit=200")
        XCTAssertEqual(Model.Filter.allCases.map(\.title), ["All", "Open", "Partial", "Closed"],
                       "one position of the switch for each status Folync filters by")
    }

    func testTheWinRateCaptionComesFromTheCounts() {
        XCTAssertEqual(Text.winRateCaption(wins: 9, losses: 5), "9 of 14 trades made money")
        XCTAssertEqual(Text.winRateCaption(wins: 1, losses: 0), "1 of 1 trade made money")
        XCTAssertNil(Text.winRateCaption(wins: nil, losses: 5), "a missing count gives no caption")
        XCTAssertNil(Text.winRateCaption(wins: 3, losses: nil))
        XCTAssertNil(Text.winRateCaption(wins: 0, losses: 0), "nothing counted yet")
        XCTAssertEqual(Text.beatIndexCaption(wins: 8, losses: 6), "8 of 14, over the same days")
        XCTAssertNil(Text.beatIndexCaption(wins: nil, losses: 6))
        XCTAssertEqual(Text.wholePercent(64.3), "64%")
        XCTAssertEqual(Text.wholePercent(nil), "–", "unknown is a dash, never zero")
    }

    func testTheStatusPillForEachStatus() {
        XCTAssertEqual(Text.pill(.known(.open)), .init(title: "Open", kind: .open))
        XCTAssertEqual(Text.pill(.known(.partial)), .init(title: "Partial", kind: .partial))
        XCTAssertEqual(Text.pill(.known(.closed)), .init(title: "Closed", kind: .closed))
        XCTAssertEqual(Text.pill(.unknown("Reopened")), .init(title: "Reopened", kind: .other),
                       "a status this build does not know is shown as sent")
        XCTAssertEqual(Text.pill(FolyncOpenEnum(rawValue: "Partial")), .init(title: "Partial", kind: .partial))
    }

    func testHeldForTextAndDates() {
        XCTAssertEqual(Text.heldFor(days: 646).text, "646 d")
        XCTAssertEqual(Text.heldFor(days: 646).spoken, "646 days")
        XCTAssertEqual(Text.heldFor(days: 1).spoken, "1 day")
        XCTAssertEqual(Text.heldFor(days: 0).text, "0 d")
        XCTAssertEqual(Text.openedOn("2025-02-11", locale: britain), "11 Feb 2025")
        XCTAssertEqual(Text.openedOn("not a day", locale: britain), "not a day")
    }

    func testGainReturnAndComparisonCarrySignAndColour() {
        let gain = Text.signedAmount(5540.35, currency: "GBP")
        XCTAssertEqual(gain.text, "+£5,540.35")
        XCTAssertEqual(gain.tone, .gain)
        let loss = Text.signedAmount(-64.1, currency: "GBP")
        XCTAssertEqual(loss.text, "-£64.10")
        XCTAssertEqual(loss.tone, .loss)
        let nothing = Text.signedAmount(-0.001, currency: "GBP")
        XCTAssertEqual(nothing.text, "£0.00")
        XCTAssertEqual(nothing.tone, .neutral, "a figure that shows as zero is not red")
        XCTAssertEqual(Text.signedAmount(nil, currency: "GBP"), .unknown)

        XCTAssertEqual(Text.signedPercent(74.66).text, "+74.7%")
        XCTAssertEqual(Text.signedPercent(74.66).tone, .gain)
        XCTAssertEqual(Text.signedPercent(-2.94).text, "-2.9%")
        XCTAssertEqual(Text.signedPercent(-2.94).tone, .loss)
        XCTAssertEqual(Text.signedPercent(0.04).text, "0.0%")
        XCTAssertEqual(Text.signedPercent(0.04).tone, .neutral)
        XCTAssertEqual(Text.signedPercent(nil).text, "–")

        let ahead = Text.signedPoints(53.4, index: "S&P 500")
        XCTAssertEqual(ahead.text, "+53.4")
        XCTAssertEqual(ahead.tone, .gain)
        XCTAssertEqual(ahead.spoken, "53.4 points ahead of the S&P 500")
        let behind = Text.signedPoints(-7.8, index: "S&P 500")
        XCTAssertEqual(behind.text, "-7.8")
        XCTAssertEqual(behind.tone, .loss)
        XCTAssertEqual(behind.spoken, "7.8 points behind the S&P 500")

    }

    func testALotWithNoBenchmarkFigureShowsADashNotZero() throws {
        let none = Text.signedPoints(nil, index: "S&P 500")
        XCTAssertEqual(none.text, "–")
        XCTAssertEqual(none.tone, .neutral)
        XCTAssertEqual(none.spoken, "no comparison with the S&P 500")

        let lot = try Self.lot(Self.lotJSON(id: "lot-v", ticker: "VUSA", alpha: nil))
        XCTAssertEqual(StockbarTradesView.comparisonHelp(lot), "No comparison with the S&P 500: missing benchmark price")
    }

    func testTheCostYearChosenByDefaultAndTheYearsOffered() throws {
        let activity = try Self.response(lots: []).activity
        XCTAssertEqual(Text.activity(activity, year: 2026)?.fees, 48.2)
        XCTAssertNil(Text.activity(activity, year: 2025), "no entry for a year gives no figure")

        func period(_ year: String) -> FolyncActivityPeriod {
            FolyncActivityPeriod(period: year, fees: nil, feesPctOfAvgValue: nil, buyCount: 0, sellCount: 0,
                                 tradeCount: 0, buyValue: nil, sellValue: nil, tradeValue: nil, turnoverPct: nil)
        }
        let unsorted = [period("2024"), period("2026"), period("2025")]
        XCTAssertEqual(Text.costYears(unsorted, currentYear: 2026).offered, ["2026", "2025", "2024"])
        XCTAssertEqual(Text.costYears(unsorted, currentYear: 2026).chosen, "2026", "this year by default")
        XCTAssertEqual(Text.costYears(unsorted, currentYear: 2027).chosen, "2026", "else the newest Folync gives")
        XCTAssertEqual(Text.costYears([], currentYear: 2026).offered, [])
        XCTAssertNil(Text.costYears([], currentYear: 2026).chosen)
        XCTAssertEqual(Text.percentOfAverageValue(0.06), "0.06% of average value")
        XCTAssertNil(Text.percentOfAverageValue(nil))
        XCTAssertEqual(Text.amount(nil, currency: "GBP"), "–")
    }

    func testEachRowReadsAsOneSentence() throws {
        let nvda = try Self.lot(Self.lotJSON(id: "lot-1"))
        XCTAssertEqual(Text.rowSentence(nvda, locale: britain),
                       "NVDA, open, opened 11 Feb 2025, held 646 days, cost £7,420.00, gain +£5,540.35, "
                       + "return +74.7 percent, 53.4 points ahead of the S&P 500.")
        let vusa = try Self.lot(Self.lotJSON(id: "lot-2", ticker: "VUSA", status: "Partial", openDate: "2026-10-14",
                                             cost: 504.72, gain: nil, returnPct: nil, alpha: nil, days: 1,
                                             valuationQuality: "partial"))
        XCTAssertEqual(Text.rowSentence(vusa, locale: britain),
                       "VUSA, partial, opened 14 Oct 2026, held 1 day, cost £504.72, gain not given, "
                       + "return not given, no comparison with the S&P 500, value partial.")
    }

    func testTheTableNoteAndHeadingNameWhatFolyncReports() throws {
        let sp = try Self.lot(Self.lotJSON(id: "a"))
        let ftse = try Self.lot(Self.lotJSON(id: "b", ticker: "SHEL", index: "FTSE 100"))
        XCTAssertEqual(Text.comparisonHeading([sp]), "vs S&P")
        XCTAssertEqual(Text.comparisonHeading([sp, ftse]), "vs index")
        XCTAssertEqual(Text.tableNote(lots: [sp], method: .known(.average)),
                       "The last column is points ahead of or behind the S&P 500 over the same days. "
                       + "Trades are matched by average cost, as Folync reports; these are not tax lots.")
        XCTAssertTrue(Text.tableNote(lots: [sp, ftse], method: .known(.fifo))
            .contains("(S&P 500 or FTSE 100, as Folync compares them). Trades are matched by first in, first out"))
        XCTAssertTrue(Text.tableNote(lots: [], method: nil).hasSuffix("Folync does not say how trades are matched; these are not tax lots."))
        XCTAssertEqual(Text.shownCount(1), "Showing 1 trade")
        XCTAssertEqual(StockbarTradesView.gainCaption, "Open and closed trades, all time")
    }

    func testPartialFiguresAreSaidSo() throws {
        let partial = try Self.response(lots: [], quality: "partial")
        XCTAssertEqual(StockbarTradesView.qualityNotice(partial), "Folync marks some of these figures partial: prices stale.")
    }

    func testTheSidebarEntryIsDimmedWithItsReason() throws {
        let entries = StockbarSidebarModel.groups(dimmed: [.trades: StockbarTradesView.needsFolyncReason],
                                                  new: [.trades]).flatMap(\.entries)
        let trades = try XCTUnwrap(entries.first { $0.section == .trades })
        let order = StockbarMainSection.sidebarOrder
        let place = (order.firstIndex(of: .trades) ?? -1) + 1
        XCTAssertEqual(trades.accessibilityValue, "New, Dimmed. Needs a Folync portfolio, \(place) of \(order.count)")
        XCTAssertEqual(StockbarMainSection.trades.title, "Trades")
    }
}

// MARK: - Activity page

/// Stands in for the coordinator's transactions route. Answers in order, or
/// holds each answer until the test releases it.
private actor ActivityRouterStub: StockbarActivityTransactionsRouting {
    enum Call: Equatable {
        case first(FolyncTransactionsQuery, forceRefresh: Bool)
        case more(FolyncTransactionsQuery, cursor: String)
    }

    private(set) var calls: [Call] = []
    private var answers: [FolyncRoutedTransactionsResult] = []
    private var holdsAnswers = false
    private var held: [CheckedContinuation<FolyncRoutedTransactionsResult, Never>] = []

    var heldCount: Int { held.count }

    func queue(_ answers: FolyncRoutedTransactionsResult...) { self.answers += answers }
    func hold(_ holds: Bool) { holdsAnswers = holds }
    func release(with result: FolyncRoutedTransactionsResult) { held.removeFirst().resume(returning: result) }

    func routeTransactions(_ query: FolyncTransactionsQuery, forceRefresh: Bool) async -> FolyncRoutedTransactionsResult {
        calls.append(.first(query, forceRefresh: forceRefresh))
        return await answer()
    }

    func loadMoreTransactions(_ query: FolyncTransactionsQuery, after continuation: FolyncLedgerContinuation) async
        -> FolyncRoutedTransactionsResult {
        calls.append(.more(query, cursor: continuation.cursor))
        return await answer()
    }

    private func answer() async -> FolyncRoutedTransactionsResult {
        if holdsAnswers { return await withCheckedContinuation { held.append($0) } }
        return answers.isEmpty ? .unavailable : answers.removeFirst()
    }
}

/// A debounce the test ends by hand.
private actor ActivityDebounceGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var waits = 0

    func wait() async {
        waits += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor
final class StockbarActivityPageTests: XCTestCase {
    private let britishEnglish = Locale(identifier: "en_GB")

    // MARK: Fixtures (invented figures)

    private func transaction(
        _ id: String = "tx-1", date: String = "2026-11-12", action: String = "buy", ticker: String? = "MSFT",
        quantity: Double = 4, price: Double = 412.30, priceCurrency: String? = "USD", gross: Double = 1_649.20,
        commission: Double = 0, tax: Double = 0, currency: String = "USD", amount: Double? = 1_318.60,
        quality: FolyncFinancialQuality = .complete, reasons: [String] = [],
        adjusted: Bool? = nil, adjustedReason: String? = nil
    ) -> FolyncTransaction {
        FolyncTransaction(
            id: id, portfolioId: "pf_one", portfolioName: "Example", assetId: ticker.map { "asset_\($0.lowercased())" },
            identity: ticker.map {
                FolyncInstrumentIdentity(assetId: "asset_\($0.lowercased())", canonicalTicker: $0, displayTicker: $0,
                                         quoteSymbol: $0, aliases: [$0], isin: nil)
            },
            date: date, action: FolyncOpenEnum(rawValue: action), quantity: quantity, price: price,
            priceCurrency: priceCurrency, grossAmount: gross, commission: commission, tax: tax, currency: currency,
            portfolioCurrency: "GBP", fxRateToPortfolioCurrency: amount == nil ? nil : 0.8,
            fxRateSource: FolyncOpenEnum(rawValue: amount == nil ? "unresolved" : "provider"),
            portfolioAmount: FolyncFinancialMetric(value: amount, currency: "GBP", quality: quality,
                                                   reasonCodes: reasons, asOfDate: date),
            source: "manual", importOwned: false, adjusted: adjusted, adjustedReason: adjustedReason
        )
    }

    private func cash(_ id: String, date: String = "2026-11-02", action: String, amount: Double? = 500,
                      currency: String = "GBP", gross: Double = 500) -> FolyncTransaction {
        transaction(id, date: date, action: action, ticker: nil, quantity: 0, price: 0, priceCurrency: nil,
                    gross: gross, currency: currency, amount: amount)
    }

    private func response(_ rows: [FolyncTransaction], cursor: String? = nil, revision: String = "rev-a",
                          quality: FolyncFinancialQuality = .complete, reasons: [String] = [],
                          generatedAt: String = "2026-11-20T14:05:00.000Z") throws -> FolyncTransactionsResponse {
        let base = try JSONDecoder().decode(FolyncTransactionsResponse.self,
                                            from: Data(FolyncPortfolioSourceTests.ledgerJSON(.transactions).utf8))
        return FolyncTransactionsResponse(
            schemaVersion: base.schemaVersion, sourceRevision: base.sourceRevision, generatedAt: generatedAt,
            scope: base.scope, currency: "GBP", quality: quality, reasonCodes: reasons, freshness: base.freshness,
            mode: base.mode, transactions: rows,
            page: FolyncReadPage(limit: 100, hasMore: cursor != nil, nextCursor: cursor, collectionRevision: revision)
        )
    }

    private func page(_ ids: [String], cursor: String? = nil, status: FolyncSupplementalSourceStatus = .current,
                      paging: FolyncLedgerPaging = .firstPage) throws -> FolyncRoutedTransactionsResult {
        .folync(try response(ids.map { transaction($0) }, cursor: cursor), status: status, paging: paging)
    }

    private func model(_ router: ActivityRouterStub, gate: ActivityDebounceGate? = nil) -> StockbarActivityViewModel {
        StockbarActivityViewModel(router: router, debounce: { await gate?.wait() })
    }

    /// Waits for the model's task, and any task that replaces it, to finish.
    private func settle(_ viewModel: StockbarActivityViewModel) async {
        for _ in 0..<100 {
            guard let task = viewModel.task else { return }
            await task.value
            if viewModel.task == task { return }
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met")
    }

    // MARK: Kinds and queries

    func testEveryKnownActionIsInExactlyOneKind() {
        let kinds: [StockbarActivityKind] = [.trades, .dividends, .cash]
        for action in FolyncTransactionAction.allCases {
            XCTAssertEqual(kinds.filter { $0.actions.contains(action) }.count, 1, action.rawValue)
        }
        XCTAssertEqual(StockbarActivityKind.trades.actions, [.buy, .sell, .split, .corporateAction])
        XCTAssertEqual(StockbarActivityKind.dividends.actions, [.dividend, .stockDividend])
        XCTAssertEqual(StockbarActivityKind.cash.actions, [.deposit, .withdraw, .interest, .fee, .tax, .transfer, .note])
        XCTAssertEqual(StockbarActivityKind.all.actions, [], "All sends no action filter")
        XCTAssertEqual(StockbarActivityKind.allCases.map(\.title), ["All", "Trades", "Dividends", "Cash"])
        XCTAssertEqual(StockbarActivityMode.allCases.map(\.title), ["As entered", "Adjusted"])
    }

    func testTheQueryForEachKindModeAndHolding() {
        let actions: [StockbarActivityKind: String?] = [
            .all: nil, .trades: "buy,sell,split,corporate_action", .dividends: "dividend,stock_dividend",
            .cash: "deposit,withdraw,fee,tax,interest,transfer,note"
        ]
        let modes: [StockbarActivityMode: String] = [.asEntered: "input", .adjusted: "adjusted"]
        let holdings: [String: String?] = ["": nil, "   ": nil, " msft ": "MSFT", "Vusa": "VUSA"]
        for kind in StockbarActivityKind.allCases {
            for (mode, modeValue) in modes {
                for (holding, ticker) in holdings {
                    let items = StockbarActivityQuery.make(kind: kind, mode: mode, holding: holding).queryItems
                    var expected = [URLQueryItem(name: "mode", value: modeValue)]
                    if let ticker { expected.append(URLQueryItem(name: "ticker", value: ticker)) }
                    if let list = actions[kind] ?? nil { expected.append(URLQueryItem(name: "actions", value: list)) }
                    XCTAssertEqual(items, expected, "\(kind) \(mode) '\(holding)'")
                }
            }
        }
        let long = StockbarActivityQuery.make(kind: .all, mode: .asEntered, holding: String(repeating: "a", count: 60))
        XCTAssertEqual(long.instrument, .ticker(String(repeating: "A", count: 40)), "the route takes at most 40 characters")
    }

    // MARK: Months

    func testRowsAreGroupedByTheirOwnCalendarMonthNewestFirst() {
        // A later page continues October, and one row's day does not parse.
        let rows = [
            transaction("a", date: "2026-11-12"), transaction("b", date: "2026-11-01"),
            transaction("c", date: "2026-10-31"), transaction("d", date: "2026-12-01"),
            transaction("e", date: "not-a-day"), transaction("f", date: "2026-10-02")
        ]
        let months = StockbarActivityFormat.months(rows, locale: britishEnglish)
        XCTAssertEqual(months.map(\.title), ["December 2026", "November 2026", "October 2026", "Date not given"])
        XCTAssertEqual(months.map { $0.rows.map(\.id) }, [["d"], ["a", "b"], ["c", "f"], ["e"]],
                       "rows keep Folync's order inside a month, and none is dropped")
        XCTAssertEqual(months[1].rows[1].day, "1 Nov", "the first of the month stays in its month in any time zone")
        XCTAssertEqual(months[3].rows[0].day, "–")
        XCTAssertEqual(StockbarActivityFormat.day("2026-03-01"), FolyncLedgerDay(year: 2026, month: 3, day: 1))
        XCTAssertNil(StockbarActivityFormat.day("2026-13-01"))
    }

    // MARK: Amounts

    func testEachActionsAmountHasItsSignAndColour() {
        let expectations: [(String, String, Double?)] = [
            ("buy", "−£100.00", -1), ("sell", "+£100.00", 1), ("deposit", "+£100.00", 1),
            ("withdraw", "−£100.00", -1), ("fee", "−£100.00", -1), ("dividend", "+£100.00", 1),
            ("stock_dividend", "£100.00", nil), ("tax", "−£100.00", -1), ("interest", "+£100.00", 1),
            ("split", "£100.00", nil), ("transfer", "£100.00", nil), ("corporate_action", "£100.00", nil),
            ("note", "£100.00", nil), ("gift_received", "£100.00", nil)
        ]
        XCTAssertEqual(Set(expectations.map(\.0)).count, FolyncTransactionAction.allCases.count + 1)
        for (action, text, sign) in expectations {
            let row = transaction(action: action, amount: 100)
            XCTAssertEqual(StockbarActivityFormat.amount(row), text, action)
            XCTAssertEqual(StockbarActivityFormat.colourSign(row), sign, action)
        }
    }

    func testAnUnknownAmountIsADashNeverZero() {
        let unknown = transaction(action: "interest", amount: nil, quality: .unavailable, reasons: ["fx_unresolved"])
        let row = StockbarActivityFormat.row(unknown, locale: britishEnglish)
        XCTAssertEqual(row.amount, "–")
        XCTAssertNil(row.colourSign)
        XCTAssertEqual(row.qualityNote, "unavailable")
        XCTAssertEqual(row.reasons, "fx unresolved")

        let zero = transaction(action: "buy", amount: 0)
        XCTAssertEqual(StockbarActivityFormat.amount(zero), "£0.00", "a zero Folync gives is shown, without a sign")
        XCTAssertNil(StockbarActivityFormat.colourSign(zero))

        let negative = transaction(action: "dividend", amount: -3.2)
        XCTAssertEqual(StockbarActivityFormat.amount(negative), "−£3.20", "a sign Folync gives is kept")
        XCTAssertEqual(StockbarActivityFormat.colourSign(negative), -1)
        XCTAssertEqual(StockbarActivityFormat.spokenAmount(negative), "minus £3.20")
        XCTAssertEqual(StockbarActivityFormat.amount(transaction(action: "split", amount: -3.2)), "−£3.20")
        XCTAssertNil(StockbarActivityFormat.colourSign(transaction(action: "split", amount: -3.2)))

        let partial = StockbarActivityFormat.row(transaction(action: "dividend", amount: 14.6, quality: .partial))
        XCTAssertEqual(partial.amount, "+£14.60")
        XCTAssertEqual(partial.qualityNote, "partial")
    }

    // MARK: Detail

    func testTheDetailLineWithAndWithoutEachFigure() {
        XCTAssertEqual(StockbarActivityFormat.detail(transaction()), "4 shares at $412.30")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 1, price: 84.1234, priceCurrency: "GBP")),
                       "1 share at £84.1234", "the price as Folync gives it, to four decimals")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 140, price: 29.3, priceCurrency: "GBX")),
                       "140 shares at 29.3p")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 300, price: 0)), "300 shares")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 0, price: 412.3)), "at $412.30")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(commission: 1.5, tax: 0.25)),
                       "4 shares at $412.30 · commission $1.50 · tax $0.25")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(commission: 0, tax: 0.25)), "4 shares at $412.30 · tax $0.25")
        XCTAssertEqual(StockbarActivityFormat.detail(cash("d", action: "deposit")), "–", "a deposit has no quantity or price")
        XCTAssertEqual(StockbarActivityFormat.detail(cash("i", action: "interest", amount: nil, currency: "USD", gross: 1.84)),
                       "$1.84", "cash in another currency shows its own amount")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 40, price: 30, priceCurrency: "USD",
                                                                 adjusted: true, adjustedReason: "4-for-1 split")),
                       "40 shares at $30.00 · adjusted: 4-for-1 split")
        XCTAssertEqual(StockbarActivityFormat.detail(transaction(quantity: 2.5)), "2.5 shares at $412.30")
    }

    func testAnActionThisBuildDoesNotKnowIsShownByItsRawName() {
        let gift = transaction("g", action: "gift_received", ticker: nil, quantity: 0, price: 0, amount: 25)
        let months = StockbarActivityFormat.months([gift], locale: britishEnglish)
        let row = try? XCTUnwrap(months.first?.rows.first)
        XCTAssertEqual(row?.actionTitle, "gift_received")
        XCTAssertEqual(row?.glyph, .unknown)
        XCTAssertEqual(row?.ticker, "–")
        XCTAssertEqual(row?.amount, "£25.00")
        XCTAssertNil(row?.colourSign)
    }

    // MARK: VoiceOver

    func testEachRowReadsAsOneSentence() {
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(transaction(), name: "Microsoft", locale: britishEnglish),
                       "12 November, bought 4 Microsoft shares at $412.30, £1,318.60 out")
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(transaction(commission: 1), locale: britishEnglish),
                       "12 November, bought 4 MSFT shares at $412.30, commission $1.00, £1,318.60 out")
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(
            transaction(date: "2026-11-04", action: "dividend", ticker: "SHEL", quantity: 140, price: 29.3,
                        priceCurrency: "GBX", currency: "GBP", amount: 41.02, quality: .partial), locale: britishEnglish),
                       "4 November, dividend, SHEL, 140 shares at 29.3p, £41.02 in, partial")
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(cash("d", action: "deposit"), locale: britishEnglish),
                       "2 November, deposit, £500.00 in")
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(
            cash("i", date: "2026-09-08", action: "interest", amount: nil, currency: "USD", gross: 1.84), locale: britishEnglish),
                       "8 September, interest, $1.84, amount not given")
        XCTAssertEqual(StockbarActivityFormat.accessibilityLabel(
            cash("g", action: "gift_received", amount: 25), locale: britishEnglish),
                       "2 November, gift_received, an action Stockbar does not know, £25.00")
        XCTAssertEqual(StockbarActivityFormat.spokenName("Microsoft · Demo portfolio"), "Microsoft")
        XCTAssertNil(StockbarActivityFormat.spokenName(""), "no name: the ticker is read")
        XCTAssertEqual(StockbarActivityFormat.row(transaction(), name: "Microsoft", locale: britishEnglish).accessibilityLabel,
                       "12 November, bought 4 Microsoft shares at $412.30, £1,318.60 out")
    }

    // MARK: Load rule

    func testANonFolyncPortfolioMakesNoRequest() async {
        let router = ActivityRouterStub()
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: false)
        viewModel.kind = .trades
        viewModel.refresh()
        viewModel.loadMore()
        await settle(viewModel)
        XCTAssertEqual(viewModel.phase, .needsFolync)
        let calls = await router.calls
        XCTAssertEqual(calls, [])
    }

    func testNoRequestWhileThePageIsNotSelected() async throws {
        let router = ActivityRouterStub()
        let viewModel = model(router)
        viewModel.kind = .cash
        viewModel.mode = .adjusted
        viewModel.holding = "MSFT"
        viewModel.refresh()
        await settle(viewModel)
        XCTAssertEqual(viewModel.phase, .idle)
        let calls = await router.calls
        XCTAssertEqual(calls, [])

        await router.queue(try page(["a"]))
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        viewModel.deactivate()
        viewModel.kind = .all
        await settle(viewModel)
        let afterDeactivate = await router.calls
        XCTAssertEqual(afterDeactivate.count, 1, "a change on a page that is not selected asks nothing")
    }

    func testActivateAsksOnceAndASecondActivateAsksNothing() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a", "b"]))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        XCTAssertEqual(viewModel.phase, .idle, "nothing is shown before the answer")
        await settle(viewModel)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        let calls = await router.calls
        XCTAssertEqual(calls, [.first(StockbarActivityQuery.make(kind: .all, mode: .asEntered, holding: ""), forceRefresh: false)],
                       "opening the page leaves the five-minute reuse to the fetch policy")
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a", "b"])
    }

    func testReopeningThePageAsksThePolicyWithoutForcing() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"]), try page(["a"]))
        let first = model(router)
        first.activate(isFolyncPortfolio: true)
        await settle(first)
        first.deactivate()
        // The page is rebuilt each time it is selected.
        let second = model(router)
        second.activate(isFolyncPortfolio: true)
        await settle(second)
        let calls = await router.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { if case .first(_, forceRefresh: false) = $0 { true } else { false } })
    }

    func testTheRefreshControlForcesARefresh() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"]), try page(["a", "b"]))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        viewModel.refresh()
        XCTAssertTrue(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a"], "the rows stay while the same query is refreshed")
        await settle(viewModel)
        let calls = await router.calls
        XCTAssertEqual(calls.last, .first(viewModel.query, forceRefresh: true))
        XCTAssertFalse(viewModel.isRefreshing)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a", "b"])
    }

    func testLoadMoreAppendsAndARestartDropsTheRowsGathered() async throws {
        let router = ActivityRouterStub()
        await router.queue(
            try page(["a", "b"], cursor: "c1"),
            try page(["c"], cursor: "c2", paging: .nextPage),
            try page(["x"], cursor: "c9", paging: .restarted)
        )
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        XCTAssertTrue(viewModel.canLoadMore)
        viewModel.loadMore()
        XCTAssertTrue(viewModel.isLoadingMore)
        await settle(viewModel)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a", "b", "c"])
        viewModel.loadMore()
        await settle(viewModel)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["x"], "a restart starts again from the page returned")
        XCTAssertEqual(viewModel.continuation?.cursor, "c9")
        let calls = await router.calls
        XCTAssertEqual(calls.dropFirst().map { if case .more(_, let cursor) = $0 { cursor } else { "" } }, ["c1", "c2"])
    }

    func testAFailedLoadMoreKeepsTheRows() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"], cursor: "c1"), .unreachable)
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        viewModel.loadMore()
        await settle(viewModel)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a"])
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertTrue(viewModel.loadMoreFailed)
        XCTAssertTrue(viewModel.canLoadMore, "the user can try again")
    }

    func testNoLoadMoreWithoutACursor() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"]))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        XCTAssertFalse(viewModel.canLoadMore)
        viewModel.loadMore()
        await settle(viewModel)
        let calls = await router.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testAChangeIsDebouncedAndASupersededChangeIsCancelled() async throws {
        let router = ActivityRouterStub()
        let gate = ActivityDebounceGate()
        await router.queue(try page(["a"]), try page(["cash"]))
        let viewModel = model(router, gate: gate)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)

        viewModel.kind = .trades
        await waitUntil { await gate.waits == 1 }
        XCTAssertTrue(viewModel.isQueryPending)
        viewModel.kind = .cash
        await waitUntil { await gate.waits == 2 }
        let duringDebounce = await router.calls
        XCTAssertEqual(duringDebounce.count, 1, "nothing is asked until the debounce ends")

        await gate.open()
        await settle(viewModel)
        let calls = await router.calls
        XCTAssertEqual(calls.count, 2, "the superseded Trades query is never asked")
        XCTAssertEqual(calls.last, .first(StockbarActivityQuery.make(kind: .cash, mode: .asEntered, holding: ""),
                                          forceRefresh: false))
        XCTAssertEqual(viewModel.transactions.map(\.id), ["cash"])
        XCTAssertFalse(viewModel.isQueryPending)
    }

    func testReturningToTheQueryOnScreenAsksNothing() async throws {
        let router = ActivityRouterStub()
        let gate = ActivityDebounceGate()
        await router.queue(try page(["a"]))
        let viewModel = model(router, gate: gate)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        viewModel.holding = "MSFT"
        await waitUntil { await gate.waits == 1 }
        viewModel.holding = " "
        XCTAssertNil(viewModel.task, "the pending query is dropped")
        await gate.open()
        await settle(viewModel)
        let calls = await router.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a"])
    }

    func testRevertingAChangeWhileItLoadsShowsRowsAgain() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"]))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)

        await router.hold(true)
        viewModel.mode = .adjusted
        await waitUntil { await router.heldCount == 1 }
        XCTAssertEqual(viewModel.phase, .loading)
        viewModel.mode = .asEntered
        await waitUntil { await router.heldCount == 2 }
        await router.release(with: try page(["late-adjusted"]))
        await router.release(with: try page(["a"]))
        await settle(viewModel)
        XCTAssertEqual(viewModel.phase, .loaded, "never left on a spinner with nothing in flight")
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a"])
        let calls = await router.calls
        XCTAssertEqual(calls.last, .first(StockbarActivityQuery.make(kind: .all, mode: .asEntered, holding: ""),
                                          forceRefresh: false), "asked without forcing, so the five-minute reuse answers")
    }

    func testACancelledResultIsNeverApplied() async throws {
        let router = ActivityRouterStub()
        await router.queue(try page(["a"]))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)

        await router.hold(true)
        viewModel.mode = .adjusted
        await waitUntil { await router.heldCount == 1 }
        viewModel.mode = .asEntered
        viewModel.kind = .dividends
        await waitUntil { await router.heldCount == 2 }
        // The superseded query's answer arrives first, then the current one's.
        await router.release(with: try page(["stale-answer"]))
        await router.release(with: try page(["div"]))
        await settle(viewModel)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["div"])
        XCTAssertEqual(viewModel.appliedQuery, StockbarActivityQuery.make(kind: .dividends, mode: .asEntered, holding: ""))

        // A cancelled caller is answered `.unavailable`: it never reaches the screen.
        viewModel.refresh()
        await waitUntil { await router.heldCount == 1 }
        viewModel.deactivate()
        await router.release(with: .unavailable)
        await Task.yield()
        XCTAssertEqual(viewModel.phase, .loaded)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["div"])
    }

    func testLeavingThePageMidLoadAsksAgainOnReturn() async throws {
        let router = ActivityRouterStub()
        await router.hold(true)
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await waitUntil { await router.heldCount == 1 }
        viewModel.deactivate()
        await router.release(with: try page(["late"]))
        await Task.yield()
        XCTAssertTrue(viewModel.transactions.isEmpty)
        await router.hold(false)
        await router.queue(try page(["a"]))
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        XCTAssertEqual(viewModel.transactions.map(\.id), ["a"])
    }

    // MARK: States

    func testEachStateComesFromTheRoutesAnswer() async throws {
        let saved = try response([transaction("s")], generatedAt: "2026-11-20T14:05:00.000Z")
        let cases: [(FolyncRoutedTransactionsResult, StockbarActivityViewModel.Phase, Int)] = [
            (try page(["a"]), .loaded, 1),
            (try page(["a"], status: .partial), .loaded, 1),
            (.folync(saved, status: .stale, paging: .firstPage),
             .stale(savedAt: Date(timeIntervalSince1970: 1_795_183_500)), 1),
            (.unreachable, .unreachable, 0),
            (.unavailable, .unavailable, 0),
            (.disabled, .disabled, 0)
        ]
        for (answer, phase, rows) in cases {
            let router = ActivityRouterStub()
            await router.queue(answer)
            let viewModel = model(router)
            viewModel.activate(isFolyncPortfolio: true)
            await settle(viewModel)
            XCTAssertEqual(viewModel.phase, phase)
            XCTAssertEqual(viewModel.transactions.count, rows)
        }
    }

    func testTheLoadingStateAndTheSwitchToAFolyncPortfolio() async throws {
        let router = ActivityRouterStub()
        await router.hold(true)
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: false)
        XCTAssertEqual(viewModel.phase, .needsFolync)
        viewModel.activate(isFolyncPortfolio: true)
        await waitUntil { await router.heldCount == 1 }
        XCTAssertEqual(viewModel.phase, .loading)
        await router.release(with: try page(["a"]))
        await settle(viewModel)
        XCTAssertEqual(viewModel.phase, .loaded)
        viewModel.activate(isFolyncPortfolio: false)
        XCTAssertEqual(viewModel.phase, .needsFolync)
        XCTAssertTrue(viewModel.transactions.isEmpty)
    }

    func testPartialAnswersAndSavedCopiesSaySo() async throws {
        let router = ActivityRouterStub()
        await router.queue(.folync(try response([transaction()], quality: .partial, reasons: ["fx_stale"]),
                                   status: .partial, paging: .firstPage))
        let viewModel = model(router)
        viewModel.activate(isFolyncPortfolio: true)
        await settle(viewModel)
        XCTAssertEqual(viewModel.quality, .partial)
        XCTAssertEqual(StockbarActivityText.qualityNotice(viewModel.quality, reasons: viewModel.reasonCodes),
                       "Folync marks these transactions partial: fx stale.")

        let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
        let saved = Date(timeIntervalSince1970: 1_795_183_500)
        XCTAssertEqual(StockbarActivityText.staleNotice(savedAt: saved, now: saved.addingTimeInterval(600),
                                                        locale: britishEnglish, timeZone: utc),
                       "Couldn't get current transactions from Folync. Showing the copy saved at 14:05.")
        XCTAssertEqual(StockbarActivityText.staleNotice(savedAt: nil),
                       "Couldn't get current transactions from Folync. Showing the copy saved earlier.")
        XCTAssertEqual(StockbarActivityText.shownCount(1), "Showing 1 transaction")
        XCTAssertEqual(StockbarActivityText.shownCount(12), "Showing 12 transactions")
        XCTAssertEqual(StockbarActivityText.noRows(kind: .trades, holding: .ticker("MSFT")),
                       "Folync has no trades for MSFT.")
        XCTAssertEqual(StockbarActivityText.noRows(kind: .all, holding: nil), "Folync has no transactions for this portfolio.")
    }

    // MARK: Sidebar

    func testTheSidebarEntryIsNewAndDimmedWithoutAFolyncPortfolio() throws {
        XCTAssertEqual(StockbarMainSection.activity.title, "Activity")
        let order = StockbarMainSection.sidebarOrder
        XCTAssertEqual(order.firstIndex(of: .activity), try XCTUnwrap(order.firstIndex(of: .holdings)) + 1,
                       "Activity follows Holdings in the Portfolio group")
        XCTAssertTrue(StockbarMainSection.newSections.contains(.activity))
        XCTAssertTrue(StockbarMainSection.folyncOnlySections.contains(.activity))
        let dimmed = StockbarSidebarModel.groups(dimmed: [.activity: StockbarMainSection.needsFolyncReason],
                                                 new: StockbarMainSection.newSections).flatMap(\.entries)
        let entry = try XCTUnwrap(dimmed.first { $0.section == .activity })
        let sidebar = StockbarMainSection.sidebarOrder
        XCTAssertEqual(sidebar.firstIndex(of: .activity), 2, "Activity is the third entry, after Holdings")
        XCTAssertEqual(entry.accessibilityValue, "New, Dimmed. Needs a Folync portfolio, 3 of \(sidebar.count)")
    }
}

// MARK: - Settings switches for the Income, Trades and Activity pages

extension FolyncPortfolioSourceTests {
    private static func ledgerCapabilities(
        dividends: FolyncCapability?,
        tradeAnalysis: FolyncCapability?,
        transactions: FolyncCapability?
    ) -> FolyncCapabilities {
        let base = FolyncCapabilities.fixture(lineHistory: true, candlesticks: true, benchmarks: true, exchangeRates: true)
        return FolyncCapabilities(
            schemaVersion: base.schemaVersion,
            sourceRevision: base.sourceRevision,
            generatedAt: base.generatedAt,
            resources: .init(
                lineHistory: base.resources.lineHistory,
                candlesticks: base.resources.candlesticks,
                benchmarks: base.resources.benchmarks,
                exchangeRates: base.resources.exchangeRates,
                transactions: transactions,
                dividends: dividends,
                tradeAnalysis: tradeAnalysis
            ),
            ranges: base.ranges,
            intervals: base.intervals,
            retentionDays: base.retentionDays,
            benchmarks: base.benchmarks,
            fx: base.fx,
            trackedAssets: base.trackedAssets,
            trackedSymbols: base.trackedSymbols,
            marketIdentities: base.marketIdentities
        )
    }

    private static let usable = FolyncCapability(supported: true, ready: true, reasonCodes: [])
    private static let unsupported = FolyncCapability(supported: false, ready: false, reasonCodes: ["not_configured"])
    private static let notReady = FolyncCapability(supported: true, ready: false, reasonCodes: ["snapshots_rebuilding", "fx_stale"])

    func testLedgerSwitchTitlesAndVoiceOverNames() {
        XCTAssertEqual(FolyncLedgerRoute.allCases.map(\.settingsTitle), ["Income", "Trades", "Activity"])
        XCTAssertEqual(FolyncLedgerRoute.dividends.settingsAccessibilityLabel, "Income, New")
        XCTAssertEqual(FolyncLedgerRoute.tradeAnalysis.settingsAccessibilityLabel, "Trades, New")
        XCTAssertEqual(FolyncLedgerRoute.transactions.settingsAccessibilityLabel, "Activity, New")
    }

    func testLedgerSwitchStatusForEachCapabilityAnswer() {
        for route in FolyncLedgerRoute.allCases {
            // No capabilities answer yet: the older rows' wording.
            XCTAssertEqual(
                FolyncRouteSettingsStatus.label(for: FolyncRouteSettingsStatus.capability(for: route, in: nil)),
                "Not supported by this Folync server", "\(route)"
            )
            func status(_ capability: FolyncCapability?) -> String {
                let others = Self.usable
                let capabilities = Self.ledgerCapabilities(
                    dividends: route == .dividends ? capability : others,
                    tradeAnalysis: route == .tradeAnalysis ? capability : others,
                    transactions: route == .transactions ? capability : others
                )
                return FolyncRouteSettingsStatus.label(
                    for: FolyncRouteSettingsStatus.capability(for: route, in: capabilities)
                )
            }
            XCTAssertEqual(status(nil), "Not supported by this Folync server", "\(route) left out of the answer")
            XCTAssertEqual(status(Self.unsupported), "Unsupported", "\(route)")
            XCTAssertEqual(status(Self.notReady), "Not ready · snapshots rebuilding, fx stale", "\(route)")
            XCTAssertEqual(status(Self.usable), "Ready", "\(route)")
        }
    }

    func testOneLedgerCapabilityLeftOutAffectsOnlyItsRow() {
        let capabilities = Self.ledgerCapabilities(dividends: Self.usable, tradeAnalysis: nil, transactions: Self.notReady)
        let labels = FolyncLedgerRoute.allCases.map {
            FolyncRouteSettingsStatus.label(for: FolyncRouteSettingsStatus.capability(for: $0, in: capabilities))
        }
        XCTAssertEqual(labels, ["Ready", "Not supported by this Folync server", "Not ready · snapshots rebuilding, fx stale"])
    }

    func testOlderRowsKeepTheirStatusWording() {
        XCTAssertEqual(FolyncRouteSettingsStatus.label(for: Self.usable, readyLabel: "Folync"), "Folync")
        XCTAssertEqual(FolyncRouteSettingsStatus.label(for: Self.notReady, readyLabel: "Folync"),
                       "Not ready · snapshots rebuilding, fx stale")
        XCTAssertEqual(FolyncRouteSettingsStatus.label(for: Self.unsupported, readyLabel: "Folync"), "Unsupported")
        XCTAssertEqual(FolyncRouteSettingsStatus.label(for: nil, readyLabel: "Folync"), "Not supported by this Folync server")
    }

    func testASwitchThatIsOffCannotBeTurnedOnWithoutAUsableCapability() {
        for capability in [nil, Self.unsupported, Self.notReady] {
            XCTAssertFalse(FolyncRouteSettingsStatus.canChange(isOn: false, capability: capability), "\(String(describing: capability))")
            XCTAssertTrue(FolyncRouteSettingsStatus.canChange(isOn: true, capability: capability),
                          "A lost capability must not trap a switch that is on")
        }
        XCTAssertTrue(FolyncRouteSettingsStatus.canChange(isOn: false, capability: Self.usable))
        XCTAssertTrue(FolyncRouteSettingsStatus.canChange(isOn: true, capability: Self.usable))
    }

    /// Settings → Connections gives Folync's schedule in one line.
    func testScheduleLineGivesLastAndNextCheckInOneLine() {
        let locale = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC")!
        let last = Date(timeIntervalSince1970: 1_795_707_720)  // 2026-11-26 15:42:00 UTC
        let next = last.addingTimeInterval(65)
        XCTAssertEqual(FolyncScheduleText.line(lastChecked: last, next: next, locale: locale, timeZone: utc),
                       "Last checked 15:42, next 15:43")
        XCTAssertEqual(FolyncScheduleText.line(lastChecked: last, next: nil, locale: locale, timeZone: utc),
                       "Last checked 15:42")
        XCTAssertEqual(FolyncScheduleText.line(lastChecked: nil, next: next, locale: locale, timeZone: utc),
                       "Next check 15:43")
        XCTAssertNil(FolyncScheduleText.line(lastChecked: nil, next: nil, locale: locale, timeZone: utc),
                     "nothing known, no line")
    }

    func testSavedSupplementalSettingsKeepTheirKeysAndValues() throws {
        let settings = FolyncSupplementalSettings(
            historicalLineCharts: true, candlestickCharts: false, benchmarkMarketData: true, exchangeRates: false,
            allowLegacyFallback: true, dividends: false, tradeAnalysis: true, transactions: false
        )
        let data = try JSONEncoder().encode(settings)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
        XCTAssertEqual(Set(keys.keys), [
            "historicalLineCharts", "candlestickCharts", "benchmarkMarketData", "exchangeRates",
            "allowLegacyFallback", "dividends", "tradeAnalysis", "transactions"
        ])
        XCTAssertEqual(try JSONDecoder().decode(FolyncSupplementalSettings.self, from: data), settings)
    }

    @MainActor
    func testFlippingALedgerSwitchSavesOnlyThatSettingAndMakesNoRequest() async throws {
        let env = try makeIsolatedSessionEnvironment()
        defer { env.cleanup() }
        let initial = FolyncSupplementalSettings(
            historicalLineCharts: true, candlestickCharts: false, benchmarkMarketData: true, exchangeRates: false,
            allowLegacyFallback: true, dividends: true, tradeAnalysis: true, transactions: false
        )
        env.settingsStore.save(FolyncStoredSettings(
            isEnabled: true,
            baseURL: "https://folync.example.invalid",
            scopeID: "pf_demo",
            pollingIntervalSeconds: 60,
            supplemental: initial
        ))
        let stub = FolyncHTTPStub()
        FolyncURLProtocolStub.stub = stub
        stub.handler = { request in
            if request.url?.path == "/api/client/v2/capabilities" {
                return Self.httpResponse(request, status: 200, body: Self.readyMarketCapabilitiesJSON)
            }
            return Self.httpResponse(request, status: 404, body: "{}")
        }
        let dataModel = makeTestDataModel(dependencies: env.dependencies)
        defer { dataModel.deactivateFolyncPortfolio() }

        var expected = initial
        for route in FolyncLedgerRoute.allCases {
            for _ in 0..<2 {
                var changed = env.settingsStore.load().supplemental
                switch route {
                case .dividends: changed.dividends.toggle()
                case .tradeAnalysis: changed.tradeAnalysis.toggle()
                case .transactions: changed.transactions.toggle()
                }
                await dataModel.updateFolyncSupplementalSettings(changed)
                switch route {
                case .dividends: expected.dividends.toggle()
                case .tradeAnalysis: expected.tradeAnalysis.toggle()
                case .transactions: expected.transactions.toggle()
                }
                let saved = env.settingsStore.load()
                XCTAssertEqual(saved.supplemental, expected, "\(route): only that switch changes")
                XCTAssertTrue(saved.isEnabled)
                XCTAssertEqual(saved.baseURL, "https://folync.example.invalid")
                XCTAssertEqual(saved.scopeID, "pf_demo")
                XCTAssertEqual(saved.pollingIntervalSeconds, 60)
                for other in FolyncLedgerRoute.allCases {
                    XCTAssertEqual(saved.isLedgerRouteActive(other), expected.isEnabled(other), "\(other) after \(route)")
                }
            }
        }
        XCTAssertEqual(stub.requests.count, 0, "A ledger switch asks Folync nothing; its page asks when opened")
        XCTAssertNil(dataModel.folyncSupplementalRefreshTimer, "A ledger switch does not restart the market-data schedule")

        // The older rows still restart the schedule, which asks for capabilities.
        var marketData = env.settingsStore.load().supplemental
        marketData.exchangeRates = true
        await dataModel.updateFolyncSupplementalSettings(marketData)
        XCTAssertGreaterThan(stub.requests.count, 0)
        XCTAssertNotNil(dataModel.folyncSupplementalRefreshTimer)
    }

    func testOnlyAChangeToTheLedgerSwitchesCountsAsTheSameMarketDataRoutes() {
        let base = FolyncSupplementalSettings.disabled
        var ledger = base
        ledger.dividends = true
        ledger.tradeAnalysis = true
        ledger.transactions = true
        XCTAssertTrue(base.hasSameMarketDataRoutes(as: ledger))
        let changes: [WritableKeyPath<FolyncSupplementalSettings, Bool>] = [
            \.historicalLineCharts, \.candlestickCharts, \.benchmarkMarketData, \.exchangeRates, \.allowLegacyFallback
        ]
        for keyPath in changes {
            var changed = base
            changed[keyPath: keyPath] = true
            XCTAssertFalse(base.hasSameMarketDataRoutes(as: changed), "\(keyPath)")
        }
    }
}
