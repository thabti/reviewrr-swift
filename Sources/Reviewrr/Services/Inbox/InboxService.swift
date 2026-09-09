import Foundation

/// Cross-repository PR aggregation: per-project pull syncs plus
/// reviewer-centric search buckets, enriched with review decision, CI
/// rollup, and comment counts via one batched GraphQL call per project
/// where that's cheaper than N follow-up REST calls. Pure networking and
/// normalization — no `@Published` state, no view references — so it's
/// safe to call from any actor and to construct fresh per request.
struct InboxService {
    var api: GitHubAPI

    // Bounds so one watched project (or one search bucket) can never crawl
    // an entire history: "paginated, bounded — do not crawl everything."
    var maxProjectPages: Int = 3
    var projectPageSize: Int = 50
    var maxSearchPages: Int = 2
    var searchPageSize: Int = 50
    /// How many of a project's freshest rows get the extra GraphQL round
    /// trip; older rows keep REST-only data rather than growing one query
    /// without bound.
    var maxEnrichedPerProject: Int = 40

    init(host: ForgeHost) { self.api = GitHubAPI(host: host) }
    init(api: GitHubAPI) { self.api = api }

    // MARK: - Adding a project

    /// Confirms `owner/repo` exists and is visible with `token` before it's
    /// added to the watchlist. GitHub returns 404 for both a nonexistent
    /// repo and a private one this token can't see — `GitHubError` already
    /// phrases that distinction, so callers can surface it directly.
    func validateRepository(owner: String, repo: String, token: String?) async throws {
        _ = try await api.get(RepoExistenceProbe.self, path: "/repos/\(owner)/\(repo)", token: token)
    }

    // MARK: - Per-project sync

