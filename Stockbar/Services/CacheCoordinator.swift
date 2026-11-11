//
//  CacheCoordinator.swift
//  Stockbar
//
//  Service responsible for managing price data caching
//  Tracks successful and failed fetches per symbol
//

import Foundation

/// Coordinates caching strategy for stock price data with exponential backoff and circuit breaker
actor CacheCoordinator {
    // MARK: - Cache Configuration
    /// How long a quote counts as fresh. The refresh service keeps this in step
    /// with the user's refresh interval, so the status shown for a symbol and the
    /// decision to refetch it use the same figure.
    private(set) var cacheInterval: TimeInterval = 900

    func setFreshnessInterval(_ interval: TimeInterval) {
        guard interval.isFinite, interval > 0 else { return }
        cacheInterval = interval
    }
    private let maxCacheAge: TimeInterval = 3600  // 1 hour before forcing refresh

    // Exponential backoff retry intervals
    private let retryIntervals: [TimeInterval] = [60, 120, 300, 600]  // 1min, 2min, 5min, 10min

    // Circuit breaker configuration
    private let circuitBreakerThreshold = 5  // Consecutive failures before suspension
    private let circuitBreakerTimeout: TimeInterval = 3600  // 1 hour suspension

    // MARK: - Cache State
    private var lastSuccessfulFetch: [String: Date] = [:]
    private var lastFailedFetch: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]  // Track consecutive failures per symbol
    private var suspendedSymbols: [String: Date] = [:]  // Circuit breaker: suspended symbols

    // MARK: - Provider back-off
    //
    // When a whole refresh pass fails, or the provider reports throttling or a dead
    // connection, the fault is not any one symbol's. Counting it per symbol tripped
    // every circuit breaker together and stopped all quotes for an hour, so those
    // failures share one short back-off instead. It is deliberately not persisted.
    private let providerBackoffSteps: [TimeInterval] = [60, 120, 300, 600]
    private var providerFailureCount = 0
    private var providerBackoffUntil: Date?

    /// Records a provider-wide failure and returns how long refreshes should wait.
    @discardableResult
    func recordProviderFailure(at time: Date) -> TimeInterval {
        providerFailureCount += 1
        let wait = providerBackoffSteps[min(providerFailureCount, providerBackoffSteps.count) - 1]
        providerBackoffUntil = time.addingTimeInterval(wait)
        return wait
    }

    func recordProviderSuccess() {
        providerFailureCount = 0
        providerBackoffUntil = nil
    }

    /// Seconds left before automatic refreshes may try the provider again, or nil.
    func providerBackoffRemaining(at time: Date) -> TimeInterval? {
        guard let until = providerBackoffUntil, until > time else { return nil }
        return until.timeIntervalSince(time)
    }

    // MARK: - Persistence
    //
    // Cache and breaker state used to live only in memory, so quitting the app
    // cleared every circuit breaker and forced an immediate full refresh on the
    // next launch — which defeats the rate limiting this type exists to provide.

    private let defaults: UserDefaults
    private static let stateKey = "cacheCoordinator.state.v1"

    struct PersistedState: Codable, Sendable {
        var lastSuccessfulFetch: [String: Date]
        var lastFailedFetch: [String: Date]
        var consecutiveFailures: [String: Int]
        var suspendedSymbols: [String: Date]
    }

    init(defaults: UserDefaults = StockbarRuntimeStorage.userDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        lastSuccessfulFetch = state.lastSuccessfulFetch
        lastFailedFetch = state.lastFailedFetch
        consecutiveFailures = state.consecutiveFailures
        suspendedSymbols = state.suspendedSymbols
        // Drop anything that already aged out while the app was closed. The
        // pruning is a pure function so it can run in the nonisolated init.
        let pruned = Self.prunedState(
            PersistedState(
                lastSuccessfulFetch: lastSuccessfulFetch,
                lastFailedFetch: lastFailedFetch,
                consecutiveFailures: consecutiveFailures,
                suspendedSymbols: suspendedSymbols
            ),
            now: Date(),
            maxCacheAge: maxCacheAge,
            circuitBreakerTimeout: circuitBreakerTimeout
        )
        lastSuccessfulFetch = pruned.lastSuccessfulFetch
        lastFailedFetch = pruned.lastFailedFetch
        consecutiveFailures = pruned.consecutiveFailures
        suspendedSymbols = pruned.suspendedSymbols
    }

    private func persist() {
        let state = PersistedState(
            lastSuccessfulFetch: lastSuccessfulFetch,
            lastFailedFetch: lastFailedFetch,
            consecutiveFailures: consecutiveFailures,
            suspendedSymbols: suspendedSymbols
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    // MARK: - Cache Management

    /// Records a successful fetch for a symbol
    func setSuccessfulFetch(for symbol: String, at time: Date) {
        lastSuccessfulFetch[symbol] = time
        lastFailedFetch.removeValue(forKey: symbol)
        consecutiveFailures.removeValue(forKey: symbol)  // Reset failure count on success
        suspendedSymbols.removeValue(forKey: symbol)  // Remove from suspension on success
        persist()
    }

    /// Records a failed fetch for a symbol
    func setFailedFetch(for symbol: String, at time: Date) {
        lastFailedFetch[symbol] = time

        // Increment consecutive failure count
        let failures = (consecutiveFailures[symbol] ?? 0) + 1
        consecutiveFailures[symbol] = failures

        // Check if we should suspend this symbol (circuit breaker)
        if failures >= circuitBreakerThreshold {
            suspendedSymbols[symbol] = time
        }
        persist()
    }

    /// Gets the last successful fetch time for a symbol
    func getLastSuccessfulFetch(for symbol: String) -> Date? {
        return lastSuccessfulFetch[symbol]
    }

    /// Gets the last failed fetch time for a symbol
    func getLastFailedFetch(for symbol: String) -> Date? {
        return lastFailedFetch[symbol]
    }

    // MARK: - Cache Decision Logic

    /// Determines if a symbol should be refreshed based on cache state
    ///
    /// Symbols with recorded consecutive failures are governed exclusively by
    /// `shouldRetry` (exponential backoff and circuit breaker). Returning true
    /// here for them would bypass both: a never-successful symbol has no
    /// success timestamp, and a once-successful one ages past the freshness
    /// interval, so either would be fetched on every pass.
    func shouldRefresh(symbol: String, at time: Date, freshnessInterval: TimeInterval? = nil) -> Bool {
        let activeCacheInterval = max(0, freshnessInterval ?? cacheInterval)

        if isSuspended(symbol: symbol, at: time) || (consecutiveFailures[symbol] ?? 0) > 0 {
            return false
        }

        // No successful fetch recorded, or the cache has aged out.
        guard let lastSuccess = lastSuccessfulFetch[symbol] else { return true }

        return time.timeIntervalSince(lastSuccess) >= activeCacheInterval
    }

    /// Determines if a failed fetch should be retried using exponential backoff
    func shouldRetry(symbol: String, at time: Date) -> Bool {
        // Check if symbol is suspended (circuit breaker)
        if isSuspended(symbol: symbol, at: time) {
            return false
        }

        guard let lastFailed = lastFailedFetch[symbol] else {
            // A failure count without a timestamp (legacy persisted state)
            // must not strand the symbol; allow one retry.
            return (consecutiveFailures[symbol] ?? 0) > 0
        }

        let timeSinceFailed = time.timeIntervalSince(lastFailed)
        let retryInterval = getRetryInterval(for: symbol)

        return timeSinceFailed >= retryInterval
    }

    /// Gets the retry interval for a symbol based on consecutive failures (exponential backoff)
    func getRetryInterval(for symbol: String) -> TimeInterval {
        let failures = consecutiveFailures[symbol] ?? 0
        let index = min(failures - 1, retryIntervals.count - 1)
        return index >= 0 ? retryIntervals[index] : retryIntervals[0]
    }

    /// Checks if a symbol is currently suspended (circuit breaker)
    func isSuspended(symbol: String, at time: Date) -> Bool {
        guard let suspendedAt = suspendedSymbols[symbol] else {
            return false
        }

        let timeSinceSuspension = time.timeIntervalSince(suspendedAt)
        return timeSinceSuspension < circuitBreakerTimeout
    }

    /// Manually clears suspension for a symbol (for "retry now" functionality)
    func clearSuspension(for symbol: String) {
        suspendedSymbols.removeValue(forKey: symbol)
        consecutiveFailures.removeValue(forKey: symbol)
        persist()
    }

    /// Checks if symbol is currently cached
    func isCached(symbol: String, at time: Date) -> Bool {
        guard let lastSuccess = lastSuccessfulFetch[symbol] else {
            return false
        }

        let timeSinceSuccess = time.timeIntervalSince(lastSuccess)
        return timeSinceSuccess < cacheInterval
    }

    /// Gets cache status for a symbol.
    ///
    /// This is a **pure query**. It must not mutate cache or breaker state:
    /// it is called from display paths (menu bar construction, the diagnostics
    /// list), and clearing the failure counter here would let merely *looking*
    /// at a symbol reset its exponential backoff and disarm the circuit breaker.
    /// Expired suspensions are reaped by `clearOldCacheEntries()` instead.
    func getCacheStatus(for symbol: String, at time: Date) -> CacheStatus {
        // Check if suspended first
        if let suspendedAt = suspendedSymbols[symbol] {
            let timeSinceSuspension = time.timeIntervalSince(suspendedAt)
            if timeSinceSuspension < circuitBreakerTimeout {
                let failures = consecutiveFailures[symbol] ?? 0
                return .suspended(
                    failures: failures,
                    resumeIn: circuitBreakerTimeout - timeSinceSuspension
                )
            }
            // Suspension has expired; fall through and report the underlying
            // cache state without touching stored state.
        }

        if let lastSuccess = lastSuccessfulFetch[symbol] {
            let age = time.timeIntervalSince(lastSuccess)
            if age < cacheInterval {
                return .fresh(expiresIn: cacheInterval - age)
            } else if age < maxCacheAge {
                return .stale(age: age)
            } else {
                return .expired(age: age)
            }
        }

        if let lastFailed = lastFailedFetch[symbol] {
            let age = time.timeIntervalSince(lastFailed)
            let retryInterval = getRetryInterval(for: symbol)
            let failures = consecutiveFailures[symbol] ?? 0

            if age < retryInterval {
                return .failedRecently(retryIn: retryInterval - age, failures: failures)
            } else {
                return .readyToRetry(failures: failures)
            }
        }

        return .neverFetched
    }

    /// Clears cache for a specific symbol
    func clearCache(for symbol: String) {
        lastSuccessfulFetch.removeValue(forKey: symbol)
        lastFailedFetch.removeValue(forKey: symbol)
        consecutiveFailures.removeValue(forKey: symbol)
        suspendedSymbols.removeValue(forKey: symbol)
        persist()
    }

    /// Clears all cache
    func clearAllCache() {
        lastSuccessfulFetch.removeAll()
        lastFailedFetch.removeAll()
        consecutiveFailures.removeAll()
        suspendedSymbols.removeAll()
        persist()
    }

    /// Gets all cached symbols
    func getCachedSymbols() -> Set<String> {
        return Set(lastSuccessfulFetch.keys)
    }

    /// Gets cache statistics
    func getCacheStatistics() -> CacheStatistics {
        let now = Date()
        var freshCount = 0
        var staleCount = 0
        var expiredCount = 0

        for (_, lastFetch) in lastSuccessfulFetch {
            let age = now.timeIntervalSince(lastFetch)
            if age < cacheInterval {
                freshCount += 1
            } else if age < maxCacheAge {
                staleCount += 1
            } else {
                expiredCount += 1
            }
        }

        return CacheStatistics(
            totalCached: lastSuccessfulFetch.count,
            freshCount: freshCount,
            staleCount: staleCount,
            expiredCount: expiredCount,
            failedCount: lastFailedFetch.count
        )
    }

    /// Clears old cache entries beyond max age, and reaps circuit-breaker
    /// suspensions that have served their timeout. This is the only place that
    /// state expiry mutates — `getCacheStatus` stays a pure query.
    func clearOldCacheEntries(now: Date = Date()) {
        let pruned = Self.prunedState(
            PersistedState(
                lastSuccessfulFetch: lastSuccessfulFetch,
                lastFailedFetch: lastFailedFetch,
                consecutiveFailures: consecutiveFailures,
                suspendedSymbols: suspendedSymbols
            ),
            now: now,
            maxCacheAge: maxCacheAge,
            circuitBreakerTimeout: circuitBreakerTimeout
        )
        lastSuccessfulFetch = pruned.lastSuccessfulFetch
        lastFailedFetch = pruned.lastFailedFetch
        consecutiveFailures = pruned.consecutiveFailures
        suspendedSymbols = pruned.suspendedSymbols
        persist()
    }

    /// Ages out stale entries. Failure counts are dropped together with their
    /// failure timestamp (unless the symbol is still suspended) so an orphaned
    /// count can neither prime the breaker early nor strand a symbol with no
    /// retry timestamp.
    static func prunedState(
        _ state: PersistedState,
        now: Date,
        maxCacheAge: TimeInterval = 3600,
        circuitBreakerTimeout: TimeInterval = 3600
    ) -> PersistedState {
        let cutoffTime = now.addingTimeInterval(-maxCacheAge)
        let suspended = state.suspendedSymbols.filter {
            now.timeIntervalSince($0.value) < circuitBreakerTimeout
        }
        let failed = state.lastFailedFetch.filter { $0.value > cutoffTime }
        let failures = state.consecutiveFailures.filter { symbol, _ in
            failed[symbol] != nil || suspended[symbol] != nil
        }
        return PersistedState(
            lastSuccessfulFetch: state.lastSuccessfulFetch.filter { $0.value > cutoffTime },
            lastFailedFetch: failed,
            consecutiveFailures: failures,
            suspendedSymbols: suspended
        )
    }
}

// MARK: - Supporting Types

enum CacheStatus {
    case fresh(expiresIn: TimeInterval)
    case stale(age: TimeInterval)
    case expired(age: TimeInterval)
    case failedRecently(retryIn: TimeInterval, failures: Int)
    case readyToRetry(failures: Int)
    case suspended(failures: Int, resumeIn: TimeInterval)
    case neverFetched

    var description: String {
        switch self {
        case .fresh(let expiresIn):
            return "Fresh (expires in \(Int(expiresIn))s)"
        case .stale(let age):
            return "Stale (age: \(Int(age))s)"
        case .expired(let age):
            return "Expired (age: \(Int(age))s)"
        case .failedRecently(let retryIn, let failures):
            return "Failed \(failures)x (retry in \(Int(retryIn))s)"
        case .readyToRetry(let failures):
            return "Ready to retry (failed \(failures)x)"
        case .suspended(let failures, let resumeIn):
            return "⚠️ Suspended (failed \(failures)x, resume in \(Int(resumeIn/60))m)"
        case .neverFetched:
            return "Never fetched"
        }
    }
}

struct CacheStatistics {
    let totalCached: Int
    let freshCount: Int
    let staleCount: Int
    let expiredCount: Int
    let failedCount: Int

    var description: String {
        return "Cached: \(totalCached) (Fresh: \(freshCount), Stale: \(staleCount), Expired: \(expiredCount), Failed: \(failedCount))"
    }
}
