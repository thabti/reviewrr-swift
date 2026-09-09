import Foundation

/// What changed about a pull request between two polls.
///
/// A poll only ever sees two snapshots of a row, so "updated" has to be
/// derived — and the reviewer gets to choose which derivations are worth
/// interrupting them for. `updatedAt` moving is deliberately *not* one of
/// them: GitHub bumps it for a label change, a projects-board move, or an
/// edit to the description, and a notification that says only "something
/// happened" is the kind a reviewer turns off entirely.
enum PRUpdateTrigger: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The head SHA moved: someone pushed.
    case newCommits
    /// The comment count went up.
    case newComments
    /// Approved, changes requested, or back to review-required.
    case reviewDecision
    /// CI went green, red, or back to pending.
    case checksChanged
    /// A draft became a real pull request.
    case readyForReview
    case merged
    case closed
    /// The reviewer was added to the requested-reviewer list of a pull
    /// request they were already seeing.
    case reviewRequested

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newCommits: return "New commits"
        case .newComments: return "New comments"
        case .reviewDecision: return "Review approved or changes requested"
        case .checksChanged: return "Checks passed or failed"
        case .readyForReview: return "Draft marked ready for review"
        case .merged: return "Merged"
        case .closed: return "Closed without merging"
        case .reviewRequested: return "Your review is requested"
        }
    }

    var systemImage: String {
        switch self {
        case .newCommits: return "arrow.triangle.branch"
        case .newComments: return "bubble.left"
        case .reviewDecision: return "checkmark.seal"
        case .checksChanged: return "checkmark.circle"
        case .readyForReview: return "flag"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .reviewRequested: return "person.crop.circle.badge.exclamationmark"
        }
    }

    /// The triggers on by default: the ones that change what a reviewer
    /// should do next. Checks and comments are opt-in — a chatty pull request
    /// or a flaky pipeline would otherwise notify all afternoon.
    static let defaults: Set<PRUpdateTrigger> = [.newCommits, .reviewDecision, .readyForReview, .reviewRequested]
}

/// A ready-made answer to "when should this interrupt me".
///
/// The pane used to ask twenty-five questions — a scope, eight update
/// triggers, drafts, own pull requests, a label allow-list, sound, grouping,
/// a summary threshold — to configure one bell. Almost nobody has an
/// opinion about eight triggers; they have one about how much they want to
/// be interrupted. A preset is that opinion, and it sets the rest.
///
/// `custom` is not a fourth choice a reviewer picks: it is what the pane
/// reports once the underlying values no longer match any preset, so that
/// somebody who *did* tune the details is never told their configuration is
/// something it is not.
enum NotificationPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Only what is blocking someone: a review asked of you, or changes
    /// asked of your own work.
    case essential
    /// The default. Activity on work you are part of.
    case balanced
    /// Every pull request on every watched project, every change.
    case everything

    var id: String { rawValue }

    var label: String {
        switch self {
        case .essential: return "Only what needs me"
        case .balanced: return "Work I'm part of"
        case .everything: return "Everything"
        }
    }

    var summary: String {
        switch self {
        case .essential: return "A review asked of you, or changes requested on yours."
        case .balanced: return "Pull requests you're involved in, when they move."
        case .everything: return "Every pull request on every watched project."
        }
    }

    var systemImage: String {
        switch self {
        case .essential: return "bell.badge"
        case .balanced: return "bell"
        case .everything: return "bell.and.waves.left.and.right"
        }
    }

    /// Roughly how often this fires, so the choice can be made without
    /// discovering the answer over a working week.
    var volumeHint: String {
        switch self {
        case .essential: return "Quietest"
        case .balanced: return "A few a day"
        case .everything: return "Loud"
        }
    }

    /// The values this preset stands for. Only the fields a preset has an
    /// opinion about — sound, grouping and quiet hours are the reviewer's
    /// regardless of which one they pick.
    func applied(to preferences: NotificationPreferences) -> NotificationPreferences {
        var updated = preferences
        switch self {
        case .essential:
            updated.scope = .reviewRequested
            updated.notifyOnNewPullRequest = false
            updated.notifyOnUpdate = true
            updated.updateTriggers = [.reviewRequested, .reviewDecision]
            updated.includeOwnPullRequests = false
            updated.includeDrafts = false
        case .balanced:
            updated.scope = .involved
            updated.notifyOnNewPullRequest = true
            updated.notifyOnUpdate = true
            updated.updateTriggers = PRUpdateTrigger.defaults
            updated.includeOwnPullRequests = false
            updated.includeDrafts = false
        case .everything:
            updated.scope = .allWatched
            updated.notifyOnNewPullRequest = true
            updated.notifyOnUpdate = true
            updated.updateTriggers = Set(PRUpdateTrigger.allCases)
            updated.includeOwnPullRequests = true
            updated.includeDrafts = true
        }
        return updated
    }
}

extension NotificationPreferences {
    /// Which preset these values are, or nil when they are no longer any of
    /// them.
    ///
    /// Derived by comparison rather than stored, so a reviewer who edits one
    /// checkbox in Advanced is shown "Custom" immediately and a stored
    /// preset name can never disagree with the values it claims to describe.
    var matchingPreset: NotificationPreset? {
        NotificationPreset.allCases.first { $0.applied(to: self) == self }
    }

    /// What to call the current configuration in the pane.
    var presetLabel: String { matchingPreset?.label ?? "Custom" }
}

