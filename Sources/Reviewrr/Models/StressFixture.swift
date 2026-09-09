import Foundation

/// A synthetic pull request large enough to measure the workspace against.
///
/// The bundled demo is eleven small files, which every part of the review
/// surface renders instantly — so it proves nothing about scrolling. Real
/// review sessions in this app run on pull requests with hundreds of changed
/// files and single files thousands of lines long, and that is where a per-row
/// cost or a redundant `body` evaluation turns into a dropped frame.
///
/// `REVIEWRR_STRESS=<files>` swaps this in for the demo fixture's file list
/// (`REVIEWRR_STRESS=1` is read as "use the default size", not "one file",
/// because a one-file stress test is not one). Off by default and never
/// reachable without the variable, so it costs a shipped run nothing.
enum StressFixture {
    static let fileCount: Int? = {
        guard let raw = ProcessInfo.processInfo.environment["REVIEWRR_STRESS"], let value = Int(raw) else { return nil }
        return value <= 1 ? 300 : value
    }()

    static var isEnabled: Bool { fileCount != nil }

    /// Built once, lazily: the first file is deliberately enormous so the
    /// diff pane opens onto the worst case rather than a typical one.
    static let files: [PRFile] = {
        guard let count = fileCount else { return [] }
        var files: [PRFile] = [
            file(index: 0, hunks: 60, linesPerHunk: 70, path: "packages/core/src/engine/Scheduler.ts")
        ]
        for index in 1..<count {
            // A spread of sizes, because a pane that is fast on 40-line files
            // and slow on 900-line ones reads as "randomly slow".
            let hunks = [4, 6, 9, 14, 22, 34][index % 6]
            files.append(file(index: index, hunks: hunks, linesPerHunk: 24))
        }
        return files
    }()

    private static func file(index: Int, hunks: Int, linesPerHunk: Int, path: String? = nil) -> PRFile {
        let filename = path ?? "packages/module\(index % 24)/src/feature/Component\(index).tsx"
        let patch = self.patch(hunks: hunks, linesPerHunk: linesPerHunk)
        let additions = hunks * linesPerHunk / 4
        let deletions = hunks * linesPerHunk / 4
        return PRFile(
            filename: filename, previousFilename: nil, status: .modified,
            additions: additions, deletions: deletions, changes: additions + deletions,
            patch: patch
        )
    }

    /// Hunks whose lines vary in width and include tabs and long identifiers:
    /// tab expansion, syntax highlighting and word-diff all scale with the
    /// content, so a patch of uniform short lines under-reports every one.
    private static func patch(hunks: Int, linesPerHunk: Int) -> String {
        var out: [String] = []
        for hunk in 0..<hunks {
            let start = hunk * (linesPerHunk + 12) + 1
            out.append("@@ -\(start),\(linesPerHunk) +\(start),\(linesPerHunk) @@ export function handler\(hunk)(request: Request)")
            for line in 0..<linesPerHunk {
                switch line % 5 {
                case 0:
                    out.append("-\tconst previous = await repository.find({ id, tenantId, includeArchived: false })")
                case 1:
                    out.append("+\tconst previous = await repository.find({ id, tenantId, includeArchived: true, trace })")
                case 2:
                    out.append("     // context line \(line) explaining why the branch below exists at all")
                case 3:
                    out.append("     if (!previous) { throw new NotFoundError(`no record for ${id} in ${tenantId}`) }")
                default:
                    out.append("     return serialize(previous, { fields: FIELDS, locale: request.locale })")
                }
            }
        }
        return out.joined(separator: "\n")
    }
}
