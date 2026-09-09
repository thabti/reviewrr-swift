import Foundation

/// The AI right-rail's view model: structured analysis (with an offline
/// heuristic fallback) and a scoped Ask conversation. Every provider call
/// is read-only — see the product-vision "AI as a quiet companion" rule —
/// so this type never writes to GitHub, the filesystem, or the diff; a
/// human turns an answer into a draft via the `onCreateDraft` callback the
/// view supplies, not anything here.
@MainActor
final class AIModel: ObservableObject {
    enum AnalysisState: Equatable {
        case idle
        case loading
        case ready(AnalysisPresentation)
        case failed(String)
    }

    struct AnalysisPresentation: Equatable {
        var outcome: AnalysisOutcome
        var source: AnalysisSource
        var providerID: String
        var model: String
        var elapsedMS: Int
        var usage: AIUsage?
        var generatedAt: Date
    }

    /// Why an automatic analysis did not start when the PR opened.
    ///
    /// Kept separate from `AnalysisState` rather than added as a case: "no
    /// analysis has run" and "one is running" are unchanged facts, and the
    /// panel needs to say *why* nothing ran without every consumer of that
    /// enum having to learn a new case.
    struct AutoAnalysisSkip: Equatable {
        var fileCount: Int
        var threshold: Int
    }

    enum ProviderTestState: Equatable {
        case idle
        case running(partial: String)
        case success(providerName: String, model: String, elapsedMS: Int, firstLine: String, usage: AIUsage?)
        case failure(String)
    }

    // Ask
    let askComposer = AIAskComposerModel()
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isAsking = false
    @Published var askError: String?
    @Published private(set) var starterQuestions: [String] = []

    // Analysis
    @Published private(set) var analysisState: AnalysisState = .idle
    @Published private(set) var isAnalyzing = false
    /// Set when this PR was large enough that auto-analysis stood down and
    /// the reviewer has to ask for it. Cleared as soon as one runs.
    @Published private(set) var autoAnalysisSkip: AutoAnalysisSkip?

    // The files of the currently configured PR, exposed read-only so the
    // panel can offer a per-file Ask scope without a second source of truth.
    @Published private(set) var files: [PRFile] = []

    // Provider/model/effort selection, mirrored from `AppSettings` into
    // published state the panel header and Settings view can bind to
    // directly.
    @Published var providerID: String
    @Published var modelID: String
    @Published var reasoningEffort: String

    // Auto-analysis policy, mirrored the same way so Settings can bind to it.
    @Published var autoAnalyzeOnOpen: Bool
    @Published var autoAnalyzeMaxFiles: Int

    // Drives `AIProviderSettingsView`'s Test action.
    @Published private(set) var testState: ProviderTestState = .idle

    // MARK: Revisit state

    /// How the restored Ask transcript relates to the revision now open.
    @Published private(set) var sessionContinuity: AISessionContinuity = .fresh
    /// Set when the analysis on screen was carried over from an earlier
    /// revision, so the panel can say so rather than implying it describes
    /// the current diff.
    @Published private(set) var carriedOverFromHeadSha: String?
    /// Findings the reviewer already turned into a draft comment. The
    /// Findings list offers to draft again only for the rest.
    @Published private(set) var draftedFindingIDs: Set<String> = []
    /// Findings the reviewer set aside. Kept out of the way on a re-analysis
    /// without being deleted — disagreeing with a finding is not the same as
    /// it never having been raised.
    @Published private(set) var dismissedFindingIDs: Set<String> = []
    /// Draft comments written against a revision that is no longer the head.
    @Published private(set) var staleDrafts: [DraftComment] = []

    private let context: AppContext
    /// The AI module's entry point. Everything this view model used to do
    /// itself — provider construction, Keychain reads, prompt assembly,
    /// cache identity, GitHub fetches — happens behind it now.
    private let engine: AIEngine
    private var reference: PRReference?
    private var pullRequest: PullRequest?
    /// The situation the last turn was built from, kept so a draft or a
    /// dismissal can be folded in without refetching the PR.
    private var situation: AIReviewSituation?
    private var session = AISession()

    private var analyzeTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?

    init(context: AppContext, engine: AIEngine? = nil) {
        self.context = context
        self.engine = engine ?? AIEngine(context: context)
        let settings = context.settings()
        providerID = settings.aiProviderID
        modelID = settings.aiModel
        reasoningEffort = settings.aiReasoningEffort
        autoAnalyzeOnOpen = settings.autoAnalyzeOnOpen
        autoAnalyzeMaxFiles = settings.autoAnalyzeMaxFiles
    }

