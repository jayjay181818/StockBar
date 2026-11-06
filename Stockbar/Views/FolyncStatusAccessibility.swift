import AppKit

/// Speaks Folync status changes to VoiceOver. The Folync section shows its
/// status as caption text that changes after asynchronous work, which VoiceOver
/// would otherwise not read.
@MainActor
struct FolyncStatusAccessibilityAnnouncer {
    private let postAnnouncement: (String) -> Void

    init(postAnnouncement: @escaping (String) -> Void) {
        self.postAnnouncement = postAnnouncement
    }

    func announce(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        postAnnouncement(trimmed)
    }

    static let live = FolyncStatusAccessibilityAnnouncer { message in
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Folync status: \(message)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// Decides which background connection-state changes are worth announcing.
/// Folync is checked every minute, so routine progress and repeated problems
/// stay quiet; a problem is announced once, and again only after the
/// connection has recovered or the problem has changed.
struct FolyncStatusAnnouncementPolicy {
    private var lastAnnouncedIssue: String?

    mutating func announcement(for state: FolyncConnectionState) -> String? {
        guard let issue = Self.issueKey(for: state) else {
            if case .current = state { lastAnnouncedIssue = nil }
            return nil
        }
        guard issue != lastAnnouncedIssue else { return nil }
        lastAnnouncedIssue = issue
        return state.message
    }

    /// A refresh the user asked for always gets an answer, and counts as
    /// having announced its outcome so the next background check stays quiet.
    mutating func manualRefreshAnnouncement(for state: FolyncConnectionState) -> String {
        if let issue = Self.issueKey(for: state) {
            lastAnnouncedIssue = issue
            return "Refresh complete. \(state.message)"
        }
        if case .current = state {
            lastAnnouncedIssue = nil
            return "Refresh complete. \(state.message)"
        }
        return state.message
    }

    /// Identifies a problem state for de-duplication, or nil when the state is
    /// not a problem. A rate limit is one problem however long the wait is,
    /// so its countdown does not trigger a new announcement every check.
    private static func issueKey(for state: FolyncConnectionState) -> String? {
        switch state {
        case .notConfigured, .connecting, .current:
            return nil
        case .rateLimited:
            return "rate-limited"
        case .waitingForKeychain, .stale, .rebuilding, .offlineCached, .unauthorized, .unavailable, .incompatible:
            return state.message
        }
    }
}
