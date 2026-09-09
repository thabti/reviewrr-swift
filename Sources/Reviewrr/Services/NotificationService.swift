import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// What macOS currently thinks about Reviewrr posting notifications.
enum NotificationPermission: Equatable, Sendable {
    /// Not asked yet, and not asked on our own initiative either — the
    /// prompt goes up when the reviewer turns notifications on.
    case notAsked
    case allowed
    /// Allowed, but silently: banners are off in System Settings, so a
    /// notification lands in Notification Centre and nowhere else. Worth
    /// saying, because "it's on and nothing happens" is otherwise a bug
    /// report.
    case allowedQuietly
    case denied
    /// No notification centre to talk to — a unit test, a preview, or a
    /// process with no bundle identifier.
    case unavailable

    var canDeliver: Bool { self == .allowed || self == .allowedQuietly }

    var label: String {
        switch self {
        case .notAsked: return "Not requested yet"
        case .allowed: return "Allowed"
        case .allowedQuietly: return "Allowed, but banners are off"
        case .denied: return "Refused in System Settings"
        case .unavailable: return "Unavailable in this build"
        }
    }

    /// What the reviewer can do about it, when there is something.
    var remedy: String? {
        switch self {
        case .notAsked, .allowed, .unavailable:
            return nil
        case .allowedQuietly:
            return "Reviewrr can post notifications, but macOS is set to deliver them silently. Turn on “Allow Notifications” and choose a banner style for Reviewrr in System Settings ▸ Notifications."
        case .denied:
            return "macOS is blocking Reviewrr's notifications. Allow them for Reviewrr in System Settings ▸ Notifications, then check again here."
        }
    }
}

/// Posts system notifications, and owns the two halves of that everyone
/// forgets: asking permission, and doing something when one is clicked.
///
/// The old implementation called `UNUserNotificationCenter.add` and nothing
/// else — no authorization request, so every notification was dropped before
/// it reached the screen, and no delegate, so any that did arrive did nothing
/// when clicked and never appeared at all while Reviewrr was frontmost.
///
/// Everything is guarded on having a real app bundle: `UNUserNotificationCenter`
/// traps in a process without a bundle identifier, which is every unit test
/// and SwiftUI preview.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    /// Set when a notification is clicked, for `RootView` to consume. A
    /// published value rather than a callback into `AppModel` so this service
    /// stays usable from a test and from a preview.
    @Published private(set) var pendingOpen: PRReference?
    @Published private(set) var permission: NotificationPermission = .notAsked
    /// Set when a delivery attempt failed, so the settings pane can say so
    /// instead of leaving the reviewer to wonder.
    @Published private(set) var lastDeliveryError: String?

    /// Notification Centre groups by this; one thread per project when the
    /// reviewer asked for grouping.
    static let categoryIdentifier = "reviewrr.pullRequest"
    private static let referenceKey = "reviewrr.reference"

    private var isAvailable: Bool {
        #if canImport(UserNotifications)
        return Bundle.main.bundleIdentifier != nil
        #else
        return false
        #endif
    }

    /// Registers as the notification delegate and reads the current
    /// permission. Called once at launch — before that, a notification
    /// clicked from Notification Centre would launch the app and be dropped.
    func start() {
        #if canImport(UserNotifications)
        guard isAvailable else {
            permission = .unavailable
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: "reviewrr.open",
                        title: "Open in Reviewrr",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
        Task { await refreshPermission() }
        #else
        permission = .unavailable
        #endif
    }

    /// Reads the permission macOS holds, without prompting.
    func refreshPermission() async {
        #if canImport(UserNotifications)
        guard isAvailable else {
            permission = .unavailable
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = Self.permission(from: settings)
        #endif
    }

    /// Asks macOS for permission, and reports what came back.
    ///
    /// Only ever called from the reviewer turning notifications on: an
    /// unprompted permission panel at launch is the fastest way to get told
    /// "no" permanently.
    @discardableResult
    func requestPermission() async -> NotificationPermission {
        #if canImport(UserNotifications)
        guard isAvailable else {
            permission = .unavailable
            return permission
        }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            lastDeliveryError = error.localizedDescription
        }
        await refreshPermission()
        return permission
        #else
        permission = .unavailable
        return permission
        #endif
    }

    /// One notification. `threadIdentifier` groups it in Notification Centre.
    struct Payload {
        var identifier: String
        var title: String
        var subtitle: String?
        var body: String
        var threadIdentifier: String?
        var playSound: Bool
        /// The pull request to open when it is clicked.
        var reference: PRReference?
    }

    func deliver(_ payload: Payload) {
        #if canImport(UserNotifications)
        guard isAvailable, permission.canDeliver else { return }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let subtitle = payload.subtitle { content.subtitle = subtitle }
        content.body = payload.body
        content.categoryIdentifier = Self.categoryIdentifier
        if let thread = payload.threadIdentifier { content.threadIdentifier = thread }
        if payload.playSound { content.sound = .default }
        if let reference = payload.reference {
            content.userInfo = [Self.referenceKey: reference.key]
        }
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastDeliveryError = error.localizedDescription }
        }
        #endif
    }

    /// Posts one notification so the reviewer can see what their settings
    /// actually produce, rather than waiting for a real pull request.
    func deliverTest() async {
        if !permission.canDeliver { await requestPermission() }
        deliver(
            Payload(
                identifier: "reviewrr.test.\(UUID().uuidString)",
                title: "Reviewrr notifications are working",
                subtitle: "acme/web-app",
                body: "#482 Add teammate invitations with roles",
                threadIdentifier: "reviewrr.test",
                playSound: true,
                reference: nil
            )
        )
    }

    func consumePendingOpen() {
        pendingOpen = nil
    }

    #if canImport(UserNotifications)
    private static func permission(from settings: UNNotificationSettings) -> NotificationPermission {
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notAsked
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            // Authorized with every presentation style off is the state that
            // looks exactly like a broken app.
            let showsBanner = settings.alertSetting == .enabled
            let showsInCentre = settings.notificationCenterSetting == .enabled
            return showsBanner || showsInCentre ? .allowed : .allowedQuietly
        @unknown default:
            return .notAsked
        }
    }
    #endif
}

#if canImport(UserNotifications)
extension NotificationService: UNUserNotificationCenterDelegate {
    /// Without this, macOS drops every notification posted while Reviewrr is
    /// the frontmost app — which is most of them, since polling only runs
    /// while the app is open. Whether a foreground notification is *wanted*
    /// is the reviewer's call, made in `NotificationPreferences` before we
    /// ever get here.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A click opens the pull request. The reference travels in `userInfo`
    /// rather than as a `reviewrr://` URL because this path does not need the
    /// round trip through the deep-link parser — but it is the same
    /// destination, so both entry points land in one place.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo[Self.referenceKey] as? String
        Task { @MainActor [weak self] in
            if let key, let reference = PRReference.parse(key) {
                self?.pendingOpen = reference
            }
            completionHandler()
        }
    }
}
#endif
