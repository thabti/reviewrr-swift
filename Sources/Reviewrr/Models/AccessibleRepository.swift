import Foundation

/// A repository the configured credential can actually see, as returned by
/// `GET /user/repos`.
///
/// Distinct from `WatchedProject`: this is a *candidate* the reviewer might
/// choose to watch, carrying the extra detail needed to choose well — which
/// organization owns it, whether it is private, archived, or a fork, and how
/// recently it changed.
struct AccessibleRepository: Identifiable, Equatable, Hashable, Codable, Sendable {
    /// The account that owns the repository. `type` separates a personal
    /// account from an organization, which is how the picker groups.
    struct Owner: Equatable, Hashable, Codable, Sendable {
        let login: String
        let type: String
        let avatarUrl: String?

        var isOrganization: Bool { type.lowercased() == "organization" }

        enum CodingKeys: String, CodingKey {
            case login, type
            case avatarUrl = "avatar_url"
        }
    }

    let id: Int
    let name: String
    let fullName: String
    let owner: Owner
    let isPrivate: Bool
    let isFork: Bool
    let isArchived: Bool
    let description: String?
    let updatedAt: Date?
    let pushedAt: Date?
    let openIssuesCount: Int?
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, description
        case fullName = "full_name"
        case isPrivate = "private"
        case isFork = "fork"
        case isArchived = "archived"
        case updatedAt = "updated_at"
        case pushedAt = "pushed_at"
        case openIssuesCount = "open_issues_count"
        case defaultBranch = "default_branch"
    }

    /// The most recent signal of activity. GitHub's `pushed_at` reflects code
    /// changes while `updated_at` also moves for metadata edits, so the
    /// larger of the two is the honest "last touched".
    var lastActivityAt: Date? {
        switch (pushedAt, updatedAt) {
        case let (pushed?, updated?): return max(pushed, updated)
        case let (pushed?, nil): return pushed
        case let (nil, updated?): return updated
        default: return nil
        }
    }

    func watchKey(host: ForgeHost) -> String {
        WatchedProject.makeKey(host: host, owner: owner.login, repo: name)
    }

    /// Matches the reviewer's search text against the parts of a repository
    /// they would actually type: its name, its owner, the combined
    /// `owner/name`, and its description.
    func matches(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if name.range(of: needle, options: .caseInsensitive) != nil { return true }
        if owner.login.range(of: needle, options: .caseInsensitive) != nil { return true }
        if fullName.range(of: needle, options: .caseInsensitive) != nil { return true }
        if let description, description.range(of: needle, options: .caseInsensitive) != nil { return true }
        return false
    }
}

/// One organization (or the reviewer's personal account) plus the
/// repositories under it that the credential can see.
struct RepositoryOwnerGroup: Identifiable, Equatable {
    let owner: AccessibleRepository.Owner
    let repositories: [AccessibleRepository]

    var id: String { owner.login }
    var isPersonal: Bool { !owner.isOrganization }
}
