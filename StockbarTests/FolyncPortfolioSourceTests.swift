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
