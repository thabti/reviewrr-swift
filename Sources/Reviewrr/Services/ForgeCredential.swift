import Foundation

/// A username and password sent as HTTP Basic on every request to a host.
///
/// This exists for instances that sit behind Basic auth. Note what it is
/// *not*: GitLab's own `/api/v4` does not accept `Authorization: Basic` —
/// Basic works for Git-over-HTTP and the container registry, not the REST
/// API. So Basic alone cannot authenticate an API call to a stock GitLab;
/// it gets a request *through* a Basic-protected front door, and the token
/// in `ForgeCredential.token` is what GitLab itself authenticates.
///
/// Reviewrr sends whichever of the two are configured and reports what came
/// back, rather than deciding for the operator which one their instance
/// wants. An instance patched to accept Basic on the API will work with
/// Basic alone; a stock one needs the token, and says so on a 401.
struct BasicCredential: Codable, Equatable, Sendable {
    var username: String
    var password: String

    var isEmpty: Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && password.isEmpty
    }

    /// The header value, `Basic base64(user:password)` per RFC 7617.
    ///
    /// Encoded as UTF-8. RFC 7617 leaves the charset to the server and
    /// recommends UTF-8; a password with non-ASCII characters otherwise has
    /// no defined encoding at all, and silently failing to authenticate is
    /// worse than sending the standard's recommendation.
    var headerValue: String {
        let joined = "\(username):\(password)"
        return "Basic \(Data(joined.utf8).base64EncodedString())"
    }

    /// For display. The username is not a secret and identifies which
    /// account is in use; the password never appears.
    var maskedDescription: String {
        let name = username.isEmpty ? "(no username)" : username
        return "\(name) : ••••"
    }
}

/// Everything needed to authenticate to one host.
///
/// Both parts are optional and independent. A GitHub.com reviewer has a
/// token and no Basic credential; a locked-down self-hosted instance may
/// need both; a misconfigured setup may have neither, and that is reported
/// as "no credential" rather than as a mysterious 401.
struct ForgeCredential: Equatable, Sendable {
    var token: String?
    var basic: BasicCredential?

    static let none = ForgeCredential(token: nil, basic: nil)

    init(token: String? = nil, basic: BasicCredential? = nil) {
        self.token = Self.normalize(token)
        self.basic = basic?.isEmpty == true ? nil : basic
    }

    var hasToken: Bool { token?.isEmpty == false }
    var hasBasic: Bool { basic != nil }
    /// Whether there is anything at all to send. A request with neither is
    /// still attempted for public resources, but "signed in" means this.
    var isEmpty: Bool { !hasToken && !hasBasic }

    private static func normalize(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension ForgeCredential {
    /// The auth headers to set on a request to `forge`.
    ///
    /// ## Why GitLab can carry both and GitHub cannot
    ///
    /// GitLab authenticates a personal access token through its own
    /// `PRIVATE-TOKEN` header, which leaves `Authorization` free for Basic.
    /// Both parts therefore travel on the same request: Basic gets through
    /// the front door, `PRIVATE-TOKEN` identifies the user to GitLab.
    ///
    /// GitHub has no such header — a token goes in `Authorization: Bearer`,
    /// which is the one header Basic also needs. They cannot coexist, and
    /// HTTP offers no second `Authorization`. When a GitHub host has both,
    /// the token wins: it is the credential GitHub itself checks, and
    /// dropping it to satisfy a proxy would fail authentication at the
    /// server instead of at the proxy. (GitHub removed Basic auth for its
    /// API in 2020, so there is no combined `user:token` form left either.)
    /// The Account pane says this rather than leaving it to be discovered.
    func headers(for forge: Forge) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        switch forge {
        case .gitlab:
            if let token, !token.isEmpty {
                headers.append((name: "PRIVATE-TOKEN", value: token))
            }
            if let basic {
                headers.append((name: "Authorization", value: basic.headerValue))
            }
        case .github:
            if let token, !token.isEmpty {
                headers.append((name: "Authorization", value: "Bearer \(token)"))
            } else if let basic {
                headers.append((name: "Authorization", value: basic.headerValue))
            }
        }
        return headers
    }

    /// Whether a Basic credential configured for this host will actually be
    /// sent, so the UI can warn instead of pretending. False only for a
    /// GitHub host that also has a token — see `headers(for:)`.
    func basicIsSent(for forge: Forge) -> Bool {
        guard hasBasic else { return false }
        switch forge {
        case .gitlab: return true
        case .github: return !hasToken
        }
    }
}

/// Where each host's credential parts live in the Keychain.
///
/// Per host, so a GitHub.com token, an Enterprise token, and a self-hosted
/// GitLab token coexist — a credential is host-specific and always was;
/// before this there was simply nowhere to put the second one.
enum ForgeCredentialStore {
    /// The account name the app has always used for github.com's token.
    /// Kept as-is so an existing install stays signed in: a rename here
    /// would look exactly like being silently signed out.
    static let legacyGitHubTokenAccount = "github-token"

    static func tokenAccount(for host: ForgeHost) -> String {
        host.isDotCom ? legacyGitHubTokenAccount : "token.\(host.identityKey)"
    }

    static func basicAccount(for host: ForgeHost) -> String {
        "basic.\(host.identityKey)"
    }

    // MARK: - Reading

    /// Reads a host's credential. A Keychain refusal is reported by
    /// `readToken` rather than swallowed here, so the caller can tell
    /// "nothing saved" from "this build was refused" — the distinction the
    /// rest of the app is built around.
    static func read(host: ForgeHost) -> (credential: ForgeCredential, tokenRead: KeychainReadResult) {
        let tokenRead = KeychainStore.read(account: tokenAccount(for: host))
        let token: String? = if case .value(let value) = tokenRead { value } else { nil }
        return (ForgeCredential(token: token, basic: readBasic(host: host)), tokenRead)
    }

    static func readBasic(host: ForgeHost) -> BasicCredential? {
        guard
            let raw = KeychainStore.load(account: basicAccount(for: host)),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(BasicCredential.self, from: data),
            !decoded.isEmpty
        else { return nil }
        return decoded
    }

    // MARK: - Writing

    static func writeToken(_ token: String, host: ForgeHost) -> KeychainWriteResult {
        KeychainStore.write(token, account: tokenAccount(for: host))
    }

    /// Stored as JSON in a single Keychain item rather than two items: the
    /// pair is only ever meaningful together, and a half-written credential
    /// (username saved, password refused) would authenticate as nobody.
    static func writeBasic(_ credential: BasicCredential, host: ForgeHost) -> KeychainWriteResult {
        guard
            let data = try? JSONEncoder().encode(credential),
            let json = String(data: data, encoding: .utf8)
        else { return .failed(errSecParam) }
        return KeychainStore.write(json, account: basicAccount(for: host))
    }

    static func deleteToken(host: ForgeHost) {
        KeychainStore.delete(account: tokenAccount(for: host))
    }

    static func deleteBasic(host: ForgeHost) {
        KeychainStore.delete(account: basicAccount(for: host))
    }

    static func deleteAll(host: ForgeHost) {
        deleteToken(host: host)
        deleteBasic(host: host)
    }
}
