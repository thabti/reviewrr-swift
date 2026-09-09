import Foundation

/// One review-workspace API, whichever forge is behind it.
///
/// Deliberately shaped as `GitHubClient`'s method-for-method twin rather
/// than as a new abstraction: `AppModel.performLoad` fans out five calls
/// and assembles them, and that code is about *loading a review*, not about
/// which service the review came from. Matching the existing signatures
/// means the workspace, the draft store, and the diff pane needed no
/// changes at all to review a merge request.
///
/// Stateless with respect to the token, like both clients under it. The
/// Basic credential travels on the value because it is host configuration
/// (see `GitHubAPI.basic`).
struct ForgeClient {
    let host: ForgeHost
    let basic: BasicCredential?

    init(host: ForgeHost, basic: BasicCredential? = nil) {
        self.host = host
        self.basic = basic
    }

    var forge: Forge { host.forge }

    private var github: GitHubClient { GitHubClient(api: GitHubAPI(host: host, basic: basic)) }
    private var gitlab: GitLabClient { GitLabClient(api: GitLabAPI(host: host, basic: basic)) }

    // MARK: - Credential

    func verifyToken(_ token: String?) async throws -> GitHubUser {
        switch forge {
        case .github: return try await github.verifyToken(token)
        case .gitlab: return try await gitlab.verifyToken(token)
        }
    }

    // MARK: - Loading a review

    func fetchPullRequest(_ reference: PRReference, token: String?) async throws -> PullRequest {
        switch forge {
        case .github: return try await github.fetchPullRequest(reference, token: token)
        case .gitlab: return try await gitlab.fetchPullRequest(reference, token: token)
        }
    }

    func fetchFiles(_ reference: PRReference, token: String?) async throws -> [PRFile] {
        switch forge {
        case .github: return try await github.fetchFiles(reference, token: token)
        case .gitlab: return try await gitlab.fetchFiles(reference, token: token)
        }
    }

    func fetchIssueComments(_ reference: PRReference, token: String?) async throws -> [IssueComment] {
        switch forge {
        case .github:
            return try await github.fetchIssueComments(reference, token: token)
        case .gitlab:
            return try await gitlab.fetchDiscussions(
                reference, mergeRequestURL: webURL(reference), token: token
            ).comments
        }
    }

    func fetchReviews(_ reference: PRReference, token: String?) async throws -> [Review] {
        switch forge {
        case .github: return try await github.fetchReviews(reference, token: token)
        case .gitlab: return try await gitlab.fetchReviews(reference, token: token)
        }
    }

    /// Flat diff-anchored comments, which the caller groups with
    /// `groupedIntoThreads()`. GitLab's discussions already carry the
    /// grouping, and the mapper encodes it as `in_reply_to_id` so that same
    /// grouping call reconstructs it — see `GitLabMapper.reviewComments`.
    func fetchReviewComments(_ reference: PRReference, token: String?) async throws -> [ReviewComment] {
        switch forge {
        case .github:
            return try await github.fetchReviewComments(reference, token: token)
        case .gitlab:
            let discussions = try await gitlab.fetchDiscussionsRaw(reference, token: token)
            return GitLabMapper.reviewComments(from: discussions, mergeRequestURL: webURL(reference))
        }
    }

    func fetchFileContent(owner: String, repo: String, path: String, ref: String, token: String?) async throws -> String? {
        switch forge {
        case .github:
            return try await github.fetchFileContent(owner: owner, repo: repo, path: path, ref: ref, token: token)
        case .gitlab:
            return try await gitlab.fetchFileContent(owner: owner, repo: repo, path: path, ref: ref, token: token)
        }
    }

    func fetchChecks(owner: String, repo: String, headSha: String, number: Int, token: String?) async throws -> [CheckRun] {
        switch forge {
        case .github:
            return try await ChecksClient(api: GitHubAPI(host: host, basic: basic))
                .fetchChecks(owner: owner, repo: repo, headSha: headSha, token: token)
        case .gitlab:
            // GitLab attaches pipelines to the merge request, not to a bare
            // SHA, so the number is what identifies them — the head SHA is
            // accepted here only to keep one signature for both forges.
            return try await gitlab.fetchChecks(
                PRReference(owner: owner, repo: repo, number: number), token: token
            )
        }
    }

    // MARK: - Submitting

    /// Publishes a review.
    ///
    /// The signature matches GitHub's even though GitLab needs the merge
    /// request's diff SHAs to anchor comments: fetching those is this
    /// type's problem, not the caller's. It costs one extra request on
    /// submit, and only on GitLab, and only when there are inline comments
    /// to anchor.
    func submitReview(
        _ reference: PRReference, token: String?, summary: String, event: ReviewEvent, comments: [DraftComment]
    ) async throws {
        switch forge {
        case .github:
            _ = try await github.submitReview(
                reference, token: token, summary: summary, event: event, comments: comments
            )
        case .gitlab:
            let diffRefs = comments.isEmpty
                ? nil
                : try await gitlab.fetchMergeRequest(reference, token: token).diffRefs
            try await gitlab.submitReview(
                reference, token: token, summary: summary, event: event,
                comments: comments, diffRefs: diffRefs
            )
        }
    }

    // MARK: - Helpers

    private func webURL(_ reference: PRReference) -> String {
        host.webURL(owner: reference.owner, repo: reference.repo, number: reference.number)?.absoluteString ?? ""
    }
}

extension GitLabClient {
    /// The undecorated discussions, for callers that want to map them
    /// themselves rather than take the split `fetchDiscussions` performs.
    func fetchDiscussionsRaw(_ reference: PRReference, token: String?) async throws -> [GLDiscussion] {
        try await api.getAllPages(
            GLDiscussion.self, path: api.mergeRequestPath(reference) + "/discussions", token: token
        )
    }
}
