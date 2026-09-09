import AppKit
import SwiftUI

/// The centre pane: the diff of the file the reviewer has open, and nothing
/// else.
///
/// It used to concatenate every changed file into one scroll. That is a fine
/// shape for a five-file pull request and the wrong one for six hundred: a
/// file had no scroll position of its own to remember, one horizontal offset
/// and one canvas width were shared by every file, "which file am I in" was a
/// guess computed from the offset, and restoring the reviewer's place after
/// any height change meant scrolling to an id inside a lazy stack whose
/// offscreen sections had unknown heights — approximate by construction, and
/// the reason a jump needed a sleep before it could land.
///
/// One file at a time makes all four of those questions arithmetic instead of
/// estimation: the open file *is* the selection, its scroll position is a
/// remembered row, its canvas is as wide as its own longest line, and a jump
/// scrolls within a bounded document. `docs/mvp-plan.md` specified this shape
/// ("file tabs") from the start.
struct DiffContainerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    @FocusState private var containerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set the instant a jump lands — the scroll motion already carries the
    /// "something moved" cue, so the flash itself needs no fade-in — then
    /// cleared a beat later inside an explicit, Reduce-Motion-aware
    /// transaction so it fades out instead of disappearing.
    @State private var flashedRowID: String?
    /// How strongly the landed row is lit: full on arrival, then held
    /// quieter while the reviewer reads it. Published to the rows through
    /// the environment alongside the id.
    @State private var flashIntensity: Double = 0
    /// The in-flight fade, held so the next jump replaces it instead of
    /// racing it.
    @State private var flashTask: Task<Void, Never>?
    /// The longest line in the pull request, in characters — what makes the
    /// pane's scrollable width wide enough to actually reach it.
    @State private var maxColumns = 0

    /// The files the pane draws: exactly the ones the sidebar's tree is
    /// showing, in the order it shows them.
    ///
    /// The pane used to render every changed file regardless of the filters,
    /// which put it at odds with both halves of its own workspace — the tree
    /// said "5 of 675", `j`/`k` stepped through those 5, and scrolling landed
    /// in the 670 the reviewer had just hidden. It also meant a minified
    /// bundle the reviewer had filtered out still set the pane's scrollable
    /// width for every other file.
    ///
    /// The list itself is derived once per filter change by `WorkspaceModel`
    /// alongside `orderedVisiblePaths`, so the two can never disagree — and
    /// so this pane stops building a dictionary of all 675 changed files,
    /// twice, on every evaluation of `body`.
    private var visibleFiles: [PRFile] { workspace.visibleFiles }

    /// The file on screen. Selection is the pane's contents now, so a
    /// selection the filters have hidden falls back to the first file the
    /// tree is showing rather than leaving the reviewer looking at nothing.
    private var openFile: PRFile? {
        // A lookup, not a scan: `body` reaches this and the visible list can
        // hold every changed file in the pull request.
        if let selected = model.selectedFile, let match = workspace.visibleFile(at: selected) {
            return match
        }
        return workspace.visibleFiles.first
    }

    private var openFileIndex: Int? {
        guard let path = openFile?.filename else { return nil }
        return workspace.orderedVisiblePaths.firstIndex(of: path)
    }

    /// Puts the review workspace through the three things a reviewer does to
    /// it continuously — scroll a file, step between files, jump a screenful
    /// at a time — with the frame probe running, and prints a report per
    /// phase. Returns immediately unless `REVIEWRR_PERF_SCROLL` asked for it.
    ///
    /// It lives on the container rather than on the open file's view because
    /// the file-stepping phase changes the selection, which would cancel a
    /// task belonging to the file being replaced — the benchmark would abort
    /// itself and start over.
    private func runScrollBenchmarkIfRequested(proxy: ScrollViewProxy) async {
        guard let seconds = PerfScroll.seconds else { return }
        // Benchmark the worst file in the pull request, not whichever one the
        // tree happened to select first. Deterministic, so the newly opened
        // file's own task finds itself already the target and gets on with it.
        if let worst = workspace.visibleFiles.max(by: { $0.changes < $1.changes })?.filename,
           worst != openFile?.filename {
            PerfProbe.log("opening the largest file for the scroll pass: \(worst)")
            model.selectedFile = worst
            // The pane has to open it before its rows can be scrolled.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await model.ensureParsed(worst)
        }
        guard let file = openFile, let parsed = model.parsedFiles[file.filename] else { return }
        let ids = (0..<parsed.hunks.count).map { diffHunkScrollID(path: file.filename, hunkIndex: $0) }
        PerfProbe.log("scroll pass: \(file.filename), \(ids.count) hunks, \(seconds)s per phase")
        guard ids.count > 2 else { return }
        // The first frame of a freshly opened file is a different measurement
        // from steady-state scrolling; let it land before resetting.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Phase one: what a fling on a trackpad asks for — a few new rows per
        // frame, sixty times a second, for the length of the file. This is the
        // number that answers "does it scroll smoothly".
        let rowIDs = (0..<parsed.hunks.count).flatMap { index in
            workspace.pairedRows(path: file.filename, hunkIndex: index, lines: parsed.hunks[index].lines)
                .map { diffRowScrollID(path: file.filename, hunkIndex: index, rowID: $0.id) }
        }
        if rowIDs.count > 8 {
            PerfProbe.reset()
            PerfProbe.mark("row scroll — \(file.displayName), \(rowIDs.count) rows, 3 rows/frame")
            let rowDeadline = Date().addingTimeInterval(seconds)
            var cursor = 0
            var step = 3
            while Date() < rowDeadline {
                proxy.scrollTo(rowIDs[cursor], anchor: .top)
                cursor += step
                if cursor >= rowIDs.count { cursor = rowIDs.count - 1; step = -3 }
                if cursor < 0 { cursor = 0; step = 3 }
                try? await Task.sleep(nanoseconds: PerfScroll.stepNanoseconds)
            }
            FileHandle.standardError.write(Data((PerfProbe.report() + "\n").utf8))
        }

        // Phase two: stepping through files the way `j`/`k` does. Not a
        // scroll, but the other thing a reviewer does continuously on this
        // screen, and it re-renders the sidebar tree as well as the pane.
        let paths = workspace.orderedVisiblePaths
        if paths.count > 4 {
            PerfProbe.reset()
            // A quarter of a second apart, not every frame: a switch has to
            // finish before the next one starts, or the report measures a
            // backlog of four selections coalesced into one pass rather than
            // what a keystroke actually costs.
            PerfProbe.mark("file stepping — \(paths.count) files, one every 250ms")
            let stepDeadline = Date().addingTimeInterval(seconds)
            var cursor = 0
            while Date() < stepDeadline {
                cursor = (cursor + 1) % paths.count
                model.selectedFile = paths[cursor]
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            FileHandle.standardError.write(Data((PerfProbe.report() + "\n").utf8))
            model.selectedFile = file.filename
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Phase three: a step per frame, each landing on the next hunk. Every
        // step materializes a screenful of rows it has never seen, which is
        // the ceiling on how much work a scroll can ask for.
        PerfProbe.reset()
        PerfProbe.mark("screen jump — \(file.displayName), \(ids.count) hunks")
        let deadline = Date().addingTimeInterval(seconds)
        var index = 0
        var direction = 1
        while Date() < deadline {
            proxy.scrollTo(ids[index], anchor: .top)
            index += direction
            if index >= ids.count { index = max(0, ids.count - 2); direction = -1 }
            if index < 0 { index = min(1, ids.count - 1); direction = 1 }
            try? await Task.sleep(nanoseconds: PerfScroll.stepNanoseconds)
        }
        FileHandle.standardError.write(Data((PerfProbe.report() + "\n").utf8))
    }

    private var layout: DiffPaneLayout {
        DiffPaneLayout.resolve(
            maxColumns: maxColumns,
            split: model.settings.diffLayout == .split,
            wraps: model.settings.wordWrap
        )
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("DiffContainerView", perfStart) }
        return ScrollViewReader { proxy in
            Group {
                surface(proxy: proxy)
            }
            .environment(\.flashedDiffRowID, flashedRowID)
            .environment(\.flashedDiffRowIntensity, flashIntensity)
            .environment(\.diffPaneLayout, layout)
            .background(Color(nsColor: .windowBackgroundColor))
            .safeAreaInset(edge: .top, spacing: 0) {
                DiffToolbar(workspace: workspace)
            }
            // Floating, rather than a second bar: it sits over the code, and
            // the content below reserves its height so the last line of a
            // file can always be scrolled clear of it.
            .overlay(alignment: .bottom) {
                if openFile != nil {
                    DiffNavigationBar(workspace: workspace)
                }
            }
            // Selecting a file no longer scrolls the pane to it — it *is* the
            // pane. `OpenFileDiffView` restores wherever the reviewer was in
            // that file the last time they had it open.
            // A selection and an open composer belong to the file they were
            // drawn in; carried across, a "Comment here" in the next file
            // could inherit a range from the last one.
            .onChange(of: model.selectedFile) { _, path in
                workspace.fileDidChange(to: path)
            }
            .onChange(of: workspace.pendingJump) { _, anchor in
                guard let anchor else { return }
                jump(to: anchor, proxy: proxy)
            }
            .task { await runScrollBenchmarkIfRequested(proxy: proxy) }
        }
        // A refresh keeps the diff on screen and readable; only the fact
        // that it is being refetched is new, so it gets a pill, not a scrim.
        .overlay(alignment: .top) { refreshPill }
        .focusable()
        .focusEffectDisabled(false)
        .focused($containerFocused)
        // The set comes from `Shortcut`, not a string typed out here: the
        // shortcuts sheet advertises those same letters, and a key that is
        // documented but not listened for is the defect this pane can
        // produce on its own.
        .onKeyPress(characters: CharacterSet(charactersIn: Shortcut.diffPaneKeyCharacters)) { press in
            // Every one of these is an unmodified letter, so each one is also
            // a character somebody might be trying to type. Asking a question
            // in the AI rail and reaching `?` opened the shortcuts sheet over
            // the half-written question; `u` in a comment draft flipped the
            // whole pane between split and unified.
            guard !Self.isTypingInTextControl else { return .ignored }
            // `?` is shift-slash on every layout the app supports, so
            // requiring an empty modifier set meant the one key that opens
            // the shortcuts sheet was the one key the sheet's own list
            // advertised and the pane ignored.
            let allowed: EventModifiers = press.characters == "?" ? .shift : []
            guard press.modifiers.subtracting(allowed).isEmpty else { return .ignored }
            handle(key: press.characters)
            return .handled
        }
        .task { containerFocused = true }
        // Focus used to be asserted exactly once, above, and never again —
        // so whatever took it kept it. The file filter could not hand the
        // keyboard back on Escape, and j/k could still be dead after the
        // shortcuts sheet or the ⌘K palette closed, with nothing on screen
        // to explain why.
        .onChange(of: workspace.diffFocusRequested) { _, requested in
            guard requested else { return }
            containerFocused = true
            workspace.diffFocusRequested = false
        }
        .onChange(of: workspace.showShortcuts) { _, presented in
            guard !presented else { return }
            requestFocusUnlessTyping()
        }
        .onChange(of: model.isCommandPalettePresented) { _, presented in
            guard !presented else { return }
            requestFocusUnlessTyping()
        }
        .task(id: model.reference?.key) {
            guard let reference = model.reference else { return }
            workspace.configureIfNeeded(prKey: reference.key, hiddenFileCategories: model.settings.hiddenFileCategories)
            workspace.refresh(files: model.files)
            refreshCanvasWidth()
        }
        .onChange(of: model.files) { _, newFiles in
            workspace.refresh(files: newFiles)
        }
        .onChange(of: workspace.searchText) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: workspace.sortOption) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: workspace.hiddenCategories) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: workspace.revealedPaths) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: model.diffColumnsByPath) { _, _ in refreshCanvasWidth() }
        .onChange(of: model.selectedFile) { _, _ in refreshCanvasWidth() }
        .onChange(of: workspace.orderedVisiblePaths) { _, _ in refreshCanvasWidth() }
        .sheet(isPresented: $workspace.showShortcuts) { ShortcutsSheet() }
    }

    /// Scans the parsed patches for the longest line, so the pane knows how
    /// far it has to be able to scroll before laying out a single row.
    /// Character counts, not measured text: a monospaced face advances the
    /// same width per glyph, and stopping at `DiffRowMetrics.maxColumns`
    /// bounds the cost on a pull request that contains a minified bundle.
    /// How wide this file's canvas has to be, from the measurement the parse
    /// pass already took.
    ///
    /// One file's longest line, not the whole pull request's: a minified
    /// bundle somewhere in the diff no longer sets the horizontal scroll for
    /// every other file, which is what made short-lined files render as
    /// coloured bands with the code off-screen to the left.
    private func refreshCanvasWidth() {
        maxColumns = openFile.flatMap { model.diffColumnsByPath[$0.filename] } ?? 0
    }

    /// Sends the pane to a cited line — from an AI citation, a finding, a
    /// comment anchor or the ⌘K palette.
    ///
    /// This used to be the most fragile path in the app: the destination
    /// might be folded away, filtered out, or simply unbuilt inside a lazy
    /// stack of six hundred sections, so it unfolded the file, rebuilt the
    /// tree, guessed at 50ms for the rows to exist, and fired two competing
    /// scrolls. With one file on screen, opening the file *is* the navigation,
    /// and the scroll that follows is inside one bounded document.
    private func jump(to anchor: DiffAnchor, proxy: ScrollViewProxy) {
        let isSameFile = model.selectedFile == anchor.path
        model.selectedFile = anchor.path
        workspace.consumePendingJump()

        Task { @MainActor in
            // The target file's patch may not be parsed yet — it is parsed
            // when opened — so resolving a line to a row waits for it. Well
            // under a millisecond for a typical file.
            await model.ensureParsed(anchor.path)
            guard let hunks = model.parsedFiles[anchor.path]?.hunks,
                  let identity = DiffNavigator.rowIdentity(forLine: anchor.line, side: anchor.side, hunks: hunks)
            else { return }
            let targetID = diffRowScrollID(path: anchor.path, hunkIndex: identity.hunkIndex, rowID: identity.rowID)

            // A jump inside the open file can scroll immediately. Switching
            // files rebuilds the pane, so the scroll waits one runloop turn —
            // one turn, not a guessed interval, because there is exactly one
            // file's worth of rows to build.
            if !isSameFile { await Task.yield() }
            withAnimation(reduceMotion || !isSameFile ? nil : Motion.smooth) {
                proxy.scrollTo(targetID, anchor: .center)
            }
            flashJump(to: targetID)
        }
    }

    /// Split out of `body`: the pane's builder had grown past what the type
    /// checker will infer in one expression.
    @ViewBuilder
    private func surface(proxy: ScrollViewProxy) -> some View {
        if model.pullRequest != nil, model.files.isEmpty, !model.isLoading {
            EmptyStateView(
                systemImage: "checkmark.seal",
                title: "No changes to review",
                message: "This pull request has no file diffs."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.pullRequest != nil, visibleFiles.isEmpty, !model.files.isEmpty, !model.isLoading {
            filteredOutState
        } else if let file = openFile {
            openFileSurface(file: file, proxy: proxy)
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: "No file open",
                message: "Choose a file in the sidebar, or press j to start at the first one."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The pane honours the tree's filters, so filtering everything out has
    /// to say so here too — an empty pane with a full pull request behind it
    /// would otherwise read as a failure to load.
    private var filteredOutState: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No files match",
                message: "Every changed file is hidden by the current search or file-type filters."
            )
            Button("Clear filters") {
                workspace.searchText = ""
                workspace.hiddenCategories = []
            }
            .buttonStyle(.reviewrrSecondary)
            .help("Show every changed file again")
            .accessibilityLabel("Clear the search and file-type filters")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One file, one scroller. The horizontal canvas is as wide as *this*
    /// file's longest line, so reading a long line no longer leaves every
    /// short-lined file scrolled off to the left showing coloured bands and
    /// no code.
    private func openFileSurface(file: PRFile, proxy: ScrollViewProxy) -> some View {
        OpenFileDiffView(file: file, proxy: proxy)
            .id(file.filename)
            // Nothing measures the pane any more. The width the rows use
            // comes from the file's own longest line, and the blocks that
            // used to hold themselves against the viewport scroll with the
            // code instead — because measuring this subtree and then sizing
            // it from that measurement is what crashed it.
    }

    /// The animation belongs to the pill, not to the pane: wrapping the whole
    /// container in `.motion(value: isLoading)` animated every layout change
    /// beneath it the instant a load finished — which is exactly when the
    /// diff first appears, and is what read as the code sliding in.
    @ViewBuilder
    private var refreshPill: some View {
        if model.isLoading {
            LoadingOverlay(message: "Refreshing this pull request…")
                .motion(Motion.smooth, value: model.isLoading)
        }
    }

    /// Lights the row a jump landed on, then fades it.
    ///
    /// One task, replaced on each jump rather than added to: holding `n`
    /// spawned an unstructured task per press, each sleeping 900ms and then
    /// re-checking whether it was still the current one. They cancelled each
    /// other out by luck rather than by construction, and a fast reviewer
    /// could have a dozen in flight.
    ///
    /// Two stages, because a binary on/off flash reads as a rendering
    /// glitch rather than a cue: it lands at full strength — the scroll
    /// already told the eye something moved, so there is nothing to fade
    /// *in* — settles to a quieter hold that survives a moment of reading,
    /// then fades out. Reduce Motion collapses this to a plain on and off.
    private func flashJump(to rowID: String) {
        flashTask?.cancel()
        flashedRowID = rowID
        flashIntensity = 1

        flashTask = Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, flashedRowID == rowID else { return }
                withAnimation(Motion.smooth) { flashIntensity = 0.55 }
            }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 900 : 1_100))
            guard !Task.isCancelled, flashedRowID == rowID else { return }
            withAnimation(reduceMotion ? nil : Motion.smooth) {
                flashedRowID = nil
                flashIntensity = 0
            }
        }
    }

    /// Takes the keyboard back after a modal surface closes — unless the
    /// reviewer was mid-sentence in a composer when they opened it, in
    /// which case the caret is theirs to keep. The responder check is the
    /// best answer available at this moment: the sheet's window is on its
    /// way out, so this can read the restored responder or the tail of the
    /// dismissal, and being wrong costs a click rather than any text.
    private func requestFocusUnlessTyping() {
        guard !Self.isTypingInTextControl else { return }
        workspace.diffFocusRequested = true
    }

    /// Whether the keyboard currently belongs to something being typed into.
    ///
    /// SwiftUI focus and AppKit's first responder are two different things,
    /// and this pane holds SwiftUI focus for as long as it is on screen — so
    /// `onKeyPress` still fires while the caret is in the AI composer, a
    /// comment draft or the file filter. The responder is what actually
    /// decides who a keystroke was meant for, so it is what this asks.
    ///
    /// A SwiftUI `TextField` answers as its field editor, which is an
    /// `NSTextView`, so both cases are the same check.
    private static var isTypingInTextControl: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let text = responder as? NSText { return text.isEditable }
        return responder is NSTextField
    }

    private func handle(key: String) {
        switch key {
        case "j": moveFile(1)
        case "k": moveFile(-1)
        case "n": moveHunk(1)
        case "p": moveHunk(-1)
        case "v":
            guard let path = openFile?.filename else { return }
            model.markViewedAndAdvance(path)
        case "u":
            model.settings.diffLayout = model.settings.diffLayout == .split ? .unified : .split
            model.persistSettings()
        case "/": workspace.searchFieldFocusRequested = true
        case "?": workspace.showShortcuts = true
        default: break
        }
    }

    private func moveFile(_ delta: Int) {
        guard let next = DiffNavigator.adjacentFile(to: model.selectedFile, in: workspace.orderedVisiblePaths, delta: delta) else { return }
        model.selectedFile = next
    }

    /// `n`/`p` step through the currently-selected file's hunks (sharing
    /// position with `DiffToolbar`'s arrow buttons via `WorkspaceModel`);
    /// once past the last hunk they carry over to the next/previous file
    /// so a reviewer never has to reach for `j`/`k` mid-review.
    private func moveHunk(_ delta: Int) {
        Task { await model.stepChange(delta) }
    }
}

