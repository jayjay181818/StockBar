//
//  CacheCoordinator.swift
//  Stockbar
//
//  Service responsible for managing price data caching
//  Tracks successful and failed fetches per symbol
//

import Foundation

/// Coordinates caching strategy for stock price data with exponential backoff and circuit breaker
class CacheCoordinator {
    // MARK: - Cache Configuration
    let cacheInterval: TimeInterval = 900  // 15 minutes for successful fetches
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

    // MARK: - Cache Management

    /// Records a successful fetch for a symbol
    func setSuccessfulFetch(for symbol: String, at time: Date) {
        lastSuccessfulFetch[symbol] = time
        lastFailedFetch.removeValue(forKey: symbol)
        consecutiveFailures.removeValue(forKey: symbol)  // Reset failure count on success
        suspendedSymbols.removeValue(forKey: symbol)  // Remove from suspension on success
    }

    /// Records a failed fetch for a symbol
    func setFailedFetch(for symbol: String, at time: Date) {
        lastFailedFetch[symbol] = time

        // Increment consecutive failure count
        let currentFailures = consecutiveFailures[symbol] ?? 0
        consecutiveFailures[symbol] = currentFailures + 1

        // Check if we should suspend this symbol (circuit breaker)
        if consecutiveFailures[symbol]! >= circuitBreakerThreshold {
            suspendedSymbols[symbol] = time
        }
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
    func shouldRefresh(symbol: String, at time: Date) -> Bool {
        // Check if we have a recent successful fetch
        if let lastSuccess = lastSuccessfulFetch[symbol] {
            let timeSinceSuccess = time.timeIntervalSince(lastSuccess)

            // If cache is still fresh, don't refresh
            if timeSinceSuccess < cacheInterval {
                return false
            }

            // If cache is very old (> 1 hour), force refresh
            if timeSinceSuccess > maxCacheAge {
                return true
            }

            // Normal case: cache expired, should refresh
            return true
        }

        // No successful fetch recorded, should refresh
        return true
    }

    /// Determines if a failed fetch should be retried using exponential backoff
    func shouldRetry(symbol: String, at time: Date) -> Bool {
        // Check if symbol is suspended (circuit breaker)
        if isSuspended(symbol: symbol, at: time) {
            return false
        }

        guard let lastFailed = lastFailedFetch[symbol] else {
            return false
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
    }

    /// Checks if symbol is currently cached
    func isCached(symbol: String, at time: Date) -> Bool {
        guard let lastSuccess = lastSuccessfulFetch[symbol] else {
            return false
        }

        let timeSinceSuccess = time.timeIntervalSince(lastSuccess)
        return timeSinceSuccess < cacheInterval
    }

    /// Gets cache status for a symbol
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
            } else {
                // Suspension expired, remove it
                suspendedSymbols.removeValue(forKey: symbol)
                consecutiveFailures.removeValue(forKey: symbol)
            }
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
    }

    /// Clears all cache
    func clearAllCache() {
        lastSuccessfulFetch.removeAll()
        lastFailedFetch.removeAll()
        consecutiveFailures.removeAll()
        suspendedSymbols.removeAll()
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

    /// Clears old cache entries beyond max age
    func clearOldCacheEntries() {
        let cutoffTime = Date().addingTimeInterval(-maxCacheAge)
        lastSuccessfulFetch = lastSuccessfulFetch.filter { $0.value > cutoffTime }
        lastFailedFetch = lastFailedFetch.filter { $0.value > cutoffTime }
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
