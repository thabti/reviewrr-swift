import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence as a provider: what the registry promises, how a
/// request is bounded before it reaches a small context window, and — when
/// the Mac can serve it — one real on-device request end to end.
final class AppleIntelligenceTests: XCTestCase {

    // MARK: - Registry

    func testAppleIntelligenceIsTheDefaultProviderAndNeedsNoConfiguration() {
        XCTAssertEqual(AppSettings().aiProviderID, "apple-intelligence")
        let descriptor = AIProviderRegistry.appleIntelligence
        XCTAssertFalse(descriptor.needsAPIKey, "There is no key to hold for an on-device model")
        XCTAssertFalse(descriptor.needsBaseURL)
        XCTAssertNil(descriptor.localAgent, "Nothing is spawned; the framework is in-process")
        XCTAssertTrue(descriptor.supportsStreaming)
        XCTAssertFalse(descriptor.supportsReasoningEffort, "The system model exposes no effort control")
        XCTAssertTrue(descriptor.models.isEmpty, "The system owns the weights; a model picker would be a lie")
        XCTAssertFalse(descriptor.defaultModel.isEmpty, "The analysis header and cache key still need a name")
    }

    func testAppleIntelligenceCarriesATighterContextBudgetThanTheDefault() throws {
        let budget = try XCTUnwrap(AIProviderRegistry.appleIntelligence.contextBudget)
        XCTAssertLessThan(budget.maxTotalChars, Prompts.defaultMaxTotalChars)
        XCTAssertLessThan(budget.maxFileChars, Prompts.defaultMaxFileChars)
    }

    func testEveryOtherProviderKeepsThePromptDefaults() {
        for descriptor in AIProviderRegistry.all where descriptor.id != "apple-intelligence" {
            XCTAssertNil(descriptor.contextBudget, "\(descriptor.id) takes the full bounded context")
        }
    }

    /// The budget has to reach `Prompts` for it to mean anything: a bound
    /// applied after the fact would cut a patch mid-hunk and leave the cache
    /// key describing context that was never sent.
    func testTheBudgetActuallyShrinksTheBuiltContext() throws {
        let budget = try XCTUnwrap(AIProviderRegistry.appleIntelligence.contextBudget)
        let patch = "@@ -1,1 +1,1 @@\n" + String(repeating: "+let value = 1\n", count: 800)
        let files = (1...6).map {
            PRFile(
                filename: "Sources/File\($0).swift", previousFilename: nil, status: .modified,
                additions: 800, deletions: 0, changes: 800, patch: patch
            )
        }
        let pullRequest = PullRequest(
            id: 1, number: 1, title: "Wide change", body: nil, state: .open, draft: false, merged: false,
            mergeableState: "clean", user: GitHubUser(login: "octocat", avatarUrl: nil),
            head: .init(ref: "feature", sha: "head1"), base: .init(ref: "main", sha: "base1"),
            additions: 4800, deletions: 0, changedFiles: 6, commits: 1, comments: 0, reviewComments: 0,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            htmlUrl: "https://github.com/acme/widget/pull/1", labels: []
        )

        let bounded = Prompts.buildContext(
            pullRequest: pullRequest, files: files,
            maxFileChars: budget.maxFileChars, maxTotalChars: budget.maxTotalChars
        )
        let unbounded = Prompts.buildContext(pullRequest: pullRequest, files: files)

        XCTAssertLessThanOrEqual(bounded.text.count, budget.maxTotalChars + 2000, "The bound must actually apply")
        XCTAssertLessThan(bounded.text.count, unbounded.text.count)
        XCTAssertFalse(bounded.analyzedFiles.isEmpty, "Trimming must not empty the context entirely")
    }

    // MARK: - Availability reporting

    func testEveryUnavailableReasonExplainsWhatToDoOrSaysThereIsNothingToDo() {
        let states: [AppleIntelligenceAvailability] = [
            .available, .requiresNewerMacOS, .deviceNotEligible, .notEnabled, .modelNotReady,
            .unknown("the system did not say why"),
        ]
        for state in states {
            XCTAssertFalse(state.explanation.isEmpty, "\(state) needs a message")
            XCTAssertTrue(state.explanation.hasSuffix("."), "\(state): messages are sentences")
        }
        XCTAssertTrue(AppleIntelligenceAvailability.notEnabled.explanation.contains("System Settings"))
        XCTAssertTrue(AppleIntelligenceAvailability.available.isAvailable)
        XCTAssertFalse(AppleIntelligenceAvailability.modelNotReady.isAvailable)
    }

    func testUnavailableSystemIsReportedAsConfigurationNotAsAMissingKey() {
        // Whatever this machine reports, the message must never send the
        // reviewer looking for an API key that does not exist.
        let description = AIProviderRegistry.appleIntelligence.needsAPIKey
        XCTAssertFalse(description)
    }

    func testFactoryReturnsAProviderOnlyWhenTheSystemCanServeIt() {
        let provider = AppleIntelligenceFactory.makeProvider()
        if AppleIntelligenceAvailability.current().isAvailable {
            XCTAssertNotNil(provider)
            XCTAssertEqual(provider?.id, "apple-intelligence")
        } else {
            XCTAssertNil(provider, "An unavailable system must not hand back a provider that cannot answer")
        }
    }

