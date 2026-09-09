import Foundation

/// Whether Reviewrr actually called a provider this time, or just re-served
/// a matching result — distinct from `AnalysisMode`, which describes what
/// the *agent* produced (see the doc comment on that enum).
enum AnalysisSource: Equatable {
    case cache
    case fresh
    case heuristic
}

struct AnalysisRun: Equatable {
    var outcome: AnalysisOutcome
    var source: AnalysisSource
    var providerID: String
    var model: String
    var elapsedMS: Int
    var usage: AIUsage?
    var generatedAt: Date
}

/// Orchestrates one analysis: build bounded PR context, reuse a cached
/// result when everything that would invalidate it still matches, run the
/// heuristic analyzer with no provider configured, or call a live provider
/// and take it through parse → validate → one repair attempt → validate.
enum PRAnalyzer {
    static let maxOutputTokens = 8000

    static func run(
        reference: PRReference,
        host: String,
        pullRequest: PullRequest,
        files: [PRFile],
        issueComments: [IssueComment] = [],
        reviewComments: [ReviewComment] = [],
        drafts: [DraftComment] = [],
        provider: AIProvider?,
        providerID: String,
        model: String,
        reasoningEffort: String,
        force: Bool,
        /// Tighter bound for a backend with a small window (the on-device
        /// model). Applied while the context is built, so the cache key
        /// describes exactly what was sent.
        contextBudget: AIContextBudget? = nil,
        /// The review as the module sees it. When present the system prompt
        /// is the layered one — it can then tell the model what the reviewer
        /// has already drafted, viewed, and discussed — and the cache entry
        /// records the per-file fingerprints that let a later revision reuse
        /// part of this run.
        situation: AIReviewSituation? = nil
    ) async throws -> AnalysisRun {
        let context = Prompts.buildContext(
            pullRequest: pullRequest, files: files,
            issueComments: issueComments, reviewComments: reviewComments, drafts: drafts,
            maxFileChars: contextBudget?.maxFileChars ?? Prompts.defaultMaxFileChars,
            maxTotalChars: contextBudget?.maxTotalChars ?? Prompts.defaultMaxTotalChars
        )

        let effectiveProviderID = provider == nil ? HeuristicAnalyzer.agentID : providerID
        let effectiveModel = provider == nil ? "" : model
        let identity = AIAnalysisIdentity(
            providerID: effectiveProviderID, model: effectiveModel, headSha: pullRequest.headSha,
            contentHash: context.contentHash, fileFingerprints: situation?.fileFingerprints() ?? [:]
        )
        let key = identity.key

        if !force, let cached = AnalysisCache.load(for: reference, key: key) {
            return AnalysisRun(
                outcome: cached.outcome, source: .cache, providerID: cached.providerID, model: cached.model,
                elapsedMS: cached.elapsedMS, usage: cached.usage, generatedAt: cached.generatedAt
            )
        }

        let run: AnalysisRun
        if let provider {
            run = try await runLive(
                provider: provider, providerID: providerID, model: model, reasoningEffort: reasoningEffort,
                host: host, reference: reference, pullRequest: pullRequest, context: context, situation: situation
            )
        } else {
            run = runHeuristic(host: host, reference: reference, pullRequest: pullRequest, files: files, context: context)
        }

        AnalysisCache.save(
            AnalysisCacheEntry(
                key: key, providerID: run.providerID, model: run.model, headSha: pullRequest.headSha,
                generatedAt: run.generatedAt, elapsedMS: run.elapsedMS, usage: run.usage, outcome: run.outcome,
                lineage: identity.lineage, fileFingerprints: identity.fileFingerprints
            ),
            for: reference
        )
        return run
    }

