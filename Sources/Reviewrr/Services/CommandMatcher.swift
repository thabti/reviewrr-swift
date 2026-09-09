import Foundation

/// Ranks palette commands against what the reviewer has typed.
///
/// Subsequence matching rather than substring: "sbr" should find "Submit
/// review" and "opgh" should find "Open on GitHub", because the whole point
/// of a palette is reaching a command in three keystrokes. Substring
/// matching would force people to remember exact wording, which is the
/// problem the palette exists to solve.
enum CommandMatcher {
    /// A scored command plus the character positions that matched, so the
    /// palette can show *why* a result is there.
    struct Match: Equatable {
        let id: String
        let score: Int
        /// Offsets into the title that matched the query, for highlighting.
        let highlights: [Int]
    }

    /// The query, prepared once per `rank` call rather than once per
    /// candidate string. Folding is the expensive part of scoring — the
    /// original implementation re-folded the query itself on every single
    /// title/subtitle/keyword comparison, which for 1,200 commands is
    /// thousands of redundant Unicode fold + array-allocation passes over a
    /// string that never changes mid-ranking.
    private struct PreparedQuery {
        /// Lowercased ASCII bytes, present only when the query itself is
        /// pure ASCII — the overwhelming common case for the words a
        /// reviewer types into the palette. `nil` sends every comparison
        /// through the Unicode fallback below.
        let asciiNeedle: [UInt8]?
        /// Unicode case/diacritic-folded characters — the fallback for the
        /// rare non-ASCII query or candidate, computed with exactly the
        /// same `folding` call the original implementation always used.
        let foldedNeedle: [Character]

        init(_ query: String) {
            asciiNeedle = CommandMatcher.asciiLowercased(query)
            foldedNeedle = Array(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    /// Ranks commands, best first. An empty query keeps the caller's order
    /// but floats recently used commands to the top — the palette's most
    /// common use is repeating what you just did.
    static func rank(
        _ commands: [PaletteCommand],
        query: String,
        recentIDs: [String] = []
    ) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            let recentRank = Dictionary(
                uniqueKeysWithValues: recentIDs.enumerated().map { ($0.element, $0.offset) }
            )
            return commands.enumerated().sorted { lhs, rhs in
                let lRecent = recentRank[lhs.element.id]
                let rRecent = recentRank[rhs.element.id]
                switch (lRecent, rRecent) {
                case let (l?, r?): return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if lhs.element.group.rank != rhs.element.group.rank {
                        return lhs.element.group.rank < rhs.element.group.rank
                    }
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }

        let preparedQuery = PreparedQuery(trimmed)
        var scored: [(command: PaletteCommand, match: Match)] = []
        scored.reserveCapacity(commands.count)
        for command in commands {
            // `rank` only ever reads `match.score` — the final result is
            // `[PaletteCommand]`, not `[Match]` — so this hot path skips
            // building the `highlights` array entirely rather than
            // allocating and immediately discarding it 1,200 times over.
            if let match = self.match(command, preparedQuery: preparedQuery, needsHighlights: false) {
                scored.append((command, match))
            }
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                // Stable, predictable tie-break so results do not shuffle as
                // the reviewer types another character.
                if lhs.command.group.rank != rhs.command.group.rank {
                    return lhs.command.group.rank < rhs.command.group.rank
                }
                return lhs.command.title.count < rhs.command.title.count
            }
            .map(\.command)
    }

    /// Scores one command, or nil when the query does not match it at all.
    static func match(_ command: PaletteCommand, query: String) -> Match? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Match(id: command.id, score: 0, highlights: []) }
        return match(command, preparedQuery: PreparedQuery(trimmed), needsHighlights: true)
    }

    private static func match(_ command: PaletteCommand, preparedQuery: PreparedQuery, needsHighlights: Bool) -> Match? {
        var best: (score: Int, highlights: [Int])?

        if let titleMatch = score(preparedQuery, in: command.title, needsHighlights: needsHighlights) {
            best = titleMatch
        }
        // A subtitle hit (a file path, a repository) is a real match but must
        // never outrank the command whose *title* the reviewer typed. Its
        // highlights are discarded either way, so this never needs them.
        if let subtitle = command.subtitle, let subtitleMatch = score(preparedQuery, in: subtitle, needsHighlights: false) {
            let demoted = (score: subtitleMatch.score - 40, highlights: [Int]())
            if (best?.score ?? Int.min) < demoted.score { best = demoted }
        }
        for keyword in command.keywords {
            if let keywordMatch = score(preparedQuery, in: keyword, needsHighlights: false) {
                let demoted = (score: keywordMatch.score - 60, highlights: [Int]())
                if (best?.score ?? Int.min) < demoted.score { best = demoted }
            }
        }

        guard let best else { return nil }
        // A disabled command still matches — it is shown greyed with its
        // reason rather than vanishing, so the reviewer learns it exists.
        return Match(id: command.id, score: best.score - (command.isEnabled ? 0 : 500), highlights: best.highlights)
    }

