import Foundation

/// Which flavour of Jira the reviewer's team runs.
///
/// The link is the same either way — `<base>/browse/<KEY>` — so this exists
/// for the two places the difference is real: what a valid base URL looks
/// like, and what to tell someone whose URL does not work.
enum IssueTrackerKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Atlassian-hosted, `https://<site>.atlassian.net`.
    case jiraCloud
    /// Run by the team: any host, and often behind a context path such as
    /// `https://jira.acme.com/jira`.
    case jiraServer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jiraCloud: return "Jira Cloud"
        case .jiraServer: return "Jira Server or Data Center"
        }
    }

    var placeholder: String {
        switch self {
        case .jiraCloud: return "https://your-team.atlassian.net"
        case .jiraServer: return "https://jira.example.com"
        }
    }

    var explanation: String {
        switch self {
        case .jiraCloud:
            return "Your Atlassian site, exactly as it appears in the browser — the part before /browse."
        case .jiraServer:
            return "Your Jira host, including a context path if it has one (…/jira). Reviewrr only builds links; it never calls the API, so this works behind a VPN."
        }
    }
}

extension IssueTrackerKind {
    /// Which flavour an address belongs to, read off the address itself.
    ///
    /// Atlassian hosts every cloud site on `atlassian.net`, so asking the
    /// reviewer to pick was asking them to restate something they had
    /// already typed — and getting it wrong changed nothing but the help
    /// text, which is the definition of a control that should not exist.
    static func inferred(from baseURL: String) -> IssueTrackerKind {
        let lowered = baseURL.lowercased()
        return lowered.contains("atlassian.net") || lowered.contains("jira.com") ? .jiraCloud : .jiraServer
    }

    /// What to call it once it has been recognised.
    var detectedLabel: String {
        switch self {
        case .jiraCloud: return "Jira Cloud"
        case .jiraServer: return "Self-hosted Jira"
        }
    }
}

/// One issue key found in a pull request.
struct IssueReference: Equatable, Hashable, Identifiable, Sendable {
    /// Normalised to upper case: `ec-1013` and `EC-1013` are one issue, and
    /// Jira's own URLs are upper case.
    let key: String
    /// The project part, `EC` in `EC-1013`.
    let projectKey: String
    /// Where it was found, for the reviewer's benefit and for tests.
    let source: Source

    enum Source: String, Equatable, Hashable, Sendable {
        case title, body, branch, comment
    }

    var id: String { "\(source.rawValue):\(key)" }
}

/// Where Reviewrr looks for issue keys, and what it links them to.
///
/// Link-only by design: no API calls, no credentials, no summaries fetched.
/// That keeps a self-hosted Jira behind a VPN working exactly as well as
/// Atlassian's cloud, and means the feature cannot leak a pull request's
/// title to a tracker that has never been authenticated.
struct IssueTrackerSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool = false
    /// Kept in the model for the help text and for old blobs, but derived
    /// from the address rather than chosen — see `IssueTrackerKind.inferred`.
    var kind: IssueTrackerKind = .jiraCloud

    /// The flavour implied by whatever is currently typed.
    var detectedKind: IssueTrackerKind { .inferred(from: baseURL) }
    /// The site root. Trailing slashes and an accidental `/browse` suffix are
    /// tolerated — see `normalizedBaseURL`.
    var baseURL: String = ""

    /// When non-empty, only these project keys are linked.
    ///
    /// The escape hatch for a repository whose diffs are full of things that
    /// look like issue keys — `UTF-8`, `SHA-256`, `HTTP-2`, an enum case in a
    /// generated file. A reviewer who names their projects gets exact
    /// matching and no false positives at all.
    var projectKeys: Set<String> = []

    // Where to look. All on by default: "or anywhere" is the ask, and a key
    // that is only in the branch name is exactly the case a reviewer wants
    // rescued.
    /// Always on, and no longer asked about: a key in the title or the
    /// description is the most deliberate mention there is, and nobody
    /// wants it left unlinked. Kept as stored properties so an older blob
    /// decodes, but the pane offers no way to turn them off.
    var scanTitle: Bool = true
    var scanBody: Bool = true
    var scanBranch: Bool = true
    var scanComments: Bool = true

    /// Jira's key shape: a project key, a hyphen, a number.
    ///
    /// A constant, not a setting. A regular expression is not something a
    /// reviewer should own: Jira's key shape does not vary between
    /// installations, so the field could only ever be left alone or broken —
    /// and a pane that asks for one is asking someone to debug a regex to get
    /// a hyperlink.
    ///
    /// At least two characters in the project key on purpose — a one-letter
    /// prefix turns every `A-1` in prose into a link.
    static let pattern = "[A-Z][A-Z0-9]{1,9}-[0-9]+"

    /// Jira's permalink path. Constant for the same reason the pattern is:
    /// every Jira serves `/browse/KEY`.
    static let browsePath = "browse"

    init() {}

    /// The base URL with the noise a reviewer will paste taken off: trailing
    /// slashes, and a `/browse` or `/browse/KEY` tail from copying a link to
    /// an issue rather than the site root.
    var normalizedBaseURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        // `…/browse/EC-1013` and `…/browse` both collapse to the site root.
        let lowered = text.lowercased()
        if let range = lowered.range(of: "/\(Self.browsePath)") {
            text = String(text[text.startIndex..<range.lowerBound])
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// Whether this configuration can actually produce a link.
    var isUsable: Bool { isEnabled && normalizedBaseURL != nil }

    /// The permalink for a key: `<base>/browse/EC-1013`.
    func url(for key: String) -> URL? {
        guard let base = normalizedBaseURL else { return nil }
        return base
            .appendingPathComponent(Self.browsePath)
            .appendingPathComponent(key)
    }

    /// A concrete example of what this configuration produces, for the
    /// preview. `EC-1013` because it looks like a real key and belongs to
    /// nobody.
    static let sampleKey = "EC-1013"

    var sampleURL: URL? { url(for: Self.sampleKey) }

    // MARK: - Forward-compatible decoding

    /// `pattern` and `browsePath` were settings once. They are absent here
    /// rather than retained as dead storage: an unknown key in a stored blob
    /// is already ignored, so an older file decodes on its remaining fields
    /// and the retired ones simply stop existing.
    enum CodingKeys: String, CodingKey {
        case isEnabled, kind, baseURL, projectKeys
        case scanTitle, scanBody, scanBranch, scanComments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IssueTrackerSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        isEnabled = value(.isEnabled, defaults.isEnabled)
        kind = value(.kind, defaults.kind)
        baseURL = value(.baseURL, defaults.baseURL)
        projectKeys = value(.projectKeys, defaults.projectKeys)
        scanTitle = value(.scanTitle, defaults.scanTitle)
        scanBody = value(.scanBody, defaults.scanBody)
        scanBranch = value(.scanBranch, defaults.scanBranch)
        scanComments = value(.scanComments, defaults.scanComments)
    }
}

