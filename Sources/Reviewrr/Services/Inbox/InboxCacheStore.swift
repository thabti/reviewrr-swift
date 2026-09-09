import Foundation

/// Persists the inbox rows between launches.
///
/// Without this, every launch showed an empty inbox until several paginated
/// syncs finished — the reviewer's first impression of the app was a
/// spinner, even though the answer from ten minutes ago was almost entirely
/// correct. Rows render immediately from disk and polling corrects them.
///
/// This is a cache, not a store of record: GitHub remains the truth, and a
/// missing or undecodable file simply means the first sync has to finish
/// before anything appears.
enum InboxCacheStore {
    /// Rows older than this are still shown, but the freshness indicator
    /// says so and a refresh is already in flight.
    static let staleAfter: TimeInterval = 60 * 15

    struct Snapshot: Codable, Equatable {
        var rows: [InboxPR]
        var fetchedAt: Date

        func isStale(now: Date = Date()) -> Bool {
            now.timeIntervalSince(fetchedAt) > InboxCacheStore.staleAfter
        }
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Reviewrr", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Keyed by host, so an Enterprise appliance never renders github.com's
    /// pull requests.
    private static func fileURL(host: ForgeHost) -> URL {
        // `ForgeHost.identityKey`, not `hashValue`: Swift seeds String's
        // hash per process, so this name used to change on every launch —
        // the cache never hit once, and a file leaked per run.
        let key = host.identityKey
        return directory().appendingPathComponent("inbox-\(key).json")
    }

    static func load(host: ForgeHost) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(host: host)) else { return nil }
        return try? GitHubAPI.decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ rows: [InboxPR], host: ForgeHost) {
        // Bounded: the dashboard shows a few hundred rows at most, and an
        // unbounded cache would grow with every project ever watched.
        let snapshot = Snapshot(rows: Array(rows.prefix(1_000)), fetchedAt: Date())
        guard let data = try? GitHubAPI.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL(host: host), options: .atomic)
    }

    static func clear(host: ForgeHost) {
        try? FileManager.default.removeItem(at: fileURL(host: host))
    }
}
