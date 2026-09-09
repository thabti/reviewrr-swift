import Foundation

/// The dashboard's GitLab side: watched-project merge request listing, the
/// reviewer buckets, and the project probe that validates a watchlist entry.
///
/// Mirrors `InboxService`'s surface so `DashboardModel` dispatches on the
/// host's forge and nothing above it changes. Rows land in the same
/// `InboxPR`, so a GitHub project and a GitLab project appear in one inbox.
struct GitLabInboxService {
    var api: GitLabAPI

    init(api: GitLabAPI) {
        self.api = api
    }

    init(host: ForgeHost, basic: BasicCredential? = nil) {
        self.api = GitLabAPI(host: host, basic: basic)
    }

    /// One row of GitLab's merge request list. A subset of `GLMergeRequest`:
    /// the list endpoint omits `diff_refs` and the counts, and decoding a
    /// separate narrower type keeps a missing field on the *list* from
    /// failing the whole page.
    struct RawMergeRequest: Decodable, Sendable {
        let iid: Int
        let title: String
        let state: String
        let draft: Bool?
        let workInProgress: Bool?
        let author: GLUser
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let labels: [GLLabel]?
        let sourceBranch: String?
        let sha: String?
        let userNotesCount: Int?
        let reviewers: [GLUser]?
        let references: References?
        let webUrl: String?

        /// GitLab's own rendering of the project path, which is how a
        /// bucket row learns which project it belongs to — the list
        /// endpoint for `/merge_requests` spans every project the user can
        /// see, so the row cannot assume the project it was asked about.
        struct References: Decodable, Sendable {
            let full: String?
        }

        enum CodingKeys: String, CodingKey {
            case iid, title, state, draft, author, labels, sha, reviewers, references
            case workInProgress = "work_in_progress"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case mergedAt = "merged_at"
            case sourceBranch = "source_branch"
            case userNotesCount = "user_notes_count"
            case webUrl = "web_url"
        }

        var isDraft: Bool { draft ?? workInProgress ?? false }
    }

    // MARK: - Watchlist validation

    /// Probes a project so a watchlist entry cannot be saved for something
    /// this credential cannot see.
    func validateRepository(owner: String, repo: String, token: String?) async throws {
        struct Probe: Decodable { let id: Int }
        _ = try await api.get(
            Probe.self,
            path: "/projects/\(GitLabAPI.encodedProjectPath(owner: owner, repo: repo))",
            token: token
        )
    }

    // MARK: - Per-project sync

    func fetchProject(_ project: WatchedProject, token: String?) async throws -> [InboxPR] {
        let raw = try await api.getAllPages(
            RawMergeRequest.self,
            path: "/projects/\(GitLabAPI.encodedProjectPath(owner: project.owner, repo: project.repo))/merge_requests",
            token: token,
            query: [
                URLQueryItem(name: "state", value: "all"),
                URLQueryItem(name: "order_by", value: "updated_at"),
                URLQueryItem(name: "sort", value: "desc"),
                URLQueryItem(name: "with_labels_details", value: "true"),
            ],
            // The dashboard wants recent activity, not an archive. Same
            // reasoning as the GitHub path's page cap.
            maxPages: 2
        )
        return raw.map { row in
            InboxPR(host: api.host, owner: project.owner, repo: project.repo, raw: row, source: .project, buckets: [])
        }
    }

    // MARK: - Reviewer buckets

