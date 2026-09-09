import AppKit
import SwiftUI

/// Unified-mode rows for one hunk: a single content column with both old
/// and new line-number gutters, reusing the same `pairedForSplitView()`
/// grouping the split view uses so a replace shows its deletion directly
/// above its addition (GitHub's unified diff does the same).
struct UnifiedHunkRows: View {
    let filename: String
    let hunkIndex: Int
    let hunk: DiffHunk
    let language: String
    let wordWrap: Bool

    var body: some View {
        UnifiedRows(
            filename: filename, lines: hunk.lines, language: language,
            wordWrap: wordWrap, hunkIndex: hunkIndex
        )
    }
}

/// Unified rows for any run of diff lines. Expanded context (the "show N
/// unmodified lines" gap) is rendered through here too, so switching to
/// unified no longer leaves two-column blocks embedded in a one-column
/// diff. `hunkIndex` is `nil` for those gap rows: they are not jump targets,
/// so they take no scroll identity and cannot collide with a real hunk's.
struct UnifiedRows: View {
    let filename: String
    let lines: [DiffLine]
    let language: String
    let wordWrap: Bool
    var hunkIndex: Int?

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("UnifiedRows", perfStart) }
        return ForEach(pairedRows) { row in
            let scrollID = hunkIndex.map { diffRowScrollID(path: filename, hunkIndex: $0, rowID: row.id) } ?? ""
            UnifiedRowGroup(row: row, filename: filename, language: language, wordWrap: wordWrap, scrollID: scrollID)
                .id(scrollID.isEmpty ? "gap:\(filename)#\(row.id)" : scrollID)
        }
    }

    /// A real hunk's pairing is memoized by (path, hunk index) — it is
    /// rebuilt on every evaluation of this `body` otherwise, once per line
    /// of the file. Expanded gap rows are not: they are at most a couple of
    /// dozen lines and their extent changes as the reviewer reveals more,
    /// so there is nothing stable to key them on.
    private var pairedRows: [SplitDiffRow] {
        guard let hunkIndex else { return lines.pairedForSplitView() }
        return WorkspaceModel.shared.pairedRows(path: filename, hunkIndex: hunkIndex, lines: lines)
    }
}

private struct UnifiedRowGroup: View {
    @EnvironmentObject var model: AppModel
    let row: SplitDiffRow
    let filename: String
    let language: String
    let wordWrap: Bool
    var scrollID: String = ""
    @ObservedObject private var workspace = WorkspaceModel.shared
    @Environment(\.flashedDiffRowID) private var flashedRowID
    /// The flash settles to a quieter hold before it fades; unified rows read
    /// the same value as split ones so a jump looks the same in both layouts.
    @Environment(\.flashedDiffRowIntensity) private var flashIntensity
    @Environment(\.diffPaneLayout) private var layout


    /// `pairedForSplitView()` gives a context line the *same* `DiffLine` on
    /// both sides; a replace/add/delete row never shares an id across sides.
    private var isContextRow: Bool {
        guard let left = row.left, let right = row.right else { return false }
        return left.id == right.id
    }

    private var isFlashed: Bool { !scrollID.isEmpty && scrollID == flashedRowID }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("UnifiedRowGroup", perfStart) }
        return VStack(alignment: .leading, spacing: 0) {
            if isContextRow, let contextLine = row.left {
                lineView(contextLine, wordDiffAgainst: nil, wordDiffAgainstID: nil)
            } else {
                if let left = row.left {
                    lineView(left, wordDiffAgainst: row.right?.displayText, wordDiffAgainstID: row.right?.id)
                }
                if let right = row.right {
                    lineView(right, wordDiffAgainst: row.left?.displayText, wordDiffAgainstID: row.left?.id)
                }
            }
            // Below the range, not beside the clicked line — see the same
            // handling in `SplitDiffRowView`.
            if let side = composerSide, let lineNumber = composerLine(for: side) {
                CommentComposer(filename: filename, line: lineNumber, side: side) {
                    workspace.closeComposer()
                }
                    .diffPanePinned(to: layout)
            }
        }
    }

    /// Which side, if either, has its composer anchored to a line in this row.
    private var composerSide: DiffSide? {
        DiffSide.allCases.first { side in
            composerLine(for: side) != nil
        }
    }

    private func composerLine(for side: DiffSide) -> Int? {
        for line in [row.left, row.right].compactMap({ $0 }) where diffCommentSide(for: line.kind) == side {
            let number = side == .left ? line.oldLineNumber : line.newLineNumber
            if workspace.isComposerOpen(path: filename, side: side, line: number) { return number }
        }
        return nil
    }

    private func openComposer(side: DiffSide) {
        guard let target = anchorLine(for: side),
              let number = side == .left ? target.oldLineNumber : target.newLineNumber
        else { return }
        workspace.openComposer(path: filename, side: side, line: number)
    }

    private func anchorLine(for side: DiffSide) -> DiffLine? {
        if let left = row.left, diffCommentSide(for: left.kind) == side { return left }
        if let right = row.right, diffCommentSide(for: right.kind) == side { return right }
        return nil
    }

    /// A line, plus whatever is attached to it.
    ///
    /// The overwhelmingly common case is "nothing is attached", and it now
    /// renders as the bare row: no wrapping `VStack`, no two `ForEach` nodes
    /// standing by to iterate empty arrays. On a screenful of 45 rows that is
    /// ~135 view-graph nodes the layout no longer has to walk per frame.
    @ViewBuilder
    private func lineView(_ diffLine: DiffLine, wordDiffAgainst: String?, wordDiffAgainstID: Int?) -> some View {
        let side = diffCommentSide(for: diffLine.kind)
        let lineNumber = side == .left ? diffLine.oldLineNumber : diffLine.newLineNumber
        let threads = threadsAnchored(in: model, path: filename, line: lineNumber, side: side)
        let drafts = draftsAnchored(in: model, path: filename, line: lineNumber, side: side)
        let row = UnifiedLineRow(
            line: diffLine, filename: filename, language: language,
            wordDiffAgainst: wordDiffAgainst, wordDiffAgainstID: wordDiffAgainstID,
            wordWrap: wordWrap, onComment: { openComposer(side: side) }
        )
        .diffJumpFlash(isFlashed, intensity: flashIntensity)

        if threads.isEmpty && drafts.isEmpty {
            row
        } else {
            VStack(alignment: .leading, spacing: 0) {
                row
                ForEach(threads) { thread in
                    ThreadView(thread: thread)
                        .diffPanePinned(to: layout)
                }
                ForEach(drafts) { comment in
                    DraftCommentRow(comment: comment)
                        .diffPanePinned(to: layout)
                }
            }
        }
    }
}

