import Foundation

/// Drives the "Watch a Project" picker: loads every repository the
/// credential can see, groups it by organization, filters it as the reviewer
/// types, and tracks which ones they have selected to watch.
///
/// Holds no view code — it compiles into the unit-test bundle, and its
/// filtering and grouping are tested directly.
@MainActor
final class RepositoryPickerModel: ObservableObject {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var groups: [RepositoryOwnerGroup] = []
    /// nil means "every owner"; otherwise the login of the scoped owner.
    @Published var ownerFilter: String?
    @Published var searchText: String = ""
    @Published var includeArchived = false
    @Published var includeForks = false
    @Published private(set) var selectedKeys: Set<String> = []

    /// Repositories found only by asking GitHub's search API, kept separate
    /// so a search that reaches beyond the local crawl is clearly additive
    /// rather than silently mixed into the affiliation list.
    @Published private(set) var remoteMatches: [AccessibleRepository] = []
    @Published private(set) var isSearchingRemotely = false

    /// True while a network refresh runs *behind* an already-visible cached
    /// list. Distinct from `.loading`, which means there is nothing to show
    /// yet — the two need different UI, because a spinner over real content
    /// reads as "broken" rather than "checking".
    @Published private(set) var isRefreshing = false
    /// When the visible list was fetched from GitHub, cached or not.
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var refreshError: String?

    private let context: AppContext
    /// Keys already on the watchlist. Those rows still appear — seeing a
    /// repository listed as already watched answers "did I add this?"
    /// better than its absence does.
    private let alreadyWatchedKeys: Set<String>
    private var remoteSearchTask: Task<Void, Never>?

    /// Which host the picker is browsing.
    ///
    /// Deliberately *not* the app's active host. Watching a project is not
    /// the same act as switching the review session: a reviewer adding a
    /// GitHub repository while reading a GitLab merge request should not
    /// have their workspace yanked to another server, and the dashboard
    /// syncs every watched host anyway. Changing this reloads the list and
    /// nothing else.
    @Published var browsingHost: ForgeHost {
        didSet {
            guard browsingHost.identityKey != oldValue.identityKey else { return }
            // Selection belongs to the host it was made on; carrying keys
            // across a host switch would watch the wrong repositories.
            selectedKeys = []
            ownerFilter = nil
            searchText = ""
            remoteMatches = []
            groups = []
            phase = .idle
            Task { await load() }
        }
    }

    /// The hosts offered in the picker's switcher.
    let availableHosts: [ForgeHost]

    init(context: AppContext, alreadyWatchedKeys: Set<String>, availableHosts: [ForgeHost] = []) {
        self.context = context
        self.alreadyWatchedKeys = alreadyWatchedKeys
        let hosts = availableHosts.isEmpty ? [context.host] : availableHosts
        self.availableHosts = hosts
        // Start on the active host: it is the one the reviewer was last
        // working against, so it is the likeliest thing they came here for.
        self.browsingHost = hosts.first { $0.identityKey == context.host.identityKey } ?? hosts[0]
    }

    var host: ForgeHost { browsingHost }
    var credential: HostCredential { context.credential(for: browsingHost) }
    var hasToken: Bool { credential.isUsable }

    // MARK: - Loading

    /// Renders the cached list immediately, then refreshes behind it.
    ///
    /// Repository membership changes on the order of weeks while fetching it
    /// costs several paginated round trips, so a cold spinner is the wrong
    /// default: show what was true a few hours ago, then quietly correct it.
    func load() async {
        guard !isRefreshing, phase != .loading else { return }

        let host = browsingHost
        if let cached = RepositoryCacheStore.load(host: host), !cached.repositories.isEmpty {
            apply(cached)
            guard cached.isStale() else { return }
            await refresh(silently: true)
            return
        }

        phase = .loading
        await refresh(silently: false)
    }

