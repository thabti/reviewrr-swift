import Foundation

/// A GitHub-Flavored Markdown table.
///
/// Foundation's `AttributedString(markdown:)` does not parse tables at all —
/// it treats the rows as paragraphs, so a review-bot comment's severity
/// table arrived as a wall of pipes. This carries the parsed shape so the
/// view can lay it out as an actual grid.
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing
    }

    var headers: [String]
    /// One per column, from the delimiter row's colons (`:---`, `:---:`,
    /// `---:`). Always the same length as `headers`.
    var alignments: [Alignment]
    var rows: [[String]]

    var columnCount: Int { headers.count }
}

/// One piece of a comment body, split by the things that need their own
/// renderer.
///
/// Everything Foundation handles well stays in `.markdown` and goes through
/// the normal `AttributedString` path. Only the two constructs it gets wrong
/// are pulled out: tables (unsupported) and fenced code (so a table *inside*
/// a fence is never mistaken for a table).
enum MarkdownSegment: Equatable, Identifiable {
    case markdown(String)
    case table(MarkdownTable)
    case codeBlock(language: String?, code: String)
    /// A ```` ```suggestion ```` block: a concrete replacement for the lines
    /// the comment is anchored to. Both forges have this, and it is the one
    /// code block in a review that is not an illustration but a proposal —
    /// so it gets its own presentation rather than a grey box labelled
    /// "suggestion".
    case suggestion(SuggestedChange)

    var id: String {
        switch self {
        case .markdown(let text): return "md:\(text.hashValue)"
        case .table(let table): return "tbl:\(table.headers.joined(separator: "|")):\(table.rows.count)"
        case .codeBlock(let language, let code): return "code:\(language ?? "")\(code.hashValue)"
        case .suggestion(let change): return "sug:\(change.code.hashValue)"
        }
    }
}

/// A suggested change lifted out of a comment body.
struct SuggestedChange: Equatable {
    /// The replacement text, exactly as written — leading whitespace
    /// included, because the indentation *is* part of the suggestion.
    var code: String
    /// GitLab's line offsets from a ```` ```suggestion:-2+3 ```` fence:
    /// how many lines above and below the anchored line the suggestion
    /// replaces. GitHub's plain `suggestion` fence carries none, and nil
    /// means "the anchored line only".
    var linesAbove: Int?
    var linesBelow: Int?

    /// How many lines this replaces, when the fence said so.
    var replacedLineCount: Int? {
        guard let linesAbove, let linesBelow else { return nil }
        return linesAbove + linesBelow + 1
    }
}

/// Splits a comment body into renderable segments, and cleans up the inline
/// HTML that bot comments routinely carry.
///
/// Pure string work, deliberately outside `Views/`: the unit-test target
/// compiles `Models/` but not `Views/`, and this is the part with the edge
/// cases worth pinning down.
enum MarkdownSegmenter {
    // MARK: - Segmentation

    static func segments(from source: String) -> [MarkdownSegment] {
        let lines = source.components(separatedBy: "\n")
        var segments: [MarkdownSegment] = []
        var pending: [String] = []
        var index = 0

        func flushPending() {
            let text = pending.joined(separator: "\n")
            pending.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            segments.append(.markdown(text))
        }

        while index < lines.count {
            let line = lines[index]

            // Fenced code first: a pipe table inside a fence is code, not a
            // table, and a heading inside one is not a heading.
            if let fence = FenceMarker(line) {
                flushPending()
                var body: [String] = []
                index += 1
                while index < lines.count, !fence.closes(lines[index]) {
                    body.append(lines[index])
                    index += 1
                }
                // Skip the closing fence when there is one; an unterminated
                // fence runs to the end of the comment, which is what every
                // markdown implementation does.
                if index < lines.count { index += 1 }
                let code = body.joined(separator: "\n")
                if let change = suggestedChange(fenceInfo: fence.language, code: code) {
                    segments.append(.suggestion(change))
                } else {
                    segments.append(.codeBlock(language: fence.language, code: code))
                }
                continue
            }

            if let table = parseTable(lines, startingAt: index) {
                flushPending()
                segments.append(.table(table.table))
                index = table.endIndex
                continue
            }

            pending.append(line)
            index += 1
        }

        flushPending()
        return segments
    }

