import XCTest

final class RepositoryDirectoryTests: XCTestCase {
    private func repo(
        _ id: Int,
        owner: String,
        ownerType: String = "Organization",
        name: String,
        isPrivate: Bool = false,
        isFork: Bool = false,
        isArchived: Bool = false,
        description: String? = nil,
        pushedAt: Date? = nil
    ) -> AccessibleRepository {
        // Built through the decoder rather than a memberwise initializer so
        // the tests also cover the JSON contract the API actually returns.
        let pushed = pushedAt.map { "\"\(ISO8601DateFormatter().string(from: $0))\"" } ?? "null"
        let descriptionJSON = description.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "id": \(id),
          "name": "\(name)",
          "full_name": "\(owner)/\(name)",
          "owner": {"login": "\(owner)", "type": "\(ownerType)", "avatar_url": null},
          "private": \(isPrivate),
          "fork": \(isFork),
          "archived": \(isArchived),
          "description": \(descriptionJSON),
          "updated_at": null,
          "pushed_at": \(pushed),
          "open_issues_count": 3,
          "default_branch": "main"
        }
        """
        return try! GitHubAPI.decoder.decode(AccessibleRepository.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testDecodesTheFieldsThePickerShows() {
        let decoded = repo(1, owner: "acme", name: "web", isPrivate: true, description: "The storefront")
        XCTAssertEqual(decoded.fullName, "acme/web")
        XCTAssertEqual(decoded.owner.login, "acme")
        XCTAssertTrue(decoded.owner.isOrganization)
        XCTAssertTrue(decoded.isPrivate)
        XCTAssertEqual(decoded.description, "The storefront")
        XCTAssertEqual(decoded.defaultBranch, "main")
    }

    func testPersonalAccountIsNotAnOrganization() {
        XCTAssertFalse(repo(1, owner: "octo-dev", ownerType: "User", name: "dotfiles").owner.isOrganization)
    }

    // MARK: - Grouping

    func testGroupsByOwnerWithPersonalAccountFirstThenAlphabetical() {
        let repositories = [
            repo(1, owner: "zeta-corp", name: "api"),
            repo(2, owner: "octo-dev", ownerType: "User", name: "dotfiles"),
            repo(3, owner: "acme", name: "web"),
        ]
        let groups = RepositoryDirectory.grouped(repositories)
        XCTAssertEqual(groups.map(\.owner.login), ["octo-dev", "acme", "zeta-corp"])
    }

    func testGroupOrdersRepositoriesByMostRecentActivity() {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        let repositories = [
            repo(1, owner: "acme", name: "stale", pushedAt: old),
            repo(2, owner: "acme", name: "fresh", pushedAt: recent),
        ]
        let groups = RepositoryDirectory.grouped(repositories)
        XCTAssertEqual(groups.first?.repositories.map(\.name), ["fresh", "stale"])
    }

    func testRepositoriesWithNoActivityFallBackToNameOrder() {
        let repositories = [
            repo(1, owner: "acme", name: "zebra"),
            repo(2, owner: "acme", name: "alpha"),
        ]
        XCTAssertEqual(RepositoryDirectory.grouped(repositories).first?.repositories.map(\.name), ["alpha", "zebra"])
    }

    func testKnownOrganizationWithNoRepositoriesStillAppears() {
        // A membership that owns nothing the token can read is a real
        // answer; omitting it silently looks like the org is missing.
        let groups = RepositoryDirectory.grouped(
            [repo(1, owner: "acme", name: "web")],
            knownOrganizations: [AccessibleRepository.Owner(login: "empty-org", type: "Organization", avatarUrl: nil)]
        )
        XCTAssertEqual(groups.map(\.owner.login), ["acme", "empty-org"])
        XCTAssertEqual(groups.last?.repositories.count, 0)
    }

    func testKnownOrganizationDoesNotDuplicateAnOwnerAlreadyPresent() {
        let groups = RepositoryDirectory.grouped(
            [repo(1, owner: "acme", name: "web")],
            knownOrganizations: [AccessibleRepository.Owner(login: "acme", type: "Organization", avatarUrl: nil)]
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.repositories.count, 1)
    }

    // MARK: - Matching

    func testMatchesNameOwnerFullNameAndDescription() {
        let repository = repo(1, owner: "acme-tech", name: "acme-storefront", description: "Storefront app")
        XCTAssertTrue(repository.matches("acme-store"))
        XCTAssertTrue(repository.matches("ACME-TECH"))
        XCTAssertTrue(repository.matches("acme-tech/acme"))
        XCTAssertTrue(repository.matches("storefront"))
        XCTAssertTrue(repository.matches(""))
        XCTAssertFalse(repository.matches("checkout"))
    }

    func testLastActivityPrefersTheMoreRecentTimestamp() {
        let pushed = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(repo(1, owner: "acme", name: "web", pushedAt: pushed).lastActivityAt, pushed)
        XCTAssertNil(repo(2, owner: "acme", name: "none").lastActivityAt)
    }
}

final class RepositoryCacheStoreTests: XCTestCase {
    private func repo(_ id: Int) -> AccessibleRepository {
        let json = """
        {
          "id": \(id), "name": "repo\(id)", "full_name": "acme/repo\(id)",
          "owner": {"login": "acme", "type": "Organization", "avatar_url": null},
          "private": false, "fork": false, "archived": false,
          "description": "cached", "updated_at": null, "pushed_at": null,
          "open_issues_count": 0, "default_branch": "main"
        }
        """
        return try! GitHubAPI.decoder.decode(AccessibleRepository.self, from: Data(json.utf8))
    }

    /// An Enterprise host must never be served github.com's cache, so the
    /// two are written to separate files.
    private let enterprise = ForgeHost.enterprise("github.example.com")!

    override func tearDown() {
        RepositoryCacheStore.clear(host: .dotCom)
        RepositoryCacheStore.clear(host: enterprise)
        super.tearDown()
    }

    func testSnapshotRoundTripsThroughDisk() {
        let snapshot = RepositoryCacheStore.Snapshot(
            repositories: [repo(1), repo(2)],
            organizations: [AccessibleRepository.Owner(login: "acme", type: "Organization", avatarUrl: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        RepositoryCacheStore.save(snapshot, host: .dotCom)

        let loaded = RepositoryCacheStore.load(host: .dotCom)
        XCTAssertEqual(loaded?.repositories.map(\.fullName), ["acme/repo1", "acme/repo2"])
        XCTAssertEqual(loaded?.organizations.first?.login, "acme")
        XCTAssertEqual(loaded?.fetchedAt, snapshot.fetchedAt)
    }

    func testHostsDoNotShareACache() {
        RepositoryCacheStore.save(
            .init(repositories: [repo(1)], organizations: [], fetchedAt: Date()), host: .dotCom
        )
        XCTAssertNotNil(RepositoryCacheStore.load(host: .dotCom))
        XCTAssertNil(RepositoryCacheStore.load(host: enterprise), "an Enterprise host must not read github.com's cache")
    }

    func testStalenessUsesTheFetchTimestamp() {
        let fresh = RepositoryCacheStore.Snapshot(repositories: [], organizations: [], fetchedAt: Date())
        XCTAssertFalse(fresh.isStale())

        let old = RepositoryCacheStore.Snapshot(
            repositories: [], organizations: [],
            fetchedAt: Date().addingTimeInterval(-RepositoryCacheStore.staleAfter - 60)
        )
        XCTAssertTrue(old.isStale())
    }

    func testClearRemovesTheSnapshot() {
        RepositoryCacheStore.save(.init(repositories: [repo(1)], organizations: [], fetchedAt: Date()), host: .dotCom)
        RepositoryCacheStore.clear(host: .dotCom)
        XCTAssertNil(RepositoryCacheStore.load(host: .dotCom))
    }
}

final class PaginationLinkTests: XCTestCase {
    private func response(link: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/user/repos")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: link.map { ["Link": $0] } ?? [:]
        )!
    }

    func testReadsTheLastPageNumber() {
        // Knowing the page count after one round trip is what lets the
        // remaining pages be fetched in parallel instead of one by one.
        let link = """
        <https://api.github.com/user/repos?per_page=100&page=2>; rel="next", \
        <https://api.github.com/user/repos?per_page=100&page=6>; rel="last"
        """
        XCTAssertEqual(GitHubAPI.lastPageNumber(from: response(link: link)), 6)
    }

    func testSinglePageResponseHasNoLastLink() {
        XCTAssertNil(GitHubAPI.lastPageNumber(from: response(link: nil)))
        let onlyNext = "<https://api.github.com/user/repos?page=2>; rel=\"next\""
        XCTAssertNil(GitHubAPI.lastPageNumber(from: response(link: onlyNext)))
    }

    func testMalformedLinkHeaderIsIgnored() {
        XCTAssertNil(GitHubAPI.lastPageNumber(from: response(link: "garbage; rel=\"last\"")))
        XCTAssertNil(GitHubAPI.lastPageNumber(from: response(link: "<not a url>; rel=\"last\"")))
    }
}

@MainActor
final class RepositoryPickerModelTests: XCTestCase {
    private func repo(_ id: Int, owner: String, name: String, isFork: Bool = false, isArchived: Bool = false) -> AccessibleRepository {
        let json = """
        {
          "id": \(id), "name": "\(name)", "full_name": "\(owner)/\(name)",
          "owner": {"login": "\(owner)", "type": "Organization", "avatar_url": null},
          "private": false, "fork": \(isFork), "archived": \(isArchived),
          "description": null, "updated_at": null, "pushed_at": null,
          "open_issues_count": 0, "default_branch": "main"
        }
        """
        return try! GitHubAPI.decoder.decode(AccessibleRepository.self, from: Data(json.utf8))
    }

    /// The model loads over the network, so these tests drive its pure
    /// filtering and selection surface by seeding groups the same way a
    /// finished load would.
    private func seeded(
        _ repositories: [AccessibleRepository], watched: Set<String> = [], applyDefaultScope: Bool = false
    ) -> RepositoryPickerModel {
        let model = RepositoryPickerModel(context: .stub(token: "ghp_test"), alreadyWatchedKeys: watched)
        model.applyLoadedForTesting(
            RepositoryDirectory.grouped(repositories), applyDefaultScope: applyDefaultScope
        )
        return model
    }

    private func personalRepo(_ id: Int, owner: String, name: String) -> AccessibleRepository {
        let json = """
        {
          "id": \(id), "name": "\(name)", "full_name": "\(owner)/\(name)",
          "owner": {"login": "\(owner)", "type": "User", "avatar_url": null},
          "private": false, "fork": false, "archived": false,
          "description": null, "updated_at": null, "pushed_at": null,
          "open_issues_count": 0, "default_branch": "main"
        }
        """
        return try! GitHubAPI.decoder.decode(AccessibleRepository.self, from: Data(json.utf8))
    }

    func testSearchNarrowsWithinGroups() {
        let model = seeded([
            repo(1, owner: "acme", name: "web"),
            repo(2, owner: "acme", name: "api"),
            repo(3, owner: "other", name: "webhooks"),
        ])
        model.searchText = "web"
        XCTAssertEqual(model.totalVisibleCount, 2)
        model.searchText = "api"
        XCTAssertEqual(model.visibleGroups.flatMap(\.repositories).map(\.name), ["api"])
    }

    func testOwnerFilterScopesToOneOrganization() {
        let model = seeded([
            repo(1, owner: "acme", name: "web"),
            repo(2, owner: "other", name: "api"),
        ])
        model.ownerFilter = "acme"
        XCTAssertEqual(model.visibleGroups.map(\.owner.login), ["acme"])
        model.ownerFilter = nil
        XCTAssertEqual(model.visibleGroups.count, 2)
    }

    func testForksAndArchivedAreHiddenByDefault() {
        // Forks and archived repositories were the bulk of the noise: a
        // reviewer's 31 "owners" were mostly one personal fork each.
        let model = seeded([
            repo(1, owner: "acme", name: "plain"),
            repo(2, owner: "acme", name: "forked", isFork: true),
            repo(3, owner: "acme", name: "old", isArchived: true),
        ])
        XCTAssertEqual(model.visibleGroups.flatMap(\.repositories).map(\.name), ["plain"])

        model.includeForks = true
        XCTAssertEqual(model.totalVisibleCount, 2)

        model.includeArchived = true
        XCTAssertEqual(model.totalVisibleCount, 3)
    }

    // MARK: - Scopes

    func testScopesSplitOrganizationsFromAccountsAndSortByCount() {
        let model = seeded([
            repo(1, owner: "small-org", name: "a"),
            repo(2, owner: "big-org", name: "b"),
            repo(3, owner: "big-org", name: "c"),
            repo(4, owner: "big-org", name: "d"),
            personalRepo(5, owner: "octo-dev", name: "dotfiles"),
        ])
        XCTAssertEqual(model.organizationScopes.map(\.title), ["big-org", "small-org"])
        XCTAssertEqual(model.organizationScopes.map(\.count), [3, 1])
        XCTAssertEqual(model.personalScopes.map(\.title), ["octo-dev"])
    }

    func testDefaultScopeIsTheBusiestOrganizationNotEverything() {
        // Opening onto every repository across every owner is the problem
        // this picker exists to solve, so it must never be the landing state.
        let model = seeded(
            [
                repo(1, owner: "small-org", name: "a"),
                repo(2, owner: "big-org", name: "b"),
                repo(3, owner: "big-org", name: "c"),
                personalRepo(4, owner: "octo-dev", name: "dotfiles"),
            ],
            applyDefaultScope: true
        )
        XCTAssertEqual(model.ownerFilter, "big-org")
        XCTAssertEqual(model.visibleGroups.map(\.owner.login), ["big-org"])
    }

    func testDefaultScopeFallsBackToAnAccountWhenThereAreNoOrganizations() {
        let model = seeded([personalRepo(1, owner: "octo-dev", name: "dotfiles")], applyDefaultScope: true)
        XCTAssertEqual(model.ownerFilter, "octo-dev")
    }

    func testScopeCountsExcludeFilteredRepositories() {
        // A count that includes rows the reviewer cannot see is a lie.
        let model = seeded([
            repo(1, owner: "acme", name: "real"),
            repo(2, owner: "acme", name: "forked", isFork: true),
        ])
        XCTAssertEqual(model.organizationScopes.first?.count, 1)
        model.includeForks = true
        XCTAssertEqual(model.organizationScopes.first?.count, 2)
    }

    func testAllScopeCountsEveryVisibleRepository() {
        let model = seeded([
            repo(1, owner: "acme", name: "a"),
            repo(2, owner: "other", name: "b"),
        ])
        XCTAssertEqual(model.allScope.count, 2)
        XCTAssertTrue(model.allScope.isAll)
    }

    func testAlreadyWatchedRepositoriesCannotBeSelected() {
        let watchedRepo = repo(1, owner: "acme", name: "web")
        let key = watchedRepo.watchKey(host: .dotCom)
        let model = seeded([watchedRepo, repo(2, owner: "acme", name: "api")], watched: [key])

        XCTAssertTrue(model.isWatched(watchedRepo))
        model.toggleSelection(watchedRepo)
        XCTAssertTrue(model.selectedKeys.isEmpty, "watching something twice is not a thing to allow")
    }

    func testSelectionTogglesAndClears() {
        let target = repo(1, owner: "acme", name: "web")
        let model = seeded([target])
        model.toggleSelection(target)
        XCTAssertTrue(model.isSelected(target))
        XCTAssertEqual(model.selectedRepositories.map(\.name), ["web"])
        model.toggleSelection(target)
        XCTAssertFalse(model.isSelected(target))
    }

    func testSelectAllVisibleSkipsWatchedAndHiddenRows() {
        let watchedRepo = repo(1, owner: "acme", name: "web")
        let model = seeded(
            [watchedRepo, repo(2, owner: "acme", name: "api"), repo(3, owner: "other", name: "unrelated")],
            watched: [watchedRepo.watchKey(host: .dotCom)]
        )
        model.ownerFilter = "acme"
        model.selectAllVisible()
        XCTAssertEqual(model.selectedRepositories.map(\.name), ["api"])

        model.clearSelection()
        XCTAssertTrue(model.selectedKeys.isEmpty)
    }
}
