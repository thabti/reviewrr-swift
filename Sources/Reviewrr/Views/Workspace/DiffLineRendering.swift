import AppKit
import SwiftUI

/// Renders one line's code text: syntax-highlighted, with the word-level
/// diff span (if any) picked out with a stronger background. Highlighting
/// and the word-diff span are computed off the main actor by
/// `SyntaxHighlightCache` and cached by (path, line id, side) — the plain
/// `text` paints immediately via `Text(text)` on first appearance, then is
/// swapped for the styled version once the cache task resolves, so
/// scrolling through a huge file never blocks on regex work.
/// `.task(id:)` needs *some* Equatable value that changes exactly when the
/// highlight should be recomputed. Interpolating one into a `String` (the
/// previous approach) allocates and copies a brand-new string — containing
/// the full line text — on every single body evaluation, including the
/// overwhelming majority where nothing actually changed. A plain struct
/// holding the same fields costs a few retained references to compare
/// (`String` equality can short-circuit on shared storage besides), not a
/// fresh allocation, and this view's `body` runs once per visible row on
/// every scroll-driven layout pass.
private struct HighlightTaskID: Equatable {
    let filename: String
    let lineID: Int
    let side: DiffSide
    let isLight: Bool
    let text: String
}

struct HighlightedCodeText: View {
    let filename: String
    let lineID: Int
    let side: DiffSide
    let text: String
    let language: String
    /// The paired line on the other side of a replace row, if any — passing
    /// this in (rather than looking the pair up here) keeps this view a
    /// pure function of its inputs and easy to preview/test around.
    var wordDiffAgainst: String?
    /// The paired line's id, so the span computed for this side can be stored
    /// for the other one too — the tokenization behind it produces both.
    var wordDiffAgainstID: Int?
    var wordWrap: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var styled: AttributedString?

    /// Tab-expanded text, handed in already expanded by the parse pass.
    /// Everything downstream — the plain first paint, the syntax highlight
    /// and the word-diff comparison — works on this same string, so the
    /// ranges the three produce still line up.
    private var displayText: String { text }

    /// `SyntaxHighlighter.highlight` returns the line unstyled for the
    /// `plain` language and for an empty line, so for those there is nothing
    /// to await: the plain first paint *is* the final rendering. Skipping the
    /// task saves an actor hop, a cache entry, and a `@State` write per row —
    /// and blank lines plus files with no known language are a large share of
    /// the rows in a big pull request. A word-diff span still has to be
    /// computed even when the highlight would be a no-op.
    private func highlightTaskID(_ source: String) -> HighlightTaskID? {
        guard wordDiffAgainst != nil || (language != "plain" && !source.isEmpty) else { return nil }
        return HighlightTaskID(
            filename: filename, lineID: lineID, side: side,
            isLight: colorScheme == .light, text: source
        )
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("HighlightedCodeText", perfStart) }
        // Expanded once per evaluation rather than once for the text and
        // again for the task id.
        let source = displayText
        let taskID = highlightTaskID(source)
        return Text(styled ?? AttributedString(source))
            .font(Theme.monoFont)
            .lineLimit(wordWrap ? nil : 1)
            // With wrap off the row lives in the pane's horizontal scroller,
            // so the line must take its *intrinsic* width. A flexible frame
            // here collapsed every row to exactly the viewport width, which
            // left nothing to scroll to and truncated the tail — at about 60
            // characters in split view.
            .fixedSize(horizontal: !wordWrap, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Highlighting resolves off the main actor and swaps in a
            // moment after first paint; a cross-fade reads as "this line
            // settled" rather than the flicker a bare content swap gives.
            .contentTransition(.opacity)
            // Animated on *whether* the styled text has landed, not on the
            // text itself: `AttributedString` equality walks the characters
            // and the runs, and `.animation(_:value:)` re-compares on every
            // update pass. The transition it drives is the one nil → styled
            // swap, which a `Bool` captures exactly.
            .motion(Motion.smooth, value: styled != nil)
            .task(id: taskID) {
                guard taskID != nil else {
                    // A recycled row that now holds a line needing no
                    // highlight must drop whatever the previous line left
                    // behind, or it keeps painting the old styled text.
                    if styled != nil { styled = nil }
                    return
                }
                let cache = SyntaxHighlightCache.shared
                let highlighted = await cache.highlightedLine(path: filename, lineID: lineID, side: side, text: source, language: language)
                guard !Task.isCancelled else { return }
                if let otherText = wordDiffAgainst {
                    let span = await cache.wordDiffRange(
                        path: filename, lineID: lineID, side: side, otherLineID: wordDiffAgainstID,
                        text: source, otherText: otherText
                    )
                    guard !Task.isCancelled else { return }
                    styled = Self.applying(span, to: highlighted, on: side, colorScheme: colorScheme)
                } else {
                    styled = highlighted
                }
            }
    }

