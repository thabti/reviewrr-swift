import AppKit
import Foundation

/// Drives Settings' Account pane: the current GitHub credential and its
/// verification/scope/rate-limit diagnostics, Enterprise host selection, a
/// per-repository access check, and the OAuth device flow.
///
/// Pure state and GitHub calls only — no view code. This type compiles
/// into the unit-test bundle, which excludes `Views/`.
@MainActor
final class AuthModel: ObservableObject {
    enum CredentialState: Equatable {
        case signedOut
        case verifying
        case verified(GitHubCredentialVerification)
        case failed(masked: String, message: String)
    }

    enum RepositoryCheckState: Equatable {
        case idle
        case checking(owner: String, repo: String)
        case succeeded(GitHubRepositoryAccess)
        case failed(owner: String, repo: String, message: String)
    }

    enum HostSwitchState: Equatable {
        case idle
        case validating
        case failed(String)
    }

    /// Named per the workplan's collision-avoidance rule even though it is
    /// already scoped inside `AuthModel` — kept exactly this name since the
    /// integrator and other tracks may refer to it by that name.
    enum DeviceFlowState: Equatable {
        case idle
        case requestingCode
        case awaitingAuthorization(GitHubDeviceCode)
        case succeeded
        case failed(String)
    }

    private let context: AppContext
    private var deviceFlowTask: Task<Void, Never>?

    @Published private(set) var credentialState: CredentialState = .signedOut
    @Published private(set) var rateLimit: GitHubRateLimitSnapshot?
    @Published private(set) var repositoryCheckState: RepositoryCheckState = .idle
    @Published private(set) var hostSwitchState: HostSwitchState = .idle
    @Published private(set) var deviceFlowState: DeviceFlowState = .idle

    /// Bound directly to a Settings text field; persisted to
    /// `AuthPreferences` on every change since there is no explicit "save"
    /// step in the device-flow UI.
    @Published var deviceFlowClientID: String {
        didSet {
            guard deviceFlowClientID != oldValue else { return }
            var prefs = AuthPreferences.load()
            prefs.deviceFlowClientID = deviceFlowClientID
            prefs.save()
        }
    }

    /// The token actually in effect: whatever `save(token:)` or the device
    /// flow most recently wrote this session, falling back to whatever the
    /// integrator's context already had loaded from the Keychain.
    private var activeToken: String?

    init(context: AppContext) {
        self.context = context
        self.deviceFlowClientID = AuthPreferences.load().deviceFlowClientID
        self.activeToken = context.token()
    }

    var currentHost: ForgeHost { context.settings().githubHost }

    /// The OAuth app "Continue with GitHub" signs in as, resolved fresh so
    /// it reflects the client-ID field as it is being typed rather than only
    /// what was saved.
    var oauthApp: GitHubOAuthApp { GitHubOAuthApp.current(userProvided: deviceFlowClientID) }

    var hasDeviceFlowClientID: Bool { oauthApp.isConfigured }

    /// Whether the client-ID field needs to be in front of the reviewer at
    /// all. A build that shipped with an ID (or was launched with one in the
    /// environment) already works, and asking for an OAuth client ID on the
    /// way in is the single most confusing thing a sign-in screen can do.
    var requiresClientIDFromUser: Bool {
        switch oauthApp.source {
        case .bundled, .environment: return false
        case .userProvided, .none: return true
        }
    }

    var maskedActiveToken: String? { activeToken.map(GitHubCredentialMasking.mask) }
    var isSignedIn: Bool { activeToken?.isEmpty == false }

    private var auth: GitHubAuth { GitHubAuth(host: currentHost) }
    private var gitlabClient: GitLabClient { GitLabClient(host: currentHost, basic: basicCredential) }

    /// HTTP Basic for the current host, read through the context so it
    /// always reflects what `AppModel` has.
    var basicCredential: BasicCredential? { context.basic() }

    /// Whether a configured Basic credential is actually sent to this host.
    /// False on a GitHub host that also has a token, because both would
    /// need the `Authorization` header — see `ForgeCredential.headers`.
    var basicIsSent: Bool {
        ForgeCredential(token: activeToken, basic: basicCredential).basicIsSent(for: currentHost.forge)
    }

    /// Saves or clears HTTP Basic for the current host, then re-verifies:
    /// a Basic credential is part of what authenticates a request, so
    /// changing it changes whether the host answers at all.
    func saveBasicCredential(_ credential: BasicCredential?) async {
        context.saveBasic(credential)
        await verify()
    }

