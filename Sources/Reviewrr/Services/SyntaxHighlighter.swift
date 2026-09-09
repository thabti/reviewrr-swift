import SwiftUI

/// A dependency-free, per-line syntax highlighter. It is a keyword/regex
/// scanner rather than a real tokenizer with grammar state, and it never
/// looks at neighboring lines — a `/* … */` block spanning lines the
/// reviewer hasn't scrolled to won't be perfectly colored. That trade-off
/// is what makes it safe to run per-row inside a virtualized diff: no
/// shared lexer state to thread through thousands of independent rows.
enum SyntaxHighlighter {
    enum TokenClass {
        case keyword, type, string, number, comment, attribute, punctuation
    }

    /// Every token class carries a light and a dark value, resolved at draw
    /// time by `Theme.dynamic`. A single tuned triple cannot serve both: a
    /// pastel that reads well on a dark editor background drops well below
    /// contrast minimums on a white one.
    // Resolved once and reused. A dynamic color is a live object rather
    // than a value, so building one per token would allocate on every line
    // of every file — and two separately-built ones never compare equal.
    private static let keywordColor = Theme.dynamic(light: 0.81, 0.13, 0.18, dark: 0.90, 0.45, 0.65)
    private static let typeColor = Theme.dynamic(light: 0.44, 0.26, 0.76, dark: 0.55, 0.80, 0.85)
    private static let stringColor = Theme.dynamic(light: 0.04, 0.19, 0.41, dark: 0.78, 0.55, 0.42)
    private static let numberColor = Theme.dynamic(light: 0.02, 0.31, 0.68, dark: 0.60, 0.75, 0.95)
    private static let commentColor = Color(nsColor: .systemGray)
    private static let attributeColor = Theme.dynamic(light: 0.58, 0.22, 0.0, dark: 0.65, 0.70, 0.45)
    private static let punctuationColor = Color.secondary.opacity(0.7)

    static func color(for token: TokenClass) -> Color {
        switch token {
        case .keyword: return keywordColor
        case .type: return typeColor
        case .string: return stringColor
        case .number: return numberColor
        case .comment: return commentColor
        case .attribute: return attributeColor
        case .punctuation: return punctuationColor
        }
    }

    private struct LanguageSpec {
        var keywords: Set<String> = []
        var types: Set<String> = []
        /// Prefixes that start a line (or trailing) comment, e.g. "//", "#".
        var lineComment: [String] = []
        /// (open, close) delimiter pairs for a same-line block comment.
        var blockComment: [(String, String)] = []
        var stringDelimiters: Set<Character> = ["\"", "'"]
        /// Extra regex passes applied after comment/string/number/keyword,
        /// for things a generic scanner can't express (decorators, sigils,
        /// tag names…). Applied in order; later ones don't overwrite ranges
        /// already claimed by an earlier pass.
        var extraPatterns: [(pattern: String, token: TokenClass, caseInsensitive: Bool)] = []
        var keywordsCaseInsensitive: Bool = false
        var capitalizedIdentifierIsType: Bool = true
        var hexNumbers: Bool = false
    }

    private static let plainSpec = LanguageSpec()

