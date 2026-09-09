import Foundation

enum DiffLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
}

enum DiffSide: String, Codable, Equatable, Sendable, CaseIterable {
    case left = "LEFT"
    case right = "RIGHT"
}

struct DiffLine: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: DiffLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    /// The line exactly as the patch carries it, tabs included. This is what
    /// "Copy line" puts on the clipboard.
    let text: String

    /// `text` with tabs expanded, computed once when the line is parsed.
    ///
    /// Every visible row asked for this on *every* evaluation of its body,
    /// and `expandingTabs` has to scan the whole line to find out whether
    /// there is a tab in it at all — 1.4µs a line, 0.13ms for a screenful of
    /// split cells, repeated on every frame of a scroll. Parsing happens once
    /// per file, off the main actor, so that is where the scan belongs.
    let displayText: String

    init(id: Int, kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
        self.displayText = DiffText.expandingTabs(text)
    }
}

struct DiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [DiffLine]

    /// Added and removed line counts, tallied once when the hunk is parsed.
    ///
    /// The hunk header showed these, and computed them by filtering `lines`
    /// twice on every evaluation of its body — two passes over as many as a
    /// few hundred lines, per visible header, per frame of a scroll.
    let additions: Int
    let deletions: Int

    init(id: Int, header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.id = id
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        var additions = 0
        var deletions = 0
        for line in lines {
            switch line.kind {
            case .addition: additions += 1
            case .deletion: deletions += 1
            case .context: break
            }
        }
        self.additions = additions
        self.deletions = deletions
    }
}

/// One row in the split diff view. Either side may be empty for a pure
/// addition/deletion, or both filled for a context/replace row.
struct SplitDiffRow: Identifiable, Equatable, Sendable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?
}

/// Which parsed patches to keep, most recently opened first.
///
/// Parsing every file in a pull request up front cost 110ms of CPU and
/// retained 13.6MB to render the one file on screen, so patches are parsed
/// when a file is opened. This decides what to drop as the reviewer moves
/// on: enough recent files that stepping back is instant, bounded so a long
/// review cannot accumulate every patch it passed.
///
/// Split out of the model so the ordering and eviction can be tested without
/// standing up an `AppModel` — which reads the Keychain on init and has no
/// business being constructed in a unit test.
struct ParsedDiffBudget: Equatable {
    private(set) var recency: [String] = []
    let limit: Int

    init(limit: Int = 32) {
        self.limit = max(1, limit)
    }

    /// Records that `path` was just used, and returns the paths that fell out
    /// of the budget as a result.
    mutating func touch(_ path: String) -> [String] {
        recency.removeAll { $0 == path }
        recency.insert(path, at: 0)
        guard recency.count > limit else { return [] }
        let evicted = Array(recency[limit...])
        recency = Array(recency.prefix(limit))
        return evicted
    }

    mutating func removeAll() {
        recency.removeAll()
    }
}

struct ParsedFile: Equatable, Sendable {
    let filename: String
    let hunks: [DiffHunk]
}

extension Array where Element == DiffLine {
    /// Pairs a run of diff lines into split-view rows: a deletion run and
    /// the addition run that follows it become side-by-side "replace" rows
    /// (GitHub's split view does the same), context lines flush both sides
    /// at once, and a lone add/delete run pads the other side with nil.
    func pairedForSplitView() -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var rowID = 0
        var pendingDeletions: [DiffLine] = []
        var pendingAdditions: [DiffLine] = []

        func flushPending() {
            let count = Swift.max(pendingDeletions.count, pendingAdditions.count)
            for i in 0..<count {
                let left = i < pendingDeletions.count ? pendingDeletions[i] : nil
                let right = i < pendingAdditions.count ? pendingAdditions[i] : nil
                rows.append(SplitDiffRow(id: rowID, left: left, right: right))
                rowID += 1
            }
            pendingDeletions.removeAll()
            pendingAdditions.removeAll()
        }

        for line in self {
            switch line.kind {
            case .deletion:
                pendingDeletions.append(line)
            case .addition:
                pendingAdditions.append(line)
            case .context:
                flushPending()
                rows.append(SplitDiffRow(id: rowID, left: line, right: line))
                rowID += 1
            }
        }
        flushPending()
        return rows
    }
}

/// Text preparation shared by every diff renderer.
enum DiffText {
    /// SwiftUI lays a literal tab out against a 28pt default tab stop, which
    /// is not a whole multiple of the mono advance: tab-indented code (Go,
    /// Makefiles) drifts out of alignment with itself, and against
    /// space-indented code on the other side of a replace pair. Expanding to
    /// a fixed run of spaces puts every indent back on a character column.
    static let tabWidth = 4

    /// Done once, at the rendering boundary, so the syntax highlight and the
    /// word-diff span are both measured against the *same* string — their
    /// `String.Index` ranges have to agree or the strong tint lands on the
    /// wrong characters.
    static func expandingTabs(_ text: String) -> String {
        guard text.contains("\t") else { return text }
        return text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
    }

    /// Character columns the line occupies once tabs are expanded. Lets the
    /// diff pane size its scrollable width from the text alone, without
    /// laying out a single line.
    /// Where measuring a line stops paying for itself. A minified bundle can
    /// be a single line hundreds of thousands of columns long; the diff pane
    /// will not make a canvas that wide, so neither the parse pass nor the
    /// pane counts past this.
    ///
    /// Lives here rather than next to the pane's other metrics because the
    /// parse pass measures lines too, and `ViewModels`/`Services` cannot
    /// reference a view type — the unit-test bundle excludes `Views/`.
    static let maxMeasuredColumns = 1000

    static func displayColumns(_ text: String) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            columns += scalar == "\t" ? tabWidth : 1
        }
        return columns
    }
}
