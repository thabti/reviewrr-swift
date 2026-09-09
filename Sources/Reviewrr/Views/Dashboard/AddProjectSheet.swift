import AppKit
import SwiftUI

/// Watch a project by picking a scope — an organization or an account — and
/// then a repository inside it.
///
/// A flat list of everything the token can see was unusable: 577
/// repositories across 31 owners, led by single-repo personal forks. So the
/// shape is scope-first, the way Vercel makes you choose a team before it
/// shows you projects. Organizations come first because that is where an
/// engineer's reviewable work lives, forks are hidden by default because
/// they were most of the noise, and the picker opens on the busiest
/// organization rather than on "everything".
struct AddProjectSheet: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reviewrrTextScale) private var scale

    @StateObject private var picker: RepositoryPickerModel
    @State private var manualInput = ""
    @State private var showManualEntry = false
    @FocusState private var searchFocused: Bool

    init(model: DashboardModel) {
        self.model = model
        // Constructed here rather than in `load()` so the chosen scope and
        // the selection survive a re-render of the sheet.
        _picker = StateObject(
            wrappedValue: RepositoryPickerModel(
                context: model.context,
                alreadyWatchedKeys: model.watchedKeys,
                availableHosts: model.browsableHosts
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showManualEntry { manualEntry; Divider() }
            HStack(spacing: 0) {
                scopeSidebar
                    .frame(width: 232)
                Divider()
                repositoryPane
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .task {
            await picker.load()
            searchFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Watch a Project")
                    .font(.reviewrr(16, scale: scale, weight: .semibold))
                Text(subtitle)
                    .font(.reviewrr(11, scale: scale))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Only when there is somewhere else to go. A reviewer with one
            // configured host should not be shown a picker with one item.
            if picker.availableHosts.count > 1 {
                Picker("Host", selection: $picker.browsingHost) {
                    ForEach(picker.availableHosts, id: \.identityKey) { host in
                        // The vendor's mark in the menu: a list of
                        // hostnames all look alike, and the shape says
                        // "this is the GitLab one" before the text is read.
                        Label {
                            Text(host.displayName)
                        } icon: {
                            BrandGlyph(brand: .forge(host.forge), size: 13)
                        }
                        .tag(host)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
                .help("Browse a different host — this does not change the host you are reviewing on")
                .accessibilityLabel("Host to browse")
            }

            freshnessIndicator

            Button {
                Task { await picker.refresh(silently: picker.phase == .loaded) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.reviewrrGhost)
            .disabled(picker.isRefreshing)
            .help("Check \(picker.hostDisplayName) for new \(picker.itemNounPlural)")
            .accessibilityLabel("Refresh repository list")

            Button {
                showManualEntry.toggle()
            } label: {
                Label("Paste a URL", systemImage: "link")
            }
            .buttonStyle(.reviewrrGhost)
            .help("Watch a repository by owner/repo or URL instead")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Cached lists must say how old they are, and a refresh happening
    /// behind a visible list must be visible without hiding it.
    @ViewBuilder
    private var freshnessIndicator: some View {
        if picker.isRefreshing && picker.phase == .loaded {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub…")
                    .font(.reviewrr(10, scale: scale))
                    .foregroundStyle(.secondary)
            }
        } else if let error = picker.refreshError {
            Label("Showing cached list", systemImage: "exclamationmark.triangle")
                .font(.reviewrr(10, scale: scale))
                .foregroundStyle(.orange)
                .help(error)
        } else if let updated = picker.lastUpdatedAt {
            Text("Updated \(Self.relativeFormatter.localizedString(for: updated, relativeTo: .now))")
                .font(.reviewrr(10, scale: scale))
                .foregroundStyle(.tertiary)
                .help("Repository lists are cached; refresh to check GitHub again")
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var subtitle: String {
        switch picker.phase {
        case .loading, .idle: return "Loading the \(picker.itemNounPlural) this credential can see…"
        case .failed: return "Couldn't load your \(picker.itemNounPlural)"
        case .loaded:
            let owners = picker.organizationScopes.count
            guard owners > 0 else {
                return "\(picker.itemNounPlural.capitalized) on \(picker.host.displayName)"
            }
            return "\(owners) \(picker.ownerNoun)\(owners == 1 ? "" : "s") on \(picker.host.displayName)"
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("owner/repo, repository URL, or PR URL", text: $manualInput)
                .textFieldStyle(.roundedBorder)
                .font(.reviewrr(13, scale: scale))
                .onSubmit(addManual)
            Button("Watch", action: addManual)
                .buttonStyle(.bordered)
                .disabled(WatchedProject.parseOwnerRepo(manualInput) == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Scope sidebar

    private var scopeSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !picker.organizationScopes.isEmpty {
                    scopeSectionHeader(picker.ownerNounPlural)
                    ForEach(picker.organizationScopes) { scope in
                        scopeRow(scope)
                    }
                }

                if !picker.personalScopes.isEmpty {
                    scopeSectionHeader("Accounts")
                    ForEach(picker.personalScopes) { scope in
                        scopeRow(scope)
                    }
                }

                if picker.phase == .loaded {
                    Divider().padding(.vertical, 6).padding(.horizontal, 12)
                    scopeRow(picker.allScope)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.columnSurface)
    }

    private func scopeSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.reviewrr(10, scale: scale, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scopeRow(_ scope: RepositoryPickerModel.Scope) -> some View {
        let selected = picker.ownerFilter == scope.owner?.login
        return Button {
            picker.ownerFilter = scope.owner?.login
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scope.isAll ? "square.grid.2x2" : (scope.isOrganization ? "building.2" : "person.crop.circle"))
                    .font(.reviewrr(12, scale: scale))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .frame(width: Theme.scaled(16, scale))

                Text(scope.title)
                    .font(.reviewrr(12, scale: scale, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Text("\(scope.count)")
                    .font(.reviewrr(10, scale: scale, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6, isSelected: selected)
        .padding(.horizontal, 6)
        .help(scope.isAll ? "Every repository this token can see" : scope.title)
        .accessibilityLabel("\(scope.title), \(scope.count) \(picker.itemNounPlural)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Repository pane

    private var repositoryPane: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            content
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.reviewrr(12, scale: scale))
                    .foregroundStyle(searchFocused ? Theme.accent : .secondary)
                TextField(searchPrompt, text: $picker.searchText)
                    .textFieldStyle(.plain)
                    .font(.reviewrr(13, scale: scale))
                    .focused($searchFocused)
                    .onSubmit { picker.searchRemotely() }
                if !picker.searchText.isEmpty {
                    Button {
                        picker.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.reviewrr(11, scale: scale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(searchFocused ? Theme.accent.opacity(0.65) : Theme.cardStroke, lineWidth: searchFocused ? 1.5 : 1)
            )

            Menu {
                Toggle("Include forks", isOn: $picker.includeForks)
                Toggle("Include archived", isOn: $picker.includeArchived)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Forks and archived \(picker.itemNounPlural) are hidden by default")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchPrompt: String {
        guard let owner = picker.ownerFilter else { return "Search all \(picker.itemNounPlural)…" }
        return "Search \(owner)…"
    }

    @ViewBuilder
    private var content: some View {
        switch picker.phase {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading your \(picker.itemNounPlural)…")
                    .font(.reviewrr(12, scale: scale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 14) {
                EmptyStateView(
                    systemImage: picker.hasToken ? "exclamationmark.triangle" : "key.slash",
                    title: picker.hasToken
                        ? "Couldn't load \(picker.itemNounPlural)"
                        : "No \(picker.hostDisplayName) credential",
                    message: message
                )
                HStack(spacing: 8) {
                    if !picker.hasToken {
                        Button("Open Settings") { openSettings(.account) }
                            .buttonStyle(.reviewrrPrimary)
                    }
                    Button("Try Again") { Task { await picker.load() } }
                        .buttonStyle(.reviewrrSecondary)
                    Button("Paste a URL Instead") { showManualEntry = true }
                        .buttonStyle(.reviewrrGhost)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            if picker.totalVisibleCount == 0 && picker.remoteMatches.isEmpty {
                noMatches
            } else {
                repositoryList
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: picker.searchText.isEmpty ? "Nothing to show here" : "No \(picker.itemNounPlural) match",
                message: emptyMessage
            )
            HStack(spacing: 8) {
                if !picker.includeForks {
                    Button("Include Forks") { picker.includeForks = true }
                        .buttonStyle(.reviewrrSecondary)
                }
                if !picker.searchText.isEmpty {
                    Button {
                        picker.searchRemotely()
                    } label: {
                        if picker.isSearchingRemotely {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Search all of GitHub", systemImage: "globe")
                        }
                    }
                    .buttonStyle(.reviewrrPrimary)
                    .help("Look beyond the \(picker.itemNounPlural) you're affiliated with")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyMessage: String {
        if !picker.searchText.isEmpty {
            return "Nothing in this scope matches “\(picker.searchText)”."
        }
        if !picker.includeForks {
            return "Every repository here is a fork or archived. Both are hidden by default."
        }
        return "This scope has no \(picker.itemNounPlural) this credential can see."
    }

    private var repositoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(picker.visibleGroups) { group in
                    // With a scope selected there is one group, and repeating
                    // its name above its own rows is noise — so the owner
                    // header only appears in the "All repositories" scope,
                    // where it is the only thing separating owners.
                    if picker.ownerFilter == nil {
                        Section {
                            ForEach(group.repositories) { repository in
                                RepositoryRow(repository: repository, picker: picker)
                            }
                        } header: {
                            ownerHeader(group)
                        }
                    } else {
                        ForEach(group.repositories) { repository in
                            RepositoryRow(repository: repository, picker: picker)
                        }
                    }
                }

                if !picker.remoteMatches.isEmpty {
                    Section {
                        ForEach(picker.remoteMatches) { repository in
                            RepositoryRow(repository: repository, picker: picker)
                        }
                    } header: {
                        sectionHeaderLabel(
                            title: "Found on GitHub",
                            detail: "Not in your organizations",
                            systemImage: "globe",
                            count: picker.remoteMatches.count
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .motion(Motion.smooth, value: picker.totalVisibleCount)
    }

    private func ownerHeader(_ group: RepositoryOwnerGroup) -> some View {
        sectionHeaderLabel(
            title: group.owner.login,
            detail: group.isPersonal ? "Personal" : "Organization",
            systemImage: group.isPersonal ? "person.crop.circle" : "building.2",
            count: group.repositories.count
        )
    }

    private func sectionHeaderLabel(title: String, detail: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.reviewrr(11, scale: scale))
            Text(title).font(.reviewrr(12, scale: scale, weight: .semibold))
            Text(detail).font(.reviewrr(10, scale: scale)).foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.reviewrr(10, scale: scale, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.barMaterial)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if picker.phase == .loaded, picker.totalVisibleCount > 0 {
                Button("Select All") { picker.selectAllVisible() }
                    .buttonStyle(.reviewrrGhost)
                    .help("Select every repository visible in this scope")
                if !picker.selectedKeys.isEmpty {
                    Button("Clear") { picker.clearSelection() }
                        .buttonStyle(.reviewrrGhost)
                }
            }

            Spacer()

            if let error = model.addProjectError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.reviewrr(11, scale: scale))
                    .foregroundStyle(Theme.removedText)
                    .lineLimit(2)
            }

            Text(selectionSummary)
                .font(.reviewrr(11, scale: scale))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .motion(Motion.smooth, value: picker.selectedKeys.count)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(action: addSelected) {
                if model.isAddingProject {
                    ProgressView().controlSize(.small)
                } else {
                    Text(picker.selectedKeys.count > 1 ? "Watch \(picker.selectedKeys.count) Projects" : "Watch Project")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .keyboardShortcut(.defaultAction)
            .disabled(picker.selectedKeys.isEmpty || model.isAddingProject)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.barMaterial)
    }

    private var selectionSummary: String {
        let count = picker.selectedKeys.count
        if count == 0 { return "Select \(picker.itemNounPlural) to watch" }
        return "\(count) selected"
    }

    // MARK: - Actions

    private func addSelected() {
        let repositories = picker.selectedRepositories
        guard !repositories.isEmpty else { return }
        Task {
            await model.addProjects(repositories, host: picker.browsingHost)
            if model.addProjectError == nil { dismiss() }
        }
    }

    private func addManual() {
        let input = manualInput
        guard WatchedProject.parseOwnerRepo(input) != nil else { return }
        Task {
            await model.addProject(rawInput: input, host: picker.browsingHost)
            if model.addProjectError == nil { dismiss() }
        }
    }
}

/// One selectable repository. Shows the detail that makes the choice
/// obvious — visibility, fork/archived state, and last activity — and says
/// plainly when a repository is already watched instead of hiding it.
private struct RepositoryRow: View {
    let repository: AccessibleRepository
    @ObservedObject var picker: RepositoryPickerModel
    @Environment(\.reviewrrTextScale) private var scale

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        let watched = picker.isWatched(repository)
        let selected = picker.isSelected(repository)

        Button {
            picker.toggleSelection(repository)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: watched || selected ? "checkmark.circle.fill" : "circle")
                    .font(.reviewrr(15, scale: scale))
                    .foregroundStyle(watched ? Color.secondary : (selected ? Theme.accent : Color.secondary.opacity(0.5)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repository.name)
                            .font(.reviewrr(13, scale: scale, weight: .medium))
                            .lineLimit(1)
                        if repository.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.reviewrr(9, scale: scale))
                                .foregroundStyle(.secondary)
                                .help("Private")
                        }
                        if repository.isFork {
                            Image(systemName: "tuningfork")
                                .font(.reviewrr(9, scale: scale))
                                .foregroundStyle(.secondary)
                                .help("Fork")
                        }
                        if repository.isArchived {
                            Text("Archived")
                                .font(.reviewrr(9, scale: scale, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(.reviewrr(11, scale: scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if watched {
                    Text("Watching")
                        .font(.reviewrr(10, scale: scale, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if let activity = repository.lastActivityAt {
                    Text(Self.relativeFormatter.localizedString(for: activity, relativeTo: .now))
                        .font(.reviewrr(10, scale: scale))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(watched ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 6, isSelected: selected)
        .disabled(watched)
        .help(watched ? "\(repository.fullName) is already watched" : repository.fullName)
        .accessibilityLabel(repository.fullName)
        .accessibilityValue(watched ? "Already watching" : (selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