/// One file's diff: a header that does not scroll, then the hunks.
///
/// The header sits *outside* the scroll view rather than pinned inside it,
/// which removes an entire class of problem the pinned-section-header
/// arrangement had — no sideways shear against the code, no per-frame
/// preference pass to keep it in place, and no guessing whether a pinned
/// header is what the reviewer is looking at.
private struct OpenFileDiffView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    let file: PRFile
    let proxy: ScrollViewProxy

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.diffPaneLayout) private var layout
    /// A stress run is here to render the biggest file in the pull request,
    /// so it must not stop at the "large file — show anyway?" guard.
    @State private var showAnyway = StressFixture.isEnabled
    /// The row at the top of the pane, mirrored into `WorkspaceModel` so
    /// coming back to this file lands where the reviewer left it.
    ///
    /// Held in a reference box rather than `@State`, and this is a scrolling
    /// cost rather than a style choice: `scrollPosition(id:)` writes its
    /// binding on *every frame* of a scroll, and a `@State` write re-evaluates
    /// this view's body — which rebuilds the whole `LazyVStack` builder, every
    /// realized row with it, on every frame. Nothing on screen depends on the
    /// value while scrolling; it is read once, when a file opens. `restoreTick`
    /// is the only thing that has to invalidate, and only then.
    @State private var anchorBox = ScrollAnchorBox()
    @State private var restoreTick = 0

    /// Non-observable on purpose — see `anchorBox`.
    private final class ScrollAnchorBox {
        var id: String?
    }

    private var topRowID: Binding<String?> {
        Binding(
            get: { [anchorBox] in _ = restoreTick; return anchorBox.id },
            set: { [anchorBox] newValue in
                anchorBox.id = newValue
                guard let newValue else { return }
                workspace.setScrollAnchor(newValue, for: file.filename)
            }
        )
    }

    /// The file's rows, flat: every child carries an id, so
    /// `scrollPosition(id:)` reports and restores the reviewer's place at the
    /// row they were reading rather than at whichever hunk contained it.
    private var rowStack: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsed.hunks.enumerated()), id: \.offset) { index, hunk in
                GapSeparatorView(file: file, hunkIndex: index, hunks: parsed.hunks, language: language)
                    .id(diffGapScrollID(path: file.filename, hunkIndex: index))
                DiffHunkHeaderView(file: file, hunkIndex: index, hunk: hunk)
                    .id(diffHunkScrollID(path: file.filename, hunkIndex: index))
                if !workspace.isHunkCollapsed(path: file.filename, hunkIndex: index) {
                    hunkRows(index: index, hunk: hunk)
                }
            }
        }
        .scrollTargetLayout()
        // Published once for the whole pane. Every gutter cell used to
        // subscribe to `WorkspaceModel` to answer "am I selected?", so any
        // change to any of its published state re-rendered all ninety of them.
        .environment(\.diffLineSelection, workspace.lineSelection)
        // The stack itself gets the row width, so every child — rows, hunk
        // headers, gap bands — starts on the same left edge and ends on the
        // same right one. Left implicit, each child negotiated its own width
        // against an unbounded proposal and they disagreed.
        .diffRowWidth(layout.rowWidth, alignment: .topLeading)
        // Room for the floating navigation bar. Without it the bar covers the
        // end of every file permanently, with no way to scroll past it.
        .padding(.bottom, DiffNavigationBar.reservedHeight)
    }

    @ViewBuilder
    private func hunkRows(index: Int, hunk: DiffHunk) -> some View {
        if model.settings.diffLayout == .split {
            // Memoized: pairing a 700-line file's hunks used to run in full on
            // every evaluation of this view's `body`.
            ForEach(workspace.pairedRows(path: file.filename, hunkIndex: index, lines: hunk.lines)) { row in
                let scrollID = diffRowScrollID(path: file.filename, hunkIndex: index, rowID: row.id)
                SplitDiffRowView(
                    row: row, filename: file.filename, language: language,
                    wordWrap: model.settings.wordWrap, scrollID: scrollID
                )
                .id(scrollID)
            }
        } else {
            UnifiedHunkRows(
                filename: file.filename, hunkIndex: index, hunk: hunk,
                language: language, wordWrap: model.settings.wordWrap
            )
        }
    }

    /// Tells the workspace which lines a comment can attach to, per side, as
    /// the contiguous runs each hunk provides.
    ///
    /// A drag is then held inside the run it started in. Without this a drag
    /// past the end of a hunk selected line numbers that are not in the diff,
    /// and GitHub answers that by rejecting the whole review rather than the
    /// one comment.
    private func publishSelectableRuns() {
        let hunks = model.parsedFiles[file.filename]?.hunks ?? []
        for side in DiffSide.allCases {
            var runs: [ClosedRange<Int>] = []
            for hunk in hunks {
                let numbers = hunk.lines.compactMap { side == .left ? $0.oldLineNumber : $0.newLineNumber }
                guard let low = numbers.min(), let high = numbers.max() else { continue }
                runs.append(low...high)
            }
            workspace.setSelectableRuns(runs, path: file.filename, side: side)
        }
    }

    private var classification: FileClassification {
        workspace.classifications[file.filename] ?? FileClassifier.classify(file)
    }
    private var parsed: ParsedFile { model.parsedFiles[file.filename] ?? ParsedFile(filename: file.filename, hunks: []) }
    private var language: String { SyntaxHighlighter.language(forPath: file.filename) }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("OpenFileDiffView", perfStart) }
        return VStack(spacing: 0) {
            DiffFileHeaderView(file: file, classification: classification, hunkCount: parsed.hunks.count)
            content
        }
        .task(id: file.filename) {
            await model.ensureParsed(file.filename)
            publishSelectableRuns()
            // The files j and k would reach next, so stepping through a
            // review does not wait on a parse it could have done already.
            model.prefetchNeighbours(of: file.filename, in: workspace.orderedVisiblePaths)
        }
    }

    /// `isBinaryOrEmpty` is strictly `patch == nil`. A patch that is present
    /// but carries no hunk header parses to zero hunks, which used to render
    /// as a file header, fourteen points of nothing, and the next header —
    /// so the same empty state covers both.
    @ViewBuilder
    private var content: some View {
        if model.parsedFiles[file.filename] == nil && !classification.isBinaryOrEmpty {
            // Patches are parsed when their file is opened. It takes well
            // under a millisecond for a typical file, but "no diff yet" and
            // "this file has no diff" must never look the same.
            VStack(spacing: Theme.Space.s) {
                ActivityDot(color: Theme.accent, size: 6)
                Text("Preparing diff…")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Preparing the diff for \(file.displayName)")
        } else if classification.isBinaryOrEmpty || parsed.hunks.isEmpty {
            emptyPatchView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if classification.isLargeFile && !showAnyway {
            largeFileGuard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            scroller
        }
    }

    /// Vertical only when the reviewer has word wrap on, both axes when they
    /// don't.
    ///
    /// It matters beyond the scrolling: a two-axis scroll view proposes an
    /// unbounded width to its content, and every `maxWidth: .infinity` inside
    /// then collapses to an ideal width instead of filling. Wrapping needs a
    /// bounded proposal to wrap against, so with wrap on the pane must not
    /// scroll sideways at all.
    @ViewBuilder
    private var scroller: some View {
        if model.settings.wordWrap {
            ScrollView(.vertical) { rowStack }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .scrollPosition(id: topRowID, anchor: .top)
                .task(id: file.filename) { await restoreAnchor() }
        } else {
            wideScroller
        }
    }

    private var wideScroller: some View {
        ScrollView([.vertical, .horizontal]) { rowStack }
        // The reviewer's place in this file, kept as the identity of the row
        // that was at the top rather than as a point offset: the content
        // height moves with the layout, the wrap setting, revealed context and
        // arriving comments, so an offset would restore somewhere else.
        // `minWidth: 0` is the other half of the crash, and the half a
        // publish-threshold cannot reach. A row framed to the widest line —
        // up to ~15,000pt — otherwise propagates out as this subtree's
        // *minimum* size; `NSHostingView` reports that to
        // `SplitViewChildController`, which resizes the column, which
        // re-measures the viewport, which produces a new row width. That is
        // the loop in the crash log, and it invalidates layout from inside
        // `updateConstraintsForSubtree`. A scroll view clips: its content's
        // width is nobody else's minimum.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .scrollPosition(id: topRowID, anchor: .top)
        .task(id: file.filename) { await restoreAnchor() }
    }

    /// Puts the reviewer back where they were in this file.
    ///
    /// The rows have to exist before a position can be set, hence the yield;
    /// `restoreTick` is what makes the binding's getter run again so
    /// `scrollPosition` sees the restored value.
    private func restoreAnchor() async {
        await Task.yield()
        anchorBox.id = workspace.scrollAnchor(for: file.filename)
        restoreTick += 1
    }

    private var emptyPatchView: some View {
        let (icon, title, message) = emptyPatchDescription
        return EmptyStateView(systemImage: icon, title: title, message: message)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .diffPanePinned(to: layout)
    }

    private var emptyPatchDescription: (String, String, String?) {
        switch file.status {
        case .removed:
            return ("trash", "File deleted", "GitHub didn't include a line-level diff for this removed file.")
        case .renamed where file.additions == 0 && file.deletions == 0:
            let previous = file.previousFilename ?? "its previous path"
            return ("arrow.right", "Renamed, no content changes", "\(previous) → \(file.filename)")
        default:
            return ("doc.questionmark", "Binary or too large to display", "GitHub didn't return a line-level diff for this file.")
        }
    }

    private var largeFileGuard: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Large file — \(file.changes) changed lines")
                .font(.headline)
            Text("Rendering the full diff immediately can be slow. Show it anyway?")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show anyway") { showAnyway = true }
                .buttonStyle(.reviewrrPrimary)
        }
        .frame(maxWidth: 420)
        .padding(20)
        .frame(maxWidth: .infinity)
        .diffPanePinned(to: layout)
    }

}

