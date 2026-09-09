import XCTest

/// That the three hosts coexist, and that the abstraction over them holds.
@MainActor
final class ForgeAbstractionTests: XCTestCase {
    private let dotCom = ForgeHost.dotCom
    private let enterprise = ForgeHost.enterprise("github.mycorp.com")!
    private let gitlab = ForgeHost.gitlab("git.internal.example")!

    // MARK: - The factory

    /// One place decides which implementation serves which forge. This is
    /// the test that a fourth arm can't be forgotten in one of three
    /// switches, because there is only one switch per capability now.
    func testFactoryReturnsTheRightServicePerForge() {
        XCTAssertTrue(ForgeServices.inbox(host: dotCom, basic: nil) is InboxService)
        XCTAssertTrue(ForgeServices.inbox(host: enterprise, basic: nil) is InboxService)
        XCTAssertTrue(ForgeServices.inbox(host: gitlab, basic: nil) is GitLabInboxService)

        XCTAssertTrue(ForgeServices.directory(host: dotCom, basic: nil) is RepositoryDirectory)
        XCTAssertTrue(ForgeServices.directory(host: gitlab, basic: nil) is GitLabProjectDirectory)
    }

    /// Every forge has an inbox and a directory implementation, so a host
    /// can never be configured that the dashboard cannot serve.
    func testEveryForgeHasEveryCapability() {
        for forge in Forge.allCases {
            let host: ForgeHost = switch forge {
            case .github: dotCom
            case .gitlab: gitlab
            }
            XCTAssertEqual(host.forge, forge)
            _ = ForgeServices.inbox(host: host, basic: nil)
            _ = ForgeServices.directory(host: host, basic: nil)
            _ = ForgeServices.client(host: host, basic: nil)
        }
    }

    func testForgeClientReportsTheForgeItSpeaks() {
        XCTAssertEqual(ForgeServices.client(host: dotCom, basic: nil).forge, .github)
        XCTAssertEqual(ForgeServices.client(host: enterprise, basic: nil).forge, .github)
        XCTAssertEqual(ForgeServices.client(host: gitlab, basic: nil).forge, .gitlab)
    }

    /// The Basic credential has to survive the factory, or a proxied
    /// instance authenticates as nobody.
    func testBasicCredentialReachesTheTransport() throws {
        let basic = BasicCredential(username: "u", password: "p")
        let request = try GitLabAPI(host: gitlab, basic: basic).makeRequest(path: "/user", token: "glpat-x")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") ?? false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "glpat-x")
    }

    // MARK: - Three hosts at once

    /// The three host shapes are distinct identities, so their credentials,
    /// caches and watchlist entries cannot collide.
    func testThreeHostsAreDistinctIdentities() {
        let keys = Set([dotCom, enterprise, gitlab].map(\.identityKey))
        XCTAssertEqual(keys.count, 3)

        let accounts = Set([dotCom, enterprise, gitlab].map(ForgeCredentialStore.tokenAccount(for:)))
        XCTAssertEqual(accounts.count, 3, "each host stores its own token")
    }

    /// Watching the same owner/repo name on two hosts is two projects, not
    /// one — `acme/web` on GitHub.com and on an Enterprise appliance are
    /// different repositories.
    func testSameNameOnDifferentHostsAreDifferentProjects() {
        let onDotCom = WatchedProject(host: dotCom, owner: "acme", repo: "web")
        let onEnterprise = WatchedProject(host: enterprise, owner: "acme", repo: "web")
        let onGitLab = WatchedProject(host: gitlab, owner: "acme", repo: "web")

        XCTAssertEqual(Set([onDotCom.key, onEnterprise.key, onGitLab.key]).count, 3)
    }

    /// The bug this pins: every watched project used to sync against
    /// whichever host was *selected*, so a GitHub repository and a GitLab
    /// project could not both work — switching hosts silently sent each
    /// one's requests to the other's server.
    func testEachProjectCarriesTheHostItSyncsAgainst() {
        let projects = [
            WatchedProject(host: dotCom, owner: "acme", repo: "web"),
            WatchedProject(host: gitlab, owner: "platform/backend", repo: "api"),
        ]
        XCTAssertEqual(projects[0].host.forge, .github)
        XCTAssertEqual(projects[1].host.forge, .gitlab)
        // And the service each one needs follows from its own host, not from
        // any ambient selection.
        XCTAssertTrue(ForgeServices.inbox(host: projects[0].host, basic: nil) is InboxService)
        XCTAssertTrue(ForgeServices.inbox(host: projects[1].host, basic: nil) is GitLabInboxService)
    }

