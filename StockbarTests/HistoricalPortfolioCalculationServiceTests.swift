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
        XCTAssertEqual(snapshot.portfolioComposition.keys.sorted(), ["GOOD"])
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
