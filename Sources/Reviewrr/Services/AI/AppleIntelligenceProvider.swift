import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device Apple Intelligence model can answer right now.
///
/// Reported as Reviewrr's own vocabulary rather than the framework's so the
/// rest of the app — and the Settings row — compiles and reasons about it on
/// macOS 14, where `FoundationModels` does not exist at all.
enum AppleIntelligenceAvailability: Equatable {
    case available
    /// The framework needs macOS 26; this build runs on an earlier system.
    case requiresNewerMacOS
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unknown(String)

    var isAvailable: Bool { self == .available }

    /// What the reviewer can do about it. Never blames the user's hardware
    /// without saying so plainly, and never promises a remedy that does not
    /// exist — an ineligible Mac has none.
    var explanation: String {
        switch self {
        case .available:
            return "Ready. Requests stay on this Mac."
        case .requiresNewerMacOS:
            return "Apple Intelligence needs macOS 26 or later. Choose another provider on this system."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence. Choose another provider."
        case .notEnabled:
            return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again once System Settings reports it ready."
        case .unknown(let detail):
            // The detail comes from a future OS state this build does not
            // know, so it is punctuated here rather than trusted to be a
            // sentence already.
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentence = "Apple Intelligence is unavailable: \(trimmed)"
            return sentence.hasSuffix(".") ? sentence : sentence + "."
        }
    }

    static func current() -> AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .requiresNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown("the system did not say why")
            }
        @unknown default:
            return .unknown("the system reported a state this build does not know")
        }
        #else
        return .requiresNewerMacOS
        #endif
    }
}

/// Builds the provider when the system can actually serve it.
///
/// A separate factory because the provider type itself only exists on macOS
/// 26: this is the one place that has to know that, so `AIModel` does not.
enum AppleIntelligenceFactory {
    static func makeProvider() -> AIProvider? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligenceAvailability.current().isAvailable {
            return AppleIntelligenceProvider()
        }
        #endif
        return nil
    }
}

/// The instructions the on-device model reviews under.
///
/// Separate from `Prompts.analysisSystemPrompt` on purpose: that prompt
/// spends most of its budget specifying the `reviewrr.ai-review.v1` JSON
/// contract, which a 3-billion-parameter model will not hold alongside a
/// diff. This is the fallback for a request that arrives without a system
/// prompt, and it says the two things that matter — work only from the
/// supplied patches, and cite the paths you were given.
enum AppleIntelligenceInstructions {
    static let codeReview = """
    You are a code-review assistant reading one GitHub pull request on the reviewer's own Mac.

    Work only from the pull-request context you are given: its number, title, description, and the \
    changed-file patches, each introduced by its file path. Refer to files by the exact path shown \
    and quote the specific added or removed line you mean.

    Say what the change does, which file to read first, and what looks risky. Three specific \
    observations tied to paths beat a general summary.

    Never describe a file that is not in the context, and say plainly when the context does not \
    contain the answer. Do not approve or reject the pull request and do not write a review comment \
    — the reviewer decides that.
    """
}

#if canImport(FoundationModels)

/// Apple's on-device model as an `AIProvider`.
///
/// The provider with the strongest privacy story in the registry: no key, no
/// network request, no local process — the prompt never leaves the Mac. The
/// cost is the smallest context window of any provider here, so the request
/// is bounded hard before it is sent and an overflow is reported as
/// something the reviewer can act on rather than as a model failure.
@available(macOS 26.0, *)
struct AppleIntelligenceProvider: AIProvider {
    let id = AIProviderRegistry.appleIntelligence.id

