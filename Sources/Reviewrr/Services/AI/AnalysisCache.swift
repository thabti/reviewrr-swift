import Foundation

/// One stored analysis run. `key` is the full cache-identity string from the
/// schema doc's "Cache identity and extension" section — provider, model,
/// head SHA, prompt version, schema version, and content hash — so an exact
/// match renders immediately with no provider call, and any of those
/// changing naturally misses.
struct AnalysisCacheEntry: Codable, Equatable {
    var key: String
    var providerID: String
    var model: String
    var headSha: String
    var generatedAt: Date
    var elapsedMS: Int
    var usage: AIUsage?
    var outcome: AnalysisOutcome
    /// The family this run belongs to — provider, model, prompt version,
    /// schema version — so a run made at an earlier revision can be found
    /// and partly reused instead of discarded.
    var lineage: String = ""
    /// Per-file patch hashes at the time of the run. What makes reuse across
    /// revisions possible: a finding on a file whose hash is unchanged still
    /// points at the same code.
    var fileFingerprints: [String: String] = [:]
    /// Touched on every read, so eviction drops what the reviewer stopped
    /// coming back to rather than what happens to be oldest.
    var lastUsedAt: Date?

    init(
        key: String, providerID: String, model: String, headSha: String, generatedAt: Date,
        elapsedMS: Int, usage: AIUsage?, outcome: AnalysisOutcome,
        lineage: String = "", fileFingerprints: [String: String] = [:], lastUsedAt: Date? = nil
    ) {
        self.key = key
        self.providerID = providerID
        self.model = model
        self.headSha = headSha
        self.generatedAt = generatedAt
        self.elapsedMS = elapsedMS
        self.usage = usage
        self.outcome = outcome
        self.lineage = lineage
        self.fileFingerprints = fileFingerprints
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case key, providerID, model, headSha, generatedAt, elapsedMS, usage, outcome
        case lineage, fileFingerprints, lastUsedAt
    }

    /// Field-by-field with defaults, for the same reason `AppSettings` does
    /// it: adding a field must never make an existing cache file undecodable,
    /// which would silently throw away every stored analysis on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        providerID = try container.decode(String.self, forKey: .providerID)
        model = try container.decode(String.self, forKey: .model)
        headSha = try container.decode(String.self, forKey: .headSha)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        elapsedMS = try container.decode(Int.self, forKey: .elapsedMS)
        usage = try container.decodeIfPresent(AIUsage.self, forKey: .usage)
        outcome = try container.decode(AnalysisOutcome.self, forKey: .outcome)
        lineage = ((try? container.decodeIfPresent(String.self, forKey: .lineage)) ?? nil) ?? ""
        fileFingerprints = ((try? container.decodeIfPresent([String: String].self, forKey: .fileFingerprints)) ?? nil) ?? [:]
        lastUsedAt = (try? container.decodeIfPresent(Date.self, forKey: .lastUsedAt)) ?? nil
    }

    var effectiveLastUsedAt: Date { lastUsedAt ?? generatedAt }
}

/// What the cache can offer for a given identity.
enum AnalysisCacheReuse: Equatable {
    /// The same content at the same revision. Render it; call nothing.
    case exact(AnalysisCacheEntry)
    /// A run from the same provider and model at an earlier revision. The
    /// findings whose files are byte-identical still hold; the rest are
    /// dropped rather than shown at line numbers that have moved. Worth
    /// showing while a fresh analysis runs, clearly labelled as carried over.
    case carriedOver(entry: AnalysisCacheEntry, fromHeadSha: String, keptFindingIDs: [String], droppedFindings: Int)
    case miss
}

