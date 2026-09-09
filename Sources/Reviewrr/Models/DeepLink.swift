import Foundation

/// A `reviewrr://` URL, so a pull request can be opened from anywhere on the
/// Mac that can hold a link — a Slack message, a terminal `open`, a Shortcut,
/// a bookmark, a review-request email.
///
/// The shape is deliberately the shortest thing that identifies a pull
/// request, and reads correctly out loud:
///
///     reviewrr://acme/web-app/482
///              └ owner └ repo  └ number
///
/// `reviewrr://acme/web-app/pull/482` is accepted too, so pasting a GitHub
/// path after the scheme works rather than failing on a difference nobody
/// would expect to matter.
///
/// ## No host in the link
///
/// A deep link names an owner, a repository, and a number — never a GitHub
/// host. It resolves against whichever host Reviewrr is currently configured
/// for, which is the behaviour an Enterprise Server user wants: the same link
/// works for everyone on the team, and nobody has to paste an appliance
/// hostname into a chat message. It also means a link cannot silently point
/// someone at the wrong host.
enum DeepLink: Equatable {
    case pullRequest(PRReference)

    static let scheme = "reviewrr"

    /// Builds the canonical link for a pull request. The inverse of
    /// `parse(_:)` for every reference `parse` can produce.
    static func url(for reference: PRReference) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        // `host` is where the owner goes, but `URLComponents` lowercases a
        // host on the way out. Building the whole thing as a string keeps
        // the owner's case exactly as GitHub spells it — see `parse`.
        components.host = nil
        guard
            let owner = encode(reference.owner),
            let repo = encode(reference.repo)
        else { return nil }
        return URL(string: "\(scheme)://\(owner)/\(repo)/\(reference.number)")
    }

    /// Parses an incoming URL, or returns nil for anything that is not a
    /// pull-request link this app understands.
    ///
    /// Case is preserved deliberately. `URL.host` lowercases the authority
    /// component, and the owner lives there — so a link to `Acme/web-app`
    /// would arrive as `acme/web-app`. GitHub's API does not care, but
    /// Reviewrr keys drafts, viewed-file state, and the recent list on
    /// `owner/repo#number`: a lowercased owner would quietly split one pull
    /// request's local state into two. The authority is read out of the raw
    /// string instead.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // Everything after the scheme, with any query or fragment dropped:
        // a link that picked up `?utm_source=…` on its way through a chat
        // client should still open the pull request.
        var body = url.absoluteString.dropFirst("\(url.scheme ?? "")://".count)
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            body = body[body.startIndex..<cut]
        }

        var parts = body
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { decode(String($0)) }

        // `reviewrr://acme/web-app/pull/482` — the GitHub path, pasted after
        // the scheme. Tolerated rather than rejected on a technicality.
        if parts.count == 4, parts[2].lowercased() == "pull" {
            parts.remove(at: 2)
        }

        guard parts.count == 3 else { return nil }
        let owner = parts[0], repo = parts[1]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        // `Int` alone would accept "+482", "-3", and whitespace; a PR number
        // is digits, and anything else is a link to reject rather than
        // reinterpret.
        guard parts[2].allSatisfy(\.isNumber), let number = Int(parts[2]), number > 0 else { return nil }

        return .pullRequest(PRReference(owner: owner, repo: repo, number: number))
    }

    /// What to tell the reviewer when a link does not parse. Names the shape
    /// that does work, because the usual cause is a link built by hand.
    static let malformedMessage = """
        That \(scheme):// link isn't a pull request Reviewrr can open. \
        The shape is \(scheme)://owner/repo/number — for example, \(scheme)://acme/web-app/482.
        """

    private static let allowedInPathSegment: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encode(_ segment: String) -> String? {
        guard !segment.isEmpty else { return nil }
        return segment.addingPercentEncoding(withAllowedCharacters: allowedInPathSegment)
    }

    private static func decode(_ segment: String) -> String? {
        segment.removingPercentEncoding ?? segment
    }
}

extension PRReference {
    /// This pull request as a `reviewrr://` link, for sharing.
    var deepLinkURL: URL? { DeepLink.url(for: self) }
}
