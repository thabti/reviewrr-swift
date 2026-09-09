import AppKit
import SwiftUI

/// The dashboard's right column: search/filter controls plus the grouped,
/// scrollable PR inbox. Every state the product plan calls out — no
/// token, no watched projects, first-load, filtered-to-nothing, and a
/// populated inbox — gets its own explicit rendering, each with one
/// obvious next action, rather than a blank screen.
struct InboxPanelView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: DashboardModel
    @Binding var selectedRowID: String?
    var searchFocused: FocusState<Bool>.Binding
    @Binding var showAddProject: Bool
    let onSelectRow: (InboxPR) -> Void
    var onResumeDraft: (PRReference) -> Void = { _ in }
    @Environment(\.reviewrrTextScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if model.showsSavedReviews {
                DashboardDraftsView(reviews: model.savedReviews, onResume: onResumeDraft, onClear: model.clearSavedReviews, clearError: model.draftClearError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InboxFilterBar(model: model, searchFocused: searchFocused)
                Divider()
                // One surface swapping for another (loading → empty → populated)
                // is exactly what `Motion.surface` is for; `contentStateKey`
                // exists purely to give that swap something to animate on.
                content.motion(Motion.surface, value: contentStateKey)
                Divider()
                HStack {
                    Text("\(model.filteredRows.count) pull requests")
                    Text("· Click a PR to open")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Open Pull Request") {
                        if let pr = model.filteredRows.first(where: { $0.id == selectedRowID }) { onSelectRow(pr) }
                    }
                    .disabled(selectedRowID == nil)
                    .help("Open the selected pull request, or press Return")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .onChange(of: model.selectedProjectKey) { _, _ in
            model.showsSavedReviews = false
        }
    }

    private var contentStateKey: String {
        if !model.hasToken && model.projects.isEmpty { return "no-token" }
        if model.projects.isEmpty { return "no-projects" }
        if model.rows.isEmpty && !model.hasCompletedFirstSync { return "loading" }
        if model.filteredRows.isEmpty { return model.filter.isEmpty ? "zero" : "no-match" }
        return "rows"
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasToken && model.projects.isEmpty {
            EmptyStateWithAction(
                systemImage: "key.slash",
                title: "No GitHub token",
                message: "Add a token in Settings, then watch a project to start building your inbox."
            ) {
                Button { openSettings(.account) } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .buttonStyle(.reviewrrPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.projects.isEmpty {
            EmptyStateWithAction(
                systemImage: "tray",
                title: "Nothing watched yet",
                message: "Add a project on the left to start seeing its pull requests here."
            ) {
                Button {
                    showAddProject = true
                } label: {
                    Label("Add a Project", systemImage: "plus")
                }
                .buttonStyle(.reviewrrPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty && model.projects.contains(where: { $0.lastError != nil }) {
            EmptyStateWithAction(
                systemImage: "exclamationmark.icloud",
                title: "Unable to load pull requests",
                message: "A project could not sync. Check its error in the sidebar, or review your GitHub access in Settings."
            ) {
                HStack {
                    Button { openSettings(.account) } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    Button("Try Again") { Task { await model.refreshAll(force: true) } }
                        .disabled(model.isRefreshingAll)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty && !model.hasCompletedFirstSync {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your PR inbox…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredRows.isEmpty {
            Group {
                if model.filter.isEmpty {
                    EmptyStateWithAction(
                        systemImage: "checkmark.circle",
                        title: "Inbox zero",
                        message: "No pull requests across your watched projects right now."
                    ) {
                        Button {
                            Task { await model.refreshAll(force: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.reviewrrSecondary)
                    }
                } else {
                    EmptyStateWithAction(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "No matches",
                        message: "Nothing matches the current search and filters."
                    ) {
                        Button {
                            model.searchText = ""
                            model.filter = InboxFilter()
                        } label: {
                            Label("Reset Search and Filters", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.reviewrrPrimary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedRowID) {
                    groupedContent
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    guard let id = selectedRowID,
                          let pr = model.filteredRows.first(where: { $0.id == id }) else { return .ignored }
                    onSelectRow(pr)
                    return .handled
                }
                .onChange(of: selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: model.filteredRows.map(\.id)) { _, ids in
                    if let selectedRowID, !ids.contains(selectedRowID) { self.selectedRowID = nil }
                }
            }
        }

        if let error = model.bucketsError {
            Divider()
            HStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.removedText)
                Spacer()
                Button("Retry") {
                    Task { await model.refreshAll(force: true) }
                }
                .buttonStyle(.reviewrrGhost)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var groupedContent: some View {
        switch model.grouping {
        case .byProject:
            ForEach(model.projectGroups) { group in
                if !group.rows.isEmpty {
                    section(
                        key: group.project.key, title: group.project.repo,
                        subtitle: group.project.owner, rows: group.rows, project: group.project
                    )
                }
            }
        case .byReviewerBucket:
            ForEach(model.bucketGroups) { group in
                if !group.rows.isEmpty {
                    section(
                        key: group.bucket.rawValue, title: group.bucket.label,
                        subtitle: nil, rows: group.rows, systemImage: group.bucket.systemImage
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func section(
        key: String, title: String, subtitle: String?, rows groupRows: [InboxPR],
        systemImage: String? = nil, project: WatchedProject? = nil
    ) -> some View {
        let visible = model.visibleRows(groupRows, groupKey: key)
        let hidden = model.hiddenRowCount(groupRows, groupKey: key)
        Section {
            // A section headed by a watched project already names the
            // repository; the rows under it need only the number.
            rows(visible, showsRepository: project == nil)
            if hidden > 0 {
                showMoreButton(key: key, hidden: hidden)
            } else if model.isShowingAllRows(groupKey: key), groupRows.count > DashboardModel.collapsedGroupRowLimit {
                showLessButton(key: key, total: groupRows.count)
            }
        } header: {
            InboxSectionHeaderView(
                model: model, key: key, title: title, subtitle: subtitle,
                count: groupRows.count, systemImage: systemImage, project: project, scale: scale
            )
        }
    }

    /// Expand/collapse is a layout change the reviewer is looking straight
    /// at, so it gets the same "direct manipulation" spring every other
    /// disclosure in the app uses — gated on Reduce Motion like the rest.
    private func showMoreButton(key: String, hidden: Int) -> some View {
        disclosureRow(
            title: "Show \(hidden) more",
            symbol: "chevron.down",
            help: "Show the remaining \(hidden) pull requests in this group",
            accessibilityLabel: "Show \(hidden) more pull requests",
            key: key
        )
    }

    private func showLessButton(key: String, total: Int) -> some View {
        disclosureRow(
            title: "Show fewer",
            symbol: "chevron.up",
            help: "Collapse back to the first \(DashboardModel.collapsedGroupRowLimit) of \(total)",
            accessibilityLabel: "Collapse back to the first \(DashboardModel.collapsedGroupRowLimit) of \(total)",
            key: key
        )
    }

    /// The row that expands or collapses a group.
    ///
    /// Two things were wrong with it. It carried the list's own separator, so
    /// it sat between a full-bleed rule above and the *inset* rule of the next
    /// row below — two lines of different lengths bracketing one control. And
    /// it was a full-width ghost button holding a leading-aligned label, so
    /// the text floated at the left of a row-wide hover fill that lined up
    /// with nothing.
    ///
    /// It is now a plain row: no separator of its own, content on the same
    /// leading edge as the pull-request rows above it, and a hover highlight
    /// the width of the row it actually is.
    private func disclosureRow(
        title: String,
        symbol: String,
        help: String,
        accessibilityLabel: String,
        key: String
    ) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.snappy) { model.toggleShowingAllRows(groupKey: key) }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.reviewrr(10, scale: scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.reviewrr(12, scale: scale, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.cornerRadiusSmall)
        .listRowSeparator(.hidden)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func rows(_ prs: [InboxPR], showsRepository: Bool = true) -> some View {
        ForEach(prs) { pr in
            InboxRowView(
                pr: pr, localStatus: model.localStatus(for: pr),
                isSelected: selectedRowID == pr.id, showsRepository: showsRepository
            )
                .id(pr.id)
                .tag(pr.id)
                .listRowSeparator(.visible)
                // Pinned to the row's own edges. A `List` derives a
                // separator's inset from where it thinks the row's content
                // begins, and with a narrow leading column and a wide
                // trailing cluster it decided that was the signal column —
                // drawing a short rule floating under the numbers on the
                // right instead of a divider across the row.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing]
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedRowID = pr.id
                    onSelectRow(pr)
                }
                .help("Click to open this pull request, or select it with the arrow keys and press Return")
                .accessibilityHint("Click once to open. Use arrow keys and Return from the keyboard.")
                .accessibilityAction { onSelectRow(pr) }
                .accessibilityAction(named: "Open Pull Request") { onSelectRow(pr) }
                .contextMenu {
                    Button("Open Pull Request") { onSelectRow(pr) }
                    Divider()
                    ForEach(LocalReviewStatus.allCases, id: \.self) { status in
                        Button(status.label) { model.setLocalStatus(status, for: pr.reference) }
                    }
                    Divider()
                    // Two links, named for where they land: the forge one
                    // for anyone, the `reviewrr://` one for a teammate who
                    // has the app and should land straight in the workspace.
                    // Named for *this row's* forge, because the inbox polls
                    // every configured host and two rows in one list can
                    // come from different ones.
                    Button("Copy \(pr.host.forge.displayName) Link") {
                        copyToPasteboard(webURL(for: pr).absoluteString)
                    }
                    if let deepLink = pr.reference.deepLinkURL {
                        Button("Copy Reviewrr Link") {
                            copyToPasteboard(deepLink.absoluteString)
                        }
                    }
                    Button("Open on \(pr.host.forge.displayName)") {
                        NSWorkspace.shared.open(webURL(for: pr))
                    }
                }
                .motionTransition(.reviewrrRow)
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Through `ForgeHost.webURL`, which knows both path grammars.
    ///
    /// This built `/pull/` by hand, so every GitLab row copied and opened a
    /// URL that 404s — GitLab's is `/-/merge_requests/`. The host's own
    /// builder was already right and already used by the workspace; the
    /// inbox just never called it.
    private func webURL(for pr: InboxPR) -> URL {
        pr.host.webURL(owner: pr.owner, repo: pr.repo, number: pr.number) ?? pr.host.webBaseURL
    }
}

/// Disclosure and project actions stay separate so keyboard users can reach each control.
private struct InboxSectionHeaderView: View {
    @ObservedObject var model: DashboardModel
    let key: String
    let title: String
    let subtitle: String?
    let count: Int
    let systemImage: String?
    let project: WatchedProject?
    let scale: CGFloat


    private var collapsed: Bool { model.isCollapsed(groupKey: key) }

    var body: some View {
        // The accordion trigger and the action buttons are siblings, not
        // nested: a Button inside another Button's label does not reliably
        // receive its own clicks on macOS — the outer one swallows them, so
        // "Open on GitHub" would silently toggle the section instead.
        HStack(spacing: 4) {
            Button {
                model.toggleCollapsed(groupKey: key)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.reviewrr(10, scale: scale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .motion(Motion.snappy, value: collapsed)

                    if let systemImage {
                        Image(systemName: systemImage).font(.reviewrr(12, scale: scale))
                    }

                    Text(title)
                        .font(.reviewrr(14, scale: scale, weight: .semibold))
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.reviewrr(11, scale: scale))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Text("\(count)")
                        .font(.reviewrr(11, scale: scale, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .motion(Motion.smooth, value: count)

                    Spacer(minLength: 0)
                }
                // The Spacer keeps the whole title row clickable, so the
                // accordion target is the header minus the action buttons.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand \(title)" : "Collapse \(title)")
            .accessibilityLabel("\(title), \(count) pull requests")
            .accessibilityHint(collapsed ? "Expand" : "Collapse")

            if let project {
                headerActions(for: project)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // `Theme.barMaterial` is the token for surfaces layered over
        // scrolling content — this header pins via `.sectionHeaders`, so it
        // needs the same vibrancy as every other sticky bar in the app.
        .background(Theme.barMaterial)
    }

    /// Filter icon lit means "the sidebar and this header agree the inbox is
    /// scoped to this project" — same published state either one sets.
    private func isFilteredToProject(_ project: WatchedProject) -> Bool {
        model.selectedProjectKey == project.key
    }

    @ViewBuilder
    private func headerActions(for project: WatchedProject) -> some View {
        let filtered = isFilteredToProject(project)
        HStack(spacing: 2) {
            Button {
                model.selectedProjectKey = filtered ? nil : project.key
            } label: {
                Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.reviewrr(12, scale: scale))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(filtered ? Theme.accent : .secondary)
            .help(filtered ? "Show every watched project" : "Filter the inbox to \(project.nameWithOwner)")
            .accessibilityLabel(filtered ? "Showing only \(project.nameWithOwner)" : "Filter the inbox to \(project.nameWithOwner)")
            .accessibilityHint(filtered ? "Shows every watched project" : "")

            Button {
                NSWorkspace.shared.open(project.webURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.reviewrr(12, scale: scale))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(project.nameWithOwner) on \(project.host.forge.displayName)")
            .accessibilityLabel("Open \(project.nameWithOwner) on \(project.host.forge.displayName)")
        }
    }
}

/// `EmptyStateView` plus one obvious next action. Composed here rather than
/// added to `EmptyStateView` itself, which this track doesn't own — every
/// blank state in the dashboard needs a primary button, not a grey sentence.
private struct EmptyStateWithAction<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let action: Action

    init(systemImage: String, title: String, message: String, @ViewBuilder action: () -> Action) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 16) {
            EmptyStateView(systemImage: systemImage, title: title, message: message)
            action
        }
        .motionTransition(.reviewrrPanel)
    }
}