    /// Deletions are paired with additions by position, with no similarity
    /// check, so a rewritten block reports nearly the whole line as changed —
    /// and the strong tint is then loudest exactly where it carries no
    /// information. Past this share of the line, "everything changed" is the
    /// honest reading and the row's own tint already says it.
    private static let maxStrongSpanFraction = 0.6

    /// The word-diff span's background is the one part of this view that
    /// isn't appearance-adaptive (`Theme.addedBackgroundStrong`/
    /// `removedBackgroundStrong` are dark-tuned — see `DiffRowPalette`
    /// below), so it's picked per-appearance here rather than in `Theme`,
    /// which this track doesn't own.
    private static func applying(_ span: Range<String.Index>?, to base: AttributedString, on side: DiffSide, colorScheme: ColorScheme) -> AttributedString {
        guard let span, let attrRange = Range(span, in: base) else { return base }
        let total = base.characters.count
        guard total > 0 else { return base }
        let covered = base[attrRange].characters.count
        guard Double(covered) / Double(total) <= maxStrongSpanFraction else { return base }
        var result = base
        let strongBackground: Color
        switch (side, colorScheme) {
        case (.left, .light): strongBackground = DiffRowPalette.removedStrongLight
        case (.left, _): strongBackground = Theme.removedBackgroundStrong
        case (.right, .light): strongBackground = DiffRowPalette.addedStrongLight
        case (.right, _): strongBackground = Theme.addedBackgroundStrong
        }
        result[attrRange].backgroundColor = strongBackground
        return result
    }
}

/// A single old/new line-number column with a hover-to-comment affordance,
/// shared by the split and unified renderers.
struct DiffLineGutter: View {
    let number: Int?
    /// The line a comment from this cell attaches to, when that differs from
    /// the number displayed — a unified diff shows both old and new numbers,
    /// but a comment on the line belongs to exactly one side.
    var selectionNumber: Int?
    var width: CGFloat = 40
    let showCommentAffordance: Bool
    /// Which line this gutter belongs to, so a selection can mark it.
    /// Omitted by callers that have no side to select on.
    var selectionTarget: (path: String, side: DiffSide)?
    let onComment: () -> Void

    /// The selection, handed down by the pane rather than observed here.
    ///
    /// Two gutters per row times a screenful of rows is ninety
    /// `ObservableObject` subscriptions to `WorkspaceModel`, and any change to
    /// any of its published properties then re-rendered every one of them.
    /// The environment carries the one value a gutter actually depends on, and
    /// only a change to *that* invalidates these cells.
    @Environment(\.diffLineSelection) private var selection

    /// The line this cell selects on: `selectionNumber` when the caller
    /// distinguishes it from the digits on screen, otherwise the digits.
    private var anchorNumber: Int? { selectionNumber ?? number }

