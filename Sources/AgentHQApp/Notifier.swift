import AgentHQKit
import Foundation
import UserNotifications

/// Delivers what the policy decided is worth interrupting the user about, and
/// routes the click back to the agent it named.
///
/// The policy owns every question of *whether* to say something; this only
/// says it, and only reports which one was clicked. Keeping the decision out of
/// here is what makes the rules testable without a notification centre.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Persisted, and off until the user turns it on. A menu-bar app that asks
    /// for notification permission before it has shown the user anything has
    /// not earned the prompt.
    private static let enabledKey = "notificationsEnabled"

    /// On by default, unlike ``isEnabled`` — it only takes effect once the
    /// user has turned notifications on at all, so it costs them nothing
    /// unasked. A user who wants the stuck-agent alerts and not the
    /// completions turns this one off; the reverse preference is the one the
    /// product exists to serve, so it is not the one that needs opting in.
    private static let completionsKey = "notifyOnCompletion"

    private var isAuthorized = false

    /// Called when a notification is clicked. A nil ref is a notification that
    /// named no single agent — a batch, or a machine going unreachable — and
    /// the panel simply opens.
    var onOpen: (@MainActor (AgentRef?) -> Void)?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { requestAuthorization() }
        }
    }

    var announcesCompletions: Bool {
        get {
            // `bool(forKey:)` is false for an unset key, so the default has to
            // be spelled out rather than inherited from UserDefaults.
            UserDefaults.standard.object(forKey: Self.completionsKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.completionsKey) }
    }

    func prepare() {
        // `current()` traps outside an application bundle, which is how
        // `swift run` launches this. Development runs simply have no
        // notifications rather than a crash.
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Set before authorization, not after: a click that arrives the moment
        // the user enables notifications still has to route back here.
        UNUserNotificationCenter.current().delegate = self
        guard isEnabled else { return }
        requestAuthorization()
    }

    private func requestAuthorization() {
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
        // One agent can be named in the click target. A batch cannot: which of
        // five the user meant is unknowable, so it opens the panel unfocused.
        if batch.announcements.count == 1, let ref = batch.announcements[0].subject.ref {
            content.userInfo = ["machine": ref.machine.raw, "pane": ref.agent.raw]
        }

        UNUserNotificationCenter.current().add(
            // No trigger: deliver now. A batch is already the coalesced form,
            // so there is nothing here to rate-limit further.
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
        )
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// A menu-bar app is "active" whenever its panel is open, and the default
    /// is to suppress a banner for the active app. A blocked agent is worth the
    /// banner either way.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let ref: AgentRef? = {
            guard let machine = info["machine"] as? String,
                  let pane = info["pane"] as? String
            else { return nil }
            return AgentRef(machine: MachineID(machine), agent: AgentID(pane))
        }()
        await MainActor.run { self.onOpen?(ref) }
    }
}