private struct UnifiedLineRow: View {
    let line: DiffLine
    let filename: String
    let language: String
    let wordDiffAgainst: String?
    var wordDiffAgainstID: Int?
    let wordWrap: Bool
    let onComment: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.diffPaneLayout) private var layout
    @State private var hovering = false

    private var commentSide: DiffSide { diffCommentSide(for: line.kind) }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("UnifiedLineRow", perfStart) }
        return HStack(alignment: .top, spacing: 0) {
            // One drag for both gutters, not one each: this row's two gutters
            // select the same line on the same side, so the second gesture was
            // a `DragGesture`, a `@GestureState` and a hit-test region per
            // cell for nothing. Still scoped to the gutters — dragging across
            // the code selects nothing, the way it doesn't on GitHub.
            HStack(alignment: .top, spacing: 0) {
            DiffLineGutter(
                number: line.oldLineNumber,
                selectionNumber: commentSide == .left ? line.oldLineNumber : line.newLineNumber,
                width: DiffRowMetrics.unifiedGutterWidth,
                showCommentAffordance: hovering && commentSide == .left,
                // The side a comment on *this line* attaches to, not the
                // column the gutter happens to be. A context line is anchored
                // RIGHT, so a drag down the old-number column was building a
                // LEFT selection that the composer then ignored — six lines
                // dragged, one line commented on.
                selectionTarget: (path: filename, side: commentSide),
                onComment: onComment
            )
            DiffLineGutter(
                number: line.newLineNumber,
                selectionNumber: commentSide == .left ? line.oldLineNumber : line.newLineNumber,
                width: DiffRowMetrics.unifiedGutterWidth,
                showCommentAffordance: hovering && commentSide == .right,
                selectionTarget: (path: filename, side: commentSide),
                onComment: onComment
            )
            }
            .diffSelectionDrag(
                path: filename, side: commentSide,
                line: commentSide == .left ? line.oldLineNumber : line.newLineNumber,
                onMultiLine: onComment
            )
            Text(marker)
                .font(Theme.monoFont)
                .foregroundStyle(.secondary)
                .frame(width: DiffRowMetrics.markerWidth)
            HighlightedCodeText(
                filename: filename, lineID: line.id, side: commentSide, text: line.displayText,
                language: language, wordDiffAgainst: wordDiffAgainst,
                wordDiffAgainstID: wordDiffAgainstID, wordWrap: wordWrap
            )
            .padding(.trailing, DiffRowMetrics.trailingPadding)
        }
        // A whole-point row height. The fractional `.padding(.vertical, 1.5)`
        // this replaces put every row on a half-point boundary, where text
        // renders soft.
        .padding(.vertical, DiffRowMetrics.verticalPadding)
        .diffRowWidth(layout.rowWidth)
        // A minimum, not an exact height: a wrapped line is taller, and
        // pinning the height was measured to buy nothing — the lazy stack's
        // cost is the number of nodes it walks per row, not the arithmetic.
        .frame(minHeight: DiffRowMetrics.height, alignment: .topLeading)
        .background(diffRowBackground(line.kind, colorScheme: colorScheme))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Comment here", systemImage: "bubble.left") { onComment() }
                .help("Start a draft comment on this line")
            Button("Copy line", systemImage: "doc.on.doc") {
                // Copies the line as written, tabs and all.
                NSPasteboard.general.clearContents()
                // The original text, tabs and all — what the reviewer pastes
                // should match the file, not the rendering.
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
        // One VoiceOver stop per line instead of three, and it now says what
        // happened to the line rather than reading a bare "+" that announces
        // nothing at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            diffRowAccessibilityLabel(
                kind: line.kind,
                lineNumber: commentSide == .left ? line.oldLineNumber : line.newLineNumber,
                text: line.text
            )
        )
        .accessibilityActions {
            Button("Comment on this line") { onComment() }
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }
}
