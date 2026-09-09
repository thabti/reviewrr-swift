import XCTest

// MARK: - Fixtures

private func makeUser(_ login: String = "octocat") -> GitHubUser {
    GitHubUser(login: login, avatarUrl: nil)
}

private func makePR(
    number: Int = 1, title: String = "Add atomic review submission", body: String? = "Fixes duplicate reviews.",
    headSha: String = "head123", baseSha: String = "base123"
) -> PullRequest {
    PullRequest(
        id: number, number: number, title: title, body: body, state: .open, draft: false, merged: false,
        mergeableState: "clean", user: makeUser(), head: .init(ref: "feature", sha: headSha), base: .init(ref: "main", sha: baseSha),
        additions: 10, deletions: 2, changedFiles: 1, commits: 1, comments: 0, reviewComments: 0,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        htmlUrl: "https://github.com/acme/widget/pull/\(number)", labels: []
    )
}

private func makeFile(
    _ filename: String, patch: String? = "@@ -1,1 +1,1 @@\n+let x = 1", additions: Int = 1, deletions: Int = 0,
    status: PRFileStatus = .modified
) -> PRFile {
    PRFile(filename: filename, previousFilename: nil, status: status, additions: additions, deletions: deletions, changes: additions + deletions, patch: patch)
}

/// A minimal, schema-valid `reviewrr.ai-review.v1` response, parameterized
/// on the bits individual tests need to vary.
private func validAnalysisJSON(headSha: String = "head123", schemaVersion: String = AnalysisResult.currentSchemaVersion) -> String {
    """
    {
      "schemaVersion": "\(schemaVersion)",
      "scope": {
        "host": "github.com", "owner": "acme", "repository": "widget", "prNumber": 1,
        "baseSha": "base123", "headSha": "\(headSha)", "agent": "test", "model": "test-model",
        "analysisMode": "fresh", "analyzedFiles": ["internal/service.go"], "skippedFiles": []
      },
      "overview": {
        "title": "Adds atomic review submission", "summary": "Validates and submits one review payload.",
        "intent": "Prevent partial submission.", "risk": "medium", "reviewEffort": "medium"
      },
      "reviewOrder": [{"path": "internal/service.go", "priority": 1, "reason": "Owns the write boundary"}],
      "fileSummaries": [{"path": "internal/service.go", "role": "Review orchestration", "summary": "Builds the payload.", "risk": "medium"}],
      "findings": [
        {
          "id": "finding-1", "title": "Retry can duplicate a review", "severity": "high", "category": "correctness",
          "confidence": 0.9, "path": "internal/service.go", "side": "RIGHT", "startLine": 10, "endLine": 12,
          "evidence": "Retries before reconciling.", "explanation": "May double-submit.", "suggestion": "Reconcile first."
        }
      ],
      "testGaps": [{"title": "Timeout reconciliation", "description": "Cover a timeout after success.", "paths": ["internal/service_test.go"]}],
      "architectureImpact": [{"area": "Write boundary", "impact": "Centralizes duplicate prevention.", "risk": "medium"}],
      "reviewerQuestions": [{"question": "What time window is used?", "reason": "Too broad may over-match.", "path": "internal/service.go"}],
      "limitations": ["Generated files excluded."]
    }
    """
}

// MARK: - Stub provider (no network)

private final class StubProvider: AIProvider {
    let id = "stub"
    private var responses: [String]
    private(set) var callCount = 0
    private(set) var receivedRequests: [AIRequest] = []

    init(responses: [String]) { self.responses = responses }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        callCount += 1
        receivedRequests.append(request)
        let text = callCount <= responses.count ? responses[callCount - 1] : (responses.last ?? "")
        return AIResponse(text: text, model: request.model.isEmpty ? "stub-model" : request.model, elapsedMS: 1, usage: AIUsage(inputTokens: 10, outputTokens: 5))
    }
}

final class AITests: XCTestCase {

    // MARK: - AnalysisParser

