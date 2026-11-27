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
    private let queue: HistoricalPriceFetchQueue
    private let cooldown: TimeInterval
    private let now: () -> Date
    private var gate = HistoricalFetchRequestGate()

    init(
        maximumConcurrentRequests: Int = 2,
        cooldown: TimeInterval = 600,
        now: @escaping () -> Date = Date.init
    ) {
        self.queue = HistoricalPriceFetchQueue(maximumConcurrentRequests: maximumConcurrentRequests)
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
        queue.enqueue { [self] in
            let outcome = await operation()
            gate.complete(key: key, outcome: outcome, now: now(), cooldown: cooldown)
        }
        return true
    }
}

/// FIFO concurrency budget shared by all requests that use a given provider.
@MainActor
final class HistoricalPriceFetchQueue {
    private let maximumConcurrentRequests: Int
    private var pending: [@MainActor () -> Void] = []
    private var activeCount = 0

    init(maximumConcurrentRequests: Int) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        reserve {
            Task {
                await operation()
                self.release()
            }
        }
    }

    func perform(_ operation: () async -> HistoricalPriceFetchOutcome) async -> HistoricalPriceFetchOutcome {
        await withCheckedContinuation { continuation in
            reserve { continuation.resume() }
        }
        defer { release() }
        return await operation()
    }

    private func reserve(_ start: @escaping @MainActor () -> Void) {
        if activeCount < maximumConcurrentRequests {
            activeCount += 1
            start()
        } else {
            pending.append(start)
        }
    }

    private func release() {
        if pending.isEmpty {
            activeCount -= 1
        } else {
            pending.removeFirst()()
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
        if let cached = cachedSnapshots(for: symbol, aliases: aliases) { return cached }
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

    /// The cached series, or nil without building one. A hit counts as a
    /// use; a series cached for a different alias list is dropped.
    mutating func cachedSnapshots(for symbol: String, aliases: [String]) -> [PriceSnapshot]? {
        access &+= 1
        guard var entry = entries[symbol] else { return nil }
        guard entry.aliases == aliases else {
            entries[symbol] = nil
            pointCount -= entry.snapshots.count
            return nil
        }
        entry.access = access
        entries[symbol] = entry
        return entry.snapshots
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        pointCount = 0
    }
}
