import Foundation

enum HistoricalPriceFetchOutcome {
    case success
    case empty
    case failed
    case cancelled
}

/// Shares the history request budget across symbols without blocking a thread.
@MainActor
final class HistoricalPriceFetchScheduler {
    private struct PendingRequest {
        let key: String
        let operation: @MainActor () async -> HistoricalPriceFetchOutcome
    }

    private let maximumConcurrentRequests: Int
    private let cooldown: TimeInterval
    private let now: () -> Date
    private var gate = HistoricalFetchRequestGate()
    private var pending: [PendingRequest] = []
    private var activeCount = 0

    init(
        maximumConcurrentRequests: Int = 2,
        cooldown: TimeInterval = 600,
        now: @escaping () -> Date = Date.init
    ) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.cooldown = cooldown
        self.now = now
    }

    @discardableResult
    func schedule(
        key: String,
        force: Bool = false,
        operation: @escaping @MainActor () async -> HistoricalPriceFetchOutcome
    ) -> Bool {
        guard gate.reserve(key: key, now: now(), cooldown: cooldown, force: force) else { return false }
        pending.append(PendingRequest(key: key, operation: operation))
        startPendingRequests()
        return true
    }

    private func startPendingRequests() {
        while activeCount < maximumConcurrentRequests, !pending.isEmpty {
            let request = pending.removeFirst()
            activeCount += 1
            Task {
                let outcome = await request.operation()
                gate.complete(key: request.key, outcome: outcome, now: now(), cooldown: cooldown)
                activeCount -= 1
                startPendingRequests()
            }
        }
    }
}

/// Caches complete, sorted alias series; callers still filter each moving time window.
/// A point budget avoids multiplying the retained history footprint for large series.
struct AliasPriceSnapshotCache {
    private struct Entry {
        let aliases: [String]
        let snapshots: [PriceSnapshot]
        var access: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0
    private var pointCount = 0
    private let pointLimit: Int
    private let entryLimit: Int

    init(pointLimit: Int = 7_200, entryLimit: Int = 32) {
        self.pointLimit = max(0, pointLimit)
        self.entryLimit = max(0, entryLimit)
    }

    mutating func snapshots(
        for symbol: String,
        aliases: [String],
        resolve: () -> [PriceSnapshot]
    ) -> [PriceSnapshot] {
        access &+= 1
        if var entry = entries[symbol], entry.aliases == aliases {
            entry.access = access
            entries[symbol] = entry
            return entry.snapshots
        }
        if let previous = entries.removeValue(forKey: symbol) { pointCount -= previous.snapshots.count }
        let snapshots = resolve()
        guard entryLimit > 0, snapshots.count <= pointLimit else { return snapshots }
        while entries.count >= entryLimit || pointCount + snapshots.count > pointLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            pointCount -= removed.snapshots.count
        }
        entries[symbol] = Entry(aliases: aliases, snapshots: snapshots, access: access)
        pointCount += snapshots.count
        return snapshots
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        pointCount = 0
    }
}