    // MARK: - Configuration

    func configure(reference: PRReference, pullRequest: PullRequest, files: [PRFile]) {
        if self.reference != reference { askComposer.reset() }
        askComposer.paths = files.map(\.filename)
        cancel()
        self.reference = reference
        self.pullRequest = pullRequest
        self.files = files
        askError = nil
        starterQuestions = Prompts.starterQuestions(pullRequest: pullRequest, files: files)
        analysisState = .idle
        carriedOverFromHeadSha = nil

        let situation = engine.situation(reference: reference, pullRequest: pullRequest, files: files)
        self.situation = situation
        staleDrafts = situation.staleDrafts

        // Reopening a PR is a continuation, not a reset. The Ask transcript,
        // which findings were already drafted, and which were set aside all
        // come back; a revision that moved in the meantime is marked rather
        // than thrown away.
        session = engine.loadSession(reference: reference)
        let restored = engine.restoredTranscript(session: session, openingHeadSha: pullRequest.headSha)
        messages = restored.messages
        sessionContinuity = restored.continuity
        draftedFindingIDs = session.draftedFindingIDs
        dismissedFindingIDs = session.dismissedFindingIDs

        // A cached result is shown immediately regardless of the
        // auto-analyze setting — that setting only gates a *fresh*
        // provider call, not reuse of an unchanged prior result (see the
        // schema doc's "Cache identity and extension" section). A run from
        // an earlier revision counts, narrowed to the findings whose files
        // have not changed and labelled as carried over.
        if let reuse = engine.cachedResult(situation: situation, providerID: providerID, model: modelID) {
            carriedOverFromHeadSha = reuse.carriedOverFrom
            analysisState = .ready(AnalysisPresentation(
                outcome: reuse.outcome, source: reuse.source, providerID: reuse.providerID, model: reuse.model,
                elapsedMS: reuse.elapsedMS, usage: reuse.usage, generatedAt: reuse.generatedAt
            ))
        }

        let settings = context.settings()
        autoAnalyzeOnOpen = settings.autoAnalyzeOnOpen
        autoAnalyzeMaxFiles = settings.autoAnalyzeMaxFiles

        if Self.shouldAutoAnalyze(fileCount: files.count, settings: settings) {
            autoAnalysisSkip = nil
            // Not when a carry-over is already on screen: the reviewer has
            // something to read, and a fresh call can wait for them to ask.
            if carriedOverFromHeadSha == nil {
                Task { await self.analyze(force: false) }
            }
        } else if settings.autoAnalyzeOnOpen {
            // Only worth explaining when the reviewer expects automatic
            // analysis and did not get one; if they turned it off, silence is
            // the setting working.
            autoAnalysisSkip = AutoAnalysisSkip(fileCount: files.count, threshold: settings.autoAnalyzeMaxFiles)
        } else {
            autoAnalysisSkip = nil
        }
    }

    /// Whether opening this PR should spend a provider call without being
    /// asked. A PR at exactly the limit still analyzes — the setting reads
    /// "more than N files", so N is inside it.
    nonisolated static func shouldAutoAnalyze(fileCount: Int, settings: AppSettings) -> Bool {
        settings.autoAnalyzeOnOpen && fileCount <= settings.autoAnalyzeMaxFiles
    }

    // MARK: - Draft and dismissal state

    /// Records that a finding became a draft comment, so revisiting shows it
    /// as dealt with instead of offering the same action again.
    func markFindingDrafted(id: String) {
        guard let reference else { return }
        draftedFindingIDs.insert(id)
        session.draftedFindingIDs = draftedFindingIDs
        session.headSha = pullRequest?.headSha ?? session.headSha
        engine.saveSession(session, reference: reference)
        refreshDraftState()
    }

    func setFindingDismissed(id: String, dismissed: Bool) {
        guard let reference else { return }
        if dismissed { dismissedFindingIDs.insert(id) } else { dismissedFindingIDs.remove(id) }
        session.dismissedFindingIDs = dismissedFindingIDs
        engine.saveSession(session, reference: reference)
    }

    /// Re-reads the reviewer's own draft state from disk. Drafts are written
    /// by the workspace, not by this model, so the panel's view of them is
    /// only as fresh as its last look.
    func refreshDraftState() {
        guard let reference, let pullRequest else { return }
        let refreshed = engine.situation(reference: reference, pullRequest: pullRequest, files: files)
        situation = refreshed
        staleDrafts = refreshed.staleDrafts
    }

    // MARK: - Analysis

