import AppKit
import CoreGraphics
import Foundation

/// The dashboard's view model: watched projects, the combined cross-repo PR
/// inbox, local review status, filtering/grouping state, and polling.
/// Constructed with an `AppContext` so it never depends on `AppModel`
/// directly — previews and tests use `AppContext.stub()`.
///
/// `start()`/`stop()` own polling's lifetime explicitly rather than tying
/// it to `init`/`deinit`, so a view can start polling in `.task` and stop
/// it in `.onDisappear` without racing object teardown.
@MainActor
final class DashboardModel: ObservableObject {
    // MARK: - Published state

    // `filteredRows`/`projectGroups`/`bucketGroups` below are cached rather
    // than recomputed on every access — a view `body` and `DashboardView`'s
    // keyboard handlers all read them, sometimes several times per render —
    // so every property that feeds those three derivations invalidates the
    // cache on write instead of the properties recomputing from scratch
    // every time they're read.
    @Published var projects: [WatchedProject] { didSet { invalidateProjectGroupsCache() } }
    @Published var rows: [InboxPR] = [] { didSet { invalidateFilteredRowsCache() } }
    @Published var localStatus: [String: LocalPRStatus] { didSet { invalidateFilteredRowsCache() } }

    @Published var filter = InboxFilter() { didSet { invalidateFilteredRowsCache() } }
    @Published var grouping: InboxGrouping = .byProject
    @Published var sortField: InboxSortField = .updated { didSet { invalidateFilteredRowsCache() } }
    @Published var searchText: String = "" {
        didSet { filter.searchText = searchText }
    }

    @Published private(set) var savedReviews: [DashboardReviewDraft] = []

    @Published var draftClearError: String?

    func clearSavedReviews(_ references: [PRReference]) {
        draftClearError = nil
        var failed: [String] = []
        for reference in references {
            do {
                try DraftStore.discardChecked(for: reference, host: context.host)
                if localStatus[reference.key]?.status == .inReview {
                    setLocalStatus(.none, for: reference)
                }
            } catch {
                failed.append(reference.key)
            }
        }
        reloadSavedReviews()
        if !failed.isEmpty {
            draftClearError = "Could not clear \(failed.joined(separator: ", ")). Check disk space and folder permissions, then try again."
        }
    }

    func reloadSavedReviews(includeLegacyInProgress: Bool = false) {
        var reviews = DraftStore.savedReviews(host: context.host)
        var known = Set(reviews.map(\.id))
        // Bring earlier in-progress reviews into the draft shelf as their
        // cached or live PR metadata becomes available.
        for row in rows where includeLegacyInProgress && row.host == context.host && localStatus(for: row).status == .inReview {
            guard !known.contains(row.reference.key) else { continue }
            var draft = DraftStore.load(for: row.reference, host: context.host)
            guard draft.isSubmitted != true, draft.isDiscarded != true else { continue }
            draft.referenceKey = row.reference.key
            draft.title = row.title
            draft.savedAt = draft.savedAt ?? Date()
            do {
                try DraftStore.saveChecked(draft, for: row.reference, host: context.host)
                reviews.append(DashboardReviewDraft(reference: row.reference, draft: draft))
                known.insert(row.reference.key)
            } catch {
                // Only advertise resumable state after it reaches disk.
                continue
            }
        }
        savedReviews = reviews.sorted { ($0.draft.savedAt ?? .distantPast) > ($1.draft.savedAt ?? .distantPast) }
    }

    @Published var showsSavedReviews = false
    @Published var isRefreshingAll = false
    /// Drives the add-project sheet. On the model rather than in the view so
    /// the command palette can open it too.
    @Published var isAddProjectPresented = false
    @Published var isAddingProject = false
    @Published var addProjectError: String?
    @Published var bucketsError: String?
    @Published var lastBucketsSyncAt: Date?
    @Published var recentActivity: [ActivityNotifier.Event] = []
    /// Projects with a sync currently in flight, so the sidebar can show a
    /// per-project spinner instead of one global loading flag.
    @Published var syncingProjectKeys: Set<String> = []
    @Published private var expandedGroupKeys: Set<String> = []