/// Whose pull requests are worth a notification.
enum NotificationScope: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Everything on every watched project.
    case allWatched
    /// Only pull requests the reviewer is involved in — review requested,
    /// assigned, authored, or already commented on.
    case involved
    /// Only pull requests waiting on this reviewer's review.
    case reviewRequested

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allWatched: return "Everything on watched projects"
        case .involved: return "Pull requests I'm involved in"
        case .reviewRequested: return "Only reviews requested from me"
        }
    }

    var explanation: String {
        switch self {
        case .allWatched:
            return "Every pull request on a project you watch, whoever opened it."
        case .involved:
            return "Review requested, assigned to you, opened by you, or one you've commented on."
        case .reviewRequested:
            return "Nothing but the queue that is actually waiting on you."
        }
    }
}

/// Everything a reviewer can tune about being interrupted.
///
/// One nested value on `AppSettings` rather than a dozen loose booleans, so
/// the notification rules can be reasoned about — and tested — as a unit.
struct NotificationPreferences: Codable, Equatable, Sendable {
    /// The master switch. Off by default: an app that starts posting system
    /// notifications before being asked is one a reviewer silences at the OS
    /// level, which is much harder to come back from.
    var enabled: Bool = false

    // What to notify about
    var notifyOnNewPullRequest: Bool = true
    var notifyOnUpdate: Bool = true
    var updateTriggers: Set<PRUpdateTrigger> = PRUpdateTrigger.defaults

    // Which pull requests count
    var scope: NotificationScope = .involved
    /// Notify about the reviewer's own pull requests. Off: you know you
    /// opened it, and its own CI and review activity is the most frequent
    /// noise source there is.
    var includeOwnPullRequests: Bool = false
    var includeDrafts: Bool = false
    /// Only pull requests carrying at least one of these labels, when the
    /// list is non-empty. Case-insensitive.
    var requiredLabels: Set<String> = []

    // How they arrive
    var playSound: Bool = true
    /// Group a project's notifications into one thread in Notification
    /// Centre, the way Mail groups a conversation.
    ///
    /// Always on, and no longer asked about: twenty separate banners from
    /// one repository is not something anyone chooses. Kept as a stored
    /// property so an older blob decodes.
    var groupByProject: Bool = true
    /// Beyond this many in one poll, deliver a single summary instead. A
    /// reviewer who comes back from lunch to a 40-PR sync wants one line,
    /// not forty banners.
    ///
    /// No longer asked about — five is the answer for everyone, and a
    /// 1-to-25 stepper was asking a reviewer to guess at their own
    /// tolerance before they had seen a single notification.
    var maxPerPoll: Int = 5
    /// Skip notifications while Reviewrr is the frontmost app — the activity
    /// is already on screen, and the dashboard's own feed has it.
    var suppressWhileActive: Bool = true

    // Quiet hours
    var quietHoursEnabled: Bool = false
    /// Local hour the quiet period starts, 0–23. A start later than the end
    /// wraps midnight, which is the normal case (22 → 8).
    var quietHoursStart: Int = 22
    var quietHoursEnd: Int = 8

    init() {}

    // MARK: - Forward-compatible decoding
    //
    // Same rule as `AppSettings`: a blob written by a newer build must stay
    // decodable, and a missing key must fall back to the default rather than
    // resetting every other preference.

    enum CodingKeys: String, CodingKey {
        case enabled, notifyOnNewPullRequest, notifyOnUpdate, updateTriggers
        case scope, includeOwnPullRequests, includeDrafts, requiredLabels
        case playSound, groupByProject, maxPerPoll, suppressWhileActive
        case quietHoursEnabled, quietHoursStart, quietHoursEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        enabled = value(.enabled, defaults.enabled)
        notifyOnNewPullRequest = value(.notifyOnNewPullRequest, defaults.notifyOnNewPullRequest)
        notifyOnUpdate = value(.notifyOnUpdate, defaults.notifyOnUpdate)
        updateTriggers = value(.updateTriggers, defaults.updateTriggers)
        scope = value(.scope, defaults.scope)
        includeOwnPullRequests = value(.includeOwnPullRequests, defaults.includeOwnPullRequests)
        includeDrafts = value(.includeDrafts, defaults.includeDrafts)
        requiredLabels = value(.requiredLabels, defaults.requiredLabels)
        playSound = value(.playSound, defaults.playSound)
        groupByProject = value(.groupByProject, defaults.groupByProject)
        maxPerPoll = value(.maxPerPoll, defaults.maxPerPoll)
        suppressWhileActive = value(.suppressWhileActive, defaults.suppressWhileActive)
        quietHoursEnabled = value(.quietHoursEnabled, defaults.quietHoursEnabled)
        quietHoursStart = value(.quietHoursStart, defaults.quietHoursStart)
        quietHoursEnd = value(.quietHoursEnd, defaults.quietHoursEnd)
    }

    /// Whether `date` falls inside the quiet period.
    ///
    /// A start equal to the end means the whole day, not none of it: someone
    /// who sets 9 to 9 has asked for silence, and reading it the other way
    /// would deliver every notification instead of no notification — the
    /// wrong direction to be wrong in.
    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        let start = min(max(quietHoursStart, 0), 23)
        let end = min(max(quietHoursEnd, 0), 23)
        if start == end { return true }
        if start < end { return hour >= start && hour < end }
        // Wraps midnight.
        return hour >= start || hour < end
    }
}
