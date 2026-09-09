import Foundation

/// Lists the repositories the configured credential can reach, and the
/// organizations it belongs to.
///
/// One `GET /user/repos` crawl covers everything — personal repositories and
/// every organization's — and each item already names its owner, so grouping
/// happens locally. Fetching per organization instead would cost one request
/// per org plus a request to list the orgs, for the same result.
struct RepositoryDirectory {
    let api: GitHubAPI

    /// Bounded so a reviewer in a large organization does not trigger an
    /// unbounded crawl on their first sheet open. Sorted by recent activity,
    /// so the cap keeps what is most likely to be wanted.
    private let pageSize = 100
    private let maxPages = 10

    init(api: GitHubAPI) {
        self.api = api
    }

    /// Both lists at once. The organization list is independent of the
    /// repository crawl, so waiting for one before starting the other just
    /// adds its latency to the total.
    ///
    /// A missing `read:org` scope makes the organization call fail; that is
    /// not worth failing the whole load over, so it degrades to an empty
    /// list and the repository crawl alone becomes the answer.
    func snapshot(token: String?) async throws -> RepositoryCacheStore.Snapshot {
        async let repositories = accessibleRepositories(token: token)
        async let organizations = try? organizations(token: token)
        return RepositoryCacheStore.Snapshot(
            repositories: try await repositories,
            organizations: await organizations ?? [],
            fetchedAt: Date()
        )
    }

    /// Every repository the token can see, most recently active first.
    ///
    /// `affiliation` is explicit rather than defaulted: without it GitHub
    /// omits repositories the reviewer can reach only through an
    /// organization team, which is exactly the case this picker exists for.
    func accessibleRepositories(token: String?) async throws -> [AccessibleRepository] {
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        let repositories = try await api.getAllPagesConcurrently(
            AccessibleRepository.self,
            path: "/user/repos",
            token: token,
            query: [
                URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "direction", value: "desc"),
            ],
            perPage: pageSize,
            maxPages: maxPages
        )
        return repositories
    }

    /// The organizations the credential belongs to. Used to show an
    /// organization the reviewer is a member of even when the repository
    /// crawl returned nothing for it — an empty org is a real answer, and
    /// silently omitting it looks like a bug.
    ///
    /// A classic token without `read:org` is refused here; that is not a
    /// failure worth surfacing, so the caller treats it as "no extra orgs".
    func organizations(token: String?) async throws -> [AccessibleRepository.Owner] {
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        struct RawOrganization: Decodable {
            let login: String
            let avatarUrl: String?
            enum CodingKeys: String, CodingKey {
                case login
                case avatarUrl = "avatar_url"
            }
        }
        let raw = try await api.getAllPagesConcurrently(
            RawOrganization.self, path: "/user/orgs", token: token, perPage: pageSize, maxPages: 3
        )
        return raw.map { AccessibleRepository.Owner(login: $0.login, type: "Organization", avatarUrl: $0.avatarUrl) }
    }

    /// Server-side search, for the case the local list cannot answer: a
    /// repository the reviewer can read but is not affiliated with, or one
    /// beyond the crawl's page cap.
    func searchRepositories(matching query: String, token: String?) async throws -> [AccessibleRepository] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        struct SearchEnvelope: Decodable {
            let items: [AccessibleRepository]
        }
        let envelope = try await api.get(
            SearchEnvelope.self,
            path: "/search/repositories",
            token: token,
            query: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "per_page", value: "30"),
            ]
        )
        return envelope.items
    }

    // MARK: - Grouping

    /// Groups repositories by owner: the reviewer's personal account first,
    /// then organizations alphabetically. Pure, so it is unit-testable
    /// without a network call.
    ///
    /// `knownOrganizations` are folded in even when they own none of the
    /// fetched repositories, so a membership never silently disappears.
    static func grouped(
        _ repositories: [AccessibleRepository],
        knownOrganizations: [AccessibleRepository.Owner] = []
    ) -> [RepositoryOwnerGroup] {
        var byOwner: [String: [AccessibleRepository]] = [:]
        var owners: [String: AccessibleRepository.Owner] = [:]
        byOwner.reserveCapacity(repositories.count)

        for repository in repositories {
            byOwner[repository.owner.login, default: []].append(repository)
            owners[repository.owner.login] = repository.owner
        }
        for organization in knownOrganizations where owners[organization.login] == nil {
            owners[organization.login] = organization
            byOwner[organization.login] = []
        }

        return owners.values
            .map { owner in
                RepositoryOwnerGroup(
                    owner: owner,
                    repositories: (byOwner[owner.login] ?? []).sorted { lhs, rhs in
                        switch (lhs.lastActivityAt, rhs.lastActivityAt) {
                        case let (l?, r?) where l != r: return l > r
                        case (_?, nil): return true
                        case (nil, _?): return false
                        default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                        }
                    }
                )
            }
            .sorted { lhs, rhs in
                // A reviewer's own account is the one group they can always
                // name, so it leads; organizations then read alphabetically.
                if lhs.isPersonal != rhs.isPersonal { return lhs.isPersonal }
                return lhs.owner.login.localizedCaseInsensitiveCompare(rhs.owner.login) == .orderedAscending
            }
    }
}
