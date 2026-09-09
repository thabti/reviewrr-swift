import CryptoKit
import Foundation

/// Coalesces concurrent requests for the same merge request's diffs.
///
/// `AppModel.load` fans out its stages in parallel, and on GitLab two of
/// them need the same `/diffs` response: the file list, and the merge
/// request itself — whose line counts GitLab does not report, so they are
/// counted from the patches. Without coalescing, opening a merge request
/// would fetch every diff twice.
///
/// In-flight tasks only, with no cache of finished results: a reviewer
/// pressing ⌘R after a force-push must get the new diff, and a TTL short
/// enough to guarantee that would be too short to help anyway.
actor GitLabDiffLoader {
    static let shared = GitLabDiffLoader()

    private struct Key: Hashable {
        let api: String
        let reference: String
    }

    private var inFlight: [Key: Task<[GLDiff], Error>] = [:]

    func diffs(
        for reference: PRReference,
        api: GitLabAPI,
        token: String?,
        fetch: @escaping @Sendable () async throws -> [GLDiff]
    ) async throws -> [GLDiff] {
        let key = Key(api: api.host.apiBaseURL.absoluteString, reference: reference.key)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// Endpoint-level GitLab access, mirroring `GitHubClient`: this type knows
/// only which paths make a merge request, while `GitLabAPI` owns request
/// plumbing and `GitLabMapper` owns translation into the app's models.
///
/// Stateless with respect to the token, like its GitHub counterpart — every
/// call takes the token it should use, so a request cannot race a
/// just-saved credential.
struct GitLabClient {
    var api: GitLabAPI

    init(host: ForgeHost, basic: BasicCredential? = nil) {
        self.api = GitLabAPI(host: host, basic: basic)
    }

    init(api: GitLabAPI) {
        self.api = api
    }

    var host: ForgeHost { api.host }

    // MARK: - Credential

    func verifyToken(_ token: String?) async throws -> GitHubUser {
        // `/user` always needs a credential; failing here beats a round trip
        // that can only 401. A Basic-only setup is allowed through, because
        // an instance patched to accept Basic on the API would work — and if
        // it does not, GitLab's own 401 says so precisely.
        guard api.basic != nil || token?.isEmpty == false else {
            throw GitLabError.noCredential
        }
        return GitLabMapper.user(try await api.get(GLUser.self, path: "/user", token: token))
    }

    /// Reads a project to answer "can this credential see it" without
    /// opening a merge request — the GitLab side of the Account pane's
    /// access check.
    func checkProjectAccess(owner: String, repo: String, token: String?) async throws -> GitHubRepositoryAccess {
        struct Probe: Decodable {
            let pathWithNamespace: String
            let visibility: String?
            enum CodingKeys: String, CodingKey {
                case pathWithNamespace = "path_with_namespace"
                case visibility
            }
        }
        let path = "/projects/\(GitLabAPI.encodedProjectPath(owner: owner, repo: repo))"
        let probe = try await api.get(Probe.self, path: path, token: token)
        return GitHubRepositoryAccess(
            owner: owner,
            repo: repo,
            fullName: probe.pathWithNamespace,
            isPrivate: probe.visibility != "public"
        )
    }

    // MARK: - Merge request

    func fetchMergeRequest(_ reference: PRReference, token: String?) async throws -> GLMergeRequest {
        // No `with_labels_details`: GitLab documents that parameter for its
        // *list* endpoints, not for a single merge request, and sending a
        // parameter an endpoint does not document is a way to find out how
        // an instance handles one. Labels arrive as bare names here — which
        // `GLLabel` decodes — and the inbox's list request, where the
        // parameter *is* documented, is what supplies label colours.
        try await api.get(
            GLMergeRequest.self,
            path: api.mergeRequestPath(reference),
            token: token
        )
    }

    /// The merge request, with line counts filled in from its diffs.
    ///
    /// GitLab's payload has no `additions`/`deletions` at all, so the diffs
    /// are needed to report anything truthful in the header. The fetch is
    /// coalesced with `fetchFiles`, so opening a merge request still costs
    /// one `/diffs` round trip rather than two.
    func fetchPullRequest(_ reference: PRReference, token: String?) async throws -> PullRequest {
        async let mergeRequest = fetchMergeRequest(reference, token: token)
        async let diffs = loadDiffs(reference, token: token)
        return GitLabMapper.pullRequest(try await mergeRequest, files: try await diffs.map(GitLabMapper.file(from:)))
    }

    func fetchFiles(_ reference: PRReference, token: String?) async throws -> [PRFile] {
        try await loadDiffs(reference, token: token).map(GitLabMapper.file(from:))
    }

    /// `/diffs` is the current endpoint; `/changes` is what instances before
    /// GitLab 15.7 have. The fallback triggers only on 404 — any other
    /// failure is reported as itself rather than retried against an endpoint
    /// that will fail the same way.
    private func loadDiffs(_ reference: PRReference, token: String?) async throws -> [GLDiff] {
        let api = self.api
        return try await GitLabDiffLoader.shared.diffs(for: reference, api: api, token: token) {
            do {
                return try await api.getAllPages(
                    GLDiff.self, path: api.mergeRequestPath(reference) + "/diffs", token: token
                )
            } catch GitLabError.notFound {
                return try await legacyChanges(reference, token: token)
            } catch GitLabError.serverError {
                // A 5xx from `/diffs` is worth one attempt at `/changes`
                // before giving up. Some self-managed instances fail on the
                // newer endpoint for a merge request the older one renders
                // fine — a wide diff, a broken ref — and the reviewer cares
                // about seeing the diff, not about which path served it.
                return try await legacyChanges(reference, token: token)
            }
        }
    }

    /// `/changes`, the pre-15.7 endpoint. Reached as a fallback only.
    private func legacyChanges(_ reference: PRReference, token: String?) async throws -> [GLDiff] {
        struct Changes: Decodable { let changes: [GLDiff] }
        let legacy = try await api.get(
            Changes.self, path: api.mergeRequestPath(reference) + "/changes", token: token
        )
        return legacy.changes
    }

    // MARK: - Conversation

    /// Discussions, split into the two shapes the app already has: threads
    /// anchored to diff lines, and merge-request-level comments. The index
    /// carries the discussion ids that replying and resolving need.
    func fetchDiscussions(
        _ reference: PRReference, mergeRequestURL: String, token: String?
    ) async throws -> (threads: [ReviewThread], comments: [IssueComment], index: GitLabThreadIndex) {
        let discussions = try await api.getAllPages(
            GLDiscussion.self, path: api.mergeRequestPath(reference) + "/discussions", token: token
        )
        return (
            threads: GitLabMapper.threads(from: discussions, mergeRequestURL: mergeRequestURL),
            comments: GitLabMapper.issueComments(from: discussions, mergeRequestURL: mergeRequestURL),
            index: GitLabThreadIndex(discussions: discussions)
        )
    }

    /// Approvals as `Review` values.
    ///
    /// Merge request approvals are a paid feature on GitLab.com and in some
    /// self-managed tiers. A 403 or 404 here therefore means "this instance
    /// does not offer approvals", not "the review failed" — so it returns
    /// empty rather than throwing, and the panel shows no approvals instead
    /// of an error a reviewer cannot act on.
    func fetchReviews(_ reference: PRReference, token: String?) async throws -> [Review] {
        do {
            let approvals = try await api.get(
                GLApprovals.self, path: api.mergeRequestPath(reference) + "/approvals", token: token
            )
            return GitLabMapper.reviews(from: approvals)
        } catch GitLabError.forbidden, GitLabError.notFound {
            return []
        } catch GitLabError.serverError {
            // Approvals are supporting detail. An instance failing on this
            // endpoint must not stop the merge request opening — the diff is
            // what the reviewer came for.
            return []
        }
    }

    // MARK: - CI

    /// The newest pipeline's jobs, as check runs.
    ///
    /// Jobs rather than the pipeline alone, because "which job failed" is
    /// the question a reviewer has. If the jobs cannot be read — a token
    /// without the scope, or a pipeline still being created — the pipeline
    /// itself is reported as a single run so CI does not look absent.
    func fetchChecks(_ reference: PRReference, token: String?) async throws -> [CheckRun] {
        let pipelines: [GLPipeline]
        do {
            pipelines = try await api.getAllPages(
                GLPipeline.self, path: api.mergeRequestPath(reference) + "/pipelines", token: token, maxPages: 1
            )
        } catch GitLabError.serverError, GitLabError.forbidden, GitLabError.notFound {
            // CI is supporting detail too. The panel shows no checks rather
            // than failing the load.
            return []
        }
        guard let newest = pipelines.max(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) else {
            return []
        }
        do {
            let jobs = try await api.getAllPages(
                GLJob.self,
                path: "/projects/\(api.projectPath(reference))/pipelines/\(newest.id)/jobs",
                token: token
            )
            guard !jobs.isEmpty else { return [GitLabMapper.checkRun(from: newest)] }
            return jobs.map { GitLabMapper.checkRun(from: $0, pipelineID: newest.id) }
        } catch {
            return [GitLabMapper.checkRun(from: newest)]
        }
    }

    // MARK: - File content

    /// A file's full text at a ref, for expanding context around a hunk.
    /// GitLab needs the file path URL-encoded into one segment, exactly
    /// like a project path.
    func fetchFileContent(owner: String, repo: String, path: String, ref: String, token: String?) async throws -> String? {
        struct FileResponse: Decodable {
            let content: String?
            let encoding: String?
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let project = GitLabAPI.encodedProjectPath(owner: owner, repo: repo)
        let response = try await api.get(
            FileResponse.self,
            path: "/projects/\(project)/repository/files/\(encodedPath)",
            token: token,
            query: [URLQueryItem(name: "ref", value: ref)]
        )
        guard response.encoding == "base64", let content = response.content else { return nil }
        let cleaned = content.replacingOccurrences(of: "\n", with: "")
        guard let bytes = Data(base64Encoded: cleaned) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    // MARK: - Submitting a review

    /// Publishes a review: inline comments as draft notes then one bulk
    /// publish, the summary as a merge-request note, and an approval when
    /// the reviewer asked for one.
    ///
    /// This ordering is what makes GitLab behave like the atomic review the
    /// app promises. Draft notes are staged server-side and published
    /// together, so a reviewer's inline comments appear at once rather than
    /// trickling in one notification at a time.
    ///
    /// **"Request changes" has no GitLab equivalent.** GitLab has approval
    /// and the absence of approval; there is no rejection object. That event
    /// therefore publishes the comments and the summary and does *not*
    /// approve — and, when the reviewer had previously approved, withdraws
    /// that approval, which is the only way GitLab records "not from me".
    func submitReview(
        _ reference: PRReference,
        token: String?,
        summary: String,
        event: ReviewEvent,
        comments: [DraftComment],
        diffRefs: GLDiffRefs?
    ) async throws {
        guard token?.isEmpty == false else { throw GitLabError.noCredential }

        if !comments.isEmpty {
            guard let diffRefs, let baseSha = diffRefs.baseSha, let headSha = diffRefs.headSha else {
                throw GitLabError.validation(
                    "GitLab needs this merge request's diff SHAs to anchor inline comments, and this one reports none. Refresh the merge request and try again."
                )
            }
            for comment in comments {
                try await createDraftNote(
                    reference, token: token, comment: comment,
                    baseSha: baseSha, headSha: headSha, startSha: diffRefs.startSha ?? baseSha
                )
            }
            try await api.postNoContent(
                path: api.mergeRequestPath(reference) + "/draft_notes/bulk_publish",
                token: token,
                body: Optional<String>.none
            )
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            struct NoteBody: Encodable { let body: String }
            _ = try await api.postNoContent(
                path: api.mergeRequestPath(reference) + "/notes",
                token: token,
                body: NoteBody(body: trimmedSummary)
            )
        }

        switch event {
        case .approve:
            try await approve(reference, token: token)
        case .requestChanges:
            // Withdrawing an approval is idempotent in effect but 404s when
            // there was none to withdraw, which is not a failure of the
            // review — the comments and summary are already published.
            try? await unapprove(reference, token: token)
        case .comment:
            break
        }
    }

    /// One unpublished inline comment.
    ///
    /// The position payload is GitLab's, and every field in it is required
    /// for a text position: the three SHAs, both paths, and the line on
    /// whichever side the comment sits.
    private func createDraftNote(
        _ reference: PRReference,
        token: String?,
        comment: DraftComment,
        baseSha: String,
        headSha: String,
        startSha: String
    ) async throws {
        let range = comment.lineRange
        let isRight = comment.side == .right

        struct LineRange: Encodable {
            let start: LineRangeEndValue
            let end: LineRangeEndValue
        }
        struct Position: Encodable {
            let baseSha: String
            let startSha: String
            let headSha: String
            let positionType: String
            let oldPath: String
            let newPath: String
            let oldLine: Int?
            let newLine: Int?
            let lineRange: LineRange?

            enum CodingKeys: String, CodingKey {
                case baseSha = "base_sha"
                case startSha = "start_sha"
                case headSha = "head_sha"
                case positionType = "position_type"
                case oldPath = "old_path"
                case newPath = "new_path"
                case oldLine = "old_line"
                case newLine = "new_line"
                case lineRange = "line_range"
            }
        }
        struct Body: Encodable {
            let note: String
            let position: Position
        }

        let position = Position(
            baseSha: baseSha,
            startSha: startSha,
            headSha: headSha,
            positionType: "text",
            // Both paths are sent even for a comment on one side: GitLab
            // requires the pair, and for anything but a rename they are the
            // same file.
            oldPath: comment.path,
            newPath: comment.path,
            oldLine: isRight ? nil : range.upperBound,
            newLine: isRight ? range.upperBound : nil,
            lineRange: comment.isMultiLine
                ? LineRange(
                    start: lineRangeEnd(path: comment.path, line: range.lowerBound, isRight: isRight),
                    end: lineRangeEnd(path: comment.path, line: range.upperBound, isRight: isRight)
                )
                : nil
        )
        _ = try await api.postNoContent(
            path: api.mergeRequestPath(reference) + "/draft_notes",
            token: token,
            body: Body(note: comment.body, position: position)
        )
    }

    /// A GitLab `line_code`: `SHA1(path)_oldLine_newLine`.
    ///
    /// The side the comment is not on gets 0, which is what GitLab itself
    /// uses for a line that exists on only one side. For a comment on a
    /// *context* line the real number on the other side does exist, and a
    /// `DraftComment` does not carry it — so a multi-line range anchored to
    /// context lines is the one case GitLab may reject. It reports that as
    /// a validation error with its own message rather than being silently
    /// re-anchored somewhere the reviewer did not choose.
    private func lineRangeEnd(path: String, line: Int, isRight: Bool) -> LineRangeEndValue {
        let digest = Insecure.SHA1.hash(data: Data(path.utf8))
        let sha1 = digest.compactMap { String(format: "%02x", $0) }.joined()
        let oldLine = isRight ? 0 : line
        let newLine = isRight ? line : 0
        return LineRangeEndValue(
            lineCode: "\(sha1)_\(oldLine)_\(newLine)",
            type: isRight ? "new" : "old",
            oldLine: isRight ? nil : line,
            newLine: isRight ? line : nil
        )
    }

    func approve(_ reference: PRReference, token: String?) async throws {
        do {
            _ = try await api.postNoContent(
                path: api.mergeRequestPath(reference) + "/approve", token: token, body: Optional<String>.none
            )
        } catch GitLabError.notFound, GitLabError.forbidden {
            throw GitLabError.unsupportedByInstance(
                "This GitLab does not allow approving through the API — merge request approvals are a paid feature, and approving also needs the Developer role. The comments and summary were published."
            )
        }
    }

    func unapprove(_ reference: PRReference, token: String?) async throws {
        _ = try await api.postNoContent(
            path: api.mergeRequestPath(reference) + "/unapprove", token: token, body: Optional<String>.none
        )
    }

    // MARK: - Threads

    /// Replies into an existing discussion. Needs the discussion's hex id,
    /// which the app's integer-keyed thread does not carry — hence the index
    /// built by `fetchDiscussions`.
    func reply(
        _ reference: PRReference, discussionID: String, body: String, token: String?
    ) async throws {
        struct Body: Encodable { let body: String }
        _ = try await api.postNoContent(
            path: api.mergeRequestPath(reference) + "/discussions/\(discussionID)/notes",
            token: token,
            body: Body(body: body)
        )
    }

    /// Resolves or unresolves a discussion. GitLab exposes this as a `PUT`
    /// on the discussion with a `resolved` flag — no GraphQL needed, unlike
    /// GitHub, where thread resolution exists only in the v4 API.
    @discardableResult
    func setResolved(_ resolved: Bool, reference: PRReference, discussionID: String, token: String?) async throws -> Bool {
        struct Body: Encodable { let resolved: Bool }
        struct Response: Decodable { let id: String }
        _ = try await api.put(
            Response.self,
            path: api.mergeRequestPath(reference) + "/discussions/\(discussionID)",
            token: token,
            body: Body(resolved: resolved)
        )
        return resolved
    }
}

/// Named type for a `line_range` endpoint so the private helper above can
/// return it. Declared outside `submitReview`'s local structs because a
/// function cannot return a type declared inside another function's body.
struct LineRangeEndValue: Encodable {
    let lineCode: String
    let type: String?
    let oldLine: Int?
    let newLine: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case lineCode = "line_code"
        case oldLine = "old_line"
        case newLine = "new_line"
    }
}
