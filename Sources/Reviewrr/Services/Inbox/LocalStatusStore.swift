import Foundation

/// Persists local per-PR review status (`LocalPRStatus`, keyed by
/// "owner/repo#number") alongside the watchlist, in its own file under the
/// same Application Support directory. Kept separate from `watchlist.json`
/// because the two change at very different rates: status updates on
/// nearly every dashboard interaction, while the watchlist only changes
/// when a project is added, removed, or muted.
enum LocalStatusStore {
    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Reviewrr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local-pr-status.json")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func load() -> [String: LocalPRStatus] {
        guard
            let data = try? Data(contentsOf: fileURL()),
            let decoded = try? decoder.decode([String: LocalPRStatus].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    /// Writes the read/reviewed/ignored map, or throws saying why it could
    /// not.
    ///
    /// The silent twin below swallowed both the encode and the write, so an
    /// unwritable folder cost the reviewer every "reviewed" mark they made
    /// all session — silently, at the next launch. Mirrors
    /// `DraftStore.saveChecked`; new callers use this one and surface the
    /// failure.
    static func saveChecked(_ status: [String: LocalPRStatus]) throws {
        let data = try encoder.encode(status)
        try data.write(to: fileURL(), options: .atomic)
    }

    static func save(_ status: [String: LocalPRStatus]) {
        try? saveChecked(status)
    }
}