    /// Scores one candidate string against a prepared query. Takes the ASCII
    /// fast path only when *both* sides are pure ASCII — mixing a
    /// byte-lowercased query with a Unicode-folded candidate (or vice versa)
    /// would compare incompatible representations, so any non-ASCII text on
    /// either side falls back to the exact algorithm the original
    /// implementation always used.
    private static func score(
        _ query: PreparedQuery, in candidate: String, needsHighlights: Bool
    ) -> (score: Int, highlights: [Int])? {
        if let needle = query.asciiNeedle, let hay = asciiLowercased(candidate) {
            return matchASCII(needle: needle, hay: hay, needsHighlights: needsHighlights)
        }
        let hay = Array(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        return matchFolded(needle: query.foldedNeedle, hay: hay, needsHighlights: needsHighlights)
    }

    /// Lowercased ASCII bytes for `string`, or `nil` the moment a non-ASCII
    /// byte turns up. One pass over `utf8` rather than a separate
    /// `allSatisfy` scan plus a `map` — and a plain loop rather than two
    /// higher-order-function calls, so this stays cheap even in an
    /// unoptimized build, where a closure passed to `map`/`allSatisfy` isn't
    /// inlined away the way it would be under optimization.
    private static func asciiLowercased(_ string: String) -> [UInt8]? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append(byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte)
        }
        return bytes
    }

    /// Case-insensitive subsequence scoring over lowercased ASCII bytes —
    /// the hot path, taken for essentially every command title, subtitle,
    /// and keyword in this app. Kept as a concrete, non-generic function
    /// (rather than one generic function shared with `matchFolded` below)
    /// because the closure a generic version would need for its
    /// word-boundary test only gets inlined away under optimization; in an
    /// unoptimized build it costs enough to erase most of this fast path's
    /// advantage. The two functions must be kept in sync by hand — the
    /// scoring rules are documented once, here.
    ///
    /// Rewards, in order of weight: an exact prefix, matches that start a
    /// word ("gh" in "on **G**it**H**ub"), and runs of adjacent characters.
    /// Penalizes distance, so a match spread across a long string loses to a
    /// tight one.
    private static func matchASCII(
        needle: [UInt8], hay: [UInt8], needsHighlights: Bool
    ) -> (score: Int, highlights: [Int])? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }

        var score = 0
        // Stays the shared empty-array singleton (no heap allocation) unless
        // a caller actually wants highlight positions — `rank`'s hot path
        // never reads them, so most calls never allocate this at all.
        var highlights: [Int] = []
        if needsHighlights { highlights.reserveCapacity(needle.count) }
        var hayIndex = 0
        var previousMatch: Int?

        for character in needle {
            var found: Int?
            while hayIndex < hay.count {
                if hay[hayIndex] == character { found = hayIndex; break }
                hayIndex += 1
            }
            guard let index = found else { return nil }

            score += 10
            let isWordStart = index == 0 || hay[index - 1] == 0x20 || hay[index - 1] == 0x2F || hay[index - 1] == 0x5F
            if isWordStart { score += 15 }
            if let previous = previousMatch {
                if index == previous + 1 {
                    score += 12
                } else {
                    // Gaps cost, but bounded — otherwise one long path
                    // segment would disqualify an otherwise good match.
                    score -= min(index - previous, 8)
                }
            } else if index == 0 {
                score += 25
            }

            if needsHighlights { highlights.append(index) }
            previousMatch = index
            hayIndex += 1
        }

        // Shorter candidates win ties: "Open on GitHub" should beat
        // "Open on GitHub in a new window" for the same keystrokes.
        score -= hay.count / 12
        return (score, highlights)
    }

    /// The exact same algorithm as `matchASCII`, over Unicode-folded
    /// `Character`s — the fallback for the rare non-ASCII query or
    /// candidate. See `matchASCII` for the scoring rationale.
    private static func matchFolded(
        needle: [Character], hay: [Character], needsHighlights: Bool
    ) -> (score: Int, highlights: [Int])? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }

        var score = 0
        var highlights: [Int] = []
        if needsHighlights { highlights.reserveCapacity(needle.count) }
        var hayIndex = 0
        var previousMatch: Int?

        for character in needle {
            var found: Int?
            while hayIndex < hay.count {
                if hay[hayIndex] == character { found = hayIndex; break }
                hayIndex += 1
            }
            guard let index = found else { return nil }

            score += 10
            let isWordStart = index == 0 || hay[index - 1] == " " || hay[index - 1] == "/" || hay[index - 1] == "_"
            if isWordStart { score += 15 }
            if let previous = previousMatch {
                if index == previous + 1 {
                    score += 12
                } else {
                    score -= min(index - previous, 8)
                }
            } else if index == 0 {
                score += 25
            }

            if needsHighlights { highlights.append(index) }
            previousMatch = index
            hayIndex += 1
        }

        score -= hay.count / 12
        return (score, highlights)
    }
}
