import Foundation

// MARK: - Sorting

enum FileSortOption: String, CaseIterable, Identifiable, Equatable {
    case treeOrder, mostChanged, categoryPriority

    var id: String { rawValue }

    var label: String {
        switch self {
        case .treeOrder: return "Tree order"
        case .mostChanged: return "Most changed"
        case .categoryPriority: return "Category priority"
        }
    }

    var symbolName: String {
        switch self {
        case .treeOrder: return "list.bullet.indent"
        case .mostChanged: return "arrow.up.arrow.down"
        case .categoryPriority: return "flag"
        }
    }
}

// MARK: - File tree

/// One row of the collapsible file tree. Directories whose entire chain has
/// exactly one child directory are pre-collapsed into a single node whose
/// `name` is the joined path (e.g. "src/lib/ai") — see `FileTreeBuilder`.
struct FileTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    let isDirectory: Bool
    let file: PRFile?
    let children: [FileTreeNode]
    let additions: Int
    let deletions: Int
    let fileCount: Int
    /// The lowest (highest-priority) `FileCategory.reviewPriority` among
    /// this node's descendants — lets "category priority" sort a directory
    /// by the most important thing inside it.
    let bestCategoryPriority: Int

    /// `nil` rather than `[]` for a leaf, so `List`/`OutlineGroup` (which
    /// use this to decide whether a row gets a disclosure triangle) don't
    /// draw an empty, permanently-collapsed arrow next to every file.
    var childrenOrNil: [FileTreeNode]? { children.isEmpty ? nil : children }
}

enum FileTreeBuilder {
    /// Builds a real folder hierarchy from a flat file list, aggregates
    /// add/delete counts up the tree, and collapses single-child directory
    /// chains into one row. Pure and allocation-light enough to re-run on
    /// every filter/sort change for a few hundred files.
    static func build(
        files: [PRFile],
        classifications: [String: FileClassification],
        sortOrder: FileSortOption
    ) -> [FileTreeNode] {
        guard !files.isEmpty else { return [] }

        final class RawNode {
            let name: String
            var children: [String: RawNode] = [:]
            var order: [String] = []
            var file: PRFile?
            init(name: String) { self.name = name }
        }

        let root = RawNode(name: "")
        for file in files {
            var node = root
            let components = file.filename.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                if let existing = node.children[component] {
                    node = existing
                } else {
                    let child = RawNode(name: component)
                    node.children[component] = child
                    node.order.append(component)
                    node = child
                }
                if index == components.count - 1 { node.file = file }
            }
        }

        func comparator(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
            switch sortOrder {
            case .treeOrder:
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .mostChanged:
                let changesA = a.additions + a.deletions
                let changesB = b.additions + b.deletions
                if changesA != changesB { return changesA > changesB }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .categoryPriority:
                if a.bestCategoryPriority != b.bestCategoryPriority { return a.bestCategoryPriority < b.bestCategoryPriority }
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        func convert(_ node: RawNode, pathPrefix: String) -> FileTreeNode {
            let fullPath = pathPrefix.isEmpty ? node.name : "\(pathPrefix)/\(node.name)"

            if let file = node.file, node.children.isEmpty {
                let category = classifications[file.filename]?.category ?? .other
                return FileTreeNode(
                    id: file.filename, name: node.name, isDirectory: false, file: file,
                    children: [], additions: file.additions,
                    deletions: file.deletions, fileCount: 1, bestCategoryPriority: category.reviewPriority
                )
            }

            var childNodes = node.order.compactMap { node.children[$0] }
                .map { convert($0, pathPrefix: fullPath) }
            childNodes.sort(by: comparator)

            let additions = childNodes.reduce(0) { $0 + $1.additions }
            let deletions = childNodes.reduce(0) { $0 + $1.deletions }
            let fileCount = childNodes.reduce(0) { $0 + $1.fileCount }
            let bestPriority = childNodes.map(\.bestCategoryPriority).min() ?? FileCategory.other.reviewPriority

            // Collapse a single-child directory chain into one row so a
            // deep, narrow module doesn't cost a click per level — mirrors
            // GitHub's own PR file tree.
            if childNodes.count == 1, childNodes[0].isDirectory {
                let onlyChild = childNodes[0]
                return FileTreeNode(
                    id: onlyChild.id, name: "\(node.name)/\(onlyChild.name)", isDirectory: true,
                    file: nil, children: onlyChild.children,
                    additions: additions, deletions: deletions, fileCount: fileCount,
                    bestCategoryPriority: bestPriority
                )
            }

            return FileTreeNode(
                id: fullPath, name: node.name, isDirectory: true, file: nil,
                children: childNodes, additions: additions, deletions: deletions,
                fileCount: fileCount, bestCategoryPriority: bestPriority
            )
        }

        var top = root.order.compactMap { root.children[$0] }.map { convert($0, pathPrefix: "") }
        top.sort(by: comparator)
        return top
    }

    /// Depth-first flattening of every file leaf under `nodes`, in the
    /// order the tree currently displays them — the basis for j/k
    /// next-file navigation and for comment-anchor ordering.
    static func flattenFilePaths(_ nodes: [FileTreeNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            if let file = node.file { return [file.filename] }
            return flattenFilePaths(node.children)
        }
    }
}

// MARK: - Review progress

struct CategoryProgress: Identifiable, Equatable {
    var id: FileCategory { category }
    let category: FileCategory
    let viewed: Int
    let total: Int
    var fraction: Double { total == 0 ? 0 : Double(viewed) / Double(total) }
}

struct ReviewProgress: Equatable {
    let overallViewed: Int
    let overallTotal: Int
    let byCategory: [CategoryProgress]
    var overallFraction: Double { overallTotal == 0 ? 0 : Double(overallViewed) / Double(overallTotal) }
}

enum ReviewProgressCalculator {
    /// Deliberately computed over every changed file, not just the
    /// currently-visible/filtered ones — hiding lockfiles from the tree
    /// shouldn't quietly drop them from "how much of this PR have I seen."
    /// The overall total is counted in the same pass as the per-category
    /// ones, so `overallViewed` is the sum of the category rows by
    /// construction. It used to be a second, independent `filter` over the
    /// same array: two numbers that agreed by coincidence rather than by
    /// derivation, and one more full pass plus a throwaway array per call —
    /// and this runs on every evaluation of the sidebar's `body`.
    static func progress(
        files: [PRFile], classifications: [String: FileClassification], viewedFiles: Set<String>
    ) -> ReviewProgress {
        var totals: [FileCategory: Int] = [:]
        var viewed: [FileCategory: Int] = [:]
        var overallViewed = 0
        for file in files {
            let category = classifications[file.filename]?.category ?? .other
            totals[category, default: 0] += 1
            if viewedFiles.contains(file.filename) {
                viewed[category, default: 0] += 1
                overallViewed += 1
            }
        }
        let byCategory = FileCategory.allCases
            .compactMap { category -> CategoryProgress? in
                guard let total = totals[category] else { return nil }
                return CategoryProgress(category: category, viewed: viewed[category] ?? 0, total: total)
            }
            .sorted { $0.category.reviewPriority < $1.category.reviewPriority }
        return ReviewProgress(
            overallViewed: overallViewed, overallTotal: files.count, byCategory: byCategory
        )
    }
}

// MARK: - Diff navigation

/// A GitHub-anchor-shaped location: a file, and optionally a line and (for
/// review comments) which side of the diff it's on. `line == nil` means
/// "the top of the file" rather than any specific row.
struct DiffAnchor: Equatable, Hashable {
    let path: String
    let line: Int?
    let side: DiffSide?
}

enum DiffNavigator {
    /// Pure ordering/selection logic for keyboard navigation, kept free of
    /// any live model so it's directly unit-testable.
    static func adjacentFile(to current: String?, in order: [String], delta: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return order.first }
        let target = index + delta
        guard order.indices.contains(target) else { return current }
        return order[target]
    }