    // MARK: - Credential

    func verify() async {
        // A Basic-only setup counts as something to verify: the request can
        // legitimately succeed on a host that authenticates by Basic, and
        // if it cannot, the server's own 401 is the honest answer rather
        // than the app declaring itself signed out.
        guard (activeToken?.isEmpty == false) || basicCredential != nil else {
            credentialState = .signedOut
            rateLimit = nil
            return
        }
        credentialState = .verifying
        let masked = activeToken.map(GitHubCredentialMasking.mask)
            ?? basicCredential?.maskedDescription
            ?? "credential"
        do {
            switch currentHost.forge {
            case .github:
                let verification = try await auth.verifyCredential(activeToken ?? "")
                credentialState = .verified(verification)
                await refreshRateLimit()
            case .gitlab:
                // GitLab reports neither OAuth scopes nor a rate-limit
                // budget in the shapes the GitHub diagnostics read, so the
                // pane shows identity and says the rest is not reported —
                // rather than an empty scope list that reads as "no access".
                let user = try await gitlabClient.verifyToken(activeToken)
                credentialState = .verified(
                    GitHubCredentialVerification(
                        login: user.login,
                        avatarURL: user.avatarUrl,
                        kind: .unrecognized,
                        maskedToken: masked,
                        scopes: nil,
                        scopeSufficiency: .notReported,
                        capabilityNote: Self.gitLabCapabilityNote
                    )
                )
                rateLimit = nil
            }
        } catch {
            credentialState = .failed(masked: masked, message: Self.describe(error))
        }
    }

    static let gitLabCapabilityNote = "GitLab does not report token scopes. A token needs the \"api\" scope to read and review; \"read_api\" can read but cannot post a comment, publish a review, or approve. Use the project access check below to confirm what this token can see."


    private func refreshRateLimit() async {
        guard let token = activeToken else { return }
        do {
            rateLimit = try await auth.fetchRateLimit(token: token)
        } catch {
            // Rate-limit info is a nicety layered on top of a verified
            // credential; a failure fetching it must not blank out an
            // otherwise good verification result.
            rateLimit = nil
        }
    }

    func save(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Storage goes through the context rather than straight to the
        // Keychain: `AppModel` is the one place that records *how* a save
        // went, so a refusal shows up as an explained state in the Account
        // pane instead of a discarded `Bool`.
        activeToken = trimmed
        context.saveToken(trimmed)
        await verify()
    }

    /// Removes the credential from the Keychain. This only forgets it
    /// locally — it does not revoke the token on GitHub, so a leaked or
    /// shared token still needs revoking from github.com/settings/tokens.
    func signOut() {
        cancelDeviceFlow()
        activeToken = nil
        context.forgetToken()
        credentialState = .signedOut
        rateLimit = nil
        repositoryCheckState = .idle
        refreshHostAccounts()
    }

    // MARK: - Hosts as accounts

    /// Every host and what it has to sign in with, for the Account pane.
    ///
    /// Published rather than derived in a view body, because building it
    /// reads the Keychain once per host: at `body` rate that is a Keychain
    /// call per host per frame, and on a build whose signature macOS does not
    /// recognise it is an authorisation panel per host per frame.
    @Published private(set) var hostAccounts: [HostAccount] = []

    /// Re-reads every host's credential. Called after anything that could
    /// change one — a save, a sign-out, a host switch — and once when the
    /// pane appears.
    func refreshHostAccounts() {
        let settings = context.settings()
        hostAccounts = HostAccount.all(
            active: settings.githubHost,
            known: settings.knownHosts
        ) { host in
            let credential = ForgeCredentialStore.read(host: host).credential
            return (credential.token, credential.basic)
        }
    }

    /// Switches to a host Reviewrr already knows, without asking for its URL
    /// again.
    ///
    /// The whole reason the Account pane can list hosts at all: a known host
    /// has its credential in the Keychain, so adopting it is just re-reading
    /// that and verifying. Adding a *new* host still goes through
    /// `useEnterpriseHost`/`useGitLabHost`, which have to parse and validate
    /// what was typed.
    func use(host: ForgeHost) {
        guard host.identityKey != currentHost.identityKey else { return }
        switchTo(host)
        refreshHostAccounts()
    }