    // MARK: - Private

    /// Not private: the repository picker is built from this model and needs
    /// the same API/token/settings handle rather than a second one.
    let context: AppContext
    private let pollingCoordinator = PollingCoordinator()
    /// Shared with `AppModel`, which owns it: a notification clicked in
    /// Notification Centre has to reach the window, and the permission the
    /// settings pane shows has to be the same one this posts through.
    let notifications: NotificationService
    private let activityNotifier: ActivityNotifier

    private var projectRowsCache: [String: [InboxPR]] = [:]
    private var bucketRowsCache: [InboxReviewerBucket: [InboxPR]] = [:]
    private var inFlightProjectRefresh: [String: Task<Bool, Never>] = [:]
    private var inFlightBucketsRefresh: Task<Bool, Never>?
    private var lastRefreshAllAt: Date?

    // Memoized derived view state — see `filteredRows`/`projectGroups`/
    // `bucketGroups` below. `nil` means "needs recomputing."
    private var cachedFilteredRows: [InboxPR]?
    private var cachedProjectGroups: [InboxFiltering.ProjectGroup]?
    private var cachedBucketGroups: [InboxFiltering.BucketGroup]?

    /// `notifications` is optional so a test can stand this model up without
    /// one; a fresh service is built here instead. An unstarted service has
    /// no permission and therefore delivers nothing, which is what a test
    /// wants. (Built in the body rather than as a default argument: a
    /// default is evaluated in the caller's isolation, and this type is
    /// main-actor only.)
    init(context: AppContext, notifications: NotificationService? = nil) {
        let notificationService = notifications ?? NotificationService()
        self.context = context
        self.notifications = notificationService
        self.activityNotifier = ActivityNotifier(notifications: notificationService)
        self.projects = WatchlistStore.loadProjects()
        self.localStatus = LocalStatusStore.load()

        // Rows from the last session render immediately, so launch shows the
        // inbox instead of a spinner. Polling then corrects them; nothing
        // here is treated as authoritative.
        if let cached = InboxCacheStore.load(host: context.host) {
            self.rows = cached.rows
            self.lastRowsFetchedAt = cached.fetchedAt
            self.hasLoadedCachedRows = !cached.rows.isEmpty
        }
    }

    /// When the currently displayed rows were fetched — from this session or
    /// restored from the previous one.
    @Published private(set) var lastRowsFetchedAt: Date?
    /// True when the visible rows came off disk rather than from a sync this
    /// session, so the UI can show the inbox instead of a first-load state.
    private(set) var hasLoadedCachedRows = false

    var hasToken: Bool { context.token() != nil }

    /// The host these rows came from, so the inbox chrome can use the right
    /// vocabulary — "Merge Requests" on GitLab, "Pull Requests" on GitHub.
    var host: ForgeHost { context.host }

    // MARK: - Lifecycle (integrator calls these)

    func start() {
        reloadSavedReviews(includeLegacyInProgress: true)
        pollingCoordinator.start(
            projects: { [weak self] in self?.projects ?? [] },
            settings: { [weak self] in self?.context.settings() ?? AppSettings() },
            refreshProject: { [weak self] project in await self?.refreshProjectCoalesced(project) ?? false },
            refreshBuckets: { [weak self] in await self?.refreshBucketsCoalesced() ?? false }
        )
    }

    func stop() {
        pollingCoordinator.stop()
    }

    /// A manual, whole-dashboard refresh (toolbar button, pull-to-refresh
    /// equivalent). `force: false` debounces rapid repeats; `force: true`
    /// always re-fetches. Runs every non-muted project and the reviewer
    /// buckets concurrently, but shares in-flight requests with the
    /// background poller via the same coalescing path.
    func refreshAll(force: Bool) async {
        if !force, let last = lastRefreshAllAt, Date().timeIntervalSince(last) < 5 { return }
        lastRefreshAllAt = Date()
        isRefreshingAll = true
        defer { isRefreshingAll = false }
        await withTaskGroup(of: Void.self) { group in
            for project in projects where !project.isMuted {
                group.addTask { [weak self] in _ = await self?.refreshProjectCoalesced(project) }
            }
            group.addTask { [weak self] in _ = await self?.refreshBucketsCoalesced() }
            await group.waitForAll()
        }
    }

