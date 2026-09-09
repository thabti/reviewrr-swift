import Foundation

/// Parses a single GitHub unified-diff `patch` string (as returned on a
/// changed-file object) into typed hunks and numbered lines.
enum DiffParser {
    private static let hunkHeaderPattern = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$"#
    )

    /// Count of unmodified source lines hidden immediately before
    /// `hunks[index]` (or before the first hunk when `index == 0`). Derived
    /// purely from hunk headers, so it's known before fetching file content.
    static func gapSize(beforeHunkIndex index: Int, hunks: [DiffHunk]) -> Int {
        guard index < hunks.count else { return 0 }
        let startAfterPrevious = index > 0 ? (hunks[index - 1].newStart + hunks[index - 1].newCount) : 1
        return max(0, hunks[index].newStart - startAfterPrevious)
    }

    /// Reconstructs the hidden context lines for that same gap from the
    /// full head-revision file content, so "Show N unmodified lines" can
    /// expand in place without re-fetching the whole diff.
    static func gapLines(beforeHunkIndex index: Int, hunks: [DiffHunk], fullLines: [String]) -> [DiffLine] {
        guard index < hunks.count else { return [] }
        let previous = index > 0 ? hunks[index - 1] : nil
        let newStart = previous.map { $0.newStart + $0.newCount } ?? 1
        let newEnd = hunks[index].newStart - 1
        guard newStart <= newEnd, newStart >= 1, newEnd <= fullLines.count else { return [] }
        let offset = previous.map { ($0.newStart + $0.newCount) - ($0.oldStart + $0.oldCount) } ?? 0

        var result: [DiffLine] = []
        var id = -((index + 1) * 1_000_000)
        for newLine in newStart...newEnd {
            result.append(
                DiffLine(id: id, kind: .context, oldLineNumber: newLine - offset, newLineNumber: newLine, text: fullLines[newLine - 1])
            )
            id -= 1
        }
        return result
    }

    static func parse(filename: String, patch: String?) -> ParsedFile {
        guard let patch, !patch.isEmpty else {
            return ParsedFile(filename: filename, hunks: [])
        }

        var hunks: [DiffHunk] = []
        var hunkID = 0
        var lineID = 0

        var currentHeader: String?
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var oldLine = 0, newLine = 0
        var lines: [DiffLine] = []

        func closeHunk() {
            guard let header = currentHeader else { return }
            hunks.append(
                DiffHunk(
                    id: hunkID, header: header, oldStart: oldStart, oldCount: oldCount,
                    newStart: newStart, newCount: newCount, lines: lines
                )
            )
            hunkID += 1
            lines = []
            currentHeader = nil
        }

        // `patch.split` gives `Substring`s into the original patch string;
        // working on those directly (prefix checks, `dropFirst`) avoids
        // wrapping every single line in a fresh `String` just to throw most
        // of those copies away — only the text that actually ends up in a
        // `DiffLine` gets copied into its own `String`, once.
        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            // A patch's content lines vastly outnumber its hunk headers, and
            // `NSRegularExpression` needs UTF-16 bridging to run at all — so
            // only pay for the bridge-and-match on lines that could plausibly
            // be one, rather than on every line in the file.
            if rawLine.hasPrefix("@@") {
                let line = String(rawLine)
                let full = NSRange(line.startIndex..., in: line)
                if let match = hunkHeaderPattern.firstMatch(in: line, range: full) {
                    closeHunk()
                    oldStart = match.intValue(in: line, at: 1) ?? 0
                    oldCount = match.intValue(in: line, at: 2) ?? 1
                    newStart = match.intValue(in: line, at: 3) ?? 0
                    newCount = match.intValue(in: line, at: 4) ?? 1
                    oldLine = oldStart
                    newLine = newStart
                    currentHeader = line
                    // A fresh hunk's line count is bounded by its header's
                    // own counts — reserving up front avoids the repeated
                    // doubling-reallocation an unbounded `append` loop would
                    // otherwise do across ~60 lines per hunk.
                    lines.reserveCapacity(oldCount + newCount)
                    continue
                }
            }

            guard currentHeader != nil else { continue }
            if rawLine.hasPrefix("\\ No newline at end of file") { continue }

            if rawLine.hasPrefix("+") {
                lines.append(DiffLine(id: lineID, kind: .addition, oldLineNumber: nil, newLineNumber: newLine, text: String(rawLine.dropFirst())))
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                lines.append(DiffLine(id: lineID, kind: .deletion, oldLineNumber: oldLine, newLineNumber: nil, text: String(rawLine.dropFirst())))
                oldLine += 1
            } else {
                let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : String(rawLine)
                lines.append(DiffLine(id: lineID, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: text))
                oldLine += 1
                newLine += 1
            }
            lineID += 1
        }
        closeHunk()

        return ParsedFile(filename: filename, hunks: hunks)
    }
}

private extension NSTextCheckingResult {
    func intValue(in string: String, at index: Int) -> Int? {
        guard index < numberOfRanges, let range = Range(self.range(at: index), in: string), !range.isEmpty else { return nil }
        return Int(string[range])
    }
}
