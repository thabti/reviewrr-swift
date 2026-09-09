import Foundation

/// The dashboard's view of a forge: what a watched project's rows are, and
/// whether a project exists at all.
///
/// Both `InboxService` (GitHub) and `GitLabInboxService` conform. The point
/// is not polymorphism for its own sake — it is that `DashboardModel` had
/// three `switch host.forge` statements in it, one per call, each
/// constructing a different service with different arguments. A third forge
/// would have meant a fourth arm in each of them, and the odds of adding
/// one arm and forgetting another grow with every call site.
protocol ForgeInboxProviding: Sendable {
    /// Throws when the credential cannot see `owner/repo`, so a watchlist
    /// entry is never saved for something that will never load.
    func validateRepository(owner: String, repo: String, token: String?) async throws

    /// Every open and recently closed change in one watched project.
    func fetchProject(_ project: WatchedProject, token: String?) async throws -> [InboxPR]

    /// The cross-project buckets — needs review, assigned, authored,
    /// participated. A forge with no equivalent for one of them returns it
    /// empty rather than approximating it.
    func fetchReviewerBuckets(token: String?) async throws -> [InboxReviewerBucket: [InboxPR]]
}

/// The watch-a-project picker's view of a forge: what this credential can
/// see, as candidates to watch.
protocol ForgeDirectoryProviding: Sendable {
    func snapshot(token: String?) async throws -> RepositoryCacheStore.Snapshot
}

extension InboxService: ForgeInboxProviding {}
extension GitLabInboxService: ForgeInboxProviding {}
extension RepositoryDirectory: ForgeDirectoryProviding {}
extension GitLabProjectDirectory: ForgeDirectoryProviding {}

/// Builds the right service for a host.
///
/// One place that knows which implementation belongs to which forge. Every
/// caller asks for a capability and a host and gets something that can do
/// the job — so adding a forge means conforming two types and extending two
/// switches *here*, not auditing every model that talks to a server.
enum ForgeServices {
    static func inbox(host: ForgeHost, basic: BasicCredential?) -> any ForgeInboxProviding {
        switch host.forge {
        case .github:
            return InboxService(api: GitHubAPI(host: host, basic: basic))
        case .gitlab:
            return GitLabInboxService(api: GitLabAPI(host: host, basic: basic))
        }
    }

    static func directory(host: ForgeHost, basic: BasicCredential?) -> any ForgeDirectoryProviding {
        switch host.forge {
        case .github:
            return RepositoryDirectory(api: GitHubAPI(host: host, basic: basic))
        case .gitlab:
            return GitLabProjectDirectory(api: GitLabAPI(host: host, basic: basic))
        }
    }

    static func client(host: ForgeHost, basic: BasicCredential?) -> ForgeClient {
        ForgeClient(host: host, basic: basic)
    }
}

/// A credential resolved for a specific host.
///
/// Multi-host review needs this shape: "the token" stops being a single
/// value the moment a reviewer watches a GitHub repository and a GitLab
/// project at the same time. Every call that used to read `context.token()`
/// and hope it matched the host it was talking to now asks for the
/// credential *of that host*.
struct HostCredential: Equatable, Sendable {
    var host: ForgeHost
    var credential: ForgeCredential

    var token: String? { credential.token }
    var basic: BasicCredential? { credential.basic }

    /// Whether this host has anything to authenticate with. A host with no
    /// credential is skipped rather than fetched and failed — a 401 per
    /// project per poll is noise, not information.
    var isUsable: Bool { !credential.isEmpty }
}