    // MARK: - Watchlist management

    /// Accepts "owner/repo", a repo URL, or any PR URL; validates the
    /// repository exists and is visible with the current token before
    /// adding it, and kicks off its first sync immediately rather than
    /// waiting for the next staggered poll.
    /// Refreshes one project on demand — the sidebar's per-project action.
    /// Distinct from `refreshAll` so the menu item can say what it actually
    /// does instead of quietly syncing the whole watchlist.
    func refresh(_ project: WatchedProject) async {
        _ = await refreshProjectCoalesced(project)
    }

    func addProject(rawInput: String, host: ForgeHost? = nil) async {
        addProjectError = nil
        guard let parsed = WatchedProject.parseOwnerRepo(rawInput) else {
            addProjectError = "Paste an owner/repo, a repository URL, or a PR URL."
            return
        }
        let host = host ?? context.host
        let candidateKey = WatchedProject.makeKey(host: host, owner: parsed.owner, repo: parsed.repo)
        guard !projects.contains(where: { $0.key == candidateKey }) else {
            addProjectError = "\(parsed.owner)/\(parsed.repo) is already watched."
            return
        }

        isAddingProject = true
        defer { isAddingProject = false }
        do {
            let credential = context.credential(for: host)
            try await ForgeServices.inbox(host: host, basic: credential.basic)
                .validateRepository(owner: parsed.owner, repo: parsed.repo, token: credential.token)
            let project = WatchedProject(host: host, owner: parsed.owner, repo: parsed.repo)
            projects.append(project)
            persistProjects()
            _ = await refreshProjectCoalesced(project)
        } catch {
            addProjectError = Self.describe(error)
        }
    }

    /// Watches several repositories the reviewer picked from the browser.
    ///
    /// No per-repository existence probe here: these came from GitHub's own
    /// list of what this credential can see, so the probe `addProject` needs
    /// for hand-typed input would be a redundant round trip per repository.
    /// Watches a selection made in the picker, on the host it was browsed
    /// on.
    ///
    /// `host` is passed rather than read from the context: the picker can
    /// browse a host without the app switching to it, so "the active host"
    /// is the wrong answer here — it would file a GitLab project under
    /// GitHub.com and sync it against the wrong server forever.
    func addProjects(_ repositories: [AccessibleRepository], host: ForgeHost? = nil) async {
        addProjectError = nil
        guard !repositories.isEmpty else { return }
        isAddingProject = true
        defer { isAddingProject = false }

        let host = host ?? context.host
        var added: [WatchedProject] = []
        added.reserveCapacity(repositories.count)
        for repository in repositories {
            let key = WatchedProject.makeKey(host: host, owner: repository.owner.login, repo: repository.name)
            guard !projects.contains(where: { $0.key == key }) else { continue }
            let project = WatchedProject(host: host, owner: repository.owner.login, repo: repository.name)
            projects.append(project)
            added.append(project)
        }
        guard !added.isEmpty else { return }
        persistProjects()

        // Sync the new projects concurrently but let each one fail on its
        // own: one inaccessible repository must not blank the others.
        await withTaskGroup(of: Void.self) { group in
            for project in added {
                group.addTask { [weak self] in _ = await self?.refreshProjectCoalesced(project) }
            }
            await group.waitForAll()
        }
    }

    /// Keys of everything currently watched, for the picker to mark rows
    /// that are already on the list.
    var watchedKeys: Set<String> { Set(projects.map(\.key)) }

    func removeProject(_ project: WatchedProject) {
        projects.removeAll { $0.key == project.key }
        projectRowsCache[project.key] = nil
        recomputeRows()
        persistProjects()
    }

    func toggleMute(_ project: WatchedProject) {
        guard let index = projects.firstIndex(where: { $0.key == project.key }) else { return }
        projects[index].isMuted.toggle()
        persistProjects()
    }