    func fetchProject(_ project: WatchedProject, token: String?) async throws -> [InboxPR] {
        let raw = try await api.getAllPagesConcurrently(
            RawPullListItem.self,
            path: "/repos/\(project.owner)/\(project.repo)/pulls",
            token: token,
            query: [
                URLQueryItem(name: "state", value: "all"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
            ],
            perPage: projectPageSize,
            maxPages: maxProjectPages
        )
        var pulls = raw.map { InboxPR(host: project.host, owner: project.owner, repo: project.repo, raw: $0) }

        // GraphQL enrichment is best-effort: Enterprise Server without
        // GraphQL enabled, a fine-grained token missing scope, or a
        // transient error should degrade to REST-only data, never fail
        // the whole row set.
        let enrichNumbers = Array(pulls.prefix(maxEnrichedPerProject).map(\.number))
        if let enrichment = try? await fetchEnrichment(
            owner: project.owner, repo: project.repo, numbers: enrichNumbers, token: token
        ) {
            for index in pulls.indices {
                guard let node = enrichment[pulls[index].number] else { continue }
                pulls[index].reviewDecision = Self.mapReviewDecision(node.reviewDecision)
                pulls[index].ciState = Self.mapCIState(node.commits?.nodes.first?.commit.statusCheckRollup?.state)
                if let total = node.comments?.totalCount { pulls[index].commentCount = total }
                if let additions = node.additions { pulls[index].additions = additions }
                if let deletions = node.deletions { pulls[index].deletions = deletions }
                if let changedFiles = node.changedFiles { pulls[index].changedFiles = changedFiles }
            }
        }
        return pulls
    }

    // MARK: - Reviewer-centric search buckets

    /// Fetches every bucket across all repositories the token can see. All
    /// or nothing: if one bucket's search fails (e.g. rate-limited), the
    /// whole call throws rather than committing a partial set of buckets —
    /// callers should keep showing the previous complete snapshot alongside
    /// the error rather than silently dropping buckets that didn't fail.
    func fetchReviewerBuckets(token: String?) async throws -> [InboxReviewerBucket: [InboxPR]] {
        var result: [InboxReviewerBucket: [InboxPR]] = [:]
        for bucket in InboxReviewerBucket.allCases {
            let items = try await searchIssues(query: "is:pr \(bucket.searchQualifiers)", token: token)
            result[bucket] = items.map { InboxPR(bucket: bucket, raw: $0, host: api.host) }
        }
        return result
    }

    /// `/search/issues` has its own, much lower rate limit than the rest of
    /// the REST API, and returns an envelope (`total_count`/`items`) rather
    /// than a bare array, so it can't use `GitHubAPI.getAllPages`.
    private func searchIssues(query: String, token: String?) async throws -> [RawSearchIssueItem] {
        var results: [RawSearchIssueItem] = []
        // The envelope's `total_count` isn't known until the first response,
        // but every page holds at most `searchPageSize` items regardless.
        results.reserveCapacity(searchPageSize)
        var request: URLRequest? = try api.makeRequest(
            path: "/search/issues",
            token: token,
            query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "per_page", value: String(searchPageSize)),
            ]
        )
        var seenURLs = Set<URL>()
        var pages = 0
        while let currentRequest = request, pages < maxSearchPages {
            if let url = currentRequest.url {
                guard !seenURLs.contains(url) else { break }
                seenURLs.insert(url)
            }
            let (data, http) = try await api.send(currentRequest)
            let decoded = try GitHubAPI.decode(SearchIssuesResponse.self, from: data, status: http.statusCode)
            results.reserveCapacity(results.count + decoded.items.count)
            results.append(contentsOf: decoded.items)
            request = GitHubAPI.nextPageRequest(from: http, previous: currentRequest)
            pages += 1
        }
        return results
    }

    // MARK: - GraphQL enrichment

    /// One request per project, aliasing every targeted PR number under a
    /// single `repository(owner:name:)` selection — this is the "one
    /// batched GraphQL query per project" the workplan calls for, replacing
    /// what would otherwise be one REST round trip per PR just to read
    /// `reviewDecision` and `statusCheckRollup`.
    private func fetchEnrichment(
        owner: String, repo: String, numbers: [Int], token: String?
    ) async throws -> [Int: PRGraphQLNode] {
        guard !numbers.isEmpty else { return [:] }
        let fields = """
        reviewDecision
        additions
        deletions
        changedFiles
        comments { totalCount }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        """
        let aliasedFields = numbers.enumerated()
            .map { index, number in "pr\(index): pullRequest(number: \(number)) { \(fields) }" }
            .joined(separator: "\n")
        let query = """
        query {
          repository(owner: "\(owner)", name: "\(repo)") {
            \(aliasedFields)
          }
        }
        """
        let wrapper = try await api.graphQL(RepositoryEnrichmentWrapper.self, query: query, token: token)
        var byNumber: [Int: PRGraphQLNode] = [:]
        for (index, number) in numbers.enumerated() {
            if let node = wrapper.repository["pr\(index)"] {
                byNumber[number] = node
            }
        }
        return byNumber
    }

    fileprivate static func mapReviewDecision(_ raw: String?) -> InboxReviewDecision {
        switch raw {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return .none
        }
    }

    fileprivate static func mapCIState(_ raw: String?) -> InboxCIState {
        switch raw {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        case "PENDING", "EXPECTED": return .pending
        default: return .unknown
        }
    }
}

// MARK: - Raw REST payloads

/// Minimal decode target for confirming a repository exists and is
/// visible — only enough fields to prove the response was a real repo.
private struct RepoExistenceProbe: Decodable {
    let id: Int
}

/// `GET /repos/{owner}/{repo}/pulls` returns a materially smaller shape
/// than the single-PR endpoint (no `additions`/`deletions`/`comments`/etc.),
/// so it can't decode into the shared `PullRequest` model — this mirrors
/// exactly what the list endpoint sends.
private struct RawPullListItem: Decodable {
    let number: Int
    let title: String
    let state: String
    let draft: Bool
    let user: GitHubUser
    let head: PullRequest.Branch
    let base: PullRequest.Branch
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let labels: [GitHubLabel]
    let requestedReviewers: [GitHubUser]?

    enum CodingKeys: String, CodingKey {
        case number, title, state, draft, user, head, base, labels
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case requestedReviewers = "requested_reviewers"
    }
}

/// One `/search/issues` result item. The search API returns every issue
/// and PR under one schema; `pull_request` is present only on PRs.
private struct RawSearchIssueItem: Decodable {
    struct PullRequestInfo: Decodable {
        let mergedAt: Date?
        enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
    }

