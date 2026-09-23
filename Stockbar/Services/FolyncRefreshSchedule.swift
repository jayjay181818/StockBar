import Foundation

/// Folync's broker job starts on minute boundaries. This is a polling estimate,
/// not proof that its provider request has completed.
enum FolyncRefreshSchedule {
    static let interval: TimeInterval = 60
    static let publicationDelay: TimeInterval = 5
    static let catchUpDelay: TimeInterval = 10

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