    // MARK: - Request shaping

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    func testTheSystemPromptBecomesInstructionsAndIsNotRepeatedInTheTurn() throws {
        let request = AIRequest(
            system: "Review only what you are shown.",
            messages: [ChatMessage(role: .user, content: "What changed in Sources/App.swift?")],
            model: "apple-on-device"
        )
        XCTAssertEqual(AppleIntelligenceProvider.instructions(for: request), "Review only what you are shown.")
        let prompt = AppleIntelligenceProvider.prompt(for: request)
        XCTAssertFalse(prompt.contains("Review only what you are shown."), "Instructions must not be sent twice")
        XCTAssertTrue(prompt.contains("Sources/App.swift"))
    }

    @available(macOS 26.0, *)
    func testARequestWithNoSystemPromptFallsBackToCodeReviewInstructionsThatCitePaths() {
        let request = AIRequest(messages: [ChatMessage(role: .user, content: "Summarise")], model: "apple-on-device")
        let instructions = AppleIntelligenceProvider.instructions(for: request)
        XCTAssertEqual(instructions, AppleIntelligenceInstructions.codeReview)
        XCTAssertTrue(instructions.contains("file path"), instructions)
        XCTAssertTrue(instructions.contains("exact path"), instructions)
        XCTAssertTrue(
            instructions.lowercased().contains("do not approve"),
            "The read-only product rule belongs in the instructions, not only in the UI"
        )
    }

    @available(macOS 26.0, *)
    func testAnOversizedPromptKeepsItsHeadAndItsQuestionAndSaysItWasTrimmed() {
        let head = "PR #7: Rework the cache\nFiles: Sources/Cache.swift, Sources/Store.swift\n"
        let bulk = String(repeating: "+ let cached = store.value(for: key)\n", count: 4000)
        let question = "\nUser:\nWhich file should I read first?"
        let trimmed = AppleIntelligenceProvider.bounded(head + bulk + question)

        XCTAssertLessThanOrEqual(trimmed.count, AppleIntelligenceProvider.maxPromptChars)
        XCTAssertTrue(trimmed.hasPrefix("PR #7: Rework the cache"), "The PR identity and file list must survive")
        XCTAssertTrue(trimmed.hasSuffix("Which file should I read first?"), "The question must survive")
        XCTAssertTrue(trimmed.contains("Context trimmed"), "A model reading a fragment must be told it is a fragment")
    }

    @available(macOS 26.0, *)
    func testAPromptInsideTheWindowIsNotTouched() {
        let prompt = "User:\nWhat changed?"
        XCTAssertEqual(AppleIntelligenceProvider.bounded(prompt), prompt)
    }

    @available(macOS 26.0, *)
    func testOutputTokensAreClampedToSomethingTheWindowCanHold() {
        var request = AIRequest(messages: [], model: "apple-on-device")
        request.maxOutputTokens = 99_999
        XCTAssertEqual(AppleIntelligenceProvider.options(for: request).maximumResponseTokens, 4096)
        request.maxOutputTokens = 1
        XCTAssertEqual(AppleIntelligenceProvider.options(for: request).maximumResponseTokens, 128)
    }

    @available(macOS 26.0, *)
    func testAnOverflowIsReportedAsSomethingTheReviewerCanActOn() {
        let error = AppleIntelligenceProvider.aiError(
            LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "too big"))
        )
        let message = try? XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message?.contains("too large for the on-device model") == true, message ?? "")
        XCTAssertTrue(message?.contains("Settings") == true, "Say where to switch provider")
    }

    @available(macOS 26.0, *)
    func testAModelStillDownloadingIsReportedAsConfigurationNotFailure() {
        let error = AppleIntelligenceProvider.aiError(
            LanguageModelSession.GenerationError.assetsUnavailable(.init(debugDescription: "not ready"))
        )
        guard case .missingConfiguration = error else {
            return XCTFail("A downloading model is a configuration state, got \(error)")
        }
    }
    #endif

    // MARK: - One real on-device request

    /// Runs for real when this Mac can serve Apple Intelligence, and skips
    /// with the system's own reason when it cannot. Unlike the cloud and CLI
    /// providers this costs nothing and needs no account, so it is not
    /// opt-in — it is the one provider whose end-to-end path CI can actually
    /// prove on a supported machine.
    func testAnswersAPromptOnDevice() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Apple Intelligence needs macOS 26.")
        }
        let availability = AppleIntelligenceAvailability.current()
        guard availability.isAvailable else {
            throw XCTSkip(availability.explanation)
        }
        let provider = try XCTUnwrap(AppleIntelligenceFactory.makeProvider())

        var chunks: [String] = []
        let response = try await provider.stream(AIRequest(
            system: AppleIntelligenceInstructions.codeReview,
            messages: [ChatMessage(role: .user, content: """
            PR #1: Guard the cache write

            Changed files:
            Sources/Cache.swift
            @@ -10,3 +10,4 @@
            +    guard !key.isEmpty else { return }
                 store[key] = value

            Name the one file this pull request changes.
            """)],
            model: "apple-on-device", maxOutputTokens: 200
        )) { chunks.append($0) }

        XCTAssertFalse(response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(response.elapsedMS, 0)
        XCTAssertEqual(response.model, "apple-on-device")
        XCTAssertNil(response.usage, "The framework reports no token counts and none may be invented")
        XCTAssertFalse(chunks.isEmpty, "Streaming must deliver at least one chunk")
        XCTAssertTrue(
            response.text.contains("Cache.swift"),
            "The instructions ask for the path it was given; got: \(response.text)"
        )
        #else
        throw XCTSkip("This SDK has no FoundationModels framework.")
        #endif
    }
}
