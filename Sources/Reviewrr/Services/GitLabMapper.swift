import Foundation

// MARK: - Wire types
//
// GitLab's REST v4 payloads, decoded exactly as sent and then translated
// into the app's domain models by `GitLabMapper`. Kept separate from those
// models on purpose: the app's types are GitHub-shaped because GitHub came
// first, and burying GitLab's field names inside them would leave two
// forges' vocabularies tangled in the types every view reads.

struct GLUser: Decodable, Sendable {
    let id: Int
    let username: String
    let name: String?
    let avatarUrl: String?
    let webUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarUrl = "avatar_url"
        case webUrl = "web_url"
    }
}

/// The three SHAs a GitLab diff comment must be anchored to. Absent on
/// older instances and on a merge request with no diff yet, which is why
/// every field is optional and posting a comment checks for them.
struct GLDiffRefs: Decodable, Sendable {
    let baseSha: String?
    let headSha: String?
    let startSha: String?

    enum CodingKeys: String, CodingKey {
        case baseSha = "base_sha"
        case headSha = "head_sha"
        case startSha = "start_sha"
    }
}

/// A label, which GitLab returns as a bare string by default and as an
/// object when asked with `with_labels_details=true`. Both shapes decode
/// here so a response from either request — or from an instance too old to
/// support the parameter — still yields labels rather than failing.
struct GLLabel: Decodable, Sendable {
    let name: String
    let color: String?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name
            self.color = nil
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        name = try keyed.decode(String.self, forKey: .name)
        color = try keyed.decodeIfPresent(String.self, forKey: .color)
    }

    enum CodingKeys: String, CodingKey { case name, color }
}

struct GLMergeRequest: Decodable, Sendable {
    let id: Int
    let iid: Int
    let title: String
    let description: String?
    let state: String
    let draft: Bool?
    /// What `draft` was called before GitLab 14.0. Read as a fallback so a
    /// self-managed instance a few versions behind still reports drafts.
    let workInProgress: Bool?
    let author: GLUser
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let closedAt: Date?
    let webUrl: String
    let labels: [GLLabel]?
    let sha: String?
    let diffRefs: GLDiffRefs?
    let sourceBranch: String
    let targetBranch: String
    /// A *string* — and sometimes "3+" rather than "3", because GitLab caps
    /// the count it is willing to compute on a very large merge request.
    let changesCount: String?
    let userNotesCount: Int?
    let detailedMergeStatus: String?
    let mergeStatus: String?
    let hasConflicts: Bool?
    let reviewers: [GLUser]?
    let assignees: [GLUser]?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, description, state, draft, author, labels, sha, reviewers, assignees
        case workInProgress = "work_in_progress"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case closedAt = "closed_at"
        case webUrl = "web_url"
        case diffRefs = "diff_refs"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case changesCount = "changes_count"
        case userNotesCount = "user_notes_count"
        case detailedMergeStatus = "detailed_merge_status"
        case mergeStatus = "merge_status"
        case hasConflicts = "has_conflicts"
    }

    var isDraft: Bool { draft ?? workInProgress ?? false }
    var isMerged: Bool { state == "merged" }
}

/// One changed file. GitLab sends the unified diff as text with no per-file
/// line counts at all — unlike GitHub, which sends `additions`/`deletions`
/// — so those are counted from the patch in `GitLabMapper.file(from:)`.
struct GLDiff: Decodable, Sendable {
    let oldPath: String
    let newPath: String
    let newFile: Bool
    let renamedFile: Bool
    let deletedFile: Bool
    /// Absent for a binary file, and for a diff GitLab declined to render
    /// because it is too large — the same two cases GitHub reports by
    /// omitting `patch`.
    let diff: String?
    let generatedFile: Bool?

    enum CodingKeys: String, CodingKey {
        case diff
        case oldPath = "old_path"
        case newPath = "new_path"
        case newFile = "new_file"
        case renamedFile = "renamed_file"
        case deletedFile = "deleted_file"
        case generatedFile = "generated_file"
    }
}

/// Where a diff note is anchored. `position_type` is "text" for a line
/// comment, "image"/"file" for the others Reviewrr does not place.
struct GLPosition: Decodable, Sendable {
    let baseSha: String?
    let startSha: String?
    let headSha: String?
    let oldPath: String?
    let newPath: String?
    let positionType: String?
    let oldLine: Int?
    let newLine: Int?

