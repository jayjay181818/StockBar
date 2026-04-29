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
}
