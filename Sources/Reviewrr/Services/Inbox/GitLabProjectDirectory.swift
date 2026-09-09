import Foundation

/// Lists the GitLab projects the configured credential can reach, and the
/// groups they belong to.
///
/// The GitLab half of `RepositoryDirectory`, producing the same
/// `AccessibleRepository` values so the watch-a-project picker groups,
/// searches, and renders them without knowing which forge they came from.
///
/// One `GET /projects?membership=true` crawl covers everything: personal
/// projects and every group's, each already naming its namespace, so
/// grouping happens locally. Listing groups and then their projects would
/// cost a request per group for the same answer.
struct GitLabProjectDirectory {
    let api: GitLabAPI

    /// Bounded so a reviewer in a large instance does not trigger an
    /// unbounded crawl on their first sheet open. Ordered by recent
    /// activity, so the cap keeps what is most likely to be wanted.
    private let pageSize = 100
    private let maxPages = 10

    init(api: GitLabAPI) {
        self.api = api
    }

    /// One project as GitLab returns it.
    struct RawProject: Decodable, Sendable {
        struct Namespace: Decodable, Sendable {
            let id: Int
            let name: String
            /// "group" or "user" — how the picker tells a group-owned
            /// project from a personal one.
            let kind: String?
            let fullPath: String?
            let avatarUrl: String?

            enum CodingKeys: String, CodingKey {
                case id, name, kind
                case fullPath = "full_path"
                case avatarUrl = "avatar_url"
            }
        }

        /// Present only when the project is a fork, which is how GitLab
        /// reports forkedness — there is no boolean.
        struct ForkedFrom: Decodable, Sendable {
            let id: Int
        }

        let id: Int
        let name: String
        let pathWithNamespace: String
        let namespace: Namespace
        let visibility: String?
        let archived: Bool?
        let description: String?
        let lastActivityAt: Date?
        let openIssuesCount: Int?
        let defaultBranch: String?
        let forkedFromProject: ForkedFrom?

        enum CodingKeys: String, CodingKey {
            case id, name, namespace, visibility, archived, description
            case pathWithNamespace = "path_with_namespace"
            case lastActivityAt = "last_activity_at"
            case openIssuesCount = "open_issues_count"
            case defaultBranch = "default_branch"
            case forkedFromProject = "forked_from_project"
        }
    }

    func snapshot(token: String?) async throws -> RepositoryCacheStore.Snapshot {
        let projects = try await accessibleProjects(token: token)
        return RepositoryCacheStore.Snapshot(
            repositories: projects,
            // Derived from the projects rather than fetched: GitLab's
            // `/groups` lists every group the user belongs to including ones
            // with no projects, and the picker only ever needs the groups
            // that actually own something in the list.
            organizations: Self.groups(in: projects),
            fetchedAt: Date()
        )
    }

    func accessibleProjects(token: String?) async throws -> [AccessibleRepository] {
        guard api.basic != nil || token?.isEmpty == false else { throw GitLabError.noCredential }
        let raw = try await api.getAllPages(
            RawProject.self,
            path: "/projects",
            token: token,
            query: [
                // `membership=true` is the whole point: without it this
                // endpoint returns every public project on the instance,
                // which on a large GitLab is thousands of projects the
                // reviewer has nothing to do with.
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "order_by", value: "last_activity_at"),
                URLQueryItem(name: "sort", value: "desc"),
                // Archived projects are still watchable, but they are not
                // what anyone is looking for; GitLab can leave them out.
                URLQueryItem(name: "archived", value: "false"),
                // The full payload includes `namespace`, which the picker
                // groups by. `simple=true` omits it.
                URLQueryItem(name: "simple", value: "false"),
            ],
            perPage: pageSize,
            maxPages: maxPages
        )
        return raw.map(Self.repository(from:))
    }

    /// A GitLab project as the picker's candidate type.
    ///
    /// The mapping worth naming: `owner.login` is the namespace's **full
    /// path**, not its display name. GitLab groups nest, and the watchlist
    /// addresses a project by `group/subgroup` + name — so the display name
    /// ("Platform Team") would produce a path that does not resolve.
    static func repository(from raw: RawProject) -> AccessibleRepository {
        AccessibleRepository(
            id: raw.id,
            name: raw.name,
            fullName: raw.pathWithNamespace,
            owner: AccessibleRepository.Owner(
                login: raw.namespace.fullPath ?? raw.namespace.name,
                // The picker's grouping reads `isOrganization`, and a GitLab
                // group is the thing that corresponds to a GitHub org.
                type: (raw.namespace.kind ?? "user") == "group" ? "Organization" : "User",
                avatarUrl: raw.namespace.avatarUrl
            ),
            isPrivate: (raw.visibility ?? "private") != "public",
            isFork: raw.forkedFromProject != nil,
            isArchived: raw.archived ?? false,
            description: raw.description,
            updatedAt: raw.lastActivityAt,
            // GitLab reports one activity timestamp, not a separate push
            // time. Filled with the same value rather than left nil, so
            // "recently active" sorting works the same for both forges.
            pushedAt: raw.lastActivityAt,
            openIssuesCount: raw.openIssuesCount,
            defaultBranch: raw.defaultBranch
        )
    }

    /// The groups owning at least one project, most recently active first —
    /// the order the projects already arrived in.
    static func groups(in projects: [AccessibleRepository]) -> [AccessibleRepository.Owner] {
        var seen = Set<String>()
        var ordered: [AccessibleRepository.Owner] = []
        for project in projects where project.owner.isOrganization {
            if seen.insert(project.owner.login).inserted {
                ordered.append(project.owner)
            }
        }
        return ordered
    }
}
