import Foundation

// MARK: - Token kind

/// Which flavor of GitHub credential a raw token string is, detected
/// entirely from its prefix (GitHub's convention since the 2021 token
/// format change). Knowing the kind up front — before any network call —
/// tells us whether to expect an `X-OAuth-Scopes` header at all: its
/// absence means "not applicable", not "broken".
enum GitHubTokenKind: Equatable, CustomStringConvertible {
    case classicPAT
    case fineGrainedPAT
    case oauthToken
    case appUserToServer
    case appInstallation
    case refreshToken
    /// Pre-2021 40-character hex tokens. GitHub still accepts these; they
    /// behave exactly like a classic PAT (scopes reported via header).
    case legacyClassic
    case unrecognized

    /// Longest/most specific prefix first purely so a future addition to
    /// this table can't accidentally shadow an existing one.
    private static let prefixOrder: [(prefix: String, kind: GitHubTokenKind)] = [
        ("github_pat_", .fineGrainedPAT),
        ("ghp_", .classicPAT),
        ("gho_", .oauthToken),
        ("ghu_", .appUserToServer),
        ("ghs_", .appInstallation),
        ("ghr_", .refreshToken),
    ]

    static func detect(_ token: String) -> GitHubTokenKind {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in prefixOrder where trimmed.hasPrefix(entry.prefix) {
            return entry.kind
        }
        if trimmed.count == 40, trimmed.allSatisfy(\.isHexDigit) {
            return .legacyClassic
        }
        return .unrecognized
    }

    var label: String {
        switch self {
        case .classicPAT: return "Classic personal access token"
        case .fineGrainedPAT: return "Fine-grained personal access token"
        case .oauthToken: return "OAuth token"
        case .appUserToServer: return "GitHub App token (user-to-server)"
        case .appInstallation: return "GitHub App installation token"
        case .refreshToken: return "OAuth refresh token"
        case .legacyClassic: return "Classic (legacy format)"
        case .unrecognized: return "Unrecognized credential"
        }
    }

    var description: String { label }

    /// Classic PATs and OAuth tokens (including their legacy 40-hex form)
    /// send `X-OAuth-Scopes` on every authenticated response. Fine-grained
    /// PATs and every GitHub App token kind send nothing — that is expected
    /// behavior, not a sign the token is broken, and callers must not treat
    /// a missing header from these kinds as an error.
    var reportsScopesViaHeader: Bool {
        switch self {
        case .classicPAT, .oauthToken, .legacyClassic: return true
        case .fineGrainedPAT, .appUserToServer, .appInstallation, .refreshToken, .unrecognized: return false
        }
    }

    /// The literal prefix GitHub put on this token, for masked display.
    /// Legacy and unrecognized tokens have none.
    var displayPrefix: String? {
        Self.prefixOrder.first { $0.kind == self }?.prefix
    }
}

// MARK: - Masking

enum GitHubCredentialMasking {
    /// Renders a token as `<prefix>••••<last 4>` (e.g. `ghp_••••1a2b`), or
    /// `••••<last 4>` when there is no recognized prefix — enough to tell
    /// two saved tokens apart without ever displaying the secret itself.
    /// Callers must use this (or an equally masked form) anywhere a token
    /// might be shown; the raw value must never be logged or echoed.
    static func mask(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "••••" }
        let suffix = trimmed.suffix(4)
        if let prefix = GitHubTokenKind.detect(trimmed).displayPrefix {
            return "\(prefix)••••\(suffix)"
        }
        return "••••\(suffix)"
    }
}

// MARK: - Scope sufficiency

/// What Reviewrr needs from a classic/OAuth token's granted scopes: enough
/// repository access to read diffs and post reviews, plus `read:org` so
/// organization-owned repository visibility resolves correctly.
enum GitHubScopeSufficiency: Equatable {
    /// Fine-grained PATs and GitHub App tokens never report scopes; the
    /// repository access check is the way to answer "can this see X" for
    /// these kinds. Deliberately not lumped in with `.sufficient` — the UI
    /// needs to tell "verified fine" apart from "can't tell from here".
    case notReported
    case sufficient
    case missingOrgRead
    case missingRepoAccess
    case missingBoth

    var summary: String {
        switch self {
        case .notReported:
            return "This token type doesn't report scopes. Use the repository access check below to confirm what it can see."
        case .sufficient:
            return "Scopes cover repository access and organization visibility."
        case .missingOrgRead:
            return "Has repository access but not \"read:org\" — organization-owned repositories may not resolve correctly."
        case .missingRepoAccess:
            return "Missing \"repo\" (or \"public_repo\") — Reviewrr cannot read or review pull requests with this token."
        case .missingBoth:
            return "Missing \"repo\" and \"read:org\" — this token cannot read pull requests or resolve organization repositories."
        }
    }

    /// Whether this state deserves a warning-colored badge in the UI.
    var needsAttention: Bool {
        switch self {
        case .sufficient, .notReported: return false
        case .missingOrgRead, .missingRepoAccess, .missingBoth: return true
        }
    }
}