    /// Anchors ordered by their file's position in `order`, then by line —
    /// the order a reviewer would encounter them scrolling top to bottom.
    private static func sorted(_ anchors: [DiffAnchor], order: [String]) -> [DiffAnchor] {
        let indexOf: [String: Int] = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return anchors.sorted { a, b in
            let ia = indexOf[a.path] ?? Int.max
            let ib = indexOf[b.path] ?? Int.max
            if ia != ib { return ia < ib }
            return (a.line ?? 0) < (b.line ?? 0)
        }
    }

    static func nextAnchor(after current: DiffAnchor?, in anchors: [DiffAnchor], order: [String]) -> DiffAnchor? {
        let list = sorted(anchors, order: order)
        guard !list.isEmpty else { return nil }
        guard let current, let index = list.firstIndex(of: current) else { return list.first }
        return list[min(index + 1, list.count - 1)]
    }

    static func previousAnchor(before current: DiffAnchor?, in anchors: [DiffAnchor], order: [String]) -> DiffAnchor? {
        let list = sorted(anchors, order: order)
        guard !list.isEmpty else { return nil }
        guard let current, let index = list.firstIndex(of: current) else { return list.first }
        return list[max(index - 1, 0)]
    }

    /// The first hunk's new-side start line strictly after `line` (or the
    /// very first hunk, when nothing is current yet).
    /// Where each hunk's *change* actually starts, as a line and the side it
    /// lives on.
    ///
    /// Not the hunk's `newStart`, which is what this replaced. A unified
    /// diff hunk opens with context — usually three lines of it — so
    /// stepping to `newStart` landed the reviewer, and the highlight, on an
    /// unchanged line above the thing they pressed the key to see. This
    /// finds the first added or removed line instead.
    ///
    /// A deletion-only hunk has no new-side line at all, which is why the
    /// side travels with the number: anchoring it to the right-hand column
    /// would resolve to no row and the jump would silently do nothing.
    static func changeAnchors(in hunks: [DiffHunk], path: String) -> [DiffAnchor] {
        hunks.compactMap { hunk in
            guard let change = firstChange(in: hunk) else { return nil }
            return DiffAnchor(path: path, line: change.line, side: change.side)
        }
    }

    static func firstChange(in hunk: DiffHunk) -> (line: Int, side: DiffSide)? {
        for line in hunk.lines {
            switch line.kind {
            case .addition:
                if let number = line.newLineNumber { return (number, .right) }
            case .deletion:
                if let number = line.oldLineNumber { return (number, .left) }
            case .context:
                continue
            }
        }
        // A hunk with no add or delete line is not a change to step to. It
        // can happen on a diff of pure renames or mode changes.
        return nil
    }

    /// The next change strictly after `line`, or nil when this file has
    /// none left.
    ///
    /// Nil means *exhausted*, and that is the point of the rewrite: the
    /// previous pair clamped to the last hunk and returned it, so the caller
    /// could only infer "nowhere to go" from the target coming back equal to
    /// where it already was. Exhaustion now has its own answer, which is
    /// what lets the caller step into the next file instead of dead-ending.
    static func nextChange(after line: Int?, anchors: [DiffAnchor]) -> DiffAnchor? {
        guard let line else { return anchors.first }
        // `DiffAnchor.line` is optional because a comment anchor can be
        // outdated; a change anchor always has one, so a nil here is a
        // malformed anchor to skip rather than a position to compare.
        return anchors.first { $0.line.map { $0 > line } ?? false }
    }