    enum CodingKeys: String, CodingKey {
        case baseSha = "base_sha"
        case startSha = "start_sha"
        case headSha = "head_sha"
        case oldPath = "old_path"
        case newPath = "new_path"
        case positionType = "position_type"
        case oldLine = "old_line"
        case newLine = "new_line"
    }
}

struct GLNote: Decodable, Sendable {
    let id: Int
    let body: String
    let author: GLUser
    let createdAt: Date
    let updatedAt: Date?
    /// GitLab's own activity entries — "changed the description", "assigned
    /// to @someone". Never shown as review comments: they are timeline
    /// noise, and rendering them as somebody's remark misrepresents them.
    let system: Bool
    let resolvable: Bool?
    let resolved: Bool?
    let position: GLPosition?

    enum CodingKeys: String, CodingKey {
        case id, body, author, system, resolvable, resolved, position
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// GitLab's unit of conversation. Its `id` is a hex string, not an integer —
/// the one identifier in GitLab's model that has no place in the app's
/// integer-keyed types, so `GitLabThreadIndex` keeps it alongside.
struct GLDiscussion: Decodable, Sendable {
    let id: String
    let individualNote: Bool
    let notes: [GLNote]

    enum CodingKeys: String, CodingKey {
        case id, notes
        case individualNote = "individual_note"
    }
}

struct GLApprovals: Decodable, Sendable {
    struct Approver: Decodable, Sendable {
        let user: GLUser
    }
    let approvalsRequired: Int?
    let approvalsLeft: Int?
    let approvedBy: [Approver]?
    let approved: Bool?

    enum CodingKeys: String, CodingKey {
        case approved
        case approvalsRequired = "approvals_required"
        case approvalsLeft = "approvals_left"
        case approvedBy = "approved_by"
    }
}

struct GLPipeline: Decodable, Sendable {
    let id: Int
    let sha: String?
    let ref: String?
    let status: String
    let webUrl: String?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, sha, ref, status
        case webUrl = "web_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GLJob: Decodable, Sendable {
    let id: Int
    let name: String
    let stage: String?
    let status: String
    let startedAt: Date?
    let finishedAt: Date?
    let webUrl: String?
    let allowFailure: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, stage, status
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case webUrl = "web_url"
        case allowFailure = "allow_failure"
    }
}

/// An unpublished review comment held server-side by GitLab. This is the
/// endpoint that makes GitLab's model fit Reviewrr's: comments are staged
/// and then published together, exactly like a GitHub pending review.
struct GLDraftNote: Decodable, Sendable {
    let id: Int
    let note: String
    let position: GLPosition?
}

// MARK: - Thread index

/// The GitLab identifiers the app's integer-keyed models cannot carry.
///
/// A `ReviewThread` is keyed by its root comment's integer id, because that
/// is what GitHub gives. Replying to or resolving a GitLab thread needs the
/// *discussion's* hex id, so it is kept here, keyed by the root note id the
/// rest of the app already holds. Rebuilt on every fetch rather than cached
/// across them: a stale discussion id would resolve the wrong thread.
struct GitLabThreadIndex: Equatable, Sendable {
    private var discussionIDsByRootNote: [Int: String] = [:]

    init(discussions: [GLDiscussion] = []) {
        for discussion in discussions {
            guard let root = discussion.notes.first(where: { !$0.system }) else { continue }
            discussionIDsByRootNote[root.id] = discussion.id
        }
    }

    func discussionID(forRootNote id: Int) -> String? { discussionIDsByRootNote[id] }
    var isEmpty: Bool { discussionIDsByRootNote.isEmpty }
}

// MARK: - Mapper

/// Translates GitLab's payloads into the app's domain models.
///
/// Every lossy or invented value is called out where it happens. The two
/// that matter: GitLab reports no line counts, so they are counted from the
/// patch; and GitLab has no equivalent of a "changes requested" review, so
/// approvals map to `Review` and nothing pretends to be a rejection.
enum GitLabMapper {
    // MARK: Users

    static func user(_ user: GLUser) -> GitHubUser {
        // `username` rather than `name`: it is the handle a reviewer types
        // and @-mentions, and the display name is not unique.
        GitHubUser(login: user.username, avatarUrl: user.avatarUrl)
    }

    // MARK: Merge request

