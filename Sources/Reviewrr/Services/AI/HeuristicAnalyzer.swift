import Foundation

/// Produces a real `AnalysisResult` with no provider and no network call,
/// so the AI panel is useful before a reviewer configures a key: groups
/// files into rough layers, estimates risk from change size, and scans
/// added lines for a fixed set of red-flag patterns. Labeled plainly as
/// heuristic (`scope.agent == "heuristic"`, `scope.model == ""`) — the UI
/// must never present this as an AI opinion.
enum HeuristicAnalyzer {
    static let agentID = "heuristic"

    private struct PatternRule {
        let category: AnalysisCategory
        let severity: AnalysisSeverity
        let title: String
        let regex: NSRegularExpression
        let explanation: String
    }

    private static func rule(_ category: AnalysisCategory, _ severity: AnalysisSeverity, _ title: String, _ pattern: String, _ explanation: String) -> PatternRule {
        // swiftlint-safe: every pattern below is a compile-time constant.
        PatternRule(category: category, severity: severity, title: title, regex: try! NSRegularExpression(pattern: pattern), explanation: explanation)
    }

    private static let rules: [PatternRule] = [
        rule(.correctness, .blocker, "Unresolved merge-conflict marker",
             #"^(<{7}|={7}|>{7})"#,
             "A merge-conflict marker was left in the diff."),
        rule(.security, .high, "Possible hardcoded credential",
             #"(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*['"][A-Za-z0-9/_\-.]{8,}['"]"#,
             "This looks like a literal credential or secret committed to source rather than read from configuration."),
        rule(.security, .high, "Certificate/TLS verification disabled",
             #"(?i)(verify\s*=\s*False|InsecureSkipVerify\s*:?\s*=?\s*true|rejectUnauthorized\s*:\s*false|NSAllowsArbitraryLoads)"#,
             "This line appears to disable TLS certificate validation for a connection."),
        rule(.maintainability, .medium, "Use of eval",
             #"(?i)\beval\("#,
             "`eval` executes its argument as code, which is hard to review for safety and injection risk."),
        rule(.maintainability, .low, "Debug statement left in",
             #"(?i)^\s*(console\.log\(|print\(|debugger;|Debug\.Log\(|dd\(|dump\()"#,
             "This looks like a debug statement rather than intentional logging."),
        rule(.correctness, .medium, "Empty catch/except block",
             #"(?i)(catch\s*\([^)]*\)\s*\{\s*\}|except\b[^:]*:\s*pass\b)"#,
             "Swallowing an exception with no handling can hide real failures."),
        rule(.maintainability, .low, "Suppressed lint or type check",
             #"(?i)(#\s*noqa|//\s*nolint|@SuppressWarnings|eslint-disable|swiftlint:disable|#\s*type:\s*ignore)"#,
             "A suppressed check may be hiding a real issue rather than a false positive — worth a second look."),
        rule(.testing, .medium, "Focused or skipped test",
             #"(?i)\b(fdescribe|fit\(|it\.only|describe\.only|xit\(|xdescribe|@Disabled|@pytest\.mark\.skip|t\.Skip\()"#,
             "A focused (`.only`) or skipped test won't run as part of the full suite."),
    ]

