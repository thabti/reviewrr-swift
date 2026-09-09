import Foundation

struct PRReference: Equatable, Hashable {
    let owner: String
    let repo: String
    let number: Int

    var key: String { "\(owner)/\(repo)#\(number)" }

    /// Accepts a full PR URL ("https://github.com/owner/repo/pull/123"),
    /// with an optional trailing slash or a "/files" suffix, or GitHub's
    /// raw-diff URLs ("…/pull/123.diff" / "…/pull/123.patch"), or the
    /// shorthand "owner/repo#123".
    static func parse(_ input: String) -> PRReference? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, host.contains("github.com") {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 4, parts[2] == "pull" else { return nil }
            var numberComponent = parts[3]
            if numberComponent.hasSuffix(".diff") {
                numberComponent.removeLast(".diff".count)
            } else if numberComponent.hasSuffix(".patch") {
                numberComponent.removeLast(".patch".count)
            }
            guard let number = Int(numberComponent) else { return nil }
            return PRReference(owner: parts[0], repo: parts[1], number: number)
        }

        guard let hashIndex = trimmed.firstIndex(of: "#") else { return nil }
        let ownerRepo = trimmed[trimmed.startIndex..<hashIndex]
        let numberPart = trimmed[trimmed.index(after: hashIndex)...]
        guard let number = Int(numberPart) else { return nil }
        let slashParts = ownerRepo.split(separator: "/")
        guard slashParts.count == 2 else { return nil }
        return PRReference(owner: String(slashParts[0]), repo: String(slashParts[1]), number: number)
    }
}

struct GitHubUser: Codable, Equatable, Hashable {
    let login: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarUrl = "avatar_url"
    }
}

struct GitHubLabel: Codable, Equatable, Hashable, Identifiable {
    let id: Int
    let name: String
    let color: String
}

enum PRState: String, Codable {
    case open, closed
}

struct PullRequest: Codable, Equatable, Identifiable {
    struct Branch: Codable, Equatable {
        let ref: String
        let sha: String
    }

    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: PRState
    let draft: Bool
    let merged: Bool
    let mergeableState: String?
    let user: GitHubUser
    let head: Branch
    let base: Branch
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commits: Int
    let comments: Int
    let reviewComments: Int
    let createdAt: Date
    let updatedAt: Date
    let htmlUrl: String
    let labels: [GitHubLabel]
    // Optional with defaults on purpose: GitHub omits several of these on
    // list endpoints (only the single-PR endpoint returns the full shape),
    // and defaults keep fixtures and tests constructible without them.
    var mergeable: Bool? = nil
    var mergedAt: Date? = nil
    var closedAt: Date? = nil
    var requestedReviewers: [GitHubUser]? = nil
    var assignees: [GitHubUser]? = nil

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, draft, merged, user, head, base, additions, deletions, commits, comments, labels, mergeable, assignees
        case mergeableState = "mergeable_state"
        case mergedAt = "merged_at"
        case closedAt = "closed_at"
        case requestedReviewers = "requested_reviewers"
        case changedFiles = "changed_files"
        case reviewComments = "review_comments"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlUrl = "html_url"
    }

    var headSha: String { head.sha }
    var headRef: String { head.ref }
    var baseRef: String { base.ref }
}

enum PRFileStatus: String, Codable, Sendable {
    case added, removed, modified, renamed, copied, changed, unchanged
}

struct PRFile: Codable, Equatable, Identifiable, Sendable {
    var id: String { filename }
    let filename: String
    let previousFilename: String?
    let status: PRFileStatus
    let additions: Int
    let deletions: Int
    let changes: Int
    let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, changes, patch
        case previousFilename = "previous_filename"
    }

    var isBinaryOrTooLarge: Bool { patch == nil }

    var displayName: String { (filename as NSString).lastPathComponent }
    var directory: String {
        let dir = (filename as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }
}
