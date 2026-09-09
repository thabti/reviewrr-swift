import Foundation

/// A reviewer's personal triage state for one PR, independent of GitHub's
/// own state (open/closed/merged). This is the "have I dealt with this"
/// axis GitHub doesn't track for you.
enum LocalReviewStatus: String, Codable, CaseIterable, Equatable {
    case none
    case inReview
    case reviewed
    case ignored

    var label: String {
        switch self {
        case .none: return "New"
        case .inReview: return "In review"
        case .reviewed: return "Reviewed"
        case .ignored: return "Ignored"
        }
    }
}

/// Locally tracked review status for one PR, keyed by "owner/repo#number"
/// and persisted alongside the watchlist so it survives restarts. GitHub
/// remains the source of truth for everything else; this is purely local
/// bookkeeping about what *this* reviewer has done with the PR.
struct LocalPRStatus: Codable, Equatable {
    var status: LocalReviewStatus = .none
    /// The row's `updatedAt` the last time this reviewer looked at it —
    /// compared against the live row to derive `isUnseen`.
    var lastSeenUpdatedAt: Date?
    /// The head SHA in place when this reviewer last marked the PR
    /// reviewed — compared against the live head to derive
    /// `isUpdatedSinceReview` precisely across force-pushes.
    var reviewedAtHeadSha: String?

    static func key(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }

    // MARK: - Derived signals

    /// A PR is unseen until its current `updatedAt` has been observed at
    /// least once. An ignored PR is never "unseen" — ignoring silences the
    /// PR until the reviewer explicitly changes its status, even across
    /// new commits.
    func isUnseen(currentUpdatedAt: Date) -> Bool {
        guard status != .ignored else { return false }
        guard let lastSeenUpdatedAt else { return true }
        return currentUpdatedAt > lastSeenUpdatedAt
    }

    /// True once a reviewed PR has moved past the head this reviewer last
    /// reviewed. Falls back to a timestamp comparison when the head SHA
    /// isn't known (search-bucket rows don't carry one).
    func isUpdatedSinceReview(currentUpdatedAt: Date, currentHeadSha: String?) -> Bool {
        guard status == .reviewed else { return false }
        if let reviewedAtHeadSha, let currentHeadSha {
            return reviewedAtHeadSha != currentHeadSha
        }
        guard let lastSeenUpdatedAt else { return false }
        return currentUpdatedAt > lastSeenUpdatedAt
    }

    // MARK: - Transitions
    //
    // Two kinds of transition: an automatic one triggered by opening a PR
    // (only takes effect from the neutral `.none` state, so opening a PR a
    // reviewer already explicitly marked ignored/reviewed never silently
    // reverts their choice), and an explicit one from a menu action, which
    // always applies — "always permit undo or manual override."

    /// Meaningful interaction (opening the PR) starts `.inReview` — but
    /// only from the neutral state.
    mutating func markOpened(updatedAt: Date) {
        if status == .none { status = .inReview }
        lastSeenUpdatedAt = updatedAt
    }

    /// An explicit, reviewer-driven status change.
    mutating func setStatus(_ newStatus: LocalReviewStatus, headSha: String? = nil, updatedAt: Date = Date()) {
        status = newStatus
        if newStatus == .reviewed {
            reviewedAtHeadSha = headSha
        } else if newStatus == .none {
            reviewedAtHeadSha = nil
        }
        if newStatus != .ignored {
            lastSeenUpdatedAt = updatedAt
        }
    }
}
