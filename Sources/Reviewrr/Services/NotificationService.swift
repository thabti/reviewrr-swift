import AppKit
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
/// Everything is guarded on `isAvailable` — the process being an application
/// bundle — because `UNUserNotificationCenter.current()` traps outside one,
/// which is every unit test and SwiftUI preview.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    /// What a clicked notification asks the window to open.
    ///
    /// The host travels with the reference because a reference alone cannot
    /// say which server it belongs to: a watchlist mixes GitHub and GitLab,
    /// and opening a merge request against whichever host happened to be
    /// selected fetched the wrong thing — or nothing.
    struct Target: Equatable {
        var reference: PRReference
        /// `nil` when the notification predates this field, or came from
        /// somewhere with no host to name; the window then falls back to the
        /// active host, which is the old behaviour.
        var host: ForgeHost?
    }

    /// Set when a notification is clicked, for `RootView` to consume. A
    /// published value rather than a callback into `AppModel` so this service
    /// stays usable from a test and from a preview.
    @Published private(set) var pendingOpen: Target?
    @Published private(set) var permission: NotificationPermission = .notAsked
    /// Set when a delivery attempt failed, so the settings pane can say so
    /// instead of leaving the reviewer to wonder.
    @Published private(set) var lastDeliveryError: String?

    /// Notification Centre groups by this; one thread per project when the
    /// reviewer asked for grouping.
    static let categoryIdentifier = "reviewrr.pullRequest"
    // `nonisolated`: read from the notification-centre delegate callbacks,
    // which macOS makes on no particular actor.
    private nonisolated static let referenceKey = "reviewrr.reference"
    private nonisolated static let hostKey = "reviewrr.host"

    /// Torn down with the service so a notification observer does not
    /// outlive it.
    private var activationObserver: NSObjectProtocol?

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Whether there is a notification centre to talk to at all.
    ///
    /// A bundle identifier is not the test: the xctest agent has one, and
    /// `UNUserNotificationCenter.current()` still trapped there with
    /// "bundleProxyForCurrentProcess is nil" — so the guard that was meant to
    /// keep this type usable from a test did not, and any test that touched
    /// permission killed the whole run. What macOS actually requires is that
    /// the running process *is* an application bundle.
    private var isAvailable: Bool {
        #if canImport(UserNotifications)
        return Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
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
        observeActivation()
        Task { await refreshPermission() }
        #else
        permission = .unavailable
        #endif
    }

    /// Re-reads the permission every time Reviewrr comes to the front.
    ///
    /// A reviewer who allows (or refuses) notifications in System Settings
    /// does it in another app and then comes back here. Without this the
    /// service kept the answer it read at launch: a freshly granted
    /// permission delivered nothing, and the pane went on reporting a
    /// refusal that had already been lifted, until the app was relaunched.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshPermission() }
        }
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
        /// Which server that pull request lives on. Carried so a click lands
        /// on the right one rather than on whichever host is selected when
        /// the reviewer gets round to clicking.
        var host: ForgeHost?
    }

    /// Hands one notification to macOS. Returns whether it got that far —
    /// `false` means permission is missing, not that delivery failed, which
    /// is reported asynchronously through `lastDeliveryError`.
    @discardableResult
    func deliver(_ payload: Payload) -> Bool {
        #if canImport(UserNotifications)
        guard isAvailable, permission.canDeliver else { return false }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let subtitle = payload.subtitle { content.subtitle = subtitle }
        content.body = payload.body
        content.categoryIdentifier = Self.categoryIdentifier
        if let thread = payload.threadIdentifier { content.threadIdentifier = thread }
        if payload.playSound { content.sound = .default }
        if let reference = payload.reference {
            content.userInfo = Self.userInfo(reference: reference, host: payload.host)
        }
        let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastDeliveryError = error.localizedDescription }
        }
        return true
        #else
        return false
        #endif
    }

    /// Posts one notification so the reviewer can see what their settings
    /// actually produce, rather than waiting for a real pull request.
    ///
    /// Returns whether anything was actually posted. It used to return
    /// nothing and the pane said "Sent" either way — so the one control
    /// whose entire job is to prove notifications work reported success
    /// while silently posting nothing, which is the exact failure it exists
    /// to catch.
    @discardableResult
    func deliverTest() async -> Bool {
        if !permission.canDeliver { await requestPermission() }
        guard permission.canDeliver else {
            lastDeliveryError = permission.remedy
                ?? "macOS has not been asked for permission yet, so nothing could be posted."
            return false
        }
        lastDeliveryError = nil
        return deliver(
            Payload(
                identifier: "reviewrr.test.\(UUID().uuidString)",
                title: "Reviewrr notifications are working",
                subtitle: "acme/web-app",
                body: "#482 Add teammate invitations with roles",
                threadIdentifier: "reviewrr.test",
                playSound: true,
                reference: nil,
                host: nil
            )
        )
    }

    func consumePendingOpen() {
        pendingOpen = nil
    }

    // MARK: - What a notification carries
    //
    // The two halves of one format, kept next to each other and pure so the
    // round trip is checkable without a notification centre. Everything a
    // click needs has to survive in `userInfo`: the delegate is handed the
    // posted notification and nothing else, and by then the poll that
    // produced it is long gone.

    /// What travels with a notification so a click can open the right pull
    /// request on the right server.
    nonisolated static func userInfo(reference: PRReference, host: ForgeHost?) -> [String: Any] {
        var info: [String: Any] = [referenceKey: reference.key]
        // JSON rather than the host's fields spread across `userInfo`:
        // `ForgeHost` already knows how to encode itself, and a plist
        // dictionary assembled by hand here would drift from it the next
        // time a field is added.
        if let host, let encoded = try? JSONEncoder().encode(host) {
            info[hostKey] = String(decoding: encoded, as: UTF8.self)
        }
        return info
    }

    /// Reads it back. `nil` when the notification carries no reference —
    /// the test notification, and the per-project summary, are not a
    /// destination.
    nonisolated static func target(from info: [AnyHashable: Any]) -> Target? {
        guard let key = info[referenceKey] as? String,
              let reference = PRReference.parse(key)
        else { return nil }
        let host = (info[hostKey] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ForgeHost.self, from: $0) }
        return Target(reference: reference, host: host)
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
        let target = Self.target(from: response.notification.request.content.userInfo)
        Task { @MainActor [weak self] in
            if let target { self?.pendingOpen = target }
            completionHandler()
        }
    }
}
#endif
