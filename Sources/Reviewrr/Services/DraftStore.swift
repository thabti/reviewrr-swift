import CryptoKit
import Foundation

/// How each per-pull-request store names its file on disk, and the one-shot
/// migration off the name it used before.
///
/// Shared by the three stores that keep state per change — drafts, AI
/// analyses, AI sessions. It lives beside `DraftStore` because drafts are the
/// store whose failure costs a reviewer work that exists nowhere else.
///
/// The old name was `"\(owner)_\(repo)_\(number).json"`, which assumed
/// GitHub's exactly-two-level shape. Two things were wrong with it:
///
/// - On GitLab, `PRReference.owner` carries the whole group path (that is why
///   `GitLabAPI.encodedProjectPath` exists), so a merge request in
///   `platform/payments/api` produced a *name containing a slash*.
///   `appendingPathComponent` keeps it, so every write landed in a directory
///   nobody had created — `NSCocoaErrorDomain 4`, surfaced to the reviewer as
///   a disk-space problem — and a review staged on any nested group could
///   never be saved at all.
/// - It was ambiguous on either forge: `a_b/c` and `a/b_c` both flatten to
///   `a_b_c_1.json`, so two projects could share one draft file.
///
/// A digest of the host identity and the reference cannot contain a
/// separator, cannot collide between group depths, and cannot be ambiguous.
/// It is opaque to a human reading the folder; that is the trade, and the
/// identity is kept *inside* each draft as `referenceKey`, which is what the
/// dashboard shelf reads.
enum PRStoreFileName {
    /// Written into a directory once its legacy-named files have been
    /// renamed, so the migration is one directory listing per store per
    /// install rather than one per save.
    private static let markerName = "filenames-hashed.marker"

    static func json(for reference: PRReference, host: ForgeHost = .dotCom) -> String {
        let digest = SHA256.hash(data: Data("\(host.identityKey)|\(reference.key)".utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(32)).json"
    }

    /// Depth-tolerant `owner/repo#number`.
    ///
    /// `PRReference.parse` requires exactly one slash, which is right for
    /// GitHub and wrong for GitLab: the stored key of a merge request in
    /// `platform/payments/api` has three segments, so parsing it with the
    /// stricter rule dropped every nested-group draft off the dashboard shelf
    /// — and, worse, would have left it unmigratable here. The last segment
    /// is the project; everything before it is the group path.
    static func reference(key: String) -> PRReference? {
        guard let hash = key.lastIndex(of: "#") else { return nil }
        guard let number = Int(key[key.index(after: hash)...]) else { return nil }
        let path = key[key.startIndex..<hash].split(separator: "/")
        guard path.count >= 2 else { return nil }
        return PRReference(
            owner: path.dropLast().joined(separator: "/"), repo: String(path[path.count - 1]), number: number
        )
    }

    /// The identity a pre-migration file carried in its name alone:
    /// `owner_repo_number.json`. The owner is the first segment (no forge
    /// allows an underscore in an account or group name) and the number the
    /// last; whatever is between is the repository, which may contain them.
    static func legacyReference(fileName: String) -> PRReference? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3, let number = Int(parts[parts.count - 1]) else { return nil }
        let repo = parts.dropFirst().dropLast().joined(separator: "_")
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return PRReference(owner: String(parts[0]), repo: repo, number: number)
    }