/// One hunk's header: what lines it covers, and the control that folds it.
///
/// Collapsing lives here now rather than on whole files. Folding a file was
/// review *progress* wearing a reading control's clothes — a reviewer could
/// not quiet a formatting hunk without claiming to have read the file, nor
/// re-read a file they had marked viewed without appearing to un-review it.
/// A hunk is the right unit for "I have seen enough of this".
private struct DiffHunkHeaderView: View {
    @ObservedObject private var workspace = WorkspaceModel.shared
    let file: PRFile
    let hunkIndex: Int
    let hunk: DiffHunk

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.diffPaneLayout) private var layout

    private var collapsed: Bool {
        workspace.isHunkCollapsed(path: file.filename, hunkIndex: hunkIndex)
    }

    private var lineSummary: String {
        "+\(hunk.additions) −\(hunk.deletions)"
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("DiffHunkHeaderView", perfStart) }
        return Button {
            withAnimation(reduceMotion ? nil : Motion.snappy) {
                workspace.toggleHunk(path: file.filename, hunkIndex: hunkIndex)
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(hunk.header.isEmpty
                     ? "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
                     : hunk.header)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.s)
                Text(lineSummary)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .diffRowWidth(layout.rowWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.hunkSeparator)
        .diffPanePinned(to: layout)
        .help(collapsed ? "Expand this hunk" : "Collapse this hunk")
        .accessibilityLabel("Hunk \(hunkIndex + 1), from line \(hunk.newStart), \(lineSummary)")
        .accessibilityHint(collapsed ? "Expand" : "Collapse")
        .accessibilityAddTraits(.isButton)
    }
}

