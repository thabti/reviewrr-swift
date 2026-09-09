import Foundation

/// The AI feature's entry point.
///
/// Everything above this line — the panel, Settings, the view model — talks
/// to `AIEngine` and to the value types it returns. Everything below it —
/// providers, prompts, the analysis cache, the session store, the heuristic
/// fallback — is this module's business and is not reached into from
/// elsewhere.
///
/// The boundary is the point. Before it existed, a `@MainActor` view model
/// held provider construction, Keychain reads, prompt assembly, cache-key
/// arithmetic, and GitHub fetches, and three separate places computed cache
/// identity and had to agree by hand.
///
/// Not an actor: every operation here is either pure or already `async`, and
/// making it one would put a hop between the panel and its own state for no
/// safety gained.
struct AIEngine {
    private let context: AppContext
    /// Injectable so tests can drive the engine with no Keychain, no
    /// `UserDefaults`, and no installed CLI.
    private let providerEnvironment: AIProviderFactory.Environment

    @MainActor
    init(context: AppContext, providerEnvironment: AIProviderFactory.Environment? = nil) {
        self.context = context
        self.providerEnvironment = providerEnvironment ?? .live(settings: context.settings())
    }

    // MARK: - Provider

    func provider(id: String) -> AIProvider? {
        AIProviderFactory.make(id: id, environment: providerEnvironment)
    }

    func readiness(id: String) -> AIProviderFactory.Readiness {
        AIProviderFactory.readiness(for: id, environment: providerEnvironment)
    }

    func notReadyError(id: String, whereToConfigure: String = "Settings → AI Provider") -> AIProviderError {
        AIProviderFactory.notReadyError(for: id, environment: providerEnvironment, whereToConfigure: whereToConfigure)
    }

    func isConfigured(id: String) -> Bool {
        readiness(id: id).isReady
    }

    /// The model actually sent for a provider: the reviewer's choice, or the
    /// provider's default when they have not made one.
    func resolvedModel(providerID: String, chosen: String) -> String {
        chosen.isEmpty ? AIProviderRegistry.descriptor(for: providerID).defaultModel : chosen
    }

    func contextBudget(providerID: String) -> AIContextBudget {
        AIProviderRegistry.descriptor(for: providerID).contextBudget
            ?? AIContextBudget(maxFileChars: Prompts.defaultMaxFileChars, maxTotalChars: Prompts.defaultMaxTotalChars)
    }

    // MARK: - Situation

    /// Assembles what the module knows about this review right now: the PR,
    /// its files, its discussion, the reviewer's own unsent work, and what a
    /// previous analysis of it concluded.
    @MainActor
    func situation(
        reference: PRReference, pullRequest: PullRequest, files: [PRFile],
        issueComments: [IssueComment] = [], reviewComments: [ReviewComment] = []
    ) -> AIReviewSituation {
        AIReviewSituation(
            reference: reference,
            host: context.host.webBaseURL.host ?? context.host.displayName,
            pullRequest: pullRequest,
            files: files,
            issueComments: issueComments,
            reviewComments: reviewComments,
            draft: DraftStore.load(for: reference),
            priorRun: priorRun(for: reference)
        )
    }

    /// The most recent stored analysis of this PR by any provider, used only
    /// to tell the prompt that a second look is happening and whether the
    /// revision moved.
    private func priorRun(for reference: PRReference) -> AIReviewSituation.AIPriorRun? {
        guard let latest = AnalysisCache.mostRecent(for: reference) else { return nil }
        let findings: Int
        if case .structured(let result) = latest.outcome { findings = result.findings.count } else { findings = 0 }
        return AIReviewSituation.AIPriorRun(
            headSha: latest.headSha, generatedAt: latest.generatedAt, findingCount: findings
        )
    }

    /// Best-effort discussion fetch. A failure means Ask and Analysis run
    /// with less context, not that the turn fails — the title, description,
    /// and diff are still there.
    @MainActor
    func fetchDiscussion(reference: PRReference) async -> (issueComments: [IssueComment], reviewComments: [ReviewComment]) {
        let client = GitHubClient(api: context.api())
        let token = context.token()
        let issue = (try? await client.fetchIssueComments(reference, token: token)) ?? []
        let review = (try? await client.fetchReviewComments(reference, token: token)) ?? []
        return (issue, review)
    }

    // MARK: - Cache

    func boundedContext(situation: AIReviewSituation, providerID: String, scopedTo path: String? = nil) -> Prompts.BoundedContext {
        let budget = contextBudget(providerID: providerID)
        let files = path.map { wanted in situation.files.filter { $0.filename == wanted } } ?? situation.files
        return Prompts.buildContext(
            pullRequest: situation.pullRequest, files: files,
            issueComments: situation.issueComments, reviewComments: situation.reviewComments,
            drafts: situation.draft.comments,
            maxFileChars: budget.maxFileChars, maxTotalChars: budget.maxTotalChars
        )
    }

    func identity(situation: AIReviewSituation, providerID: String, model: String) -> AIAnalysisIdentity {
        let configured = isConfigured(id: providerID)
        let effectiveProviderID = configured ? providerID : HeuristicAnalyzer.agentID
        let effectiveModel = configured ? resolvedModel(providerID: providerID, chosen: model) : ""
        return AIAnalysisIdentity(
            providerID: effectiveProviderID, model: effectiveModel, headSha: situation.headSha,
            contentHash: boundedContext(situation: situation, providerID: providerID).contentHash,
            fileFingerprints: situation.fileFingerprints()
        )
    }