    /// How much of one project's activity is worth a notification.
    ///
    /// Distinct from muting, which removes the project from the dashboard's
    /// counts and feed as well. This one only narrows notifications.
    func setNotificationLevel(_ level: WatchedProject.NotificationLevel, for key: String) {
        guard let index = projects.firstIndex(where: { $0.key == key }),
              projects[index].notificationLevel != level
        else { return }
        projects[index].notificationLevel = level
        persistProjects()
    }

    // MARK: - Local review status

    /// Per-project unread count — PRs whose current `updatedAt` this
    /// reviewer hasn't seen yet, excluding ignored PRs.
    /// The project the sidebar has selected, or nil for "every project".
    /// Writing it drives `filter.projectKeys`, so selection and filtering are
    /// one piece of state rather than two that can drift apart.
    var selectedProjectKey: String? {
        get { filter.projectKeys.first }
        set {
            if let newValue {
                filter.projectKeys = [newValue]
            } else {
                filter.projectKeys = []
            }
        }
    }

    /// The reviewer's interface text-size preference, as a multiplier the
    /// dashboard views apply to their own font sizes.
    var textScale: CGFloat { context.settings().textSize.scale }

    // MARK: - Section collapse and paging

    /// How many rows a group shows before it offers "Show more". A busy
    /// project can carry 150 open PRs; rendering all of them buries every
    /// other project below a wall the reviewer has to scroll past.
    static let collapsedGroupRowLimit = 10

    func isCollapsed(groupKey: String) -> Bool {
        context.settings().collapsedInboxGroups.contains(groupKey)
    }

    func toggleCollapsed(groupKey: String) {
        var settings = context.settings()
        if settings.collapsedInboxGroups.contains(groupKey) {
            settings.collapsedInboxGroups.remove(groupKey)
        } else {
            settings.collapsedInboxGroups.insert(groupKey)
        }
        context.updateSettings(settings)
        objectWillChange.send()
    }

    /// Expanded-beyond-the-limit is session state on purpose: unlike a
    /// collapsed section, "show me all 150" is about right now, not a
    /// standing preference.
    func isShowingAllRows(groupKey: String) -> Bool { expandedGroupKeys.contains(groupKey) }

    func toggleShowingAllRows(groupKey: String) {
        if expandedGroupKeys.contains(groupKey) {
            expandedGroupKeys.remove(groupKey)
        } else {
            expandedGroupKeys.insert(groupKey)
        }
    }

    /// The rows a group should actually render, given its collapse and
    /// show-more state.
    func visibleRows(_ rows: [InboxPR], groupKey: String) -> [InboxPR] {
        if isCollapsed(groupKey: groupKey) { return [] }
        if isShowingAllRows(groupKey: groupKey) { return rows }
        return Array(rows.prefix(Self.collapsedGroupRowLimit))
    }

    func hiddenRowCount(_ rows: [InboxPR], groupKey: String) -> Int {
        guard !isCollapsed(groupKey: groupKey), !isShowingAllRows(groupKey: groupKey) else { return 0 }
        return max(0, rows.count - Self.collapsedGroupRowLimit)
    }

    /// Seeds one project's synced rows, as a completed refresh would, so the
    /// count logic can be tested without a network round trip.
    func applyProjectRowsForTesting(_ rows: [InboxPR], for project: WatchedProject) {
        projectRowsCache[project.key] = rows
        recomputeRows()
    }

    /// Open pull requests in this project — what the sidebar badge shows and
    /// what selecting the project puts in the inbox.
    ///
    /// Counting every state made the badge meaningless: a full `state=all`
    /// sync of a busy repository reported 147, of which nine were actually
    /// open. Ignored pull requests are excluded too, because an ignored one
    /// is explicitly not asking for attention.
    func openCount(for project: WatchedProject) -> Int {
        (projectRowsCache[project.key] ?? []).filter { row in
            guard row.state.isLive else { return false }
            return (localStatus[row.statusKey] ?? LocalPRStatus()).status != .ignored
        }.count
    }

