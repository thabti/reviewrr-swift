import XCTest

/// Pure-logic coverage for the dashboard: filtering, searching,
/// sorting/grouping, local-status transitions and derived signals,
/// jitter/backoff interval math, and the watchlist codec. No network:
/// everything here operates on in-memory models and `AppContext.stub()`.
@MainActor
final class DashboardTests: XCTestCase {
    // MARK: - Fixtures

    private func makeRow(
        owner: String = "acme",
        repo: String = "web-app",
        number: Int = 1,
        title: String = "Fix the thing",
        author: String = "alice",
        state: InboxPRState = .open,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        createdAt: Date = Date(timeIntervalSince1970: 900_000),
        labels: [GitHubLabel] = [],
        headRef: String? = "alice/fix",
        headSha: String? = "sha-1",
        additions: Int? = 10,
        deletions: Int? = 2,
        changedFiles: Int? = 3,
        source: InboxPRSource = .project,
        buckets: Set<InboxReviewerBucket> = []
    ) -> InboxPR {
        InboxPR(
            host: .dotCom, owner: owner, repo: repo, number: number, title: title,
            authorLogin: author, authorAvatarURL: nil, state: state, isMerged: state == .merged,
            createdAt: createdAt, updatedAt: updatedAt, commentCount: 0, labels: labels,
            requestedReviewers: [], reviewDecision: .none, ciState: .unknown,
            additions: additions, deletions: deletions, changedFiles: changedFiles,
            headRef: headRef, headSha: headSha, source: source, buckets: buckets
        )
    }

    // MARK: - WatchedProject

    func testWatchedProjectParsesOwnerRepoShorthand() {
        let parsed = WatchedProject.parseOwnerRepo("acme/web-app")
        XCTAssertEqual(parsed?.owner, "acme")
        XCTAssertEqual(parsed?.repo, "web-app")
    }

    func testWatchedProjectParsesShorthandWithPRSuffix() {
        let parsed = WatchedProject.parseOwnerRepo("acme/web-app#482")
        XCTAssertEqual(parsed?.owner, "acme")
        XCTAssertEqual(parsed?.repo, "web-app")
    }

    func testWatchedProjectParsesRepoURL() {
        let parsed = WatchedProject.parseOwnerRepo("https://github.com/acme/web-app")
        XCTAssertEqual(parsed?.owner, "acme")
        XCTAssertEqual(parsed?.repo, "web-app")
    }

    func testWatchedProjectParsesRepoURLWithGitSuffix() {
        let parsed = WatchedProject.parseOwnerRepo("https://github.com/acme/web-app.git")
        XCTAssertEqual(parsed?.repo, "web-app")
    }

    func testWatchedProjectParsesPRURL() {
        let parsed = WatchedProject.parseOwnerRepo("https://github.com/acme/web-app/pull/482")
        XCTAssertEqual(parsed?.owner, "acme")
        XCTAssertEqual(parsed?.repo, "web-app")
    }

    func testWatchedProjectRejectsGarbageInput() {
        XCTAssertNil(WatchedProject.parseOwnerRepo("not a project"))
        XCTAssertNil(WatchedProject.parseOwnerRepo(""))
    }

    func testWatchedProjectCodecRoundTrip() throws {
        var project = WatchedProject(host: .dotCom, owner: "acme", repo: "web-app", addedAt: Date(timeIntervalSince1970: 1000))
        project.lastOpenedAt = Date(timeIntervalSince1970: 2000)
        project.lastSyncedAt = Date(timeIntervalSince1970: 3000)
        project.lastError = "rate limited"
        project.isMuted = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode([project])
        let decoded = try decoder.decode([WatchedProject].self, from: data)

        XCTAssertEqual(decoded, [project])
    }

