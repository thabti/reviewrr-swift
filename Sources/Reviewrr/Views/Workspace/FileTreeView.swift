import AppKit
import SwiftUI

/// The hierarchical file tree, sitting inside the host `List` in
/// `SidebarView`.
///
/// Built from `DisclosureGroup` rather than `OutlineGroup` for one reason:
/// `OutlineGroup` owns its expansion state and starts every folder shut, so
/// opening a pull request presented a row of folders instead of its files.
/// A `DisclosureGroup` takes a binding, which lets the tree open itself and
/// lets `WorkspaceModel` remember the folders the reviewer chose to close.
/// The cost is that disclosure and indentation are ours to draw; keyboard
/// selection still belongs to the enclosing `List`.
struct FileTreeView: View {
    @ObservedObject var workspace: WorkspaceModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        if workspace.tree.isEmpty {
            emptyState
        } else {
            ForEach(workspace.tree) { node in
                FileTreeNodeView(node: node, workspace: workspace)
            }
        }
    }

    /// Filtering every file out of the tree (or a PR with none to begin
    /// with) is a distinct situation from "still loading" — never a blank
    /// list with no explanation.
    @ViewBuilder
    private var emptyState: some View {
        if model.files.isEmpty {
            EmptyStateView(systemImage: "checkmark.seal", title: "No files", message: "This pull request has no changed files.")
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                EmptyStateView(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "No files match",
                    message: "Every changed file is hidden by the current search or category filters."
                )
                Button("Clear filters") {
                    workspace.searchText = ""
                    workspace.hiddenCategories = []
                }
                .buttonStyle(.reviewrrSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One node, and everything beneath it.
private struct FileTreeNodeView: View {
    let node: FileTreeNode
    @ObservedObject var workspace: WorkspaceModel

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { workspace.isDirectoryExpanded(node.id) },
            set: { workspace.setDirectory(node.id, expanded: $0) }
        )
    }

    var body: some View {
        // Only file rows carry a selection `.tag` — an untagged directory row
        // is still fully navigable, it just never becomes "the" selection, so
        // several folders don't all read as selected whenever no file is
        // chosen.
        if let file = node.file {
            FileLeaf(file: file, workspace: workspace)
                .tag(file.filename)
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children) { child in
                    FileTreeNodeView(node: child, workspace: workspace)
                }
            } label: {
                DirectoryRow(node: node)
                    .contextMenu {
                        Button("Collapse all folders") { workspace.setAllDirectories(expanded: false) }
                        Button("Expand all folders") { workspace.setAllDirectories(expanded: true) }
                    }
            }
        }
    }
}

private struct FileTreeRowView: View {
    let node: FileTreeNode
    @ObservedObject var workspace: WorkspaceModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Only file rows carry a selection `.tag` — an untagged directory
        // row is still fully keyboard-navigable and disclosable, it just
        // never becomes "the" selection, so several collapsed directories
        // don't all read as selected whenever no file is chosen.
        if let file = node.file {
            FileLeaf(file: file, workspace: workspace)
                .tag(file.filename)
        } else {
            DirectoryRow(node: node)
        }
    }
}

private struct DirectoryRow: View {
    let node: FileTreeNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: Theme.iconMediumSize))
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(Theme.bodyMedium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(node.fileCount)")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            DiffStatCounts(additions: node.additions, deletions: node.deletions)
        }
        .padding(.vertical, 1)
        .hoverHighlight(cornerRadius: 6)
        .help("\(node.name) — \(node.fileCount) file\(node.fileCount == 1 ? "" : "s"), +\(node.additions) −\(node.deletions)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name) folder, \(node.fileCount) files, \(node.additions) additions \(node.deletions) deletions")
    }
}

/// The observing half of a file row: it reads the model, and hands the row
/// itself nothing but values.
///
/// The split exists because selecting a file re-rendered the whole tree. Every
/// leaf observed `AppModel`, so `j` on a 300-file pull request rebuilt and
/// re-laid-out three hundred rows — measured at ~215ms of main-thread work per
/// keystroke, thirteen dropped frames, for a change that repaints two rows.
/// This view still re-runs (it has to: it is what watches the model), but its
/// body is three dictionary lookups, and `.equatable()` below stops there for
/// every row whose values did not actually change.
private struct FileLeaf: View {
    let file: PRFile
    @ObservedObject var workspace: WorkspaceModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        FileLeafRow(
            file: file,
            classification: workspace.classifications[file.filename],
            badge: workspace.commentBadge(path: file.filename, threads: model.threads, drafts: model.draft.comments),
            viewed: model.draft.viewedFiles.contains(file.filename),
            // A `Bool`, not the `URL`: building three hundred URLs per
            // keystroke to decide whether one context-menu item exists is the
            // same mistake one level down. The URL is resolved in the action.
            canOpenOnGitHub: model.reference != nil && model.pullRequest?.headSha != nil,
            actions: FileRowActions(model: model)
        )
        .equatable()
    }
}