    /// Fetches from GitHub and replaces the cache. `silently` keeps an
    /// already-visible list on screen and reports failure without wiping it.
    func refresh(silently: Bool) async {
        let host = browsingHost
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        do {
            // One factory call instead of a switch: GitHub crawls
            // `/user/repos`, GitLab crawls `/projects?membership=true`, and
            // both produce the same candidate type — so everything above
            // this line (grouping, search, selection) is already shared.
            let hostCredential = context.credential(for: host)
            let snapshot = try await ForgeServices
                .directory(host: host, basic: hostCredential.basic)
                .snapshot(token: hostCredential.token)
            RepositoryCacheStore.save(snapshot, host: host)
            apply(snapshot)
        } catch is CancellationError {
            if !silently { phase = .idle }
        } catch {
            let message = describeListingFailure(error)
            if silently {
                // The cached list is still correct enough to use, so the
                // failure is a note, not a takeover of the whole sheet.
                refreshError = message
            } else {
                phase = .failed(message)
            }
        }
    }

    private func apply(_ snapshot: RepositoryCacheStore.Snapshot) {
        groups = RepositoryDirectory.grouped(
            snapshot.repositories, knownOrganizations: snapshot.organizations
        )
        lastUpdatedAt = snapshot.fetchedAt
        phase = .loaded
        if ownerFilter == nil || !groups.contains(where: { $0.owner.login == ownerFilter }) {
            ownerFilter = defaultScope()
        }
    }

