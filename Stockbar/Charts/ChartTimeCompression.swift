import Foundation

/// Places chart points along the x-axis with long gaps squeezed, so nights and
/// weekends on a short-range chart do not take up most of the width.
///
/// Real times map to "plot" times: steps between points are kept as they are,
/// except that any gap longer than `longestGapShown` is drawn that wide. The
/// mapping is exact at every point and runs straight between them.
nonisolated struct ChartTimeCompression: Equatable, Sendable {
    /// Leaves every time where it is.
    static let identity = ChartTimeCompression(real: [], plot: [])

    /// A gap is squeezed only when it is this many times the usual step.
    static let gapMultiple = 3.0
    /// Never squeeze a gap shorter than this, however fine the series.
    static let shortestGapSqueezed: TimeInterval = 600
    /// Too few points to say what a usual step is.
    static let minimumPoints = 8

    /// Point times in seconds, ascending, and where each is drawn.
    private let real: [TimeInterval]
    private let plot: [TimeInterval]

    private init(real: [TimeInterval], plot: [TimeInterval]) {
        self.real = real
        self.plot = plot
    }

    /// Built from the dates of the series on screen, in any order.
    init(dates: [Date]) {
        let times = Array(Set(dates.map(\.timeIntervalSinceReferenceDate).filter(\.isFinite))).sorted()
        guard times.count >= Self.minimumPoints else {
            self = .identity
            return
        }
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }
        let usualStep = steps.sorted()[steps.count / 2]
        let longestGapShown = max(usualStep * Self.gapMultiple, Self.shortestGapSqueezed)
        guard steps.contains(where: { $0 > longestGapShown }) else {
            self = .identity
            return
        }
        var plotted: [TimeInterval] = [times[0]]
        plotted.reserveCapacity(times.count)
        for step in steps {
            plotted.append((plotted.last ?? times[0]) + min(step, longestGapShown))
        }
        self.init(real: times, plot: plotted)
    }

    /// True when nothing is squeezed and plot times are real times.
    var isIdentity: Bool { real.isEmpty }

    /// Where a real time is drawn.
    func plotDate(for date: Date) -> Date {
        Self.map(date, from: real, to: plot)
    }

    /// The real time drawn at a plot position.
    func realDate(forPlot date: Date) -> Date {
        Self.map(date, from: plot, to: real)
    }

    /// Plot times at which a run of points starts after a squeezed gap,
    /// beginning with the first point: one per trading session.
    var sessionStarts: [Date] {
        guard !isIdentity else { return [] }
        var starts = [plot[0]]
        for index in 1..<real.count where (real[index] - real[index - 1]) - (plot[index] - plot[index - 1]) > 0.5 {
            starts.append(plot[index])
        }
        return starts.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func map(_ date: Date, from source: [TimeInterval], to target: [TimeInterval]) -> Date {
        guard let first = source.first, let last = source.last,
              let targetFirst = target.first, let targetLast = target.last else { return date }
        let value = date.timeIntervalSinceReferenceDate
        guard value.isFinite else { return date }
        // Outside the series, time runs at its normal rate.
        if value <= first { return Date(timeIntervalSinceReferenceDate: targetFirst + (value - first)) }
        if value >= last { return Date(timeIntervalSinceReferenceDate: targetLast + (value - last)) }

        // First breakpoint above `value`.
        var low = 0
        var high = source.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if source[middle] <= value { low = middle } else { high = middle }
        }
        let span = source[high] - source[low]
        guard span > 0 else { return Date(timeIntervalSinceReferenceDate: target[low]) }
        let fraction = (value - source[low]) / span
        return Date(timeIntervalSinceReferenceDate: target[low] + fraction * (target[high] - target[low]))
    }
}
