import Foundation

struct IssueComment: Codable, Equatable, Identifiable {
    let id: Int
    let user: GitHubUser
    let body: String
    let createdAt: Date
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
        case htmlUrl = "html_url"
    }
}

enum ReviewState: String, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case pending = "PENDING"
    case dismissed = "DISMISSED"
}

struct Review: Codable, Equatable, Identifiable {
    let id: Int
    let user: GitHubUser
    let body: String?
    let state: ReviewState
    let submittedAt: Date?
    var commitId: String? = nil
    var htmlUrl: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, user, body, state
        case commitId = "commit_id"
        case htmlUrl = "html_url"
        case submittedAt = "submitted_at"
    }
}

/// A review comment anchored to a specific diff line, as returned by
/// `GET /repos/{owner}/{repo}/pulls/{number}/comments`.
struct ReviewComment: Codable, Equatable, Identifiable {
    let id: Int
    let user: GitHubUser
    let body: String
    let path: String
    let line: Int?
    let originalLine: Int?
    let side: DiffSide?
    let inReplyToId: Int?
    let createdAt: Date
    let htmlUrl: String
    var startLine: Int? = nil
    var diffHunk: String? = nil
    var updatedAt: Date? = nil
    var pullRequestReviewId: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, user, body, path, line, side
        case startLine = "start_line"
        case diffHunk = "diff_hunk"
        case updatedAt = "updated_at"
        case pullRequestReviewId = "pull_request_review_id"
        case originalLine = "original_line"
        case inReplyToId = "in_reply_to_id"
        case createdAt = "created_at"
        case htmlUrl = "html_url"
    }

    /// Whether this comment still anchors to a line that exists in the
    /// current patch (GitHub returns `line: null` for outdated comments).
    var isOutdated: Bool { line == nil }

    /// Threads are rooted at the comment with no `in_reply_to_id`.
    var isThreadRoot: Bool { inReplyToId == nil }
}

struct ReviewThread: Identifiable, Equatable {
    var id: Int { rootId }
    let rootId: Int
    let path: String
    let line: Int?
    let side: DiffSide?
    let isOutdated: Bool
    let comments: [ReviewComment]
}

extension Array where Element == ReviewComment {
    /// Groups flat review comments into threads keyed by their root comment.
    func groupedIntoThreads() -> [ReviewThread] {
        let byId = Dictionary(uniqueKeysWithValues: map { ($0.id, $0) })
        var childrenByRoot: [Int: [ReviewComment]] = [:]
        for comment in self {
            guard let replyTo = comment.inReplyToId else { continue }
            var rootId = replyTo
            var visited = Set<Int>()
            while let parent = byId[rootId]?.inReplyToId, !visited.contains(rootId) {
                visited.insert(rootId)
                rootId = parent
            }
            childrenByRoot[rootId, default: []].append(comment)
        }
        return self
            .filter { $0.isThreadRoot }
            .map { root in
                let replies = (childrenByRoot[root.id] ?? []).sorted { $0.createdAt < $1.createdAt }
                return ReviewThread(
                    rootId: root.id, path: root.path, line: root.line, side: root.side,
                    isOutdated: root.isOutdated, comments: [root] + replies
                )
            }
    }
}