    private var isSelected: Bool {
        guard let target = selectionTarget, let line = anchorNumber, let selection else { return false }
        return selection.covers(path: target.path, side: target.side, line: line)
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("DiffLineGutter", perfStart) }
        // Both layers stay mounted and just cross-fade opacity, rather than
        // an if/else content swap — the gutter's width never changes on
        // hover, so the code column next to it never reflows.
        return ZStack {
            Text(number.map(String.init) ?? "")
                .font(Theme.monoFontSmall)
                .foregroundStyle(isSelected ? Theme.accent : Theme.gutterText)
                // Exactly one of the number and the "+" is ever visible. They
                // share this cell, so showing the plus on selection while
                // leaving the number up drew them through each other.
                .opacity(showsAffordance ? 0 : 1)

            // Built only while it is visible. Kept mounted it cost a Button,
            // an Image, a help tag and an accessibility element on every
            // gutter cell of every row — two per row — and a scroll's cost is
            // the number of nodes the layout has to walk, not the number it
            // ends up drawing. The cell's width is fixed by `frame(width:)`,
            // so nothing reflows when it appears.
            if number != nil, showsAffordance {
                Button {
                    let workspace = WorkspaceModel.shared
                    // Shift extends from wherever the selection already
                    // starts, the way a file list or a text editor does.
                    if NSEvent.modifierFlags.contains(.shift), let target = selectionTarget, let number {
                        workspace.extendLineSelection(path: target.path, side: target.side, to: number)
                    } else if let target = selectionTarget, let number {
                        workspace.beginLineSelection(path: target.path, side: target.side, line: number)
                    }
                    onComment()
                } label: {
                    Image(systemName: isSelected ? "plus.circle" : "plus.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help(gutterHelp)
                .accessibilityLabel(gutterHelp)
            }
        }
        .frame(width: width)
        // The whole selection mark: one rule, in the only column of a diff
        // that green, red and word-diff tint have not already claimed. No
        // fill behind the digits — that fill was the second box.
        .overlay(alignment: .trailing) { selectionRule }
        // One animation attribute rather than two: both states cross-fade the
        // same cell over the same duration, and a graph node per row per
        // state is exactly the kind of cost that only shows up at 45 rows.
        .motion(Motion.hover, value: (showsAffordance ? 1 : 0) | (isSelected ? 2 : 0))
    }

    /// The "+" is a hover affordance and nothing else.
    ///
    /// Showing it for every selected line hid all six numbers of a six-line
    /// range behind six buttons — the range stopped being readable at exactly
    /// the moment the reviewer was choosing it.
    private var showsAffordance: Bool {
        number != nil && showCommentAffordance
    }

    /// Drawn per gutter cell, full height and with no inset, so consecutive
    /// selected lines join into one unbroken rule rather than a column of
    /// segments with visible joints.
    @ViewBuilder
    private var selectionRule: some View {
        if isSelected {
            Rectangle()
                .fill(Theme.selectionRail)
                .frame(width: Theme.selectionRailWidth)
                // Full row height, or consecutive lines each draw a short tick
                // with a gap beneath it — a dashed column, which is exactly
                // what one continuous rule is meant to replace.
                .frame(maxHeight: .infinity)
                .padding(.trailing, Theme.selectionRailInset - Theme.selectionRailWidth)
                .allowsHitTesting(false)
        }
    }

    private var gutterHelp: String {
        guard let number else { return "" }
        if let selection, selection.isMultiLine,
           selection.covers(path: selectionTarget?.path ?? "", side: selectionTarget?.side ?? .right, line: number) {
            return "Comment on lines \(selection.range.lowerBound)–\(selection.range.upperBound)"
        }
        return "Comment on line \(number) — drag or shift-click to cover several"
    }
}

/// A drag down the gutter selects the lines it passes over — the gesture
/// GitHub uses for "this whole block", instead of the same note left on six
/// consecutive lines.
///
/// Attached once per row rather than once per gutter cell. A unified row's two
/// gutters select the same line on the same side, so the second gesture was
/// pure cost: a `DragGesture`, a `@GestureState` attribute and a hit-test
/// region per cell, ninety of them on screen.
///
/// The line under the pointer comes from the distance dragged over the fixed
/// row height rather than from hit-testing each row: SwiftUI delivers a drag
/// to the view it *started* in, so the rows below never hear about it.
struct DiffSelectionDrag: ViewModifier {
    let path: String
    let side: DiffSide
    let line: Int?
    let onMultiLine: () -> Void

