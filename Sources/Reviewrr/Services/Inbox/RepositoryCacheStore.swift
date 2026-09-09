import Foundation

/// Caches the repository list the picker browses.
///
/// The set of repositories an engineer can reach changes on the order of
/// weeks, but fetching it costs several paginated round trips. Caching it to
/// disk turns the second and every later open of the sheet into an instant
/// render, with a refresh happening behind the already-visible list.
enum RepositoryCacheStore {
    /// After this, the cache is still shown immediately but refreshed in the
    /// background. It is never treated as unusable — a day-old repository
    /// list is a far better first paint than a spinner.
    static let staleAfter: TimeInterval = 60 * 60 * 6

    struct Snapshot: Codable, Equatable {
        var repositories: [AccessibleRepository]
        var organizations: [AccessibleRepository.Owner]
        var fetchedAt: Date

        func isStale(now: Date = Date()) -> Bool {
            now.timeIntervalSince(fetchedAt) > RepositoryCacheStore.staleAfter
        }
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Reviewrr", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Keyed by host so switching to a GitHub Enterprise appliance cannot
    /// serve it github.com's repositories. The key is hashed because a host
    /// URL is not a safe file name.
    private static func fileURL(host: ForgeHost) -> URL {
        // Stable across launches, unlike `hashValue` — see the same fix in
        // `InboxCacheStore`.
        let key = host.identityKey
        return directory().appendingPathComponent("repositories-\(key).json")
    }

    static func load(host: ForgeHost) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(host: host)) else { return nil }
        // A snapshot written by an older build may no longer decode. That is
        // a cache miss, not an error worth surfacing.
        return try? GitHubAPI.decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot, host: ForgeHost) {
        guard let data = try? GitHubAPI.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL(host: host), options: .atomic)
    }

    static func clear(host: ForgeHost) {
        try? FileManager.default.removeItem(at: fileURL(host: host))
    }
}
