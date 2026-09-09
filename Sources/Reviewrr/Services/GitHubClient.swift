import Foundation

enum GitHubError: LocalizedError {
    /// No token was configured *and* GitHub rejected the request because this
    /// endpoint requires authentication (401 with no `Authorization` header
    /// sent). Distinct from `.unauthorized`, where a token was sent and
    /// GitHub rejected it — those need different fixes ("add a token" vs.
    /// "your token is bad").
    case noToken
    /// A token was sent but GitHub rejected it outright.
    case unauthorized
    case rateLimited(resetAt: Date?)
    /// `hadToken` distinguishes "the configured token can't see this" from
    /// "no token was sent, so a private repo 404s exactly like a nonexistent
    /// one" — GitHub deliberately makes those look identical from outside.
    case notFound(hadToken: Bool)
    case validation(String)
    case apiError(String)
    case network(Error)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token configured — add one in Settings."
        case .unauthorized:
            return "GitHub rejected the token as invalid or expired. Update it in Settings."
        case .rateLimited(let resetAt):
            if let resetAt {
                let formatter = RelativeDateTimeFormatter()
                return "GitHub rate limit hit. Resets \(formatter.localizedString(for: resetAt, relativeTo: .now))."
            }
            return "GitHub rate limit hit. Try again shortly."
        case .notFound(let hadToken):
            if hadToken {
                return "Pull request not found. Check the owner/repo/number, or that this token can see this repository."
            }
            return "Pull request not found. If it's in a private repository, add a GitHub token with repo access in Settings."
        case .validation(let message):
            return message
        case .apiError(let message):
            return message
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let message):
            return message
        }
    }
}

/// Endpoint-level GitHub access for the single-PR review workspace.
/// All request plumbing, error mapping, pagination, and GraphQL live in
/// `GitHubAPI`; this type only knows which paths make a pull request.
///
/// Stateless with respect to auth: every call takes the token it should
/// use, so a request can never race a just-saved token.
struct GitHubClient {
    var api: GitHubAPI

    init(host: ForgeHost = .dotCom) {
        self.api = GitHubAPI(host: host)
    }

    init(api: GitHubAPI) {
        self.api = api
    }

    var host: ForgeHost { api.host }

    /// GitHub's REST path for one pull request.
    ///
    /// This lived on `PRReference` as `apiPath`, which put one forge's URL
    /// grammar on a model shared by both — GitLab addresses the same thing
    /// as `/projects/<encoded path>/merge_requests/<iid>`, and a reference
    /// that answers only GitHub's shape is a reference that quietly assumes
    /// which server it is for. Each client owns its own paths now (see
    /// `GitLabAPI.mergeRequestPath`).
    func pullRequestPath(_ reference: PRReference) -> String {
        "/repos/\(reference.owner)/\(reference.repo)/pulls/\(reference.number)"
    }

    // MARK: - Endpoints

    func verifyToken(_ token: String?) async throws -> GitHubUser {
        // `/user` always requires auth — fail fast with the specific "no
        // token" message instead of a round trip that would just 401.
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubError.noToken
        }
        return try await api.get(GitHubUser.self, path: "/user", token: token)
    }

    func fetchPullRequest(_ reference: PRReference, token: String?) async throws -> PullRequest {
        try await api.get(PullRequest.self, path: pullRequestPath(reference), token: token)
    }

    func fetchFiles(_ reference: PRReference, token: String?) async throws -> [PRFile] {
        // Concurrent rather than page-by-page: a large PR's file list is the
        // one request the workspace cannot render without.
        try await api.getAllPagesConcurrently(PRFile.self, path: pullRequestPath(reference) + "/files", token: token)
    }

    func fetchIssueComments(_ reference: PRReference, token: String?) async throws -> [IssueComment] {
        try await api.getAllPagesConcurrently(
            IssueComment.self,
            path: "/repos/\(reference.owner)/\(reference.repo)/issues/\(reference.number)/comments",
            token: token
        )
    }

    func fetchReviews(_ reference: PRReference, token: String?) async throws -> [Review] {
        try await api.getAllPagesConcurrently(Review.self, path: pullRequestPath(reference) + "/reviews", token: token)
    }

    func fetchReviewComments(_ reference: PRReference, token: String?) async throws -> [ReviewComment] {
        try await api.getAllPagesConcurrently(ReviewComment.self, path: pullRequestPath(reference) + "/comments", token: token)
    }

    /// Fetches a file's full text content at a given ref (used to expand
    /// collapsed context around a hunk). Returns nil for binary content.
    func fetchFileContent(owner: String, repo: String, path: String, ref: String, token: String?) async throws -> String? {
        let encodedPath = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        struct ContentResponse: Decodable {
            let content: String
            let encoding: String
        }
        let decoded = try await api.get(
            ContentResponse.self,
            path: "/repos/\(owner)/\(repo)/contents/\(encodedPath)",
            token: token,
            query: [URLQueryItem(name: "ref", value: ref)]
        )
        guard decoded.encoding == "base64" else { return nil }
        let cleaned = decoded.content.replacingOccurrences(of: "\n", with: "")
        guard let bytes = Data(base64Encoded: cleaned) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    /// Submits one atomic review: a summary plus every confirmed inline
    /// comment, matching GitHub's `POST .../reviews` contract.
    func submitReview(
        _ reference: PRReference, token: String?, summary: String, event: ReviewEvent, comments: [DraftComment]
    ) async throws -> Review {
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubError.noToken
        }
        struct Body: Encodable {
            struct Comment: Encodable {
                let path: String
                let line: Int
                let side: String
                let body: String
                // Omitted for a single-line comment. GitHub rejects a
                // `start_line` equal to `line`, and requires `start_side`
                // whenever `start_line` is present.
                let startLine: Int?
                let startSide: String?

                enum CodingKeys: String, CodingKey {
                    case path, line, side, body
                    case startLine = "start_line"
                    case startSide = "start_side"
                }
            }
            let body: String
            let event: String
            let comments: [Comment]
        }
        let body = Body(
            body: summary,
            event: event.rawValue,
            comments: comments.map { comment in
                let range = comment.lineRange
                let isMultiLine = range.count > 1
                return Body.Comment(
                    path: comment.path,
                    line: range.upperBound,
                    side: comment.side.rawValue,
                    body: comment.body,
                    startLine: isMultiLine ? range.lowerBound : nil,
                    startSide: isMultiLine ? (comment.startSide ?? comment.side).rawValue : nil
                )
            }
        )
        return try await api.post(Review.self, path: pullRequestPath(reference) + "/reviews", token: token, body: body)
    }
}
