import Foundation

/// Persists the watched-project list as JSON under Application Support,
/// mirroring `DraftStore`'s directory pattern. Atomic writes plus
/// `WatchedProject`'s own field-by-field tolerant decoding mean a
/// partially-understood future build (or a build one version behind) never
/// discards the whole watchlist over one field.
enum WatchlistStore {
    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Reviewrr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchlist.json")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// A decode failure (corrupted file, unreadable format) yields an empty
    /// watchlist rather than crashing — the reviewer can re-add projects,
    /// which is recoverable, unlike a launch-time trap.
    static func loadProjects() -> [WatchedProject] {
        guard
            let data = try? Data(contentsOf: fileURL()),
            let decoded = try? decoder.decode([WatchedProject].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// Writes the watchlist, or throws saying why it could not.
    ///
    /// The silent twin below swallowed both the encode and the write, and
    /// `DashboardModel.persistProjects` returned `Void`, so a full volume or
    /// a folder that had lost write permission looked identical to a
    /// successful save: the reviewer added projects, muted some, and lost
    /// every one of them at the next launch with nothing on screen to
    /// explain it. Mirrors `DraftStore.saveChecked` — new callers use this
    /// one and surface the failure.
    static func saveProjectsChecked(_ projects: [WatchedProject]) throws {
        let data = try encoder.encode(projects)
        try data.write(to: fileURL(), options: .atomic)
    }

    static func saveProjects(_ projects: [WatchedProject]) {
        try? saveProjectsChecked(projects)
    }
}
