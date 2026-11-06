import XCTest
@testable import Stockbar

final class FolyncStatusAnnouncementTests: XCTestCase {
    @MainActor
    func testAnnouncerPostsTrimmedNonEmptyMessages() {
        var announcements: [String] = []
        let announcer = FolyncStatusAccessibilityAnnouncer { announcements.append($0) }

        announcer.announce("  Connected.  ")
        announcer.announce("   ")

        XCTAssertEqual(announcements, ["Connected."])
    }

    func testBackgroundChecksAnnounceEachProblemOnceUntilRecovery() {
        var policy = FolyncStatusAnnouncementPolicy()
        let offline = FolyncConnectionState.offlineCached(message: "Network unavailable")

        // Routine progress and a healthy connection stay quiet
        XCTAssertNil(policy.announcement(for: .connecting))
        XCTAssertNil(policy.announcement(for: .current(asOf: "2026-11-06T20:00:00Z")))

        // A problem is announced once, not on every minute's check
        XCTAssertEqual(policy.announcement(for: offline), offline.message)
        XCTAssertNil(policy.announcement(for: .connecting))
        XCTAssertNil(policy.announcement(for: offline))

        // After recovery the same problem is news again
        XCTAssertNil(policy.announcement(for: .current(asOf: "2026-11-06T20:01:00Z")))
        XCTAssertEqual(policy.announcement(for: offline), offline.message)

        // A different problem is announced straight away
        XCTAssertEqual(policy.announcement(for: .unauthorized), FolyncConnectionState.unauthorized.message)
    }

    func testRateLimitCountdownIsAnnouncedOnce() {
        var policy = FolyncStatusAnnouncementPolicy()
        let first = FolyncConnectionState.rateLimited(retryAfter: 120)

        XCTAssertEqual(policy.announcement(for: first), first.message)
        XCTAssertNil(policy.announcement(for: .rateLimited(retryAfter: 60)))
        XCTAssertNil(policy.announcement(for: .rateLimited(retryAfter: nil)))
    }

    func testWaitingForKeychainIsAnnouncedBecauseItNeedsTheUser() {
        var policy = FolyncStatusAnnouncementPolicy()

        XCTAssertEqual(
            policy.announcement(for: .waitingForKeychain),
            FolyncConnectionState.waitingForKeychain.message
        )
        XCTAssertNil(policy.announcement(for: .waitingForKeychain))
    }

    func testManualRefreshAlwaysAnswersAndQuietensTheNextBackgroundCheck() {
        var policy = FolyncStatusAnnouncementPolicy()
        let current = FolyncConnectionState.current(asOf: "2026-11-06T20:00:00Z")
        let offline = FolyncConnectionState.offlineCached(message: "Network unavailable")

        XCTAssertEqual(policy.manualRefreshAnnouncement(for: current), "Refresh complete. \(current.message)")

        // Every manual refresh gets an answer, even when nothing changed
        XCTAssertEqual(policy.announcement(for: offline), offline.message)
        XCTAssertEqual(policy.manualRefreshAnnouncement(for: offline), "Refresh complete. \(offline.message)")
        XCTAssertEqual(policy.manualRefreshAnnouncement(for: offline), "Refresh complete. \(offline.message)")

        // A problem reported by a manual refresh is not repeated by the next background check
        var manualFirst = FolyncStatusAnnouncementPolicy()
        XCTAssertEqual(manualFirst.manualRefreshAnnouncement(for: offline), "Refresh complete. \(offline.message)")
        XCTAssertNil(manualFirst.announcement(for: offline))
    }
}
