import AppKit
import SwiftUI

/// The dashboard's left column: search, the persistent watchlist, and the
/// entry point for watching a new repository. A native `List(selection:)`
/// rather than a plain scroll of rows, so arrow keys, click, and Return all
/// move through it the way every other macOS sidebar does — the reviewer
/// never has to learn a Reviewrr-specific interaction.
struct ProjectSidebarView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: DashboardModel
    @Binding var showAddProject: Bool
    @Environment(\.reviewrrTextScale) private var scale

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// Rows this list can select: the synthetic "All Projects" row plus one
    /// per watched project. Bridging to `model.selectedProjectKey` directly
    /// (rather than mirroring it into local `@State`) means there is nothing
    /// for a poll to desynchronize — the list's selection *is* the model's,
    /// every render.
    private enum Row: Hashable {
        case all
        case project(String)
    }

    private var selection: Binding<Row?> {
        Binding(
            get: { model.selectedProjectKey.map(Row.project) ?? .all },
            set: { newValue in
                if case .project(let key)? = newValue {
                    model.selectedProjectKey = key
                } else if case .all? = newValue {
                    model.selectedProjectKey = nil
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !model.hasToken {
                tokenWarning
            }

            if model.projects.isEmpty {
                emptyWatchlist
            } else {
                searchField
                projectList
                Divider()
                footer
            }
        }
        .background(Theme.columnSurface)
        .background(alignment: .topLeading) { focusShortcut }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Projects")
                    .font(.reviewrr(16, scale: scale, weight: .semibold))
                Text("\(model.projects.count) watched · \(totalUnreadCount) unread")
                    .font(.reviewrr(11, scale: scale))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.refreshAll(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isRefreshingAll || model.projects.isEmpty || !model.hasToken)
            .help("Refresh all watched projects")
            .accessibilityLabel("Refresh all watched projects")
        }
        .padding(14)
        .background(Theme.columnSurface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(syncSummary, systemImage: model.isRefreshingAll ? "arrow.triangle.2.circlepath" : "tray.full")
                .font(.reviewrr(11, scale: scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            addProjectButton
        }
        .padding(12)
        .background(Theme.columnSurface)
    }

    private var syncSummary: String {
        if model.isRefreshingAll { return "Refreshing projects…" }
        let failures = model.projects.filter { $0.lastError != nil }.count
        if failures > 0 { return "\(failures) project\(failures == 1 ? "" : "s") couldn’t sync" }
        return "\(totalOpenCount) open pull requests"
    }

    private var tokenWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No GitHub token", systemImage: "key.slash")
                .font(.reviewrr(12, scale: scale, weight: .medium))
            Text("Add one in Settings to see private repositories.")
                .font(.reviewrr(11, scale: scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { openSettings(.account) }
                .buttonStyle(.reviewrrSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var emptyWatchlist: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                systemImage: "tray",
                title: "No watched projects",
                message: "Add a repository to start building your PR inbox."
            )
            addProjectButton
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Search

    /// Filters the *watchlist*, not the inbox — a separate field from the
    /// one in `InboxFilterBar`, which searches PR content within whatever
    /// project scope this sidebar has selected.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.reviewrr(11, scale: scale))
                .foregroundStyle(searchFocused ? Theme.accent : .secondary)

            TextField("Search owner or repo…", text: $searchText)
                .accessibilityLabel("Search watched projects")
                .textFieldStyle(.plain)
                .font(.reviewrr(12, scale: scale))
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    if !searchText.isEmpty {
                        searchText = ""
                    } else {
                        searchFocused = false
                    }
                    return .handled
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.reviewrr(11, scale: scale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                Text("⇧⌘F")
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .help("Press ⇧⌘F to search watched projects")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.65) : Theme.cardStroke, lineWidth: searchFocused ? 1.5 : 1)
        )
        .motion(Motion.hover, value: searchFocused)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .onTapGesture { searchFocused = true }
    }

    /// A hidden, zero-size button rather than a window command: the shortcut
    /// only makes sense while this sidebar is on screen, and it must not
    /// collide with a menu-bar binding another track adds later.
    private var focusShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .hidden()
            .accessibilityHidden(true)
    }

    // MARK: - List

    private var projectList: some View {
        List(selection: selection) {
            allProjectsRow

            if filteredProjects.isEmpty {
                noMatchesRow
            } else {
                ForEach(projectGroups) { group in
                    Section {
                        ForEach(group.projects) { project in
                            ProjectRowView(
                                project: project,
                                openCount: model.openCount(for: project),
                                unreadCount: model.unreadCount(for: project),
                                isSyncing: model.syncingProjectKeys.contains(project.key),
                                onRefresh: { Task { await model.refresh(project) } },
                                onToggleMute: { model.toggleMute(project) },
                                onCopyURL: { copyURL(project) },
                                onOpenGitHub: { NSWorkspace.shared.open(project.webURL) },
                                onRemove: { remove(project) }
                            )
                            .tag(Row.project(project.key))
                            .motionTransition(.reviewrrRow)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(group.projects.count)")
                                .monospacedDigit()
                        }
                        .help(group.title)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(group.title), \(group.projects.count) project\(group.projects.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Otherwise `List(.sidebar)` paints its own translucent grey over
        // the column's surface, which is what made this band a different
        // colour from the header and footer above and below it.
        .scrollContentBackground(.hidden)
        .motion(Motion.smooth, value: model.projects)
        .motion(Motion.smooth, value: searchText)
    }

    private var allProjectsRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "tray.full")
                .font(.reviewrr(13, scale: scale))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)

            Text("All Projects")
                .font(.reviewrr(13, scale: scale, weight: .semibold))

            Spacer(minLength: 4)

            if !model.syncingProjectKeys.isEmpty {
                ActivityDot(active: true, size: 7).accessibilityHidden(true)
            }
            if totalOpenCount > 0 {
                OpenCountBadge(count: totalOpenCount, hasUnread: totalUnreadCount > 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .tag(Row.all)
        .help("Show every watched project's pull requests")
        .accessibilityLabel(
            "All Projects, \(totalOpenCount) open\(totalUnreadCount > 0 ? ", \(totalUnreadCount) unread" : "")"
        )
    }

    private var noMatchesRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No projects match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(.reviewrr(12, scale: scale, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Clear Search") { searchText = "" }
                .buttonStyle(.reviewrrGhost)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Add project

    private var addProjectButton: some View {
        Button {
            showAddProject = true
        } label: {
            Label("Add Project", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .controlSize(.regular)
        .help("Watch a new project")
        .accessibilityLabel("Add project")
    }

    // MARK: - Derived state

    private struct ProjectGroup: Identifiable {
        let id: String
        let title: String
        let projects: [WatchedProject]
    }

    private var projectGroups: [ProjectGroup] {
        let groups = Dictionary(grouping: filteredProjects) {
            "\($0.host.apiBaseURL.absoluteString)|\($0.owner.lowercased())"
        }
        let multipleHosts = Set(model.projects.map { $0.host.apiBaseURL }).count > 1
        return groups.map { key, projects in
            let project = projects[0]
            let host = project.host.webBaseURL.host ?? project.host.webBaseURL.absoluteString
            return ProjectGroup(
                id: key,
                title: multipleHosts ? "\(project.owner) · \(host)" : project.owner,
                projects: projects
            )
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private var sortedProjects: [WatchedProject] {
        model.projects.sorted { $0.nameWithOwner.localizedStandardCompare($1.nameWithOwner) == .orderedAscending }
    }

    private var filteredProjects: [WatchedProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sortedProjects }
        return sortedProjects.filter {
            $0.owner.lowercased().contains(query)
                || $0.repo.lowercased().contains(query)
                || $0.nameWithOwner.lowercased().contains(query)
        }
    }

    private var totalUnreadCount: Int {
        model.projects.reduce(0) { $0 + model.unreadCount(for: $1) }
    }

    private var totalOpenCount: Int {
        model.projects.reduce(0) { $0 + model.openCount(for: $1) }
    }

    // MARK: - Actions

    private func copyURL(_ project: WatchedProject) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.webURL.absoluteString, forType: .string)
    }

    /// Clears the selection first if the removed project was the one
    /// filtering the inbox — otherwise the inbox would keep filtering to a
    /// project key nothing in the sidebar can select anymore.
    private func remove(_ project: WatchedProject) {
        if model.selectedProjectKey == project.key {
            model.selectedProjectKey = nil
        }
        model.removeProject(project)
    }
}

/// How many open pull requests a project has, shared by the "All Projects"
/// row and each project row.
///
/// The number answers "how much is open here", which is what the reviewer
/// reads it as and what selecting the project will show. Whether any of them
/// are still unseen is carried by the tint instead — accent when there is
/// something new, quiet when the reviewer has seen everything — so one badge
/// says both without claiming 147 things need attention.
private struct OpenCountBadge: View {
    let count: Int
    let hasUnread: Bool
    @Environment(\.reviewrrTextScale) private var scale

    var body: some View {
        Text("\(count)")
            .font(.reviewrr(11, scale: scale, weight: hasUnread ? .semibold : .regular))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (hasUnread ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.08)),
                in: Capsule()
            )
            .foregroundStyle(hasUnread ? Theme.accent : Color.secondary)
            .contentTransition(.numericText())
            .motion(Motion.smooth, value: count)
            .motion(Motion.smooth, value: hasUnread)
    }
}

private struct ProjectRowView: View {
    let project: WatchedProject
    let openCount: Int
    let unreadCount: Int
    let isSyncing: Bool
    let onRefresh: () -> Void
    let onToggleMute: () -> Void
    let onCopyURL: () -> Void
    let onOpenGitHub: () -> Void
    let onRemove: () -> Void
    @Environment(\.reviewrrTextScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            // Grouped and combined for accessibility so VoiceOver reads one
            // sentence for the project, not four fragments — the trailing
            // menu stays its own stop so its actions are still reachable.
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "shippingbox")
                    .font(.reviewrr(13, scale: scale))
                    .foregroundStyle(project.isMuted ? .secondary : Theme.accent)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(project.repo)
                            .font(.reviewrr(13, scale: scale, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if project.isMuted {
                            Image(systemName: "bell.slash")
                                .font(.reviewrr(9, scale: scale))
                                .foregroundStyle(.secondary)
                        }
                    }

                    statusLine
                }
            }
            .opacity(project.isMuted ? 0.6 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .help(project.nameWithOwner)

            Spacer(minLength: 4)

            trailingIndicator

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.reviewrr(12, scale: scale))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More actions for \(project.nameWithOwner)")
            .accessibilityLabel("Actions for \(project.nameWithOwner)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .motion(Motion.smooth, value: isSyncing)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            onRefresh()
        } label: {
            Label("Refresh This Project", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(project.isMuted ? "Unmute" : "Mute", action: onToggleMute)
        Divider()
        Button("Copy URL", action: onCopyURL)
        Button("Open on GitHub", action: onOpenGitHub)
        Divider()
        Button("Remove", role: .destructive, action: onRemove)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if isSyncing {
            // The only place this project row loops: a sync really is in
            // flight, so the pulse earns its keep.
            ActivityDot(active: true, size: 7)
                .accessibilityHidden(true)
        } else if project.lastError != nil {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.reviewrr(11, scale: scale))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.removedText)
            .help("Retry sync for \(project.nameWithOwner)")
            .accessibilityLabel("Retry sync")
        } else if openCount > 0 && !project.isMuted {
            OpenCountBadge(count: openCount, hasUnread: unreadCount > 0)
                .accessibilityHidden(true)
        } else if project.lastSyncedAt != nil && !project.isMuted {
            // A settled, caught-up project gets a quiet checkmark rather
            // than nothing — the same "you're done here" cue Mail gives.
            Image(systemName: "checkmark.circle")
                .font(.reviewrr(11, scale: scale))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = project.lastError {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.reviewrr(9, scale: scale))
                Text(error)
                    .font(.reviewrr(10, scale: scale))
                    .lineLimit(2)
            }
            .foregroundStyle(Theme.removedText)
            .help(error)
        } else {
            Text(statusText)
                .font(.reviewrr(10, scale: scale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        if isSyncing { return "Syncing…" }
        if project.isMuted { return "Muted · automatic sync paused" }
        guard let syncedAt = project.lastSyncedAt else { return "Not synced yet" }
        // A relative formatter renders a just-finished sync as "in 0 seconds"
        // when the timestamp lands a hair in the future, which reads as a
        // bug. Anything inside a minute is simply "just now".
        let elapsed = Date().timeIntervalSince(syncedAt)
        if elapsed < 60 { return "Synced just now" }
        return "Synced \(Self.relativeFormatter.localizedString(for: syncedAt, relativeTo: .now))"
    }

    // `RelativeDateTimeFormatter` construction is locale lookups, not a
    // struct literal — building one per row per render is the kind of
    // per-row formatter cost `InboxRowView` already avoids the same way.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var accessibilitySummary: String {
        var parts = [project.nameWithOwner]
        if project.isMuted { parts.append("muted") }
        if let error = project.lastError {
            parts.append("sync error: \(error)")
        } else {
            parts.append(statusText)
        }
        parts.append("\(openCount) open")
        if unreadCount > 0 { parts.append("\(unreadCount) unread") }
        return parts.joined(separator: ", ")
    }
}
