import SwiftUI

/// Search field, grouping/sort pickers, and the filter menu — the
/// dashboard inbox's control row.
struct InboxFilterBar: View {
    @ObservedObject var model: DashboardModel
    var searchFocused: FocusState<Bool>.Binding
    @Binding var sidebarCollapsed: Bool
    @Environment(\.reviewrrTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { sidebarCollapsed.toggle() } label: {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarCollapsed ? "Show projects" : "Hide projects")
                .accessibilityLabel("Toggle project sidebar")

                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeTitle)
                        .font(.reviewrr(20, scale: scale, weight: .semibold))
                        .lineLimit(1)
                    // "Merge Requests" on a GitLab host. Calling them pull
                    // requests in a GitLab shop is the kind of small
                    // wrongness that makes a tool feel foreign.
                    Text(model.host.forge.changeNounCapitalized + "s")
                        .font(.reviewrr(12, scale: scale))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ActivityButton(model: model)
                Button {
                    Task { await model.refreshAll(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshingAll)
                .help("Refresh pull requests (⌘R)")
                .accessibilityLabel("Refresh pull requests")
                if model.isRefreshingAll { ProgressView().controlSize(.small) }
            }
            searchField
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Picker("Group by", selection: $model.grouping) {
                    ForEach(InboxGrouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Picker("Sort by", selection: $model.sortField) {
                    Text("Recently updated").tag(InboxSortField.updated)
                    Text("Newest created").tag(InboxSortField.created)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
                FilterMenu(model: model)
            }
            if !model.filter.projectKeys.isEmpty {
                ProjectFilterChips(model: model)
            }
        }
        .padding(16)
        .background(Theme.barMaterial)
        .background {
            Button("Search Pull Requests") { searchFocused.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var scopeTitle: String {
        model.projects.first(where: { $0.key == model.selectedProjectKey })?.repo ?? "All Projects"
    }

    /// Search is the control a reviewer reaches for most on this screen, so
    /// it gets real field chrome, a focus ring, and type large enough to
    /// read a repository name in — not a tinted strip with 11pt text.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.reviewrr(13, scale: scale))
                .foregroundStyle(searchFocused.wrappedValue ? Theme.accent : .secondary)

            TextField("Search title, number, author, branch, label…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.reviewrr(14, scale: scale))
                .focused(searchFocused)
                .accessibilityLabel("Search pull requests")
                .onKeyPress(.escape) {
                    model.searchText = ""
                    searchFocused.wrappedValue = false
                    return .handled
                }

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.reviewrr(12, scale: scale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                Text("⌘F")
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .help("Press ⌘F to search")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    searchFocused.wrappedValue ? Theme.accent.opacity(0.65) : Theme.cardStroke,
                    lineWidth: searchFocused.wrappedValue ? 1.5 : 1
                )
        )
        .motion(Motion.hover, value: searchFocused.wrappedValue)
        .frame(minWidth: 180, maxWidth: .infinity)
        .onTapGesture { searchFocused.wrappedValue = true }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// One removable token per project key in `model.filter.projectKeys`. In
/// practice there is exactly one — the sidebar and the inbox's section
/// headers both scope through `selectedProjectKey`, which only ever holds a
/// single key — but the chip renders straight off the underlying set rather
/// than that convenience accessor, so it stays correct if the filter menu
/// ever grows a multi-project picker.
private struct ProjectFilterChips: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.filter.projectKeys), id: \.self) { key in
                ProjectFilterChip(title: projectTitle(for: key)) {
                    model.filter.projectKeys.remove(key)
                }
            }
        }
        .motionTransition(.reviewrrRow)
    }

    private func projectTitle(for key: String) -> String {
        model.projects.first { $0.key == key }?.nameWithOwner ?? "Unknown project"
    }
}

private struct ProjectFilterChip: View {
    let title: String
    let onRemove: () -> Void
    @Environment(\.reviewrrTextScale) private var scale

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.reviewrr(10, scale: scale))
                .accessibilityHidden(true)

            Text(title)
                .font(.reviewrr(11, scale: scale, weight: .medium))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.reviewrr(10, scale: scale))
            }
            .buttonStyle(.plain)
            .help("Remove this filter")
            .accessibilityLabel("Remove filter: \(title)")
        }
        .foregroundStyle(Theme.accent)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
        .help("Inbox filtered to \(title)")
    }
}

private struct FilterMenu: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Menu {
            Section("State") {
                ForEach(InboxPRState.allCases, id: \.self) { state in
                    Toggle(state.label, isOn: binding(for: state))
                }
            }
            Section("Local status") {
                ForEach(LocalReviewStatus.allCases, id: \.self) { status in
                    Toggle(status.label, isOn: binding(for: status))
                }
            }
            Toggle("Review requested of me", isOn: $model.filter.reviewRequestedOfMeOnly)
            Section("Updated within") {
                Button("Any time") { model.filter.updatedWithinDays = nil }
                Button("24 hours") { model.filter.updatedWithinDays = 1 }
                Button("7 days") { model.filter.updatedWithinDays = 7 }
                Button("30 days") { model.filter.updatedWithinDays = 30 }
            }
            if !model.filter.isEmpty {
                Divider()
                Button("Clear filters") { model.filter = InboxFilter(searchText: model.filter.searchText) }
            }
        } label: {
            Label("Filter", systemImage: model.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.reviewrrGhost)
        .help("Filter and sort the inbox")
    }

    private func binding(for state: InboxPRState) -> Binding<Bool> {
        Binding(
            get: { model.filter.states.contains(state) },
            set: { isOn in
                if isOn { model.filter.states.insert(state) } else { model.filter.states.remove(state) }
            }
        )
    }

    private func binding(for status: LocalReviewStatus) -> Binding<Bool> {
        Binding(
            get: { model.filter.localStatuses.contains(status) },
            set: { isOn in
                if isOn { model.filter.localStatuses.insert(status) } else { model.filter.localStatuses.remove(status) }
            }
        )
    }
}

/// In-app activity feed: what the most recent polls discovered (new PRs,
/// updated PRs, new review requests), independent of native notifications.
private struct ActivityButton: View {
    @ObservedObject var model: DashboardModel
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                if !model.recentActivity.isEmpty {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.reviewrrGhost)
        .motion(Motion.smooth, value: model.recentActivity.isEmpty)
        .help("Recent activity")
        .accessibilityLabel("Recent activity, \(model.recentActivity.count) events")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            activityList
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                if !model.recentActivity.isEmpty {
                    Button("Clear") { model.recentActivity.removeAll() }
                        .buttonStyle(.reviewrrGhost)
                        .font(.caption)
                }
            }
            .padding(12)
            Divider()
            if model.recentActivity.isEmpty {
                Text("Nothing new since you last checked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.recentActivity.reversed()) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    // What changed, not just "Updated": the
                                    // feed knows which triggers fired, and
                                    // "Updated" was the one word that told a
                                    // reviewer nothing they could act on.
                                    Text(event.summary)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer(minLength: 0)
                                    if event.wasNotified {
                                        Image(systemName: "bell.badge")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                            .help("This one also went out as a notification")
                                            .accessibilityLabel("Notified")
                                    }
                                }
                                Text("\(event.projectName) · #\(event.pr.number) \(event.pr.title)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .motionTransition(.reviewrrRow)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(event.summary). \(event.projectName) pull request \(event.pr.number), \(event.pr.title)")
                        }
                    }
                    .padding(12)
                    .motion(Motion.smooth, value: model.recentActivity)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
    }

}