    /// Live only for the duration of one drag.
    ///
    /// `@GestureState`, not `@State`: SwiftUI resets it automatically when the
    /// gesture ends *or is cancelled*. Held in `@State` it survived a
    /// cancelled drag, and the next press on this cell then extended whatever
    /// selection happened to exist instead of starting a new one — a drag on
    /// line 40 after a cancelled drag could produce a 257-line range.
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        if let line {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(drag(from: line))
        } else {
            content
        }
    }

    private func drag(from line: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($dragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let workspace = WorkspaceModel.shared
                if workspace.lineSelection?.anchor != line
                    || workspace.lineSelection?.path != path
                    || workspace.lineSelection?.side != side {
                    workspace.beginLineSelection(path: path, side: side, line: line)
                }
                // `translation`, not `location`: location is measured from
                // this cell's own top, so pressing in the lower part of a cell
                // added that offset to every line computed from it and the
                // range came out one line long before the pointer had moved.
                let rows = Int((value.translation.height / DiffRowMetrics.height).rounded())
                workspace.extendLineSelection(path: path, side: side, to: line + rows)
            }
            .onEnded { _ in
                // A drag that covered more than one line opens the composer
                // itself; a plain click goes through the "+" button.
                if WorkspaceModel.shared.lineSelection?.isMultiLine == true { onMultiLine() }
            }
    }
}

extension View {
    /// Makes this row or cell the start of a gutter drag-selection.
    func diffSelectionDrag(path: String, side: DiffSide, line: Int?, onMultiLine: @escaping () -> Void) -> some View {
        modifier(DiffSelectionDrag(path: path, side: side, line: line, onMultiLine: onMultiLine))
    }
}

/// The selection the diff pane is currently showing, published once by the
/// pane instead of observed by every gutter cell.
private struct DiffLineSelectionKey: EnvironmentKey {
    static let defaultValue: WorkspaceModel.DiffLineSelection? = nil
}

extension EnvironmentValues {
    var diffLineSelection: WorkspaceModel.DiffLineSelection? {
        get { self[DiffLineSelectionKey.self] }
        set { self[DiffLineSelectionKey.self] = newValue }
    }
}

/// GitHub anchors a comment on a deletion to the old (LEFT) side and a
/// comment on an addition or context line to the new (RIGHT) side — the
/// side a line simply doesn't have is never the one a comment can attach to.
func diffCommentSide(for kind: DiffLineKind) -> DiffSide {
    kind == .deletion ? .left : .right
}

/// `Theme.addedBackground`/`removedBackground` (and their "Strong" word-diff
/// variants, used above) are tuned for a dark canvas — in a light window
/// they render as a jarring dark rectangle rather than the pale, familiar
/// diff tint every code host uses. `Theme.swift` is a shared contract this
/// track doesn't own, so the light-appearance correction lives here,
/// next to the only call sites that need it.
/// `Theme`'s diff tints now resolve per appearance themselves, so these
/// aliases stay only so the light/dark branches below keep reading
/// explicitly — there is one source of truth for the actual colors.
private enum DiffRowPalette {
    static let addedLight = Theme.addedBackground
    static let removedLight = Theme.removedBackground
    static let addedStrongLight = Theme.addedBackgroundStrong
    static let removedStrongLight = Theme.removedBackgroundStrong
}

