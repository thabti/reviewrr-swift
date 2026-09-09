import Foundation

/// One comment inside a review thread, after GraphQL's resolution
/// metadata has been matched onto it. Content (author/body/timestamps)
/// always comes from the REST `ReviewComment` the app already loaded —
/// GitHub's REST API stays the source of truth for what a comment says;
/// GraphQL is consulted only for thread-level state.
struct ConversationComment: Identifiable, Equatable {
    let id: Int
    let author: GitHubUser
    let body: String
    let createdAt: Date
    let updatedAt: Date?
    let url: String
}

extension ConversationComment {
    init(rest: ReviewComment) {
        self.init(id: rest.id, author: rest.user, body: rest.body, createdAt: rest.createdAt, updatedAt: rest.updatedAt, url: rest.htmlUrl)
    }
}

/// A review thread with GitHub's own resolution state layered onto REST's
/// flat comment list.
struct ConversationThread: Identifiable, Equatable {
    enum ResolutionState: Equatable {
        case resolved(by: String?)
        case unresolved
        /// GraphQL didn't answer (offline, missing scope, transient API
        /// error) — REST alone cannot say whether a thread is resolved, and
        /// guessing "unresolved" would be a silent lie, so this stays a
        /// distinct, honestly-labelled state.
        case unknown
    }

    var id: Int { rootId }
    let rootId: Int
    let path: String
    let line: Int?
    let startLine: Int?
    let side: DiffSide?
    let isOutdated: Bool
    let isCollapsed: Bool
    let resolution: ResolutionState
    let comments: [ConversationComment]

    var isResolved: Bool {
        if case .resolved = resolution { return true }
        return false
    }

    /// A thread GitHub can no longer place at a live diff line — outdated
    /// (superseded by a later push) or missing a path/line entirely. These
    /// go in their own labelled section rather than being hidden or drawn
    /// at the wrong line.
    var isUnanchored: Bool { isOutdated || path.isEmpty || line == nil }

    func withResolution(_ resolution: ResolutionState) -> ConversationThread {
        ConversationThread(
            rootId: rootId, path: path, line: line, startLine: startLine, side: side,
            isOutdated: isOutdated, isCollapsed: isCollapsed, resolution: resolution, comments: comments
        )
    }

    func appending(_ comment: ConversationComment) -> ConversationThread {
        replacingComments(comments + [comment])
    }

    func replacingComments(_ comments: [ConversationComment]) -> ConversationThread {
        ConversationThread(
            rootId: rootId, path: path, line: line, startLine: startLine, side: side,
            isOutdated: isOutdated, isCollapsed: isCollapsed, resolution: resolution, comments: comments
        )
    }
}

/// One entry in the merged conversation timeline. Kept as three distinct
/// cases — never flattened into a generic "comment" — because the MVP plan
/// requires general discussion, formal reviews, and inline threads to stay
/// visually separate rather than becoming a flat comment dump.
enum ConversationItem: Identifiable, Equatable {
    case general(IssueComment)
    case review(Review)
    case thread(ConversationThread)

    var id: String {
        switch self {
        case .general(let comment): return "general-\(comment.id)"
        case .review(let review): return "review-\(review.id)"
        case .thread(let thread): return "thread-\(thread.rootId)"
        }
    }

    /// The timestamp used to place this item in the timeline. A thread
    /// sorts by when it was opened, not by its most recent reply, so an
    /// old thread getting a new reply doesn't jump to "now" and scramble
    /// the reading order.
    var timestamp: Date {
        switch self {
        case .general(let comment): return comment.createdAt
        case .review(let review): return review.submittedAt ?? .distantPast
        case .thread(let thread): return thread.comments.first?.createdAt ?? .distantPast
        }
    }
}