    func testWatchedProjectDecodingToleratesMissingNewerFields() throws {
        // Simulates a watchlist file written before `isMuted`/`lastError`
        // existed — an old file must never lose a project over one
        // unrecognized (here: absent) key.
        let json = """
        [{"host": {"displayName": "GitHub.com", "apiBaseURL": "https://api.github.com",
                    "webBaseURL": "https://github.com", "graphQLURL": "https://api.github.com/graphql"},
          "owner": "acme", "repo": "web-app", "addedAt": "2024-01-01T00:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WatchedProject].self, from: Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].owner, "acme")
        XCTAssertFalse(decoded[0].isMuted)
        XCTAssertNil(decoded[0].lastError)
    }

    // MARK: - LocalPRStatus transitions and derived signals

    func testLocalPRStatusIsUnseenUntilSeenOnce() {
        var status = LocalPRStatus()
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(status.isUnseen(currentUpdatedAt: now))

        status.markOpened(updatedAt: now)
        XCTAssertFalse(status.isUnseen(currentUpdatedAt: now))
        XCTAssertEqual(status.status, .inReview)

        let later = now.addingTimeInterval(60)
        XCTAssertTrue(status.isUnseen(currentUpdatedAt: later))
    }

    func testLocalPRStatusIgnoredIsNeverUnseen() {
        var status = LocalPRStatus()
        status.setStatus(.ignored)
        XCTAssertFalse(status.isUnseen(currentUpdatedAt: Date().addingTimeInterval(3600)))
    }

    func testLocalPRStatusMarkOpenedDoesNotOverrideExplicitStatus() {
        var status = LocalPRStatus()
        status.setStatus(.ignored)
        status.markOpened(updatedAt: Date())
        XCTAssertEqual(status.status, .ignored, "opening a PR must never silently un-ignore it")
    }

    func testLocalPRStatusUpdatedSinceReviewDetectsForcePush() {
        var status = LocalPRStatus()
        status.setStatus(.reviewed, headSha: "sha-1")
        XCTAssertFalse(status.isUpdatedSinceReview(currentUpdatedAt: Date(), currentHeadSha: "sha-1"))
        XCTAssertTrue(status.isUpdatedSinceReview(currentUpdatedAt: Date(), currentHeadSha: "sha-2"))
    }

    func testLocalPRStatusUpdatedSinceReviewFallsBackToTimestampWithoutHeadSha() {
        var status = LocalPRStatus()
        let reviewedAt = Date(timeIntervalSince1970: 1000)
        status.setStatus(.reviewed, headSha: nil, updatedAt: reviewedAt)
        XCTAssertFalse(status.isUpdatedSinceReview(currentUpdatedAt: reviewedAt, currentHeadSha: nil))
        XCTAssertTrue(status.isUpdatedSinceReview(currentUpdatedAt: reviewedAt.addingTimeInterval(60), currentHeadSha: nil))
    }

    // MARK: - InboxPR merging

    func testInboxPRMergePrefersProjectSourceAndUnionsBuckets() {
        let projectRow = makeRow(additions: 20, deletions: 5, changedFiles: 4, source: .project, buckets: [])
        let searchRow = makeRow(additions: nil, deletions: nil, changedFiles: nil, source: .search, buckets: [.needsReview])

        let merged = projectRow.merged(with: searchRow)
        XCTAssertEqual(merged.additions, 20, "project-sourced diff stats should win over a search row's missing stats")
        XCTAssertEqual(merged.buckets, [.needsReview])
    }

    func testInboxPRCombineDedupesByIdentity() {
        let projectRows = [makeRow(number: 1, source: .project), makeRow(number: 2, source: .project)]
        let bucketRows = [makeRow(number: 1, source: .search, buckets: [.authored]), makeRow(number: 3, source: .search, buckets: [.assigned])]

        let combined = InboxPR.combine(projectRows: projectRows, bucketRows: bucketRows)
        XCTAssertEqual(combined.count, 3)
        let mergedPR1 = combined.first { $0.number == 1 }
        XCTAssertEqual(mergedPR1?.buckets, [.authored])
        XCTAssertEqual(mergedPR1?.source, .project)
    }

    // MARK: - InboxFiltering

    // MARK: - Sidebar counts

    /// A repository name no previous run can have written status for.
    private func isolatedProject() -> WatchedProject {
        WatchedProject(host: .dotCom, owner: "acme", repo: "web-\(UUID().uuidString.prefix(8))")
    }

    @MainActor
    func testProjectBadgeCountsOnlyOpenPullRequests() async {
        // The bug this fixes: a full state=all sync of a busy repository
        // reported 147 in the sidebar, of which nine were actually open.
        let model = DashboardModel(context: .stub())
        let project = isolatedProject()
        model.applyProjectRowsForTesting(
            [
                makeRow(owner: project.owner, repo: project.repo, number: 1, state: .open),
                makeRow(owner: project.owner, repo: project.repo, number: 2, state: .draft),
                makeRow(owner: project.owner, repo: project.repo, number: 3, state: .merged),
                makeRow(owner: project.owner, repo: project.repo, number: 4, state: .closed),
            ],
            for: project
        )
        XCTAssertEqual(model.openCount(for: project), 2, "drafts are open work; merged and closed are finished")
        XCTAssertEqual(model.unreadCount(for: project), 2, "an unseen closed PR is not asking for attention")
    }

    @MainActor
    func testIgnoredPullRequestsLeaveTheBadge() {
        let model = DashboardModel(context: .stub())
        let project = isolatedProject()
        let ignored = makeRow(owner: project.owner, repo: project.repo, number: 1, state: .open)
        model.applyProjectRowsForTesting(
            [ignored, makeRow(owner: project.owner, repo: project.repo, number: 2, state: .open)],
            for: project
        )
        XCTAssertEqual(model.openCount(for: project), 2)

        model.setLocalStatus(.ignored, for: ignored.reference)
        XCTAssertEqual(model.openCount(for: project), 1, "an ignored PR explicitly is not asking for attention")
        XCTAssertEqual(model.unreadCount(for: project), 1)
    }

    func testLiveStatesMatchTheInboxDefaultFilter() {
        // One definition behind both, so the badge can never promise a count
        // the inbox then declines to show.
        XCTAssertEqual(Set(InboxPRState.allCases.filter(\.isLive)), InboxFilter.defaultStates)
        XCTAssertTrue(InboxPRState.open.isLive)
        XCTAssertTrue(InboxPRState.draft.isLive)
        XCTAssertFalse(InboxPRState.merged.isLive)
        XCTAssertFalse(InboxPRState.closed.isLive)
    }

    // MARK: - Row cache

    private var enterpriseHost: ForgeHost { ForgeHost.enterprise("github.example.com")! }

    func testRowCacheRoundTripsAndReportsStaleness() {
        InboxCacheStore.clear(host: .dotCom)
        defer { InboxCacheStore.clear(host: .dotCom) }

        InboxCacheStore.save([makeRow(number: 1), makeRow(number: 2)], host: .dotCom)
        let loaded = InboxCacheStore.load(host: .dotCom)
        XCTAssertEqual(loaded?.rows.map(\.number), [1, 2])
        XCTAssertFalse(loaded?.isStale() ?? true, "just-saved rows are fresh")

        let old = InboxCacheStore.Snapshot(
            rows: [], fetchedAt: Date().addingTimeInterval(-InboxCacheStore.staleAfter - 60)
        )
        XCTAssertTrue(old.isStale())
    }

    func testRowCacheIsPerHost() {
        InboxCacheStore.clear(host: .dotCom)
        InboxCacheStore.clear(host: enterpriseHost)
        defer {
            InboxCacheStore.clear(host: .dotCom)
            InboxCacheStore.clear(host: enterpriseHost)
        }
        InboxCacheStore.save([makeRow(number: 1)], host: .dotCom)
        XCTAssertNotNil(InboxCacheStore.load(host: .dotCom))
        XCTAssertNil(InboxCacheStore.load(host: enterpriseHost))
    }

    @MainActor
    func testCachedRowsRenderImmediatelyOnLaunch() {
        InboxCacheStore.clear(host: .dotCom)
        defer { InboxCacheStore.clear(host: .dotCom) }
        InboxCacheStore.save([makeRow(number: 7)], host: .dotCom)

        // A fresh model, as at launch: no sync has run yet, but the inbox
        // must already have something to show rather than a spinner.
        let model = DashboardModel(context: .stub())
        XCTAssertEqual(model.rows.map(\.number), [7])
        XCTAssertTrue(model.hasCompletedFirstSync)
        XCTAssertNotNil(model.lastRowsFetchedAt)
    }

    @MainActor
    func testEmptyCacheLoadsNoRows() {
        // Deliberately does not assert on `hasCompletedFirstSync`: the model
        // reads the real watchlist from disk at init, so that flag depends
        // on whatever this machine has synced. The cache path is what this
        // test owns.
        InboxCacheStore.clear(host: .dotCom)
        let model = DashboardModel(context: .stub())
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.lastRowsFetchedAt)
    }

    // MARK: - Project selection

    @MainActor
    func testSelectingAProjectFiltersTheInboxToIt() {
        let model = DashboardModel(context: .stub())
        let key = WatchedProject.makeKey(host: .dotCom, owner: "acme", repo: "web")
        model.selectedProjectKey = key
        XCTAssertEqual(model.filter.projectKeys, [key])
        model.selectedProjectKey = nil
        XCTAssertTrue(model.filter.projectKeys.isEmpty)
    }

    func testProjectFilterKeepsOnlyThatProjectsRows() {
        let web = makeRow(owner: "acme", repo: "web", number: 1)
        let api = makeRow(owner: "acme", repo: "api", number: 2)
        var filter = InboxFilter()
        filter.projectKeys = [WatchedProject.makeKey(host: .dotCom, owner: "acme", repo: "web")]
        let result = InboxFiltering.apply(filter, to: [web, api], localStatus: [:])
        XCTAssertEqual(result.map(\.number), [1])
    }

    func testProjectFilterMatchesCaseInsensitively() {
        // GitHub treats owner/repo case-insensitively, and the key
        // normalizes — a row cased differently must still match.
        let row = makeRow(owner: "Acme", repo: "Web", number: 7)
        var filter = InboxFilter()
        filter.projectKeys = [WatchedProject.makeKey(host: .dotCom, owner: "acme", repo: "web")]
        XCTAssertEqual(InboxFiltering.apply(filter, to: [row], localStatus: [:]).map(\.number), [7])
    }

    func testProjectFilterCountsAsNarrowing() {
        var filter = InboxFilter()
        XCTAssertTrue(filter.isEmpty)
        filter.projectKeys = ["anything"]
        XCTAssertFalse(filter.isEmpty)
    }

    func testScaledSizesLandOnWholePoints() {
        // Fractional point sizes render text off the pixel grid, which is
        // what made scaled type look soft rather than larger.
        for base in [10.0, 11.5, 13.5, 17.0] as [CGFloat] {
            for size in InterfaceTextSize.allCases {
                let scaled = Theme.scaled(base, size.scale)
                XCTAssertEqual(scaled, scaled.rounded(), "\(base) at \(size.rawValue)")
                XCTAssertGreaterThanOrEqual(scaled, 1)
            }
        }
    }

    // MARK: - Section collapse and paging

    @MainActor
    func testGroupsPageAtTenRowsUntilExpanded() {
        let model = DashboardModel(context: .stub())
        let rows = (1...25).map { makeRow(number: $0) }

        XCTAssertEqual(model.visibleRows(rows, groupKey: "p").count, DashboardModel.collapsedGroupRowLimit)
        XCTAssertEqual(model.hiddenRowCount(rows, groupKey: "p"), 15)

        model.toggleShowingAllRows(groupKey: "p")
        XCTAssertEqual(model.visibleRows(rows, groupKey: "p").count, 25)
        XCTAssertEqual(model.hiddenRowCount(rows, groupKey: "p"), 0)
    }

    @MainActor
    func testShortGroupOffersNoShowMore() {
        let model = DashboardModel(context: .stub())
        let rows = (1...4).map { makeRow(number: $0) }
        XCTAssertEqual(model.visibleRows(rows, groupKey: "p").count, 4)
        XCTAssertEqual(model.hiddenRowCount(rows, groupKey: "p"), 0)
    }

    @MainActor
    func testCollapsedGroupRendersNoRowsAndPersists() {
        var stored = AppSettings()
        let context = AppContext(
            api: { GitHubAPI() }, token: { nil }, saveToken: { _ in }, forgetToken: {},
            basic: { nil }, saveBasic: { _ in }, reloadCredential: {},
            credentialFor: { HostCredential(host: $0, credential: .none) },
            knownHosts: { [.dotCom] },
            settings: { stored }, updateSettings: { stored = $0 }
        )
        let model = DashboardModel(context: context)
        let rows = (1...3).map { makeRow(number: $0) }

        XCTAssertFalse(model.isCollapsed(groupKey: "acme/web"))
        model.toggleCollapsed(groupKey: "acme/web")

        XCTAssertTrue(model.isCollapsed(groupKey: "acme/web"))
        XCTAssertTrue(model.visibleRows(rows, groupKey: "acme/web").isEmpty)
        // The collapse survives in settings, which is what makes it stick
        // across launches rather than resetting every time.
        XCTAssertTrue(stored.collapsedInboxGroups.contains("acme/web"))

        model.toggleCollapsed(groupKey: "acme/web")
        XCTAssertFalse(stored.collapsedInboxGroups.contains("acme/web"))
    }

    @MainActor
    func testCollapsedGroupHidesRowsEvenWhenExpandedForShowMore() {
        let model = DashboardModel(context: .stub())
        let rows = (1...25).map { makeRow(number: $0) }
        model.toggleShowingAllRows(groupKey: "p")
        model.toggleCollapsed(groupKey: "p")
        XCTAssertTrue(model.visibleRows(rows, groupKey: "p").isEmpty)
        XCTAssertEqual(model.hiddenRowCount(rows, groupKey: "p"), 0)
    }

    func testTextSizeScalesAreOrdered() {
        let scales = InterfaceTextSize.allCases.map(\.scale)
        XCTAssertEqual(scales, scales.sorted())
        XCTAssertEqual(InterfaceTextSize.standard.scale, 1)
    }

    func testDefaultFilterShowsOnlyLiveWork() {
        let rows = [
            makeRow(number: 1, state: .open),
            makeRow(number: 2, state: .draft),
            makeRow(number: 3, state: .merged),
            makeRow(number: 4, state: .closed),
        ]
        let result = InboxFiltering.apply(InboxFilter(), to: rows, localStatus: [:])
        XCTAssertEqual(result.map(\.number), [1, 2])
    }

    func testDefaultFilterCountsAsUnfiltered() {
        // The empty-state copy and the "filters active" affordance both key
        // off this, so the default view must not read as user-narrowed.
        XCTAssertTrue(InboxFilter().isEmpty)
        var narrowed = InboxFilter()
        narrowed.states = [.merged]
        XCTAssertFalse(narrowed.isEmpty)
    }

    func testHistoricalStatesRemainReachable() {
        let rows = [makeRow(number: 1, state: .open), makeRow(number: 2, state: .merged)]
        var filter = InboxFilter()
        filter.states = [.merged]
        XCTAssertEqual(InboxFiltering.apply(filter, to: rows, localStatus: [:]).map(\.number), [2])
    }

    func testInboxFilteringByState() {
        let rows = [makeRow(number: 1, state: .open), makeRow(number: 2, state: .merged)]
        var filter = InboxFilter()
        filter.states = [.open]
        let result = InboxFiltering.apply(filter, to: rows, localStatus: [:])
        XCTAssertEqual(result.map(\.number), [1])
    }

    func testInboxFilteringByLocalStatus() {
        let rows = [makeRow(number: 1), makeRow(number: 2)]
        var ignored = LocalPRStatus()
        ignored.setStatus(.ignored)
        let localStatus = [rows[1].statusKey: ignored]

        var filter = InboxFilter()
        filter.localStatuses = [.none]
        let result = InboxFiltering.apply(filter, to: rows, localStatus: localStatus)
        XCTAssertEqual(result.map(\.number), [1])
    }

    func testInboxFilteringByReviewRequestedOfMe() {
        let rows = [makeRow(number: 1, buckets: [.needsReview]), makeRow(number: 2, buckets: [.authored])]
        var filter = InboxFilter()
        filter.reviewRequestedOfMeOnly = true
        let result = InboxFiltering.apply(filter, to: rows, localStatus: [:])
        XCTAssertEqual(result.map(\.number), [1])
    }

    func testInboxFilteringByUpdatedWithin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rows = [
            makeRow(number: 1, updatedAt: now),
            makeRow(number: 2, updatedAt: now.addingTimeInterval(-10 * 86400)),
        ]
        var filter = InboxFilter()
        filter.updatedWithinDays = 1
        let result = InboxFiltering.apply(filter, to: rows, localStatus: [:], now: now)
        XCTAssertEqual(result.map(\.number), [1])
    }

    func testInboxFilteringSearchMatchesAcrossFields() {
        let rows = [
            makeRow(number: 1, title: "Improve caching", author: "bob", headRef: "bob/caching"),
            makeRow(number: 2, title: "Fix typo", author: "alice", headRef: "alice/typo"),
        ]
        var filter = InboxFilter()
        filter.searchText = "caching"
        let result = InboxFiltering.apply(filter, to: rows, localStatus: [:])
        XCTAssertEqual(result.map(\.number), [1])

        filter.searchText = "alice"
        let byAuthor = InboxFiltering.apply(filter, to: rows, localStatus: [:])
        XCTAssertEqual(byAuthor.map(\.number), [2])
    }

    func testInboxFilteringSortedByUpdatedDescending() {
        let older = makeRow(number: 1, updatedAt: Date(timeIntervalSince1970: 100))
        let newer = makeRow(number: 2, updatedAt: Date(timeIntervalSince1970: 200))
        let sorted = InboxFiltering.sorted([older, newer], field: .updated)
        XCTAssertEqual(sorted.map(\.number), [2, 1])
    }

    func testInboxFilteringGroupedByProjectOrdersByLastOpened() {
        var recentlyOpened = WatchedProject(host: .dotCom, owner: "acme", repo: "recent", addedAt: Date(timeIntervalSince1970: 0))
        recentlyOpened.lastOpenedAt = Date(timeIntervalSince1970: 2000)
        var staleProject = WatchedProject(host: .dotCom, owner: "acme", repo: "stale", addedAt: Date(timeIntervalSince1970: 0))
        staleProject.lastOpenedAt = Date(timeIntervalSince1970: 1000)

        let rows = [
            makeRow(owner: "acme", repo: "stale", number: 1),
            makeRow(owner: "acme", repo: "recent", number: 2),
        ]
        let groups = InboxFiltering.groupedByProject(rows, projects: [staleProject, recentlyOpened])
        XCTAssertEqual(groups.map(\.project.repo), ["recent", "stale"])
    }

    func testInboxFilteringGroupedByReviewerBucket() {
        let rows = [
            makeRow(number: 1, buckets: [.needsReview]),
            makeRow(number: 2, buckets: [.authored, .needsReview]),
            makeRow(number: 3, buckets: [.authored]),
        ]
        let groups = InboxFiltering.groupedByReviewerBucket(rows)
        let needsReview = groups.first { $0.bucket == .needsReview }
        XCTAssertEqual(Set(needsReview?.rows.map(\.number) ?? []), [1, 2])
        let authored = groups.first { $0.bucket == .authored }
        XCTAssertEqual(Set(authored?.rows.map(\.number) ?? []), [2, 3])
    }

    // MARK: - PollingCoordinator interval math

    func testJitteredIntervalStaysWithinBounds() {
        for _ in 0..<50 {
            let interval = PollingCoordinator.jitteredInterval(base: 300, jitterFraction: 0.2)
            XCTAssertGreaterThanOrEqual(interval, 240)
            XCTAssertLessThanOrEqual(interval, 360)
        }
    }

    func testJitteredIntervalWithZeroJitterIsExact() {
        let interval = PollingCoordinator.jitteredInterval(base: 300, jitterFraction: 0)
        XCTAssertEqual(interval, 300, accuracy: 0.001)
    }

    func testBackoffDoublesAndCapsAtMax() {
        XCTAssertEqual(PollingCoordinator.nextBackoffInterval(previous: 300, base: 300, max: 1800), 600)
        XCTAssertEqual(PollingCoordinator.nextBackoffInterval(previous: 600, base: 300, max: 1800), 1200)
        XCTAssertEqual(PollingCoordinator.nextBackoffInterval(previous: 1200, base: 300, max: 1800), 1800)
        // Already at (or past) the cap: stays capped rather than continuing to grow.
        XCTAssertEqual(PollingCoordinator.nextBackoffInterval(previous: 1800, base: 300, max: 1800), 1800)
    }

    // MARK: - DashboardModel (constructed via AppContext.stub(), no network)

    func testDashboardModelHasTokenReflectsContext() {
        let withToken = DashboardModel(context: .stub(token: "ghp_test"))
        XCTAssertTrue(withToken.hasToken)

        let withoutToken = DashboardModel(context: .stub(token: nil))
        XCTAssertFalse(withoutToken.hasToken)
    }

    func testDashboardModelFilteredRowsReflectFilterAndSearch() {
        let model = DashboardModel(context: .stub())
        model.rows = [makeRow(number: 1, title: "Add caching"), makeRow(number: 2, title: "Fix typo")]
        model.searchText = "caching"
        XCTAssertEqual(model.filteredRows.map(\.number), [1])
    }

    func testDashboardModelProjectGroupsUseCurrentGrouping() {
        let model = DashboardModel(context: .stub())
        let project = WatchedProject(host: .dotCom, owner: "acme", repo: "web-app")
        model.projects = [project]
        model.rows = [makeRow(owner: "acme", repo: "web-app", number: 1)]

        let groups = model.projectGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.rows.map(\.number), [1])
    }

    // MARK: - Persistence failures are reported, not swallowed

    /// A seam that stays in memory: the model reads the real watchlist and
    /// status map from Application Support at `init`, so a test that cares
    /// about either has to start from state it set itself rather than
    /// whatever this Mac happens to have synced — and must not write over
    /// the developer's own files on the way.
    private func inMemoryPersistence(
        projects: [WatchedProject] = [],
        status: [String: LocalPRStatus] = [:]
    ) -> DashboardPersistence {
        var storedProjects = projects
        var storedStatus = status
        return DashboardPersistence(
            loadProjects: { storedProjects },
            saveProjects: { storedProjects = $0 },
            loadLocalStatus: { storedStatus },
            saveLocalStatus: { storedStatus = $0 }
        )
    }

    @MainActor
    func testFailedWatchlistSaveIsReportedAndRetryable() {
        // The defect: both stores were `try?` behind a `Void` return, so a
        // full volume looked exactly like a successful save — the watchlist
        // was correct all session and empty at the next launch.
        var writesFail = true
        var stored: [WatchedProject] = []
        let persistence = DashboardPersistence(
            loadProjects: { [] },
            saveProjects: { projects in
                if writesFail { throw DashboardSaveFailure.noSpace }
                stored = projects
            },
            loadLocalStatus: { [:] },
            saveLocalStatus: { _ in }
        )
        let model = DashboardModel(context: .stub(), persistence: persistence)
        XCTAssertNil(model.saveError, "a healthy model must not cry wolf")

        let project = isolatedProject()
        model.projects = [project]
        model.toggleMute(project)

        XCTAssertNotNil(model.saveError, "a watchlist write that failed has to be reported")
        XCTAssertTrue(model.projects[0].isMuted, "the reviewer's change stands — only its trip to disk failed")
        XCTAssertTrue(stored.isEmpty)

        writesFail = false
        model.retrySave()
        XCTAssertNil(model.saveError)
        XCTAssertEqual(stored.map(\.key), [project.key], "Retry writes what was still only in memory")
    }

    @MainActor
    func testFailedLocalStatusSaveIsReportedAndRetryable() {
        var writesFail = true
        var stored: [String: LocalPRStatus] = [:]
        let persistence = DashboardPersistence(
            loadProjects: { [] },
            saveProjects: { _ in },
            loadLocalStatus: { [:] },
            saveLocalStatus: { status in
                if writesFail { throw DashboardSaveFailure.noSpace }
                stored = status
            }
        )
        let model = DashboardModel(context: .stub(), persistence: persistence)
        let reference = PRReference(owner: "acme", repo: "web-app", number: 41)

        model.setLocalStatus(.reviewed, for: reference)
        XCTAssertNotNil(model.saveError, "a dozen PRs marked reviewed must not be lost silently")
        XCTAssertEqual(model.localStatus[reference.key]?.status, .reviewed)

        writesFail = false
        model.retrySave()
        XCTAssertNil(model.saveError)
        XCTAssertEqual(stored[reference.key]?.status, .reviewed)
    }

    @MainActor
    func testWarningStaysWhileEitherFileIsStillUnsaved() {
        // One file recovering is not the all-clear: the banner has to keep
        // describing whatever is still only in memory.
        var projectWritesFail = true
        let persistence = DashboardPersistence(
            loadProjects: { [] },
            saveProjects: { _ in if projectWritesFail { throw DashboardSaveFailure.noSpace } },
            loadLocalStatus: { [:] },
            saveLocalStatus: { _ in throw DashboardSaveFailure.noSpace }
        )
        let model = DashboardModel(context: .stub(), persistence: persistence)
        let project = isolatedProject()
        model.projects = [project]
        model.toggleMute(project)
        model.setLocalStatus(.reviewed, for: PRReference(owner: project.owner, repo: project.repo, number: 7))
        XCTAssertNotNil(model.saveError)

        projectWritesFail = false
        model.retrySave()
        XCTAssertNotNil(model.saveError, "the status map is still unsaved, so the warning stands")
    }

    // MARK: - A refresh that outlives interest in its project

    @MainActor
    func testRefreshLandingAfterRemovalWritesNoRows() {
        // The race: refresh the dashboard, then immediately unwatch a
        // project. Its finished sync used to write its rows back — into the
        // inbox's header count but not its groups, into keyboard selection,
        // and into the on-disk cache under a key no later refresh could ever
        // overwrite, because the project was gone from the sidebar.
        InboxCacheStore.clear(host: .dotCom)
        defer { InboxCacheStore.clear(host: .dotCom) }

        let project = isolatedProject()
        let model = DashboardModel(context: .stub(), persistence: inMemoryPersistence(projects: [project]))
        let rows = [makeRow(owner: project.owner, repo: project.repo, number: 1)]

        XCTAssertNotNil(model.commitProjectRows(rows, for: project), "while watched, a finished sync commits")
        XCTAssertEqual(model.rows.map(\.number), [1])

        model.removeProject(project)
        XCTAssertTrue(model.rows.isEmpty)

        XCTAssertNil(model.commitProjectRows(rows, for: project), "an unwatched project's rows must not be written")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.openCount(for: project), 0)
        XCTAssertEqual(InboxCacheStore.load(host: .dotCom)?.rows.count, 0, "and nothing ghost-like reaches the cache")
    }

    @MainActor
    func testCancelledRefreshWritesNoRows() async {
        // Sign-out and `stop()` cancel the in-flight sync, but a response can
        // already be on its way back when they do: it used to commit rows and
        // fire a notification for an account that had just signed out.
        InboxCacheStore.clear(host: .dotCom)
        defer { InboxCacheStore.clear(host: .dotCom) }

        let project = isolatedProject()
        let model = DashboardModel(context: .stub(), persistence: inMemoryPersistence(projects: [project]))
        let rows = [makeRow(owner: project.owner, repo: project.repo, number: 2)]

        let landing = Task { @MainActor in model.commitProjectRows(rows, for: project) }
        landing.cancel()

        let committed = await landing.value
        XCTAssertNil(committed, "a cancelled sync must not write, even with the answer in hand")
        XCTAssertTrue(model.rows.isEmpty)
    }
}

/// Stands in for the disk being full or the folder having lost write
/// permission — the two ways these saves fail in the field.
private enum DashboardSaveFailure: Error {
    case noSpace
}

/// A pull request's size has to fit its column at a glance.
///
/// A release branch's "+32,940 −9,658" overflowed the trailing cluster and
/// wrapped into two half-numbers stacked on each other — the exact opposite
/// of a glanceable size. The order of magnitude is the triage signal; the
/// exact count lives in the tooltip.
final class InboxDiffSizeTests: XCTestCase {
    func testSmallCountsStayExact() {
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(0), "0")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(9), "9")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(999), "999")
    }

    func testThousandsKeepOneDecimal() {
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(1_000), "1.0k")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(3_646), "3.6k")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(9_999), "10.0k")
    }

    /// The same formatter now writes comment and file counts, so a four-digit
    /// count cannot widen a column past what it can hold.
    func testCountsUseTheSameAbbreviation() {
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(31), "31")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(702), "702")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(1_240), "1.2k")
    }

    func testTensOfThousandsDropTheDecimal() {
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(32_940), "32k")
        XCTAssertEqual(InboxDiffSizeFormatting.abbreviate(120_000), "120k")
    }
}