    func testParsesValidJSON() {
        switch AnalysisParser.parse(validAnalysisJSON()) {
        case .success(let result):
            XCTAssertEqual(result.schemaVersion, AnalysisResult.currentSchemaVersion)
            XCTAssertEqual(result.scope.headSha, "head123")
            XCTAssertEqual(result.findings.count, 1)
            XCTAssertEqual(result.findings.first?.id, "finding-1")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParsesFencedMarkdownJSON() {
        let fenced = "Here is the analysis:\n```json\n\(validAnalysisJSON())\n```\n"
        switch AnalysisParser.parse(fenced) {
        case .success(let result):
            XCTAssertEqual(result.scope.headSha, "head123")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParsesJSONEmbeddedInProse() {
        let wrapped = "Sure, here you go: \(validAnalysisJSON()) Let me know if you need more."
        switch AnalysisParser.parse(wrapped) {
        case .success(let result):
            XCTAssertEqual(result.overview.title, "Adds atomic review submission")
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testParsesPartialJSON() {
        // Missing every optional array/section — still valid per the
        // schema doc's "empty arrays are valid" rule.
        let partial = """
        {
          "schemaVersion": "\(AnalysisResult.currentSchemaVersion)",
          "scope": {
            "host": "github.com", "owner": "acme", "repository": "widget", "prNumber": 1,
            "baseSha": "base123", "headSha": "head123", "agent": "test", "model": "test-model",
            "analysisMode": "fresh"
          },
          "overview": {
            "title": "Small fix", "summary": "One-line change.", "intent": "Fix a typo.", "risk": "low", "reviewEffort": "small"
          }
        }
        """
        switch AnalysisParser.parse(partial) {
        case .success(let result):
            XCTAssertEqual(result.scope.analyzedFiles, [])
            XCTAssertEqual(result.scope.skippedFiles, [])
            XCTAssertEqual(result.findings, [])
            XCTAssertEqual(result.reviewOrder, [])
            XCTAssertEqual(result.limitations, [])
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testFailsOnInvalidJSON() {
        switch AnalysisParser.parse("this is not JSON at all, just prose.") {
        case .success:
            XCTFail("expected failure")
        case .failure(let error):
            XCTAssertEqual(error, AnalysisParser.ParseError.noJSONObjectFound)
        }
    }

    func testFailsOnMissingRequiredField() {
        // Valid JSON object, but missing the required `overview` key.
        let missingOverview = """
        { "schemaVersion": "\(AnalysisResult.currentSchemaVersion)", "scope": { "host": "github.com", "owner": "a", "repository": "b", "prNumber": 1, "baseSha": "x", "headSha": "y", "agent": "t", "model": "m", "analysisMode": "fresh" } }
        """
        switch AnalysisParser.parse(missingOverview) {
        case .success:
            XCTFail("expected failure")
        case .failure:
            break
        }
    }

    // MARK: - AnalysisValidator

    func testValidResultHasNoErrors() {
        guard case .success(let result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        XCTAssertEqual(AnalysisValidator.validate(result, expectedHeadSha: "head123"), [])
    }

    func testDetectsHeadShaMismatch() {
        guard case .success(let result) = AnalysisParser.parse(validAnalysisJSON(headSha: "stale-sha")) else {
            return XCTFail("fixture should parse")
        }
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("headSha") })
    }

    func testDetectsDuplicateFindingIDs() {
        guard case .success(var result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        result.findings.append(result.findings[0])
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("duplicate id") })
    }

    func testDetectsOutOfRangeConfidence() {
        guard case .success(var result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        result.findings[0].confidence = 1.5
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("confidence") })
    }

    func testDetectsPartialAnchor() {
        guard case .success(var result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        result.findings[0].side = nil // path/startLine/endLine still set — inconsistent
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("all together or all to null") })
    }

    func testDetectsNonPositivePriority() {
        guard case .success(var result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        result.reviewOrder[0].priority = 0
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("positive integer") })
    }

    func testDetectsFindingAnchorOutsideAnalyzedFiles() {
        guard case .success(var result) = AnalysisParser.parse(validAnalysisJSON()) else {
            return XCTFail("fixture should parse")
        }
        result.findings[0].path = "not/analyzed.go"
        let errors = AnalysisValidator.validate(result, expectedHeadSha: "head123")
        XCTAssertTrue(errors.contains { $0.contains("not in scope.analyzedFiles") })
    }

    // MARK: - Prompts: repair path construction

    func testRepairPromptIncludesErrorsAndOriginalResponse() {
        let prompt = Prompts.repairPrompt(originalResponse: "{\"broken\": true", errors: ["missing closing brace", "schemaVersion is required"])
        XCTAssertTrue(prompt.contains("missing closing brace"))
        XCTAssertTrue(prompt.contains("schemaVersion is required"))
        XCTAssertTrue(prompt.contains("{\"broken\": true"))
        XCTAssertTrue(prompt.contains("reviewrr.ai-review.v1"))
    }

    // MARK: - Prompts: context bounding

    func testBuildContextExcludesVendorGeneratedAndBinaryFiles() {
        let files = [
            makeFile("src/app.swift"),
            makeFile("vendor/lib/thing.go"),
            makeFile("package-lock.json"),
            makeFile("assets/logo.png", patch: nil),
        ]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files)
        XCTAssertEqual(context.analyzedFiles, ["src/app.swift"])
        let reasons = Dictionary(uniqueKeysWithValues: context.skippedFiles.map { ($0.path, $0.reason) })
        XCTAssertEqual(reasons["vendor/lib/thing.go"], AnalysisSkipReason.vendor)
        XCTAssertEqual(reasons["package-lock.json"], AnalysisSkipReason.generated)
        XCTAssertEqual(reasons["assets/logo.png"], AnalysisSkipReason.binary)
    }

    func testBuildContextTruncatesOversizedPatch() {
        let hugePatch = "@@ -1,1 +1,1 @@\n" + String(repeating: "+x\n", count: 5000)
        let context = Prompts.buildContext(pullRequest: makePR(), files: [makeFile("big.swift", patch: hugePatch)], maxFileChars: 200)
        XCTAssertEqual(context.analyzedFiles, ["big.swift"])
        XCTAssertTrue(context.text.contains("(truncated)"))
    }

    func testBuildContextSkipsFilesOverTotalBudget() {
        let files = [makeFile("first.swift", patch: String(repeating: "x", count: 500)), makeFile("second.swift", patch: String(repeating: "y", count: 500))]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files, maxFileChars: 1000, maxTotalChars: 600)
        XCTAssertEqual(context.analyzedFiles, ["first.swift"])
        XCTAssertEqual(context.skippedFiles.first { $0.path == "second.swift" }?.reason, AnalysisSkipReason.contextLimit)
    }

    func testContentHashIsStableAcrossDiscussionContext() {
        let files = [makeFile("a.swift")]
        let pr = makePR()
        let withoutDiscussion = Prompts.buildContext(pullRequest: pr, files: files)
        let comment = IssueComment(id: 1, user: makeUser(), body: "looks good", createdAt: Date(), htmlUrl: "x")
        let withDiscussion = Prompts.buildContext(pullRequest: pr, files: files, issueComments: [comment])
        // The cache identity is about the diff being analyzed, not the
        // ever-changing conversation around it — see the doc comment in
        // Prompts.buildContext.
        XCTAssertEqual(withoutDiscussion.contentHash, withDiscussion.contentHash)
        XCTAssertNotEqual(withoutDiscussion.text, withDiscussion.text)
    }

    func testStarterQuestionsAdaptToFileList() {
        let migrationFiles = [makeFile("db/migrations/0001_add_column.sql")]
        let questions = Prompts.starterQuestions(pullRequest: makePR(), files: migrationFiles)
        XCTAssertTrue(questions.contains { $0.lowercased().contains("migration") || $0.lowercased().contains("backfill") })
    }

    // MARK: - Citations

    func testExtractsSimpleCitation() {
        let citations = Citations.extract(from: "The bug is at internal/service.go:42 in the retry loop.")
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations.first?.path, "internal/service.go")
        XCTAssertEqual(citations.first?.startLine, 42)
        XCTAssertEqual(citations.first?.endLine, 42)
    }

