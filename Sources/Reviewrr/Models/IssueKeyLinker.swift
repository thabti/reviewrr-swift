import Foundation

/// Rewrites bare issue keys in prose into Markdown links, so a key mentioned
/// in a description or a review comment is clickable wherever it appears.
///
/// Done as a text rewrite before the Markdown is parsed, rather than as a pass
/// over the parsed `AttributedString`, for one reason: the existing renderer
/// already knows how to draw and open a Markdown link, and this way a key in a
/// table cell, a list item or a blockquote works with no extra code.
///
/// What it must not touch is the interesting part. A key inside a code span or
/// a fenced block is code, and a key that is already a link must not be
/// wrapped twice.
enum IssueKeyLinker {
    /// `text` with every bare key turned into `[KEY](url)`.
    ///
    /// Returns the input unchanged when the tracker is off or unusable, so a
    /// caller can apply this unconditionally.
    static func linkify(_ text: String, settings: IssueTrackerSettings) -> String {
        guard settings.isUsable, !text.isEmpty else { return text }
        let detector = IssueKeyDetector(settings: settings)

        var output = ""
        output.reserveCapacity(text.count + 32)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "`":
                // A code span, however many backticks opened it. Copied
                // through untouched, up to and including its closing run — a
                // key in `EC-1013` is a literal, not a link.
                let fence = run(of: "`", in: text, from: index)
                output += text[index..<fence]
                index = fence
                if let close = closingFence(in: text, from: index, length: text.distance(from: findStart(text, fence), to: fence)) {
                    output += text[index..<close]
                    index = close
                }
            case "[":
                // An existing link, image or reference: `[label](url)`. The
                // label may itself contain a key, and wrapping a link in a
                // link produces markup nothing can render.
                if let end = endOfLink(in: text, from: index) {
                    output += text[index..<end]
                    index = end
                } else {
                    output.append(character)
                    index = text.index(after: index)
                }
            case "<":
                // An autolink, `<https://…>`.
                if let close = text[index...].firstIndex(of: ">") {
                    let end = text.index(after: close)
                    output += text[index..<end]
                    index = end
                } else {
                    output.append(character)
                    index = text.index(after: index)
                }
            default:
                // Plain prose up to the next thing worth skipping, rewritten
                // in one pass.
                let next = text[index...].firstIndex(where: { "`[<".contains($0) }) ?? text.endIndex
                output += rewrite(String(text[index..<next]), detector: detector, settings: settings)
                index = next
            }
        }
        return output
    }

    /// Replaces every key in one run of plain prose.
    private static func rewrite(
        _ prose: String,
        detector: IssueKeyDetector,
        settings: IssueTrackerSettings
    ) -> String {
        let keys = detector.keys(in: prose, source: .body)
        guard !keys.isEmpty else { return prose }
        var result = prose
        // Longest first, so `EC-10131` is never half-replaced by a rule that
        // matched `EC-1013`.
        for reference in keys.sorted(by: { $0.key.count > $1.key.count }) {
            guard let url = settings.url(for: reference.key) else { continue }
            result = replaceWholeWords(of: reference.key, in: result, with: "[\(reference.key)](\(url.absoluteString))")
        }
        return result
    }

    /// Word-boundary replacement, case-insensitive on the way in and
    /// canonical on the way out.
    ///
    /// The boundary check is what stops `EC-1013` matching inside
    /// `MYEC-1013` or `EC-10131`, which a plain string replacement would.
    private static func replaceWholeWords(of key: String, in text: String, with replacement: String) -> String {
        var result = ""
        result.reserveCapacity(text.count + replacement.count)
        var index = text.startIndex
        while let found = text.range(of: key, options: [.caseInsensitive], range: index..<text.endIndex) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isKeyCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isKeyCharacter(text[found.upperBound])
            result += text[index..<found.lowerBound]
            result += (beforeOK && afterOK) ? replacement : String(text[found])
            index = found.upperBound
        }
        result += text[index..<text.endIndex]
        return result
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    // MARK: - Skipping markup

    /// The end of a run of `character` starting at `from`.
    private static func run(of character: Character, in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] == character {
            index = text.index(after: index)
        }
        return index
    }

    private static func findStart(_ text: String, _ end: String.Index) -> String.Index {
        var index = end
        while index > text.startIndex {
            let previous = text.index(before: index)
            guard text[previous] == "`" else { break }
            index = previous
        }
        return index
    }

    /// The index just past a closing backtick run of `length`.
    private static func closingFence(in text: String, from start: String.Index, length: Int) -> String.Index? {
        guard length > 0 else { return nil }
        var index = start
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let end = run(of: "`", in: text, from: index)
            if text.distance(from: index, to: end) == length { return end }
            index = end
        }
        // An unclosed span: the rest of the text is code as far as any
        // Markdown parser is concerned, so leave it alone.
        return text.endIndex
    }

    /// The index just past `[label](destination)`, or nil when this `[` does
    /// not open one.
    private static func endOfLink(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var index = start
        var labelEnd: String.Index?
        while index < text.endIndex {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    labelEnd = index
                }
            default: break
            }
            index = text.index(after: index)
            if labelEnd != nil { break }
        }
        guard let labelEnd, index < text.endIndex, text[index] == "(" else { return nil }
        _ = labelEnd
        guard let close = text[index...].firstIndex(of: ")") else { return nil }
        return text.index(after: close)
    }
}