    func analyze(force: Bool) async {
        guard let reference, let pullRequest else { return }
        // Whatever the reviewer was told about standing down no longer
        // applies once an analysis is under way.
        autoAnalysisSkip = nil
        analyzeTask?.cancel()
        let previousState = analysisState
        isAnalyzing = true
        analysisState = .loading

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isAnalyzing = false }
            do {
                let discussion = await self.engine.fetchDiscussion(reference: reference)
                try Task.checkCancellation()
                let situation = self.engine.situation(
                    reference: reference, pullRequest: pullRequest, files: self.files,
                    issueComments: discussion.issueComments, reviewComments: discussion.reviewComments
                )
                self.situation = situation
                self.staleDrafts = situation.staleDrafts

                let run = try await self.engine.analyze(
                    situation: situation, providerID: self.providerID, model: self.modelID,
                    effort: self.reasoningEffort, force: force
                )
                try Task.checkCancellation()
                // A fresh run describes the revision on screen, so any
                // carry-over label from an earlier one no longer applies.
                self.carriedOverFromHeadSha = nil
                self.analysisState = .ready(AnalysisPresentation(
                    outcome: run.outcome, source: run.source, providerID: run.providerID, model: run.model,
                    elapsedMS: run.elapsedMS, usage: run.usage, generatedAt: run.generatedAt
                ))
            } catch is CancellationError {
                if case .loading = self.analysisState { self.analysisState = previousState }
            } catch {
                self.analysisState = .failed(Self.describe(error))
            }
        }
        analyzeTask = task
        await task.value
    }

    // MARK: - Ask

    func ask(_ question: String, scope: AIScope) async {
        guard let reference, let pullRequest else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        askTask?.cancel()
        askError = nil

        messages.append(ChatMessage(role: .user, content: trimmed, taggedFiles: scope.paths.isEmpty ? nil : scope.paths))
        persistTranscript()
        let placeholder = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(placeholder)
        let assistantID = placeholder.id
        isAsking = true

        let history = messages
            .filter { $0.id != assistantID }
            .filter { $0.role != .system }

        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isAsking = false }
            do {
                let discussion = await self.engine.fetchDiscussion(reference: reference)
                try Task.checkCancellation()
                let situation = self.engine.situation(
                    reference: reference, pullRequest: pullRequest, files: self.files,
                    issueComments: discussion.issueComments, reviewComments: discussion.reviewComments
                )
                self.situation = situation
                self.staleDrafts = situation.staleDrafts

                let response = try await self.engine.ask(
                    situation: situation, scope: scope, history: history,
                    providerID: self.providerID, model: self.modelID, effort: self.reasoningEffort
                ) { [weak self] chunk in
                    Task { @MainActor in self?.appendChunk(chunk, to: assistantID) }
                }
                try Task.checkCancellation()
                self.finishStreaming(id: assistantID, finalText: response.text)
                self.persistTranscript()
            } catch is CancellationError {
                self.removeMessage(id: assistantID)
            } catch {
                self.askError = Self.describe(error)
                self.removeMessage(id: assistantID)
            }
        }
        askTask = task
        await task.value
    }

    /// Stores the transcript so reopening this PR — tomorrow, or after a
    /// relaunch — comes back to the conversation rather than a blank panel.
    private func persistTranscript() {
        guard let reference else { return }
        session.messages = messages
        session.headSha = pullRequest?.headSha ?? session.headSha
        session.draftedFindingIDs = draftedFindingIDs
        session.dismissedFindingIDs = dismissedFindingIDs
        engine.saveSession(session, reference: reference)
        // The transcript now belongs to the revision on screen, so the
        // "revision moved" marker has served its purpose.
        if case .revisionMoved = sessionContinuity { sessionContinuity = .sameRevision }
    }

    /// Clears the conversation for this PR, on disk as well as on screen.
    /// Explicit because a transcript that survives a relaunch also has to be
    /// removable — otherwise the only way out is to stop using the panel.
    func clearConversation() {
        messages = []
        askError = nil
        sessionContinuity = .fresh
        guard let reference else { return }
        session.messages = []
        engine.saveSession(session, reference: reference)
    }

    private func appendChunk(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += chunk
    }

    private func finishStreaming(id: UUID, finalText: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if !finalText.isEmpty { messages[index].content = finalText }
        messages[index].isStreaming = false
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    // MARK: - Provider selection

    func selectProvider(_ id: String) {
        providerID = id
        persistSelection()
    }

    func selectModel(_ id: String) {
        modelID = id
        persistSelection()
    }

    func selectReasoningEffort(_ effort: String) {
        reasoningEffort = effort
        persistSelection()
    }

    func setAutoAnalyzeOnOpen(_ enabled: Bool) {
        autoAnalyzeOnOpen = enabled
        var settings = context.settings()
        settings.autoAnalyzeOnOpen = enabled
        context.updateSettings(settings)
    }

    /// What the settings pane reads for values it only displays and writes
    /// back, rather than mirroring each one into its own published property.
    var settingsSnapshot: AppSettings { context.settings() }

    /// How long a command-line agent may stay silent before a run is
    /// abandoned. Clamped to something an agent could plausibly need: below
    /// half a minute every real analysis would fail, and past fifteen minutes
    /// of *silence* the agent is wedged, not thinking.
    func setAgentIdleTimeout(_ seconds: Double) {
        let clamped = min(max(seconds, 30), 900)
        var settings = context.settings()
        settings.aiAgentIdleTimeoutSeconds = clamped
        context.updateSettings(settings)
        objectWillChange.send()
    }

    /// Clamped rather than validated at the control: a stored 0 would mean
    /// "never analyze automatically" while the toggle still claimed it was
    /// on, which is a worse state than a value the reviewer did not type.
    func setAutoAnalyzeMaxFiles(_ limit: Int) {
        let clamped = min(max(limit, 1), 500)
        autoAnalyzeMaxFiles = clamped
        var settings = context.settings()
        settings.autoAnalyzeMaxFiles = clamped
        context.updateSettings(settings)
    }

    private func persistSelection() {
        var settings = context.settings()
        settings.aiProviderID = providerID
        settings.aiModel = modelID
        settings.aiReasoningEffort = reasoningEffort
        context.updateSettings(settings)
    }

    private func resolvedModel() -> String {
        engine.resolvedModel(providerID: providerID, chosen: modelID)
    }

    // MARK: - Provider test (used by AIProviderSettingsView)

    func testSelectedProvider() async {
        testTask?.cancel()
        let providerIDSnapshot = providerID
        let modelSnapshot = resolvedModel()
        let descriptor = AIProviderRegistry.descriptor(for: providerIDSnapshot)
        guard let provider = engine.provider(id: providerIDSnapshot) else {
            testState = .failure(
                engine.notReadyError(id: providerIDSnapshot, whereToConfigure: "this panel").errorDescription
                    ?? "Missing configuration."
            )
            return
        }
        testState = .running(partial: "")
        let effort = descriptor.supportsReasoningEffort ? reasoningEffort : nil

        let task = Task { [weak self] in
            guard let self else { return }
            let request = AIRequest(
                system: "You are confirming a connection test inside Reviewrr. Reply with one short, friendly sentence.",
                messages: [ChatMessage(role: .user, content: "Say hello and confirm you're connected.")],
                model: modelSnapshot, reasoningEffort: effort, maxOutputTokens: 200
            )
            do {
                let response = try await provider.stream(request) { [weak self] chunk in
                    Task { @MainActor in self?.appendTestChunk(chunk) }
                }
                try Task.checkCancellation()
                let firstLine = response.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? response.text
                self.testState = .success(
                    providerName: descriptor.displayName, model: response.model, elapsedMS: response.elapsedMS,
                    firstLine: firstLine, usage: response.usage
                )
            } catch is CancellationError {
                self.testState = .idle
            } catch {
                self.testState = .failure(Self.describe(error))
            }
        }
        testTask = task
        await task.value
    }

    private func appendTestChunk(_ chunk: String) {
        if case .running(let partial) = testState {
            testState = .running(partial: partial + chunk)
        } else {
            testState = .running(partial: chunk)
        }
    }

    // MARK: - Provider construction

    var isProviderConfigured: Bool { engine.isConfigured(id: providerID) }

    var providerConfigurationHint: String {
        isProviderConfigured
            ? "Run a fresh analysis for this pull request"
            : (engine.notReadyError(id: providerID).errorDescription ?? "This provider is not configured.")
    }

    /// Why a provider could not be built. Retained as a static entry point
    /// for callers with no model instance; the engine is the live path.
    static func notConfiguredError(providerID: String, whereToConfigure: String = "Settings → AI Provider") -> AIProviderError {
        AIProviderFactory.notReadyError(
            for: providerID,
            environment: .live(settings: AppSettings.load()),
            whereToConfigure: whereToConfigure
        )
    }

    // MARK: - Cancellation

    func cancel() {
        analyzeTask?.cancel()
        askTask?.cancel()
        testTask?.cancel()
    }

    private static func describe(_ error: Error) -> String {
        if let providerError = error as? AIProviderError { return providerError.errorDescription ?? "Something went wrong." }
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription { return description }
        return error.localizedDescription
    }
}
