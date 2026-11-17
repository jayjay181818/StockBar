import XCTest
@testable import Stockbar

final class ChartSeriesProcessingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func series(_ values: [Double]) -> [ChartDataPoint] {
        values.enumerated().map { index, value in
            ChartDataPoint(date: epoch.addingTimeInterval(Double(index) * 60), value: value)
        }
    }

    // MARK: - Downsampling

    func testDownsampleLeavesSmallSeriesUntouched() {
        let points = series((0..<900).map(Double.init))
        XCTAssertEqual(ChartSeriesProcessing.downsample(points).count, 900)
    }

    func testDownsampleKeepsFirstAndLastPoints() {
        let points = series((0..<2_501).map { Double($0 % 7) })
        let sampled = ChartSeriesProcessing.downsample(points)
        XCTAssertLessThan(sampled.count, points.count)
        XCTAssertEqual(sampled.first?.date, points.first?.date)
        XCTAssertEqual(sampled.last?.date, points.last?.date)
        XCTAssertEqual(sampled.last?.value, points.last?.value)
    }

    func testDownsampleKeepsPriceExtremesAndStaysWithinTarget() {
        var values = (0..<5_000).map { 100 + sin(Double($0) / 40) * 5 }
        values[1_234] = 400   // spike a stride sampler would usually skip
        values[3_777] = -250  // and a trough
        let points = series(values)
        let sampled = ChartSeriesProcessing.downsample(points, threshold: 1_000, target: 800)

        XCTAssertLessThanOrEqual(sampled.count, 800)
        XCTAssertEqual(sampled.map(\.value).max(), 400)
        XCTAssertEqual(sampled.map(\.value).min(), -250)
        XCTAssertEqual(sampled.map(\.date), sampled.map(\.date).sorted(), "Output stays in date order")
    }

    func testDownsampleBucketSizeRoundsUp() {
        // 1_001 points would stride by 1 with floor division (no thinning); ceil buckets still cap the result.
        let points = series((0..<1_001).map { Double($0 % 13) })
        let sampled = ChartSeriesProcessing.downsample(points, threshold: 1_000, target: 800)
        XCTAssertLessThanOrEqual(sampled.count, 800)
        XCTAssertEqual(sampled.last?.date, points.last?.date)
    }

    // MARK: - Custom dates and filters

    func testCustomRangeIsWholeDaysWithExclusiveUpperBound() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15, minute: 42))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9, minute: 5))!

        let range = ChartSeriesProcessing.normalizedCustomRange(start: start, end: end, calendar: calendar)

        XCTAssertEqual(range.from, calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!)
        XCTAssertEqual(range.toExclusive, calendar.date(from: DateComponents(year: 2026, month: 3, day: 13))!)
    }

    func testCustomRangeSingleDayAndReversedDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 18))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 6))!

        let single = ChartSeriesProcessing.normalizedCustomRange(start: day, end: day, calendar: calendar)
        XCTAssertEqual(single.toExclusive.timeIntervalSince(single.from), 86_400)

        let reversed = ChartSeriesProcessing.normalizedCustomRange(start: day, end: earlier, calendar: calendar)
        XCTAssertEqual(reversed.from, calendar.startOfDay(for: earlier))
    }

    func testFiltersApplyThresholdAndExclusiveUpperBound() {
        let points = series([1, 5, 10, 20])
        let window = (from: epoch, toExclusive: epoch.addingTimeInterval(120))
        let filtered = ChartSeriesProcessing.applyFilters(points, valueThreshold: 4, dateWindow: window)
        // Index 2 sits exactly on the exclusive bound and index 0 fails the threshold.
        XCTAssertEqual(filtered.map(\.value), [5])
    }

    func testIsSameSeriesIgnoresRegeneratedIDs() {
        let first = series([1, 2, 3])
        let second = series([1, 2, 3])
        XCTAssertNotEqual(first.map(\.id), second.map(\.id))
        XCTAssertTrue(ChartSeriesProcessing.isSameSeries(first, second))
        XCTAssertFalse(ChartSeriesProcessing.isSameSeries(first, series([1, 2, 4])))
        XCTAssertFalse(ChartSeriesProcessing.isSameSeries(first, series([1, 2])))
    }

    // MARK: - Selection and export

    func testSelectionSurvivesReloadByDate() {
        let old = series([1, 2, 3, 4])
        let new = series([1, 2, 3, 4])
        let selected: Set<UUID> = [old[1].id, old[3].id]

        let remapped = ChartSeriesProcessing.remapSelection(selected: selected, oldData: old, newData: new)

        XCTAssertEqual(remapped, [new[1].id, new[3].id])
        XCTAssertTrue(ChartSeriesProcessing.remapSelection(selected: [], oldData: old, newData: new).isEmpty)
    }

    func testExportUsesFullResolutionAndNeverReturnsEmptyForStaleSelection() {
        let full = series((0..<3_000).map(Double.init))
        let displayed = ChartSeriesProcessing.downsample(full)

        XCTAssertEqual(ChartSeriesProcessing.exportSeries(full: full, displayed: displayed, selected: []).count, 3_000)
        // A selection whose ids no longer exist must not produce an empty export.
        XCTAssertEqual(ChartSeriesProcessing.exportSeries(full: full, displayed: displayed, selected: [UUID()]).count, 3_000)
    }

    func testExportOfSelectionInDownsampledSeriesCoversSelectedSpanInFull() {
        let full = series((0..<3_000).map(Double.init))
        let displayed = ChartSeriesProcessing.downsample(full)
        let selected = Set(displayed.filter { $0.date >= full[1_000].date && $0.date <= full[1_500].date }.map(\.id))

        let exported = ChartSeriesProcessing.exportSeries(full: full, displayed: displayed, selected: selected)

        XCTAssertGreaterThan(exported.count, selected.count)
        XCTAssertTrue(exported.allSatisfy { $0.date >= (displayed.filter { selected.contains($0.id) }.map(\.date).min()!) })
    }

    func testExportOfSelectionWithoutDownsamplingIsExactPoints() {
        let full = series([1, 2, 3, 4, 5])
        let selected: Set<UUID> = [full[0].id, full[4].id]
        let exported = ChartSeriesProcessing.exportSeries(full: full, displayed: full, selected: selected)
        XCTAssertEqual(exported.map(\.value), [1, 5])
    }

    // MARK: - Dates

    func testDayGranularDetectionUsesUTCMidnight() {
        XCTAssertTrue(ChartSeriesProcessing.isDayGranular(Date(timeIntervalSince1970: 1_767_225_600))) // 2026-01-01T00:00:00Z
        XCTAssertFalse(ChartSeriesProcessing.isDayGranular(Date(timeIntervalSince1970: 1_767_225_600 + 3_600)))
        XCTAssertFalse(ChartSeriesProcessing.isDayGranular([ChartDataPoint]()))
    }

    func testNearestIndexAndPaddedDomain() {
        let dates = (0..<5).map { epoch.addingTimeInterval(Double($0) * 100) }
        XCTAssertEqual(ChartSeriesProcessing.nearestIndex(in: dates, to: epoch.addingTimeInterval(260)), 3)
        XCTAssertNil(ChartSeriesProcessing.nearestIndex(in: [], to: epoch))

        let domain = ChartSeriesProcessing.paddedDateDomain(dates)
        XCTAssertEqual(domain?.lowerBound, epoch.addingTimeInterval(-50))
        XCTAssertEqual(domain?.upperBound, epoch.addingTimeInterval(450))
        XCTAssertNotNil(ChartSeriesProcessing.paddedDateDomain([epoch]))
        XCTAssertNil(ChartSeriesProcessing.paddedDateDomain([]))
    }
}