    static func previousChange(before line: Int?, anchors: [DiffAnchor]) -> DiffAnchor? {
        guard let line else { return anchors.last }
        return anchors.last { $0.line.map { $0 < line } ?? false }
    }

    /// Resolves a (line, side) anchor to the paired-row identity the diff
    /// views key their `.id()` on for `ScrollViewReader`. A hunk's own
    /// `pairedForSplitView()` row ids restart at 0 for every hunk, so only
    /// (hunk index, row id) together identify one row uniquely within a file.
    static func rowIdentity(forLine line: Int?, side: DiffSide?, hunks: [DiffHunk]) -> (hunkIndex: Int, rowID: Int)? {
        guard let line else { return nil }
        for (hunkIndex, hunk) in hunks.enumerated() {
            for row in hunk.lines.pairedForSplitView() {
                if side == .left, let left = row.left, left.oldLineNumber == line { return (hunkIndex, row.id) }
                if side != .left, let right = row.right, right.newLineNumber == line { return (hunkIndex, row.id) }
            }
        }
        return nil
    }
}

// MARK: - WorkspaceModel

/// Filter, sort, and navigation state for the review workspace, plus pure
/// transforms over `[PRFile]`/`ParsedFile`. Holds no reference to
/// `AppModel`: views feed it inputs (`refresh(files:)`) and read its
/// `@Published` outputs, which keeps this type usable from the unit-test
/// bundle and free of any SwiftUI view dependency.
///
/// `Views/SidebarView.swift` and `Views/DiffView.swift` both need to react
/// to the same navigation/filter state, but they're siblings under the
/// integrator's `NavigationSplitView` (`Views/RootView.swift`) rather than
/// parent/child — so there's no shared ancestor to hang an `@EnvironmentObject`
/// off of. Both views observe `WorkspaceModel.shared` directly instead.
@MainActor
final class WorkspaceModel: ObservableObject {
    static let shared = WorkspaceModel()

    // Filter & sort (session UI state, seeded from AppSettings once per PR).
    @Published var searchText: String = ""
    @Published var sortOption: FileSortOption = .treeOrder
    @Published var hiddenCategories: Set<FileCategory> = [.lockfile, .generated]

    // Diff pane presentation, mirrored from/to AppSettings by the view.
    @Published var showShortcuts = false
    /// Set by the `/` shortcut; `FilterBarView` focuses its search field on
    /// the next change and immediately resets this back to `false`.
    @Published var searchFieldFocusRequested = false

    /// Unresolved-thread counts per path, published by the conversation
    /// model. REST alone cannot distinguish resolved from unresolved, so
    /// this stays empty until GraphQL thread state loads — the tree then
    /// falls back to counting every thread on the file rather than
    /// claiming they are all unresolved.
    @Published var unresolvedCountsByPath: [String: Int] = [:]

    // Derived state, recomputed by `refresh`.
    @Published private(set) var classifications: [String: FileClassification] = [:]
    @Published private(set) var tree: [FileTreeNode] = []
    @Published private(set) var orderedVisiblePaths: [String] = []
    /// Each visible path's position in that list, so "file 42 of 300" in the
    /// diff pane's header is a lookup rather than a linear scan of every
    /// visible path on every render of that header.
    @Published private(set) var visibleIndexByPath: [String: Int] = [:]
    @Published private(set) var hiddenCountByCategory: [FileCategory: Int] = [:]

    /// The same files `orderedVisiblePaths` names, in the same order, as
    /// `PRFile` values — so the diff pane can render exactly what the tree
    /// shows without rebuilding a path→file index inside its `body`. It did
    /// exactly that, twice per evaluation, over every changed file.
    ///
    /// `visibleFiles.count == orderedVisiblePaths.count` always holds: both
    /// are derived from `tree` in the same pass.
    @Published private(set) var visibleFiles: [PRFile] = []

    /// The same files keyed by path, so opening a file is a dictionary hit
    /// rather than a scan of `visibleFiles`. The diff pane's `body` looked
    /// its own file up on every evaluation — including every frame of a
    /// scroll — which made the cost of finding it grow with the size of
    /// the pull request.
    @Published private(set) var visibleFileByPath: [String: PRFile] = [:]

    /// A cross-view "go here" request. The diff pane observes this, performs
    /// the scroll, then calls `consumePendingJump()`. Exposed so other
    /// tracks (a comment view, a search result) can navigate the workspace
    /// without needing a reference to whichever view currently hosts it.
    @Published private(set) var pendingJump: DiffAnchor?

    /// Files the reviewer has been sent to that the filters would otherwise
    /// hide.
    ///
    /// An AI citation, a finding or a comment anchor can point at a file the
    /// current search or category filters exclude. The pane only draws what
    /// the tree shows, so without this the jump landed on a file that was not
    /// in the view tree and nothing happened at all — the worst possible
    /// answer. Clearing the reviewer's filters for them is the second worst,
    /// so exactly the file they asked for comes back, and nothing else.
    @Published private(set) var revealedPaths: Set<String> = []

    /// Where the reviewer had scrolled to in each file, as the identity of
    /// the row that was at the top of the pane.
    ///
    /// A row id rather than a point offset: the pane's content height changes
    /// with the layout, the wrap setting, revealed context and arriving
    /// comments, so a saved offset would restore to a different place than it
    /// was taken from. The row that was at the top is the same row whatever
    /// the geometry does around it.
    ///
    /// This is the thing a single scroll of every file could not have at all
    /// — one scroll has one offset, and a file has no position of its own in
    /// it.
    ///
    /// Deliberately *not* `@Published`: the pane writes it on every frame of
    /// a scroll, and nothing observes it reactively — it is read once, when a
    /// file opens. Publishing it would re-render the tree, the filter bar and
    /// the pane itself continuously while the reviewer scrolls.
    private var scrollAnchors: [String: String] = [:]