enum GitHubScopeEvaluator {
    static let repoScope = "repo"
    static let publicRepoScope = "public_repo"
    static let orgReadScope = "read:org"

    static func evaluate(scopes: [String]?, kind: GitHubTokenKind) -> GitHubScopeSufficiency {
        guard kind.reportsScopesViaHeader else { return .notReported }
        let granted = Set(scopes ?? [])
        let hasRepo = granted.contains(repoScope) || granted.contains(publicRepoScope)
        let hasOrg = granted.contains(orgReadScope)
        switch (hasRepo, hasOrg) {
        case (true, true): return .sufficient
        case (true, false): return .missingOrgRead
        case (false, true): return .missingRepoAccess
        case (false, false): return .missingBoth
        }
    }
}

// MARK: - Verification results

struct GitHubCredentialVerification: Equatable {
    var login: String
    var avatarURL: String?
    var kind: GitHubTokenKind
    var maskedToken: String
    /// nil exactly when `kind.reportsScopesViaHeader` is false — not an
    /// error, just a kind that doesn't expose scopes this way.
    var scopes: [String]?
    var scopeSufficiency: GitHubScopeSufficiency
    /// Set only for kinds that don't report scopes: explains what to check
    /// instead of leaving a blank space where a scope list would be.
    var capabilityNote: String?
}

struct GitHubRateLimitSnapshot: Equatable {
    struct Budget: Equatable {
        var limit: Int
        var remaining: Int
        var resetAt: Date
    }
    var core: Budget
    var search: Budget
}

struct GitHubRepositoryAccess: Equatable {
    var owner: String
    var repo: String
    var fullName: String
    var isPrivate: Bool
}

// MARK: - Device flow

/// A device-flow authorization in progress: the code the user types on
/// GitHub, and everything the polling loop needs to keep going correctly.
struct GitHubDeviceCode: Equatable {
    var deviceCode: String
    var userCode: String
    var verificationURI: String
    var verificationURIComplete: String?
    var expiresAt: Date
    var interval: Int
}

/// RFC 8628 / GitHub's own error vocabulary for the device-flow token
/// endpoint. `authorization_pending` and `slow_down` mean "keep polling";
/// everything else is terminal and needs to reach the reviewer as text.
enum GitHubDeviceFlowErrorCode: String, Decodable, Equatable {
    case authorizationPending = "authorization_pending"
    case slowDown = "slow_down"
    case expiredToken = "expired_token"
    case accessDenied = "access_denied"
    case incorrectClientCredentials = "incorrect_client_credentials"
    case incorrectDeviceCode = "incorrect_device_code"
    case unsupportedGrantType = "unsupported_grant_type"
    case deviceFlowDisabled = "device_flow_disabled"

    var message: String {
        switch self {
        case .authorizationPending: return "Waiting for approval on GitHub."
        case .slowDown: return "Polling too fast; backing off."
        case .expiredToken: return "The device code expired before it was approved. Start over."
        case .accessDenied: return "Authorization was denied on GitHub."
        case .incorrectClientCredentials: return "The configured OAuth client ID is invalid."
        case .incorrectDeviceCode: return "The device code is invalid or was already used."
        case .unsupportedGrantType: return "GitHub rejected this OAuth grant type."
        case .deviceFlowDisabled: return "This OAuth app has device flow disabled."
        }
    }
}

enum GitHubDeviceTokenResult: Equatable {
    case pending(retryIntervalOverride: Int?)
    case success(token: String)
    case failed(GitHubDeviceFlowErrorCode, detail: String?)
}

private struct DeviceCodeResponseBody: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct DeviceTokenResponseBody: Decodable {
    let accessToken: String?
    let error: GitHubDeviceFlowErrorCode?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Reviewrr's own auth preferences

/// Small preferences separate from `AppSettings` (owned by another track,
/// additive-only): currently just the reviewer-supplied OAuth client ID
/// the device flow needs, since Reviewrr ships with none of its own.
struct AuthPreferences: Codable, Equatable {
    var deviceFlowClientID: String = ""

    private static let defaultsKey = "reviewrr.auth"