    /// Asks GitHub directly for repositories the affiliation crawl did not
    /// return. Debounced, and cancelled when the query changes again.
    func searchRemotely() {
        remoteSearchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            remoteMatches = []
            isSearchingRemotely = false
            return
        }
        let directory = RepositoryDirectory(api: context.api())
        let token = context.token()
        isSearchingRemotely = true
        remoteSearchTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.isSearchingRemotely = false } }
            do {
                let found = try await directory.searchRepositories(matching: query, token: token)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let localKeys = Set(self.groups.flatMap(\.repositories).map(\.fullName))
                    self.remoteMatches = found.filter { !localKeys.contains($0.fullName) }
                }
            } catch {
                // A failed supplementary search must not disturb the local
                // list the reviewer is already using.
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.remoteMatches = [] }
            }
        }
    }

    // MARK: - Scopes

    /// One selectable owner in the scope list, plus how many repositories it
    /// contributes *after* the fork/archived filters — a count that includes
    /// rows the reviewer cannot see would be a lie.
    struct Scope: Identifiable, Equatable {
        let owner: AccessibleRepository.Owner?
        let count: Int
        /// nil owner is the "everything" scope.
        var id: String { owner?.login ?? "__all__" }
        var isAll: Bool { owner == nil }
        var isOrganization: Bool { owner?.isOrganization ?? false }
        var title: String { owner?.login ?? "All repositories" }
    }

    /// Organizations first, then personal accounts — an engineer's work lives
    /// in organizations, and the long tail of one-repo personal accounts is
    /// what made the flat list noise. Both are sorted by repository count so
    /// the busiest scope is the easiest to reach.
    var organizationScopes: [Scope] {
        scopes(where: { $0.owner.isOrganization })
    }

    var personalScopes: [Scope] {
        scopes(where: { !$0.owner.isOrganization })
    }

    var allScope: Scope {
        Scope(owner: nil, count: groups.reduce(0) { $0 + $1.repositories.filter { include($0, needle: "") }.count })
    }

    private func scopes(where predicate: (RepositoryOwnerGroup) -> Bool) -> [Scope] {
        groups
            .filter(predicate)
            .map { Scope(owner: $0.owner, count: $0.repositories.filter { include($0, needle: "") }.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// The scope to land on after loading: the busiest organization, else the
    /// busiest personal account. Never "all" — opening onto 577 rows across
    /// 31 owners is the problem this picker exists to solve.
    private func defaultScope() -> String? {
        if let organization = organizationScopes.first(where: { $0.count > 0 }) { return organization.owner?.login }
        return personalScopes.first(where: { $0.count > 0 })?.owner?.login
    }

    // MARK: - Derived view state

    /// The groups to show, after the owner scope and the search text.
    var visibleGroups: [RepositoryOwnerGroup] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            if let ownerFilter, group.owner.login != ownerFilter { return nil }
            let repositories = group.repositories.filter { include($0, needle: needle) }
            guard !repositories.isEmpty else { return nil }
            return RepositoryOwnerGroup(owner: group.owner, repositories: repositories)
        }
    }

    private func include(_ repository: AccessibleRepository, needle: String) -> Bool {
        if !includeArchived && repository.isArchived { return false }
        if !includeForks && repository.isFork { return false }
        return repository.matches(needle)
    }

    var totalVisibleCount: Int { visibleGroups.reduce(0) { $0 + $1.repositories.count } }
    var totalAvailableCount: Int { groups.reduce(0) { $0 + $1.repositories.count } }

    func isWatched(_ repository: AccessibleRepository) -> Bool {
        alreadyWatchedKeys.contains(repository.watchKey(host: host))
    }

    func isSelected(_ repository: AccessibleRepository) -> Bool {
        selectedKeys.contains(repository.watchKey(host: host))
    }

    /// Already-watched repositories are not selectable — adding one twice is
    /// not a thing a reviewer can want, and the row says so instead.
    func toggleSelection(_ repository: AccessibleRepository) {
        guard !isWatched(repository) else { return }
        let key = repository.watchKey(host: host)
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    func selectAllVisible() {
        for repository in visibleGroups.flatMap(\.repositories) where !isWatched(repository) {
            selectedKeys.insert(repository.watchKey(host: host))
        }
    }

    func clearSelection() { selectedKeys.removeAll() }

    /// The repositories behind the current selection, in the order they are
    /// displayed, including any found only through remote search.
    var selectedRepositories: [AccessibleRepository] {
        let candidates = groups.flatMap(\.repositories) + remoteMatches
        var seen = Set<String>()
        return candidates.filter { repository in
            let key = repository.watchKey(host: host)
            guard selectedKeys.contains(key), !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    /// Seeds the model as a finished load would, so the filtering and
    /// selection surface can be tested without a network round trip.
    func applyLoadedForTesting(_ groups: [RepositoryOwnerGroup], applyDefaultScope: Bool = false) {
        self.groups = groups
        phase = .loaded
        if applyDefaultScope { ownerFilter = defaultScope() }
    }

    /// The forge's word for what this picker lists, for copy that a
    /// GitLab reviewer will not read as being about someone else's tool.
    var hostDisplayName: String { browsingHost.displayName }
    var itemNoun: String { browsingHost.isGitLab ? "project" : "repository" }
    /// GitLab nests projects in *groups*; GitHub has organizations. The
    /// picker's whole left rail is this concept, so it cannot borrow the
    /// other forge's word for it.
    var ownerNoun: String { browsingHost.isGitLab ? "group" : "organization" }
    var ownerNounPlural: String { browsingHost.isGitLab ? "Groups" : "Organizations" }
    var itemNounPlural: String { browsingHost.isGitLab ? "projects" : "repositories" }

    /// Describes a failure *in this context*.
    ///
    /// The transport's error type is shared with the pull-request path, and
    /// `GitHubError.notFound` spells itself out as "Pull request not found.
    /// If it's in a private repository, add a GitHub token…" — which is what
    /// this sheet used to show when listing failed, an answer to a question
    /// nobody asked. A shared error type means the caller has to name the
    /// context, so that is done here rather than by widening the error.
    private func describeListingFailure(_ error: Error) -> String {
        switch error {
        case GitHubError.notFound, GitLabError.notFound:
            return "\(browsingHost.displayName) returned nothing for this credential. Check that the token can see the \(itemNounPlural) you expect, or paste a URL instead."
        case GitHubError.noToken, GitLabError.noCredential:
            return "No credential is configured for \(browsingHost.displayName). Add one in Settings ▸ Account, or paste a URL instead."
        default:
            return Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