    /// `additions`, `deletions` and `changedFiles` come from `files` when
    /// the caller already has them, because GitLab's merge-request payload
    /// carries no line counts. With no files to count, `changes_count` still
    /// gives a file count — including its "3+" form, where GitLab has given
    /// up counting exactly and the digits are a floor, not a total.
    static func pullRequest(_ mr: GLMergeRequest, files: [PRFile]? = nil) -> PullRequest {
        let additions = files?.reduce(0) { $0 + $1.additions } ?? 0
        let deletions = files?.reduce(0) { $0 + $1.deletions } ?? 0
        let changedFiles = files?.count ?? parseChangesCount(mr.changesCount) ?? 0

        return PullRequest(
            id: mr.id,
            number: mr.iid,
            title: mr.title,
            body: mr.description,
            state: mr.state == "opened" ? .open : .closed,
            draft: mr.isDraft,
            merged: mr.isMerged,
            mergeableState: mr.detailedMergeStatus ?? mr.mergeStatus,
            user: user(mr.author),
            head: PullRequest.Branch(ref: mr.sourceBranch, sha: mr.diffRefs?.headSha ?? mr.sha ?? ""),
            base: PullRequest.Branch(ref: mr.targetBranch, sha: mr.diffRefs?.baseSha ?? ""),
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            // GitLab does not report a commit count on the merge request;
            // it is a separate paginated endpoint, and nothing in the
            // workspace needs it badly enough to spend a request on.
            commits: 0,
            comments: mr.userNotesCount ?? 0,
            reviewComments: 0,
            createdAt: mr.createdAt,
            updatedAt: mr.updatedAt,
            htmlUrl: mr.webUrl,
            labels: (mr.labels ?? []).map(label),
            // GitLab expresses mergeability as a status string rather than a
            // boolean; `has_conflicts` is the closest true equivalent.
            mergeable: mr.hasConflicts.map { !$0 },
            mergedAt: mr.mergedAt,
            closedAt: mr.closedAt,
            requestedReviewers: mr.reviewers?.map(user),
            assignees: mr.assignees?.map(user)
        )
    }

    /// "3" → 3, "3+" → 3, nil/garbage → nil.
    static func parseChangesCount(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// GitLab labels have no numeric id, and the app's `GitHubLabel` needs
    /// one for `Identifiable`. Derived from the name with FNV-1a rather than
    /// `hashValue`, which Swift seeds per process — a per-launch id would
    /// make SwiftUI treat every label as new on every launch.
    static func label(_ label: GLLabel) -> GitHubLabel {
        GitHubLabel(
            id: Int(truncatingIfNeeded: fnv1a(label.name)),
            name: label.name,
            color: label.color?.replacingOccurrences(of: "#", with: "") ?? "9e9e9e"
        )
    }

    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        // Kept positive: a negative id is legal but reads as a bug in logs.
        return hash & 0x7fff_ffff_ffff_ffff
    }

    // MARK: Files

    static func file(from diff: GLDiff) -> PRFile {
        let counts = lineCounts(in: diff.diff)
        return PRFile(
            filename: diff.newPath.isEmpty ? diff.oldPath : diff.newPath,
            previousFilename: diff.renamedFile ? diff.oldPath : nil,
            status: status(for: diff),
            additions: counts.additions,
            deletions: counts.deletions,
            changes: counts.additions + counts.deletions,
            patch: diff.diff
        )
    }

    static func status(for diff: GLDiff) -> PRFileStatus {
        if diff.newFile { return .added }
        if diff.deletedFile { return .removed }
        if diff.renamedFile { return .renamed }
        return .modified
    }