    /// A ``` or ~~~ fence, and its info string.
    private struct FenceMarker {
        let character: Character
        let length: Int
        let language: String?

        init?(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            let run = trimmed.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            character = first
            length = run.count
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            language = info.isEmpty ? nil : info
        }

        /// A fence closes on a run of the same character at least as long as
        /// the one that opened it, and nothing else on the line.
        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.allSatisfy({ $0 == character }) else { return false }
            return trimmed.count >= length
        }
    }

    // MARK: - Suggestions

    /// Reads a fence's info string as a suggestion, or returns nil when it
    /// is an ordinary code fence.
    ///
    /// GitHub writes `suggestion`. GitLab writes `suggestion` too, and
    /// optionally `suggestion:-2+3` — replace two lines above the anchor and
    /// three below. Anything else, including a language that merely starts
    /// with the word, is a normal code block.
    static func suggestedChange(fenceInfo: String?, code: String) -> SuggestedChange? {
        guard let info = fenceInfo?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        guard info == "suggestion" || info.hasPrefix("suggestion:") else { return nil }

        guard info.hasPrefix("suggestion:") else {
            return SuggestedChange(code: code, linesAbove: nil, linesBelow: nil)
        }
        // `-2+3`: a signed pair. A malformed range still produces a
        // suggestion — the code is the useful part, and refusing to render
        // it over an unparseable offset would hide the proposal.
        let range = info.dropFirst("suggestion:".count)
        let above = signedValue(in: range, sign: "-")
        let below = signedValue(in: range, sign: "+")
        return SuggestedChange(code: code, linesAbove: above, linesBelow: below)
    }

    private static func signedValue(in text: Substring, sign: Character) -> Int? {
        guard let start = text.firstIndex(of: sign) else { return nil }
        let digits = text[text.index(after: start)...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Tables

    /// Parses a table starting at `start`, or returns nil if there isn't one.
    ///
    /// A GFM table is a header row, a delimiter row whose column count
    /// matches it, and zero or more body rows. The delimiter row is the
    /// whole test — a line with pipes in it is otherwise just prose about
    /// pipes.
    static func parseTable(_ lines: [String], startingAt start: Int) -> (table: MarkdownTable, endIndex: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start]
        guard headerLine.contains("|") else { return nil }

        let headers = cells(in: headerLine)
        guard !headers.isEmpty else { return nil }
        guard let alignments = alignmentRow(lines[start + 1]), alignments.count == headers.count else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            // A blank line, or a line with no pipe, ends the table.
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            var row = cells(in: line)
            // GFM pads a short row and truncates a long one rather than
            // rejecting the table, so a bot that miscounted a column still
            // renders.
            if row.count < headers.count {
                row.append(contentsOf: Array(repeating: "", count: headers.count - row.count))
            } else if row.count > headers.count {
                row = Array(row.prefix(headers.count))
            }
            rows.append(row)
            index += 1
        }

        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), index)
    }

    /// The delimiter row's alignments, or nil when the line is not one.
    static func alignmentRow(_ line: String) -> [MarkdownTable.Alignment]? {
        let raw = cells(in: line)
        guard !raw.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in raw {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            let dashes = trimmed.dropFirst(leading ? 1 : 0).dropLast(trailing ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Splits a table row into cells on unescaped pipes.
    ///
    /// The outer pipes are optional in GFM, so an empty first or last cell
    /// produced by `|a|b|` is dropped — but an empty cell *between* pipes is
    /// real content and kept.
    static func cells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                // A `\|` is a literal pipe inside a cell, which is how a bot
                // writes a table cell containing one.
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "|":
                cells.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)

        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Hard breaks

    /// Turns single newlines into markdown hard breaks.
    ///
    /// Markdown joins consecutive lines into one paragraph; GitLab and
    /// GitHub both render a newline in a *comment* as a line break, because
    /// people write comments in lines, not paragraphs. Without this, two
    /// findings a bot wrote on separate lines arrive as one run-on
    /// sentence.
    ///
    /// Applied conservatively: only between two lines that are both plain
    /// prose. A line that starts a block construct — list item, heading,
    /// quote, table row, fence, indented code — keeps markdown's own
    /// meaning, so a list's structure and a nested item's continuation are
    /// untouched.
    static func applyHardBreaks(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.count > 1 else { return source }

        var result: [String] = []
        for (index, line) in lines.enumerated() {
            guard index + 1 < lines.count else {
                result.append(line)
                continue
            }
            let next = lines[index + 1]
            let joinsWithNext = !isBlank(line)
                && !isBlank(next)
                && !startsBlock(line)
                && !startsBlock(next)
                // Already a hard break, or an escaped one.
                && !line.hasSuffix("  ")
                && !line.hasSuffix("\\")
            result.append(joinsWithNext ? line + "  " : line)
        }
        return result.joined(separator: "\n")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether a line begins something markdown treats as its own block.
    static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        // Indented code: four spaces or a tab.
        if line.hasPrefix("    ") || line.hasPrefix("\t") { return true }
        switch first {
        case "#", ">", "|", "`", "~":
            return true
        case "-", "*", "+":
            // A list marker is a marker only when followed by a space; a
            // sentence beginning with a dash is prose, and a rule of dashes
            // is its own block either way.
            let rest = trimmed.dropFirst()
            return rest.isEmpty || rest.hasPrefix(" ") || trimmed.allSatisfy { $0 == first }
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            // "1. " or "1) " — an ordered list item.
            let digits = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(digits.count)
            return rest.hasPrefix(". ") || rest.hasPrefix(") ")
        default:
            return false
        }
    }

    // MARK: - Inline HTML

    /// Tags a comment body may carry that Foundation renders as literal
    /// text. Bot comments use them constantly — `<sub>` for a footer,
    /// `<br>` for a line break inside a table cell, `<details>` for a
    /// collapsible section.
    ///
    /// The text inside is kept and the tags are dropped: showing
    /// `<sub>Automated by Claude AI</sub>` with the angle brackets visible
    /// is worse than showing the sentence at normal size.
    private static let strippableTags = [
        "sub", "sup", "kbd", "b", "i", "em", "strong", "u", "s", "small",
        "details", "summary", "span", "div", "p", "a", "img", "picture", "source",
    ]

    static func stripInlineHTML(_ source: String) -> String {
        var result = source

        // `<br>` and `<br/>` are line breaks, and dropping them silently
        // would join two lines a bot deliberately separated.
        for pattern in ["<br>", "<br/>", "<br />", "<BR>", "<BR/>"] {
            result = result.replacingOccurrences(of: pattern, with: "\n")
        }

        // Comments, which otherwise print in full.
        result = removeRanges(in: result, from: "<!--", to: "-->")

        for tag in strippableTags {
            for form in ["<\(tag)>", "</\(tag)>", "<\(tag) />", "<\(tag)/>"] {
                result = result.replacingOccurrences(of: form, with: "", options: .caseInsensitive)
            }
            // Opening tags with attributes: `<a href="…">`, `<details open>`.
            result = removeRanges(in: result, from: "<\(tag) ", to: ">", caseInsensitive: true)
        }
        return result
    }

    /// Removes every `from…to` span, including the delimiters. Written as a
    /// scan rather than a regular expression so an unterminated opener at
    /// the end of a body is left alone instead of eating the rest of it.
    private static func removeRanges(
        in source: String, from opener: String, to closer: String, caseInsensitive: Bool = false
    ) -> String {
        var result = source
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let open = result.range(of: opener, options: options, range: searchStart..<result.endIndex) {
            guard let close = result.range(of: closer, range: open.upperBound..<result.endIndex) else {
                // No closer: leave the remainder untouched.
                break
            }
            result.removeSubrange(open.lowerBound..<close.upperBound)
            searchStart = open.lowerBound
        }
        return result
    }
}
