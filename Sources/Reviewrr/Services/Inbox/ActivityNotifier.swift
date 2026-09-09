import Foundation

/// Turns "here's what a poll just found" into an in-app activity feed and,
/// opt-in, system notifications.
///
/// The decisions live in `PRChangeDetector` and `NotificationPolicy`, which
/// are pure; this owns the feed, the per-poll batching, and the wording. The
/// split matters because the interesting part — whether a given change should
/// interrupt a given reviewer at a given moment — is a rule with a dozen
/// inputs, and it has to be checkable without a Mac in front of it.
@MainActor
final class ActivityNotifier {
    struct Event: Identifiable, Equatable {
        enum Kind: Equatable { case newPR, updatedPR, newReviewRequest }
        let id = UUID()
        let projectKey: String
        let projectName: String
        let kind: Kind
        let pr: InboxPR
        /// What actually moved, for an update. Empty for a new pull request.
        var triggers: Set<PRUpdateTrigger> = []
        /// Whether this event also went out as a system notification, so the
        /// feed can show which ones interrupted the reviewer.
        var wasNotified = false
        let occurredAt = Date()

        /// One line naming what happened, in the reviewer's terms.
        var summary: String {
            switch kind {
            case .newPR: return "Opened by \(pr.authorLogin)"
            case .newReviewRequest: return "Your review was requested"
            case .updatedPR: return ActivityNotifier.describe(triggers) ?? "Updated"
            }
        }
    }

    private(set) var recentEvents: [Event] = []
    private let maxRecentEvents = 50

    private let notifications: NotificationService

    init(notifications: NotificationService) {
        self.notifications = notifications
    }

    /// Everything about the moment that isn't the project or its rows.
    struct SyncContext {
        var settings: AppSettings
        var ignoredKeys: Set<String>
        /// Who is signed in, when the dashboard has been able to work it out.
        /// Only used to recognise the reviewer's own pull requests.
        var viewerLogin: String?
        var isAppActive: Bool
        var now: Date

        init(
            settings: AppSettings,
            ignoredKeys: Set<String>,
            viewerLogin: String? = nil,
            isAppActive: Bool = false,
            now: Date = Date()
        ) {
            self.settings = settings
            self.ignoredKeys = ignoredKeys
            self.viewerLogin = viewerLogin
            self.isAppActive = isAppActive
            self.now = now
        }
    }

    /// Diffs a project's previous and new row snapshots, records what changed
    /// in the feed, and notifies about whatever the reviewer asked to be
    /// notified about.
    ///
    /// Rows in `ignoredKeys` never produce anything: an ignored pull request
    /// produces no counts and no alerts until the reviewer changes that.
    @discardableResult
    func noteSync(
        project: WatchedProject,
        previousRows: [InboxPR],
        newRows: [InboxPR],
        context: SyncContext
    ) -> [Event] {
        let settings = context.settings
        guard !project.isMuted else { return [] }
        guard settings.inAppActivityEnabled || settings.notifications.enabled else { return [] }

        let changes = PRChangeDetector
            .changes(previous: previousRows, current: newRows)
            .filter { !context.ignoredKeys.contains($0.pr.statusKey) }
        guard !changes.isEmpty else { return [] }

        let policyContext = NotificationPolicy.Context(
            preferences: settings.notifications,
            projectLevel: project.notificationLevel,
            isProjectMuted: project.isMuted,
            viewerLogin: context.viewerLogin,
            isAppActive: context.isAppActive,
            now: context.now
        )

        var events: [Event] = []
        var notifiable: [Event] = []
        for change in changes {
            var event = Self.event(for: change, project: project)
            if NotificationPolicy.decide(change, context: policyContext).shouldNotify {
                event.wasNotified = true
                notifiable.append(event)
            }
            events.append(event)
        }

        if settings.inAppActivityEnabled {
            recentEvents.append(contentsOf: events)
            if recentEvents.count > maxRecentEvents {
                recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
            }
        }
        deliver(notifiable, project: project, preferences: settings.notifications)
        return events
    }