    func scrollAnchor(for path: String) -> String? { scrollAnchors[path] }

    func setScrollAnchor(_ rowID: String?, for path: String) {
        scrollAnchors[path] = rowID
    }

    /// Directories the reviewer has folded shut.
    ///
    /// Stored as the *closed* set, not the open one, so the tree opens itself:
    /// a reviewer arriving at a pull request wants to see the files, not a row
    /// of folders to click through, and on a filtered tree the folders are
    /// most of what a click would reveal. Anything the reviewer closes stays
    /// closed until the pull request changes.
    @Published private(set) var collapsedDirectories: Set<String> = []

    /// Hunks the reviewer has folded away, keyed `path#hunkIndex`.
    ///
    /// Collapsing is a reading aid — quieting a formatting hunk while working
    /// through a file — and it now belongs to hunks. It used to belong to
    /// whole files and to double as review progress: marking a file viewed
    /// folded it, which meant a reviewer could not fold a file for quiet
    /// without claiming to have read it, nor re-read a file they had marked
    /// viewed without appearing to un-review it.
    @Published private(set) var collapsedHunks: Set<String> = []

    /// A range of lines being picked out for one comment.
    ///
    /// GitHub lets a reviewer drag down the gutter to comment on several
    /// lines at once, which is how you say "this whole block is the problem"
    /// instead of leaving the same note on six lines. `anchor` is where the
    /// gesture started and `head` is where it is now, so a drag that reverses
    /// direction selects upward without the range inverting.
    struct DiffLineSelection: Equatable {
        let path: String
        let side: DiffSide
        var anchor: Int
        var head: Int

        var range: ClosedRange<Int> {
            anchor <= head ? anchor...head : head...anchor
        }

        var isMultiLine: Bool { range.count > 1 }

        func covers(path: String, side: DiffSide, line: Int) -> Bool {
            self.path == path && self.side == side && range.contains(line)
        }
    }

    @Published private(set) var lineSelection: DiffLineSelection?

    /// Half-written inline comments, keyed by the line they are attached to.
    ///
    /// This text used to live in the composer view's own `@State`, inside the
    /// lazy stack — so scrolling far enough for the row to be recycled, or
    /// anyone marking that file viewed, destroyed whatever the reviewer had
    /// typed, with no warning and no recovery. Review comments are the work;
    /// losing them to a scroll is the worst thing this app could do.
    ///
    /// Session-scoped on purpose: a *submitted* draft is durable through
    /// `DraftStore`, and an abandoned half-sentence should not outlive the
    /// window it was typed in.
    ///
    /// Deliberately **not** `@Published`. Nothing renders it — the composer
    /// that owns the text holds it in `@State` while it is on screen and
    /// writes through here — and every view in the workspace observes this
    /// model, so publishing a keystroke re-rendered the diff pane, the file
    /// tree, the toolbar and the filter bar for a character only one text
    /// box could see.
    private(set) var composerText: [String: String] = [:]

    func composerText(path: String, line: Int, side: DiffSide) -> String {
        composerText[Self.composerKey(path: path, line: line, side: side)] ?? ""
    }

    func setComposerText(_ body: String, path: String, line: Int, side: DiffSide) {
        composerText[Self.composerKey(path: path, line: line, side: side)] = body
    }

    /// Drops every half-written comment — a different pull request opening.
    func clearAllComposerText() {
        composerText.removeAll()
    }

    static func composerKey(path: String, line: Int, side: DiffSide) -> String {
        "\(path)#\(line)#\(side.rawValue)"
    }

    func isDirectoryExpanded(_ id: String) -> Bool {
        !collapsedDirectories.contains(id)
    }

    func setDirectory(_ id: String, expanded: Bool) {
        if expanded {
            collapsedDirectories.remove(id)
        } else {
            collapsedDirectories.insert(id)
        }
    }

    /// Every directory in the current tree, folded or opened at once.
    func setAllDirectories(expanded: Bool) {
        guard !expanded else {
            collapsedDirectories.removeAll()
            return
        }
        var ids: Set<String> = []
        func walk(_ nodes: [FileTreeNode]) {
            for node in nodes where node.isDirectory {
                ids.insert(node.id)
                walk(node.children)
            }
        }
        walk(tree)
        collapsedDirectories = ids
    }

    /// Which line currently has an open comment composer.
    ///
    /// Shared rather than held by the row that was clicked, because the
    /// composer does not necessarily belong to that row: a comment on a
    /// dragged range opens under the *last* line of the range, so the box is
    /// always below the code it is about and never in the middle of it.
    @Published private(set) var openComposer: DiffAnchor?

    /// The lines a comment can attach to, per file and side, grouped into the
    /// contiguous runs a hunk provides.
    ///
    /// GitHub rejects a comment whose range reaches outside the diff — and
    /// rejects the *whole* review, not the one comment — so a drag has to
    /// stop at the end of the hunk it started in rather than sailing into
    /// line numbers that were never in the patch.
    private var selectableRuns: [String: [ClosedRange<Int>]] = [:]

    private static func runsKey(path: String, side: DiffSide) -> String { "\(path)#\(side.rawValue)" }

    func setSelectableRuns(_ runs: [ClosedRange<Int>], path: String, side: DiffSide) {
        selectableRuns[Self.runsKey(path: path, side: side)] = runs
    }

    /// The run containing `line`, if any.
    private func run(containing line: Int, path: String, side: DiffSide) -> ClosedRange<Int>? {
        selectableRuns[Self.runsKey(path: path, side: side)]?.first { $0.contains(line) }
    }

    // MARK: - Composer placement

