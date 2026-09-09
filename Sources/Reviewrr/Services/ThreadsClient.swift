import Foundation

/// Bridges GitHub's two pull-request discussion surfaces: the REST review
/// comments the rest of the app already fetches (body, author, timestamps)
/// and the thread resolution state that only exists in GraphQL. Comment
/// content is never trusted from GraphQL — REST stays the source of truth
/// for what a comment says; GraphQL is consulted only to say whether the
/// thread around it is open or closed.
struct ThreadsClient {
    var api: GitHubAPI

    init(api: GitHubAPI) {
        self.api = api
    }

    /// One `reviewThreads` node's resolution metadata, keyed for merge by
    /// the databaseId of any comment inside it (REST and GraphQL share
    /// comment ids; they do not share thread ids).
    struct ThreadState: Equatable {
        var nodeId: String
        var isResolved: Bool
        var isOutdated: Bool
        var isCollapsed: Bool
        var resolvedByLogin: String?
        var commentDatabaseIds: [Int]
    }

    // MARK: - Fetch resolution state

    /// The GraphQL response shape for `threadsQuery`, one level in from the
    /// envelope's `data` key (which `GitHubAPI.graphQL` already unwraps).
    /// Kept internal, rather than private, so a fixture string can be
    /// decoded and mapped through `threadStates(from:)` in a unit test with
    /// no network involved.
    struct ThreadsQueryResult: Decodable {
        struct Repository: Decodable { let pullRequest: PullRequestNode? }
        struct PullRequestNode: Decodable { let reviewThreads: Connection }
        struct Connection: Decodable { let nodes: [ThreadNode] }
        struct ThreadNode: Decodable {
            let id: String
            let isResolved: Bool
            let isOutdated: Bool
            let isCollapsed: Bool
            let resolvedBy: Actor?
            let comments: CommentConnection
        }
        struct Actor: Decodable { let login: String }
        struct CommentConnection: Decodable { let nodes: [CommentNode] }
        struct CommentNode: Decodable { let databaseId: Int? }
        let repository: Repository?
    }

    /// Maps a decoded query result to the flat `ThreadState` list the merge
    /// step consumes. Nil means the shape was well-formed JSON but carried
    /// no reachable `reviewThreads` (an unexpected/missing PR node) —
    /// treated the same as "GraphQL unavailable" by the caller.
    static func threadStates(from result: ThreadsQueryResult) -> [ThreadState]? {
        guard let nodes = result.repository?.pullRequest?.reviewThreads.nodes else { return nil }
        return nodes.map { node in
            ThreadState(
                nodeId: node.id,
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                isCollapsed: node.isCollapsed,
                resolvedByLogin: node.resolvedBy?.login,
                commentDatabaseIds: node.comments.nodes.compactMap(\.databaseId)
            )
        }
    }

    private static let threadsQuery = """
    query PullRequestThreads($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              isOutdated
              isCollapsed
              resolvedBy { login }
              comments(first: 100) {
                nodes { databaseId }
              }
            }
          }
        }
      }
    }
    """

    /// Fetches resolution state for every thread on the PR. Returns nil
    /// (never throws) when GraphQL itself is unreachable, unauthorized, or
    /// malformed, so a caller can degrade to an honestly-labelled REST-only
    /// view instead of failing the whole conversation load over what is a
    /// secondary signal.
    func fetchThreadStates(owner: String, repo: String, number: Int, token: String?) async -> [ThreadState]? {
        do {
            let result: ThreadsQueryResult = try await api.graphQL(
                ThreadsQueryResult.self,
                query: Self.threadsQuery,
                variables: ["owner": owner, "repo": repo, "number": number],
                token: token
            )
            return Self.threadStates(from: result)
        } catch {
            return nil
        }
    }

    // MARK: - Merge

    /// Combines REST threads with GraphQL resolution state into the app's
    /// `ConversationThread` model, and separately returns the rootId →
    /// GraphQL-node-id lookup `ConversationModel` needs later to resolve or
    /// unresolve a specific thread (the mutation takes GraphQL's opaque
    /// node id, not the REST root comment id).
    static func merge(restThreads: [ReviewThread], states: [ThreadState]?) -> (threads: [ConversationThread], nodeIdByRoot: [Int: String]) {
        var stateByCommentId: [Int: ThreadState] = [:]
        if let states {
            for state in states {
                for commentId in state.commentDatabaseIds {
                    stateByCommentId[commentId] = state
                }
            }
        }

        var nodeIdByRoot: [Int: String] = [:]
        let threads = restThreads.map { rest -> ConversationThread in
            let matchedState = rest.comments.lazy.compactMap { stateByCommentId[$0.id] }.first

            let resolution: ConversationThread.ResolutionState
            let isOutdated: Bool
            let isCollapsed: Bool
            if let matchedState {
                resolution = matchedState.isResolved ? .resolved(by: matchedState.resolvedByLogin) : .unresolved
                isOutdated = matchedState.isOutdated || rest.isOutdated
                isCollapsed = matchedState.isCollapsed
                nodeIdByRoot[rest.rootId] = matchedState.nodeId
            } else {
                // Either GraphQL was unreachable entirely, or this thread
                // wasn't found among its nodes (e.g. truncated by the
                // first-100 page cap) — both collapse to the same honest
                // answer: this app cannot currently say whether it's resolved.
                resolution = .unknown
                isOutdated = rest.isOutdated
                isCollapsed = false
            }

            return ConversationThread(
                rootId: rest.rootId,
                path: rest.path,
                line: rest.line,
                startLine: rest.comments.first?.startLine,
                side: rest.side,
                isOutdated: isOutdated,
                isCollapsed: isCollapsed,
                resolution: resolution,
                comments: rest.comments.map(ConversationComment.init(rest:))
            )
        }
        return (threads, nodeIdByRoot)
    }

    // MARK: - Reply

    /// Posts a human-authored reply to an existing thread, anchored to its
    /// root comment. Returns the created comment so the caller can splice
    /// it into the thread without a full reload. Never called automatically
    /// — only from an explicit "Reply" action in the UI.
    func reply(owner: String, repo: String, number: Int, rootCommentId: Int, body: String, token: String?) async throws -> ReviewComment {
        struct Body: Encodable { let body: String }
        return try await api.post(
            ReviewComment.self,
            path: "/repos/\(owner)/\(repo)/pulls/\(number)/comments/\(rootCommentId)/replies",
            token: token,
            body: Body(body: body)
        )
    }

    // MARK: - Resolve / unresolve

    private struct ResolveMutationResult: Decodable {
        let resolveReviewThread: Payload?
        let unresolveReviewThread: Payload?
        struct Payload: Decodable {
            struct Thread: Decodable { let id: String; let isResolved: Bool }
            let thread: Thread
        }
    }

    private static let resolveMutation = """
    mutation ResolveThread($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
    }
    """
    private static let unresolveMutation = """
    mutation UnresolveThread($threadId: ID!) {
      unresolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
    }
    """

    /// Flips a thread's resolved state via GraphQL. Never automatic — only
    /// reachable from an explicit resolve/unresolve button, matching
    /// GitHub's own "a human closed this" semantics.
    @discardableResult
    func setResolved(_ resolved: Bool, threadNodeId: String, token: String?) async throws -> Bool {
        let result: ResolveMutationResult = try await api.graphQL(
            ResolveMutationResult.self,
            query: resolved ? Self.resolveMutation : Self.unresolveMutation,
            variables: ["threadId": threadNodeId],
            token: token
        )
        return (result.resolveReviewThread?.thread.isResolved ?? result.unresolveReviewThread?.thread.isResolved) ?? resolved
    }
}
