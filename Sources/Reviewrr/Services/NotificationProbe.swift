import Foundation

/// `REVIEWRR_NOTIFY_TEST=1` — post one notification at launch and say, on
/// stderr, what macOS did with it.
///
/// The rest of this feature is checkable without a Mac: `NotificationPolicy`
/// decides, `PRChangeDetector` detects, and both are pure and unit-tested.
/// The one part that is not is the part that fails silently — permission,
/// and whether `UNUserNotificationCenter` accepted the request — and the
/// only control that exercises it lives behind a button in a settings pane.
/// This is that button, reachable from a terminal, so "do notifications
/// work on this machine" has an answer that does not depend on a person
/// clicking and watching.
///
/// Off unless the variable is set, so a shipped run never sees it.
enum NotificationProbe {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["REVIEWRR_NOTIFY_TEST"] == "1"
    }

    /// Prompts if it has to, posts one, and reports. Quits afterwards: the
    /// probe is a command, not a session, and leaving a window behind means
    /// the next run finds the app already open and does nothing.
    @MainActor
    static func run(_ service: NotificationService) async {
        await service.refreshPermission()
        report("permission before: \(service.permission.label)")
        // Prompts when macOS has not been asked yet, which is the same path
        // the settings switch takes.
        let sent = await service.deliverTest()
        report("permission after:  \(service.permission.label)")
        guard sent else {
            report("nothing posted — \(service.lastDeliveryError ?? "no reason reported")")
            exit(1)
        }
        // Long enough for the banner to appear before the app goes away, and
        // long enough for the notification centre to answer: `add` reports a
        // rejected request through a completion handler, so exiting the
        // instant the request is handed over would call every failure a pass.
        try? await Task.sleep(for: .seconds(3))
        if let error = service.lastDeliveryError {
            report("rejected by the notification centre — \(error)")
            exit(1)
        }
        report("posted, and not rejected — a banner, or an entry in Notification Centre, is the pass")
        exit(0)
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data("notify-test: \(line)\n".utf8))
    }
}
