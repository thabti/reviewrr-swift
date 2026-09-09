import Foundation

/// Persists local, unsent review state (drafts, summary, event, viewed
/// files) to disk so it survives restarts. Keyed by PR so switching
/// between PRs does not lose work in progress.
enum DraftStore {
    private static func directory(host: ForgeHost = .dotCom) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Reviewrr/drafts", isDirectory: true)
        if !host.isDotCom {
            let key = Data(host.apiBaseURL.absoluteString.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
            dir = dir.appendingPathComponent(key, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for reference: PRReference, host: ForgeHost = .dotCom) -> URL {
        directory(host: host).appendingPathComponent("\(reference.owner)_\(reference.repo)_\(reference.number).json")
    }

    static func load(for reference: PRReference, host: ForgeHost = .dotCom) -> ReviewDraft {
        let url = fileURL(for: reference, host: host)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(ReviewDraft.self, from: data)
        else {
            return ReviewDraft()
        }
        return decoded
    }

    static func save(_ draft: ReviewDraft, for reference: PRReference) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? data.write(to: fileURL(for: reference), options: .atomic)
    }

    static func saveChecked(_ draft: ReviewDraft, for reference: PRReference, host: ForgeHost) throws {
        let data = try JSONEncoder().encode(draft)
        try data.write(to: fileURL(for: reference, host: host), options: .atomic)
    }

    static func savedReviews(host: ForgeHost = .dotCom) -> [DashboardReviewDraft] {
        savedReviews(in: directory(host: host))
    }

    static func savedReviews(in directory: URL) -> [DashboardReviewDraft] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls.compactMap { url -> DashboardReviewDraft? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  var draft = try? JSONDecoder().decode(ReviewDraft.self, from: data),
                  draft.isSubmitted != true, draft.isDiscarded != true else { return nil }
            // Older files encode the PR identity in their filename only.
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_", omittingEmptySubsequences: false)
            let legacyKey = parts.count >= 3
                ? "\(parts[0])/\(parts.dropFirst().dropLast().joined(separator: "_"))#\(parts.last!)" : ""
            guard let reference = PRReference.parse(draft.referenceKey ?? legacyKey) else { return nil }
            guard draft.referenceKey != nil || !draft.comments.isEmpty || !draft.summary.isEmpty
                    || !draft.viewedFiles.isEmpty || draft.event != .comment else { return nil }
            if draft.savedAt == nil {
                draft.savedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            return DashboardReviewDraft(reference: reference, draft: draft)
        }.sorted { ($0.draft.savedAt ?? .distantPast) > ($1.draft.savedAt ?? .distantPast) }
    }

    /// An empty marker prevents legacy in-review status from recreating a cleared draft.
    static func discardChecked(for reference: PRReference, host: ForgeHost) throws {
        var cleared = ReviewDraft()
        cleared.isDiscarded = true
        try saveChecked(cleared, for: reference, host: host)
    }

    static func clear(for reference: PRReference) {
        try? FileManager.default.removeItem(at: fileURL(for: reference))
    }
}
