import Foundation

/// Decodes what it can and reports the rest as `nil`.
///
/// A `[DraftComment]` decoded as a whole array costs all eight of a
/// reviewer's staged comments when one of them is unreadable — the array's
/// decode throws, `comments` falls back to empty, and the seven intact
/// comments go with it. Wrapping each element moves the blast radius from
/// the review to the one comment that is actually broken.
private struct DraftLossyElement<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct DraftComment: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var path: String
    /// The *last* line of the comment's range, matching GitHub's own shape:
    /// a single-line comment is `line` with no `startLine`.
    var line: Int
    var side: DiffSide
    var body: String
    var headSha: String
    /// First line of a multi-line comment. `nil` for a single line.
    ///
    /// Optional, so every draft written before ranges existed still decodes.
    var startLine: Int? = nil
    /// Which side the range starts on. GitHub allows a range to begin on the
    /// old side and end on the new one; Reviewrr only ever selects within one
    /// side, so this mirrors `side` — sent because GitHub requires it
    /// alongside `start_line`.
    var startSide: DiffSide? = nil

    init(
        id: UUID = UUID(), path: String, line: Int, side: DiffSide, body: String, headSha: String,
        startLine: Int? = nil, startSide: DiffSide? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.body = body
        self.headSha = headSha
        self.startLine = startLine
        self.startSide = startSide
    }

    // MARK: - Forward-compatible decoding
    //
    // Written out for the reason `Forge.swift` documents: Swift's synthesized
    // decoder throws `keyNotFound` for a missing key *even when the property
    // has a default value*, so one field added in a later release would have
    // made every comment a reviewer had already staged undecodable. This is
    // the type where that costs unsent human work, so it gets the same
    // treatment as `WatchedProject`.
    //
    // `path` and `line` stay required: they are the anchor. A comment that
    // cannot say where it belongs is not a comment, and inventing an anchor
    // would attach a reviewer's words to code they never read.
    enum CodingKeys: String, CodingKey {
        case id, path, line, side, body, headSha, startLine, startSide
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        path = try container.decode(String.self, forKey: .path)
        line = try container.decode(Int.self, forKey: .line)
        side = ((try? container.decodeIfPresent(DiffSide.self, forKey: .side)) ?? nil) ?? .right
        body = ((try? container.decodeIfPresent(String.self, forKey: .body)) ?? nil) ?? ""
        headSha = ((try? container.decodeIfPresent(String.self, forKey: .headSha)) ?? nil) ?? ""
        startLine = (try? container.decodeIfPresent(Int.self, forKey: .startLine)) ?? nil
        startSide = (try? container.decodeIfPresent(DiffSide.self, forKey: .startSide)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(line, forKey: .line)
        try container.encode(side, forKey: .side)
        try container.encode(body, forKey: .body)
        try container.encode(headSha, forKey: .headSha)
        try container.encodeIfPresent(startLine, forKey: .startLine)
        try container.encodeIfPresent(startSide, forKey: .startSide)
    }

    /// The lines this comment covers, in ascending order.
    var lineRange: ClosedRange<Int> {
        guard let startLine, startLine < line else { return line...line }
        return startLine...line
    }

    var isMultiLine: Bool { lineRange.count > 1 }

    /// How the range reads in the interface: "line 42" or "lines 42–47".
    var rangeDescription: String {
        isMultiLine ? "lines \(lineRange.lowerBound)–\(lineRange.upperBound)" : "line \(line)"
    }
}

enum ReviewEvent: String, Codable, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }
}

struct ReviewDraft: Codable, Equatable {
    /// What shape this file was written in. Absent means "before versioning",
    /// which is `1`.
    ///
    /// Nothing branches on it yet, deliberately: it exists so that the next
    /// change that *cannot* be absorbed by the tolerant decoding below can be
    /// migrated from a known starting point instead of guessed at from which
    /// keys happen to be present.
    static let currentSchemaVersion = 1
    var schemaVersion: Int = ReviewDraft.currentSchemaVersion

    // Optional metadata preserves compatibility with existing draft files.
    var referenceKey: String?
    var title: String?
    var savedAt: Date?
    var isSubmitted: Bool?
    var isDiscarded: Bool?
    var pendingComments: [String: DraftComment]?

    var summary: String = ""
    var event: ReviewEvent = .comment
    var comments: [DraftComment] = []
    var viewedFiles: Set<String> = []

    init() {}

    // MARK: - Forward-compatible decoding
    //
    // Every field defaulted, in the style of `WatchedProject` and
    // `AppSettings`, because this is the file that holds a review nobody has
    // sent yet. A synthesized decoder would have turned "this build knows one
    // more field than the file does" into "the update ate my reviews": the
    // whole draft throws, and until T-010 that empty result was written back
    // over the file.
    //
    // What is deliberately *not* tolerated: a payload that is not a JSON
    // object at all. That still throws, so `DraftStore.read` can tell a file
    // it could not understand from one that is genuinely empty — and refuse to
    // overwrite the first.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, referenceKey, title, savedAt, isSubmitted, isDiscarded, pendingComments
        case summary, event, comments, viewedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = ((try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil) ?? 1
        referenceKey = (try? container.decodeIfPresent(String.self, forKey: .referenceKey)) ?? nil
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        savedAt = (try? container.decodeIfPresent(Date.self, forKey: .savedAt)) ?? nil
        isSubmitted = (try? container.decodeIfPresent(Bool.self, forKey: .isSubmitted)) ?? nil
        isDiscarded = (try? container.decodeIfPresent(Bool.self, forKey: .isDiscarded)) ?? nil
        let pending = (try? container.decodeIfPresent(
            [String: DraftLossyElement<DraftComment>].self, forKey: .pendingComments
        )) ?? nil
        pendingComments = pending?.compactMapValues(\.value)
        summary = ((try? container.decodeIfPresent(String.self, forKey: .summary)) ?? nil) ?? ""
        event = ((try? container.decodeIfPresent(ReviewEvent.self, forKey: .event)) ?? nil) ?? .comment
        let staged = (try? container.decodeIfPresent(
            [DraftLossyElement<DraftComment>].self, forKey: .comments
        )) ?? nil
        comments = staged?.compactMap(\.value) ?? []
        viewedFiles = ((try? container.decodeIfPresent(Set<String>.self, forKey: .viewedFiles)) ?? nil) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(referenceKey, forKey: .referenceKey)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(isSubmitted, forKey: .isSubmitted)
        try container.encodeIfPresent(isDiscarded, forKey: .isDiscarded)
        try container.encodeIfPresent(pendingComments, forKey: .pendingComments)
        try container.encode(summary, forKey: .summary)
        try container.encode(event, forKey: .event)
        try container.encode(comments, forKey: .comments)
        try container.encode(viewedFiles, forKey: .viewedFiles)
    }
}

struct DashboardReviewDraft: Identifiable {
    let reference: PRReference
    let draft: ReviewDraft
    var id: String { reference.key }
}