/// The open file's header. It does not scroll and it does not fold the file:
/// the pane holds one file, so "which file am I in" is answered by the header
/// being there, and folding belongs to hunks.
private struct DiffFileHeaderView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    let file: PRFile
    let classification: FileClassification
    let hunkCount: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.diffPaneLayout) private var layout
    private var viewed: Bool { model.draft.viewedFiles.contains(file.filename) }

    /// Where this file sits in the review — the orientation a single long
    /// scroll gave through raw position and a one-file pane has to say out
    /// loud.
    private var positionLabel: String? {
        guard let index = workspace.visibleIndexByPath[file.filename] else { return nil }
        return "\(index + 1) of \(workspace.orderedVisiblePaths.count)"
    }

    private var allHunksCollapsed: Bool {
        hunkCount > 0 && (0..<hunkCount).allSatisfy {
            workspace.isHunkCollapsed(path: file.filename, hunkIndex: $0)
        }
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("DiffFileHeaderView", perfStart) }
        return HStack(spacing: 8) {
            Text(file.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.filename)
                .accessibilityLabel(file.filename)
                .layoutPriority(1)
            if classification.isFormattingOnly {
                Image(systemName: "textformat.size")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Formatting-only change")
                    .accessibilityLabel("Formatting-only change")
            }
            CategoryChip(category: classification.category)
                .help("Classified as \(classification.category.label.lowercased())")
            Spacer(minLength: 8)
            if let positionLabel {
                Text(positionLabel)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .help("File \(positionLabel) in the filtered file list")
                    .accessibilityLabel("File \(positionLabel)")
            }
            DiffStatCounts(additions: file.additions, deletions: file.deletions)
            if hunkCount > 1 {
                Button {
                    workspace.setHunks(collapsed: !allHunksCollapsed, path: file.filename, count: hunkCount)
                } label: {
                    Image(systemName: allHunksCollapsed ? "chevron.down.2" : "chevron.up.2")
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
                .help(allHunksCollapsed ? "Expand every hunk in this file" : "Collapse every hunk in this file")
                .accessibilityLabel(allHunksCollapsed ? "Expand every hunk" : "Collapse every hunk")
            }
            Button {
                model.toggleViewed(file.filename)
            } label: {
                Label { Text(viewed ? "Viewed" : "Mark viewed") } icon: { ViewedGlyph(viewed: viewed) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewed ? DiffTextColor.added(colorScheme) : .secondary)
            .motion(Motion.snappy, value: viewed)
            .accessibilityLabel(viewed ? "Mark \(file.displayName) as not viewed" : "Mark \(file.displayName) as viewed")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.barMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button {
                model.toggleViewed(file.filename)
            } label: {
                Label(viewed ? "Mark as not viewed" : "Mark as viewed", systemImage: viewed ? "circle" : "checkmark.circle")
            }
            if hunkCount > 1 {
                Button {
                    workspace.setHunks(collapsed: !allHunksCollapsed, path: file.filename, count: hunkCount)
                } label: {
                    Label(
                        allHunksCollapsed ? "Expand all hunks" : "Collapse all hunks",
                        systemImage: allHunksCollapsed ? "chevron.down.2" : "chevron.up.2"
                    )
                }
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.filename, forType: .string)
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            if let url = githubBlobURL(model: model, path: file.filename) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
            }
        }
        // The header names the file the reviewer is looking at; it has no
        // business sliding off to the left when they scroll right to read a
        // long line, so it is held to the visible width and stays there.
        .diffPanePinned(to: layout)
    }
}