    /// Moves a file out of the way instead of deleting it, and reports where
    /// it went. Both callers are cases where the app must not *use* a file and
    /// must not destroy it either: one it could not decode, and one a newer
    /// save has superseded.
    @discardableResult
    static func moveAside(_ url: URL, reason: String, now: Date = Date()) -> URL? {
        let manager = FileManager.default
        // Seconds since the epoch rather than a formatted date: a colon in a
        // filename reads as a path separator to parts of macOS.
        var destination = url.appendingPathExtension("\(reason)-\(Int(now.timeIntervalSince1970))")
        if manager.fileExists(atPath: destination.path) {
            destination = url.appendingPathExtension(
                "\(reason)-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            )
        }
        do {
            try manager.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Renames every legacy-named file in `directory` to its hashed name,
    /// once. `identify` says which change a file belongs to; a store that
    /// records its own reference inside the file should prefer that over the
    /// name, because the name is the thing that was wrong.
    static func migrateLegacyNames(in directory: URL, host: ForgeHost, identify: (URL) -> PRReference?) {
        let manager = FileManager.default
        let marker = directory.appendingPathComponent(markerName)
        guard !manager.fileExists(atPath: marker.path) else { return }
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var failed = false
        for url in urls where url.pathExtension == "json" {
            guard legacyReference(fileName: url.lastPathComponent) != nil else { continue }
            // A file whose identity cannot be recovered is left alone: no
            // future load will look for it, and deleting a reviewer's file to
            // tidy the directory is not this function's business.
            guard let reference = identify(url) else { continue }
            let destination = directory.appendingPathComponent(json(for: reference, host: host))
            guard destination.lastPathComponent != url.lastPathComponent else { continue }
            if manager.fileExists(atPath: destination.path) {
                if moveAside(url, reason: "superseded") == nil { failed = true }
                continue
            }
            do {
                try manager.moveItem(at: url, to: destination)
            } catch {
                failed = true
            }
        }
        // Only stamp the directory when everything moved. A half-migrated
        // directory has to be retried on the next launch, or the drafts left
        // behind are ones nothing will ever look for again.
        if !failed { try? Data().write(to: marker) }
    }
}

/// What was on disk for a pull request.
///
/// A three-way answer rather than "a draft, possibly empty", because the
/// caller has to treat the third case differently: `AppModel` writes the
/// draft back shortly after loading it, and an unreadable file that decodes
/// as "empty" is a file about to be overwritten with nothing. Work that was
/// merely unreadable became erased, silently, about a second after the
/// reviewer opened the pull request.
enum DraftLoad: Equatable {
    /// Nothing has been staged on this pull request.
    case absent
    case decoded(ReviewDraft)
    /// The file exists and could not be read. It has been moved aside to
    /// `quarantinedAt` (`nil` if even that failed) so that nothing can
    /// overwrite it, and `reason` is the underlying failure, for the banner.
    case unreadable(quarantinedAt: URL?, reason: String)
}

/// Persists local, unsent review state (drafts, summary, event, viewed
/// files) to disk so it survives restarts. Keyed by PR so switching
/// between PRs does not lose work in progress.
enum DraftStore {
    /// One directory per host, named from `ForgeHost.identityKey` — the same
    /// digest the Keychain and the inbox cache use.
    ///
    /// It used to be a base64 of the API root with `/` swapped for `_`, which
    /// (a) differed from every other store, so the obvious future cleanup
    /// would have orphaned every Enterprise and GitLab draft, and (b) is
    /// case-sensitive, so two hosts differing only in case collided into one
    /// directory on a case-insensitive volume. `identityKey` is lowercase hex
    /// and cannot do either.
    ///
    /// GitHub.com keeps the top-level directory it has always had. Moving
    /// those files too would buy uniformity and risk the most common store in
    /// the app on a rename nobody needs.
    private static func directory(host: ForgeHost = .dotCom) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Reviewrr/drafts", isDirectory: true)
        if !host.isDotCom {
            let current = dir.appendingPathComponent(host.identityKey, isDirectory: true)
            let legacy = dir.appendingPathComponent(legacyHostDirectoryName(host: host), isDirectory: true)
            migrateHostDirectory(legacy: legacy, current: current)
            dir = current
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        PRStoreFileName.migrateLegacyNames(in: dir, host: host, identify: identify)
        return dir
    }

    /// The pre-`identityKey` directory name, kept only so the migration above
    /// can find what an earlier version wrote.
    private static func legacyHostDirectoryName(host: ForgeHost) -> String {
        Data(host.apiBaseURL.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func migrateHostDirectory(legacy: URL, current: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacy.path) else { return }
        // The whole-directory move is the case that actually happens, and it
        // is atomic.
        guard manager.fileExists(atPath: current.path) else {
            try? manager.moveItem(at: legacy, to: current)
            return
        }
        // Both exist only if an earlier rename failed part-way. Merge rather
        // than leave drafts in a directory nothing reads again, and never
        // over an existing file: the one already under the new name is the
        // newer of the two. The legacy directory is deliberately left in
        // place — removing a directory that still holds a draft is exactly
        // the failure this is here to avoid.
        let contents = (try? manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "json" {
            let destination = current.appendingPathComponent(url.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.moveItem(at: url, to: destination)
        }
    }

    private static func fileURL(for reference: PRReference, host: ForgeHost = .dotCom) -> URL {
        directory(host: host).appendingPathComponent(PRStoreFileName.json(for: reference, host: host))
    }

    /// Which change a stored file belongs to. The key inside the file wins:
    /// the filename is the part that was wrong for GitLab, and a nested group
    /// path cannot be recovered from it.
    private static func identify(_ url: URL) -> PRReference? {
        let draft = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ReviewDraft.self, from: $0) }
        if let key = draft?.referenceKey, let reference = PRStoreFileName.reference(key: key) {
            return reference
        }
        guard let reference = PRStoreFileName.legacyReference(fileName: url.lastPathComponent) else { return nil }
        // The name was the only record of which pull request this draft
        // belongs to, and the hashed name it is about to get says nothing.
        // Writing the key into the file first is what keeps the migration from
        // being a different kind of loss: `savedReviews` reads identity from
        // the file, so a draft renamed without this would still open, and
        // would silently disappear from the dashboard shelf.
        if var stamped = draft, stamped.referenceKey == nil {
            stamped.referenceKey = reference.key
            if let data = try? JSONEncoder().encode(stamped) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return reference
    }

    /// Reads the stored draft, distinguishing "nothing staged" from "there is
    /// something here and I could not read it".
    ///
    /// The unreadable file is renamed to `<name>.json.corrupt-<timestamp>`
    /// before returning, so the reviewer's own bytes are still on disk for
    /// them (or a support conversation) to recover, and the next save writes
    /// a fresh file instead of landing on top of it.
    static func read(for reference: PRReference, host: ForgeHost = .dotCom) -> DraftLoad {
        let url = fileURL(for: reference, host: host)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            let data = try Data(contentsOf: url)
            return .decoded(try JSONDecoder().decode(ReviewDraft.self, from: data))
        } catch {
            return .unreadable(
                quarantinedAt: PRStoreFileName.moveAside(url, reason: "corrupt"),
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// For callers that only want whatever is staged and have nothing to lose
    /// by treating an unreadable file as empty — the dashboard shelf, and the
    /// AI module's read-only view of the review. The workspace uses `read`,
    /// because it saves the result straight back.
    static func load(for reference: PRReference, host: ForgeHost = .dotCom) -> ReviewDraft {
        if case .decoded(let draft) = read(for: reference, host: host) { return draft }
        return ReviewDraft()
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
            // A file that predates hashed names encodes the PR identity in
            // its filename only. Listing deliberately does not quarantine
            // what it cannot decode: renaming files behind a reviewer's back
            // during a routine dashboard refresh is not a listing's job, and
            // `read` does it when they actually open that pull request.
            let legacyKey = PRStoreFileName.legacyReference(fileName: url.lastPathComponent)?.key ?? ""
            guard let reference = PRStoreFileName.reference(key: draft.referenceKey ?? legacyKey) else { return nil }
            guard draft.referenceKey != nil || !draft.comments.isEmpty || !draft.summary.isEmpty
                    || !draft.viewedFiles.isEmpty || draft.event != .comment else { return nil }
            if draft.savedAt == nil {
                draft.savedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            return DashboardReviewDraft(reference: reference, draft: draft)
        }.sorted { ($0.draft.savedAt ?? .distantPast) > ($1.draft.savedAt ?? .distantPast) }
    }

    /// An empty marker prevents legacy in-review status from recreating a
    /// cleared draft. It carries its `referenceKey` like any other draft, so
    /// that a future change of filename scheme can migrate it rather than
    /// leave a marker nothing can place.
    static func discardChecked(for reference: PRReference, host: ForgeHost) throws {
        var cleared = ReviewDraft()
        cleared.referenceKey = reference.key
        cleared.isDiscarded = true
        try saveChecked(cleared, for: reference, host: host)
    }
}