    /// Opens the composer for a click on `line`, or — when a multi-line
    /// selection covers it — under the last line of that selection.
    func openComposer(path: String, side: DiffSide, line: Int) {
        var anchorLine = line
        if let selection = lineSelection, selection.covers(path: path, side: side, line: line) {
            anchorLine = selection.range.upperBound
        }
        openComposer = DiffAnchor(path: path, line: anchorLine, side: side)
    }

    func closeComposer() {
        openComposer = nil
    }

    func isComposerOpen(path: String, side: DiffSide, line: Int?) -> Bool {
        guard let line, let anchor = openComposer else { return false }
        return anchor.path == path && anchor.side == side && anchor.line == line
    }

    // MARK: - Line selection

    func beginLineSelection(path: String, side: DiffSide, line: Int) {
        lineSelection = DiffLineSelection(path: path, side: side, anchor: line, head: line)
    }

    /// Extends the selection to `line` — a drag moving, or a shift-click.
    ///
    /// A line on a different file or side starts a new selection rather than
    /// stretching across the boundary: GitHub will not accept a range that
    /// spans two files, and a range spanning both sides of a split diff means
    /// nothing to a reviewer reading it.
    func extendLineSelection(path: String, side: DiffSide, to line: Int) {
        guard var selection = lineSelection, selection.path == path, selection.side == side else {
            beginLineSelection(path: path, side: side, line: line)
            return
        }
        // Held inside the hunk the selection started in. Without this a drag
        // past the end of a hunk produced a range covering lines that are not
        // in the diff, which GitHub answers by rejecting the entire review.
        let clamped: Int
        if let run = run(containing: selection.anchor, path: path, side: side) {
            clamped = min(max(line, run.lowerBound), run.upperBound)
        } else {
            clamped = max(1, line)
        }
        // Every pointer move fires this; most of them land on the line the
        // selection already ends at, and republishing then re-renders every
        // visible row for nothing.
        guard clamped != selection.head else { return }

        // `DiffAnchor.line` is optional — a file-level anchor has no line.
        let composerFollowsThisSelection: Bool = {
            guard let anchor = openComposer, let anchorLine = anchor.line else { return false }
            return anchor.path == path && anchor.side == side && selection.range.contains(anchorLine)
        }()

        selection.head = clamped
        lineSelection = selection

        // The box follows the bottom of the range so it stays below the code
        // it will comment on — but only when it belongs to *this* selection.
        // Moving any open composer meant that starting a new drag elsewhere
        // re-anchored a composer the reviewer had already typed into, and its
        // text is keyed by line, so the box reappeared empty.
        if composerFollowsThisSelection {
            openComposer = DiffAnchor(path: path, line: selection.range.upperBound, side: side)
        }
    }

    func clearLineSelection() {
        lineSelection = nil
    }

    /// Called when the open file changes. A selection belongs to the file it
    /// was drawn in; carrying it across meant a "Comment here" in the next
    /// file could inherit a range from the last one.
    func fileDidChange(to path: String?) {
        if let selection = lineSelection, selection.path != path { lineSelection = nil }
        if let anchor = openComposer, anchor.path != path { openComposer = nil }
    }

    /// True when this exact line is inside the current selection, for the
    /// tint that shows the reviewer what they have picked.
    func isLineSelected(path: String, side: DiffSide, line: Int?) -> Bool {
        guard let line, let selection = lineSelection else { return false }
        return selection.covers(path: path, side: side, line: line)
    }

    static func hunkKey(path: String, hunkIndex: Int) -> String { "\(path)#\(hunkIndex)" }

    func isHunkCollapsed(path: String, hunkIndex: Int) -> Bool {
        collapsedHunks.contains(Self.hunkKey(path: path, hunkIndex: hunkIndex))
    }

    func toggleHunk(path: String, hunkIndex: Int) {
        let key = Self.hunkKey(path: path, hunkIndex: hunkIndex)
        if collapsedHunks.contains(key) {
            collapsedHunks.remove(key)
        } else {
            collapsedHunks.insert(key)
        }
    }

    func setHunks(collapsed: Bool, path: String, count: Int) {
        for index in 0..<max(0, count) {
            let key = Self.hunkKey(path: path, hunkIndex: index)
            if collapsed { collapsedHunks.insert(key) } else { collapsedHunks.remove(key) }
        }
    }

    /// The visible file at `path`, in O(1). Used by the diff pane, which
    /// resolves its own file on every `body` evaluation.
    func visibleFile(at path: String) -> PRFile? { visibleFileByPath[path] }

