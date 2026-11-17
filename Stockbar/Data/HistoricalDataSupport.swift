import Foundation

// Small types used by `HistoricalDataManager`.

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension DateFormatter {
    static let debug: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

struct InstrumentAliasHistoryLookup {
    /// The prices stored and sampled for `symbol` and its aliases, oldest
    /// first, one per millisecond. Where several share a millisecond, later
    /// aliases win, then the symbol itself, and within each of them a live
    /// sample wins over a stored price. With `window`, only the prices
    /// inside it, the same ones the whole series would have there.
    static func combinedSnapshots(
        for symbol: String,
        aliases: [String],
        storedBySymbol: [String: [PriceSnapshot]],
        liveBySymbol: [String: [PriceSnapshot]],
        within window: ClosedRange<Date>? = nil
    ) -> [PriceSnapshot] {
        let requested = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var seenAliases = Set<String>()
        var orderedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != requested && seenAliases.insert($0).inserted }
        orderedAliases.append(requested)

        // Prices that share a millisecond are at most 1 ms apart, so reading
        // 2 ms either side of the window takes in every price that could
        // replace one inside it. The result is then cut to the window.
        let readWindow = window.map { $0.lowerBound.addingTimeInterval(-0.002)...$0.upperBound.addingTimeInterval(0.002) }
        var latestByTimestamp: [Int64: PriceSnapshot] = [:]
        for alias in orderedAliases {
            for source in [storedBySymbol, liveBySymbol] {
                for snapshot in values(for: alias, in: source)
                    where snapshot.price.isFinite && snapshot.price > 0
                        && readWindow?.contains(snapshot.timestamp) != false {
                    let key = Int64((snapshot.timestamp.timeIntervalSince1970 * 1_000).rounded())
                    latestByTimestamp[key] = snapshot
                }
            }
        }
        var combined = Array(latestByTimestamp.values)
        if let window { combined.removeAll { !window.contains($0.timestamp) } }
        return combined.sorted { $0.timestamp < $1.timestamp }
    }

    private static func values(
        for symbol: String,
        in valuesBySymbol: [String: [PriceSnapshot]]
    ) -> [PriceSnapshot] {
        valuesBySymbol[symbol]
            ?? valuesBySymbol.first { $0.key.uppercased() == symbol }?.value
            ?? []
    }
}

struct FolyncLineSeriesKey: Hashable, Sendable {
    let symbol: String
    let range: String
    let customFromMilliseconds: Int64?
    let customToMilliseconds: Int64?

    init(
        symbol: String,
        timeRange: ChartTimeRange,
        customFrom: Date? = nil,
        customTo: Date? = nil
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.range = timeRange.folyncRange
        if timeRange == .custom {
            self.customFromMilliseconds = customFrom.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
            self.customToMilliseconds = customTo.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            }
        } else {
            self.customFromMilliseconds = nil
            self.customToMilliseconds = nil
        }
    }

    var storageKey: String {
        "line|\(symbol)|\(range)|\(customFromMilliseconds.map(String.init) ?? "-")|\(customToMilliseconds.map(String.init) ?? "-")"
    }
}

struct HistoricalFetchRequestGate {
    private(set) var lastRequestByKey: [String: Date] = [:]
    private(set) var inFlightKeys: Set<String> = []
    private var emptyResponseCounts: [String: Int] = [:]
    private var emptyRetryAfter: [String: Date] = [:]

    mutating func reserve(key: String, now: Date, cooldown: TimeInterval, force: Bool = false) -> Bool {
        guard !inFlightKeys.contains(key) else { return false }
        let expiredKeys = lastRequestByKey.compactMap { key, date in
            !inFlightKeys.contains(key) && now.timeIntervalSince(date) > 24 * 60 * 60 ? key : nil
        }
        for expiredKey in expiredKeys {
            lastRequestByKey.removeValue(forKey: expiredKey)
            emptyResponseCounts.removeValue(forKey: expiredKey)
            emptyRetryAfter.removeValue(forKey: expiredKey)
        }
        if !force, let retryAfter = emptyRetryAfter[key], now < retryAfter { return false }
        if !force, let lastRequest = lastRequestByKey[key],
           now.timeIntervalSince(lastRequest) < cooldown {
            return false
        }

        lastRequestByKey[key] = now
        inFlightKeys.insert(key)
        return true
    }

    mutating func complete(
        key: String,
        outcome: HistoricalPriceFetchOutcome = .success,
        now: Date = Date(),
        cooldown: TimeInterval = 600
    ) {
        inFlightKeys.remove(key)
        switch outcome {
        case .empty:
            let count = min((emptyResponseCounts[key] ?? 0) + 1, 5)
            emptyResponseCounts[key] = count
            let delay = min(6 * 60 * 60, cooldown * 3 * pow(2, Double(count - 1)))
            emptyRetryAfter[key] = now.addingTimeInterval(delay)
        case .success, .cancelled:
            emptyResponseCounts.removeValue(forKey: key)
            emptyRetryAfter.removeValue(forKey: key)
            if outcome == .cancelled { lastRequestByKey.removeValue(forKey: key) }
        case .failed:
            break
        }
    }
}
