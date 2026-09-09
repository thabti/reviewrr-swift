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

    static func save(_ status: [String: LocalPRStatus]) {
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: fileURL(), options: .atomic)
    }
}