private struct GapSeparatorView: View {
    @EnvironmentObject var model: AppModel
    let file: PRFile
    let hunkIndex: Int
    let hunks: [DiffHunk]
    let language: String
    @Environment(\.diffPaneLayout) private var layout
    @State private var revealedTop = 0
    @State private var revealedBottom = 0

    /// Lines revealed per click — small enough that "a bit more context"
    /// stays a lightweight, reversible-feeling action.
    private static let step = 20

    private var gapCount: Int { DiffParser.gapSize(beforeHunkIndex: hunkIndex, hunks: hunks) }
    private var expandedLines: [String]? { model.expandedContextLines[file.filename] }

    var body: some View {
        if gapCount > 0 {
            if let expandedLines {
                expandedContent(fullLines: expandedLines)
            } else {
                Button {
                    Task { await model.expandContext(for: file.filename) }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                        Text("Show \(gapCount) unmodified line\(gapCount == 1 ? "" : "s")")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .diffRowWidth(layout.rowWidth, alignment: .leading)
                .background(Theme.hunkSeparator)
                .help("Fetch the unchanged lines between these hunks and show them")
                .accessibilityLabel("Show \(gapCount) unmodified line\(gapCount == 1 ? "" : "s")")
                .accessibilityHint("Loads the surrounding code from GitHub")
            }
        }
    }

    @ViewBuilder
    private func expandedContent(fullLines: [String]) -> some View {
        let allGapLines = DiffParser.gapLines(beforeHunkIndex: hunkIndex, hunks: hunks, fullLines: fullLines)
        let hiddenCount = max(0, allGapLines.count - revealedTop - revealedBottom)

        VStack(spacing: 0) {
            if revealedTop > 0 {
                gapRows(Array(allGapLines.prefix(revealedTop)))
                    .motionTransition(.opacity)
            }
            if hiddenCount > 0 {
                expansionControls(hiddenCount: hiddenCount, total: allGapLines.count)
            }
            if revealedBottom > 0 {
                gapRows(Array(allGapLines.suffix(revealedBottom)))
                    .motionTransition(.opacity)
            }
        }
        .motion(Motion.snappy, value: revealedTop)
        .motion(Motion.snappy, value: revealedBottom)
    }

    /// Expanded context follows the diff layout the reviewer chose. It used
    /// to render as split rows unconditionally, which dropped a two-column
    /// block into the middle of a unified diff.
    @ViewBuilder
    private func gapRows(_ lines: [DiffLine]) -> some View {
        if model.settings.diffLayout == .split {
            ForEach(lines.pairedForSplitView()) { row in
                SplitDiffRowView(row: row, filename: file.filename, language: language, wordWrap: model.settings.wordWrap)
            }
        } else {
            UnifiedRows(
                filename: file.filename, lines: lines, language: language,
                wordWrap: model.settings.wordWrap
            )
        }
    }

    private func expansionControls(hiddenCount: Int, total: Int) -> some View {
        HStack(spacing: 14) {
            Button {
                revealedTop = min(revealedTop + Self.step, total - revealedBottom)
            } label: {
                Label("\(min(Self.step, hiddenCount)) more above", systemImage: "arrow.up.to.line.compact")
            }
            .accessibilityLabel("Show \(min(Self.step, hiddenCount)) more lines above")

            Button {
                revealedBottom = min(revealedBottom + Self.step, total - revealedTop)
            } label: {
                Label("\(min(Self.step, hiddenCount)) more below", systemImage: "arrow.down.to.line.compact")
            }
            .accessibilityLabel("Show \(min(Self.step, hiddenCount)) more lines below")

            Spacer()

            Button("Expand all \(hiddenCount)") {
                revealedTop = total
                revealedBottom = 0
            }
            .accessibilityLabel("Expand all \(hiddenCount) remaining lines")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.hunkSeparator)
        .diffPanePinned(to: layout)
    }
}

struct SplitDiffRowView: View {
    @EnvironmentObject var model: AppModel
    let row: SplitDiffRow
    let filename: String
    let language: String
    var wordWrap: Bool = false
    var scrollID: String = ""
    @Environment(\.flashedDiffRowID) private var flashedRowID
    @Environment(\.flashedDiffRowIntensity) private var flashIntensity
    @Environment(\.diffPaneLayout) private var layout
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var workspace = WorkspaceModel.shared

