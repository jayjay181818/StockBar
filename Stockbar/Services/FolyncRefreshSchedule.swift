import Foundation

/// Folync's broker job starts on minute boundaries. This is a polling estimate,
/// not proof that its provider request has completed.
enum FolyncRefreshSchedule {
    static let interval: TimeInterval = 60
    static let publicationDelay: TimeInterval = 5
    static let catchUpDelay: TimeInterval = 10
    /// A rejected token does not start working on its own, so it is not re-sent
    /// every minute. Refresh Now or re-activating still retries at once.
    static let unauthorizedRetryDelay: TimeInterval = 15 * 60

    /// The earliest next automatic check after a failed poll, or nil when the
    /// failure keeps the regular cadence.
    static func backoff(after error: Error, at now: Date) -> Date? {
        switch error as? FolyncPortfolioSourceError {
        case .unauthorized:
            return now.addingTimeInterval(unauthorizedRetryDelay)
        case .rateLimited(let retryAfter):
            let regular = nextRegularCheck(after: now)
            guard let retryAfter else { return regular }
            return max(regular, now.addingTimeInterval(retryAfter))
        default:
            return nil
        }
    }

    /// How long to wait after `consecutiveFailures` failed polls in a row:
    /// the regular minute, then two minutes, then five. A server that is down
    /// or a tailnet that is away is not asked again every minute for hours.
    static func repeatedFailureDelay(consecutiveFailures: Int) -> TimeInterval {
        switch consecutiveFailures {
        case ...1: return interval
        case 2: return 120
        default: return 300
        }
    }

    /// The earliest next automatic check after `consecutiveFailures` failed
    /// polls, or nil while the regular cadence still applies.
    static func repeatedFailureBackoff(consecutiveFailures: Int, at now: Date) -> Date? {
        let delay = repeatedFailureDelay(consecutiveFailures: consecutiveFailures)
        return delay > interval ? now.addingTimeInterval(delay) : nil
    }

    /// A short, stable name for why a poll failed, for the log.
    static func failureCategory(_ error: Error) -> String {
        if let sourceError = error as? FolyncPortfolioSourceError {
            switch sourceError {
            case .unauthorized: return "unauthorized"
            case .rateLimited: return "rate-limited"
            case .unavailable(let status): return "http-\(status)"
            case .unsupportedSchema: return "unsupported-schema"
            case .invalidPayload, .invalidResponse: return "invalid-response"
            case .missingToken: return "missing-token"
            case .invalidEndpoint, .insecureTransport, .invalidScope: return "configuration"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "offline"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "unreachable"
            case .cancelled: return "cancelled"
            default: return "network-\(urlError.code.rawValue)"
            }
        }
        if error is DecodingError { return "invalid-response" }
        return "other"
    }

    /// True for an address on this Mac, which needs no network to reach.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static func nextRegularCheck(after now: Date) -> Date {
        let minute = floor(now.timeIntervalSince1970 / interval) * interval
        let target = minute + publicationDelay
        return Date(timeIntervalSince1970: target > now.timeIntervalSince1970 ? target : target + interval)
    }

    static func needsCatchUp(providerSyncAt: Date?, checkStartedAt: Date, completedAt: Date) -> Bool {
        guard let providerSyncAt else { return false }
        let expectedCycle = floor(checkStartedAt.timeIntervalSince1970 / interval) * interval
        let age = checkStartedAt.timeIntervalSince(providerSyncAt)
        // Unknown, future or long-stale timestamps cannot establish a running cycle.
        // Do not add a retry if the normal next check is already due soon.
        return providerSyncAt.timeIntervalSince1970 < expectedCycle
            && age >= 0 && age <= 3 * interval
            && completedAt.addingTimeInterval(catchUpDelay) < nextRegularCheck(after: checkStartedAt)
    }
}

actor FolyncBackoffCoordinator {
    static let shared = FolyncBackoffCoordinator()

    private var backoffUntil: Date?

    init(backoffUntil: Date? = nil) {
        self.backoffUntil = backoffUntil
    }

    func until() -> Date? {
        backoffUntil
    }

    func isBackingOff(at now: Date = Date()) -> Bool {
        guard let backoffUntil else { return false }
        return backoffUntil > now
    }

    @discardableResult
    func recordFailure(_ error: Error, at now: Date = Date()) -> Date? {
        guard let next = FolyncRefreshSchedule.backoff(after: error, at: now) else {
            return backoffUntil
        }
        if let existing = backoffUntil, existing > next {
            return existing
        }
        backoffUntil = next
        return next
    }

    func clear() {
        backoffUntil = nil
    }

    func set(_ date: Date?) {
        backoffUntil = date
    }
}