    /// The four buckets, from GitLab's own filters on the instance-wide
    /// merge request list.
    ///
    /// GitLab has no free-text search grammar like GitHub's `review:required`
    /// qualifiers — it has typed parameters, which is a better fit: each
    /// bucket is one documented filter rather than a query string.
    ///
    /// "Participated" has no GitLab equivalent at all. Rather than
    /// approximate it with something that means something else, it comes
    /// back empty, and the section is simply absent for a GitLab host.
    func fetchReviewerBuckets(token: String?) async throws -> [InboxReviewerBucket: [InboxPR]] {
        var result: [InboxReviewerBucket: [InboxPR]] = [:]
        for bucket in InboxReviewerBucket.allCases {
            guard let query = Self.bucketQuery(bucket) else {
                result[bucket] = []
                continue
            }
            let raw = try await api.getAllPages(
                RawMergeRequest.self,
                path: "/merge_requests",
                token: token,
                query: query + [
                    URLQueryItem(name: "state", value: "opened"),
                    URLQueryItem(name: "order_by", value: "updated_at"),
                    URLQueryItem(name: "sort", value: "desc"),
                    URLQueryItem(name: "with_labels_details", value: "true"),
                ],
                maxPages: 1
            )
            result[bucket] = raw.map { row in
                let path = Self.splitProjectPath(row.references?.full)
                return InboxPR(
                    host: api.host, owner: path.owner, repo: path.repo, raw: row,
                    source: .search, buckets: [bucket]
                )
            }
        }
        return result
    }

    static func bucketQuery(_ bucket: InboxReviewerBucket) -> [URLQueryItem]? {
        switch bucket {
        case .needsReview:
            return [
                URLQueryItem(name: "scope", value: "all"),
                URLQueryItem(name: "reviewer_id", value: "Any"),
                URLQueryItem(name: "scope", value: "assigned_to_me"),
            ]
        case .assigned:
            return [URLQueryItem(name: "scope", value: "assigned_to_me")]
        case .authored:
            return [URLQueryItem(name: "scope", value: "created_by_me")]
        case .participated:
            // No GitLab filter means "I commented on this". Left out rather
            // than filled with a different meaning.
            return nil
        }
    }

    /// `group/subgroup/project!42` → (`group/subgroup`, `project`).
    ///
    /// GitLab's `references.full` carries the whole path plus the merge
    /// request's `!iid` suffix, and the group part can be nested any number
    /// of levels — so the split takes the *last* segment as the project and
    /// everything before it as the owner, which is the same convention
    /// `PRReference` uses for GitLab.
    static func splitProjectPath(_ raw: String?) -> (owner: String, repo: String) {
        guard let raw, !raw.isEmpty else { return ("", "") }
        let withoutReference = raw.split(separator: "!").first.map(String.init) ?? raw
        var parts = withoutReference.split(separator: "/").map(String.init)
        guard let repo = parts.popLast() else { return ("", "") }
        return (parts.joined(separator: "/"), repo)
    }
}

extension InboxPR {
    /// One GitLab merge request as an inbox row.
    ///
    /// `reviewDecision` and `ciState` stay unknown: GitLab reports neither
    /// on its list endpoint, and per-row requests for them would cost one
    /// round trip per merge request. The row says "unknown" rather than
    /// guessing, exactly as the GitHub list path does.
    init(
        host: ForgeHost,
        owner: String,
        repo: String,
        raw: GitLabInboxService.RawMergeRequest,
        source: InboxPRSource,
        buckets: Set<InboxReviewerBucket>
    ) {
        self.init(
            host: host,
            owner: owner,
            repo: repo,
            number: raw.iid,
            title: raw.title,
            authorLogin: raw.author.username,
            authorAvatarURL: raw.author.avatarUrl,
            state: InboxPR.gitLabState(state: raw.state, draft: raw.isDraft, mergedAt: raw.mergedAt),
            isMerged: raw.state == "merged" || raw.mergedAt != nil,
            createdAt: raw.createdAt,
            updatedAt: raw.updatedAt,
            commentCount: raw.userNotesCount ?? 0,
            labels: (raw.labels ?? []).map(GitLabMapper.label),
            requestedReviewers: (raw.reviewers ?? []).map(\.username),
            reviewDecision: .none,
            ciState: .unknown,
            additions: nil,
            deletions: nil,
            changedFiles: nil,
            headRef: raw.sourceBranch,
            headSha: raw.sha,
            source: source,
            buckets: buckets
        )
    }

    /// GitLab reports "merged" as a state of its own, where GitHub reports
    /// closed plus a `merged_at` timestamp.
    static func gitLabState(state: String, draft: Bool, mergedAt: Date?) -> InboxPRState {
        if state == "merged" || mergedAt != nil { return .merged }
        if state == "closed" || state == "locked" { return .closed }
        if draft { return .draft }
        return .open
    }
}