    private var isFlashed: Bool { !scrollID.isEmpty && scrollID == flashedRowID }

    /// The two columns split the row evenly, minus the rule between them —
    /// computed rather than left to `maxWidth: .infinity` so the fills behind
    /// the row land on exactly the same boundary the content does.
    ///
    /// `nil` with word wrap on: there is no fixed row width then, so each half
    /// takes an equal share of whatever the pane offers.
    private var halfWidth: CGFloat? {
        layout.rowWidth.map { max(1, ($0 - DiffRowMetrics.splitDivider) / 2) }
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("SplitDiffRowView", perfStart) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                DiffCellView(
                    line: row.left, language: language, side: .left, filename: filename,
                    wordDiffAgainst: row.right?.displayText, wordDiffAgainstID: row.right?.id, wordWrap: wordWrap,
                    facesContent: row.right != nil, width: halfWidth
                ) { openComposer(side: .left) }
                // The rule between the columns is drawn in `rowFills`, where
                // the height is definite and it can run the whole row; here
                // it only has to reserve its point of width.
                Color.clear.frame(width: DiffRowMetrics.splitDivider)
                DiffCellView(
                    line: row.right, language: language, side: .right, filename: filename,
                    wordDiffAgainst: row.left?.displayText, wordDiffAgainstID: row.left?.id, wordWrap: wordWrap,
                    facesContent: row.left != nil, width: halfWidth
                ) { openComposer(side: .right) }
            }
            .diffRowWidth(layout.rowWidth, alignment: .topLeading)
            // The tints are painted as one layer behind the whole row rather
            // than per cell. A cell only ever knows its own content's height,
            // so when one side wrapped to three lines the other side's tint
            // stopped after one — and a pure add/delete row was a stripe of
            // colour with a white notch in it.
            .background(alignment: .leading) { rowFills }
            // Present in the tree only on the row that was jumped to — see
            // `DiffJumpFlash`. `allowsHitTesting(false)` lives in there too,
            // because a `Color` overlay stays hit-testable at zero opacity and
            // the old always-on version quietly ate the hover-to-comment "+"
            // and the row's context menu on every row it had ever flashed.
            .diffJumpFlash(isFlashed, intensity: flashIntensity)