    private static func runHeuristic(
        host: String, reference: PRReference, pullRequest: PullRequest, files: [PRFile], context: Prompts.BoundedContext
    ) -> AnalysisRun {
        let start = Date()
        let result = HeuristicAnalyzer.analyze(
            host: host, owner: reference.owner, repository: reference.repo, prNumber: reference.number,
            baseSha: pullRequest.base.sha, headSha: pullRequest.headSha,
            pullRequest: pullRequest, files: files, context: context
        )
        return AnalysisRun(
            outcome: .structured(result), source: .heuristic, providerID: HeuristicAnalyzer.agentID, model: "",
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000), usage: nil, generatedAt: Date()
        )
    }

    private static func runLive(
        provider: AIProvider, providerID: String, model: String, reasoningEffort: String,
        host: String, reference: PRReference, pullRequest: PullRequest, context: Prompts.BoundedContext,
        situation: AIReviewSituation? = nil
    ) async throws -> AnalysisRun {
        let systemPrompt: String
        if let situation {
            systemPrompt = AISystemPrompt.analysis(
                situation: situation, context: context, detail: .forProvider(providerID)
            )
        } else {
            systemPrompt = Prompts.analysisSystemPrompt(
                host: host, owner: reference.owner, repository: reference.repo, prNumber: reference.number,
                baseSha: pullRequest.base.sha, headSha: pullRequest.headSha, context: context
            )
        }
        let userPrompt = Prompts.analysisUserPrompt(context: context)
        let firstRequest = AIRequest(
            system: systemPrompt, messages: [ChatMessage(role: .user, content: userPrompt)],
            model: model, reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens, jsonMode: true
        )

        // Streamed rather than a single blocking call: a structured-analysis
        // response can run long, and streaming resets the idle timeout on
        // every chunk instead of needing the whole response inside one
        // fixed window. The chunks themselves aren't surfaced anywhere yet.
        let firstResponse = try await provider.stream(firstRequest) { _ in }
        var finalText = firstResponse.text
        var finalUsage = firstResponse.usage
        var finalElapsedMS = firstResponse.elapsedMS
        var finalModel = firstResponse.model

        var (result, errors) = evaluate(finalText, expectedHeadSha: pullRequest.headSha)

        if result == nil {
            let repairRequest = AIRequest(
                system: systemPrompt,
                messages: [
                    ChatMessage(role: .user, content: userPrompt),
                    ChatMessage(role: .assistant, content: finalText),
                    ChatMessage(role: .user, content: Prompts.repairPrompt(originalResponse: finalText, errors: errors)),
                ],
                model: model, reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens, jsonMode: true
            )
            let repairResponse = try await provider.stream(repairRequest) { _ in }
            finalText = repairResponse.text
            finalUsage = repairResponse.usage ?? finalUsage
            finalElapsedMS += repairResponse.elapsedMS
            finalModel = repairResponse.model
            (result, errors) = evaluate(finalText, expectedHeadSha: pullRequest.headSha)
        }

        let outcome: AnalysisOutcome
        if let result {
            outcome = .structured(result)
        } else {
            let reason = errors.isEmpty ? "The response could not be parsed as reviewrr.ai-review.v1." : errors.joined(separator: "; ")
            outcome = .unstructured(raw: finalText, reason: reason)
        }

        return AnalysisRun(
            outcome: outcome, source: .fresh, providerID: providerID, model: finalModel,
            elapsedMS: finalElapsedMS, usage: finalUsage, generatedAt: Date()
        )
    }

    /// Parses, then validates when parsing succeeded. `nil` result means
    /// "invalid" either way — the caller doesn't need to distinguish a
    /// parse failure from a validation failure, only whether a repair is
    /// needed and, if so, what to tell the model went wrong.
    private static func evaluate(_ text: String, expectedHeadSha: String) -> (AnalysisResult?, [String]) {
        switch AnalysisParser.parse(text) {
        case .success(let result):
            let errors = AnalysisValidator.validate(result, expectedHeadSha: expectedHeadSha)
            return errors.isEmpty ? (result, []) : (nil, errors)
        case .failure(let error):
            return (nil, [error.errorDescription ?? "The response is not valid JSON."])
        }
    }
}
