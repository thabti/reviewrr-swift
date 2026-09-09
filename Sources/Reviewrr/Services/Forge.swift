import CryptoKit
import Foundation

/// Which code-review service a host speaks.
///
/// The app's domain models are GitHub-shaped because GitHub came first;
/// GitLab is mapped onto them rather than duplicated (see `GitLabMapper`).
/// This enum is what lets the parts that genuinely differ — API roots, auth
/// headers, pagination, the word for a proposed change — branch in one
/// place instead of leaking `if host.isGitLab` through the UI.
enum Forge: String, Codable, CaseIterable, Sendable, Identifiable {
    case github
    case gitlab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    /// What this forge calls a proposed change, for text a reviewer reads.
    /// Calling a merge request a "pull request" in a GitLab shop is the kind
    /// of small wrongness that makes a tool feel foreign.
    var changeNoun: String {
        switch self {
        case .github: return "pull request"
        case .gitlab: return "merge request"
        }
    }

    var changeNounCapitalized: String {
        switch self {
        case .github: return "Pull Request"
        case .gitlab: return "Merge Request"
        }
    }

    var changeNounAbbreviation: String {
        switch self {
        case .github: return "PR"
        case .gitlab: return "MR"
        }
    }

    /// Where a reviewer creates the credential this forge needs.
    var tokenSettingsPath: String {
        switch self {
        case .github: return "Settings ▸ Developer settings ▸ Personal access tokens"
        case .gitlab: return "Preferences ▸ Access tokens"
        }
    }
}

/// Which install requests go to.
///
/// GitHub.com and GitHub Enterprise Server differ in both the API root
/// (`api.github.com` vs `/api/v3` on the appliance host) and the web root
/// used to build browser links. GitLab adds a third shape: `/api/v4` on the
/// instance host, with GraphQL at `/api/graphql`.
struct ForgeHost: Codable, Equatable, Hashable, Sendable {
    var forge: Forge = .github
    var displayName: String
    var apiBaseURL: URL
    var webBaseURL: URL
    var graphQLURL: URL

    init(forge: Forge = .github, displayName: String, apiBaseURL: URL, webBaseURL: URL, graphQLURL: URL) {
        self.forge = forge
        self.displayName = displayName
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
        self.graphQLURL = graphQLURL
    }

    /// Decoded by hand so a blob written before GitLab support — every
    /// existing `watchlist.json` and settings blob — still decodes, as
    /// GitHub.
    ///
    /// A default value on the property is *not* enough: Swift's synthesized
    /// `init(from:)` still requires the key to be present, so the whole
    /// host, and with it every watched project in the file, would have
    /// failed to decode. That is silent data loss on upgrade, and it is the
    /// reason this initializer is written out.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forge = try container.decodeIfPresent(Forge.self, forKey: .forge) ?? .github
        displayName = try container.decode(String.self, forKey: .displayName)
        apiBaseURL = try container.decode(URL.self, forKey: .apiBaseURL)
        webBaseURL = try container.decode(URL.self, forKey: .webBaseURL)
        graphQLURL = try container.decode(URL.self, forKey: .graphQLURL)
    }

    static let dotCom = ForgeHost(
        forge: .github,
        displayName: "GitHub.com",
        apiBaseURL: URL(string: "https://api.github.com")!,
        webBaseURL: URL(string: "https://github.com")!,
        graphQLURL: URL(string: "https://api.github.com/graphql")!
    )

    /// GitLab's own SaaS instance. Not the default anything — offered
    /// because a reviewer typing "gitlab.com" should not have to know that
    /// it is spelled the same way as a self-hosted instance.
    static let gitLabDotCom = ForgeHost(
        forge: .gitlab,
        displayName: "gitlab.com",
        apiBaseURL: URL(string: "https://gitlab.com/api/v4")!,
        webBaseURL: URL(string: "https://gitlab.com")!,
        graphQLURL: URL(string: "https://gitlab.com/api/graphql")!
    )

    /// Builds a GitHub Enterprise Server host from a bare hostname or a full
    /// URL. Returns nil when the input has no usable host component.
    static func enterprise(_ input: String) -> ForgeHost? {
        guard let web = Self.normalizedBase(input) else { return nil }
        return ForgeHost(
            forge: .github,
            displayName: web.host ?? input,
            apiBaseURL: web.appendingPathComponent("api/v3"),
            webBaseURL: web,
            graphQLURL: web.appendingPathComponent("api/graphql")
        )
    }

    /// Builds a GitLab host — self-managed or gitlab.com — from a bare
    /// hostname or a full URL.
    ///
    /// A path on the input is kept, unlike `enterprise`: GitLab is commonly
    /// installed under a subdirectory of an existing domain
    /// (`https://internal.example.com/gitlab`), and discarding that path
    /// would send every request to a host that has no GitLab on it.
    static func gitlab(_ input: String) -> ForgeHost? {
        guard let base = Self.normalizedBase(input, keepingPath: true) else { return nil }
        let name = base.host.map { host -> String in
            let path = base.path
            return path.isEmpty || path == "/" ? host : host + path
        }
        return ForgeHost(
            forge: .gitlab,
            displayName: name ?? input,
            apiBaseURL: base.appendingPathComponent("api/v4"),
            webBaseURL: base,
            graphQLURL: base.appendingPathComponent("api/graphql")
        )
    }

    /// `https://host[/path]` from a bare hostname or a full URL, with any
    /// trailing slash and (unless asked for) any path removed. Defaults to
    /// HTTPS: a self-hosted instance reached over plain HTTP would send the
    /// credential in clear text, so `http://` has to be asked for
    /// explicitly rather than inferred from a bare hostname.
    private static func normalizedBase(_ input: String, keepingPath: Bool = false) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let url = URL(string: withScheme),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = url.host,
            !host.isEmpty,
            !host.contains(" ")
        else { return nil }

        var base = "\(scheme)://\(host)"
        if let port = url.port { base += ":\(port)" }
        if keepingPath {
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            base += path
        }
        return URL(string: base)
    }

    var isDotCom: Bool { apiBaseURL == ForgeHost.dotCom.apiBaseURL }
    var isGitHub: Bool { forge == .github }
    var isGitLab: Bool { forge == .gitlab }

    /// A stable, filesystem- and Keychain-safe identifier for this host.
    ///
    /// Stable across launches, which is the whole point: the inbox cache
    /// used to name its file from `apiBaseURL.hashValue`, and Swift seeds
    /// `String`'s hash per process — so the name changed on every launch,
    /// the cache never hit, and a file leaked per run. A digest of the API
    /// root cannot drift, and is not reversible into a hostname for anyone
    /// reading a Keychain account name.
    var identityKey: String {
        let digest = SHA256.hash(data: Data(apiBaseURL.absoluteString.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "\(forge.rawValue)-\(hex.prefix(16))"
    }

    /// Web URL for one change on this host, for "Open in browser" links.
    func webURL(owner: String, repo: String, number: Int) -> URL? {
        switch forge {
        case .github:
            return URL(string: "\(webBaseURL.absoluteString)/\(owner)/\(repo)/pull/\(number)")
        case .gitlab:
            // GitLab nests a project under its group path, and the owner
            // field already carries that path (`group/subgroup`).
            return URL(string: "\(webBaseURL.absoluteString)/\(owner)/\(repo)/-/merge_requests/\(number)")
        }
    }
}