    /// The dashboard syncs the active host plus every host it watches
    /// something on, each exactly once.
    func testSyncHostsCoverTheActiveHostAndEveryWatchedHost() {
        let context = AppContext.stub(settings: {
            var settings = AppSettings()
            settings.githubHost = dotCom
            return settings
        }())
        let model = DashboardModel(context: context)

        // `projects` is set explicitly rather than asserted on first: a
        // `DashboardModel` loads the reviewer's real watchlist from
        // Application Support on init, so anything about its initial state
        // would pass or fail depending on whose Mac ran the test.
        model.projects = [
            WatchedProject(host: gitlab, owner: "a", repo: "b"),
            WatchedProject(host: gitlab, owner: "c", repo: "d"),
            WatchedProject(host: enterprise, owner: "e", repo: "f"),
        ]
        let keys = model.syncHosts.map(\.identityKey)
        XCTAssertEqual(Set(keys).count, keys.count, "no host is asked twice")
        XCTAssertEqual(Set(keys), Set([dotCom, gitlab, enterprise].map(\.identityKey)))
        XCTAssertEqual(keys.first, dotCom.identityKey, "the active host is asked first")

        // The active host is included even with nothing watched on it —
        // that is where a reviewer opening a URL lands.
        model.projects = [WatchedProject(host: gitlab, owner: "a", repo: "b")]
        XCTAssertTrue(model.syncHosts.contains { $0.identityKey == dotCom.identityKey })
    }

    // MARK: - Watching across hosts

    /// The picker browses a host without switching the app to it.
    ///
    /// The distinction that matters: watching a project and switching the
    /// review session are different acts. A reviewer adding a GitHub
    /// repository while reading a GitLab merge request must not have their
    /// workspace yanked to another server.
    func testBrowsingAHostDoesNotChangeTheActiveHost() {
        var settings = AppSettings()
        settings.githubHost = gitlab
        let context = AppContext.stub(token: "glpat-x", settings: settings)

        let picker = RepositoryPickerModel(
            context: context,
            alreadyWatchedKeys: [],
            availableHosts: [gitlab, dotCom, enterprise]
        )
        XCTAssertEqual(picker.browsingHost.identityKey, gitlab.identityKey, "opens on the active host")

        picker.browsingHost = dotCom
        XCTAssertEqual(picker.browsingHost.identityKey, dotCom.identityKey)
        XCTAssertEqual(
            context.settings().githubHost.identityKey,
            gitlab.identityKey,
            "the review session stays where it was"
        )
    }

    /// Selection is per host. Carrying keys across a switch would watch
    /// repositories the reviewer never saw, on a host they just left.
    func testSwitchingBrowsedHostClearsSelectionAndFilters() {
        let picker = RepositoryPickerModel(
            context: AppContext.stub(),
            alreadyWatchedKeys: [],
            availableHosts: [dotCom, gitlab]
        )
        picker.searchText = "api"
        picker.ownerFilter = "acme"

        picker.browsingHost = gitlab

        XCTAssertTrue(picker.selectedKeys.isEmpty)
        XCTAssertTrue(picker.searchText.isEmpty)
        XCTAssertNil(picker.ownerFilter)
    }

    /// The picker offers the active host even when the caller passes
    /// nothing, so it can never present an empty switcher.
    func testPickerAlwaysHasAtLeastTheActiveHost() {
        var settings = AppSettings()
        settings.githubHost = enterprise
        let picker = RepositoryPickerModel(
            context: AppContext.stub(settings: settings), alreadyWatchedKeys: []
        )
        XCTAssertEqual(picker.availableHosts.map(\.identityKey), [enterprise.identityKey])
        XCTAssertEqual(picker.browsingHost.identityKey, enterprise.identityKey)
    }

    /// Vocabulary follows the browsed host, not the active one — GitLab
    /// nests projects in groups, GitHub has organizations.
    func testPickerVocabularyFollowsTheBrowsedHost() {
        let picker = RepositoryPickerModel(
            context: AppContext.stub(), alreadyWatchedKeys: [], availableHosts: [dotCom, gitlab]
        )
        XCTAssertEqual(picker.itemNounPlural, "repositories")
        XCTAssertEqual(picker.ownerNounPlural, "Organizations")

        picker.browsingHost = gitlab
        XCTAssertEqual(picker.itemNounPlural, "projects")
        XCTAssertEqual(picker.ownerNoun, "group")
        XCTAssertEqual(picker.hostDisplayName, gitlab.displayName)
    }