    /// Forgets one host's credential, whether or not it is the active host.
    ///
    /// Local only, like `signOut()` — nothing is revoked server-side.
    func signOut(host: ForgeHost) {
        guard host.identityKey != currentHost.identityKey else {
            signOut()
            return
        }
        ForgeCredentialStore.deleteAll(host: host)
        refreshHostAccounts()
    }

    /// Removes a host from Reviewrr entirely: its credential and its place in
    /// the known-hosts list.
    ///
    /// Removing the host currently in use falls back to GitHub.com rather
    /// than leaving the app pointed at a host it no longer knows — which
    /// would make every request fail with nothing on screen to explain it.
    /// GitHub.com itself is never removable; signing out of it is.
    func forget(host: ForgeHost) {
        guard !host.isDotCom else {
            signOut(host: host)
            return
        }
        ForgeCredentialStore.deleteAll(host: host)
        var settings = context.settings()
        settings.knownHosts.removeAll { $0.identityKey == host.identityKey }
        context.updateSettings(settings)
        if host.identityKey == currentHost.identityKey {
            switchTo(.dotCom)
        }
        refreshHostAccounts()
    }

    // MARK: - Repository access

    func checkRepositoryAccess(owner: String, repo: String) async {
        let owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repo.isEmpty else { return }
        repositoryCheckState = .checking(owner: owner, repo: repo)
        do {
            let access: GitHubRepositoryAccess
            switch currentHost.forge {
            case .github:
                access = try await auth.checkRepositoryAccess(owner: owner, repo: repo, token: activeToken)
            case .gitlab:
                access = try await gitlabClient.checkProjectAccess(owner: owner, repo: repo, token: activeToken)
            }
            repositoryCheckState = .succeeded(access)
        } catch {
            repositoryCheckState = .failed(owner: owner, repo: repo, message: Self.describe(error))
        }
    }

    // MARK: - Enterprise host

    /// Parses `input` into a host, verifies the current token against it,
    /// and only persists on success — a typo or an unreachable appliance
    /// must never silently strand the reviewer on a host that can't work.
    func useEnterpriseHost(_ input: String) async {
        guard let candidate = ForgeHost.enterprise(input) else {
            hostSwitchState = .failed("That doesn't look like a valid host or URL.")
            return
        }
        guard let token = activeToken, !token.isEmpty else {
            hostSwitchState = .failed("Add a GitHub token for this host before switching — a saved credential is host-specific and won't carry over.")
            return
        }
        hostSwitchState = .validating
        do {
            let verification = try await GitHubAuth.verify(host: candidate, token: token)
            var settings = context.settings()
            settings.githubHost = candidate
            context.updateSettings(settings)
            hostSwitchState = .idle
            credentialState = .verified(verification)
            await refreshRateLimit()
            // The token just verified against this host is the one to keep
            // using, so it is stored for it rather than left belonging to
            // the host the reviewer switched away from.
            context.saveToken(token)
        } catch {
            hostSwitchState = .failed(Self.describe(error))
        }
    }

    func useDotComHost() {
        switchTo(.dotCom)
    }

    /// Parses `input` as a GitLab instance, verifies whatever credential is
    /// saved *for that host* against it, and persists only on success.
    ///
    /// Unlike the Enterprise path this does not demand a token up front: a
    /// GitLab host may already have one saved from a previous session, and
    /// an instance behind Basic auth may authenticate with Basic alone. The
    /// verification call decides, not a guess made beforehand.
    func useGitLabHost(_ input: String) async {
        guard let candidate = ForgeHost.gitlab(input) else {
            hostSwitchState = .failed("That doesn't look like a valid host or URL.")
            return
        }
        hostSwitchState = .validating
        let saved = ForgeCredentialStore.read(host: candidate).credential
        guard !saved.isEmpty else {
            // Nothing saved for this host yet, so there is nothing to verify
            // against it. The host is still adopted: the reviewer's next
            // step is to paste a token, and refusing to switch would leave
            // them nowhere to paste it.
            switchTo(candidate)
            hostSwitchState = .failed(
                "Switched to \(candidate.displayName). Add a GitLab access token below — a credential is host-specific and does not carry over."
            )
            return
        }
        do {
            _ = try await GitLabClient(host: candidate, basic: saved.basic).verifyToken(saved.token)
            switchTo(candidate)
        } catch {
            hostSwitchState = .failed(Self.describe(error))
        }
    }