/// Background tint for a diff row, given its kind and the active appearance.
func diffRowBackground(_ kind: DiffLineKind?, colorScheme: ColorScheme) -> Color {
    switch (kind, colorScheme) {
    case (.addition, .light): return DiffRowPalette.addedLight
    case (.addition, _): return Theme.addedBackground
    case (.deletion, .light): return DiffRowPalette.removedLight
    case (.deletion, _): return Theme.removedBackground
    case (.context, _), (nil, _): return Color.clear
    }
}

/// "This side has no line here" in the split view. It used to be
/// `Color.primary.opacity(0.04)` — the same wash inline discussion painted
/// itself with, so "someone commented here" and "this half is empty" were the
/// same rectangle. Inline discussion is a bordered card now, and this is a
/// deliberately flatter, greyer surface than any diff tint: absence, not an
/// unchanged line.
let diffEmptyHalfFill = Theme.dynamic(light: 0.91, 0.91, 0.93, dark: 0.14, 0.14, 0.16)

/// What VoiceOver reads for one diff line. A row is a stack of loose `Text`s,
/// so without this the cursor stops three times per line — once on a bare
/// "+" that announces nothing — and never says whether the line was added or
/// removed, which is the single most important fact about it.
func diffRowAccessibilityLabel(kind: DiffLineKind?, lineNumber: Int?, text: String?, facesContent: Bool = false) -> String {
    guard let kind, let text else {
        return facesContent ? "No line on this side" : "Blank"
    }
    let change: String
    switch kind {
    case .addition: change = "Added"
    case .deletion: change = "Removed"
    case .context: change = "Unchanged"
    }
    let position = lineNumber.map { "line \($0)" } ?? "no line number"
    let body = text.trimmingCharacters(in: .whitespaces)
    return body.isEmpty ? "\(change), \(position), empty line" : "\(change), \(position), \(body)"
}

/// Fixed geometry for a diff row, measured from the mono font rather than
/// guessed at. Row height has to land on a whole point: the fractional
/// `.padding(.vertical, 1.5)` these constants replace put every row on a
/// half-point boundary, where text renders soft.
enum DiffRowMetrics {
    /// Mirrors `Theme.monoFont`'s size. Held locally because the metrics
    /// below need an `NSFont` to measure and a `Font` cannot be measured.
    private static let pointSize: CGFloat = 12
    static let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)

    /// Every glyph in a monospaced face advances by the same amount, so one
    /// measurement sizes any line from its character count alone.
    static let advance: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    static let verticalPadding: CGFloat = 2
    static let height: CGFloat = (font.ascender - font.descender + font.leading).rounded(.up)
        + verticalPadding * 2

    static let gutterWidth: CGFloat = 40
    static let unifiedGutterWidth: CGFloat = 36
    static let markerWidth: CGFloat = 12
    static let trailingPadding: CGFloat = 8
    /// The single vertical `Divider` between the split view's two columns.
    static let splitDivider: CGFloat = 1

    static let splitChrome = gutterWidth + markerWidth + trailingPadding
    static let unifiedChrome = unifiedGutterWidth * 2 + markerWidth + trailingPadding

    /// Past this the line is minified or generated, and a pane wide enough to
    /// hold it has a horizontal scrollbar that is useless for every other
    /// file. Such a line is clipped at the pane's right edge instead.
    static let maxColumns = DiffText.maxMeasuredColumns
}

/// The one-row flash that marks where a jump landed.
///
/// Absent from the view tree unless this is the row that was jumped to. Built
/// unconditionally it added an overlay, a stack, two rectangles and two
/// modifiers to every row on screen, to draw nothing at all on 44 of them.
struct DiffJumpFlash: ViewModifier {
    let active: Bool
    var intensity: Double = 1