    /// What can be shown for this PR without calling a provider: the same
    /// run, or a partial carry-over from an earlier revision labelled as
    /// such.
    func cachedResult(situation: AIReviewSituation, providerID: String, model: String) -> AIAnalysisReuse? {
        switch AnalysisCache.reuse(for: situation.reference, identity: identity(situation: situation, providerID: providerID, model: model)) {
        case .exact(let entry):
            return AIAnalysisReuse(
                outcome: entry.outcome, source: .cache, providerID: entry.providerID, model: entry.model,
                elapsedMS: entry.elapsedMS, usage: entry.usage, generatedAt: entry.generatedAt, carriedOverFrom: nil
            )
        case .carriedOver(let entry, let fromHeadSha, let keptFindingIDs, let droppedFindings):
            return AIAnalysisReuse(
                outcome: AnalysisCache.carryOver(entry, keptFindingIDs: keptFindingIDs, droppedFindings: droppedFindings),
                source: .cache, providerID: entry.providerID, model: entry.model,
                elapsedMS: entry.elapsedMS, usage: entry.usage, generatedAt: entry.generatedAt,
                carriedOverFrom: fromHeadSha
            )
        case .miss:
            return nil
        }
    }

    // MARK: - Analysis

    @MainActor
    func analyze(situation: AIReviewSituation, providerID: String, model: String, effort: String, force: Bool) async throws -> AnalysisRun {
        try await PRAnalyzer.run(
            reference: situation.reference, host: situation.host, pullRequest: situation.pullRequest,
            files: situation.files, issueComments: situation.issueComments,
            reviewComments: situation.reviewComments, drafts: situation.draft.comments,
            provider: provider(id: providerID), providerID: providerID,
            model: resolvedModel(providerID: providerID, chosen: model),
            reasoningEffort: effort, force: force,
            contextBudget: AIProviderRegistry.descriptor(for: providerID).contextBudget,
            situation: situation
        )
    }

    // MARK: - Ask

    func boundedAskContext(situation: AIReviewSituation, scope: AIScope, providerID: String) throws -> Prompts.BoundedContext {
        var scopedSituation = situation
        if !scope.paths.isEmpty {
            let selected = Set(scope.paths)
            guard selected.isSubset(of: Set(situation.files.map(\.filename))) else {
                throw AIProviderError.invalidResponse("A tagged file is no longer in this PR. Remove it and choose a current file.")
            }
            scopedSituation.files = situation.files.filter { selected.contains($0.filename) }
        }
        return boundedContext(situation: scopedSituation, providerID: providerID)
    }

    /// One Ask turn; file tags bound the new diff context while history stays intact.
    @MainActor
    func ask(
        situation: AIReviewSituation, scope: AIScope, history: [ChatMessage],
        providerID: String, model: String, effort: String,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> AIResponse {
        guard let provider = provider(id: providerID) else { throw notReadyError(id: providerID) }
        let descriptor = AIProviderRegistry.descriptor(for: providerID)
        let bounded = try boundedAskContext(situation: situation, scope: scope, providerID: providerID)
        let systemPrompt = AISystemPrompt.ask(
            situation: situation, scope: scope, context: bounded.text,
            detail: .forProvider(providerID)
        )
        let request = AIRequest(
            system: systemPrompt,
            // System-role entries are Reviewrr's own markers (a revision
            // notice, for instance), not turns the model authored.
            messages: history.filter { $0.role != .system }.map { message in
                var contextual = message
                if let paths = message.taggedFiles, !paths.isEmpty {
                    contextual.content += "\n\nReferenced PR files: " + paths.joined(separator: ", ")
                }
                return contextual
            },
            model: resolvedModel(providerID: providerID, chosen: model),
            reasoningEffort: descriptor.supportsReasoningEffort ? effort : nil,
            maxOutputTokens: 4096, jsonMode: false
        )
        return try await provider.stream(request, onChunk: onChunk)
    }

    // MARK: - Session

    func loadSession(reference: PRReference) -> AISession {
        AISessionStore.load(for: reference)
    }

    func saveSession(_ session: AISession, reference: PRReference) {
        AISessionStore.save(session, for: reference)
    }

    /// The transcript to show when opening a PR, plus how it relates to the
    /// revision now open. A moved revision keeps the conversation and marks
    /// it; it does not throw the reviewer's reading away.
    func restoredTranscript(session: AISession, openingHeadSha: String) -> (messages: [ChatMessage], continuity: AISessionContinuity) {
        let continuity = AISessionStore.continuity(of: session, openingHeadSha: openingHeadSha)
        switch continuity {
        case .fresh:
            return (session.messages, .fresh)
        case .sameRevision:
            return (session.messages, .sameRevision)
        case .revisionMoved(let fromHeadSha):
            var messages = session.messages
            messages.append(AISessionStore.revisionMovedNotice(fromHeadSha: fromHeadSha, toHeadSha: openingHeadSha))
            return (messages, continuity)
        }
    }
}

/// A result the module could produce without calling a provider.
struct AIAnalysisReuse: Equatable {
    var outcome: AnalysisOutcome
    var source: AnalysisSource
    var providerID: String
    var model: String
    var elapsedMS: Int
    var usage: AIUsage?
    var generatedAt: Date
    /// Set when this came from an analysis of a different revision, so the
    /// panel can say so instead of implying it describes the current diff.
    var carriedOverFrom: String?
}