    func clear() {
        recentEvents.removeAll()
    }

    // MARK: - Wording

    private static func event(for change: PRChange, project: WatchedProject) -> Event {
        let kind: Event.Kind
        switch change {
        case .appeared:
            kind = change.pr.buckets.contains(.needsReview) ? .newReviewRequest : .newPR
        case .changed(_, _, let triggers):
            kind = triggers.contains(.reviewRequested) ? .newReviewRequest : .updatedPR
        }
        return Event(
            projectKey: project.key,
            projectName: project.nameWithOwner,
            kind: kind,
            pr: change.pr,
            triggers: change.triggers
        )
    }

    /// What a set of triggers reads as in one line.
    ///
    /// `nonisolated`: `Event.summary` is a value read from wherever an event
    /// happens to be held, and the wording depends on nothing but the
    /// triggers.
    ///
    /// Ordered by what changes a reviewer's next action, not alphabetically:
    /// "your review is requested" outranks "checks passed" every time, and a
    /// notification body has room for one clause, not five.
    nonisolated static func describe(_ triggers: Set<PRUpdateTrigger>) -> String? {
        let ranked: [(PRUpdateTrigger, String)] = [
            (.reviewRequested, "Your review was requested"),
            (.merged, "Merged"),
            (.closed, "Closed without merging"),
            (.readyForReview, "Ready for review"),
            (.reviewDecision, "Review submitted"),
            (.newCommits, "New commits pushed"),
            (.newComments, "New comments"),
            (.checksChanged, "Checks updated"),
        ]
        guard let first = ranked.first(where: { triggers.contains($0.0) }) else { return nil }
        let others = triggers.count - 1
        guard others > 0 else { return first.1 }
        return "\(first.1) · \(others) more change\(others == 1 ? "" : "s")"
    }

    // MARK: - Delivery

    private func deliver(_ events: [Event], project: WatchedProject, preferences: NotificationPreferences) {
        guard !events.isEmpty else { return }
        let thread = preferences.groupByProject ? "reviewrr.project.\(project.key)" : nil

        // Past the cap, one line instead of a stack of banners. A reviewer
        // back from lunch to a forty-row sync wants to know it happened, not
        // to dismiss forty notifications to find out.
        guard events.count <= max(1, preferences.maxPerPoll) else {
            let requests = events.filter { $0.kind == .newReviewRequest }.count
            var body = "\(events.count) pull requests changed"
            if requests > 0 {
                body += " · \(requests) waiting on your review"
            }
            notifications.deliver(
                NotificationService.Payload(
                    identifier: "reviewrr.summary.\(project.key).\(Int(Date().timeIntervalSince1970))",
                    title: project.nameWithOwner,
                    subtitle: nil,
                    body: body,
                    threadIdentifier: thread,
                    playSound: preferences.playSound,
                    reference: nil,
                    host: project.host
                )
            )
            return
        }

        for event in events {
            notifications.deliver(
                NotificationService.Payload(
                    identifier: "reviewrr.event.\(event.id.uuidString)",
                    title: Self.notificationTitle(for: event),
                    subtitle: "\(event.projectName) · #\(event.pr.number)",
                    body: event.pr.title,
                    threadIdentifier: thread,
                    playSound: preferences.playSound,
                    reference: event.pr.reference,
                    // The row's own host, not the active one: a click has to
                    // land on the server the pull request came from.
                    host: event.pr.host
                )
            )
        }
    }

    /// The title is the *event*, not the repository: Notification Centre
    /// shows the app name already, and the subtitle carries the project. A
    /// title of "acme/web-app" told the reviewer nothing they could act on.
    private static func notificationTitle(for event: Event) -> String {
        switch event.kind {
        case .newReviewRequest: return "Review requested"
        case .newPR: return "New pull request"
        case .updatedPR: return describe(event.triggers) ?? "Pull request updated"
        }
    }
}