final class ChartHitTestingTests: XCTestCase {
    func testPlotPointSubtractsPlotAreaOrigin() {
        let plotPoint = ChartHitTesting.plotPoint(fromViewPoint: CGPoint(x: 70, y: 40), plotOrigin: CGPoint(x: 20, y: 10))
        XCTAssertEqual(plotPoint, CGPoint(x: 50, y: 30))
    }

    func testBoxSelectionUsesTopLeftOriginAndPlotOffset() {
        let nearTop = (id: UUID(), point: CGPoint(x: 50, y: 10))     // plot space, y grows downwards
        let nearBottom = (id: UUID(), point: CGPoint(x: 50, y: 150))
        let outsideX = (id: UUID(), point: CGPoint(x: 300, y: 10))
        let origin = CGPoint(x: 30, y: 8)

        // A box drawn near the top of the view (view space = plot space + origin).
        let topBox = CGRect(x: 60, y: 8, width: 40, height: 30)
        let selectedTop = ChartHitTesting.selectedIDs(
            inViewRect: topBox, plotOrigin: origin, positions: [nearTop, nearBottom, outsideX]
        )
        XCTAssertEqual(selectedTop, [nearTop.id])

        let bottomBox = CGRect(x: 60, y: 140, width: 40, height: 30)
        let selectedBottom = ChartHitTesting.selectedIDs(
            inViewRect: bottomBox, plotOrigin: origin, positions: [nearTop, nearBottom, outsideX]
        )
        XCTAssertEqual(selectedBottom, [nearBottom.id])
    }
}

final class MenuChartSeriesAlignmentTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ offset: TimeInterval, _ price: Double) -> MenuChartDataPoint {
        MenuChartDataPoint(date: epoch.addingTimeInterval(offset), price: price, symbol: "X")
    }

    func testComparisonIsClippedAndRebasedToThePrimaryWindow() {
        let window = epoch.addingTimeInterval(100)...epoch.addingTimeInterval(300)
        // The benchmark has history before and after the primary window.
        let benchmark = [point(0, 50), point(100, 100), point(200, 110), point(300, 90), point(400, 500)]

        let series = MenuChartSeriesAlignment.percentSeries(benchmark, window: window)

        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].value, 0, accuracy: 1e-9)
        XCTAssertEqual(series[1].value, 0.10, accuracy: 1e-9)
        XCTAssertEqual(series[2].value, -0.10, accuracy: 1e-9)
        XCTAssertEqual(series.first?.time, epoch.addingTimeInterval(100).timeIntervalSince1970)
        XCTAssertEqual(series.last?.time, epoch.addingTimeInterval(300).timeIntervalSince1970)
    }

    func testEarlierBenchmarkValueIsCarriedToTheWindowStart() {
        let window = epoch.addingTimeInterval(100)...epoch.addingTimeInterval(300)
        let benchmark = [point(0, 80), point(200, 88)]

        let series = MenuChartSeriesAlignment.percentSeries(benchmark, window: window)

        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].time, epoch.addingTimeInterval(100).timeIntervalSince1970)
        XCTAssertEqual(series[0].value, 0, accuracy: 1e-9)
        XCTAssertEqual(series[1].value, 0.10, accuracy: 1e-9)
    }

    func testSeriesStartingInsideWindowRebasesToItsFirstPoint() {
        let window = epoch...epoch.addingTimeInterval(300)
        let series = MenuChartSeriesAlignment.percentSeries([point(100, 200), point(200, 220)], window: window)
        assertClose(series.map { $0.value }, [0, 0.10], accuracy: 1e-9)
    }

    func testPercentFormatterUsesLocaleAndSign() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(MenuPopoverFormatter.percent(1.5, locale: german).replacingOccurrences(of: "\u{00A0}", with: " "), "+1,50 %")
        XCTAssertTrue(MenuPopoverFormatter.percent(-2.25, locale: Locale(identifier: "en_US")).hasPrefix("-"))
        XCTAssertTrue(MenuPopoverFormatter.percent(1.5, locale: Locale(identifier: "en_US")).hasPrefix("+"))
        XCTAssertEqual(MenuPopoverFormatter.percent(nil), "")
        XCTAssertEqual(MenuPopoverFormatter.percent(.nan), "")
    }
}

final class MenuPopoverCurveTests: XCTestCase {
    /// A day of prices a pixel apart, a night with none, then the next day:
    /// the shape that drew a hook either side of the night.
    private let twoSessions: [CGPoint] = {
        let evening = (0...10).map { CGPoint(x: CGFloat($0), y: 40 + CGFloat($0 % 3) * 4) }
        let morning = (0...10).map { CGPoint(x: 146 + CGFloat($0), y: 60 + CGFloat($0 % 4) * 5) }
        return evening + morning
    }()

