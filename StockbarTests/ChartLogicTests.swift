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

private func assertClose(_ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
}