    /// Characters of prompt the on-device window can take alongside its
    /// instructions and its own answer. The window is a few thousand tokens
    /// shared between all three, and this leaves room for the answer; it is
    /// deliberately below `AIProviderRegistry.appleIntelligence`'s context
    /// budget so a caller that ignores that budget still gets a reply rather
    /// than an overflow.
    static let maxPromptChars = 7000

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let started = Date()
        let session = LanguageModelSession(instructions: Self.instructions(for: request))
        do {
            let response = try await session.respond(to: Self.prompt(for: request), options: Self.options(for: request))
            return AIResponse(
                text: response.content, model: AIProviderRegistry.appleIntelligence.defaultModel,
                elapsedMS: Int(Date().timeIntervalSince(started) * 1000), usage: nil
            )
        } catch {
            throw Self.aiError(error)
        }
    }

    func stream(_ request: AIRequest, onChunk: @escaping @Sendable (String) -> Void) async throws -> AIResponse {
        let started = Date()
        let session = LanguageModelSession(instructions: Self.instructions(for: request))
        var text = ""
        do {
            let stream = session.streamResponse(to: Self.prompt(for: request), options: Self.options(for: request))
            // Snapshots are cumulative, but `AIProvider.stream` promises
            // deltas — the panel appends what it is handed — so only the new
            // tail goes to the caller.
            for try await snapshot in stream {
                try Task.checkCancellation()
                let whole = snapshot.content
                guard whole.count > text.count else { continue }
                let delta = String(whole.dropFirst(text.count))
                text = whole
                onChunk(delta)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.aiError(error)
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("Apple Intelligence produced no answer.")
        }
        return AIResponse(
            text: text, model: AIProviderRegistry.appleIntelligence.defaultModel,
            elapsedMS: Int(Date().timeIntervalSince(started) * 1000), usage: nil
        )
    }

    // MARK: - Request shaping

    static func instructions(for request: AIRequest) -> String {
        guard let system = request.system?.trimmingCharacters(in: .whitespacesAndNewlines), !system.isEmpty else {
            return AppleIntelligenceInstructions.codeReview
        }
        return system
    }

    static func prompt(for request: AIRequest) -> String {
        bounded(AgentPrompt.flatten(request, includeSystem: false))
    }

    /// Trims the middle, not the end. The head carries the PR identity and
    /// the file list, and the tail carries the reviewer's actual question;
    /// dropping either to keep diff bulk would answer the wrong thing. The
    /// cut is stated in the prompt so the model does not treat the remaining
    /// patches as the whole change.
    static func bounded(_ prompt: String) -> String {
        guard prompt.count > maxPromptChars else { return prompt }
        let notice = "\n\n[Context trimmed to fit the on-device model. Some patches are missing; say so if the answer needs them.]\n\n"
        let keep = maxPromptChars - notice.count
        let head = keep * 2 / 3
        let tail = keep - head
        return String(prompt.prefix(head)) + notice + String(prompt.suffix(tail))
    }

    static func options(for request: AIRequest) -> GenerationOptions {
        // Greedy sampling: a review that changes its mind between runs on the
        // same diff is worse than a slightly duller one, and the analysis
        // cache keys on the request rather than the reply.
        GenerationOptions(
            sampling: .greedy,
            temperature: nil,
            maximumResponseTokens: min(max(request.maxOutputTokens, 128), 4096)
        )
    }

    // MARK: - Errors

    static func aiError(_ error: Error) -> AIProviderError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .invalidResponse("Apple Intelligence failed: \(error.localizedDescription)")
        }
        switch generationError {
        case .exceededContextWindowSize:
            return .unsupported(
                "This pull request is too large for the on-device model. Ask about a single file, or choose a "
                    + "cloud provider in Settings → AI provider."
            )
        case .assetsUnavailable:
            return .missingConfiguration(AppleIntelligenceAvailability.modelNotReady.explanation)
        case .guardrailViolation, .refusal:
            // The model declined. Its own explanation is available
            // asynchronously, which this synchronous mapping cannot wait for,
            // so the message says what happened rather than inventing a why.
            return .invalidResponse("Apple Intelligence declined to answer this request.")
        case .concurrentRequests:
            return .network("Apple Intelligence is already answering another request. Try again in a moment.")
        case .unsupportedLanguageOrLocale:
            return .unsupported("Apple Intelligence does not support this language. Choose another provider.")
        case .rateLimited:
            return .network("Apple Intelligence is rate limited on this Mac. Try again shortly.")
        case .decodingFailure, .unsupportedGuide:
            return .invalidResponse("Apple Intelligence returned a response Reviewrr could not read.")
        @unknown default:
            return .invalidResponse("Apple Intelligence failed: \(generationError.localizedDescription)")
        }
    }
}

#endif