    /// Where the curve from `points[index - 1]` to `points[index]` is, left to right, part of the way along it.
    private func curveX(_ points: [CGPoint], endingAt index: Int, at fraction: CGFloat) -> CGFloat {
        let controls = MenuPopoverLineChart.curveControls(points, endingAt: index)
        let rest = 1 - fraction
        return rest * rest * rest * points[index - 1].x
            + 3 * rest * rest * fraction * controls.first.x
            + 3 * rest * fraction * fraction * controls.second.x
            + fraction * fraction * fraction * points[index].x
    }

    func testTheLineNeverTurnsBackWhereTimeHasAGap() {
        for index in 1..<twoSessions.count {
            var previous = twoSessions[index - 1].x
            for step in 1...100 {
                let x = curveX(twoSessions, endingAt: index, at: CGFloat(step) / 100)
                XCTAssertGreaterThanOrEqual(x, previous - 1e-9, "piece \(index) moves back at step \(step)")
                previous = x
            }
        }
    }

    func testEveryPullStaysInsideItsOwnPieceOfTheLine() {
        for index in 1..<twoSessions.count {
            let controls = MenuPopoverLineChart.curveControls(twoSessions, endingAt: index)
            let start = twoSessions[index - 1].x
            let end = twoSessions[index].x
            XCTAssertGreaterThanOrEqual(controls.first.x, start - 1e-9, "piece \(index)")
            XCTAssertLessThanOrEqual(controls.first.x, controls.second.x + 1e-9, "piece \(index)")
            XCTAssertLessThanOrEqual(controls.second.x, end + 1e-9, "piece \(index)")
        }
    }

    func testAShortenedPullKeepsItsDirection() {
        // The last piece before the night: its far end is pulled towards the
        // first point of the morning, 136 pixels on.
        let index = 10
        let controls = MenuPopoverLineChart.curveControls(twoSessions, endingAt: index)
        let end = twoSessions[index]
        let towards = CGVector(dx: twoSessions[index + 1].x - twoSessions[index - 1].x,
                               dy: twoSessions[index + 1].y - twoSessions[index - 1].y)
        let pull = CGVector(dx: end.x - controls.second.x, dy: end.y - controls.second.y)
        XCTAssertEqual(pull.dx, (end.x - twoSessions[index - 1].x) / 3, accuracy: 1e-9)
        XCTAssertEqual(pull.dx * towards.dy - pull.dy * towards.dx, 0, accuracy: 1e-9)
    }

    func testEvenlySpacedPointsKeepTheCurveTheyHad() {
        let points = [12.0, 30, 18, 25, 40, 22].enumerated().map { CGPoint(x: CGFloat($0.offset) * 7, y: CGFloat($0.element)) }
        for index in 1..<points.count {
            let p0 = points[max(index - 2, 0)]
            let p1 = points[index - 1]
            let p2 = points[index]
            let p3 = points[min(index + 1, points.count - 1)]
            let controls = MenuPopoverLineChart.curveControls(points, endingAt: index)
            XCTAssertEqual(controls.first.x, p1.x + (p2.x - p0.x) / 6, accuracy: 1e-9)
            XCTAssertEqual(controls.first.y, p1.y + (p2.y - p0.y) / 6, accuracy: 1e-9)
            XCTAssertEqual(controls.second.x, p2.x - (p3.x - p1.x) / 6, accuracy: 1e-9)
            XCTAssertEqual(controls.second.y, p2.y - (p3.y - p1.y) / 6, accuracy: 1e-9)
        }
    }

    func testTwoPointsAtTheSameTimeAreJoinedByAStraightLine() {
        let points = [CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 12), CGPoint(x: 5, y: 20), CGPoint(x: 9, y: 15)]
        let controls = MenuPopoverLineChart.curveControls(points, endingAt: 2)
        XCTAssertEqual(controls.first.x, 5, accuracy: 1e-9)
        XCTAssertEqual(controls.first.y, 12, accuracy: 1e-9)
        XCTAssertEqual(controls.second.x, 5, accuracy: 1e-9)
        XCTAssertEqual(controls.second.y, 20, accuracy: 1e-9)
    }
}

private func assertClose(_ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
}

