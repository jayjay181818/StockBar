import Foundation
@preconcurrency import UserNotifications

/// Posts informational system notifications through UserNotifications.
///
/// Replaces the deprecated `NSUserNotification` API. Authorization is requested
/// on first use (price alerts already request the same options), and posting is
/// skipped silently when the user has declined notifications.
enum StockbarNotificationPoster {
    static func post(title: String, body: String, playSound: Bool = true) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .denied:
            return
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            await Logger.shared.warning("Failed to post notification '\(title)': \(error.localizedDescription)")
        }
    }
}