    /// Open pull requests here that this reviewer has not looked at yet.
    /// Drives the badge's tint rather than its number.
    func unreadCount(for project: WatchedProject) -> Int {
        (projectRowsCache[project.key] ?? []).filter { row in
            guard row.state.isLive else { return false }
            let status = localStatus[row.statusKey] ?? LocalPRStatus()
            return status.isUnseen(currentUpdatedAt: row.updatedAt)
        }.count
    }

    func localStatus(for pr: InboxPR) -> LocalPRStatus {
        localStatus[pr.statusKey] ?? LocalPRStatus()
    }

    /// Call when a row is opened — from the dashboard itself, or (via the
    /// integrator) from anywhere else a PR is opened, so "meaningful
    /// interaction starts in review" holds regardless of entry point.
    func markOpened(_ pr: InboxPR) {
        var status = localStatus[pr.statusKey] ?? LocalPRStatus()
        status.markOpened(updatedAt: pr.updatedAt)
        localStatus[pr.statusKey] = status
        persistLocalStatus()

        if let index = projects.firstIndex(where: { $0.owner == pr.owner && $0.repo == pr.repo }) {
            projects[index].lastOpenedAt = Date()
            persistProjects()
        }
    }

    /// The same "opened" transition keyed by reference, for entry points
    /// that have no inbox row — a pasted PR URL, or a recent-PR shortcut.
    func markOpened(reference: PRReference, updatedAt: Date) {
        let key = LocalPRStatus.key(owner: reference.owner, repo: reference.repo, number: reference.number)
        var status = localStatus[key] ?? LocalPRStatus()
        status.markOpened(updatedAt: updatedAt)
        localStatus[key] = status
        persistLocalStatus()

        if let index = projects.firstIndex(where: { $0.owner == reference.owner && $0.repo == reference.repo }) {
            projects[index].lastOpenedAt = Date()
            persistProjects()
        }
    }

    /// An explicit reviewer-driven status change (menu action): always
    /// applies, regardless of the current status — "always permit undo or
    /// manual override."
    func setLocalStatus(_ newStatus: LocalReviewStatus, for reference: PRReference, headSha: String? = nil) {
        let key = LocalPRStatus.key(owner: reference.owner, repo: reference.repo, number: reference.number)
        var status = localStatus[key] ?? LocalPRStatus()
        status.setStatus(newStatus, headSha: headSha)
        localStatus[key] = status
        persistLocalStatus()
    }

    /// The integrator calls this after `AppModel` successfully submits a
    /// GitHub review, so local status reflects "reviewed" even though the
    /// submission itself happens outside the dashboard.
    func markReviewed(_ reference: PRReference, headSha: String?) {
        setLocalStatus(.reviewed, for: reference, headSha: headSha)
    }

    // MARK: - Derived view state

    /// Filtered, sorted rows — cached until `rows`, `filter`, `sortField`,
    /// or `localStatus` actually change. A single render can read this from
    /// several view bodies plus `DashboardView`'s keyboard handlers, and a
    /// scroll re-reads it at 60Hz; recomputing filter+sort+group from
    /// scratch every time paid that cost repeatedly for the same answer.
    var filteredRows: [InboxPR] {
        if let cachedFilteredRows { return cachedFilteredRows }
        let computed = InboxFiltering.sorted(
            InboxFiltering.apply(filter, to: rows, localStatus: localStatus), field: sortField
        )
        cachedFilteredRows = computed
        return computed
    }

    var projectGroups: [InboxFiltering.ProjectGroup] {
        if let cachedProjectGroups { return cachedProjectGroups }
        let computed = InboxFiltering.groupedByProject(filteredRows, projects: projects, sortField: sortField)
        cachedProjectGroups = computed
        return computed
    }

    var bucketGroups: [InboxFiltering.BucketGroup] {
        if let cachedBucketGroups { return cachedBucketGroups }
        let computed = InboxFiltering.groupedByReviewerBucket(filteredRows, sortField: sortField)
        cachedBucketGroups = computed
        return computed
    }

    /// Both group caches derive from `filteredRows`, so invalidating it must
    /// also drop them — a stale `filteredRows` behind a fresh group would be
    /// a worse bug than recomputing too often.
    private func invalidateFilteredRowsCache() {
        cachedFilteredRows = nil
        cachedProjectGroups = nil
        cachedBucketGroups = nil
    }

