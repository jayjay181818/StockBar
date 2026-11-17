import XCTest
@testable import Stockbar

final class HistoricalPortfolioCalculationServiceTests: XCTestCase {
    func testCalculateSnapshotsFiltersRangeAndPreservesFirstAndLastDates() async throws {
        // Given: Historical prices spanning outside and inside the requested range.
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 4, day: 20))!
        let dayOne = calendar.date(from: DateComponents(year: 2026, month: 4, day: 21))!
        let dayTwo = calendar.date(from: DateComponents(year: 2026, month: 4, day: 22))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 4, day: 23))!

        let prices = [
            PriceSnapshot(timestamp: start.addingTimeInterval(-86_400), price: 50, previousClose: 50, symbol: "AAPL"),
            PriceSnapshot(timestamp: dayOne, price: 100, previousClose: 95, symbol: "AAPL"),
            PriceSnapshot(timestamp: dayTwo, price: 110, previousClose: 100, symbol: "AAPL"),
            PriceSnapshot(timestamp: end.addingTimeInterval(86_400), price: 120, previousClose: 110, symbol: "AAPL")
        ]
        let composition = PortfolioComposition(positions: [
            PortfolioPosition(symbol: "AAPL", units: 10, avgCost: 80, currency: "USD")
        ])
        let input = HistoricalPortfolioCalculationInput(
            startDate: start,
            endDate: end,
            priceSnapshots: ["AAPL": prices],
            composition: composition,
            preferredCurrency: "USD"
        )

        // When: Calculating historical portfolio values off the manager.
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)

        // Then: Only in-range days are returned, ordered and valued correctly.
        XCTAssertEqual(snapshots.map(\.date), [dayOne, dayTwo])
        let firstSnapshot = try XCTUnwrap(snapshots.first)
        let lastSnapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(firstSnapshot.totalValue, 1_000, accuracy: 0.01)
        XCTAssertEqual(lastSnapshot.totalValue, 1_100, accuracy: 0.01)
        XCTAssertEqual(firstSnapshot.totalCost, 800, accuracy: 0.01)
    }

    func testCalculateSnapshotsSkipsInvalidPricesButKeepsValidPositions() async throws {
        // Given: One invalid position price and one valid position on the same day.
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let composition = PortfolioComposition(positions: [
            PortfolioPosition(symbol: "GOOD", units: 5, avgCost: 40, currency: "USD"),
            PortfolioPosition(symbol: "BAD", units: 5, avgCost: 40, currency: "USD")
        ])
        let input = HistoricalPortfolioCalculationInput(
            startDate: date.addingTimeInterval(-60),
            endDate: date.addingTimeInterval(60),
            priceSnapshots: [
                "GOOD": [PriceSnapshot(timestamp: date, price: 50, previousClose: 45, symbol: "GOOD")],
                "BAD": [PriceSnapshot(timestamp: date, price: .nan, previousClose: 45, symbol: "BAD")]
            ],
            composition: composition,
            preferredCurrency: "USD"
        )

        // When: Calculating snapshots with partial invalid data.
        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)

        // Then: The valid position is retained and the invalid one is omitted.
        XCTAssertEqual(snapshots.count, 1)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.totalValue, 250, accuracy: 0.01)
        XCTAssertEqual(snapshot.portfolioComposition.symbols, ["GOOD"])
    }

    func testGainsUseOnlyValuedPositionsWithAReadableCost() async throws {
        let date = Date(timeIntervalSince1970: 1_777_777_777)
        let composition = PortfolioComposition(positions: [
            PortfolioPosition(symbol: "GOOD", units: 5, avgCost: 40, currency: "USD"),
            PortfolioPosition(symbol: "NOPRICE", units: 5, avgCost: 1_000, currency: "USD"),
            PortfolioPosition(symbol: "NOCOST", units: 2, avgCost: .nan, currency: "USD")
        ])
        let input = HistoricalPortfolioCalculationInput(
            startDate: date.addingTimeInterval(-60),
            endDate: date.addingTimeInterval(60),
            priceSnapshots: [
                "GOOD": [PriceSnapshot(timestamp: date, price: 50, previousClose: 45, symbol: "GOOD")],
                "NOCOST": [PriceSnapshot(timestamp: date, price: 30, previousClose: 30, symbol: "NOCOST")]
            ],
            composition: composition,
            preferredCurrency: "USD"
        )

        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)
        let snapshot = try XCTUnwrap(snapshots.first)

        XCTAssertEqual(snapshot.totalValue, 310, accuracy: 0.01)
        XCTAssertEqual(snapshot.totalCost, 200, accuracy: 0.01)
        XCTAssertEqual(snapshot.totalGains, 50, accuracy: 0.01)
    }

    func testADayIsNotRecordedWhileALargeHoldingHasNoPriceYet() async throws {
        let day = { (n: Double) in Date(timeIntervalSince1970: 1_777_766_400 + n * 86_400) }
        let composition = PortfolioComposition(positions: [
            PortfolioPosition(symbol: "SMALL", units: 1, avgCost: 10, currency: "USD"),
            PortfolioPosition(symbol: "LARGE", units: 100, avgCost: 10, currency: "USD")
        ])
        let input = HistoricalPortfolioCalculationInput(
            startDate: day(0).addingTimeInterval(-60),
            endDate: day(3),
            priceSnapshots: [
                "SMALL": [0, 1, 2].map { PriceSnapshot(timestamp: day($0), price: 10, previousClose: 10, symbol: "SMALL") },
                // LARGE has no history before day 1; day 0 must not borrow day 1's price.
                "LARGE": [PriceSnapshot(timestamp: day(1), price: 20, previousClose: 20, symbol: "LARGE")]
            ],
            composition: composition,
            preferredCurrency: "USD"
        )

        let snapshots = await HistoricalPortfolioCalculationService().calculateSnapshots(input)

        // Day 0 is dropped (only 10 of 2,010 priced); day 2 carries LARGE's day-1 price forward.
        XCTAssertEqual(snapshots.map(\.totalValue), [2_010, 2_010])
    }

    // MARK: - History retention and merging

    func testThinnedPriceHistoryKeepsRecentPointsAndOneCloseFromEachOlderDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        let old = calendar.date(from: DateComponents(year: 2021, month: 11, day: 4, hour: 16))!
        var snapshots: [PriceSnapshot] = []
        // Five years of daily closes, then two dense intraday samples per older day.
        for day in 0..<1_800 {
            let close = old.addingTimeInterval(Double(day) * 86_400)
            guard close < now.addingTimeInterval(-8 * 86_400) else { break }
            snapshots.append(PriceSnapshot(timestamp: close.addingTimeInterval(-3_600), price: 1, previousClose: 1, symbol: "AV.L"))
            snapshots.append(PriceSnapshot(timestamp: close, price: 2, previousClose: 1, symbol: "AV.L"))
        }
        let recent = (0..<300).map {
            PriceSnapshot(timestamp: now.addingTimeInterval(-Double($0) * 300), price: 3, previousClose: 2, symbol: "AV.L")
        }

        let thinned = HistoricalDataManager.thinnedPriceHistory(snapshots + recent, now: now, intradayDays: 7, calendar: calendar)

        XCTAssertEqual(thinned.first?.timestamp, old, "The oldest daily close of a long backfill survives")
        XCTAssertEqual(thinned.filter { $0.price == 1 }.count, 0, "Only the last point of each older day is kept")
        XCTAssertEqual(thinned.filter { $0.price == 3 }.count, 300, "Every point from the last week is kept")
        XCTAssertEqual(thinned.map(\.timestamp), thinned.map(\.timestamp).sorted())
    }

    func testThinnedPriceHistoryHoldsLittleMoreThanItKeeps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        // 3000 daily closes, all kept, and the same days with four points each,
        // three of which are dropped.
        let daily = (0..<3_000).map {
            PriceSnapshot(timestamp: now.addingTimeInterval(-Double($0 + 40) * 86_400), price: 1, previousClose: 1, symbol: "AV.L")
        }
        let dense = daily.flatMap { close in
            (0..<4).map {
                PriceSnapshot(timestamp: close.timestamp.addingTimeInterval(-Double($0) * 600), price: 1, previousClose: 1, symbol: "AV.L")
            }
        }

        for stored in [daily, dense] {
            let thinned = HistoricalDataManager.thinnedPriceHistory(stored, now: now, calendar: calendar)

            XCTAssertEqual(thinned.count, 3_000)
            // An eighth is the most the thinning leaves; the rest of the
            // allowance is the allocator rounding a block up.
            XCTAssertLessThan(thinned.capacity, 3_000 + 3_000 / 8 + 256, "\(stored.count) stored points")
        }
    }

    func testAFullPriceSeriesGrowsByAStepAndDoesNotDouble() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func point(_ index: Int) -> PriceSnapshot {
            PriceSnapshot(timestamp: start.addingTimeInterval(Double(index) * 60), price: 1, previousClose: 1, symbol: "AV.L")
        }
        var fitted: [PriceSnapshot] = []
        fitted.reserveCapacity(3_000)
        fitted.append(contentsOf: (0..<3_000).map(point))
        // Held the way the app holds it: in a dictionary keyed by symbol.
        var series = ["AV.L": fitted]
        fitted = []
        let step = HistoricalDataManager.priceHistoryGrowthStep
        var largestSlack = 0

        for index in 3_000..<4_000 {
            HistoricalDataManager.appendToPriceHistory(point(index), &series["AV.L", default: []])
            largestSlack = max(largestSlack, series["AV.L"]!.capacity - series["AV.L"]!.count)
        }

        XCTAssertEqual(series["AV.L"]?.count, 4_000)
        XCTAssertEqual(series["AV.L"]?.map(\.timestamp), (0..<4_000).map { point($0).timestamp })
        // The step, plus the allocator rounding a block up. Doubling at the
        // first append would have left room for 3000 more.
        XCTAssertGreaterThanOrEqual(largestSlack, step - 1)
        XCTAssertLessThan(largestSlack, 1_000)

        var empty: [String: [PriceSnapshot]] = [:]
        HistoricalDataManager.appendToPriceHistory(point(0), &empty["NEW", default: []])
        XCTAssertEqual(empty["NEW"]?.count, 1)
    }

    func testMergePortfolioHistoryOnlyFillsDaysWithoutRecordedSnapshots() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = 86_400.0
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func snapshot(_ offset: Double, _ value: Double) -> HistoricalPortfolioSnapshot {
            HistoricalPortfolioSnapshot(
                date: base.addingTimeInterval(offset * day), totalValue: value, totalGains: 0,
                totalCost: value, currency: "GBP", portfolioComposition: [:]
            )
        }
        // Recorded: days 0-9 plus intraday samples on day 9; nothing on days 10-12.
        let recorded = (0..<10).map { snapshot(Double($0) + 0.5, 1_000) } + [snapshot(9.6, 1_010), snapshot(9.7, 1_020)]
        let recalculated = (0..<13).map { snapshot(Double($0) + 0.9, 2_000) }

        let merged = HistoricalDataManager.mergePortfolioHistory(existing: recorded, recalculated: recalculated, calendar: calendar)

        XCTAssertEqual(merged.count, recorded.count + 3, "Only days 10-12 are filled")
        XCTAssertEqual(merged.filter { $0.totalValue == 2_000 }.count, 3)
        XCTAssertEqual(merged.filter { $0.totalValue != 2_000 }.count, recorded.count, "Every recorded snapshot survives, intraday ones included")
        XCTAssertEqual(merged.map(\.date), merged.map(\.date).sorted())
        XCTAssertEqual(HistoricalDataManager.mergePortfolioHistory(existing: recorded, recalculated: []).count, recorded.count)
    }

    func testOldPortfolioHistoryKeepsOneSnapshotPerDayInMemory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)
        func snapshot(daysAgo: Double, value: Double) -> HistoricalPortfolioSnapshot {
            HistoricalPortfolioSnapshot(
                date: today.addingTimeInterval(-daysAgo * 86_400), totalValue: value, totalGains: 0,
                totalCost: value, currency: "GBP", portfolioComposition: [:]
            )
        }
        // Three intraday samples on an old day and on a recent day.
        let old = [snapshot(daysAgo: 99.8, value: 1), snapshot(daysAgo: 99.5, value: 2), snapshot(daysAgo: 99.2, value: 3)]
        let recent = [snapshot(daysAgo: 4.8, value: 4), snapshot(daysAgo: 4.5, value: 5), snapshot(daysAgo: 4.2, value: 6)]

        let thinned = HistoricalDataManager.thinnedPortfolioHistory(
            (recent + old).shuffled(), fullResolutionDays: 90, now: now, calendar: calendar
        )

        XCTAssertEqual(thinned.map(\.totalValue), [3, 4, 5, 6], "Old days keep their last snapshot; recent days keep every sample")
    }

    func testPortfolioCompositionHashIsStableAcrossLaunches() {
        let positions = [
            PortfolioPosition(symbol: "SSE.L", units: 10, avgCost: 15, currency: "GBP"),
            PortfolioPosition(symbol: "AV.L", units: 5, avgCost: 4.8, currency: "GBP"),
        ]
        let hash = PortfolioComposition(positions: positions).compositionHash
        XCTAssertEqual(hash, PortfolioComposition(positions: positions.reversed()).compositionHash)
        XCTAssertEqual(hash.count, 64, "A SHA-256 hex digest, not the per-process hashValue")
        XCTAssertNotEqual(hash, PortfolioComposition(positions: Array(positions.prefix(1))).compositionHash)
    }
}