    /// GitHub.com is always browsable: it needs no configuration to exist,
    /// so a reviewer whose only configured host is a GitLab instance can
    /// still watch a public GitHub repository.
    func testKnownHostsAlwaysIncludeGitHubDotCom() {
        var settings = AppSettings()
        settings.githubHost = gitlab
        settings.knownHosts = [gitlab]
        let hosts = ([ForgeHost.dotCom, settings.githubHost] + settings.knownHosts)
            .reduce(into: [ForgeHost]()) { result, host in
                if !result.contains(where: { $0.identityKey == host.identityKey }) { result.append(host) }
            }
        XCTAssertTrue(hosts.contains { $0.identityKey == ForgeHost.dotCom.identityKey })
        XCTAssertEqual(hosts.count, 2)
    }

    /// A settings blob written before multi-host support has no
    /// `knownHosts` key and must still decode.
    func testSettingsWithoutKnownHostsStillDecode() throws {
        let json = #"{"githubHost":{"displayName":"GitHub.com","apiBaseURL":"https://api.github.com","webBaseURL":"https://github.com","graphQLURL":"https://api.github.com/graphql"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.knownHosts.isEmpty)
        XCTAssertTrue(settings.githubHost.isDotCom)
    }

    // MARK: - Per-host credentials

    /// `token()` answers for the active host. A dashboard syncing three
    /// hosts has to ask per host instead, or two of them get the wrong
    /// credential.
    func testCredentialIsResolvedPerHost() {
        let context = AppContext.stub(token: "ghp_active")
        let resolved = context.credential(for: gitlab)
        XCTAssertEqual(resolved.host, gitlab)
        // The stub answers with one credential; the shape is what matters —
        // the caller names the host rather than assuming the ambient one.
        XCTAssertEqual(resolved.token, "ghp_active")
    }

    func testHostWithNoCredentialIsNotUsable() {
        let empty = HostCredential(host: gitlab, credential: .none)
        XCTAssertFalse(empty.isUsable)
        XCTAssertTrue(HostCredential(host: gitlab, credential: ForgeCredential(token: "glpat-x")).isUsable)
        // Basic alone counts: an instance behind a Basic front door may
        // authenticate with it.
        XCTAssertTrue(
            HostCredential(
                host: gitlab,
                credential: ForgeCredential(basic: BasicCredential(username: "u", password: "p"))
            ).isUsable
        )
    }

    // MARK: - No forge leaks in shared models

    /// `PRReference` used to answer `apiPath` as `/repos/owner/repo/pulls/n`
    /// — one forge's URL grammar on a model both forges share. Each client
    /// owns its own paths now.
    func testReferenceCarriesNoForgeSpecificPath() {
        let reference = PRReference(owner: "acme", repo: "web", number: 7)
        XCTAssertEqual(reference.key, "acme/web#7")

        XCTAssertEqual(
            GitHubClient(host: dotCom).pullRequestPath(reference),
            "/repos/acme/web/pulls/7"
        )
        XCTAssertEqual(
            GitLabAPI(host: gitlab).mergeRequestPath(reference),
            "/projects/acme%2Fweb/merge_requests/7"
        )
    }

    /// A GitLab project path nests, and the same reference type has to carry
    /// it — which is why the owner field holds the whole group path.
    func testNestedGitLabGroupSurvivesTheSharedReferenceType() {
        let reference = PRReference(owner: "platform/backend", repo: "api-gateway", number: 12)
        XCTAssertEqual(
            GitLabAPI(host: gitlab).mergeRequestPath(reference),
            "/projects/platform%2Fbackend%2Fapi-gateway/merge_requests/12"
        )
    }

    /// Each forge builds its own web URL shape from the same reference.
    func testWebURLsDifferPerForgeFromOneReference() {
        XCTAssertEqual(
            dotCom.webURL(owner: "acme", repo: "web", number: 7)?.absoluteString,
            "https://github.com/acme/web/pull/7"
        )
        XCTAssertEqual(
            enterprise.webURL(owner: "acme", repo: "web", number: 7)?.absoluteString,
            "https://github.mycorp.com/acme/web/pull/7"
        )
        XCTAssertEqual(
            gitlab.webURL(owner: "platform/backend", repo: "api", number: 7)?.absoluteString,
            "https://git.internal.example/platform/backend/api/-/merge_requests/7"
        )
    }

    /// Vocabulary follows the forge, so a GitLab reviewer is never told
    /// about pull requests.
    func testVocabularyFollowsTheHost() {
        XCTAssertEqual(dotCom.forge.changeNounCapitalized, "Pull Request")
        XCTAssertEqual(enterprise.forge.changeNounCapitalized, "Pull Request")
        XCTAssertEqual(gitlab.forge.changeNounCapitalized, "Merge Request")
    }
}
