import Foundation

/// Semantic checks beyond what `Decodable` already enforces: the rules from
/// "Required semantics" in `docs/architecture/ai-review-result-v1.md` that
/// aren't expressible as Swift types (uniqueness, cross-field consistency,
/// the revision the result claims to describe).
enum AnalysisValidator {
    /// Empty means valid. A non-empty result triggers exactly one repair
    /// attempt in `PRAnalyzer`, never more.
    static func validate(_ result: AnalysisResult, expectedHeadSha: String) -> [String] {
        var errors: [String] = []

        if result.schemaVersion != AnalysisResult.currentSchemaVersion {
            errors.append("schemaVersion must equal \"\(AnalysisResult.currentSchemaVersion)\", got \"\(result.schemaVersion)\"")
        }
        if result.scope.headSha != expectedHeadSha {
            errors.append("scope.headSha (\"\(result.scope.headSha)\") must equal the revision being analyzed (\"\(expectedHeadSha)\")")
        }
        if result.overview.title.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("overview.title must not be empty")
        }

        var seenReviewOrderPaths = Set<String>()
        for item in result.reviewOrder {
            if item.priority <= 0 {
                errors.append("reviewOrder priority for \"\(item.path)\" must be a positive integer, got \(item.priority)")
            }
            if !seenReviewOrderPaths.insert(item.path).inserted {
                errors.append("reviewOrder has a duplicate path \"\(item.path)\"")
            }
        }

        var seenFileSummaryPaths = Set<String>()
        for item in result.fileSummaries {
            if !seenFileSummaryPaths.insert(item.path).inserted {
                errors.append("fileSummaries has a duplicate path \"\(item.path)\"")
            }
        }

        let analyzedFiles = Set(result.scope.analyzedFiles)
        var seenFindingIDs = Set<String>()
        for finding in result.findings {
            if finding.id.isEmpty {
                errors.append("a finding is missing its id")
            } else if !seenFindingIDs.insert(finding.id).inserted {
                errors.append("findings has a duplicate id \"\(finding.id)\"")
            }
            if !(0...1).contains(finding.confidence) {
                errors.append("finding \"\(finding.id)\" confidence must be between 0 and 1, got \(finding.confidence)")
            }

            let anchorFields = [finding.path != nil, finding.side != nil, finding.startLine != nil, finding.endLine != nil]
            let anchorCount = anchorFields.filter { $0 }.count
            if anchorCount != 0 && anchorCount != anchorFields.count {
                errors.append("finding \"\(finding.id)\" must set path/side/startLine/endLine all together or all to null")
            } else if anchorCount == anchorFields.count {
                if let path = finding.path, !analyzedFiles.isEmpty, !analyzedFiles.contains(path) {
                    errors.append("finding \"\(finding.id)\" anchors to \"\(path)\", which is not in scope.analyzedFiles")
                }
                if let start = finding.startLine, let end = finding.endLine, start > end {
                    errors.append("finding \"\(finding.id)\" has startLine (\(start)) greater than endLine (\(end))")
                }
            }
        }

        return errors
    }
}