@MainActor
final class DataIntegrityGuardTests: XCTestCase {
    func testBackupCleanupAlwaysKeepsTheNewestBackups() {
        let now = Date()
        let backups = (0..<8).map { index in
            (url: URL(fileURLWithPath: "/tmp/portfolio_backup_\(index).json"),
             created: now.addingTimeInterval(-Double(index) * 40 * 86_400))
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400)

        let deleted = BackupService.backupsToDelete(backups, cutoff: cutoff, minimumKept: 5, keeping: backups[6].url)

        // All but the newest are past the cutoff; the newest five and the kept file survive.
        XCTAssertEqual(deleted.map(\.lastPathComponent), ["portfolio_backup_5.json", "portfolio_backup_7.json"])
        XCTAssertTrue(BackupService.backupsToDelete(Array(backups.suffix(3)), cutoff: cutoff, minimumKept: 5, keeping: nil).isEmpty)
    }

    func testAnnotationDecodingKeepsReadableEntries() throws {
        let good = ChartAnnotation(type: .note, date: Date(timeIntervalSince1970: 1_700_000_000), price: 10, text: "Kept", symbol: "TEST")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let data = Data("[\(goodJSON), {\"unexpected\": true}]".utf8)

        let decoded = try ChartAnnotationService.decodeAnnotations(from: data)

        XCTAssertEqual(decoded.annotations.map(\.text), ["Kept"])
        XCTAssertEqual(decoded.droppedCount, 1)
    }

    func testAnnotationsSurviveAReloadFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockbarTests-Annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chart_annotations.json")

        let first = ChartAnnotationService(storageURL: url)
        let kept = ChartAnnotation(type: .buyMarker, date: Date(timeIntervalSince1970: 1_700_000_000), price: 12.5, text: "Bought", symbol: "AAA")
        let removed = ChartAnnotation(type: .note, date: Date(timeIntervalSince1970: 1_700_100_000), price: 13, text: "Gone", symbol: "AAA")
        let other = ChartAnnotation(type: .text, date: Date(timeIntervalSince1970: 1_700_200_000), price: 1, text: "Other", symbol: "BBB")
        first.addAnnotation(kept)
        first.addAnnotation(removed)
        first.addAnnotation(other)
        first.removeAnnotation(id: removed.id)
        first.clearAnnotations(for: "BBB")

        let reloaded = ChartAnnotationService(storageURL: url)
        XCTAssertEqual(reloaded.annotations, [kept])
    }

    func testBackupFileRestoresThePortfolioAndSkipsBenchmarks() async throws {
        let backups = try BackupService.shared.getBackupDirectory()
        let realRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stockbar", isDirectory: true).standardizedFileURL.path
        guard !backups.standardizedFileURL.path.hasPrefix(realRoot) else {
            return XCTFail("Backups must go to the isolated test root, not \(realRoot)")
        }
        let before = Set(BackupService.shared.listAvailableBackups().map(\.url))

        let holding = RealTimeTrade(
            trade: Trade(name: "VOD.L", position: Position(unitSize: "12.345678", positionAvgCost: "71.25", currency: "GBP", costCurrency: "GBX")),
            realTimeInfo: TradingInfo()
        )
        let benchmark = RealTimeTrade(
            trade: Trade(name: "^GSPC", position: Position(unitSize: "0", positionAvgCost: "", currency: "USD", costCurrency: "USD")),
            realTimeInfo: TradingInfo()
        )
        let saved = await BackupService.shared.performManualBackup(trades: [holding, benchmark])
        XCTAssertTrue(saved)

        let created = BackupService.shared.listAvailableBackups().map(\.url).filter { !before.contains($0) }
        defer { created.forEach { try? FileManager.default.removeItem(at: $0) } }
        let backupURL = try XCTUnwrap(created.first)

        let restored = try await BackupService.shared.restoreFromBackup(backupURL: backupURL)
        XCTAssertEqual(restored.map(\.name), ["VOD.L"], "Benchmarks are internal rows and are not backed up")
        let position = try XCTUnwrap(restored.first?.position)
        XCTAssertEqual(position.unitSize, 12.345678, accuracy: 1e-9)
        XCTAssertEqual(position.costCurrency, "GBX")
        XCTAssertEqual(position.currency, "GBP")
    }

    func testPriceSanitiserAcceptsLargeRealQuotes() {
        let service = DataValidationService.shared
        XCTAssertEqual(service.sanitizePrice(1_520_000), 1_520_000)
        XCTAssertNil(service.sanitizePrice(.infinity))
        XCTAssertNil(service.sanitizePrice(DataValidationService.maximumPlausiblePrice * 10))
    }

    func testLeakScanSeesRawSecretsThatRedactionWouldHide() {
        let raw = "ERROR 403 url=https://financialmodelingprep.com/api/v3/quote/MU?apikey=raw-secret"
        let rawSnapshot = RuntimeIssueMonitor.scan(logs: [raw])
        let redactedSnapshot = RuntimeIssueMonitor.scan(logs: [LogRedactor.redact(raw)])
        XCTAssertEqual(rawSnapshot.secretLeakCount, 1)
        XCTAssertEqual(redactedSnapshot.secretLeakCount, 0)
    }
}
