import Foundation

@MainActor
final class AIAskComposerModel: ObservableObject {
    @Published var text = ""
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var taggedPaths: [String] = [] { didSet { invalidateMatches() } }
    @Published var selectedIndex = 0
    @Published var dismissed = false { didSet { invalidateMatches() } }
    @Published var focusRequest = 0
    /// The changed files that can be tagged, with the detail the picker
    /// shows: status and line counts. Paths alone made every row in the list
    /// look identical, so choosing between `Button.tsx` and `Button.test.tsx`
    /// meant reading two long paths character by character.
    @Published var files: [PRFile] = [] { didSet { indexFiles() } }

    // Everything below is derived from `files` and rebuilt when it changes.
    //
    // It is all cached rather than computed, because the composer's `body`
    // reads it several times per keystroke: `paths` for the count, `matches`
    // three times (the empty check, the rows, the list height), and one
    // membership test per tagged file for `canSend`. Recomputing a
    // 675-element map and a linear search on each of those made typing cost
    // more the larger the pull request — exactly backwards.

    /// What may be tagged.
    private(set) var paths: [String] = []
    private var pathSet: Set<String> = []
    private var filesByPath: [String: PRFile] = [:]
    private var candidates: [Candidate] = []

    /// One taggable file with its name and path already lowercased.
    ///
    /// Ranking touches every changed file, and doing `lastPathComponent` and
    /// `lowercased()` inside that loop meant two allocations and an NSString
    /// bridge per file per keystroke. They depend only on the path, so they
    /// are done once when the pull request loads.
    struct Candidate {
        let path: String
        let name: String
        let full: String

        init(path: String) {
            self.path = path
            self.name = (path as NSString).lastPathComponent.lowercased()
            self.full = path.lowercased()
        }
    }

    /// Whether a path is still in the pull request. O(1); the linear scan
    /// this replaced ran once per tagged file per body evaluation.
    func isInPullRequest(_ path: String) -> Bool { pathSet.contains(path) }

    /// The file behind a tagged path, when it is still in the pull request.
    func file(for path: String) -> PRFile? { filesByPath[path] }

