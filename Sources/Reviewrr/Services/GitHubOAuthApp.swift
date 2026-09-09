import Foundation

/// Where the OAuth client ID driving "Continue with GitHub" came from.
///
/// Worth telling apart rather than collapsing to "we have one": what the
/// sign-in screen should say when there *isn't* one depends entirely on
/// whether this build was meant to ship with one, and a reviewer who typed
/// their own into Settings should be told the app is using theirs.
enum GitHubOAuthClientIDSource: Equatable {
    /// Baked in at build time from the `ReviewrrGitHubClientID` Info.plist
    /// key — how a distributed build gets a working sign-in button.
    case bundled
    /// From `REVIEWRR_GITHUB_CLIENT_ID` in the environment. The override a
    /// development build can be launched with, matching how
    /// `REVIEWRR_GITHUB_TOKEN` overrides the Keychain.
    case environment
    /// Typed into Settings on this Mac, for a build that shipped without one.
    case userProvided
    case none
}

/// The GitHub OAuth application Reviewrr signs in as.
///
/// ## Why the device flow, and not a browser redirect
///
/// GitHub's authorization-code flow requires a `client_secret` on the token
/// exchange and does not support PKCE, so a native app with no server of
/// its own cannot use it without shipping a secret inside the app bundle —
/// where it is not a secret. The device flow (RFC 8628) exchanges a device
/// code for a token using only the *public* client ID, which is exactly the
/// shape a Mac app without a backend needs. That is why sign-in shows a code
/// to type on github.com rather than opening a redirect URL.
///
/// The client ID itself is public by design (it appears in every OAuth URL),
/// so baking it into the app bundle is correct — unlike the secret, which is
/// never needed here and must never be added.
struct GitHubOAuthApp: Equatable {
    /// Empty exactly when `source == .none`.
    var clientID: String
    var source: GitHubOAuthClientIDSource

    static let unconfigured = GitHubOAuthApp(clientID: "", source: .none)

    var isConfigured: Bool { source != .none }

    /// `repo` covers reading diffs and submitting reviews; `read:org`
    /// resolves organization-owned repository visibility — the same bar
    /// `GitHubScopeEvaluator` holds a classic/OAuth token to, so a token
    /// obtained this way passes the Account pane's own scope check.
    static let scope = GitHubAuth.defaultDeviceFlowScope

    /// The Info.plist key a build stamps the client ID into. Set via the
    /// `INFOPLIST_KEY_ReviewrrGitHubClientID` build setting (see
    /// `project.yml`), which takes its value from the `REVIEWRR_GITHUB_CLIENT_ID`
    /// user-defined setting so a build can override it on the command line:
    ///
    ///     xcodebuild … REVIEWRR_GITHUB_CLIENT_ID=Ov23liXXXXXXXXXXXXXX
    static let infoPlistKey = "ReviewrrGitHubClientID"
    static let environmentVariable = "REVIEWRR_GITHUB_CLIENT_ID"

    /// Resolves the client ID actually in effect.
    ///
    /// Precedence, most specific first: what the reviewer typed into
    /// Settings, then the environment, then whatever the build shipped with.
    /// The typed value wins because it is the only one of the three that can
    /// be changed without a rebuild or a relaunch — someone who pastes their
    /// own OAuth App's ID into a build that already has one is deliberately
    /// replacing it, and silently ignoring them would look like the field
    /// was broken.
    ///
    /// Pure, so the precedence rule is testable without a bundle, an
    /// environment, or `UserDefaults`.
    static func resolve(
        userProvided: String?,
        environment: String?,
        bundled: String?
    ) -> GitHubOAuthApp {
        let candidates: [(String?, GitHubOAuthClientIDSource)] = [
            (userProvided, .userProvided),
            (environment, .environment),
            (bundled, .bundled),
        ]
        for (raw, source) in candidates {
            if let value = sanitize(raw) {
                return GitHubOAuthApp(clientID: value, source: source)
            }
        }
        return .unconfigured
    }

    /// The live resolution, reading the real bundle, environment, and saved
    /// preferences. `userProvided` is passed in rather than read here so a
    /// caller holding an unsaved edit (the Settings text field binds to
    /// `AuthModel.deviceFlowClientID`) resolves against what is on screen.
    static func current(userProvided: String? = AuthPreferences.load().deviceFlowClientID) -> GitHubOAuthApp {
        resolve(
            userProvided: userProvided,
            environment: ProcessInfo.processInfo.environment[environmentVariable],
            bundled: Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
        )
    }

    /// Trims, and rejects the two things that look like a client ID but
    /// aren't: an empty value, and an Info.plist entry whose build setting
    /// was never substituted (`$(REVIEWRR_GITHUB_CLIENT_ID)` reaches the
    /// bundle verbatim when the setting is undefined). Whitespace inside a
    /// value is rejected too — GitHub client IDs have none, and a pasted
    /// line break would otherwise become an unexplained HTTP 401.
    static func sanitize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard !trimmed.contains("$(") else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        return trimmed
    }
}
