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
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-31T12:00:00Z"))
        let later = day.addingTimeInterval(86_400 * 30)
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
        try await Task.sleep(nanoseconds: 50_000_000)
        let joining = Task {
            await policy.perform(key) {
                ran.value.append("joining")
                return .init(result: "joining", firstPageToKeep: nil)
            }
        }
        let refreshing = Task {
            await policy.perform(key, forceRefresh: true) {
                ran.value.append("refreshing")
                return .init(result: "refreshing", firstPageToKeep: nil)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
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
        func run(_ name: String) async -> String {
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

        let reused: String = await policy.perform(key("a")) { .init(result: "not reused", firstPageToKeep: nil) }
        XCTAssertEqual(reused, "a")
        clock.value = clock.value.addingTimeInterval(FolyncLedgerFetchPolicy.defaultReuseInterval)
        let expired: String = await policy.perform(key("a")) { .init(result: "fresh", firstPageToKeep: nil) }
        XCTAssertEqual(expired, "fresh")
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
