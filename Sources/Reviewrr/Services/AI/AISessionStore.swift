import Foundation

/// One reviewer's AI session on one pull request, across app launches.
///
/// Reopening a PR used to reset the panel: `AIModel.configure` cleared the
/// Ask transcript unconditionally, so every answer the reviewer had already
/// read was gone, and a finding they had already turned into a draft looked
/// untouched. A review of a real pull request happens over days and several
/// revisions — this is the state that makes coming back feel like continuing.
struct AISession: Codable, Equatable {
    /// The Ask transcript, oldest first. Streaming placeholders are never
    /// stored: a half-written answer is not worth restoring.
    var messages: [ChatMessage] = []
    /// The head SHA the transcript was written against, so a revision that
    /// has since moved can be marked rather than silently misread.
    var headSha: String = ""
    /// Findings the reviewer has already turned into a draft comment. Keyed
    /// by finding id, which the analysis contract asks the model to keep
    /// stable for the same underlying problem.
    var draftedFindingIDs: Set<String> = []
    /// Findings the reviewer explicitly set aside. Kept separate from
    /// drafted: "I dealt with this" and "I disagree with this" are different
    /// answers, and only the second should stay quiet on a re-analysis.
    var dismissedFindingIDs: Set<String> = []
    var updatedAt: Date = Date()

    var isEmpty: Bool {
        messages.isEmpty && draftedFindingIDs.isEmpty && dismissedFindingIDs.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case messages, headSha, draftedFindingIDs, dismissedFindingIDs, updatedAt
    }

    init() {}

    /// Field-by-field with defaults, so adding state later never discards a
    /// reviewer's existing transcript.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = ((try? container.decodeIfPresent([ChatMessage].self, forKey: .messages)) ?? nil) ?? []
        headSha = ((try? container.decodeIfPresent(String.self, forKey: .headSha)) ?? nil) ?? ""
        draftedFindingIDs = ((try? container.decodeIfPresent(Set<String>.self, forKey: .draftedFindingIDs)) ?? nil) ?? []
        dismissedFindingIDs = ((try? container.decodeIfPresent(Set<String>.self, forKey: .dismissedFindingIDs)) ?? nil) ?? []
        updatedAt = ((try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil) ?? Date()
    }
}

/// How a restored session relates to the revision now open.
enum AISessionContinuity: Equatable {
    /// Nothing stored, or nothing worth restoring.
    case fresh
    /// The transcript was written against the revision that is open now.
    case sameRevision
    /// The head moved since. The transcript is still shown — the reviewer's
    /// own questions and the reasoning they read are not invalidated by a new
    /// commit — but it is marked, because the code the answers describe may
    /// no longer be the code on screen.
    case revisionMoved(fromHeadSha: String)
}

enum AISessionStore {
    /// Long enough to cover a review that stalls over a holiday, short
    /// enough that a merged PR's transcript does not live forever.
    static let timeToLive: TimeInterval = 30 * 24 * 60 * 60
    static let maxStoredSessions = 200
    /// A transcript is unbounded in principle — a reviewer can ask all day —
    /// so only the most recent turns are kept. Enough to hold the thread of
    /// a conversation, not enough to grow without limit.
    static let maxStoredMessages = 60

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Reviewrr/ai-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // See `PRStoreFileName`: the old name held a slash for any nested
        // GitLab group, so an Ask transcript on one of those projects was
        // never written — the panel reset itself on every reopen, which is
        // exactly the behaviour this store exists to stop.
        PRStoreFileName.migrateLegacyNames(in: dir, host: .dotCom) {
            PRStoreFileName.legacyReference(fileName: $0.lastPathComponent)
        }
        return dir
    }

    private static func fileURL(for reference: PRReference) -> URL {
        directory().appendingPathComponent(PRStoreFileName.json(for: reference))
    }

    static func load(for reference: PRReference, now: Date = Date()) -> AISession {
        guard
            let data = try? Data(contentsOf: fileURL(for: reference)),
            let decoded = try? JSONDecoder().decode(AISession.self, from: data),
            now.timeIntervalSince(decoded.updatedAt) < timeToLive
        else {
            return AISession()
        }
        return decoded
    }

    static func save(_ session: AISession, for reference: PRReference) {
        var stored = session
        stored.updatedAt = Date()
        // Never persist a reply that was still arriving: on restore it would
        // show a typing indicator that nothing is feeding.
        stored.messages = stored.messages
            .filter { !$0.isStreaming && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(maxStoredMessages)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL(for: reference), options: .atomic)
        prune()
    }

    static func clear(for reference: PRReference) {
        try? FileManager.default.removeItem(at: fileURL(for: reference))
    }

    /// How a stored session lines up with the revision being opened.
    static func continuity(of session: AISession, openingHeadSha: String) -> AISessionContinuity {
        guard !session.messages.isEmpty else { return .fresh }
        guard !session.headSha.isEmpty, session.headSha != openingHeadSha else {
            return session.headSha == openingHeadSha ? .sameRevision : .fresh
        }
        return .revisionMoved(fromHeadSha: session.headSha)
    }

    /// The marker inserted into a restored transcript when the revision has
    /// moved. A system-role message, so it renders as neither the reviewer's
    /// question nor the model's answer.
    static func revisionMovedNotice(fromHeadSha: String, toHeadSha: String) -> ChatMessage {
        ChatMessage(
            role: .system,
            content: "The pull request moved from \(String(fromHeadSha.prefix(7))) to "
                + "\(String(toHeadSha.prefix(7))) after the answers above. Line numbers and code they refer to may "
                + "have changed."
        )
    }

    /// Same sweep-on-write approach as the analysis cache, and for the same
    /// reason: there is no background daemon to do it later.
    static func prune(now: Date = Date()) {
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
        guard dated.count > maxStoredSessions else { return }
        for entry in dated.sorted(by: { $0.modified < $1.modified }).prefix(dated.count - maxStoredSessions) {
            try? manager.removeItem(at: entry.url)
        }
    }
}
