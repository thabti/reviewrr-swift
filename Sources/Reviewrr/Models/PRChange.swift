import Foundation

/// What a poll found about one pull request, and whether it is worth
/// interrupting the reviewer for.
///
/// Pure value logic, deliberately separate from the thing that posts
/// notifications: "should this notify?" is a rule with a dozen inputs, and a
/// rule that can only be checked by watching a real Mac's Notification Centre
/// is a rule nobody checks.
enum PRChange {
    /// A pull request that was not in the previous snapshot.
    case appeared(InboxPR)
    /// A pull request that was already there, plus what moved.
    case changed(InboxPR, previous: InboxPR, triggers: Set<PRUpdateTrigger>)

    var pr: InboxPR {
        switch self {
        case .appeared(let pr): return pr
        case .changed(let pr, _, _): return pr
        }
    }

    var triggers: Set<PRUpdateTrigger> {
        switch self {
        case .appeared: return []
        case .changed(_, _, let triggers): return triggers
        }
    }
}

/// Diffs poll snapshots into changes.
enum PRChangeDetector {
    /// Every difference between two snapshots of one project's rows.
    ///
    /// Rows that vanished produce nothing: a pull request leaving the sync
    /// window (closed long enough ago, or filtered out server-side) is not an
    /// event, and announcing it would mean announcing every old PR the day
    /// the query changes.
    static func changes(previous: [InboxPR], current: [InboxPR]) -> [PRChange] {
        // A first sync has nothing to compare against, and treating all of it
        // as new would notify once per open pull request the first time a
        // project is watched — the single worst first impression this feature
        // could make.
        guard !previous.isEmpty else { return [] }
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.compactMap { row in
            guard let before = previousByID[row.id] else { return .appeared(row) }
            let triggers = self.triggers(from: before, to: row)
            return triggers.isEmpty ? nil : .changed(row, previous: before, triggers: triggers)
        }
    }

    /// What moved between two sightings of the same pull request.
    static func triggers(from before: InboxPR, to after: InboxPR) -> Set<PRUpdateTrigger> {
        var triggers: Set<PRUpdateTrigger> = []

        // Only when both sightings actually carry a SHA: search-sourced rows
        // omit it, and `nil` → a value is the field arriving, not a push.
        if let old = before.headSha, let new = after.headSha, old != new {
            triggers.insert(.newCommits)
        }
        if after.commentCount > before.commentCount {
            triggers.insert(.newComments)
        }
        if after.reviewDecision != before.reviewDecision, after.reviewDecision != .none {
            triggers.insert(.reviewDecision)
        }
        // `unknown` is "not reported yet", not a result — a row whose checks
        // arrive a poll later has not had its build change.
        if after.ciState != before.ciState, after.ciState != .unknown {
            triggers.insert(.checksChanged)
        }
        if before.state == .draft, after.state == .open {
            triggers.insert(.readyForReview)
        }
        if !before.isMerged, after.isMerged {
            triggers.insert(.merged)
        } else if before.state.isLive, after.state == .closed {
            triggers.insert(.closed)
        }
        // Set membership, not count: a reviewer removed and another added
        // leaves the count identical and is still a request arriving.
        let requestedBefore = Set(before.requestedReviewers.map { $0.lowercased() })
        let requestedAfter = Set(after.requestedReviewers.map { $0.lowercased() })
        if !before.buckets.contains(.needsReview), after.buckets.contains(.needsReview) {
            triggers.insert(.reviewRequested)
        } else if !requestedAfter.subtracting(requestedBefore).isEmpty,
                  after.buckets.contains(.needsReview) {
            triggers.insert(.reviewRequested)
        }
        return triggers
    }
}

/// Applies `NotificationPreferences` to detected changes.
///
/// Split from the detector because the two answer different questions —
/// "what happened" is about the forge, "should this interrupt anyone" is
/// about the reviewer — and the second one has to be settable to every
/// combination in a test.
enum NotificationPolicy {
    /// One decision, with the reason it came out that way.
    struct Decision: Equatable {
        var shouldNotify: Bool
        var reason: Reason