    private static let hunkHeaderNewStart = try! NSRegularExpression(pattern: #"\+(\d+)"#)

    private static func layer(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("test") || lower.contains("spec") { return "Tests" }
        if lower.contains("/docs/") || lower.hasSuffix(".md") { return "Docs" }
        if lower.contains("config") || lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.hasSuffix(".json") || lower.hasSuffix(".toml") { return "Config" }
        if lower.contains("/views/") || lower.contains("/ui/") || lower.contains("component") { return "UI" }
        if lower.contains("/models/") || lower.contains("/domain/") { return "Domain" }
        if lower.contains("/services/") || lower.contains("/api/") { return "Service" }
        return "App"
    }

    private static func risk(for file: PRFile) -> AnalysisRisk {
        switch file.additions + file.deletions {
        case 0...20: return .low
        case 21...150: return .medium
        default: return .high
        }
    }

    /// Walks one file's unified-diff patch, tracking new-file line numbers
    /// from each hunk header, and matches `rules` against every added line.
    private static func scan(patch: String, path: String, nextID: () -> String) -> [AnalysisFinding] {
        var findings: [AnalysisFinding] = []
        var newLineNumber = 0
        for rawLine in patch.components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@") {
                if let match = hunkHeaderNewStart.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)),
                   let range = Range(match.range(at: 1), in: rawLine) {
                    newLineNumber = (Int(rawLine[range]) ?? 1) - 1
                }
                continue
            }
            if rawLine.hasPrefix("+++") || rawLine.hasPrefix("---") { continue }
            if rawLine.hasPrefix("+") {
                newLineNumber += 1
                let content = String(rawLine.dropFirst())
                let range = NSRange(content.startIndex..., in: content)
                for rule in rules {
                    guard rule.regex.firstMatch(in: content, range: range) != nil else { continue }
                    findings.append(AnalysisFinding(
                        id: nextID(), title: rule.title, severity: rule.severity, category: rule.category, confidence: 0.6,
                        path: path, side: .right, startLine: newLineNumber, endLine: newLineNumber,
                        evidence: content.trimmingCharacters(in: .whitespaces), explanation: rule.explanation, suggestion: nil
                    ))
                }
            } else if rawLine.hasPrefix("-") || rawLine.hasPrefix("\\") {
                continue // old-file-only line, or "\ No newline at end of file"
            } else {
                newLineNumber += 1 // context line, present in both revisions
            }
        }
        return findings
    }

    static func analyze(
        host: String, owner: String, repository: String, prNumber: Int, baseSha: String, headSha: String,
        pullRequest: PullRequest, files: [PRFile], context: Prompts.BoundedContext
    ) -> AnalysisResult {
        var fileSummaries: [AnalysisFileSummary] = []
        var reviewOrderDraft: [(path: String, risk: AnalysisRisk)] = []
        var findings: [AnalysisFinding] = []
        var findingIndex = 0
        func nextID() -> String { findingIndex += 1; return "heuristic-\(findingIndex)" }

        let analyzedSet = Set(context.analyzedFiles)
        for file in files where analyzedSet.contains(file.filename) {
            let fileLayer = layer(for: file.filename)
            let fileRisk = risk(for: file)
            fileSummaries.append(AnalysisFileSummary(
                path: file.filename, role: fileLayer,
                summary: "+\(file.additions)/-\(file.deletions) in the \(fileLayer.lowercased()) layer.",
                risk: fileRisk
            ))
            reviewOrderDraft.append((file.filename, fileRisk))
            if let patch = file.patch {
                findings.append(contentsOf: scan(patch: patch, path: file.filename, nextID: nextID))
            }
        }

        let riskOrder: [AnalysisRisk] = [.critical, .high, .medium, .low]
        let sortedOrder = reviewOrderDraft.sorted { (riskOrder.firstIndex(of: $0.risk) ?? 3) < (riskOrder.firstIndex(of: $1.risk) ?? 3) }
        let reviewOrder = sortedOrder.enumerated().map { index, entry in
            AnalysisReviewOrderItem(
                path: entry.path, priority: index + 1,
                reason: "\(entry.risk.rawValue.capitalized) estimated risk from change size and pattern-scan hits"
            )
        }

        let overallRisk: AnalysisRisk = findings.contains { $0.severity == .blocker || $0.severity == .high }
            ? .high
            : (fileSummaries.contains { $0.risk == .high } ? .medium : .low)
        let totalChanges = files.reduce(0) { $0 + $1.additions + $1.deletions }
        let effort: AnalysisReviewEffort = totalChanges > 600 ? .large : (totalChanges > 150 ? .medium : .small)

        let overview = AnalysisOverview(
            title: pullRequest.title,
            summary: "Heuristic scan of \(context.analyzedFiles.count) file(s) — no AI provider is configured.",
            intent: (pullRequest.body?.isEmpty == false) ? String(pullRequest.body!.prefix(280)) : "No description provided.",
            risk: overallRisk,
            reviewEffort: effort
        )

        let scope = AnalysisScope(
            host: host, owner: owner, repository: repository, prNumber: prNumber, baseSha: baseSha, headSha: headSha,
            agent: agentID, model: "", analysisMode: .fresh,
            analyzedFiles: context.analyzedFiles, skippedFiles: context.skippedFiles
        )

        return AnalysisResult(
            scope: scope, overview: overview, reviewOrder: reviewOrder, fileSummaries: fileSummaries,
            findings: findings, testGaps: [], architectureImpact: [], reviewerQuestions: [],
            limitations: [
                "This is a heuristic, pattern-based scan, not an AI-generated review. Configure a provider in Settings for deeper analysis.",
            ]
        )
    }
}
