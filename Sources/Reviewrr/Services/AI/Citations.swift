import Foundation

/// Turns `path/to/file.ext:123` (or `:123-140`) tokens inside AI answer
/// text into navigable citations. This is the only bridge between free-form
/// prose and the diff: Reviewrr never lets AI output become a diff
/// decoration on its own, so a citation is just a link the reviewer follows.
enum Citations {
    struct Citation: Equatable {
        var path: String
        var startLine: Int
        var endLine: Int
        /// The exact substring matched in the source text, so the UI can
        /// find and style it without re-deriving the regex match.
        var matchedText: String
    }

    // A path needs a file extension before the colon (so "10:30" — a time,
    // or a ratio — never matches) and can't start mid-word (so
    // "src/foo.go:12" inside a longer token still anchors correctly).
    private static let pattern: NSRegularExpression = {
        // swiftlint-safe: pattern is a compile-time constant, `try!` is safe.
        try! NSRegularExpression(
            pattern: #"(?<![\w/.\-])([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)*\.[A-Za-z0-9]+):(\d+)(?:-(\d+))?"#
        )
    }()

    static func extract(from text: String) -> [Citation] {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match -> Citation? in
            guard
                let pathRange = Range(match.range(at: 1), in: text),
                let startRange = Range(match.range(at: 2), in: text),
                let startLine = Int(text[startRange])
            else { return nil }
            let path = String(text[pathRange])
            let endLine: Int
            if match.range(at: 3).location != NSNotFound, let endRange = Range(match.range(at: 3), in: text) {
                endLine = Int(text[endRange]) ?? startLine
            } else {
                endLine = startLine
            }
            let matched = nsText.substring(with: match.range)
            return Citation(path: path, startLine: startLine, endLine: endLine, matchedText: matched)
        }
    }
}