    static func load() -> AuthPreferences {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AuthPreferences.self, from: data)
        else {
            return AuthPreferences()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - GitHubAuth

/// Everything Settings' Account pane needs beyond the single-PR endpoints
/// in `GitHubClient`: credential diagnostics (`/user`, `/rate_limit`), a
/// per-repository access probe, and the OAuth device flow. Kept separate
/// from `GitHubClient` because it talks to account- and OAuth-level
/// endpoints rather than PR data, and none of it should know about diffs.
///
/// Stateless with respect to auth, like `GitHubClient`: every call takes
/// the token and host it should use.
struct GitHubAuth {
    var api: GitHubAPI

    init(host: ForgeHost = .dotCom) { self.api = GitHubAPI(host: host) }
    init(api: GitHubAPI) { self.api = api }

    var host: ForgeHost { api.host }

    // MARK: Verification

    func verifyCredential(_ token: String) async throws -> GitHubCredentialVerification {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitHubError.noToken }
        let kind = GitHubTokenKind.detect(trimmed)
        let response = try await api.getResponse(GitHubUser.self, path: "/user", token: trimmed)
        let scopes = response.oauthScopes
        return GitHubCredentialVerification(
            login: response.value.login,
            avatarURL: response.value.avatarUrl,
            kind: kind,
            maskedToken: GitHubCredentialMasking.mask(trimmed),
            scopes: scopes,
            scopeSufficiency: GitHubScopeEvaluator.evaluate(scopes: scopes, kind: kind),
            capabilityNote: Self.capabilityNote(for: kind)
        )
    }

    /// Verifies `token` against a specific host without touching the
    /// currently configured one — used to validate an Enterprise Server
    /// candidate host before it is saved.
    static func verify(host: ForgeHost, token: String) async throws -> GitHubCredentialVerification {
        try await GitHubAuth(host: host).verifyCredential(token)
    }

    static func capabilityNote(for kind: GitHubTokenKind) -> String? {
        guard !kind.reportsScopesViaHeader else { return nil }
        return "\(kind.label) tokens don't report scopes. Use the repository access check below to confirm this token can see a specific repo — submitting a review additionally needs the token's \"Pull requests: read and write\" permission."
    }

    func fetchRateLimit(token: String?) async throws -> GitHubRateLimitSnapshot {
        struct Resource: Decodable { let limit: Int; let remaining: Int; let reset: Double }
        struct Resources: Decodable { let core: Resource; let search: Resource }
        struct Envelope: Decodable { let resources: Resources }
        let envelope = try await api.get(Envelope.self, path: "/rate_limit", token: token)
        func budget(_ resource: Resource) -> GitHubRateLimitSnapshot.Budget {
            GitHubRateLimitSnapshot.Budget(
                limit: resource.limit, remaining: resource.remaining,
                resetAt: Date(timeIntervalSince1970: resource.reset)
            )
        }
        return GitHubRateLimitSnapshot(core: budget(envelope.resources.core), search: budget(envelope.resources.search))
    }

    func checkRepositoryAccess(owner: String, repo: String, token: String?) async throws -> GitHubRepositoryAccess {
        struct Probe: Decodable {
            let isPrivate: Bool
            let fullName: String
            enum CodingKeys: String, CodingKey {
                case isPrivate = "private"
                case fullName = "full_name"
            }
        }
        let probe = try await api.get(Probe.self, path: "/repos/\(owner)/\(repo)", token: token)
        return GitHubRepositoryAccess(owner: owner, repo: repo, fullName: probe.fullName, isPrivate: probe.isPrivate)
    }

    // MARK: Device flow

    /// `repo` covers reading diffs and submitting reviews; `read:org`
    /// resolves organization-owned repository visibility — the same bar
    /// `GitHubScopeEvaluator` holds a classic/OAuth PAT to.
    static let defaultDeviceFlowScope = "repo read:org"

    func requestDeviceCode(clientID: String, scope: String = defaultDeviceFlowScope) async throws -> GitHubDeviceCode {
        let request = makeDeviceRequest(path: "login/device/code", params: [
            ("client_id", clientID),
            ("scope", scope),
        ])
        let (data, _) = try await api.send(request)
        return try Self.parseDeviceCode(from: data)
    }

    func pollDeviceToken(clientID: String, deviceCode: String) async throws -> GitHubDeviceTokenResult {
        let request = makeDeviceRequest(path: "login/oauth/access_token", params: [
            ("client_id", clientID),
            ("device_code", deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        let (data, _) = try await api.send(request)
        return try Self.parseDeviceTokenResponse(from: data)
    }

    /// Pure parsing, split out from the networking calls above so it can be
    /// exercised in tests against fixture JSON with no network involved.
    static func parseDeviceCode(from data: Data) throws -> GitHubDeviceCode {
        let body = try GitHubAPI.decode(DeviceCodeResponseBody.self, from: data, status: 200)
        return GitHubDeviceCode(
            deviceCode: body.deviceCode,
            userCode: body.userCode,
            verificationURI: body.verificationUri,
            verificationURIComplete: body.verificationUriComplete,
            expiresAt: Date().addingTimeInterval(TimeInterval(body.expiresIn)),
            interval: max(body.interval, 5)
        )
    }

    static func parseDeviceTokenResponse(from data: Data) throws -> GitHubDeviceTokenResult {
        let body = try GitHubAPI.decode(DeviceTokenResponseBody.self, from: data, status: 200)
        if let token = body.accessToken, !token.isEmpty {
            return .success(token: token)
        }
        guard let error = body.error else {
            throw GitHubError.decoding("Unexpected response from GitHub's device flow token endpoint.")
        }
        switch error {
        case .authorizationPending, .slowDown:
            return .pending(retryIntervalOverride: nil)
        default:
            return .failed(error, detail: body.errorDescription)
        }
    }

    private func makeDeviceRequest(path: String, params: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: host.webBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Reviewrr-Mac", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncode(params)
        return request
    }

    /// A minimal, correct `application/x-www-form-urlencoded` encoder for
    /// the handful of ASCII, colon-and-underscore-bearing values the device
    /// flow sends — not a general-purpose one.
    private static func formEncode(_ params: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return pairs.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}