    func testExtractsRangeCitation() {
        let citations = Citations.extract(from: "See Sources/App.swift:10-20 for the handler.")
        XCTAssertEqual(citations.first?.startLine, 10)
        XCTAssertEqual(citations.first?.endLine, 20)
    }

    func testIgnoresTimeLikeTokens() {
        let citations = Citations.extract(from: "The meeting is at 10:30, unrelated to any file.")
        XCTAssertTrue(citations.isEmpty)
    }

    func testExtractsMultipleCitations() {
        let citations = Citations.extract(from: "Compare a/b.go:1 with a/b.go:1 and c/d.rs:5-7.")
        XCTAssertEqual(citations.count, 3)
    }

    // MARK: - HeuristicAnalyzer

    func testHeuristicAnalyzerDetectsHardcodedCredential() {
        let patch = "@@ -1,1 +1,2 @@\n+let apiKey = \"sk-live-abcdef1234567890\""
        let files = [makeFile("Config.swift", patch: patch)]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files)
        let result = HeuristicAnalyzer.analyze(
            host: "github.com", owner: "acme", repository: "widget", prNumber: 1, baseSha: "base123", headSha: "head123",
            pullRequest: makePR(), files: files, context: context
        )
        XCTAssertEqual(result.scope.agent, "heuristic")
        XCTAssertTrue(result.findings.contains { $0.category == .security && $0.title.lowercased().contains("credential") })
    }

    func testHeuristicAnalyzerDetectsDisabledTLSAndFocusedTest() {
        let patch = "@@ -1,1 +1,3 @@\n+client.verify = False\n+it.only(\"runs\", () => {})"
        let files = [makeFile("Client.py", patch: patch)]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files)
        let result = HeuristicAnalyzer.analyze(
            host: "github.com", owner: "acme", repository: "widget", prNumber: 1, baseSha: "base123", headSha: "head123",
            pullRequest: makePR(), files: files, context: context
        )
        XCTAssertTrue(result.findings.contains { $0.title.contains("TLS") })
        XCTAssertTrue(result.findings.contains { $0.category == .testing })
    }

    func testHeuristicAnalyzerFindingsAnchorToCorrectLineNumbers() {
        // Hunk starts at new-file line 10; the second line (context) is 10,
        // the added line with the secret is new-file line 11.
        let patch = "@@ -8,2 +10,2 @@\n let unrelated = 0\n+let password = \"hunter2-hunter2\""
        let files = [makeFile("Config.swift", patch: patch)]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files)
        let result = HeuristicAnalyzer.analyze(
            host: "github.com", owner: "acme", repository: "widget", prNumber: 1, baseSha: "base123", headSha: "head123",
            pullRequest: makePR(), files: files, context: context
        )
        XCTAssertEqual(result.findings.first?.startLine, 11)
    }

    func testHeuristicAnalyzerNeverInventsFindingsForCleanCode() {
        let files = [makeFile("Clean.swift", patch: "@@ -1,1 +1,1 @@\n+let value = compute()")]
        let context = Prompts.buildContext(pullRequest: makePR(), files: files)
        let result = HeuristicAnalyzer.analyze(
            host: "github.com", owner: "acme", repository: "widget", prNumber: 1, baseSha: "base123", headSha: "head123",
            pullRequest: makePR(), files: files, context: context
        )
        XCTAssertEqual(result.findings, [])
    }

    // MARK: - AIProviderRegistry

    func testRegistryDefaultsAreWellFormed() {
        for descriptor in AIProviderRegistry.all {
            if descriptor.needsAPIKey {
                XCTAssertFalse(descriptor.defaultModel.isEmpty, "\(descriptor.id) needs a default model")
            }
            for option in descriptor.models {
                XCTAssertFalse(option.modelID.isEmpty)
            }
        }
    }

    func testOllamaNeedsNoAPIKey() {
        XCTAssertFalse(AIProviderRegistry.ollama.needsAPIKey)
    }

    func testOpenAICompatibleNeedsBaseURLNotAPIKey() {
        XCTAssertTrue(AIProviderRegistry.openAICompatible.needsBaseURL)
        XCTAssertFalse(AIProviderRegistry.openAICompatible.needsAPIKey)
    }

    func testDescriptorLookupFallsBackToAnthropicForUnknownID() {
        XCTAssertEqual(AIProviderRegistry.descriptor(for: "not-a-real-provider").id, "anthropic")
    }

    // MARK: - Auto-analysis policy

    func testAPullRequestAtTheFileLimitStillAnalyzesAutomatically() {
        var settings = AppSettings()
        settings.autoAnalyzeOnOpen = true
        settings.autoAnalyzeMaxFiles = 30
        XCTAssertTrue(
            AIModel.shouldAutoAnalyze(fileCount: 30, settings: settings),
            "The setting reads \"more than 30 files\", so 30 is inside the limit"
        )
    }

    func testAPullRequestPastTheFileLimitWaitsForTheReviewer() {
        var settings = AppSettings()
        settings.autoAnalyzeOnOpen = true
        settings.autoAnalyzeMaxFiles = 30
        XCTAssertFalse(AIModel.shouldAutoAnalyze(fileCount: 31, settings: settings))
        XCTAssertFalse(AIModel.shouldAutoAnalyze(fileCount: 400, settings: settings))
    }

    func testAutoAnalysisOffMeansNoProviderCallAtAnySize() {
        var settings = AppSettings()
        settings.autoAnalyzeOnOpen = false
        settings.autoAnalyzeMaxFiles = 30
        XCTAssertFalse(AIModel.shouldAutoAnalyze(fileCount: 1, settings: settings))
    }

    func testDefaultFileLimitIsThirty() {
        XCTAssertEqual(AppSettings().autoAnalyzeMaxFiles, 30)
        XCTAssertTrue(AppSettings().autoAnalyzeOnOpen)
    }

    @MainActor
    func testFileLimitIsClampedSoAutomaticAnalysisCannotBeSilentlyDisabled() {
        let model = AIModel(context: AppContext.stub())
        model.setAutoAnalyzeMaxFiles(0)
        XCTAssertEqual(model.autoAnalyzeMaxFiles, 1, "0 would read as \"on\" while never analyzing")
        model.setAutoAnalyzeMaxFiles(10_000)
        XCTAssertEqual(model.autoAnalyzeMaxFiles, 500)
        model.setAutoAnalyzeMaxFiles(45)
        XCTAssertEqual(model.autoAnalyzeMaxFiles, 45)
    }

    // MARK: - PRAnalyzer (stubbed provider, no network)

    func testPRAnalyzerCachesFreshResultAndReusesItWithoutCallingProviderAgain() async throws {
        let reference = PRReference(owner: "acme-\(UUID().uuidString)", repo: "widget", number: 1)
        AnalysisCache.clear(for: reference)
        defer { AnalysisCache.clear(for: reference) }

        let stub = StubProvider(responses: [validAnalysisJSON()])
        let pr = makePR()
        let files = [makeFile("internal/service.go")]

        let first = try await PRAnalyzer.run(
            reference: reference, host: "github.com", pullRequest: pr, files: files,
            provider: stub, providerID: "stub", model: "stub-model", reasoningEffort: "medium", force: false
        )
        XCTAssertEqual(first.source, AnalysisSource.fresh)
        XCTAssertEqual(stub.callCount, 1)

        let second = try await PRAnalyzer.run(
            reference: reference, host: "github.com", pullRequest: pr, files: files,
            provider: stub, providerID: "stub", model: "stub-model", reasoningEffort: "medium", force: false
        )
        XCTAssertEqual(second.source, AnalysisSource.cache)
        XCTAssertEqual(stub.callCount, 1, "a cache hit must not call the provider again")
        XCTAssertEqual(first.outcome, second.outcome)
    }

    func testPRAnalyzerRepairsAnInvalidFirstResponse() async throws {
        let reference = PRReference(owner: "acme-\(UUID().uuidString)", repo: "widget", number: 2)
        AnalysisCache.clear(for: reference)
        defer { AnalysisCache.clear(for: reference) }

        let stub = StubProvider(responses: ["not json at all", validAnalysisJSON()])
        let run = try await PRAnalyzer.run(
            reference: reference, host: "github.com", pullRequest: makePR(), files: [makeFile("internal/service.go")],
            provider: stub, providerID: "stub", model: "stub-model", reasoningEffort: "medium", force: false
        )
        XCTAssertEqual(stub.callCount, 2, "one repair attempt should be made")
        guard case .structured(let result) = run.outcome else {
            return XCTFail("expected the repaired response to parse as structured")
        }
        XCTAssertEqual(result.findings.first?.id, "finding-1")
        // The repair request should carry the original invalid response and
        // the validation/parse errors that triggered it.
        let repairMessage = stub.receivedRequests[1].messages.last?.content ?? ""
        XCTAssertTrue(repairMessage.contains("not json at all"))
    }

    func testPRAnalyzerFallsBackToUnstructuredWhenRepairAlsoFails() async throws {
        let reference = PRReference(owner: "acme-\(UUID().uuidString)", repo: "widget", number: 3)
        AnalysisCache.clear(for: reference)
        defer { AnalysisCache.clear(for: reference) }

        let stub = StubProvider(responses: ["still not json", "still not json either"])
        let run = try await PRAnalyzer.run(
            reference: reference, host: "github.com", pullRequest: makePR(), files: [makeFile("internal/service.go")],
            provider: stub, providerID: "stub", model: "stub-model", reasoningEffort: "medium", force: false
        )
        XCTAssertEqual(stub.callCount, 2)
        guard case .unstructured(let raw, let reason) = run.outcome else {
            return XCTFail("expected an unstructured fallback")
        }
        XCTAssertEqual(raw, "still not json either")
        XCTAssertFalse(reason.isEmpty)
    }

    func testPRAnalyzerRunsHeuristicWhenNoProviderIsConfigured() async throws {
        let reference = PRReference(owner: "acme-\(UUID().uuidString)", repo: "widget", number: 4)
        AnalysisCache.clear(for: reference)
        defer { AnalysisCache.clear(for: reference) }

        let run = try await PRAnalyzer.run(
            reference: reference, host: "github.com", pullRequest: makePR(), files: [makeFile("internal/service.go")],
            provider: nil, providerID: "anthropic", model: "", reasoningEffort: "medium", force: false
        )
        XCTAssertEqual(run.source, AnalysisSource.heuristic)
        guard case .structured(let result) = run.outcome else {
            return XCTFail("the heuristic analyzer always returns structured output")
        }
        XCTAssertEqual(result.scope.agent, HeuristicAnalyzer.agentID)
    }
}