    /// Counts added and removed lines in a unified diff.
    ///
    /// `+++`/`---` file headers are skipped: they begin with the same
    /// characters as content lines and would otherwise inflate every file by
    /// one addition and one deletion. GitLab normally omits them from the
    /// `diff` field, but includes them for a renamed file, so this cannot
    /// assume they are absent.
    static func lineCounts(in patch: String?) -> (additions: Int, deletions: Int) {
        guard let patch else { return (0, 0) }
        var additions = 0
        var deletions = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    // MARK: Comments and threads

    /// A note anchored to a diff line becomes a `ReviewComment`.
    ///
    /// `side` follows which line number GitLab filled in: `new_line` for the
    /// right-hand side, `old_line` alone for the left. A note whose position
    /// has neither is *outdated* — the line it referred to is no longer in
    /// the diff — which the app already represents as `line == nil`.
    static func reviewComment(_ note: GLNote, mergeRequestURL: String, inReplyTo: Int? = nil) -> ReviewComment? {
        guard let position = note.position, position.positionType ?? "text" == "text" else { return nil }
        let isRight = position.newLine != nil
        return ReviewComment(
            id: note.id,
            user: user(note.author),
            body: note.body,
            path: (isRight ? position.newPath : position.oldPath) ?? position.newPath ?? position.oldPath ?? "",
            line: position.newLine ?? position.oldLine,
            originalLine: position.oldLine,
            side: isRight ? .right : .left,
            // GitLab models replies through the discussion rather than a
            // parent pointer, so the discussion's root note id is filled in
            // here for every note after the first. That is what lets the
            // app's existing `groupedIntoThreads()` rebuild GitLab's
            // discussions unchanged, instead of the workspace needing to
            // know that two forges group conversation differently.
            inReplyToId: inReplyTo,
            createdAt: note.createdAt,
            htmlUrl: "\(mergeRequestURL)#note_\(note.id)",
            startLine: nil,
            diffHunk: nil,
            updatedAt: note.updatedAt,
            pullRequestReviewId: nil
        )
    }

    /// Every diff-anchored note across every discussion, flattened, with
    /// each discussion's replies pointing at its root note.
    ///
    /// Shaped this way so it can go straight into the same
    /// `groupedIntoThreads()` the GitHub path uses — the workspace then
    /// holds one kind of thread regardless of which forge produced it.
    static func reviewComments(from discussions: [GLDiscussion], mergeRequestURL: String) -> [ReviewComment] {
        discussions.flatMap { discussion -> [ReviewComment] in
            let visible = discussion.notes.filter { !$0.system }
            guard let root = visible.first, root.position != nil else { return [] }
            guard let rootComment = reviewComment(root, mergeRequestURL: mergeRequestURL) else { return [] }
            let replies = visible.dropFirst().compactMap {
                reviewComment($0, mergeRequestURL: mergeRequestURL, inReplyTo: rootComment.id)
            }
            return [rootComment] + replies
        }
    }

    /// Groups GitLab discussions into the app's threads.
    ///
    /// Uses GitLab's own grouping rather than reconstructing it: a
    /// discussion *is* a thread, so its notes are its comments in order.
    /// Only discussions whose root note has a diff position become review
    /// threads; the rest are merge-request-level conversation.
    static func threads(from discussions: [GLDiscussion], mergeRequestURL: String) -> [ReviewThread] {
        discussions.compactMap { discussion in
            let visible = discussion.notes.filter { !$0.system }
            guard let root = visible.first, root.position != nil else { return nil }
            let comments = visible.compactMap { reviewComment($0, mergeRequestURL: mergeRequestURL) }
            guard let rootComment = comments.first else { return nil }
            return ReviewThread(
                rootId: rootComment.id,
                path: rootComment.path,
                line: rootComment.line,
                side: rootComment.side,
                isOutdated: rootComment.line == nil,
                comments: comments
            )
        }
    }

    /// Resolution state per discussion, in the shape `ThreadsClient.merge`
    /// already consumes.
    ///
    /// This is the join that let GitLab reuse the whole conversation panel
    /// unchanged. GitHub keeps resolution in GraphQL and REST keeps comment
    /// bodies, so the app already had a type for "resolution metadata,
    /// matched to threads by comment id" — and GitLab's discussions carry
    /// exactly that, in `resolved` on each note. The discussion's hex id
    /// goes in `nodeId`, where GitHub puts its GraphQL node id: both are
    /// opaque handles the resolve call passes straight back.
    static func threadStates(from discussions: [GLDiscussion]) -> [ThreadsClient.ThreadState] {
        discussions.compactMap { discussion in
            let visible = discussion.notes.filter { !$0.system }
            guard let root = visible.first, root.position != nil else { return nil }
            return ThreadsClient.ThreadState(
                nodeId: discussion.id,
                isResolved: root.resolved ?? false,
                // GitLab reports an outdated note by dropping the line from
                // its position rather than with a flag, so this is derived
                // the same way the comment mapping derives it.
                isOutdated: root.position?.newLine == nil && root.position?.oldLine == nil,
                // GitLab has no per-thread collapse state; a resolved
                // discussion is what its UI collapses.
                isCollapsed: root.resolved ?? false,
                // GitLab's payload does not say *who* resolved a
                // discussion, only that it is resolved. Left nil rather
                // than attributed to the reader.
                resolvedByLogin: nil,
                commentDatabaseIds: visible.map(\.id)
            )
        }
    }

    /// Merge-request-level notes — GitLab's equivalent of a GitHub issue
    /// comment. System notes are dropped, and so is anything with a diff
    /// position, which belongs to a review thread instead.
    static func issueComments(from discussions: [GLDiscussion], mergeRequestURL: String) -> [IssueComment] {
        discussions
            .flatMap(\.notes)
            .filter { !$0.system && $0.position == nil }
            .map { note in
                IssueComment(
                    id: note.id,
                    user: user(note.author),
                    body: note.body,
                    createdAt: note.createdAt,
                    htmlUrl: "\(mergeRequestURL)#note_\(note.id)"
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Approvals become `Review` values in the `.approved` state.
    ///
    /// Nothing maps to `.changesRequested`: GitLab has no such object. An
    /// unresolved blocking discussion is the nearest thing, and it is
    /// already visible as an unresolved thread — inventing a rejection
    /// review from it would attribute a verdict nobody gave.
    ///
    /// `submittedAt` is nil because GitLab's approvals payload carries no
    /// timestamp per approver. Left nil rather than filled with "now",
    /// which would redate every approval on each refresh.
    static func reviews(from approvals: GLApprovals) -> [Review] {
        (approvals.approvedBy ?? []).map { approver in
            Review(
                id: approver.user.id,
                user: user(approver.user),
                body: nil,
                state: .approved,
                submittedAt: nil,
                commitId: nil,
                htmlUrl: approver.user.webUrl
            )
        }
    }

    // MARK: CI

    /// A pipeline job becomes a check run. Jobs rather than pipelines are
    /// the useful unit: a reviewer wants to see *which* job failed, which is
    /// what the GitHub Checks list shows.
    static func checkRun(from job: GLJob, pipelineID: Int) -> CheckRun {
        let status = checkStatus(for: job.status)
        return CheckRun(
            // Namespaced by pipeline so a job id from a re-run pipeline can
            // never collide with the original's.
            id: "gitlab-job-\(pipelineID)-\(job.id)",
            name: job.name,
            appName: job.stage,
            status: status,
            conclusion: status == .completed ? checkConclusion(for: job.status, allowFailure: job.allowFailure ?? false) : nil,
            startedAt: job.startedAt,
            completedAt: job.finishedAt,
            detailsURL: job.webUrl.flatMap(URL.init(string:)),
            outputTitle: nil,
            outputSummary: nil,
            source: .checkRun
        )
    }

    /// A pipeline with no jobs readable — a token without `read_api` on
    /// jobs, or a pipeline still being created — still reports as one run,
    /// so CI does not silently look absent.
    static func checkRun(from pipeline: GLPipeline) -> CheckRun {
        let status = checkStatus(for: pipeline.status)
        return CheckRun(
            id: "gitlab-pipeline-\(pipeline.id)",
            name: "Pipeline #\(pipeline.id)",
            appName: "GitLab CI",
            status: status,
            conclusion: status == .completed ? checkConclusion(for: pipeline.status, allowFailure: false) : nil,
            startedAt: pipeline.createdAt,
            completedAt: status == .completed ? pipeline.updatedAt : nil,
            detailsURL: pipeline.webUrl.flatMap(URL.init(string:)),
            outputTitle: nil,
            outputSummary: nil,
            source: .checkRun
        )
    }

    /// GitLab's status vocabulary is richer than the app's three-state
    /// lifecycle, and every value maps onto it. `manual` and `scheduled`
    /// deserve a word: a manual job has not run and is waiting for a person,
    /// so it reports as completed/`actionRequired` rather than queued —
    /// otherwise a pipeline that is finished except for a manual deploy step
    /// would read as still running forever.
    static func checkStatus(for raw: String) -> CheckStatus {
        switch raw {
        case "created", "waiting_for_resource", "preparing", "pending", "scheduled":
            return .queued
        case "running":
            return .inProgress
        default:
            return .completed
        }
    }

    static func checkConclusion(for raw: String, allowFailure: Bool) -> CheckConclusion? {
        switch raw {
        case "success":
            return .success
        case "failed":
            // A job marked `allow_failure` is advisory; reporting it as a
            // failure would make a green pipeline look broken.
            return allowFailure ? .neutral : .failure
        case "canceled", "canceling":
            return .cancelled
        case "skipped":
            return .skipped
        case "manual":
            return .actionRequired
        default:
            return nil
        }
    }
}