    let number: Int
    let title: String
    let state: String
    let draft: Bool?
    let user: GitHubUser
    let createdAt: Date
    let updatedAt: Date
    let comments: Int
    let labels: [GitHubLabel]
    let repositoryUrl: String
    let pullRequest: PullRequestInfo?

    enum CodingKeys: String, CodingKey {
        case number, title, state, draft, user, comments, labels
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case repositoryUrl = "repository_url"
        case pullRequest = "pull_request"
    }
}

private struct SearchIssuesResponse: Decodable {
    let totalCount: Int
    let incompleteResults: Bool
    let items: [RawSearchIssueItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case incompleteResults = "incomplete_results"
        case items
    }
}

// MARK: - GraphQL payload

/// GraphQL keys are already camelCase, matching these property names
/// directly — no snake-case conversion needed.
private struct PRGraphQLNode: Decodable {
    struct CommentsConnection: Decodable { let totalCount: Int }
    struct StatusCheckRollup: Decodable { let state: String }
    struct CommitDetail: Decodable { let statusCheckRollup: StatusCheckRollup? }
    struct CommitNode: Decodable { let commit: CommitDetail }
    struct CommitsConnection: Decodable { let nodes: [CommitNode] }

    let reviewDecision: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let comments: CommentsConnection?
    let commits: CommitsConnection?
}

/// A null aliased `pullRequest(number:)` (the PR vanished between the REST
/// list call and this enrichment call, a few seconds later at most) makes
/// the whole dictionary decode fail — caught by the `try?` at the call
/// site, so that one project's enrichment silently skips for this poll
/// cycle rather than crashing; the next cycle recovers.
private struct RepositoryEnrichmentWrapper: Decodable {
    let repository: [String: PRGraphQLNode]
}

// MARK: - Normalizing into InboxPR

private extension InboxPR {
    static func computeState(state: String, draft: Bool, mergedAt: Date?) -> InboxPRState {
        if mergedAt != nil { return .merged }
        if state == "closed" { return .closed }
        if draft { return .draft }
        return .open
    }

    static func splitRepositoryURL(_ raw: String) -> (owner: String, repo: String) {
        let parts = raw.split(separator: "/")
        guard parts.count >= 2 else { return ("", "") }
        return (String(parts[parts.count - 2]), String(parts[parts.count - 1]))
    }

    init(host: ForgeHost, owner: String, repo: String, raw: RawPullListItem) {
        self.init(
            host: host, owner: owner, repo: repo, number: raw.number, title: raw.title,
            authorLogin: raw.user.login, authorAvatarURL: raw.user.avatarUrl,
            state: InboxPR.computeState(state: raw.state, draft: raw.draft, mergedAt: raw.mergedAt),
            isMerged: raw.mergedAt != nil, createdAt: raw.createdAt, updatedAt: raw.updatedAt,
            // Comment count isn't in the list payload; GraphQL enrichment
            // fills it in for the freshest rows, older rows show 0.
            commentCount: 0, labels: raw.labels,
            requestedReviewers: (raw.requestedReviewers ?? []).map(\.login),
            reviewDecision: .none, ciState: .unknown,
            additions: nil, deletions: nil, changedFiles: nil,
            headRef: raw.head.ref, headSha: raw.head.sha,
            source: .project, buckets: []
        )
    }

    init(bucket: InboxReviewerBucket, raw: RawSearchIssueItem, host: ForgeHost) {
        let parsed = InboxPR.splitRepositoryURL(raw.repositoryUrl)
        self.init(
            host: host, owner: parsed.owner, repo: parsed.repo, number: raw.number, title: raw.title,
            authorLogin: raw.user.login, authorAvatarURL: raw.user.avatarUrl,
            state: InboxPR.computeState(state: raw.state, draft: raw.draft ?? false, mergedAt: raw.pullRequest?.mergedAt),
            isMerged: raw.pullRequest?.mergedAt != nil, createdAt: raw.createdAt, updatedAt: raw.updatedAt,
            commentCount: raw.comments, labels: raw.labels, requestedReviewers: [],
            reviewDecision: .none, ciState: .unknown,
            additions: nil, deletions: nil, changedFiles: nil,
            // Search results carry no head ref/sha or diff stats.
            headRef: nil, headSha: nil,
            source: .search, buckets: [bucket]
        )
    }
}
