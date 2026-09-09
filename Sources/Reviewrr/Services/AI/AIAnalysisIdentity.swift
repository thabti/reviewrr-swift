import Foundation

/// What makes one analysis run interchangeable with another.
///
/// The one place cache identity is computed. It used to be derived
/// independently in the view model, in the analyzer, and in the cache, all
/// of which had to agree by hand — a change to the per-provider context
/// budget nearly left the lookup and the store computing different keys, so
/// every analysis would have been a miss and every reopen a fresh provider
/// call.
struct AIAnalysisIdentity: Equatable {
    var providerID: String
    var model: String
    var headSha: String
    /// Hash of the bounded context actually sent — so a different context
    /// budget, a new comment folded into the prompt, or a changed patch all
    /// miss.
    var contentHash: String
    /// Per-file patch hashes, so a run made at one revision can say which
    /// files are unchanged at the next one.
    var fileFingerprints: [String: String]

    /// Excludes `fileFingerprints`: two runs of the same content at the same
    /// revision are the same run, and the fingerprints are carried for reuse
    /// decisions rather than identity.
    var key: String {
        "\(providerID)|\(model)|\(headSha)|\(Prompts.promptVersion)|\(AnalysisResult.currentSchemaVersion)|\(contentHash)"
    }

    /// Same provider, model, prompt version, and schema version — the family
    /// within which a result from another revision can still be partly
    /// useful. Deliberately excludes head SHA and content hash.
    var lineage: String {
        "\(providerID)|\(model)|\(Prompts.promptVersion)|\(AnalysisResult.currentSchemaVersion)"
    }

    static func make(
        situation: AIReviewSituation, providerID: String, model: String, context: Prompts.BoundedContext
    ) -> AIAnalysisIdentity {
        AIAnalysisIdentity(
            providerID: providerID, model: model, headSha: situation.headSha,
            contentHash: context.contentHash, fileFingerprints: situation.fileFingerprints()
        )
    }

    /// The identity of a heuristic run: no provider, no model, so it never
    /// collides with a real one and never gets reused as one.
    static func heuristic(situation: AIReviewSituation, context: Prompts.BoundedContext) -> AIAnalysisIdentity {
        AIAnalysisIdentity(
            providerID: HeuristicAnalyzer.agentID, model: "", headSha: situation.headSha,
            contentHash: context.contentHash, fileFingerprints: situation.fileFingerprints()
        )
    }
}
