import Combine
import XCTest
@testable import Stockbar

/// Stored price history is read away from the main actor and then taken into
/// memory. These pin what the read returns, how it is merged with points
/// recorded meanwhile, and that rows read before the store changed underneath
/// are not taken.
@MainActor
final class StoredPriceHistoryAdoptionTests: XCTestCase {
    private typealias StoredPriceHistory = HistoricalDataManager.StoredPriceHistory

    private let held = "ZZADOPTHELD"
    private let other = "ZZADOPTOTHER"
    private var manager: HistoricalDataManager { .shared }

    override func setUp() async throws {
        try await super.setUp()
        // The shared manager reads its own store when it is first used. Let
        // that finish, so that it cannot land between a test's steps.
        for _ in 0..<500 where !manager.hasLoadedStoredPortfolioHistory {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(manager.hasLoadedStoredPortfolioHistory)
    }

    override func tearDown() async throws {
        for symbol in [held, other] { manager.priceSnapshots.removeValue(forKey: symbol) }
        try await super.tearDown()
    }

    // MARK: - The read

    func testTheReadIsNilWhenTheStoreCannotListItsSymbols() async {
        let read = await HistoricalDataManager.readStoredPriceHistory(for: nil, from: StoredHistoryStub(symbols: nil))
        XCTAssertNil(read)

        manager.priceSnapshots[held] = [point(daysAgo: 1, hour: 10, price: 7)]
        await manager.adoptStoredPriceHistory(read, readAfter: manager.priceInvalidationCount)
        XCTAssertEqual(manager.priceSnapshots[held]?.map(\.price), [7])
    }

    func testTheReadSkipsSymbolsWithoutRowsAndSymbolsThatFailButCountsThem() async throws {
        let rows = [
            point(daysAgo: 90, hour: 9, price: 1), point(daysAgo: 90, hour: 15, price: 2),
            point(daysAgo: 1, hour: 10, price: 3),
        ]
        let stub = StoredHistoryStub(
            symbols: [held, other, "ZZADOPTFAILS"], prices: [held: rows, other: [], "ZZADOPTFAILS": nil]
        )

        let read = await HistoricalDataManager.readStoredPriceHistory(for: nil, from: stub)

        let history = try XCTUnwrap(read)
        XCTAssertEqual(history.symbolCount, 3)
        XCTAssertEqual(history.series.map(\.symbol), [held])
        // Thinned: the last point of the old day, and every recent one.
        XCTAssertEqual(history.series.first?.snapshots.map(\.price), [2, 3])
    }

    func testTheReadLooksUpOnlyTheSymbolsAskedFor() async throws {
        let stub = StoredHistoryStub(symbols: nil, prices: [held: [point(daysAgo: 1, hour: 10, price: 4)]])

        let read = await HistoricalDataManager.readStoredPriceHistory(for: [held], from: stub)

        let history = try XCTUnwrap(read)
        XCTAssertEqual(history.symbolCount, 1)
        XCTAssertEqual(history.series.first?.snapshots.map(\.price), [4])
    }

    func testThePortfolioReadIsEmptyWhenTheFetchFails() async {
        let snapshots = await HistoricalDataManager.readPortfolioSnapshots(
            timeRange: .all, from: StoredHistoryStub(portfolio: nil)
        )
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testThePortfolioValuesReadIsEmptyWhenTheFetchFails() async {
        let values = await HistoricalDataManager.readPortfolioValues(
            timeRange: .all, from: StoredHistoryStub(portfolio: nil)
        )
        XCTAssertTrue(values.isEmpty)
    }

    // MARK: - Taking the read into memory

    func testWithNothingInMemoryTheStoredSeriesIsTakenAsItIsAndEachSymbolIsNoted() async {
        var noted: [Set<String>] = []
        let subscription = manager.priceDataChanges.sink { if let keys = $0 { noted.append(keys) } }
        defer { subscription.cancel() }

        await manager.adoptStoredPriceHistory(
            StoredPriceHistory(symbolCount: 3, series: [
                (held, [point(daysAgo: 90, hour: 16, price: 1), point(daysAgo: 1, hour: 10, price: 2)]),
                (other, [point(daysAgo: 1, hour: 11, price: 3, symbol: other)]),
            ]),
            readAfter: manager.priceInvalidationCount
        )

        XCTAssertEqual(manager.priceSnapshots[held]?.map(\.price), [1, 2])
        XCTAssertEqual(manager.priceSnapshots[other]?.map(\.price), [3])
        XCTAssertEqual(noted.filter { $0.contains(held) }.count, 1)
        XCTAssertEqual(noted.filter { $0.contains(other) }.count, 1)
    }

    func testAdoptingThinnedRowsGivesWhatMergingTheUnthinnedRowsGave() async {
        // Stored: three points on one old day, two on another, and two recent.
        let stored = [
            point(daysAgo: 90, hour: 9, price: 10), point(daysAgo: 90, hour: 12, price: 11),
            point(daysAgo: 90, hour: 16, price: 12),
            point(daysAgo: 60, hour: 9, price: 20), point(daysAgo: 60, hour: 16, price: 21),
            point(daysAgo: 2, hour: 10, price: 30), point(daysAgo: 1, hour: 10, price: 31),
        ]
        // Recorded in memory while the read ran.
        let inMemory = [
            point(daysAgo: 90, hour: 12, price: 911),  // at a stored row that thinning drops
            point(daysAgo: 90, hour: 16, price: 912),  // at a stored row that thinning keeps
            point(daysAgo: 75, hour: 11, price: 950),  // on an old day the store has nothing for
            point(daysAgo: 60, hour: 18, price: 921),  // later than the store's last point of its day
            point(daysAgo: 1, hour: 10, price: 931),   // at a recent stored row
            point(daysAgo: 1, hour: 14, price: 932),   // a new recent point
        ]
        // The merge as it was when the unthinned rows were merged on the main actor.
        let storedKeys = Set(stored.map { manager.snapshotTimestampKey($0.timestamp) })
        let expected = HistoricalDataManager.thinnedPriceHistory(
            stored + inMemory.filter { !storedKeys.contains(manager.snapshotTimestampKey($0.timestamp)) }
        )

        manager.priceSnapshots[held] = inMemory
        await manager.adoptStoredPriceHistory(
            StoredPriceHistory(symbolCount: 1, series: [(held, HistoricalDataManager.thinnedPriceHistory(stored))]),
            readAfter: manager.priceInvalidationCount
        )

        let merged = manager.priceSnapshots[held] ?? []
        XCTAssertEqual(merged.map(\.timestamp), expected.map(\.timestamp))
        XCTAssertEqual(merged.map(\.price), expected.map(\.price))
        XCTAssertEqual(merged.map(\.price), [12, 950, 921, 30, 31, 932])
    }

    // MARK: - Rows read before the store changed underneath

    func testRowsReadBeforeAnInvalidationAreNotTakenOverTheReload() async {
        // A read that began before a repair of the store holds the old rows.
        let readBegan = manager.priceInvalidationCount
        let oldRows = StoredPriceHistory(symbolCount: 2, series: [
            (held, [point(daysAgo: 1, hour: 10, price: 12_300)]),
            (other, [point(daysAgo: 1, hour: 10, price: 5, symbol: other)]),
        ])

        // The repair rewrites the rows where they are, invalidates and reloads.
        manager.invalidatePriceData(for: [held.lowercased()])
        await manager.adoptStoredPriceHistory(
            StoredPriceHistory(symbolCount: 1, series: [(held, [point(daysAgo: 1, hour: 10, price: 123)])]),
            readAfter: manager.priceInvalidationCount
        )
        await manager.adoptStoredPriceHistory(oldRows, readAfter: readBegan)

        XCTAssertEqual(manager.priceSnapshots[held]?.map(\.price), [123])
        XCTAssertEqual(manager.priceSnapshots[other]?.map(\.price), [5], "A symbol that was not invalidated is still taken.")
    }

    func testRowsReadBeforeAnInvalidationAreNotTakenAheadOfTheReloadEither() async {
        let readBegan = manager.priceInvalidationCount
        let oldRows = StoredPriceHistory(symbolCount: 1, series: [(held, [point(daysAgo: 1, hour: 10, price: 12_300)])])

        manager.invalidatePriceData(for: [held])
        await manager.adoptStoredPriceHistory(oldRows, readAfter: readBegan)
        XCTAssertNil(manager.priceSnapshots[held])

        await manager.adoptStoredPriceHistory(
            StoredPriceHistory(symbolCount: 1, series: [(held, [point(daysAgo: 1, hour: 10, price: 123)])]),
            readAfter: manager.priceInvalidationCount
        )
        XCTAssertEqual(manager.priceSnapshots[held]?.map(\.price), [123])
    }

    // MARK: - Helpers

    /// A point `hour` hours into the calendar day `daysAgo` days back: 90 and 60
    /// are thinned to a point a day, 2 and 1 are kept whole.
    private func point(daysAgo: Int, hour: Double, price: Double, symbol: String? = nil) -> PriceSnapshot {
        let day = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
        return PriceSnapshot(
            timestamp: day.addingTimeInterval(hour * 3_600), price: price, previousClose: price, symbol: symbol ?? held
        )
    }
}

/// A store that answers from fixed values. Nil stands for a fetch that throws.
private struct StoredHistoryStub: HistoricalDataServiceProtocol {
    struct Unavailable: Error {}

    var symbols: [String]? = []
    var prices: [String: [PriceSnapshot]?] = [:]
    var portfolio: [HistoricalPortfolioSnapshot]? = []

    func fetchStoredPriceSymbols() async throws -> [String] {
        guard let symbols else { throw Unavailable() }
        return symbols
    }

    func fetchAllPriceSnapshots(for symbol: String) async throws -> [PriceSnapshot] {
        guard let answer = prices[symbol] else { return [] }
        guard let stored = answer else { throw Unavailable() }
        return stored
    }

    func fetchPortfolioSnapshots(from startDate: Date, to endDate: Date) async throws -> [HistoricalPortfolioSnapshot] {
        guard let portfolio else { throw Unavailable() }
        return portfolio
    }

    func fetchPortfolioValues(from startDate: Date, to endDate: Date) async throws -> [StoredPortfolioValue] {
        guard let portfolio else { throw Unavailable() }
        return portfolio.map { StoredPortfolioValue(date: $0.date, totalValue: $0.totalValue, currency: $0.currency) }
    }

    // The launch read uses none of these.
    func savePriceSnapshots(_ snapshots: [PriceSnapshot]) async throws {}
    func fetchPriceSnapshots(for symbol: String, from startDate: Date, to endDate: Date) async throws -> [PriceSnapshot] { [] }
    func savePortfolioSnapshot(_ snapshot: HistoricalPortfolioSnapshot) async throws {}
    func fetchAllPortfolioSnapshots() async throws -> [HistoricalPortfolioSnapshot] { [] }
    func getDataCount(for symbol: String) async throws -> Int { 0 }
    func getTotalPriceSnapshotCount() async throws -> Int { 0 }
    func getPortfolioSnapshotCount() async throws -> Int { 0 }
}
