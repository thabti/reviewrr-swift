import Foundation

/// How a pull request's size is written in the inbox.
///
/// Lives here rather than in the row that draws it because the test bundle
/// excludes `Views/`, and the rounding is the part worth pinning down.
enum InboxDiffSizeFormatting {
    static func abbreviate(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<10_000: return String(format: "%.1fk", Double(value) / 1_000)
        default: return "\(value / 1_000)k"
        }
    }
}

/// Where an `InboxPR` row was discovered — a watched project's pull sync,
/// or a reviewer-centric `/search/issues` bucket. Search results carry a
/// smaller payload (GitHub's search schema omits diff stats, requested
/// reviewers, and head ref), so downstream code can tell which fields to
/// trust and how to merge two sightings of the same PR.
enum InboxPRSource: String, Codable, Equatable, Sendable {
    case project
    case search
}

/// Derived PR state, distinct from GitHub's raw `state` field: draft and
/// merged are folded in so the dashboard doesn't need three fields to show
/// one pill.
enum InboxPRState: String, CaseIterable, Codable, Equatable, Sendable {
    case open, draft, merged, closed

    /// Still live work: open on GitHub, draft included. Merged and closed
    /// remain searchable but are finished, so they never count toward
    /// anything that claims a reviewer's attention.
    ///
    /// The single definition behind both the inbox's default filter and the
    /// sidebar's per-project count — when those two disagreed, the badge
    /// promised 147 pull requests and selecting the project showed 9.
    var isLive: Bool { self == .open || self == .draft }

    var label: String {
        switch self {
        case .open: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }
}

enum InboxReviewDecision: String, Codable, Equatable, Sendable {
    case approved, changesRequested, reviewRequired, none
}

enum InboxCIState: String, Codable, Equatable, Sendable {
    case success, failure, pending, unknown
}

/// Reviewer-centric cross-repo buckets sourced from `/search/issues`. A row
/// can belong to more than one — e.g. a PR that both requests your review
/// and that you've also commented on.
enum InboxReviewerBucket: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case needsReview, assigned, authored, participated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsReview: return "Needs review"
        case .assigned: return "Assigned"
        case .authored: return "Authored"
        case .participated: return "Participated"
        }
    }

    var systemImage: String {
        switch self {
        case .needsReview: return "person.crop.circle.badge.exclamationmark"
        case .assigned: return "person.crop.circle"
        case .authored: return "pencil"
        case .participated: return "bubble.left.and.bubble.right"
        }
    }

    /// `/search/issues` qualifiers for this bucket, appended to a base
    /// `is:pr` search.
    var searchQualifiers: String {
        switch self {
        case .needsReview: return "is:open review-requested:@me"
        case .assigned: return "assignee:@me"
        case .authored: return "author:@me"
        case .participated: return "involves:@me"
        }
    }
}

/// One normalized inbox row, whether it came from a watched project's pull
/// sync or a reviewer-centric search bucket. `Services/Inbox/InboxService`
/// is the only place that constructs or enriches these; this type is pure
/// data so filtering/sorting/grouping logic is unit-testable without a
/// network call. Property order matters — `InboxService`'s raw-payload
/// initializers rely on the synthesized memberwise initializer.
struct InboxPR: Identifiable, Equatable, Hashable, Codable, Sendable {
    var host: ForgeHost
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var authorLogin: String
    var authorAvatarURL: String?
    var state: InboxPRState
    var isMerged: Bool
    var createdAt: Date
    var updatedAt: Date
    var commentCount: Int
    var labels: [GitHubLabel]
    var requestedReviewers: [String]
    var reviewDecision: InboxReviewDecision
    var ciState: InboxCIState
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var headRef: String?
    var headSha: String?
    var source: InboxPRSource
    var buckets: Set<InboxReviewerBucket>

    var id: String { "\(host.apiBaseURL.absoluteString)|\(owner)/\(repo)#\(number)" }
    /// The key `LocalPRStatus` is stored under.
    var statusKey: String { LocalPRStatus.key(owner: owner, repo: repo, number: number) }
    var repoNameWithOwner: String { "\(owner)/\(repo)" }
    var reference: PRReference { PRReference(owner: owner, repo: repo, number: number) }

    /// Merges two sightings of the same PR (e.g. found both in its
    /// project's pull sync and a reviewer-bucket search) into one row: the
    /// project-sourced side wins for richer fields (diff stats, requested
    /// reviewers, head ref/sha), while bucket membership and freshness are
    /// the union/max of both.
    func merged(with other: InboxPR) -> InboxPR {
        var result = source == .project ? self : (other.source == .project ? other : self)
        result.buckets = buckets.union(other.buckets)
        result.updatedAt = max(updatedAt, other.updatedAt)
        result.commentCount = max(commentCount, other.commentCount)
        return result
    }

    /// Dedupes and merges a watched-project sync with reviewer-bucket
    /// search results into one combined row set, keyed by PR identity.
    static func combine(projectRows: [InboxPR], bucketRows: [InboxPR]) -> [InboxPR] {
        var byID: [String: InboxPR] = [:]
        for row in projectRows { byID[row.id] = row }
        for row in bucketRows {
            if let existing = byID[row.id] {
                byID[row.id] = existing.merged(with: row)
            } else {
                byID[row.id] = row
            }
        }
        return Array(byID.values)
    }
}