    /// `projectGroups` alone depends on `projects` (ordering, and which
    /// projects exist) — `bucketGroups` does not, so a project rename/mute/
    /// removal need not drop it too.
    private func invalidateProjectGroupsCache() {
        cachedProjectGroups = nil
    }

    /// True once at least one watched project has completed a sync — used
    /// to tell "still loading for the first time" apart from "genuinely no
    /// PRs match."
    var hasCompletedFirstSync: Bool {
        // Restored rows count: the inbox has something true to show, so the
        // first-load state would be a lie.
        hasLoadedCachedRows || projects.contains { $0.lastSyncedAt != nil } || lastBucketsSyncAt != nil
    }

    // MARK: - Refresh implementation

    private func refreshProjectCoalesced(_ project: WatchedProject) async -> Bool {
        if let existing = inFlightProjectRefresh[project.key] {
            return await existing.value
        }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performProjectRefresh(project)
        }
        inFlightProjectRefresh[project.key] = task
        let result = await task.value
        inFlightProjectRefresh[project.key] = nil
        return result
    }

    private func performProjectRefresh(_ project: WatchedProject) async -> Bool {
        syncingProjectKeys.insert(project.key)
        defer { syncingProjectKeys.remove(project.key) }
        do {
            // `project.host`, not the active host. A watched project has
            // always carried the host it came from, but every sync used
            // whichever host the reviewer happened to have selected — so
            // watching a GitHub repository and a GitLab project at the same
            // time sent each one's request to the other's server. Switching
            // hosts silently broke every project belonging to the other.
            let credential = context.credential(for: project.host)
            guard credential.isUsable else {
                updateProject(project.key) {
                    $0.lastError = "No credential saved for \(project.host.displayName). Add one in Settings ▸ Account."
                }
                return false
            }
            let newRows = try await ForgeServices
                .inbox(host: project.host, basic: credential.basic)
                .fetchProject(project, token: credential.token)
            let previousRows = projectRowsCache[project.key] ?? []
            projectRowsCache[project.key] = newRows
            recomputeRows()
            updateProject(project.key) { $0.lastSyncedAt = Date(); $0.lastError = nil }

            let ignoredKeys = Set(localStatus.filter { $0.value.status == .ignored }.keys)
            let events = activityNotifier.noteSync(
                project: project, previousRows: previousRows, newRows: newRows,
                context: ActivityNotifier.SyncContext(
                    settings: context.settings(),
                    ignoredKeys: ignoredKeys,
                    viewerLogin: viewerLogin,
                    // Whether the reviewer is looking at the app right now,
                    // for "don't interrupt me with what's already on screen".
                    isAppActive: NSApplication.shared.isActive
                )
            )
            if !events.isEmpty { recentActivity = activityNotifier.recentEvents }
            return true
        } catch is CancellationError {
            // A superseded or torn-down refresh is not a project error — the
            // previous snapshot stays valid and unannotated.
            return false
        } catch {
            updateProject(project.key) { $0.lastError = Self.describe(error) }
            return false
        }
    }

    /// Who is signed in, worked out from the rows rather than asked for.
    ///
    /// Every row in the `authored` bucket came back from `author:@me`, so its
    /// author *is* the reviewer — no extra request, no persisted copy to go
    /// stale, and it costs one dictionary lookup. `nil` until a reviewer-bucket
    /// sync has run, which is the honest answer: without it there is nothing
    /// in a watched project's rows that says which login is yours, and the
    /// `authored` bucket membership is the fallback the policy uses instead.
    private var viewerLogin: String? {
        bucketRowsCache[.authored]?.first?.authorLogin
    }

    private func refreshBucketsCoalesced() async -> Bool {
        if let existing = inFlightBucketsRefresh {
            return await existing.value
        }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performBucketsRefresh()
        }
        inFlightBucketsRefresh = task
        let result = await task.value
        inFlightBucketsRefresh = nil
        return result
    }

    /// Hosts the watch-a-project picker may browse: everything configured,
    /// plus any host already carrying a watched project.
    ///
    /// A superset of `syncHosts` — that one answers "what must I poll", this
    /// one answers "where could a reviewer add something", and a configured
    /// host with nothing watched on it yet only belongs in the second.
    var browsableHosts: [ForgeHost] {
        var seen = Set<String>()
        var hosts: [ForgeHost] = []
        for host in context.knownHosts() + syncHosts where seen.insert(host.identityKey).inserted {
            hosts.append(host)
        }
        return hosts
    }

    /// Every host the dashboard has something to sync against: the active
    /// one, plus the host of every watched project.
    ///
    /// Derived rather than stored. The watchlist already records the host of
    /// each project, so the set of hosts in play is a *fact about the
    /// watchlist* — keeping a separate list of configured hosts in settings
    /// would be a second source of truth to drift out of agreement with it.
    var syncHosts: [ForgeHost] {
        var seen = Set<String>()
        var hosts: [ForgeHost] = []
        for host in [context.host] + projects.map(\.host) where seen.insert(host.identityKey).inserted {
            hosts.append(host)
        }
        return hosts
    }

    /// The reviewer buckets, merged across every host with a credential.
    ///
    /// This is the other half of making three forges work at once: a
    /// reviewer with a GitHub repository and a GitLab project has review
    /// requests on both, and asking only the active host meant half their
    /// queue was invisible depending on which host they last selected.
    ///
    /// Hosts are asked concurrently — they are independent servers, and
    /// three sequential crawls would take as long as the slowest one plus
    /// the other two.
    private func performBucketsRefresh() async -> Bool {
        let usable = syncHosts.map { context.credential(for: $0) }.filter(\.isUsable)
        // Every bucket endpoint requires auth; skip quietly rather than
        // surfacing a "no token" error for a background sync the reviewer
        // never directly asked for.
        guard !usable.isEmpty else { return false }

        var merged: [InboxReviewerBucket: [InboxPR]] = [:]
        var failures: [String] = []

        await withTaskGroup(of: (ForgeHost, Result<[InboxReviewerBucket: [InboxPR]], Error>).self) { group in
            for credential in usable {
                group.addTask {
                    let service = await ForgeServices.inbox(host: credential.host, basic: credential.basic)
                    do {
                        return (credential.host, .success(try await service.fetchReviewerBuckets(token: credential.token)))
                    } catch {
                        return (credential.host, .failure(error))
                    }
                }
            }
            for await (host, result) in group {
                switch result {
                case .success(let buckets):
                    for (bucket, rows) in buckets {
                        merged[bucket, default: []] += rows
                    }
                case .failure(let error):
                    if error is CancellationError { continue }
                    // One unreachable host must not blank the queue of the
                    // others, so it is named rather than thrown.
                    failures.append("\(host.displayName): \(Self.describe(error))")
                }
            }
        }

        if merged.isEmpty && !failures.isEmpty {
            bucketsError = failures.joined(separator: " · ")
            return false
        }

        for bucket in InboxReviewerBucket.allCases {
            bucketRowsCache[bucket] = merged[bucket] ?? []
        }
        recomputeRows()
        lastBucketsSyncAt = Date()
        bucketsError = failures.isEmpty ? nil : failures.joined(separator: " · ")
        return true
    }

    private func recomputeRows() {
        let projectRows = projectRowsCache.values.flatMap { $0 }
        let bucketRows = bucketRowsCache.values.flatMap { $0 }
        rows = InboxPR.combine(projectRows: projectRows, bucketRows: bucketRows)
        lastRowsFetchedAt = Date()
        InboxCacheStore.save(rows, host: context.host)
    }

    private func updateProject(_ key: String, _ mutate: (inout WatchedProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.key == key }) else { return }
        mutate(&projects[index])
        persistProjects()
    }

    private func persistProjects() { WatchlistStore.saveProjects(projects) }
    private func persistLocalStatus() { LocalStatusStore.save(localStatus) }

    /// Prefers `LocalizedError.errorDescription` explicitly, matching
    /// `AppModel`'s pattern, so a `GitHubError`'s specific message always
    /// reaches the UI rather than a generic NSError-bridged fallback.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