    private func indexFiles() {
        paths = files.map(\.filename)
        pathSet = Set(paths)
        filesByPath = Dictionary(files.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        candidates = paths.map(Candidate.init(path:))
        invalidateMatches()
    }

    var mentionRange: NSRange? {
        guard !dismissed, selection.length == 0 else { return nil }
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let prefix = ns.substring(to: caret) as NSString
        let at = prefix.range(of: "@", options: .backwards)
        guard at.location != NSNotFound else { return nil }
        if at.location > 0 {
            let previous = prefix.substring(with: NSRange(location: at.location - 1, length: 1))
            guard previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        }
        let query = prefix.substring(from: at.location + 1)
        guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return NSRange(location: at.location, length: caret - at.location)
    }

    /// What the query under the cursor is, without the `@`.
    var mentionQuery: String {
        guard let range = mentionRange else { return "" }
        return String((text as NSString).substring(with: range).dropFirst())
    }

    /// The ranked, untagged files the picker offers.
    ///
    /// Memoized on the query it was computed for: the view asks for this
    /// three times per body evaluation and the answer cannot change between
    /// them, but each call used to re-filter and re-sort every changed file
    /// in the pull request.
    var matches: [String] {
        guard mentionRange != nil else { return [] }
        let query = mentionQuery
        if let cachedMatches, cachedMatchQuery == query { return cachedMatches }

        // Typing narrows: everything matching `butto` is a superset of
        // everything matching `button`, for all four ranks, because each one
        // is a containment test. So an extra character re-ranks the handful
        // that survived rather than all 675 changed files — which is the
        // difference between the cost of a keystroke growing with the pull
        // request and staying flat.
        let pool: [Candidate]
        if let previous = cachedMatchQuery, !previous.isEmpty, query.hasPrefix(previous), let cachedPool {
            pool = cachedPool
        } else {
            let tagged = Set(taggedPaths)
            pool = candidates.filter { !tagged.contains($0.path) }
        }

        let ranked = Self.rank(pool, query: query)
        cachedPool = ranked.pool
        cachedMatches = ranked.paths
        cachedMatchQuery = query
        return ranked.paths
    }

    private var cachedMatches: [String]?
    private var cachedMatchQuery: String?
    /// The candidates behind `cachedMatches`, kept so the next keystroke can
    /// narrow this set instead of the whole pull request.
    private var cachedPool: [Candidate]?

    private func invalidateMatches() {
        cachedMatches = nil
        cachedMatchQuery = nil
        cachedPool = nil
    }

    /// Ranks candidate paths against what has been typed after the `@`.
    ///
    /// Pure and static so the ordering is checkable directly — it is the
    /// difference between the file you meant being first and being eleventh.
    ///
    /// The old rule was two buckets: does the *filename* start with the
    /// query, or not. Everything else tied and fell back to alphabetical, so
    /// typing `button` put `src/a/Button.tsx` above `Button.tsx`, and a
    /// query that only matched a directory ranked level with one that
    /// matched the name exactly. These four ranks say what a reviewer
    /// actually means by typing a few letters: the file called that, then
    /// files starting with it, then files containing it, then anywhere in
    /// the path.
    static func rank(_ paths: [String], query: String) -> [String] {
        rank(paths.map(Candidate.init(path:)), query: query).paths
    }

    /// Returns the ranked paths and the candidates behind them, so a caller
    /// that is about to be asked a longer query can narrow to these.
    static func rank(_ candidates: [Candidate], query: String) -> (paths: [String], pool: [Candidate]) {
        let needle = query.lowercased()
        guard !needle.isEmpty else {
            let sorted = candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return (sorted.map(\.path), sorted)
        }
        let scored: [(Candidate, Int)] = candidates.compactMap { candidate in
            if candidate.name == needle { return (candidate, 0) }
            if candidate.name.hasPrefix(needle) { return (candidate, 1) }
            if candidate.name.contains(needle) { return (candidate, 2) }
            if candidate.full.contains(needle) { return (candidate, 3) }
            return nil
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1
                ? lhs.0.path.localizedStandardCompare(rhs.0.path) == .orderedAscending
                : lhs.1 < rhs.1
        }
        return (scored.map(\.0.path), scored.map(\.0))
    }

    var scope: AIScope { taggedPaths.isEmpty ? .wholePR : .files(taggedPaths) }

    func update(text: String, selection: NSRange) {
        if self.text != text || self.selection != selection {
            dismissed = false
            selectedIndex = 0
            invalidateMatches()
        }
        self.text = text
        self.selection = selection
    }

    func choose(_ path: String) {
        guard isInPullRequest(path), let range = mentionRange else { return }
        if !taggedPaths.contains(path) { taggedPaths.append(path) }
        text = (text as NSString).replacingCharacters(in: range, with: "")
        selection = NSRange(location: range.location, length: 0)
        selectedIndex = 0
        focusRequest += 1
    }

    func showPicker() {
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let separator = caret > 0 && ns.substring(with: NSRange(location: caret - 1, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " : ""
        let insertion = separator + "@"
        text = ns.replacingCharacters(in: NSRange(location: caret, length: min(selection.length, ns.length - caret)), with: insertion)
        selection = NSRange(location: caret + insertion.utf16.count, length: 0)
        dismissed = false
        selectedIndex = 0
        focusRequest += 1
    }

    func handle(_ command: String) -> Bool {
        guard mentionRange != nil else { return false }
        switch command {
        case "cancelOperation:": dismissed = true
        case "moveUp:": selectedIndex = max(0, selectedIndex - 1)
        case "moveDown:": selectedIndex = min(max(0, matches.count - 1), selectedIndex + 1)
        case "insertNewline:", "insertTab:":
            if matches.indices.contains(selectedIndex) { choose(matches[selectedIndex]) }
        default: return false
        }
        return true
    }

    /// Tagged paths that are no longer in the pull request — the head moved
    /// and a file went away. They block sending, so the view offers to drop
    /// them rather than leaving the reviewer to work out why Send is dead.
    var staleTaggedPaths: [String] {
        taggedPaths.filter { !isInPullRequest($0) }
    }

    /// Whether every tagged file is still in the pull request — what Send
    /// depends on, asked once instead of once per tag.
    var everyTagIsLive: Bool { taggedPaths.allSatisfy(isInPullRequest) }

    func untag(_ path: String) {
        taggedPaths.removeAll { $0 == path }
    }

    func untagAll() {
        taggedPaths.removeAll()
    }

    func dropStaleTags() {
        taggedPaths.removeAll { !isInPullRequest($0) }
    }

    func reset() {
        text = ""
        selection = NSRange(location: 0, length: 0)
        taggedPaths = []
        dismissed = false
        selectedIndex = 0
        invalidateMatches()
    }
}
