import Foundation

/// A repository a reviewer follows across sessions: host + owner + repo,
/// plus the bookkeeping the dashboard needs for freshness, errors, and
/// per-project ordering. Persisted by `Services/Inbox/WatchlistStore`.
struct WatchedProject: Codable, Equatable, Identifiable {
    var host: ForgeHost
    var owner: String
    var repo: String
    var addedAt: Date
    var lastOpenedAt: Date?
    var lastSyncedAt: Date?
    /// The last sync failure, in the same user-facing wording `GitHubError`
    /// produces. Cleared on the next successful sync.
    var lastError: String?
    var isMuted: Bool = false
    /// How much of this project's activity is worth a notification, over and
    /// above the global rules.
    ///
    /// Separate from `isMuted`, which is the blunt instrument: a muted project
    /// contributes nothing at all — no counts, no feed, no alerts. This tunes
    /// a project the reviewer still wants to *see*, for the common case of one
    /// busy repository that should only speak up when it needs them.
    var notificationLevel: NotificationLevel = .inherit

    /// A project's own notification rule.
    enum NotificationLevel: String, CaseIterable, Codable, Identifiable, Equatable, Sendable {
        /// Whatever the global notification preferences say.
        case inherit
        /// Only when this reviewer's review is requested.
        case reviewRequestsOnly
        /// Never notify, but keep the project's rows, counts and activity.
        case silent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .inherit: return "Follow global settings"
            case .reviewRequestsOnly: return "Only when my review is requested"
            case .silent: return "Never notify"
            }
        }

        var systemImage: String {
            switch self {
            case .inherit: return "bell"
            case .reviewRequestsOnly: return "bell.badge"
            case .silent: return "bell.slash"
            }
        }
    }

    var id: String { key }
    var nameWithOwner: String { "\(owner)/\(repo)" }
    var webURL: URL { host.webBaseURL.appendingPathComponent(owner).appendingPathComponent(repo) }

    /// GitHub owner/repo names are case-insensitive, so the key normalizes
    /// case to avoid watching "Acme/Web" and "acme/web" as two projects.
    static func makeKey(host: ForgeHost, owner: String, repo: String) -> String {
        "\(host.apiBaseURL.absoluteString)|\(owner.lowercased())/\(repo.lowercased())"
    }

    var key: String { Self.makeKey(host: host, owner: owner, repo: repo) }

    init(host: ForgeHost, owner: String, repo: String, addedAt: Date = Date()) {
        self.host = host
        self.owner = owner
        self.repo = repo
        self.addedAt = addedAt
    }

    // MARK: - Forward-compatible decoding
    //
    // Field-by-field with defaults, matching `AppSettings`'s pattern: a
    // watchlist file written by a newer build must never become entirely
    // unreadable because of one field an older build doesn't recognize yet,
    // and an old file must never lose a project because of one missing key.
    enum CodingKeys: String, CodingKey {
        case host, owner, repo, addedAt, lastOpenedAt, lastSyncedAt, lastError, isMuted
        case notificationLevel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(ForgeHost.self, forKey: .host)
        owner = try container.decode(String.self, forKey: .owner)
        repo = try container.decode(String.self, forKey: .repo)
        addedAt = ((try? container.decodeIfPresent(Date.self, forKey: .addedAt)) ?? nil) ?? Date()
        lastOpenedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)) ?? nil
        lastSyncedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)) ?? nil
        lastError = (try? container.decodeIfPresent(String.self, forKey: .lastError)) ?? nil
        isMuted = ((try? container.decodeIfPresent(Bool.self, forKey: .isMuted)) ?? nil) ?? false
        notificationLevel = ((try? container.decodeIfPresent(NotificationLevel.self, forKey: .notificationLevel)) ?? nil) ?? .inherit
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(owner, forKey: .owner)
        try container.encode(repo, forKey: .repo)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(notificationLevel, forKey: .notificationLevel)
    }

    /// Accepts "owner/repo" (optionally with a "#123" PR suffix), a bare
    /// repository URL, or any PR URL, and extracts the owner/repo pair to
    /// watch regardless of which shape was pasted.
    static func parseOwnerRepo(_ input: String) -> (owner: String, repo: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"), let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            let owner = parts[0]
            guard !owner.isEmpty, !repo.isEmpty else { return nil }
            return (owner, repo)
        }

        var remainder = Substring(trimmed)
        if let hashIndex = remainder.firstIndex(of: "#") { remainder = remainder[remainder.startIndex..<hashIndex] }
        let slashParts = remainder.split(separator: "/")
        guard slashParts.count == 2 else { return nil }
        var repo = String(slashParts[1])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let owner = String(slashParts[0])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo)
    }
}