/// The agent watchdog measures *silence*, not duration.
///
/// A wall-clock budget could not tell a wedged agent from a big analysis, so
/// it killed working runs: "codex did not answer within 120s" arrived while
/// codex was busy answering.
final class AgentIdleWatchdogTests: XCTestCase {
    func testAStreamingRunSurvivesPastTheIdleBudget() async {
        let fired = TimeoutFlag()
        let watchdog = AgentProcess.IdleWatchdog(idleTimeout: 1.2, maximumRuntime: 60) { fired.set() }
        defer { watchdog.cancel() }

        // Two seconds of work, speaking every 300ms: longer than the budget,
        // never silent for it.
        for _ in 0..<7 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            watchdog.touch()
        }
        XCTAssertFalse(fired.isSet, "an agent that keeps producing output must not be killed for being slow")
    }

    func testSilenceFires() async {
        let fired = TimeoutFlag()
        let watchdog = AgentProcess.IdleWatchdog(idleTimeout: 0.6, maximumRuntime: 60) { fired.set() }
        defer { watchdog.cancel() }

        try? await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertTrue(fired.isSet, "an agent that stops producing output is what the budget is for")
    }

    func testAnEndlessRunStillStops() async {
        let fired = TimeoutFlag()
        let watchdog = AgentProcess.IdleWatchdog(idleTimeout: 30, maximumRuntime: 1) { fired.set() }
        defer { watchdog.cancel() }

        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            watchdog.touch()
        }
        XCTAssertTrue(fired.isSet, "chattering forever is still a run that has to end")
    }
}