/// Finds issue keys in text.
///
/// A value rather than a free function because the compiled regex is worth
/// keeping: the diff pane and the inbox both scan on every refresh, and
/// `NSRegularExpression` compilation is the expensive part.
struct IssueKeyDetector {
    let settings: IssueTrackerSettings
    private let regex: NSRegularExpression?

    init(settings: IssueTrackerSettings) {
        self.settings = settings
        // The constant, not a stored value: the pattern is not
        // configuration any more, so there is no invalid state to pass
        // through and no way for a reviewer to break key detection.
        //
        // Case-insensitive exactly when the reviewer has named their
        // projects. `git checkout -b ec-1013-fix` is how branches are
        // actually typed, and a key that only matches shouting is a key that
        // misses half of them — but matching any case without an allow-list
        // would link `utf-8`, `part-2` and `covid-19` in ordinary prose. So
        // filling in the project keys makes detection both stricter (nothing
        // else can match) and more forgiving (any case).
        let options: NSRegularExpression.Options = settings.projectKeys.isEmpty ? [] : [.caseInsensitive]
        self.regex = try? NSRegularExpression(pattern: IssueTrackerSettings.pattern, options: options)
    }

    /// Always true in practice — the pattern is a compile-time constant.
    /// Kept as a property because the preview reads it, and because a
    /// literal `true` there would read as an oversight rather than a fact.
    var isPatternValid: Bool { regex != nil }

    /// Every key in `text`, in the order they appear, deduped.
    func keys(in text: String, source: IssueReference.Source) -> [IssueReference] {
        guard let regex, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var found: [IssueReference] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let matched = Range(match.range, in: text) else { return }
            let raw = String(text[matched]).uppercased()
            guard let hyphen = raw.lastIndex(of: "-") else { return }
            let project = String(raw[raw.startIndex..<hyphen])
            // An allow-list means exactly those projects and nothing else.
            if !settings.projectKeys.isEmpty {
                let allowed = Set(settings.projectKeys.map { $0.uppercased() })
                guard allowed.contains(project) else { return }
            }
            guard seen.insert(raw).inserted else { return }
            found.append(IssueReference(key: raw, projectKey: project, source: source))
        }
        return found
    }

    /// Every key anywhere in a pull request the reviewer asked to be scanned.
    ///
    /// Ordered title → body → branch, so the most deliberate mention wins the
    /// first chip, and deduped across sources: a key in both the title and
    /// the description is one issue, not two.
    func keys(
        title: String? = nil,
        body: String? = nil,
        branch: String? = nil,
        comments: [String] = []
    ) -> [IssueReference] {
        guard settings.isEnabled else { return [] }
        var found: [IssueReference] = []
        var seen = Set<String>()

        func collect(_ text: String?, _ source: IssueReference.Source, _ isWanted: Bool) {
            guard isWanted, let text else { return }
            for reference in keys(in: text, source: source) where seen.insert(reference.key).inserted {
                found.append(reference)
            }
        }

        collect(title, .title, settings.scanTitle)
        collect(body, .body, settings.scanBody)
        // Branch names carry the key with a separator that is not a hyphen
        // often enough to matter — `feature/EC-1013-add-invites` matches as
        // written, but `feature/ec_1013` never will, and that is the honest
        // outcome rather than guessing.
        collect(branch, .branch, settings.scanBranch)
        if settings.scanComments {
            for comment in comments {
                collect(comment, .comment, true)
            }
        }
        return found
    }
}
