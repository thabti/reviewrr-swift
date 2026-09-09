import Foundation

/// Drives the right-rail Conversation and Checks tabs: merges REST
/// discussion with GraphQL thread state into one timeline, and holds CI
/// check state for the PR's current head commit.
///
/// Every write here (reply, resolve/unresolve) is a direct result of an
/// explicit user action — nothing in this class polls or posts on its own.
@MainActor
final class ConversationModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable, Hashable {
        case all
        case unresolved
        case mine
        case sinceLastReview

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .unresolved: return "Unresolved"
            case .mine: return "Mine"
            case .sinceLastReview: return "Since my last review"
            }
        }
    }

    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var items: [ConversationItem] = []
    @Published private(set) var threads: [ConversationThread] = []
    @Published private(set) var checks: [CheckRun] = []
    @Published private(set) var checkRollup: CheckRollup = .empty
    @Published var filter: Filter = .all
    @Published private(set) var loadPhase: LoadPhase = .idle
    @Published private(set) var checksLoadPhase: LoadPhase = .idle
    /// Set (and shown, then cleared by the view) after a failed reply or
    /// resolve/unresolve — GitHub's own message, not a generic fallback.
    @Published var lastError: String?
    @Published private(set) var pendingReplyThreadIds: Set<Int> = []
    @Published private(set) var pendingResolveThreadIds: Set<Int> = []
    /// The signed-in user's login, resolved once per load so "Mine" and
    /// "Since my last review" have something to compare against. Nil when
    /// signed out or the lookup failed — those filters then degrade to
    /// showing everything rather than silently emptying the timeline.
    @Published private(set) var currentUserLogin: String?

    private let context: AppContext
    private var reference: PRReference?
    private var headSha: String?
    private var cachedIssueComments: [IssueComment] = []
    private var cachedReviews: [Review] = []
    private var threadNodeIdByRoot: [Int: String] = [:]

    private var threadsClient: ThreadsClient { ThreadsClient(api: context.api()) }
    private var checksClient: ChecksClient { ChecksClient(api: context.api()) }

    init(context: AppContext) {
        self.context = context
    }

    // MARK: - Load

    func load(reference: PRReference, headSha: String, restThreads: [ReviewThread], issueComments: [IssueComment], reviews: [Review]) async {
        self.reference = reference
        self.headSha = headSha
        self.cachedIssueComments = issueComments
        self.cachedReviews = reviews
        loadPhase = .loading

        let token = context.token()
        let host = context.settings().githubHost
        async let states = Self.fetchThreadStates(
            reference: reference, host: host, basic: context.basic(), threadsClient: threadsClient, token: token
        )
        async let login = Self.fetchCurrentUserLogin(
            host: host, basic: context.basic(), api: context.api(), token: token
        )
        let (resolvedStates, resolvedLogin) = await (states, login)

        let (merged, nodeIds) = ThreadsClient.merge(restThreads: restThreads, states: resolvedStates)
        threads = merged
        threadNodeIdByRoot = nodeIds
        currentUserLogin = resolvedLogin
        items = Self.buildTimeline(threads: merged, issueComments: issueComments, reviews: reviews)
        loadPhase = .loaded

        await refreshChecks()
    }

    private static func fetchCurrentUserLogin(
        host: ForgeHost, basic: BasicCredential?, api: GitHubAPI, token: String?
    ) async -> String? {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Best-effort only: "Mine" and "since my last review" are
        // conveniences, not core data, so a failed lookup here degrades
        // those filters rather than failing the whole load.
        return try? await ForgeClient(host: host, basic: basic).verifyToken(token).login
    }

    /// Resolution state, from whichever surface the host keeps it in:
    /// GitHub's GraphQL `reviewThreads`, or GitLab's `resolved` flag on the
    /// first note of each discussion. Both reduce to `ThreadState`, so the
    /// merge and the whole conversation panel below it are shared.
    private static func fetchThreadStates(
        reference: PRReference,
        host: ForgeHost,
        basic: BasicCredential?,
        threadsClient: ThreadsClient,
        token: String?
    ) async -> [ThreadsClient.ThreadState]? {
        switch host.forge {
        case .github:
            return await threadsClient.fetchThreadStates(
                owner: reference.owner, repo: reference.repo, number: reference.number, token: token
            )
        case .gitlab:
            // nil rather than [] on failure, which the merge reads as
            // "resolution unknown" and renders honestly, instead of
            // claiming every thread is unresolved.
            guard let discussions = try? await GitLabClient(host: host, basic: basic)
                .fetchDiscussionsRaw(reference, token: token)
            else { return nil }
            return GitLabMapper.threadStates(from: discussions)
        }
    }

    // MARK: - Checks

    func refreshChecks() async {
        guard let reference, let headSha else { return }
        checksLoadPhase = .loading
        do {
            let runs = try await ForgeClient(host: context.settings().githubHost, basic: context.basic())
                .fetchChecks(
                    owner: reference.owner, repo: reference.repo, headSha: headSha,
                    number: reference.number, token: context.token()
                )
            checks = runs
            checkRollup = CheckRollup.compute(from: runs)
            checksLoadPhase = .loaded
        } catch is CancellationError {
            // Leave the phase as-is: the reviewer navigated away or a newer
            // refresh replaced this one, which is not a checks failure.
        } catch {
            checksLoadPhase = .failed(Self.describe(error))
        }
    }

    // MARK: - Reply

    /// Posts a reply, showing it immediately and rolling back to the exact
    /// pre-reply state (surfacing GitHub's own message) if the request fails.
    func reply(to threadRootId: Int, body: String) async {
        guard let reference else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = threads.firstIndex(where: { $0.rootId == threadRootId }) else { return }

        let previous = threads[index]
        // Negative ids can never collide with a real GitHub databaseId
        // (always positive), so the placeholder is unambiguous to replace.
        let optimisticId = -Int(Date().timeIntervalSince1970 * 1000)
        let optimisticComment = ConversationComment(
            id: optimisticId,
            author: GitHubUser(login: currentUserLogin ?? "you", avatarUrl: nil),
            body: trimmed,
            createdAt: Date(),
            updatedAt: nil,
            url: previous.comments.first?.url ?? ""
        )
        threads[index] = previous.appending(optimisticComment)
        rebuildItems()
        lastError = nil
        pendingReplyThreadIds.insert(threadRootId)
        defer { pendingReplyThreadIds.remove(threadRootId) }

        do {
            let created = try await threadsClient.reply(
                owner: reference.owner, repo: reference.repo, number: reference.number,
                rootCommentId: threadRootId, body: trimmed, token: context.token()
            )
            if let idx = threads.firstIndex(where: { $0.rootId == threadRootId }) {
                let realComments = threads[idx].comments.filter { $0.id != optimisticId } + [ConversationComment(rest: created)]
                threads[idx] = threads[idx].replacingComments(realComments)
                rebuildItems()
            }
        } catch {
            if let idx = threads.firstIndex(where: { $0.rootId == threadRootId }) {
                threads[idx] = previous
                rebuildItems()
            }
            lastError = Self.describe(error)
        }
    }

    // MARK: - Resolve / unresolve

    /// Flips a thread's resolved state, optimistically, rolling back on
    /// failure. Refuses (with an explanatory error rather than a silent
    /// no-op) when this thread's GraphQL node id was never resolved —
    /// i.e. GraphQL was unreachable at load time, so there is nothing to
    /// mutate honestly.
    func setResolved(_ resolved: Bool, threadRootId: Int) async {
        guard let index = threads.firstIndex(where: { $0.rootId == threadRootId }) else { return }
        guard let nodeId = threadNodeIdByRoot[threadRootId] else {
            lastError = "This thread's resolution state isn't available from GitHub right now, so it can't be changed here."
            return
        }

        let previous = threads[index]
        threads[index] = previous.withResolution(resolved ? .resolved(by: currentUserLogin) : .unresolved)
        rebuildItems()
        lastError = nil
        pendingResolveThreadIds.insert(threadRootId)
        defer { pendingResolveThreadIds.remove(threadRootId) }

        do {
            let host = context.settings().githubHost
            switch host.forge {
            case .github:
                try await threadsClient.setResolved(resolved, threadNodeId: nodeId, token: context.token())
            case .gitlab:
                // `nodeId` carries GitLab's discussion id here — see
                // `GitLabMapper.threadStates`. GitLab addresses a discussion
                // under its merge request, so this needs the reference the
                // panel was loaded with.
                guard let reference else {
                    lastError = "This merge request is no longer open, so its thread can't be resolved."
                    return
                }
                try await GitLabClient(host: host, basic: context.basic())
                    .setResolved(resolved, reference: reference, discussionID: nodeId, token: context.token())
            }
        } catch {
            if let idx = threads.firstIndex(where: { $0.rootId == threadRootId }) {
                threads[idx] = previous
                rebuildItems()
            }
            lastError = Self.describe(error)
        }
    }

    // MARK: - Derived state

    /// Unresolved-thread counts keyed by file path, for Track C's file
    /// tree. A thread whose resolution state is unknown counts as needing
    /// attention — assuming it's resolved without evidence would be the
    /// dangerous default, not the safe one.
    var unresolvedCountsByPath: [String: Int] { Self.unresolvedCounts(fromThreads: threads) }

    /// Pure grouping logic behind `unresolvedCountsByPath`, split out so it
    /// can be unit tested against hand-built threads with no model instance
    /// (and no network) required.
    nonisolated static func unresolvedCounts(fromThreads threads: [ConversationThread]) -> [String: Int] {
        Dictionary(grouping: threads.filter { !$0.isResolved && !$0.path.isEmpty }, by: \.path)
            .mapValues(\.count)
    }

    /// How many threads are in each resolution state, counted separately.
    ///
    /// `unresolvedCounts` above deliberately folds `.unknown` into "needs
    /// attention" — for a per-file dot in the tree, treating an unknown
    /// thread as settled is the dangerous default. A header or a badge that
    /// prints a *number* cannot make that trade: it would turn "GitHub never
    /// told us" into a claim about how many threads are open. Anything that
    /// states a count reads this instead and says nothing when
    /// `isIncomplete`.
    struct ResolutionTally: Equatable {
        var resolved = 0
        var unresolved = 0
        var unknown = 0

        var total: Int { resolved + unresolved + unknown }
        /// At least one thread's state never arrived (offline, missing
        /// OAuth scope, GraphQL error), so no unresolved count is honest.
        var isIncomplete: Bool { unknown > 0 }
    }

    var resolutionTally: ResolutionTally { Self.resolutionTally(fromThreads: threads) }

    nonisolated static func resolutionTally(fromThreads threads: [ConversationThread]) -> ResolutionTally {
        var tally = ResolutionTally()
        for thread in threads {
            switch thread.resolution {
            case .resolved: tally.resolved += 1
            case .unresolved: tally.unresolved += 1
            case .unknown: tally.unknown += 1
            }
        }
        return tally
    }

    var filteredItems: [ConversationItem] { Self.filter(items, by: filter, currentUserLogin: currentUserLogin, reviews: cachedReviews) }

    private func rebuildItems() {
        items = Self.buildTimeline(threads: threads, issueComments: cachedIssueComments, reviews: cachedReviews)
    }

    // MARK: - Pure helpers (unit tested directly)

    /// Merges the three discussion sources into one chronological list,
    /// sorted by each item's opening timestamp. Kept as three distinct
    /// cases end to end (never flattened) so the UI can render general
    /// comments, formal reviews, and inline threads with different chrome.
    nonisolated static func buildTimeline(threads: [ConversationThread], issueComments: [IssueComment], reviews: [Review]) -> [ConversationItem] {
        var items: [ConversationItem] = []
        items.append(contentsOf: issueComments.map(ConversationItem.general))
        items.append(contentsOf: reviews.map(ConversationItem.review))
        items.append(contentsOf: threads.map(ConversationItem.thread))
        return items.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated static func filter(_ items: [ConversationItem], by filter: Filter, currentUserLogin: String?, reviews: [Review]) -> [ConversationItem] {
        switch filter {
        case .all:
            return items
        case .unresolved:
            return items.filter { item in
                if case .thread(let thread) = item { return !thread.isResolved }
                return true
            }
        case .mine:
            guard let currentUserLogin else { return items }
            return items.filter { item in
                switch item {
                case .general(let comment): return comment.user.login == currentUserLogin
                case .review(let review): return review.user.login == currentUserLogin
                case .thread(let thread): return thread.comments.contains { $0.author.login == currentUserLogin }
                }
            }
        case .sinceLastReview:
            guard let cutoff = lastReviewSubmittedAt(by: currentUserLogin, in: reviews) else { return items }
            return items.filter { $0.timestamp > cutoff }
        }
    }

    nonisolated static func lastReviewSubmittedAt(by login: String?, in reviews: [Review]) -> Date? {
        guard let login else { return nil }
        return reviews.filter { $0.user.login == login }.compactMap(\.submittedAt).max()
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