    func body(content: Content) -> some View {
        if active {
            content.overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                    // Brightest at the rail the eye is being sent to, rather
                    // than a flat band across a 1,400pt row.
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.02)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .opacity(intensity)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func diffJumpFlash(_ active: Bool, intensity: Double = 1) -> some View {
        modifier(DiffJumpFlash(active: active, intensity: intensity))
    }
}

/// How wide the diff pane draws, published by `DiffContainerView` and read by
/// every row.
///
/// With word wrap off a long line has to be reachable *somehow*: code that
/// runs off the right edge with no scroller is simply unreadable, and in
/// split view, where every line gets half the window, that is most of the
/// file. One width for the whole pane — not one per file — so the split
/// view's two columns land on the same x on every row of every file, and one
/// horizontal offset serves the lot.
struct DiffPaneLayout: Equatable {
    /// The width every code row takes when word wrap is off: the widest line
    /// in the open file, in points.
    ///
    /// Derived from a character count and the mono advance — never from a
    /// measurement of the pane. A width measured from the pane and then
    /// applied to the pane's own content is a layout cycle, and inside a
    /// `NavigationSplitView` that cycle reaches AppKit mid-constraint-pass
    /// and aborts the process.
    ///
    /// `nil` with wrap on: rows fill whatever they are given and wrap, and
    /// nothing scrolls sideways.
    var rowWidth: CGFloat?
    var wraps: Bool = true

    static func resolve(maxColumns: Int, split: Bool, wraps: Bool) -> DiffPaneLayout {
        guard !wraps else { return DiffPaneLayout(rowWidth: nil, wraps: true) }
        // Two columns of slack: the advance is measured from `NSFont`, and
        // SwiftUI's own resolution of `.monospaced` could round a hair wider.
        // Erring wide costs a little empty scroll; erring narrow clips the end
        // of the longest line in the file, which is the one line this
        // calculation exists to make reachable.
        let columns = Swift.min(maxColumns, DiffRowMetrics.maxColumns) + 2
        let code = CGFloat(columns) * DiffRowMetrics.advance
        let needed = split
            ? (DiffRowMetrics.splitChrome + code) * 2 + DiffRowMetrics.splitDivider
            : DiffRowMetrics.unifiedChrome + code
        return DiffPaneLayout(rowWidth: Swift.max(1, needed.rounded(.up)), wraps: false)
    }
}

private struct DiffPaneLayoutKey: EnvironmentKey {
    static let defaultValue = DiffPaneLayout()
}

extension EnvironmentValues {
    var diffPaneLayout: DiffPaneLayout {
        get { self[DiffPaneLayoutKey.self] }
        set { self[DiffPaneLayoutKey.self] = newValue }
    }
}

/// The diff pane's own coordinate space, so the pane can measure how far its
/// content has been scrolled sideways.
let diffPaneCoordinateSpace = "reviewrr.diffPane"

/// How far the pane's content is currently scrolled horizontally, published
/// once by `DiffContainerView`.
///
/// Deliberately *not* part of `DiffPaneLayout`: this changes on every frame
/// of a horizontal scroll, and every row reads the layout. Keeping it its own
/// key means only the handful of pinned blocks re-render while dragging.
/// Vertical scrolling never changes it, so scrolling down costs nothing.
private struct DiffPaneScrollXKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var diffPaneScrollX: CGFloat {
        get { self[DiffPaneScrollXKey.self] }
        set { self[DiffPaneScrollXKey.self] = newValue }
    }
}

