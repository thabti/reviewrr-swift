import Foundation

/// Turns a provider's raw text reply into an `AnalysisResult`, tolerating
/// the two most common ways a model fails to follow "JSON only": wrapping
/// the object in a Markdown code fence, or prefacing/following it with
/// prose. Semantic validation (does the JSON *mean* something valid) is
/// `AnalysisValidator`'s job, not this file's.
enum AnalysisParser {
    enum ParseError: LocalizedError, Equatable {
        case noJSONObjectFound
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noJSONObjectFound: return "No JSON object found in the response."
            case .decodingFailed(let message): return "Couldn't decode the response as reviewrr.ai-review.v1: \(message)"
            }
        }
    }

    /// Strips a wrapping ` ```json ... ``` ` (or bare ` ``` ... ``` `)
    /// fence. Leaves the text untouched when it isn't fenced.
    static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans for the first balanced `{...}` object, ignoring braces that
    /// appear inside string literals — a fallback for a response that
    /// wrapped valid JSON in explanatory prose despite instructions not to.
    static func extractJSONObject(from text: String) -> String? {
        var depth = 0
        var inString = false
        var escapeNext = false
        var startIndex: String.Index?
        for index in text.indices {
            let char = text[index]
            if inString {
                if escapeNext {
                    escapeNext = false
                } else if char == "\\" {
                    escapeNext = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { startIndex = index }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let start = startIndex {
                    return String(text[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    /// Tries, in order: the whole (fence-stripped) text as JSON, then the
    /// first balanced object found inside it. Returns the parsed result or
    /// the reason both attempts failed.
    static func parse(_ text: String) -> Result<AnalysisResult, ParseError> {
        let candidates = [stripCodeFence(text), text].compactMap { candidate -> String? in
            extractJSONObject(from: candidate) ?? (candidate.hasPrefix("{") ? candidate : nil)
        }
        guard !candidates.isEmpty else { return .failure(.noJSONObjectFound) }

        var lastError: Error?
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return .success(try JSONDecoder().decode(AnalysisResult.self, from: data))
            } catch {
                lastError = error
            }
        }
        return .failure(.decodingFailed(GitHubAPI.describe(decodingError: lastError ?? ParseError.noJSONObjectFound)))
    }
}
