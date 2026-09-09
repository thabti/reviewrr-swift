import CryptoKit
import Foundation

/// Everything the AI module knows about one review at one moment.
///
/// One value type, built once per turn, from which the prompt, the cache
/// fingerprint, and the staleness check all derive. Before this existed each
/// of those read the world separately and had to be kept in agreement by
/// hand — which is how a context-budget change nearly stopped the analysis
/// cache from ever hitting.
struct AIReviewSituation {
    var reference: PRReference
    var host: String
    var pullRequest: PullRequest
    var files: [PRFile]
    var issueComments: [IssueComment]
    var reviewComments: [ReviewComment]
    /// Local, unsent review state. The reviewer's own work in progress: the
    /// model must not re-raise what they have already written down.
    var draft: ReviewDraft
    /// What a previous analysis of this PR concluded, when there is one.
    var priorRun: AIPriorRun?

    struct AIPriorRun: Equatable {
        var headSha: String
        var generatedAt: Date
        var findingCount: Int
    }

    var headSha: String { pullRequest.headSha }

    /// Paths that already carry review discussion. Not "resolved" — Reviewrr
    /// does not know resolution state for these comments, and the prompt says
    /// so rather than implying the thread is closed.
    var discussedPaths: [String] {
        var seen = Set<String>()
        return reviewComments.compactMap { seen.insert($0.path).inserted ? $0.path : nil }.sorted()
    }

    var draftedPaths: [String] {
        var seen = Set<String>()
        return draft.comments.compactMap { seen.insert($0.path).inserted ? $0.path : nil }.sorted()
    }

    /// Drafts written against a revision that is no longer the head. Worth
    /// naming in the prompt and in the UI: their line anchors may no longer
    /// point at the code the reviewer meant.
    var staleDrafts: [DraftComment] {
        draft.comments.filter { !$0.headSha.isEmpty && $0.headSha != headSha }
    }

    /// Files the reviewer has already marked viewed *and* that carry no
    /// draft. Somewhere they have been and had nothing to say — a weaker
    /// signal than a draft, so it only reorders attention.
    var settledPaths: [String] {
        let drafted = Set(draftedPaths)
        return draft.viewedFiles.filter { !drafted.contains($0) }.sorted()
    }

    /// A short, honest description of the languages and shapes in the change,
    /// so the model reviews Swift as Swift without being told which repo this
    /// is. Derived from paths only — nothing here inspects file contents.
    var changeShape: [String] {
        var notes: [String] = []
        let extensions = Dictionary(grouping: files.compactMap { path -> String? in
            let extension_ = (path.filename as NSString).pathExtension.lowercased()
            return extension_.isEmpty ? nil : extension_
        }, by: { $0 }).mapValues(\.count)
        let ranked = extensions.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(4)
        if !ranked.isEmpty {
            notes.append("File types: " + ranked.map { ".\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        let testFiles = files.filter { FileClassifier.category(for: $0.filename) == .test }
        notes.append(testFiles.isEmpty
            ? "No test files are part of this change."
            : "\(testFiles.count) of \(files.count) changed files are tests.")
        let renamed = files.filter { $0.status == .renamed }
        if !renamed.isEmpty { notes.append("\(renamed.count) file(s) renamed — compare against the previous path.") }
        let removed = files.filter { $0.status == .removed }
        if !removed.isEmpty { notes.append("\(removed.count) file(s) deleted — callers may not be in this diff.") }
        return notes
    }

    /// Per-file identity, so a cache built at one revision can tell which
    /// files actually changed at the next one. Hashing the patch rather than
    /// the whole file because the patch is all Reviewrr ever sends.
    func fileFingerprints() -> [String: String] {
        var result: [String: String] = [:]
        for file in files {
            let material = "\(file.status.rawValue)|\(file.additions)|\(file.deletions)|\(file.patch ?? "")"
            result[file.filename] = Self.hash(material)
        }
        return result
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
