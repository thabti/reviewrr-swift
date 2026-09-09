import Foundation

/// The slice of app-wide state a feature model needs, handed over as
/// closures rather than a reference to `AppModel`.
///
/// Two reasons: values resolve at call time, so a token, host, or settings
/// change is picked up without re-wiring anything; and a feature model can
/// be constructed in a test or preview with `.stub` instead of standing up
/// the whole app.
@MainActor
struct AppContext {
    /// A configured transport for the currently selected GitHub host.
    /// Deliberately called fresh per use (see the type doc above): the
    /// returned `GitHubAPI` value is cheap to construct because its
    /// `URLSession` is a shared-per-host instance under the hood, not a
    /// freshly opened connection pool.
    var api: () -> GitHubAPI
    /// The current GitHub token, or nil when signed out.
    var token: () -> String?
    /// Stores a newly obtained token *and* publishes it app-wide: the
    /// Keychain is the store of record, and every already-constructed
    /// feature model picks it up in the same session rather than only after
    /// a relaunch.
    ///
    /// Both halves belong in one closure on purpose. When they were
    /// separate, the device flow wrote the Keychain itself and forgot to
    /// publish — sign-in succeeded, the Account pane said so, and the
    /// dashboard stayed signed out until the app was relaunched. Keeping
    /// storage in `AppModel`'s hands also means a Keychain refusal is
    /// recorded once, in the one place that knows how to explain it
    /// (`AppModel.TokenSource`), instead of vanishing into a `Bool`.
    var saveToken: (String) -> Void
    /// Forgets the credential on this Mac — removes it from the Keychain
    /// and clears it app-wide. Does not revoke anything on the server.
    var forgetToken: () -> Void
    /// HTTP Basic for the current host, for an instance behind a
    /// Basic-protected front door. Independent of the token: a proxied
    /// instance needs both, and clearing one must not clear the other.
    var basic: () -> BasicCredential?
    /// Saves, or with nil clears, the current host's Basic credential.
    var saveBasic: (BasicCredential?) -> Void
    /// Re-reads the credential after a host switch, since a credential is
    /// host-specific and does not carry over.
    var reloadCredential: () -> Void
    /// The credential for *a named host*, which is what multi-host review
    /// needs: `token()` answers for whichever host is active, and a
    /// dashboard syncing a GitHub repository and a GitLab project in the
    /// same pass has to ask per host instead.
    var credentialFor: (ForgeHost) -> HostCredential
    /// Every host the reviewer has configured, for the picker's switcher.
    var knownHosts: () -> [ForgeHost]
    var settings: () -> AppSettings
    /// Persists a mutated settings value app-wide.
    var updateSettings: (AppSettings) -> Void

    var host: ForgeHost { api().host }

    /// The credential for `host`, however it is stored.
    func credential(for host: ForgeHost) -> HostCredential { credentialFor(host) }

    /// A context backed by in-memory values, for previews and tests.
    static func stub(token: String? = nil, settings: AppSettings = AppSettings()) -> AppContext {
        var stored = settings
        var storedToken = token
        var storedBasic: BasicCredential?
        return AppContext(
            api: { GitHubAPI(host: stored.githubHost) },
            token: { storedToken },
            saveToken: { storedToken = $0 },
            forgetToken: { storedToken = nil },
            basic: { storedBasic },
            saveBasic: { storedBasic = $0 },
            reloadCredential: {},
            credentialFor: { host in
                HostCredential(host: host, credential: ForgeCredential(token: storedToken, basic: storedBasic))
            },
            knownHosts: { [stored.githubHost] },
            settings: { stored },
            updateSettings: { stored = $0 }
        )
    }
}