/// What a file row can do, as one non-`Equatable` bundle.
///
/// Kept out of `FileLeafRow`'s `==` deliberately: closures never compare
/// equal, so a row carrying its own callbacks could never be skipped. This
/// holds the model instead, and the row calls through it.
@MainActor
private struct FileRowActions {
    let model: AppModel

    func toggleViewed(_ path: String) { model.toggleViewed(path) }
    func select(_ path: String) { model.selectedFile = path }
    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
    func openOnGitHub(_ path: String) {
        guard let url = githubBlobURL(model: model, path: path) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One file in the tree. Pure values in, so SwiftUI can skip it.
private struct FileLeafRow: View, Equatable {
    let file: PRFile
    let classification: FileClassification?
    let badge: WorkspaceModel.CommentBadge
    let viewed: Bool
    let canOpenOnGitHub: Bool
    let actions: FileRowActions
    @Environment(\.colorScheme) private var colorScheme

    /// Everything the row draws, and nothing else — `actions` is excluded
    /// because it holds a reference to the model, which is the same object on
    /// every row and changes identity never.
    static func == (lhs: FileLeafRow, rhs: FileLeafRow) -> Bool {
        lhs.file == rhs.file
            && lhs.classification == rhs.classification
            && lhs.badge == rhs.badge
            && lhs.viewed == rhs.viewed
            && lhs.canOpenOnGitHub == rhs.canOpenOnGitHub
    }

    var body: some View {
        let perfStart = PerfProbe.begin()
        defer { PerfProbe.end("FileLeafRow", perfStart) }
        let displayName = file.displayName
        return HStack(spacing: 6) {
            if let category = classification?.category {
                // At 6pt the muted tints (gray, brown) all but vanished
                // against the sidebar; a point of diameter is the cheapest
                // fix that keeps the category visible without dominating the name.
                Circle()
                    .fill(category.tint)
                    .frame(width: 7, height: 7)
                    .help(category.label)
                    .accessibilityHidden(true)
            }
            if file.status != .modified && file.status != .changed {
                FileStatusIcon(status: file.status)
                    .help("\(file.status.rawValue.capitalized) file")
            }
            Text(displayName)
                .font(Theme.bodyMedium)
                .lineLimit(1)
                .help(file.filename)
            // Dimming the whole row took the viewed checkmark — the state
            // indicator itself — down with it, and on a large pull request
            // most of the tree ends up viewed: a path you cannot read is a
            // file you cannot navigate back to. Only the text fades.
                .opacity(viewed ? Theme.viewedDim : 1)
            if classification?.isFormattingOnly == true {
                Image(systemName: "textformat.size")
                    .font(.system(size: Theme.iconSmallSize))
                    .foregroundStyle(.secondary)
                    .help("Formatting-only change")
            }
            Spacer(minLength: 4)
            if badge.total > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left.fill")
                    Text(verbatim: "\(badge.total)")
                }
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                // The badge is a total, but it adds published threads to
                // local drafts and the thread half means "unresolved" only
                // once GitHub has told us which are resolved. It used to
                // call all of it "comments"; the tooltip now names what it
                // actually counted.
                .help(badge.summary)
                .accessibilityLabel(badge.summary)
            }
            DiffStatCounts(additions: file.additions, deletions: file.deletions)
            Button {
                actions.toggleViewed(file.filename)
            } label: {
                ViewedGlyph(viewed: viewed)
                    .foregroundStyle(viewed ? DiffTextColor.added(colorScheme) : .secondary)
            }
            .buttonStyle(.plain)
            .help(viewed ? "Mark as not viewed" : "Mark as viewed")
            .accessibilityLabel(viewed ? "Mark \(displayName) as not viewed" : "Mark \(displayName) as viewed")
        }
        .padding(.vertical, 1)
        .motion(Motion.smooth, value: viewed)
        .hoverHighlight(cornerRadius: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            actions.select(file.filename)
        }
        .contextMenu {
            Button {
                actions.toggleViewed(file.filename)
            } label: {
                Label(viewed ? "Mark as not viewed" : "Mark as viewed", systemImage: viewed ? "circle" : "checkmark.circle")
            }
            Divider()
            Button {
                actions.copyPath(file.filename)
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            if canOpenOnGitHub {
                Button {
                    actions.openOnGitHub(file.filename)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
            }
        }
        // One element with actions, which is Apple's pattern for a list row
        // carrying an accessory control: `.combine` alone reads the row
        // nicely and then hides the mark-viewed button inside it, leaving a
        // VoiceOver user able to hear the state but not change it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(file.status.rawValue), +\(file.additions) -\(file.deletions)\(viewed ? ", viewed" : "")")
        .accessibilityAction(named: viewed ? "Mark as not viewed" : "Mark as viewed") {
            actions.toggleViewed(file.filename)
        }
        .accessibilityAction(named: "Copy path") {
            actions.copyPath(file.filename)
        }
    }
}
