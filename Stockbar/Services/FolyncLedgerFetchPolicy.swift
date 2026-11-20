import Foundation

/// The one object in front of Folync's three ledger routes. Each of them makes
/// Folync rebuild a whole report, unqueued, and a later page costs as much as
/// the first, so:
///
/// - Requests take turns, first come first served: never two at once across
///   the three routes. Callers asking for the same thing share one request.
/// - A successful first page is reused for `reuseInterval` (five minutes) for
///   the same endpoint, scope, route and query, with no request. An explicit
///   refresh skips the reuse but still takes its turn.
/// - Only first pages are kept. A later page ("load more", which is always
///   explicit) is handed to its caller and kept nowhere. A kept page is
///   dropped once it is past the reuse window.
/// - A request still waiting its turn is not made if every caller waiting for
///   it has been cancelled by then, so a run of superseded requests (a filter
///   changed several times) does not reach Folync one after another.
///
/// It makes no request of its own and runs no timer. The clock is injected so
/// tests do not wait.
actor FolyncLedgerFetchPolicy {
    static let defaultReuseInterval: TimeInterval = 5 * 60

    /// What one request is for. Two equal keys are the same request.
    struct Key: Hashable, Sendable {
        let route: FolyncLedgerRoute
        let endpoint: String
        let scopeID: String
        /// `FolyncLedgerQuery.cacheKey`, without the cursor.
        let query: String
        /// Nil for page one.
        let cursor: String?

        var firstPage: Key {
            Key(route: route, endpoint: endpoint, scopeID: scopeID, query: query, cursor: nil)
        }
    }

    /// What an operation returns: the caller's result, and the first page to
    /// keep for reuse, if the operation produced a fresh one.
    struct Outcome<Value: Sendable>: Sendable {
        let result: Value
        let firstPageToKeep: Value?
    }

    private struct Kept {
        let value: any Sendable
        let storedAt: Date
    }

    /// A request started and not yet finished, queued ones included.
    private struct Pending {
        let task: Task<any Sendable, Never>
        let forceRefresh: Bool
        /// Callers still waiting for the answer.
        var callers: Int
    }

    /// What a request returns when it was never made.
    private struct Abandoned: Sendable {}

    let reuseInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var kept: [Key: Kept] = [:]
    private var pending: [UInt64: Pending] = [:]
    /// The newest pending request for each key: the one a new caller may join.
    private var newest: [Key: UInt64] = [:]
    private var lastID: UInt64 = 0
    private var isTurnTaken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(reuseInterval: TimeInterval = defaultReuseInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reuseInterval = reuseInterval
        self.now = now
    }

    /// Runs `operation` in its turn, or returns a result it can reuse or share.
    ///
    /// - Parameters:
    ///   - key: what is asked for. A first page (no cursor) may be answered
    ///     from what was kept; a later page never is.
    ///   - forceRefresh: skip the reuse window. The request still waits its turn.
    /// - Returns: the result, or nil when no request was made because the
    ///   caller was cancelled: either before it asked, or while the request
    ///   waited its turn with nobody else waiting for it.
    func perform<Value: Sendable>(
        _ key: Key,
        forceRefresh: Bool = false,
        operation: @escaping @Sendable () async -> Outcome<Value>
    ) async -> Value? {
        if !forceRefresh, let reused: Value = reusable(key) { return reused }
        if Task.isCancelled { return nil }
        // A refresh does not join a request that may still answer from the
        // reuse window; anything else joins the request already under way.
        if let id = newest[key], let shared = pending[id], shared.forceRefresh || !forceRefresh {
            pending[id]?.callers += 1
            return await answer(of: shared.task, id: id)
        }
        lastID += 1
        let id = lastID
        let task = Task<any Sendable, Never> {
            await self.takeTurn()
            defer { self.finish(id, key: key) }
            // Every caller gave up while this waited its turn: make no request.
            if self.pending[id]?.callers == 0 { return Abandoned() }
            if !forceRefresh, let reused: Value = self.reusable(key) { return reused }
            let outcome = await operation()
            if let firstPage = outcome.firstPageToKeep { self.keep(firstPage, for: key.firstPage) }
            return outcome.result
        }
        pending[id] = Pending(task: task, forceRefresh: forceRefresh, callers: 1)
        newest[key] = id
        return await answer(of: task, id: id)
    }

    /// Waits for a pending request. A caller cancelled meanwhile is counted
    /// out, but still gets the answer if the request is made for someone else
    /// or was already under way.
    private func answer<Value: Sendable>(of task: Task<any Sendable, Never>, id: UInt64) async -> Value? {
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.callerGaveUp(id) }
        }
        if value is Abandoned { return nil }
        // The task only ever returns `Value` for this key's route.
        guard let typed = value as? Value else { preconditionFailure("Ledger result of an unexpected type") }
        return typed
    }

    private func callerGaveUp(_ id: UInt64) {
        guard let callers = pending[id]?.callers, callers > 0 else { return }
        pending[id]?.callers = callers - 1
    }

    private func finish(_ id: UInt64, key: Key) {
        pending[id] = nil
        if newest[key] == id { newest[key] = nil }
        endTurn()
    }

    private func keep(_ value: any Sendable, for key: Key) {
        let time = now()
        // A page past the reuse window can never be returned again. Dropping
        // them here keeps a long session from holding every page it loaded.
        kept = kept.filter { isReusable($0.value, at: time) }
        kept[key] = Kept(value: value, storedAt: time)
    }

    /// How many first pages are held for reuse. For tests.
    var keptPageCount: Int { kept.count }

    /// Forgets every kept first page, for example when the connection changes.
    func removeAll() {
        kept.removeAll()
    }

    private func reusable<Value>(_ key: Key) -> Value? {
        guard key.cursor == nil, let entry = kept[key], isReusable(entry, at: now()) else { return nil }
        return entry.value as? Value
    }

    private func isReusable(_ entry: Kept, at time: Date) -> Bool {
        let age = time.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < reuseInterval
    }

    private func takeTurn() async {
        guard isTurnTaken else {
            isTurnTaken = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            isTurnTaken = false
        } else {
            // The turn passes straight to the next caller in line.
            waiting.removeFirst().resume()
        }
    }
}