    /// The next file after `current` that has not been marked viewed, in the
    /// order the tree is showing. Falls back to the plain next file when
    /// everything ahead is already viewed, and returns `nil` only when there
    /// is nowhere left to go.
    func nextUnviewedPath(after current: String?, viewedFiles: Set<String>) -> String? {
        guard !orderedVisiblePaths.isEmpty else { return nil }
        let startIndex = current.flatMap { orderedVisiblePaths.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if let ahead = orderedVisiblePaths[startIndex...].first(where: { !viewedFiles.contains($0) }) {
            return ahead
        }
        // Wrap once: a reviewer who marked the last file viewed still has
        // whatever they skipped earlier, and silently doing nothing reads as
        // a broken key.
        if let behind = orderedVisiblePaths.prefix(startIndex).first(where: { !viewedFiles.contains($0) }) {
            return behind
        }
        return DiffNavigator.adjacentFile(to: current, in: orderedVisiblePaths, delta: 1)
    }

    func clearComposer(path: String, line: Int, side: DiffSide) {
        composerText.removeValue(forKey: Self.composerKey(path: path, line: line, side: side))
    }

    /// Per-file "where n/p last left off" — shared by `DiffToolbar`'s arrow
    /// buttons and the `n`/`p` keyboard shortcut so clicking and typing
    /// never disagree about the current position.
    /// Which change the reviewer is on, per file. Readable so the
    /// navigation bar can say "3/7" — a count on its own does not tell you
    /// whether pressing the key again will do anything.
    private(set) var hunkCursor: [String: Int] = [:]
    private var commentCursor: DiffAnchor?

    private var configuredForPRKey: String?

    /// Everything `refresh` reads. The sidebar and the diff pane are
    /// siblings that both drive the workspace, so every one of the five
    /// triggers (files, search, sort, category filters, PR open) arrives
    /// twice — and each arrival republished `tree`, which re-renders both
    /// panes and the filter bar. Comparing the inputs first makes the
    /// duplicate free: `Array`/`Set` equality short-circuits on identical
    /// storage, which is the case every time.
    private struct RefreshInputs: Equatable {
        let files: [PRFile]
        let searchText: String
        let sortOption: FileSortOption
        let hiddenCategories: Set<FileCategory>
        /// Part of the key, or revealing a filtered-out file would be
        /// early-outed as "nothing changed" and the jump would land nowhere.
        let revealedPaths: Set<String>
    }

    private var lastRefreshInputs: RefreshInputs?
    private var formattingScanTask: Task<Void, Never>?

    init() {}

    /// Seeds session filter state from the persisted default the first
    /// time a given PR is seen, and resets it when a *different* PR loads.
    /// Safe to call on every `body` evaluation — it no-ops otherwise.
    func configureIfNeeded(prKey: String, hiddenFileCategories: Set<String>) {
        guard configuredForPRKey != prKey else { return }
        configuredForPRKey = prKey
        hiddenCategories = Set(hiddenFileCategories.compactMap(FileCategory.init(rawValue:)))
        searchText = ""
        sortOption = .treeOrder
        revealedPaths = []
        lineSelection = nil
        openComposer = nil
        collapsedDirectories = []
        scrollAnchors.removeAll()
        collapsedHunks = []
        composerText.removeAll()
        lastRefreshInputs = nil
        formattingScanTask?.cancel()
        resetDerivationCaches()
        Task { await SyntaxHighlightCache.shared.reset() }
    }

    /// Recomputes classification (only when the file set actually changed)
    /// and always recomputes the filtered/sorted tree — cheap enough to
    /// call from `.onChange` on files, search text, sort, or category
    /// toggles alike.
    func refresh(files: [PRFile]) {
        let inputs = RefreshInputs(
            files: files, searchText: searchText,
            sortOption: sortOption, hiddenCategories: hiddenCategories,
            revealedPaths: revealedPaths
        )
        guard inputs != lastRefreshInputs else { return }
        lastRefreshInputs = inputs

        let needsClassification = classifications.count != files.count
            || files.contains { classifications[$0.filename] == nil }
        if needsClassification {
            // Path-only work here; the patch scan that decides
            // `isFormattingOnly` follows off the main actor.
            classifications = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, FileClassifier.quickClassify($0)) })
            scheduleFormattingScan(files)
        }

        var hiddenCounts: [FileCategory: Int] = [:]
        for file in files {
            let category = classifications[file.filename]?.category ?? .other
            if hiddenCategories.contains(category) { hiddenCounts[category, default: 0] += 1 }
        }
        hiddenCountByCategory = hiddenCounts

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var byPath: [String: PRFile] = [:]
        byPath.reserveCapacity(files.count)
        var visible: [PRFile] = []
        for file in files {
            let revealed = revealedPaths.contains(file.filename)
            let category = classifications[file.filename]?.category ?? .other
            guard revealed || !hiddenCategories.contains(category) else { continue }
            guard revealed || needle.isEmpty || file.filename.lowercased().contains(needle) else { continue }
            visible.append(file)
            byPath[file.filename] = file
        }
        tree = FileTreeBuilder.build(files: visible, classifications: classifications, sortOrder: sortOption)
        let paths = FileTreeBuilder.flattenFilePaths(tree)
        orderedVisiblePaths = paths
        visibleIndexByPath = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
        // Built here, once per actual filter change, from the index the
        // filter pass already had to walk — rather than in the diff pane's
        // `body`, where it was rebuilt from scratch on every evaluation.
        let files = paths.compactMap { byPath[$0] }
        visibleFiles = files
        visibleFileByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0) })
    }

    /// Fills in `isFormattingOnly` for every file, off the main actor.
    ///
    /// The tree is already on screen and correctly filtered by then — this
    /// only adds the "formatting-only" glyph, so arriving a moment late costs
    /// the reviewer nothing, where blocking the first frame of a 675-file
    /// pull request on it cost them the wait.
    private func scheduleFormattingScan(_ files: [PRFile]) {
        formattingScanTask?.cancel()
        formattingScanTask = Task { [weak self] in
            let flags = await Self.formattingOnlyFlags(files)
            guard !Task.isCancelled else { return }
            self?.applyFormattingFlags(flags)
        }
    }

    private func applyFormattingFlags(_ flags: [String: Bool]) {
        var updated = classifications
        var changed = false
        for (path, isFormattingOnly) in flags where isFormattingOnly {
            guard let existing = updated[path], !existing.isFormattingOnly else { continue }
            updated[path] = FileClassification(
                category: existing.category,
                isFormattingOnly: true,
                isLargeFile: existing.isLargeFile,
                isBinaryOrEmpty: existing.isBinaryOrEmpty,
                isRename: existing.isRename
            )
            changed = true
        }
        // Only republish when a flag actually flipped: `classifications`
        // drives the whole tree, and most pull requests contain no
        // formatting-only files at all.
        guard changed else { return }
        classifications = updated
    }

    nonisolated private static func formattingOnlyFlags(_ files: [PRFile]) async -> [String: Bool] {
        guard !files.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Bool).self) { group in
            for file in files {
                group.addTask {
                    (file.filename, FileClassifier.isFormattingOnly(patch: file.patch))
                }
            }
            var flags: [String: Bool] = [:]
            flags.reserveCapacity(files.count)
            for await (path, isFormattingOnly) in group {
                flags[path] = isFormattingOnly
            }
            return flags
        }
    }

    func toggleCategory(_ category: FileCategory) {
        if hiddenCategories.contains(category) {
            hiddenCategories.remove(category)
        } else {
            hiddenCategories.insert(category)
        }
    }

    /// Requests that the diff pane scroll to `path` (and `line`/`side`, if
    /// given). The pane is responsible for actually performing the scroll
    /// and for selecting the file in `AppModel`.
    func jump(to path: String, line: Int? = nil, side: DiffSide? = nil) {
        revealedPaths.insert(path)
        pendingJump = DiffAnchor(path: path, line: line, side: side)
    }

    func consumePendingJump() {
        pendingJump = nil
    }

    /// Advances (or retreats) one hunk within `filename`, returning the new
    /// target line, or `nil` when there's nowhere left to go in this file
    /// (the caller then typically falls back to moving to the next file).
    func advanceHunk(in filename: String, hunks: [DiffHunk], delta: Int) -> DiffAnchor? {
        let anchors = DiffNavigator.changeAnchors(in: hunks, path: filename)
        let current = hunkCursor[filename]
        let target = delta > 0
            ? DiffNavigator.nextChange(after: current, anchors: anchors)
            : DiffNavigator.previousChange(before: current, anchors: anchors)
        guard let target else { return nil }
        hunkCursor[filename] = target.line
        return target
    }

    /// Seeds the cursor for a file the reviewer is entering from another
    /// one, so the first press lands on that file's first (or last) change
    /// rather than wherever they left this file's cursor on a previous
    /// visit.
    func enterFile(_ filename: String, hunks: [DiffHunk], from direction: Int) -> DiffAnchor? {
        let anchors = DiffNavigator.changeAnchors(in: hunks, path: filename)
        guard let target = direction > 0 ? anchors.first : anchors.last else { return nil }
        hunkCursor[filename] = target.line
        return target
    }

    /// Advances (or retreats) to the next/previous comment anchor across
    /// the whole PR, in file-then-line order.
    func advanceComment(anchors: [DiffAnchor], delta: Int) -> DiffAnchor? {
        let target = delta > 0
            ? DiffNavigator.nextAnchor(after: commentCursor, in: anchors, order: orderedVisiblePaths)
            : DiffNavigator.previousAnchor(before: commentCursor, in: anchors, order: orderedVisiblePaths)
        commentCursor = target
        return target
    }

    // MARK: - Derivations for the diff pane and the tree
    //
    // None of these are `@Published`: they are memoized *functions* of
    // values the caller already holds, not state anyone should observe.
    // Each takes its whole source collection and rebuilds only when that
    // collection actually changed, so a caller can invoke it straight from
    // a `body` without any ordering assumption about when an `onChange`
    // ran — and without publishing anything back into the update it is
    // part of.

    /// One diff row's anchor: threads and drafts are looked up by the exact
    /// (path, line, side) triple a row can carry.
    private struct LineAnchorKey: Hashable {
        let path: String
        let line: Int
        let side: DiffSide
    }

    /// Comment anchors in reading order, rebuilt only when the threads or
    /// drafts behind them actually change.
    ///
    /// The navigation bar asks for these from its `body`, and it observes
    /// `AppModel` — so without memoizing, every unrelated model change
    /// remapped every thread and draft in the pull request.
    func commentAnchors(threads: [ReviewThread], drafts: [DraftComment]) -> [DiffAnchor] {
        if threads == anchorSourceThreads, drafts == anchorSourceDrafts {
            return cachedCommentAnchors
        }
        anchorSourceThreads = threads
        anchorSourceDrafts = drafts
        let fromThreads = threads.compactMap { thread -> DiffAnchor? in
            guard let line = thread.line else { return nil }
            return DiffAnchor(path: thread.path, line: line, side: thread.side)
        }
        let fromDrafts = drafts.map { DiffAnchor(path: $0.path, line: $0.line, side: $0.side) }
        cachedCommentAnchors = fromThreads + fromDrafts
        return cachedCommentAnchors
    }

    private var anchorSourceThreads: [ReviewThread] = []
    private var anchorSourceDrafts: [DraftComment] = []
    private var cachedCommentAnchors: [DiffAnchor] = []

    private var indexedThreads: [ReviewThread] = []
    private var threadsByAnchor: [LineAnchorKey: [ReviewThread]] = [:]
    private var threadCountByPath: [String: Int] = [:]

    private var indexedDrafts: [DraftComment] = []
    private var draftsByAnchor: [LineAnchorKey: [DraftComment]] = [:]
    private var draftCountByPath: [String: Int] = [:]

    private func indexThreads(_ threads: [ReviewThread]) {
        guard threads != indexedThreads else { return }
        indexedThreads = threads
        var byAnchor: [LineAnchorKey: [ReviewThread]] = [:]
        var counts: [String: Int] = [:]
        for thread in threads {
            counts[thread.path, default: 0] += 1
            // An outdated thread has no line to anchor to (GitHub returns
            // `line: null`); it still counts towards the file's badge.
            guard let line = thread.line else { continue }
            // GitHub's own default for a review comment is the new side, and
            // the split view already assumed it. The unified view used its
            // own strict `side ==` test and so dropped a thread that arrived
            // without one entirely — the same thread, visible in one layout
            // and missing in the other.
            byAnchor[LineAnchorKey(path: thread.path, line: line, side: thread.side ?? .right), default: []]
                .append(thread)
        }
        threadsByAnchor = byAnchor
        threadCountByPath = counts
    }

    private func indexDrafts(_ drafts: [DraftComment]) {
        guard drafts != indexedDrafts else { return }
        indexedDrafts = drafts
        var byAnchor: [LineAnchorKey: [DraftComment]] = [:]
        var counts: [String: Int] = [:]
        for draft in drafts {
            counts[draft.path, default: 0] += 1
            byAnchor[LineAnchorKey(path: draft.path, line: draft.line, side: draft.side), default: []]
                .append(draft)
        }
        draftsByAnchor = byAnchor
        draftCountByPath = counts
    }

    /// Published threads anchored to exactly this row. One dictionary
    /// lookup, where every diff row used to scan every thread in the pull
    /// request on every evaluation of its `body`.
    func inlineThreads(in threads: [ReviewThread], path: String, line: Int?, side: DiffSide) -> [ReviewThread] {
        guard let line else { return [] }
        indexThreads(threads)
        return threadsByAnchor[LineAnchorKey(path: path, line: line, side: side)] ?? []
    }

    func inlineDrafts(in drafts: [DraftComment], path: String, line: Int?, side: DiffSide) -> [DraftComment] {
        guard let line else { return [] }
        indexDrafts(drafts)
        return draftsByAnchor[LineAnchorKey(path: path, line: line, side: side)] ?? []
    }

    /// What the file tree's per-file badge stands for. The number on screen
    /// is a total, but the two halves mean different things and one of them
    /// means different things again depending on what GitHub told us — so
    /// the badge carries its own description rather than leaving the row to
    /// call all of it "comments".
    struct CommentBadge: Equatable {
        let threads: Int
        let drafts: Int
        /// True when `threads` counts only threads GitHub reported as
        /// unresolved. False when resolution state never arrived and every
        /// thread on the file is counted instead — which is the safe
        /// direction to be wrong in, but not something to label as
        /// "unresolved".
        let threadsAreUnresolvedOnly: Bool

        var total: Int { threads + drafts }

        /// Tooltip / VoiceOver phrasing. Says what the number counts.
        var summary: String {
            var parts: [String] = []
            if threads > 0 {
                let noun = threads == 1 ? "thread" : "threads"
                parts.append(threadsAreUnresolvedOnly ? "\(threads) unresolved \(noun)" : "\(threads) review \(noun)")
            }
            if drafts > 0 {
                parts.append("\(drafts) draft comment\(drafts == 1 ? "" : "s")")
            }
            return parts.isEmpty ? "No comments on this file" : parts.joined(separator: ", ")
        }
    }

    func commentBadge(path: String, threads: [ReviewThread], drafts: [DraftComment]) -> CommentBadge {
        // `unresolvedCountsByPath` is empty both before GraphQL thread state
        // arrives and when every thread in the PR is resolved. Counting all
        // threads in the second case over-reports, but claiming zero
        // unresolved in the first would under-report the only thing a
        // reviewer must not miss.
        let unresolvedKnown = !unresolvedCountsByPath.isEmpty
        indexDrafts(drafts)
        let threadCount: Int
        if unresolvedKnown {
            threadCount = unresolvedCountsByPath[path] ?? 0
        } else {
            indexThreads(threads)
            threadCount = threadCountByPath[path] ?? 0
        }
        return CommentBadge(
            threads: threadCount, drafts: draftCountByPath[path] ?? 0,
            threadsAreUnresolvedOnly: unresolvedKnown
        )
    }

    private struct PairedRowsKey: Hashable {
        let path: String
        let hunkIndex: Int
    }

    private var pairedRowsCache: [PairedRowsKey: (lines: [DiffLine], rows: [SplitDiffRow])] = [:]
    private var pairedRowsCached = 0

    /// Roughly a thousand screenfuls of rows. Past it the whole cache is
    /// dropped rather than evicted entry by entry: the working set is
    /// whatever the reviewer is scrolled to, so rebuilding it costs one
    /// pairing pass per visible hunk and nothing else.
    private static let pairedRowsBudget = 60_000

    /// `pairedForSplitView()` for one hunk, memoized. Both diff layouts pair
    /// a hunk's lines to build their rows, and both did it inside `body` —
    /// so every evaluation of a built file section allocated a fresh
    /// `SplitDiffRow` array for every line of that file, on every change to
    /// `AppModel` (selecting a file with j/k, marking one viewed, a poll
    /// landing). The pairing of a given hunk never changes while it is on
    /// screen; only a refetch that actually replaces the lines invalidates
    /// it, which the identity-fast-path array comparison catches.
    func pairedRows(path: String, hunkIndex: Int, lines: [DiffLine]) -> [SplitDiffRow] {
        let key = PairedRowsKey(path: path, hunkIndex: hunkIndex)
        if let cached = pairedRowsCache[key], cached.lines == lines { return cached.rows }
        let rows = lines.pairedForSplitView()
        if pairedRowsCached > Self.pairedRowsBudget {
            pairedRowsCache.removeAll(keepingCapacity: true)
            pairedRowsCached = 0
        }
        pairedRowsCache[key] = (lines, rows)
        pairedRowsCached += rows.count
        return rows
    }

    /// Dropped when a different pull request opens — every key in them is
    /// scoped to the PR that is loaded.
    private func resetDerivationCaches() {
        indexedThreads = []
        threadsByAnchor = [:]
        threadCountByPath = [:]
        indexedDrafts = []
        draftsByAnchor = [:]
        draftCountByPath = [:]
        pairedRowsCache = [:]
        pairedRowsCached = 0
    }
}