final class ChartAuditFixTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    // MARK: Axis domain

    func testPaddedDomainIgnoresValuesThatWouldCrashAScale() {
        let domain = ChartSeriesProcessing.paddedDomain([10, .nan, 20, .infinity, -.infinity])
        XCTAssertEqual(domain.lowerBound, 9.5, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 20.5, accuracy: 1e-9)
    }

    func testPaddedDomainIsNeverEmpty() {
        XCTAssertEqual(ChartSeriesProcessing.paddedDomain([]), 0...1)
        XCTAssertEqual(ChartSeriesProcessing.paddedDomain([.nan], fallback: 0...100), 0...100)
        let flat = ChartSeriesProcessing.paddedDomain([50, 50])
        XCTAssertLessThan(flat.lowerBound, 50)
        XCTAssertGreaterThan(flat.upperBound, 50)
    }

    // MARK: Zoom

    func testZoomedDomainIsNilAtNormalSize() {
        XCTAssertNil(ChartSeriesProcessing.zoomedDomain(
            first: epoch, last: epoch.addingTimeInterval(100), scale: 1, panFraction: 0
        ))
        XCTAssertNil(ChartSeriesProcessing.zoomedDomain(first: epoch, last: epoch, scale: 4, panFraction: 0))
    }

    func testZoomedDomainHalvesTheSpanAndStaysInsideTheSeries() throws {
        let last = epoch.addingTimeInterval(100)
        let centred = try XCTUnwrap(ChartSeriesProcessing.zoomedDomain(
            first: epoch, last: last, scale: 2, panFraction: 0
        ))
        XCTAssertEqual(centred.lowerBound, epoch.addingTimeInterval(25))
        XCTAssertEqual(centred.upperBound, epoch.addingTimeInterval(75))

        // Dragging right shows earlier dates, but never before the first point.
        let earliest = try XCTUnwrap(ChartSeriesProcessing.zoomedDomain(
            first: epoch, last: last, scale: 2, panFraction: 50
        ))
        XCTAssertEqual(earliest.lowerBound, epoch)
        XCTAssertEqual(earliest.upperBound, epoch.addingTimeInterval(50))
    }

    // MARK: Candle aggregation

    private func dailyCandles(_ count: Int) -> [OHLCDataPoint] {
        (0..<count).map { index in
            let price = 100 + Double(index)
            return OHLCDataPoint(
                timestamp: epoch.addingTimeInterval(Double(index) * day),
                open: price, high: price + 2, low: price - 3, close: price + 1, volume: 10
            )
        }
    }

    func testFewCandlesAreLeftAlone() {
        let candles = dailyCandles(50)
        XCTAssertEqual(ChartSeriesProcessing.aggregatedCandles(candles).map(\.id), candles.map(\.id))
    }

    func testManyDailyCandlesMergeIntoLongerPeriodsWithoutLosingExtremes() throws {
        let candles = dailyCandles(2_000)
        let merged = ChartSeriesProcessing.aggregatedCandles(candles)

        XCTAssertLessThanOrEqual(merged.count, ChartSeriesProcessing.maxCandles)
        XCTAssertGreaterThan(merged.count, 20)
        XCTAssertEqual(merged.first?.open, candles.first?.open)
        XCTAssertEqual(merged.last?.close, candles.last?.close)
        XCTAssertEqual(merged.map(\.high).max(), candles.map(\.high).max())
        XCTAssertEqual(merged.map(\.low).min(), candles.map(\.low).min())
        XCTAssertEqual(merged.compactMap(\.volume).reduce(0, +), 20_000)
        XCTAssertEqual(merged.map(\.timestamp), merged.map(\.timestamp).sorted())
    }

    func testIntradayCandlesMergeInEqualRuns() {
        let candles = (0..<900).map { index in
            OHLCDataPoint(
                timestamp: epoch.addingTimeInterval(Double(index) * 300),
                open: 1, high: Double(index), low: 0.5, close: 1, volume: nil
            )
        }
        let merged = ChartSeriesProcessing.aggregatedCandles(candles)
        XCTAssertEqual(merged.count, 300)
        XCTAssertEqual(merged.first?.high, 2)
        XCTAssertNil(merged.first?.volume)
    }

    // MARK: Comparison

    func testComparisonRebasesEverySeriesToTheFirstSharedDate() throws {
        let long = (0..<4).map { ChartDataPoint(date: epoch.addingTimeInterval(Double($0) * day), value: [50, 100, 110, 120][$0]) }
        let short = (2..<4).map { ChartDataPoint(date: epoch.addingTimeInterval(Double($0) * day), value: [200, 220][$0 - 2]) }
        let rebased = ChartSeriesProcessing.rebasedToCommonStart(["LONG": long, "SHORT": short])

        // LONG doubled before SHORT existed; that must not count in the comparison.
        let longSeries = try XCTUnwrap(rebased["LONG"])
        XCTAssertEqual(longSeries.count, 2)
        XCTAssertEqual(longSeries[0].value, 0, accuracy: 1e-9)
        XCTAssertEqual(longSeries[1].value, 120.0 / 110.0 - 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rebased["SHORT"]?.last).value, 0.1, accuracy: 1e-9)
    }

    func testComparisonDropsSeriesWithNothingUsable() {
        let rebased = ChartSeriesProcessing.rebasedToCommonStart([
            "EMPTY": [],
            "BAD": [ChartDataPoint(date: epoch, value: .nan)],
            "OK": [ChartDataPoint(date: epoch, value: 5), ChartDataPoint(date: epoch.addingTimeInterval(day), value: 6)]
        ])
        XCTAssertEqual(Array(rebased.keys), ["OK"])
    }

    // MARK: Popover downsampling

    func testPopoverDownsamplingKeepsSpikesAndEndpoints() {
        var prices = Array(repeating: 100.0, count: 1_000)
        prices[333] = 250
        prices[777] = 10
        let points = prices.enumerated().map { index, price in
            MenuChartDataPoint(date: epoch.addingTimeInterval(Double(index) * 60), price: price, symbol: "X")
        }
        let sampled = MenuChartDataBuilder.downsample(points, maxPoints: 60)

        XCTAssertLessThanOrEqual(sampled.count, 60)
        XCTAssertEqual(sampled.first?.date, points.first?.date)
        XCTAssertEqual(sampled.last?.date, points.last?.date)
        XCTAssertEqual(sampled.map(\.price).max(), 250)
        XCTAssertEqual(sampled.map(\.price).min(), 10)
        XCTAssertEqual(sampled.map(\.date), sampled.map(\.date).sorted())
    }

    // MARK: Remembered choices

    private func scratchDefaults() throws -> UserDefaults {
        // Stored under the test defaults folder, not ~/Library/Preferences,
        // where each run used to leave a file behind.
        let name = TestDefaultsSuite.makeName("ChartAuditFixTests.")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { TestDefaultsSuite.remove(name) }
        return defaults
    }

    func testChartSelectionRoundTripsAndForgetsCustomRanges() throws {
        let defaults = try scratchDefaults()
        ChartViewSelection(chartType: .individualStock("NVDA"), timeRange: .year, style: .candlestick).save(to: defaults)
        let loaded = ChartViewSelection.load(from: defaults)
        XCTAssertEqual(loaded.timeRange, .year)
        XCTAssertEqual(loaded.style, .candlestick)
        guard case .individualStock("NVDA") = loaded.chartType(among: ["AAPL", "NVDA"]) else {
            return XCTFail("the saved stock should be restored")
        }

        // A stock that has since been sold falls back to the portfolio.
        guard case .portfolioValue = loaded.chartType(among: ["AAPL"]) else {
            return XCTFail("a stock no longer held should not be restored")
        }

        ChartViewSelection(chartType: .portfolioGains, timeRange: .custom, style: .line).save(to: defaults)
        XCTAssertEqual(ChartViewSelection.load(from: defaults).timeRange, .month)
    }

    func testIndicatorTogglesSurviveAReload() throws {
        let defaults = try scratchDefaults()
        var settings = CandlestickChartSettings()
        settings.showGrid = false
        var toggles = CandlestickChartToggles.load(defaults: settings, from: defaults)
        XCTAssertFalse(toggles.gridLines, "the first load follows the saved chart settings")
        XCTAssertFalse(toggles.rsi)

        toggles.rsi = true
        toggles.sma50 = true
        toggles.save(to: defaults)
        XCTAssertEqual(CandlestickChartToggles.load(defaults: CandlestickChartSettings(), from: defaults), toggles)
    }

    // MARK: Menu bar

    func testPriceIsMarkedStaleOnlyWellPastTheRefreshCadence() {
        let now = epoch
        func stale(minutesOld: Double, interval: TimeInterval = 300) -> Bool {
            MenuBarStaleness.isStale(
                lastUpdate: now.addingTimeInterval(-minutesOld * 60), now: now, refreshInterval: interval
            )
        }
        // Closed markets refetch every half hour, so an hour old is still normal.
        XCTAssertFalse(stale(minutesOld: 5))
        XCTAssertFalse(stale(minutesOld: 60))
        XCTAssertTrue(stale(minutesOld: 80))
        // A long refresh interval moves the line with it.
        XCTAssertFalse(stale(minutesOld: 120, interval: 3_600))
        XCTAssertTrue(stale(minutesOld: 160, interval: 3_600))
        XCTAssertFalse(MenuBarStaleness.isStale(lastUpdate: nil, now: now, refreshInterval: 300))
    }

    // MARK: - Squeezed time axis

    /// Two sessions of five-minute points with a 17-hour night between them.
    private func twoSessions() -> [Date] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = (0..<10).map { start.addingTimeInterval(Double($0) * 300) }
        let second = (0..<10).map { start.addingTimeInterval(17 * 3_600 + Double($0) * 300) }
        return first + second
    }

    func testTimeCompressionSqueezesALongGapAndKeepsOrdinarySteps() throws {
        let dates = twoSessions()
        let compression = ChartTimeCompression(dates: dates)
        XCTAssertFalse(compression.isIdentity)

        let plotted = dates.map(compression.plotDate(for:))
        XCTAssertEqual(plotted[0], dates[0])
        // Inside a session the five-minute steps are untouched.
        XCTAssertEqual(plotted[9].timeIntervalSince(plotted[0]), 9 * 300, accuracy: 0.001)
        XCTAssertEqual(plotted[19].timeIntervalSince(plotted[10]), 9 * 300, accuracy: 0.001)
        // The night is drawn as three steps wide.
        XCTAssertEqual(plotted[10].timeIntervalSince(plotted[9]), 900, accuracy: 0.001)
        // Order is kept, and every point maps back to its own time.
        XCTAssertEqual(plotted, plotted.sorted())
        for (date, plot) in zip(dates, plotted) {
            XCTAssertEqual(
                compression.realDate(forPlot: plot).timeIntervalSince(date), 0, accuracy: 0.001
            )
        }
        XCTAssertEqual(compression.sessionStarts, [plotted[0], plotted[10]])
    }

    func testTimeCompressionLeavesAnEvenOrShortSeriesAlone() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let even = (0..<50).map { start.addingTimeInterval(Double($0) * 300) }
        XCTAssertTrue(ChartTimeCompression(dates: even).isIdentity)
        XCTAssertTrue(ChartTimeCompression(dates: Array(twoSessions().prefix(5))).isIdentity)
        XCTAssertTrue(ChartTimeCompression(dates: []).isIdentity)
        XCTAssertTrue(ChartTimeCompression.identity.sessionStarts.isEmpty)

        let date = start.addingTimeInterval(1_234)
        XCTAssertEqual(ChartTimeCompression.identity.plotDate(for: date), date)
        XCTAssertEqual(ChartTimeCompression.identity.realDate(forPlot: date), date)
    }

    func testTimeCompressionHandlesTimesOutsideAndBetweenPoints() {
        let dates = twoSessions()
        let compression = ChartTimeCompression(dates: dates.shuffled() + [dates[3]])
        // Before the first point and after the last, time runs at its normal rate.
        XCTAssertEqual(
            compression.plotDate(for: dates[0].addingTimeInterval(-600)),
            dates[0].addingTimeInterval(-600)
        )
        let lastPlot = compression.plotDate(for: dates[19])
        XCTAssertEqual(
            compression.plotDate(for: dates[19].addingTimeInterval(600)).timeIntervalSince(lastPlot),
            600, accuracy: 0.001
        )
        // Half-way through the night sits half-way across the squeezed gap.
        let midnight = dates[9].addingTimeInterval(dates[10].timeIntervalSince(dates[9]) / 2)
        let gapStart = compression.plotDate(for: dates[9])
        XCTAssertEqual(compression.plotDate(for: midnight).timeIntervalSince(gapStart), 450, accuracy: 0.001)
    }
}