            // Skipped wholesale on a row with nothing attached, which is
            // almost every row: two `ForEach` nodes per row exist to iterate
            // two empty arrays otherwise.
            if !threadsForRow.isEmpty || !draftsForRow.isEmpty {
                ForEach(threadsForRow) { thread in
                    ThreadView(thread: thread)
                        .diffPanePinned(to: layout)
                }
                ForEach(draftsForRow) { comment in
                    DraftCommentRow(comment: comment)
                        .diffPanePinned(to: layout)
                }
            }
            // The composer belongs to the *last* line of the range, not to the
            // row that was clicked, so the box is always below the code it is
            // about rather than splitting it. Each row asks whether it is that
            // line; `WorkspaceModel` holds the answer because the row that
            // opened the composer is often not the row that shows it.
            if let side = composerSide, let lineNumber = lineNumber(for: side) {
                CommentComposer(filename: filename, line: lineNumber, side: side) {
                    workspace.closeComposer()
                }
            }
        }
    }

    private var rowFills: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(fill(for: row.left, facing: row.right != nil))
                .diffRowWidth(halfWidth)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: DiffRowMetrics.splitDivider)
            Rectangle()
                .fill(fill(for: row.right, facing: row.left != nil))
        }
    }

    private func lineNumber(for side: DiffSide) -> Int? {
        side == .left ? row.left?.oldLineNumber : row.right?.newLineNumber
    }

    /// Which side, if either, has the composer open on one of this row's
    /// lines. A plain check rather than a `ForEach` over both sides: the
    /// `ForEach` put a list node and two conditional nodes into every row on
    /// screen to render nothing on all but one of them.
    private var composerSide: DiffSide? {
        for side in DiffSide.allCases {
            if let lineNumber = lineNumber(for: side),
               workspace.isComposerOpen(path: filename, side: side, line: lineNumber) {
                return side
            }
        }
        return nil
    }

    private func openComposer(side: DiffSide) {
        guard let lineNumber = lineNumber(for: side) else { return }
        workspace.openComposer(path: filename, side: side, line: lineNumber)
    }

    private func fill(for line: DiffLine?, facing: Bool) -> Color {
        if line == nil && facing { return diffEmptyHalfFill }
        return diffRowBackground(line?.kind, colorScheme: colorScheme)
    }

    /// Two dictionary lookups, one per half of the row. This used to scan
    /// every thread in the pull request — per visible row, on every
    /// evaluation of `body`, which `@EnvironmentObject var model` makes any
    /// change at all to `AppModel`.
    private var threadsForRow: [ReviewThread] {
        let workspace = WorkspaceModel.shared
        let left = workspace.inlineThreads(in: model.threads, path: filename, line: row.left?.oldLineNumber, side: .left)
        let right = workspace.inlineThreads(in: model.threads, path: filename, line: row.right?.newLineNumber, side: .right)
        return left.isEmpty ? right : (right.isEmpty ? left : left + right)
    }

    private var draftsForRow: [DraftComment] {
        let workspace = WorkspaceModel.shared
        let comments = model.draft.comments
        let left = workspace.inlineDrafts(in: comments, path: filename, line: row.left?.oldLineNumber, side: .left)
        let right = workspace.inlineDrafts(in: comments, path: filename, line: row.right?.newLineNumber, side: .right)
        return left.isEmpty ? right : (right.isEmpty ? left : left + right)
    }
}