        enum Reason: Equatable {
            case notify
            case notificationsOff
            case projectSilenced
            case kindNotWanted
            case noWantedTrigger
            case outOfScope
            case ownPullRequest
            case draft
            case labelMismatch
            case quietHours
            case appIsActive
        }

        static let allowed = Decision(shouldNotify: true, reason: .notify)
        static func denied(_ reason: Reason) -> Decision { Decision(shouldNotify: false, reason: reason) }
    }

    /// Everything about the moment a decision is made that isn't the change
    /// itself or the reviewer's preferences.
    struct Context {
        var preferences: NotificationPreferences
        var projectLevel: WatchedProject.NotificationLevel
        var isProjectMuted: Bool
        /// The signed-in reviewer's login, when it is known. Used only to
        /// recognise their own pull requests.
        var viewerLogin: String?
        var isAppActive: Bool
        var now: Date

        init(
            preferences: NotificationPreferences,
            projectLevel: WatchedProject.NotificationLevel = .inherit,
            isProjectMuted: Bool = false,
            viewerLogin: String? = nil,
            isAppActive: Bool = false,
            now: Date = Date()
        ) {
            self.preferences = preferences
            self.projectLevel = projectLevel
            self.isProjectMuted = isProjectMuted
            self.viewerLogin = viewerLogin
            self.isAppActive = isAppActive
            self.now = now
        }
    }

    /// Checked in the order a reviewer would reason about it: the switches
    /// they set, then the pull request, then the moment.
    static func decide(_ change: PRChange, context: Context) -> Decision {
        let preferences = context.preferences
        guard preferences.enabled else { return .denied(.notificationsOff) }
        guard !context.isProjectMuted, context.projectLevel != .silent else { return .denied(.projectSilenced) }

        let pr = change.pr
        let isReviewRequest = change.triggers.contains(.reviewRequested)
            || (isAppearance(change) && pr.buckets.contains(.needsReview))

        // A project set to "only what needs me" overrides the global scope
        // downward, never upward: it is a way to quieten one noisy repository
        // without rebuilding the global rules around it.
        if context.projectLevel == .reviewRequestsOnly, !isReviewRequest {
            return .denied(.outOfScope)
        }

        switch change {
        case .appeared:
            guard preferences.notifyOnNewPullRequest else { return .denied(.kindNotWanted) }
        case .changed(_, _, let triggers):
            guard preferences.notifyOnUpdate else { return .denied(.kindNotWanted) }
            guard !triggers.intersection(preferences.updateTriggers).isEmpty else {
                return .denied(.noWantedTrigger)
            }
        }

        if let login = context.viewerLogin, !login.isEmpty, !preferences.includeOwnPullRequests,
           pr.authorLogin.caseInsensitiveCompare(login) == .orderedSame {
            return .denied(.ownPullRequest)
        }
        // The bucket is the fallback when the login is not known: a row the
        // reviewer-centric search returned as `authored` is theirs.
        if (context.viewerLogin ?? "").isEmpty, !preferences.includeOwnPullRequests,
           pr.buckets.contains(.authored) {
            return .denied(.ownPullRequest)
        }
        if !preferences.includeDrafts, pr.state == .draft { return .denied(.draft) }

        switch preferences.scope {
        case .allWatched:
            break
        case .involved:
            // A review request always counts as involvement, even before the
            // bucket search has caught up with it.
            guard isReviewRequest || !pr.buckets.isEmpty else { return .denied(.outOfScope) }
        case .reviewRequested:
            guard isReviewRequest || pr.buckets.contains(.needsReview) else { return .denied(.outOfScope) }
        }

        if !preferences.requiredLabels.isEmpty {
            let wanted = Set(preferences.requiredLabels.map { $0.lowercased() })
            let carried = Set(pr.labels.map { $0.name.lowercased() })
            guard !wanted.intersection(carried).isEmpty else { return .denied(.labelMismatch) }
        }

        if preferences.isQuiet(at: context.now) { return .denied(.quietHours) }
        if preferences.suppressWhileActive, context.isAppActive { return .denied(.appIsActive) }

        return .allowed
    }

    private static func isAppearance(_ change: PRChange) -> Bool {
        if case .appeared = change { return true }
        return false
    }
}