struct DiffPaneScrollXPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Holds a full-width block — a file header, an inline thread, a composer, an
/// empty state — to the pane's *visible* width and keeps it there while the
/// code scrolls sideways underneath. Without this, a comment written about a
/// long line slides off screen the moment the reviewer scrolls right to read
/// the line it is about.
///
/// A real `.offset` rather than a `visualEffect`: the composer has a text
/// editor and buttons in it, and a visual effect moves what is drawn without
/// moving what is clickable.
/// Gives a diff row (or half of one) its width.
///
/// The distinction this exists to get right: inside a horizontally scrolling
/// pane the proposed width is *unbounded*, and `maxWidth:` under an unbounded
/// proposal resolves to the view's **ideal** width, not the maximum. So
/// `maxWidth: halfWidth` on a cell gave it the width of its own text while
/// the tint behind it kept the full half — the columns drifted apart and the
/// code bunched into the middle of the pane.
///
/// With wrap off there is an exact width and it must be applied exactly. With
/// wrap on there is none: the pane scrolls vertically only, the proposal is
/// bounded, and filling it is both correct and what wrapping needs.
struct DiffRowWidth: ViewModifier {
    let width: CGFloat?
    var alignment: Alignment = .topLeading

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: alignment)
        } else {
            content.frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

extension View {
    func diffRowWidth(_ width: CGFloat?, alignment: Alignment = .topLeading) -> some View {
        modifier(DiffRowWidth(width: width, alignment: alignment))
    }
}

/// Held a block to the pane's visible width and slid it back as the code
/// scrolled sideways. It is now a no-op, deliberately.
///
/// It set `.frame(width:)` from a measured viewport: the measurement was
/// published into state, the state set an explicit width, that width changed
/// what `NSHostingView` reports to `SplitViewChildController` as the column's
/// min and max size, and reporting it during AppKit's constraint pass
/// invalidates layout from inside layout — `abort()`, reproducibly, in the
/// field. A publish threshold damps a wobble but not a real resize, which is
/// why the crash survived one.
///
/// Kept as a no-op rather than deleted from thirteen call sites: the shape of
/// the pane is not what should churn while a crash is being fixed. These
/// blocks now scroll sideways with the code they annotate, which is what
/// every editor does anyway.
private struct DiffPanePinned: ViewModifier {
    func body(content: Content) -> some View { content }
}

extension View {
    func diffPanePinned(to layout: DiffPaneLayout) -> some View {
        modifier(DiffPanePinned())
    }
}

/// A cross-view "flash this row" signal: `DiffContainerView` sets it to the
/// scroll id of a `WorkspaceModel.pendingJump` target the instant the scroll
/// lands, then clears it a beat later under an explicit animation so the
/// destination visibly fades rather than snapping away. Lives here (rather
/// than as new `WorkspaceModel` state) because this track doesn't own
/// `ViewModels/`.
private struct FlashedDiffRowIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct FlashedDiffRowIntensityKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

extension EnvironmentValues {
    /// How strongly to light the flashed row: 1 on arrival, held lower
    /// while it is read, 0 once faded. Separate from the id so the fade is
    /// an animatable number rather than an id blinking out.
    var flashedDiffRowIntensity: Double {
        get { self[FlashedDiffRowIntensityKey.self] }
        set { self[FlashedDiffRowIntensityKey.self] = newValue }
    }

    var flashedDiffRowID: String? {
        get { self[FlashedDiffRowIDKey.self] }
        set { self[FlashedDiffRowIDKey.self] = newValue }
    }
}

/// Threads/drafts anchored at exactly this (path, line, side) — used by
/// both the split and unified row views to render inline discussion.
///
/// One dictionary lookup into `WorkspaceModel`'s anchor index rather than a
/// scan of every thread in the pull request, which is what these were: run
/// twice per line, for every line on screen, on every change to `AppModel`.
/// The index also anchors a thread that arrives with no `side` to RIGHT
/// (GitHub's own default), which the previous strict `$0.side == side` test
/// dropped — so such a thread showed in the split view and vanished in the
/// unified one.
@MainActor
func threadsAnchored(in model: AppModel, path: String, line: Int?, side: DiffSide) -> [ReviewThread] {
    WorkspaceModel.shared.inlineThreads(in: model.threads, path: path, line: line, side: side)
}

@MainActor
func draftsAnchored(in model: AppModel, path: String, line: Int?, side: DiffSide) -> [DraftComment] {
    WorkspaceModel.shared.inlineDrafts(in: model.draft.comments, path: path, line: line, side: side)
}