private struct DiffCellView: View {
    let line: DiffLine?
    let language: String
    let side: DiffSide
    let filename: String
    let wordDiffAgainst: String?
    var wordDiffAgainstID: Int?
    let wordWrap: Bool
    /// True when this half is empty but the other half has a line — the
    /// deleted-here/added-there case. A blank cell next to a tinted one reads
    /// as "the file is empty here"; the grey `diffEmptyHalfFill` behind it
    /// reads as "this side has nothing to show", which is what happened.
    var facesContent: Bool = false
    /// Half the row, handed down rather than taken from the layout so both
    /// cells and the fills behind them agree to the point. `nil` with word
    /// wrap on, where the row has no fixed width to halve.
    let width: CGFloat?
    let onComment: () -> Void
    @State private var hovering = false

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("DiffCellView", perfStart) }
        return HStack(alignment: .top, spacing: 0) {
            DiffLineGutter(
                number: lineNumber,
                showCommentAffordance: hovering && line != nil,
                selectionTarget: (path: filename, side: side),
                onComment: onComment
            )
            // On the gutter, not the cell: a drag across the code column
            // selects nothing, as on GitHub. One per half of the row, because
            // the two halves select different lines on different sides.
            .diffSelectionDrag(path: filename, side: side, line: lineNumber, onMultiLine: onComment)

            Text(marker)
                // Without the mono font this placeholder inherited 13pt body
                // and stood about 1.7pt taller than a code line, so every
                // pure add or delete row was fractionally taller than the
                // context rows around it.
                .font(Theme.monoFont)
                .foregroundStyle(.secondary)
                .frame(width: DiffRowMetrics.markerWidth)

            Group {
                if let line {
                    HighlightedCodeText(
                        filename: filename, lineID: line.id, side: side, text: line.displayText,
                        language: language, wordDiffAgainst: wordDiffAgainst, wordWrap: wordWrap
                    )
                } else {
                    Text(" ")
                        .font(Theme.monoFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.trailing, DiffRowMetrics.trailingPadding)
        }
        .padding(.vertical, DiffRowMetrics.verticalPadding)
        .diffRowWidth(width)
        .frame(minHeight: DiffRowMetrics.height, alignment: .topLeading)
        // The cell paints nothing of its own now, so it needs a shape to be
        // hovered and right-clicked over.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let line {
                Button("Comment here", systemImage: "bubble.left") { onComment() }
                Button("Copy line", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    // The original text, tabs and all — what the reviewer
                    // pastes should match the file, not the rendering.
                    NSPasteboard.general.setString(line.text, forType: .string)
                }
            }
        }
        // One VoiceOver stop per line instead of three, and it now says what
        // happened to the line rather than reading a bare "+" that announces
        // nothing at all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            diffRowAccessibilityLabel(kind: line?.kind, lineNumber: lineNumber, text: line?.text, facesContent: facesContent)
        )
        .accessibilityActions {
            if line != nil {
                Button("Comment on this line") { onComment() }
            }
        }
    }

    private var lineNumber: Int? { side == .left ? line?.oldLineNumber : line?.newLineNumber }

    private var marker: String {
        guard let line else { return "" }
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }
}
