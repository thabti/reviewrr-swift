import SwiftUI

/// Search, sort, and per-category visibility for the file tree.
///
/// Category visibility used to be a horizontally scrolling strip of eleven
/// chips inside a 300pt column, which meant most of the filters — and the
/// counts that justify them — sat permanently off the right edge. They live
/// in a menu now, where every category is reachable and labelled, and the
/// bar itself shows only the filters that are actually *on*, so the row
/// stays one line for the common case and wraps rather than clips when it
/// isn't.
///
/// Category visibility is session state on `WorkspaceModel`, but the
/// *default* set of hidden categories is a persisted preference
/// (`AppSettings.hiddenFileCategories`) — this view is the only place that
/// writes that preference back, via `onHiddenCategoriesChanged`.
struct FilterBarView: View {
    @ObservedObject var workspace: WorkspaceModel
    let onHiddenCategoriesChanged: (Set<FileCategory>) -> Void
    @FocusState private var searchFocused: Bool
    /// What the reviewer has typed so far, which is not the same thing as
    /// what the tree is filtered by.
    ///
    /// Binding the field straight to `workspace.searchText` re-filtered,
    /// re-sorted and re-measured the whole pull request on every keystroke —
    /// and because the diff pane's horizontal canvas is sized from the widest
    /// visible line, typing "vie" resized the canvas three times and replaced
    /// every section under a scroll offset that no longer meant anything.
    @State private var searchDraft: String = ""
    @State private var searchDebounce: Task<Void, Never>?

    /// The categories with something actually hidden behind them, in review
    /// order. Read straight off the model's own tally rather than rebuilt
    /// from `classifications`: this runs on every `body`, and walking 675
    /// classifications to answer a question the model already answered
    /// during `refresh` is exactly the per-body work the workspace is
    /// trying to shed. A category hidden by preference but absent from this
    /// PR has no tally, and correctly gets no chip.
    private var hiddenCategories: [FileCategory] {
        workspace.hiddenCountByCategory.keys.sorted { $0.reviewPriority < $1.reviewPriority }
    }

    /// Every changed file the tree is not showing — category filters *and*
    /// the search term. Summing `hiddenCountByCategory` alone under-reported
    /// the moment a reviewer typed in the field, which is exactly when the
    /// line is being read.
    private var hiddenFileCount: Int {
        max(0, workspace.classifications.count - workspace.orderedVisiblePaths.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            searchRow
            if !workspace.hiddenCountByCategory.isEmpty {
                activeFilters
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.smooth, value: workspace.hiddenCategories)
        .onAppear { searchDraft = workspace.searchText }
        // Long enough to swallow a typing burst, short enough that the tree
        // still feels like it is answering the keystroke.
        .onChange(of: searchDraft) { _, typed in
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                workspace.searchText = typed
            }
        }
        // The `/` shortcut and "clear" act on the model; mirror those back
        // into the field so the two never disagree.
        .onChange(of: workspace.searchText) { _, value in
            if value != searchDraft { searchDraft = value }
        }
        .onChange(of: workspace.searchFieldFocusRequested) { _, requested in
            guard requested else { return }
            searchFocused = true
            workspace.searchFieldFocusRequested = false
        }
    }

    // MARK: - Search row