    /// Adopts `host` and re-reads the credential saved for it.
    ///
    /// The re-read is the point: a credential belongs to a host, so keeping
    /// the previous host's token in memory after a switch would send it to
    /// the new host and produce a 401 the reviewer cannot explain.
    private func switchTo(_ host: ForgeHost) {
        var settings = context.settings()
        settings.githubHost = host
        // Remembered so the watch-a-project picker can browse this host
        // later without the whole app having to be switched to it again.
        if !settings.knownHosts.contains(where: { $0.identityKey == host.identityKey }) {
            settings.knownHosts.append(host)
        }
        context.updateSettings(settings)
        context.reloadCredential()
        activeToken = context.token()
        hostSwitchState = .idle
        repositoryCheckState = .idle
        cancelDeviceFlow()
        refreshHostAccounts()
        Task { await verify() }
    }

    // MARK: - OAuth device flow

    /// Requests a device code and returns as soon as it has one (so the UI
    /// can show `user_code` immediately), then keeps polling in the
    /// background via `deviceFlowTask` until it succeeds, fails, expires,
    /// or `cancelDeviceFlow()` is called.
    func startDeviceFlow() async {
        let clientID = oauthApp.clientID
        guard !clientID.isEmpty else {
            deviceFlowState = .failed(Self.missingClientIDMessage)
            return
        }
        deviceFlowTask?.cancel()
        deviceFlowState = .requestingCode
        do {
            let code = try await auth.requestDeviceCode(clientID: clientID)
            deviceFlowState = .awaitingAuthorization(code)
            deviceFlowTask = Task { [weak self] in
                await self?.pollDeviceFlow(clientID: clientID, code: code)
            }
        } catch {
            deviceFlowState = .failed(Self.describe(error))
        }
    }

    func cancelDeviceFlow() {
        deviceFlowTask?.cancel()
        deviceFlowTask = nil
        deviceFlowState = .idle
    }

    private func pollDeviceFlow(clientID: String, code: GitHubDeviceCode) async {
        var interval = code.interval
        while !Task.isCancelled {
            if Date() >= code.expiresAt {
                deviceFlowState = .failed(GitHubDeviceFlowErrorCode.expiredToken.message)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            if Task.isCancelled { return }
            do {
                let result = try await auth.pollDeviceToken(clientID: clientID, deviceCode: code.deviceCode)
                switch result {
                case .pending:
                    continue
                case .success(let token):
                    // `context.saveToken` both stores and publishes. It used
                    // to be a bare Keychain write here, which meant a
                    // successful device sign-in reached the Account pane and
                    // nothing else: the dashboard and inbox stayed signed
                    // out until the app was relaunched.
                    activeToken = token
                    context.saveToken(token)
                    deviceFlowState = .succeeded
                    await verify()
                    return
                case .failed(let errorCode, let detail):
                    if errorCode == .slowDown {
                        interval += 5
                        continue
                    }
                    deviceFlowState = .failed(detail ?? errorCode.message)
                    return
                }
            } catch {
                if error is CancellationError { return }
                deviceFlowState = .failed(Self.describe(error))
                return
            }
        }
    }

    // MARK: - Client ID guidance

    /// What to say when sign-in is asked for and there is no client ID.
    ///
    /// Says what to do rather than what is missing: "no OAuth client ID" is
    /// not a sentence a reviewer can act on, and the personal-access-token
    /// route on the same screen works right now.
    static let missingClientIDMessage = """
        This build ships without a GitHub OAuth client ID, so it cannot start browser sign-in. \
        Either paste a personal access token below, or create a GitHub OAuth App with device flow \
        enabled and paste its client ID — the client ID is public, and no client secret is needed.
        """

    /// Where the client ID in effect came from, for the Account pane. `nil`
    /// when the reviewer typed it in themselves — the field they typed into
    /// is right there, so restating it adds nothing.
    var clientIDProvenance: String? {
        switch oauthApp.source {
        case .bundled:
            return "Using the OAuth client ID this build shipped with."
        case .environment:
            return "Using the OAuth client ID in $\(GitHubOAuthApp.environmentVariable), which overrides the one this build shipped with."
        case .userProvided, .none:
            return nil
        }
    }

    // MARK: - Helpers

    /// Prefers `LocalizedError.errorDescription` explicitly so a
    /// `GitHubError`'s specific, diagnosable message always reaches the UI
    /// rather than a generic NSError-bridged fallback string.
    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func openVerificationURI(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
