import Foundation
import UserNotifications

/// Banners for profile switches and problems. Which ones are shown is up
/// to `AppState` (Settings ▸ General); this just posts them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when a notification is clicked.
    var onClick: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once; macOS remembers the answer. `completion` gets whether
    /// notifications are allowed.
    func requestPermission(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    /// nil until the user has been asked.
    func checkPermission(completion: @escaping @MainActor @Sendable (Bool?) -> Void) {
        center.getNotificationSettings { settings in
            let allowed: Bool?
            switch settings.authorizationStatus {
            case .notDetermined: allowed = nil
            case .denied: allowed = false
            default: allowed = true
            }
            Task { @MainActor in completion(allowed) }
        }
    }

    /// A notification with the same `id` replaces the one before it.
    func post(id: String = UUID().uuidString, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while a ContextSwitch window is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { onClick?() }
    }
}
