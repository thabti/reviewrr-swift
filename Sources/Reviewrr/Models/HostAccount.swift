import Foundation

/// One host Reviewrr knows about, and what it has to sign in with.
///
/// The Account pane used to describe a *selection*: a segmented picker chose
/// one of GitHub.com / Enterprise / GitLab, and everything below it — the
/// credential, its state, and the sign-out button floating above all of it —
/// silently belonged to whichever one was picked. A reviewer with a token on
/// github.com and another on an appliance could see one at a time and could
/// not tell, from looking, that the other still existed.
///
/// So a host is a thing on screen now, one card each, and the actions that
/// apply to a host live inside it.
struct HostAccount: Identifiable, Equatable, Sendable {
    let host: ForgeHost
    /// The host Reviewrr is currently operating on. Exactly one is.
    let isActive: Bool
    let maskedToken: String?
    let basicUsername: String?

    var id: String { host.identityKey }

    var hasCredential: Bool { maskedToken != nil || basicUsername != nil }

    /// What this host authenticates with, in one line.
    var credentialSummary: String {
        switch (maskedToken, basicUsername) {
        case (let token?, let user?):
            return "\(token) · HTTP Basic as \(user)"
        case (let token?, nil):
            return token
        case (nil, let user?):
            return "HTTP Basic as \(user)"
        case (nil, nil):
            return "No credential saved"
        }
    }

    /// GitHub.com is never removable: it is the default host, and a Reviewrr
    /// with no hosts at all has nowhere to put the next token. Signing out of
    /// it is always allowed — that just clears the credential.
    var isRemovable: Bool { !host.isDotCom }

    /// What kind of host this is, for the badge on the card.
    var kindLabel: String {
        if host.isGitLab { return host.isDotCom ? "GitLab" : "GitLab (self-managed)" }
        return host.isDotCom ? "GitHub.com" : "GitHub Enterprise"
    }

    var symbol: String {
        host.isGitLab ? "point.3.filled.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right"
    }
}

extension HostAccount {
    /// Every host worth showing, in a stable order.
    ///
    /// GitHub.com first because it is the default and always present, then
    /// everything the reviewer has added, alphabetically — not in the order
    /// they happened to be added, which makes the list jump around as hosts
    /// come and go.
    ///
    /// `credentialFor` is injected rather than read from the Keychain here:
    /// this runs to build a view, the Keychain is slow enough to matter at
    /// that rate, and a test must be able to describe a signed-in host
    /// without one.
    static func all(
        active: ForgeHost,
        known: [ForgeHost],
        credentialFor: (ForgeHost) -> (token: String?, basic: BasicCredential?)
    ) -> [HostAccount] {
        var hosts: [ForgeHost] = [.dotCom]
        // The active host may not be in `knownHosts` yet — it is added on a
        // switch, and a build that has only ever run on one host has an empty
        // list. Including it explicitly means the card for the host you are
        // using is never the one missing.
        for host in known + [active] where !hosts.contains(where: { $0.identityKey == host.identityKey }) {
            hosts.append(host)
        }
        let sorted = [hosts[0]] + hosts.dropFirst().sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return sorted.map { host in
            let credential = credentialFor(host)
            return HostAccount(
                host: host,
                isActive: host.identityKey == active.identityKey,
                maskedToken: credential.token.map(GitHubCredentialMasking.mask),
                basicUsername: credential.basic.map(\.username)
            )
        }
    }
}
