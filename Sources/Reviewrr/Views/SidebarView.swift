import SwiftUI

/// The review workspace's left column: what this pull request *is* at the
/// top, what to filter it by in the middle, and the file tree filling the
/// rest.
///
/// Summary and filters sit in a pinned inset rather than as the first rows
/// of the `List`. Scrolling a 675-file tree used to carry the search field
/// away with it, so the one control a reviewer reaches for while lost in a
/// long list was the first thing to disappear.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    @State private var progress = ReviewProgress(overallViewed: 0, overallTotal: 0, byCategory: [])

    var body: some View {
        Group {
            if let pr = model.pullRequest {
                fileList(pr: pr)
            } else {
                EmptyStateView(
                    systemImage: "tray",
                    title: "No pull request open",
                    message: "Paste a PR URL to get started."
                )
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle("")
    }

    /// Split out from `body` as its own function (rather than inlined into
    /// the `if let pr` branch above) purely for compile speed: one giant
    /// expression carrying a `List`, two `safeAreaInset`s, a `task`, and four
    /// `onChange`s together was measured over Reviewrr's 120ms per-`body`
    /// type-check budget; the compiler type-checks each function
    /// independently, so splitting it in two keeps both fast.
    private func fileList(pr: PullRequest) -> some View {
        List(selection: $model.selectedFile) {
            Section {
                FileTreeView(workspace: workspace)
            } header: {
                filesHeader
            }
        }
        .listStyle(.sidebar)
        // Filter/sort/search changes reshape the tree; letting the
        // rows animate in and out (rather than the filter bar that
        // triggered it) is what makes the change read as "the list
        // updated" instead of a hard cut.
        .motion(Motion.smooth, value: workspace.tree)
        .safeAreaInset(edge: .top, spacing: 0) { header(pr: pr) }
        .safeAreaInset(edge: .bottom, spacing: 0) { filterFooter }
        .task(id: model.reference?.key) {
            guard let reference = model.reference else { return }
            workspace.configureIfNeeded(prKey: reference.key, hiddenFileCategories: model.settings.hiddenFileCategories)
            workspace.refresh(files: model.files)
            recomputeProgress()
        }
        .onChange(of: model.files) { _, newFiles in
            workspace.refresh(files: newFiles)
            recomputeProgress()
        }
        .onChange(of: model.draft.viewedFiles) { _, _ in recomputeProgress() }
        .onChange(of: workspace.classifications) { _, _ in recomputeProgress() }
        .onChange(of: workspace.searchText) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: workspace.sortOption) { _, _ in workspace.refresh(files: model.files) }
        .onChange(of: workspace.hiddenCategories) { _, _ in workspace.refresh(files: model.files) }
        // A jump can reveal a file the filters were hiding; the tree has to
        // show it too, or the pane and the tree disagree about what exists.
        .onChange(of: workspace.revealedPaths) { _, _ in workspace.refresh(files: model.files) }
    }

    // MARK: - Pinned header

    /// One material, one inset, one hairline between blocks. The summary
    /// sets its own 44pt identity row and its own bottom inset; the filter
    /// block adds `Space.s` above and below a `Theme.controlHeight` field,
    /// which lands it on a whole 44pt too — the same height as the right
    /// rail's identity line and the diff toolbar. The header, the footer
    /// and every block between them share one `Space.m` margin on both
    /// sides; the tree in the middle keeps the `List`'s own sidebar insets,
    /// which are the system's to set.
    private func header(pr: PullRequest) -> some View {
        VStack(spacing: 0) {
            if let reference = model.reference {
                PRSummaryCard(pr: pr, reference: reference)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.barMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Filtering lives under the tree, not over it.
    ///
    /// It sat above, between the pull request's summary and the files —
    /// which put three rows of controls, chips and a "4 files hidden" line
    /// between a reviewer and the thing they came to the column for. The
    /// list is the content; the controls that narrow it belong at the edge,
    /// next to the progress that summarises it.
    private var filterFooter: some View {
        VStack(spacing: 0) {
            FilterBarView(workspace: workspace, onHiddenCategoriesChanged: persistHiddenCategories)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
            ReviewProgressFooter(progress: progress)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.barMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    /// The tree's own section header carries the "you are not seeing all of
    /// them" fact, next to the count it applies to.
    private var filesHeader: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Files")
            Spacer(minLength: Theme.Space.xs)
            Text("\(workspace.orderedVisiblePaths.count) of \(model.files.count)")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .motion(Motion.smooth, value: workspace.orderedVisiblePaths.count)
        }
        .frame(maxWidth: .infinity)
        .help("\(workspace.orderedVisiblePaths.count) of \(model.files.count) changed files shown")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Files, \(workspace.orderedVisiblePaths.count) of \(model.files.count) shown")
    }

    /// Cached rather than recomputed in `body`. The calculation walks every
    /// changed file — 675 of them on the pull request this was built for —
    /// and `body` re-runs on any `AppModel` publish, so it was paying a full
    /// pass over the file list to answer a question whose inputs only change
    /// when a file is marked viewed, the filters reclassify, or the PR
    /// reloads. Progress deliberately counts every changed file, including
    /// the ones the filters are hiding: hiding lockfiles must not quietly
    /// shrink how much of the pull request you have read.
    private func recomputeProgress() {
        progress = ReviewProgressCalculator.progress(
            files: model.files, classifications: workspace.classifications, viewedFiles: model.draft.viewedFiles
        )
    }

    /// The filter bar toggles session state on `WorkspaceModel` directly;
    /// this just mirrors the resulting hidden-category set back into
    /// `AppSettings` so it becomes tomorrow's default.
    private func persistHiddenCategories(_ hidden: Set<FileCategory>) {
        model.settings.hiddenFileCategories = Set(hidden.map(\.rawValue))
        model.persistSettings()
    }
}
