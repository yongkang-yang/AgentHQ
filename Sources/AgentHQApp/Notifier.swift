import AgentHQKit
import Foundation
import UserNotifications

/// Delivers what the policy decided is worth interrupting the user about.
///
/// The policy owns every question of *whether* to say something; this only
/// says it. Keeping the decision out of here is what makes the rules testable
/// without a notification centre.
@MainActor
final class Notifier {
    /// Persisted, and off until the user turns it on. A menu-bar app that asks
    /// for notification permission before it has shown the user anything has
    /// not earned the prompt.
    private static let enabledKey = "notificationsEnabled"

    private var isAuthorized = false

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    func prepare() {
        guard isEnabled else { return }
        requestAuthorization()
    }

    private func requestAuthorization() {
        // `current()` traps outside an application bundle, which is how
        // `swift run` launches this. Development runs simply have no
        // notifications rather than a crash.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.isAuthorized = granted }
        }
    }

    func deliver(_ batch: AnnouncementBatch) {
        guard isEnabled, isAuthorized, !batch.isEmpty else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = batch.title
        content.body = batch.body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            // No trigger: deliver now. A batch is already the coalesced form,
            // so there is nothing here to rate-limit further.
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
        )
    }
}
