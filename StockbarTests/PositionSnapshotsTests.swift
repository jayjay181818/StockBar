import XCTest
@testable import Stockbar

/// The positions a portfolio snapshot carries are a sorted array that has to
/// behave like the dictionary it replaced.
final class PositionSnapshotsTests: XCTestCase {
    private func position(_ symbol: String, units: Double = 1) -> PositionSnapshot {
        PositionSnapshot(symbol: symbol, units: units, priceAtDate: 10, valueAtDate: units * 10, currency: "USD")
    }

    func testPositionsAreFoundBySymbolWhateverOrderTheyWereGivenIn() {
        let symbols = ["MSFT", "AAPL", "VOD.L", "^GSPC", "BRK-B", "aapl", "ZM", "A"]

        let positions = PositionSnapshots(
            firstValuesFor: symbols.enumerated().map { position($0.element, units: Double($0.offset + 1)) }
        )

        XCTAssertEqual(positions.count, symbols.count)
        XCTAssertEqual(positions.symbols, symbols.sorted())
        XCTAssertEqual(positions.map(\.symbol), symbols.sorted())
        for (index, symbol) in symbols.enumerated() {
            XCTAssertEqual(positions[symbol]?.units, Double(index + 1), symbol)
        }
        for missing in ["", "AAP", "AAPLX", "ZZZ", "0"] {
            XCTAssertNil(positions[missing], missing)
        }
    }

    func testLookupsAgreeWithADictionaryForManySetsOfSymbols() {
        let universe = (0..<40).map { "S\($0 % 7)\($0)" } + ["", "É", "E\u{301}", "^IDX"]
        var state: UInt64 = 0x5EED
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }

        for _ in 0..<200 {
            let given = (0..<Int(next() % 25)).map { index in
                position(universe[Int(next() % UInt64(universe.count))], units: Double(index + 1))
            }
            let expected = Dictionary(given.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })

            let positions = PositionSnapshots(firstValuesFor: given)

            XCTAssertEqual(positions.count, expected.count)
            XCTAssertEqual(positions.symbols, expected.keys.sorted())
            for symbol in universe {
                XCTAssertEqual(positions[symbol]?.units, expected[symbol]?.units, symbol)
            }
            let fromDictionary = PositionSnapshots(expected)
            XCTAssertEqual(fromDictionary.map(\.units), positions.map(\.units))
        }
    }

    func testAnEmptySetHoldsNothing() {
        let positions = PositionSnapshots()

        XCTAssertTrue(positions.isEmpty)
        XCTAssertEqual(positions.symbols, [])
        XCTAssertNil(positions["AAPL"])
    }

    func testARepeatedSymbolKeepsItsFirstPosition() {
        let positions = PositionSnapshots(firstValuesFor: [
            position("B", units: 1), position("A", units: 2), position("B", units: 3),
            position("A", units: 4), position("C", units: 5)
        ])

        XCTAssertEqual(positions.symbols, ["A", "B", "C"])
        XCTAssertEqual(positions.map(\.units), [2, 1, 5])
    }

    func testADictionaryEntryIsFoundUnderItsKey() {
        let positions = PositionSnapshots(["KEY": position("OTHER", units: 7), "SAME": position("SAME", units: 8)])

        XCTAssertEqual(positions.symbols, ["KEY", "SAME"])
        XCTAssertEqual(positions["KEY"]?.units, 7)
        XCTAssertEqual(positions["KEY"]?.symbol, "KEY")
        XCTAssertNil(positions["OTHER"])
    }

    func testFilteringKeepsLookupBySymbol() {
        let positions = PositionSnapshots(firstValuesFor: ["AAPL", "^GSPC", "MSFT", "^FTSE"].map { position($0) })

        let held = positions.filter { !$0.symbol.hasPrefix("^") }

        XCTAssertEqual(held.symbols, ["AAPL", "MSFT"])
        XCTAssertEqual(held["MSFT"]?.units, 1)
        XCTAssertNil(held["^GSPC"])
    }

    /// Legacy caches and anything else written as JSON hold the positions as a
    /// dictionary keyed by symbol, and that must not change.
    func testASnapshotIsReadAndWrittenAsADictionaryKeyedBySymbol() throws {
        struct DictionaryShape: Codable {
            let date: Date
            let totalValue: Double
            let totalGains: Double
            let totalCost: Double
            let currency: String
            let portfolioComposition: [String: PositionSnapshot]
        }
        let json = Data("""
        {"date":0,"totalValue":30,"totalGains":5,"totalCost":25,"currency":"GBP","portfolioComposition":{
          "MSFT":{"symbol":"MSFT","units":2,"priceAtDate":10,"valueAtDate":20,"currency":"USD"},
          "AAPL":{"symbol":"AAPL","units":1,"priceAtDate":10,"valueAtDate":10,"currency":"USD"}}}
        """.utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let snapshot = try JSONDecoder().decode(HistoricalPortfolioSnapshot.self, from: json)
        let written = try encoder.encode(snapshot)

        XCTAssertEqual(snapshot.portfolioComposition.symbols, ["AAPL", "MSFT"])
        XCTAssertEqual(snapshot.portfolioComposition["MSFT"]?.valueAtDate, 20)
        let asDictionary = try encoder.encode(JSONDecoder().decode(DictionaryShape.self, from: json))
        XCTAssertEqual(String(decoding: written, as: UTF8.self), String(decoding: asDictionary, as: UTF8.self))
    }

    func testASnapshotWithNoPositionsIsWrittenWithAnEmptyDictionary() throws {
        let snapshot = HistoricalPortfolioSnapshot(
            date: Date(timeIntervalSinceReferenceDate: 0), totalValue: 0, totalGains: 0, totalCost: 0,
            currency: "USD", portfolioComposition: PositionSnapshots()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let written = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        let readBack = try JSONDecoder().decode(HistoricalPortfolioSnapshot.self, from: Data(written.utf8))

        XCTAssertTrue(written.contains("\"portfolioComposition\":{}"), written)
        XCTAssertTrue(readBack.portfolioComposition.isEmpty)
    }
}