/// Persists analysis results per PR to disk (same Application Support
/// layout as `DraftStore`), so reopening a PR at an unchanged revision
/// renders instantly instead of re-calling a provider.
enum AnalysisCache {
    /// Bounded per PR: an active review session realistically cycles
    /// through a handful of provider/model combinations, not hundreds.
    private static let maxEntriesPerPR = 12
    /// A cached analysis of a revision nobody has opened in two weeks is
    /// worth less than the disk it sits on, and the model has moved on.
    static let timeToLive: TimeInterval = 14 * 24 * 60 * 60
    /// Total PR files kept on disk. Reviewrr has no background daemon to
    /// sweep this, so the sweep happens on write.
    static let maxCachedPullRequests = 200

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Reviewrr/ai-analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Same one-shot rename the draft store does, for the same reason: the
        // old name held a slash for any GitLab project below the top level, so
        // `write` failed with ENOENT under a `try?` and analyses for those
        // projects were silently never cached — every reopen paid a provider
        // call again. See `PRStoreFileName`.
        PRStoreFileName.migrateLegacyNames(in: dir, host: .dotCom) {
            PRStoreFileName.legacyReference(fileName: $0.lastPathComponent)
        }
        return dir
    }

    /// Named per reference only. Unlike drafts, this store is never told which
    /// host it is caching for — `AIEngine` does not pass one — so two projects
    /// with the same path on different forges still share a file here. That is
    /// unchanged from the old name and worth its own task; what is fixed is
    /// that the name can no longer contain a path separator.
    private static func fileURL(for reference: PRReference) -> URL {
        directory().appendingPathComponent(PRStoreFileName.json(for: reference))
    }

    /// Retained for callers without an `AIAnalysisIdentity`; the identity
    /// type is the one that also carries the fingerprints reuse needs.
    static func cacheKey(providerID: String, model: String, headSha: String, contentHash: String) -> String {
        AIAnalysisIdentity(
            providerID: providerID, model: model, headSha: headSha,
            contentHash: contentHash, fileFingerprints: [:]
        ).key
    }

    private static func loadAll(for reference: PRReference) -> [AnalysisCacheEntry] {
        guard
            let data = try? Data(contentsOf: fileURL(for: reference)),
            let decoded = try? JSONDecoder().decode([AnalysisCacheEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func load(for reference: PRReference, key: String) -> AnalysisCacheEntry? {
        guard let entry = loadAll(for: reference).first(where: { $0.key == key }) else { return nil }
        guard Date().timeIntervalSince(entry.generatedAt) < timeToLive else { return nil }
        touch(key: key, for: reference)
        return entry
    }

    /// The newest stored run for this PR by any provider, used to tell a
    /// fresh prompt that this is a second look and whether the revision moved
    /// since. Deliberately not filtered by provider: the reviewer switching
    /// model does not make the earlier pass stop having happened.
    static func mostRecent(for reference: PRReference, now: Date = Date()) -> AnalysisCacheEntry? {
        loadAll(for: reference)
            .filter { now.timeIntervalSince($0.generatedAt) < timeToLive }
            .max { $0.generatedAt < $1.generatedAt }
    }

    /// The best the cache can do for this identity: the same run, a partial
    /// carry-over from an earlier revision, or nothing.
    static func reuse(for reference: PRReference, identity: AIAnalysisIdentity, now: Date = Date()) -> AnalysisCacheReuse {
        let entries = loadAll(for: reference).filter { now.timeIntervalSince($0.generatedAt) < timeToLive }

        if let exact = entries.first(where: { $0.key == identity.key }) {
            touch(key: exact.key, for: reference)
            return .exact(exact)
        }

        // Same provider and model, different revision. Newest first: the
        // closest revision is the one most likely to still line up.
        let sameLineage = entries
            .filter { !$0.lineage.isEmpty && $0.lineage == identity.lineage && $0.headSha != identity.headSha }
            .sorted { $0.generatedAt > $1.generatedAt }
        for candidate in sameLineage {
            guard case .structured(let result) = candidate.outcome, !result.findings.isEmpty else { continue }
            let unchanged = unchangedPaths(previous: candidate.fileFingerprints, current: identity.fileFingerprints)
            guard !unchanged.isEmpty else { continue }
            // A finding with no anchor cannot be checked against a file, so
            // it is not carried: the reviewer would have no way to tell
            // whether it still applies.
            let kept = result.findings.filter { finding in
                guard let path = finding.path else { return false }
                return unchanged.contains(path)
            }
            guard !kept.isEmpty else { continue }
            touch(key: candidate.key, for: reference)
            return .carriedOver(
                entry: candidate, fromHeadSha: candidate.headSha,
                keptFindingIDs: kept.map(\.id), droppedFindings: result.findings.count - kept.count
            )
        }
        return .miss
    }

    /// Files present in both runs with an identical patch hash. A file absent
    /// from either side counts as changed — a file that was not part of the
    /// earlier run was never reviewed at that revision.
    static func unchangedPaths(previous: [String: String], current: [String: String]) -> Set<String> {
        var result = Set<String>()
        for (path, hash) in current where previous[path] == hash {
            result.insert(path)
        }
        return result
    }

    /// Narrows a carried-over result to the findings that still hold, and
    /// says so in `limitations` — a reviewer must never be shown a finding
    /// from an older revision without being told.
    static func carryOver(_ entry: AnalysisCacheEntry, keptFindingIDs: [String], droppedFindings: Int) -> AnalysisOutcome {
        guard case .structured(var result) = entry.outcome else { return entry.outcome }
        let keep = Set(keptFindingIDs)
        result.findings = result.findings.filter { keep.contains($0.id) }
        let short = String(entry.headSha.prefix(7))
        var note = "Carried over from an analysis of revision \(short): these findings are on files that have not "
            + "changed since. A fresh analysis of the current revision has not completed."
        if droppedFindings > 0 {
            note += " \(droppedFindings) finding(s) on files that did change were dropped rather than shown at "
                + "line numbers that may have moved."
        }
        result.limitations.append(note)
        return .structured(result)
    }

    private static func touch(key: String, for reference: PRReference) {
        var entries = loadAll(for: reference)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries[index].lastUsedAt = Date()
        write(entries, for: reference)
    }

    static func save(_ entry: AnalysisCacheEntry, for reference: PRReference) {
        var stored = entry
        if stored.lastUsedAt == nil { stored.lastUsedAt = stored.generatedAt }
        var entries = loadAll(for: reference)
            .filter { $0.key != stored.key }
            .filter { Date().timeIntervalSince($0.generatedAt) < timeToLive }
        entries.append(stored)
        if entries.count > maxEntriesPerPR {
            // Least recently *used*, not oldest: a reviewer who keeps coming
            // back to one provider's result should keep it.
            entries = Array(entries.sorted { $0.effectiveLastUsedAt > $1.effectiveLastUsedAt }.prefix(maxEntriesPerPR))
        }
        write(entries, for: reference)
        pruneStore()
    }

    private static func write(_ entries: [AnalysisCacheEntry], for reference: PRReference) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL(for: reference), options: .atomic)
    }

    /// Drops whole PR files that have expired, then the least recently
    /// modified ones once the store is over its cap. Runs on write because
    /// there is no background daemon (a deliberate product rule) and a
    /// review session writes far less often than it reads.
    static func pruneStore(now: Date = Date()) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory(), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }

        var dated: [(url: URL, modified: Date)] = []
        for url in urls where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > timeToLive {
                try? manager.removeItem(at: url)
            } else {
                dated.append((url, modified))
            }
        }
        guard dated.count > maxCachedPullRequests else { return }
        for entry in dated.sorted(by: { $0.modified < $1.modified }).prefix(dated.count - maxCachedPullRequests) {
            try? manager.removeItem(at: entry.url)
        }
    }

    static func clear(for reference: PRReference) {
        try? FileManager.default.removeItem(at: fileURL(for: reference))
    }
}