    /// A recess in the header's material rather than a card on top of it:
    /// one fill, one hairline, and the accent ring only while focused. Held
    /// to `Theme.controlHeight` so the whole filter block is a round 44pt,
    /// the same as the identity row above it.
    private var searchRow: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.iconMediumSize))
                .foregroundStyle(searchFocused ? Theme.accent : .secondary)
                .help("Filter files by path (/)")
                .accessibilityHidden(true)

            TextField("Filter files", text: $searchDraft)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($searchFocused)
                .frame(maxWidth: .infinity)
                .help("Filter files by path (/)")
                .accessibilityLabel("Filter files by path")

            if !searchDraft.isEmpty {
                Button {
                    searchDebounce?.cancel()
                    searchDraft = ""
                    workspace.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the path filter")
                .accessibilityLabel("Clear the path filter")
            }

            sortMenu
            categoryMenu
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.controlHeight)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                .strokeBorder(searchFocused ? Theme.focusRing : Theme.hairline, lineWidth: 1)
        )
        .motion(Motion.hover, value: searchFocused)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $workspace.sortOption) {
                ForEach(FileSortOption.allCases) { option in
                    Label(option.label, systemImage: option.symbolName).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: workspace.sortOption.symbolName)
                .font(.system(size: Theme.iconMediumSize))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort files: \(workspace.sortOption.label)")
        .accessibilityLabel("Sort files, currently \(workspace.sortOption.label)")
    }

    /// Every present category with its count, so the reviewer can see what
    /// this PR is *made of* while deciding what to hide — the information
    /// the old chip strip clipped away.
    private var categoryMenu: some View {
        Menu {
            Section("Show file types") {
                categoryToggles()
            }
            Divider()
            Button("Show all file types") { setHidden([]) }
                .disabled(workspace.hiddenCategories.isEmpty)
            Button("Hide generated files and lockfiles") { setHidden([.generated, .lockfile]) }
        } label: {
            Image(systemName: workspace.hiddenCategories.isEmpty
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: Theme.iconMediumSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(workspace.hiddenCategories.isEmpty ? Color.secondary : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filterHelp)
        .accessibilityLabel(filterHelp)
    }

    /// One pass over the classifications for the whole menu. The counts used
    /// to be a `filter().count` per category — eleven walks of the file set
    /// to build one menu — and they double-counted every hidden category,
    /// which classifications and the hidden tally both include.
    private func categoryToggles() -> some View {
        var counts: [FileCategory: Int] = [:]
        for classification in workspace.classifications.values {
            counts[classification.category, default: 0] += 1
        }
        let present = FileCategory.allCases
            .filter { counts[$0] != nil }
            .sorted { $0.reviewPriority < $1.reviewPriority }

        return ForEach(present) { category in
            Toggle(isOn: visibility(of: category)) {
                Label("\(category.label) (\(counts[category] ?? 0))", systemImage: category.symbolName)
            }
        }
    }

    private var filterHelp: String {
        let hidden = workspace.hiddenCategories.count
        return hidden == 0
            ? "Filter by file type"
            : "Filter by file type — \(hidden) type\(hidden == 1 ? "" : "s") hidden"
    }

    // MARK: - Active filters

    /// Only the *hidden* categories get a chip, and each carries the number
    /// of files it is currently holding back. A filter you can't see is a
    /// filter you forget you set, and this row is the one place that admits
    /// files are missing from the tree below it.
    private var activeFilters: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                ForEach(hiddenCategories) { category in
                    CategoryChip(
                        category: category,
                        count: workspace.hiddenCountByCategory[category],
                        isHidden: true,
                        action: {
                            workspace.toggleCategory(category)
                            onHiddenCategoriesChanged(workspace.hiddenCategories)
                        }
                    )
                }
                Button("Show all") { setHidden([]) }
                    .buttonStyle(.reviewrrChip(selected: false))
                    .help("Show every hidden file type again")
                    .accessibilityLabel("Show every hidden file type again")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hiddenFileCount > 0 {
                Text("\(hiddenFileCount) file\(hiddenFileCount == 1 ? "" : "s") hidden")
                    .font(Theme.caption)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Mutation

    private func visibility(of category: FileCategory) -> Binding<Bool> {
        Binding(
            get: { !workspace.hiddenCategories.contains(category) },
            set: { shown in
                var hidden = workspace.hiddenCategories
                if shown { hidden.remove(category) } else { hidden.insert(category) }
                setHidden(hidden)
            }
        )
    }

    private func setHidden(_ hidden: Set<FileCategory>) {
        workspace.hiddenCategories = hidden
        onHiddenCategoriesChanged(hidden)
    }
}