    private static let specs: [String: LanguageSpec] = [
        "swift": LanguageSpec(
            keywords: [
                "func", "var", "let", "if", "else", "guard", "return", "struct", "class", "enum",
                "protocol", "extension", "import", "for", "in", "while", "repeat", "switch", "case",
                "default", "private", "public", "internal", "fileprivate", "open", "static", "final",
                "self", "Self", "super", "true", "false", "nil", "throws", "rethrows", "throw", "try",
                "catch", "async", "await", "actor", "init", "deinit", "as", "is", "some", "any",
                "where", "typealias", "associatedtype", "mutating", "nonmutating", "override",
                "lazy", "weak", "unowned", "indirect", "inout", "operator", "defer", "break",
                "continue", "willSet", "didSet", "get", "set", "convenience", "required", "dynamic",
            ],
            types: ["Int", "Double", "Float", "String", "Bool", "Character", "Array", "Dictionary",
                    "Set", "Optional", "Void", "Any", "AnyObject", "Never", "Result"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\""],
            extraPatterns: [(#"@\w+"#, .attribute, false)]
        ),
        "typescript": LanguageSpec(
            keywords: [
                "function", "const", "let", "var", "if", "else", "return", "class", "interface",
                "type", "import", "export", "for", "of", "in", "while", "do", "switch", "case",
                "default", "private", "public", "protected", "static", "this", "true", "false",
                "null", "undefined", "throw", "try", "catch", "finally", "async", "await", "new",
                "extends", "implements", "as", "from", "enum", "namespace", "declare", "readonly",
                "abstract", "satisfies", "typeof", "instanceof", "void", "delete", "yield", "get", "set",
            ],
            types: ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\"", "'", "`"],
            extraPatterns: [(#"@\w+"#, .attribute, false)]
        ),
        "go": LanguageSpec(
            keywords: [
                "func", "var", "const", "if", "else", "return", "struct", "interface", "import",
                "package", "for", "range", "switch", "case", "default", "go", "chan", "select",
                "defer", "true", "false", "nil", "type", "map", "make", "new", "fallthrough", "goto",
            ],
            types: ["bool", "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8",
                    "uint16", "uint32", "uint64", "float32", "float64", "byte", "rune", "error", "any"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\"", "`"]
        ),
        "rust": LanguageSpec(
            keywords: [
                "fn", "let", "mut", "const", "static", "if", "else", "match", "loop", "while", "for",
                "in", "return", "struct", "enum", "trait", "impl", "pub", "use", "mod", "crate",
                "self", "Self", "super", "where", "as", "move", "ref", "dyn", "async", "await",
                "unsafe", "extern", "true", "false",
            ],
            types: ["i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f32",
                    "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\""],
            extraPatterns: [(#"#\[.*?\]"#, .attribute, false)]
        ),
        "python": LanguageSpec(
            keywords: [
                "def", "class", "if", "elif", "else", "return", "import", "from", "for", "in",
                "while", "with", "as", "try", "except", "finally", "raise", "True", "False", "None",
                "lambda", "yield", "async", "await", "pass", "break", "continue", "self", "global",
                "nonlocal", "not", "and", "or", "is", "del", "assert", "match", "case",
            ],
            lineComment: ["#"], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"@\w+(\.\w+)*"#, .attribute, false)]
        ),
        "ruby": LanguageSpec(
            keywords: [
                "def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when",
                "while", "until", "for", "in", "do", "begin", "rescue", "ensure", "raise", "return",
                "yield", "self", "nil", "true", "false", "require", "require_relative",
                "attr_accessor", "attr_reader", "attr_writer", "private", "public", "protected",
                "module_function", "lambda", "proc", "and", "or", "not",
            ],
            lineComment: ["#"], blockComment: [("=begin", "=end")], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#":\w+"#, .attribute, false)]
        ),
        "java": LanguageSpec(
            keywords: [
                "public", "private", "protected", "class", "interface", "extends", "implements",
                "static", "final", "abstract", "void", "new", "return", "if", "else", "for", "while",
                "do", "switch", "case", "default", "break", "continue", "try", "catch", "finally",
                "throw", "throws", "import", "package", "this", "super", "null", "true", "false",
                "enum", "synchronized", "volatile", "transient", "instanceof",
            ],
            types: ["int", "long", "short", "byte", "double", "float", "boolean", "char", "String",
                    "Object", "List", "Map", "Set", "Void"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\""],
            extraPatterns: [(#"@\w+"#, .attribute, false)]
        ),
        "kotlin": LanguageSpec(
            keywords: [
                "fun", "val", "var", "if", "else", "when", "for", "while", "do", "return", "class",
                "interface", "object", "is", "as", "in", "override", "open", "private", "protected",
                "public", "internal", "companion", "data", "sealed", "enum", "null", "true", "false",
                "try", "catch", "finally", "throw", "import", "package", "this", "super", "suspend",
                "inline", "reified", "out", "vararg", "lateinit", "by", "init", "abstract",
            ],
            types: ["Int", "Long", "Short", "Byte", "Double", "Float", "Boolean", "Char", "String",
                    "Unit", "Any", "List", "Map", "Set"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\""],
            extraPatterns: [(#"@\w+"#, .attribute, false)]
        ),
        "php": LanguageSpec(
            keywords: [
                "function", "public", "private", "protected", "static", "class", "interface",
                "trait", "extends", "implements", "if", "else", "elseif", "foreach", "for", "while",
                "do", "switch", "case", "default", "break", "continue", "return", "echo", "print",
                "require", "require_once", "include", "include_once", "namespace", "use", "new",
                "try", "catch", "finally", "throw", "null", "true", "false", "global", "const",
                "abstract", "final", "instanceof", "match",
            ],
            lineComment: ["//", "#"], blockComment: [("/*", "*/")], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"\$\w+"#, .attribute, false)]
        ),
        "c": LanguageSpec(
            keywords: [
                "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
                "return", "struct", "typedef", "enum", "union", "static", "const", "volatile",
                "extern", "sizeof", "void", "inline", "goto", "class", "public", "private",
                "protected", "namespace", "template", "new", "delete", "this", "virtual", "override",
                "using", "nullptr", "true", "false", "auto", "constexpr",
            ],
            types: ["int", "char", "float", "double", "long", "short", "unsigned", "signed", "bool",
                    "size_t", "id", "NSString", "NSArray", "NSDictionary", "NSObject"],
            lineComment: ["//"], blockComment: [("/*", "*/")], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"@\w+"#, .attribute, false)], hexNumbers: true
        ),
        "shell": LanguageSpec(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case",
                "esac", "function", "return", "local", "export", "readonly", "shift", "exit",
                "source", "alias", "unset", "trap", "echo",
            ],
            lineComment: ["#"], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"\$\{?\w+\}?"#, .attribute, false)]
        ),
        "sql": LanguageSpec(
            keywords: [
                "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
                "create", "table", "alter", "drop", "join", "left", "right", "inner", "outer", "on",
                "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null",
                "is", "in", "exists", "distinct", "union", "all", "case", "when", "then", "else",
                "end", "primary", "key", "foreign", "references", "default", "index", "view", "with",
            ],
            lineComment: ["--"], blockComment: [("/*", "*/")], stringDelimiters: ["'"],
            keywordsCaseInsensitive: true, capitalizedIdentifierIsType: false
        ),
        "json": LanguageSpec(
            keywords: ["true", "false", "null"], stringDelimiters: ["\""],
            extraPatterns: [(#""[^"]*"\s*(?=:)"#, .attribute, false)],
            capitalizedIdentifierIsType: false
        ),
        "yaml": LanguageSpec(
            keywords: ["true", "false", "null", "yes", "no"], lineComment: ["#"],
            stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"^\s*[\w.\-\/]+(?=:)"#, .attribute, false)],
            capitalizedIdentifierIsType: false
        ),
        "toml": LanguageSpec(
            keywords: ["true", "false"], lineComment: ["#"], stringDelimiters: ["\"", "'"],
            extraPatterns: [(#"^\s*[\w.\-]+(?=\s*=)"#, .attribute, false), (#"^\s*\[.*\]\s*$"#, .type, false)],
            capitalizedIdentifierIsType: false
        ),
        "markdown": LanguageSpec(
            extraPatterns: [
                (#"^#{1,6}\s.*$"#, .keyword, false),
                (#"`[^`]+`"#, .string, false),
                (#"\*\*[^*]+\*\*|__[^_]+__"#, .attribute, false),
                (#"\[[^\]]*\]\([^)]*\)"#, .type, false),
            ],
            capitalizedIdentifierIsType: false
        ),
        "html": LanguageSpec(
            blockComment: [("<!--", "-->")], stringDelimiters: ["\"", "'"],
            extraPatterns: [
                (#"</?[A-Za-z][\w-]*"#, .type, false),
                (#"[a-zA-Z-]+(?=\=)"#, .attribute, false),
            ],
            capitalizedIdentifierIsType: false
        ),
        "css": LanguageSpec(
            blockComment: [("/*", "*/")], stringDelimiters: ["\"", "'"],
            extraPatterns: [
                (#"[a-zA-Z-]+(?=\s*:)"#, .attribute, false),
                (#"@[\w-]+"#, .keyword, false),
                (#"\.[\w-]+|#[\w-]+"#, .type, false),
            ],
            capitalizedIdentifierIsType: false
        ),
    ]

    static func language(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "typescript"
        case "go": return "go"
        case "rs": return "rust"
        case "py": return "python"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return "c"
        case "sh", "bash", "zsh": return "shell"
        case "sql": return "sql"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml": return "toml"
        case "md", "mdx": return "markdown"
        case "html", "htm": return "html"
        case "css", "scss", "sass", "less": return "css"
        default: return "plain"
        }
    }

    /// Above this length, highlighting isn't worth its cost — a minified
    /// bundle or a single-line generated JSON blob is exactly the case
    /// that would make regex scanning expensive, and it's the least useful
    /// place to show syntax color anyway.
    static let maxHighlightLineLength = 2000

    /// Everything a line pass needs, pre-built exactly once. The raw
    /// `LanguageSpec` table above is the readable source of truth (kept
    /// as-is so the per-language data stays easy to scan and edit); this
    /// is the form the hot path actually runs against.
    ///
    /// The `NSRegularExpression`s here used to be constructed fresh inside
    /// `highlight(_:language:)` — once per pattern, per line. The Swift spec
    /// alone joins ~60 keywords into one alternation; compiling that (and
    /// half a dozen smaller patterns) 400 times for a 400-line diff was the
    /// dominant cost behind the old ~103ms benchmark. Building the table
    /// once via `static let` (Swift guarantees a single, thread-safe
    /// initialization) turns that into a one-time cost independent of how
    /// many lines get highlighted.
    private struct CompiledLanguageSpec {
        let keywords: Set<String>
        let types: Set<String>
        let lineComment: [String]
        let lineCommentFirstChars: Set<Character>
        let blockComment: [(open: String, close: String)]
        let blockCommentFirstChars: Set<Character>
        let stringDelimiters: Set<Character>
        let keywordsCaseInsensitive: Bool
        let capitalizedIdentifierIsType: Bool
        let hexNumbers: Bool
        /// Patterns a generic scanner can't express (decorators, CSS
        /// selectors, Markdown syntax, YAML/TOML keys…) — still regex, but
        /// compiled once here rather than per line.
        let extraPatterns: [(regex: NSRegularExpression, token: TokenClass)]

        init(_ spec: LanguageSpec) {
            keywords = spec.keywordsCaseInsensitive ? Set(spec.keywords.map { $0.lowercased() }) : spec.keywords
            types = spec.types
            lineComment = spec.lineComment
            lineCommentFirstChars = Set(spec.lineComment.compactMap(\.first))
            blockComment = spec.blockComment.map { (open: $0.0, close: $0.1) }
            blockCommentFirstChars = Set(spec.blockComment.compactMap { $0.0.first })
            stringDelimiters = spec.stringDelimiters
            keywordsCaseInsensitive = spec.keywordsCaseInsensitive
            capitalizedIdentifierIsType = spec.capitalizedIdentifierIsType
            hexNumbers = spec.hexNumbers
            extraPatterns = spec.extraPatterns.compactMap { extra in
                var options: NSRegularExpression.Options = []
                if extra.caseInsensitive { options.insert(.caseInsensitive) }
                guard let regex = try? NSRegularExpression(pattern: extra.pattern, options: options) else { return nil }
                return (regex, extra.token)
            }
        }
    }

    private static let compiledSpecs: [String: CompiledLanguageSpec] = specs.mapValues(CompiledLanguageSpec.init)
    private static let compiledPlainSpec = CompiledLanguageSpec(plainSpec)

    static func highlight(_ line: String, language: String) -> AttributedString {
        var result = AttributedString(line)
        guard language != "plain", !line.isEmpty, line.count <= maxHighlightLineLength else { return result }
        let spec = compiledSpecs[language] ?? compiledPlainSpec

        // Ranges already assigned a color, in the order they were assigned.
        // The hand-scan below never revisits a character twice so it never
        // needs to consult this list; only the `extraPatterns` regex pass
        // afterward (which searches the whole line independently) checks it,
        // exactly as the old all-regex implementation did.
        var claimed: [Range<String.Index>] = []

        func paint(_ range: Range<String.Index>, as token: TokenClass) {
            guard !range.isEmpty else { return }
            claimed.append(range)
            if let attrRange = Range(range, in: result) {
                result[attrRange].foregroundColor = color(for: token)
            }
        }

        scanTokens(line, spec: spec, paint: paint)

        if !spec.extraPatterns.isEmpty {
            let full = NSRange(line.startIndex..., in: line)
            for extra in spec.extraPatterns {
                extra.regex.enumerateMatches(in: line, range: full) { match, _, _ in
                    guard let match, let range = Range(match.range, in: line), !range.isEmpty else { return }
                    guard !claimed.contains(where: { range.overlaps($0) }) else { return }
                    paint(range, as: extra.token)
                }
            }
        }

        return result
    }

    /// A single left-to-right pass that does the job the old code did with
    /// five separate whole-line `NSRegularExpression` scans (line comments,
    /// block comments, strings, numbers, keywords/types): every character
    /// is visited once, classified, and the whole token it belongs to is
    /// consumed in one step. No `NSRange`/UTF-16 bridging and no regex
    /// engine runs for any of this — plain `String.Index` scanning over
    /// the line's own `Character`s.
    private static func scanTokens(_ line: String, spec: CompiledLanguageSpec, paint: (Range<String.Index>, TokenClass) -> Void) {
        var i = line.startIndex
        let end = line.endIndex

        while i < end {
            let c = line[i]

            if spec.lineCommentFirstChars.contains(c),
               spec.lineComment.contains(where: { line[i...].hasPrefix($0) }) {
                // Nothing after a line comment marker can be anything else.
                paint(i..<end, .comment)
                return
            }

            if spec.blockCommentFirstChars.contains(c),
               let pair = spec.blockComment.first(where: { line[i...].hasPrefix($0.open) }) {
                let afterOpen = line.index(i, offsetBy: pair.open.count)
                if let closeRange = line.range(of: pair.close, range: afterOpen..<end) {
                    paint(i..<closeRange.upperBound, .comment)
                    i = closeRange.upperBound
                    continue
                }
                // No closing delimiter on this line: the old regex required
                // a literal close to match at all, so — same as there —
                // this position is left unstyled and scanning falls through
                // to treat it character by character.
            }

            if spec.stringDelimiters.contains(c) {
                if let closeIndex = findStringEnd(in: line, delimiter: c, from: line.index(after: i), end: end) {
                    paint(i..<closeIndex, .string)
                    i = closeIndex
                    continue
                }
                // Unterminated string on this line: same fallback as above.
            }

            if c.isNumber, let numberEnd = scanNumber(in: line, from: i, end: end, hex: spec.hexNumbers) {
                paint(i..<numberEnd, .number)
                i = numberEnd
                continue
            }

            if c.isWordCharacter {
                let wordEnd = scanWordRun(in: line, from: i, end: end)
                classify(line[i..<wordEnd], spec: spec, range: i..<wordEnd, paint: paint)
                i = wordEnd
                continue
            }

            i = line.index(after: i)
        }
    }

    /// Classifies one already-scanned identifier-shaped run: exact keyword,
    /// then exact type, then (for languages where it applies) the
    /// capitalized-identifier-as-type fallback — the same priority order
    /// the old sequential regex passes applied, just decided once per token
    /// instead of via three separate full-line scans.
    private static func classify(_ word: Substring, spec: CompiledLanguageSpec, range: Range<String.Index>, paint: (Range<String.Index>, TokenClass) -> Void) {
        let key = String(word)
        if spec.keywords.contains(spec.keywordsCaseInsensitive ? key.lowercased() : key) {
            paint(range, .keyword)
            return
        }
        if spec.types.contains(key) {
            paint(range, .type)
            return
        }
        if spec.capitalizedIdentifierIsType, let first = word.first, first.isASCIIUppercaseLetter {
            paint(range, .type)
        }
    }

    private static func scanWordRun(in line: String, from start: String.Index, end: String.Index) -> String.Index {
        var i = line.index(after: start)
        while i < end, line[i].isWordCharacter { i = line.index(after: i) }
        return i
    }

    /// Mirrors `delim(?:[^delim\\]|\\.)*delim`: any run of non-delimiter,
    /// non-backslash characters, or a backslash-escaped pair, until a bare
    /// delimiter closes the string. Returns `nil` (unterminated) exactly
    /// when that regex would fail to find a literal closing delimiter.
    private static func findStringEnd(in line: String, delimiter: Character, from start: String.Index, end: String.Index) -> String.Index? {
        var i = start
        while i < end {
            let ch = line[i]
            if ch == "\\" {
                let next = line.index(after: i)
                guard next < end else { return nil }
                i = line.index(after: next)
            } else if ch == delimiter {
                return line.index(after: i)
            } else {
                i = line.index(after: i)
            }
        }
        return nil
    }

    /// Mirrors `\b0[xX][0-9a-fA-F]+\b|\b\d+\.?\d*(?:[eE][+-]?\d+)?\b`. The
    /// trailing `\b` in that pattern can, in principle, send a regex engine
    /// backtracking to a shorter match — but only the exact digit run this
    /// scan already finds is ever a candidate boundary: every position
    /// inside a maximal run of word characters borders another word
    /// character, so no shorter prefix could satisfy `\b` where the full
    /// run doesn't either. Failing the trailing check and giving up (rather
    /// than trying shorter alternatives) reaches the same answer.
    private static func scanNumber(in line: String, from start: String.Index, end: String.Index, hex: Bool) -> String.Index? {
        if hex, line[start] == "0" {
            let afterZero = line.index(after: start)
            if afterZero < end, line[afterZero] == "x" || line[afterZero] == "X" {
                var j = line.index(after: afterZero)
                let hexDigitsStart = j
                while j < end, line[j].isHexDigit { j = line.index(after: j) }
                if j > hexDigitsStart, isTokenBoundary(at: j, end: end, line: line) {
                    return j
                }
            }
        }

        var j = start
        while j < end, line[j].isNumber { j = line.index(after: j) }
        if j < end, line[j] == "." {
            j = line.index(after: j)
            while j < end, line[j].isNumber { j = line.index(after: j) }
        }
        if j < end, line[j] == "e" || line[j] == "E" {
            var k = line.index(after: j)
            if k < end, line[k] == "+" || line[k] == "-" { k = line.index(after: k) }
            if k < end, line[k].isNumber {
                while k < end, line[k].isNumber { k = line.index(after: k) }
                j = k
            }
        }
        guard isTokenBoundary(at: j, end: end, line: line) else { return nil }
        return j
    }

    private static func isTokenBoundary(at index: String.Index, end: String.Index, line: String) -> Bool {
        index >= end || !line[index].isWordCharacter
    }
}

/// Applies word-level (not character-level) intra-line highlighting: given
/// a paired deletion/addition line, finds the common leading and trailing
/// tokens and reports only the differing span in the middle — the same
/// "trim the common ends" approach GitHub's own split diff uses, chosen
/// over a full LCS/Myers diff because it's O(n) and good enough for the
/// overwhelmingly common case of a single changed identifier or literal.
enum WordDiff {
    /// Above this length, computing (and rendering) an intra-line diff
    /// costs more than it's worth — long lines are usually generated or
    /// minified, exactly where a word-level highlight is least useful.
    static let maxLineLength = 400

    /// Splits into maximal runs of word characters or single non-word
    /// characters. Concatenating the result always reconstructs `line`
    /// exactly, so ranges derived from tokens are safe to slice back out.
    static func tokenize(_ line: String) -> [Substring] {
        guard !line.isEmpty else { return [] }
        var tokens: [Substring] = []
        var start = line.startIndex
        var isWord = line[start].isWordCharacter
        var index = line.index(after: start)
        while index < line.endIndex {
            let currentIsWord = line[index].isWordCharacter
            if currentIsWord != isWord {
                tokens.append(line[start..<index])
                start = index
                isWord = currentIsWord
            }
            index = line.index(after: index)
        }
        tokens.append(line[start..<line.endIndex])
        return tokens
    }

    /// The changed span on each side of a replace pair, or `nil` for a side
    /// that has nothing left to highlight once the common prefix/suffix is
    /// trimmed (including "skipped, lines too long" and "identical").
    static func changedRanges(old: String, new: String) -> (old: Range<String.Index>?, new: Range<String.Index>?) {
        guard old != new else { return (nil, nil) }
        guard old.count <= maxLineLength, new.count <= maxLineLength else { return (nil, nil) }

        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)

        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count, oldTokens[prefix] == newTokens[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix] == newTokens[newTokens.count - 1 - suffix] {
            suffix += 1
        }

        func range(in tokens: [Substring]) -> Range<String.Index>? {
            guard prefix < tokens.count - suffix else { return nil }
            return tokens[prefix].startIndex..<tokens[tokens.count - 1 - suffix].endIndex
        }

        return (range(in: oldTokens), range(in: newTokens))
    }
}

private extension Character {
    var isWordCharacter: Bool { isLetter || isNumber || self == "_" }
    /// Matches regex `[A-Z]` exactly (ASCII only) — the capitalized-
    /// identifier-as-type fallback never treated other Unicode uppercase
    /// letters as a type marker, and this keeps that unchanged.
    var isASCIIUppercaseLetter: Bool { self >= "A" && self <= "Z" }
}

/// Off-main-actor cache for the two per-row rendering computations (syntax
/// highlighting, word-level diff spans), keyed by file path + the diff
/// line's own id + side. A 200-file PR means thousands of rows; computing
/// and caching on an actor keeps that work off the main thread and means
/// scrolling back to an already-seen line is a dictionary lookup, not a
/// re-scan.
actor SyntaxHighlightCache {
    static let shared = SyntaxHighlightCache()

    private struct LineKey: Hashable {
        let path: String
        let lineID: Int
        let side: DiffSide?
    }

    /// Bounds each cache to a few thousand entries. The pane holds one file
    /// at a time, so the working set is that file's lines plus whatever the
    /// reviewer scrolls back through — comfortably inside this, where a
    /// concatenation of every file in a large pull request was not. A
    /// fixed-size ring of keys tracks insertion order so eviction is O(1);
    /// a growing array's `removeFirst()` would be O(n) per insert once the
    /// cache is full, which would itself become a hot-path cost.
    private static let capacity = 4000

    private var highlighted: [LineKey: AttributedString] = [:]
    private var highlightedRing: [LineKey?] = Array(repeating: nil, count: capacity)
    private var highlightedCursor = 0

    private var wordDiffs: [LineKey: Range<String.Index>?] = [:]
    private var wordDiffsRing: [LineKey?] = Array(repeating: nil, count: capacity)
    private var wordDiffsCursor = 0

    func highlightedLine(path: String, lineID: Int, side: DiffSide?, text: String, language: String) -> AttributedString {
        let key = LineKey(path: path, lineID: lineID, side: side)
        if let cached = highlighted[key] { return cached }
        // The caller's `.task` is cancelled when its row is recycled, but
        // nothing here checked, so a fling through a file left this actor —
        // a single serial queue shared by every row — grinding through
        // highlighting for rows that no longer exist.
        if Task.isCancelled { return AttributedString(text) }
        let result = SyntaxHighlighter.highlight(text, language: language)
        highlighted[key] = result
        if let evicted = highlightedRing[highlightedCursor] {
            highlighted.removeValue(forKey: evicted)
        }
        highlightedRing[highlightedCursor] = key
        highlightedCursor = (highlightedCursor + 1) % Self.capacity
        return result
    }

    /// The changed span within one side of a replace row.
    ///
    /// `WordDiff.changedRanges` produces *both* sides' spans from one pass,
    /// and 98% of its cost is tokenizing the two strings. The two halves of a
    /// row were calling it separately and each discarding the half it did not
    /// need — the same tokenization twice, ~19µs of pure waste per replace
    /// row. Both results are now stored from the one pass, so whichever side
    /// asks first pays and the other is a lookup.
    func wordDiffRange(
        path: String, lineID: Int, side: DiffSide, otherLineID: Int?, text: String, otherText: String
    ) -> Range<String.Index>? {
        let key = LineKey(path: path, lineID: lineID, side: side)
        if let cached = wordDiffs[key] { return cached }
        if Task.isCancelled { return nil }

        let spans = side == .left
            ? WordDiff.changedRanges(old: text, new: otherText)
            : WordDiff.changedRanges(old: otherText, new: text)
        let own = side == .left ? spans.old : spans.new
        store(own, for: key)

        if let otherLineID {
            let otherKey = LineKey(path: path, lineID: otherLineID, side: side == .left ? .right : .left)
            if wordDiffs[otherKey] == nil {
                store(side == .left ? spans.new : spans.old, for: otherKey)
            }
        }
        return own
    }

    private func store(_ span: Range<String.Index>?, for key: LineKey) {
        wordDiffs[key] = span
        if let evicted = wordDiffsRing[wordDiffsCursor] {
            wordDiffs.removeValue(forKey: evicted)
        }
        wordDiffsRing[wordDiffsCursor] = key
        wordDiffsCursor = (wordDiffsCursor + 1) % Self.capacity
    }

    /// Cleared when a new PR loads — otherwise the cache would grow
    /// unbounded across the app's lifetime as different PRs are opened.
    func reset() {
        highlighted.removeAll()
        highlightedRing = Array(repeating: nil, count: Self.capacity)
        highlightedCursor = 0
        wordDiffs.removeAll()
        wordDiffsRing = Array(repeating: nil, count: Self.capacity)
        wordDiffsCursor = 0
    }
}
