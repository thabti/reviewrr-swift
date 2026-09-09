import Foundation

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
}

struct DashboardReviewDraft: Identifiable {
    let reference: PRReference
    let draft: ReviewDraft
    var id: String { reference.key }
}
