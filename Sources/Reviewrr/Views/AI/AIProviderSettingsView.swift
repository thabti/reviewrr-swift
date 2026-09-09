import SwiftUI

/// Provider selection, key entry, model/effort choice, and a live
/// connection test. Track B embeds this as `AnyView` in the Settings
/// window, so it must compile and behave standalone from just an `AIModel`.
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIModel

    @State private var apiKeyInput: String = ""
    @State private var modelNameCommit: Task<Void, Never>?
    @State private var baseURLInput: String = ""
    @State private var customModelInput: String = ""
    @State private var savedKeyPresent: Bool = false
    @State private var showKeySavedConfirmation = false
    /// Nil until the probe answers; the row shows a checking state rather
    /// than claiming the tool is missing while the answer is still in flight.
    @State private var agentAvailability: AgentAvailability?
    @State private var isProbingAgent = false

    init(model: AIModel) {
        self.model = model
    }

    private var descriptor: AIProviderDescriptor { AIProviderRegistry.descriptor(for: model.providerID) }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: providerBinding) {
                    ForEach(AIProviderRegistry.all) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
                .accessibilityLabel("AI provider")
            }

            if descriptor.id == AIProviderRegistry.appleIntelligence.id {
                appleIntelligenceSection
            }

            if let spec = descriptor.localAgent {
                localAgentSection(spec: spec)
            }

            if descriptor.needsBaseURL {
                Section {
                    // A visible label in the leading column rather than a
                    // placeholder carrying the field's meaning: a placeholder
                    // disappears the moment anyone types, taking the only
                    // description of the field with it.
                    TextField("Base URL", text: $baseURLInput, prompt: Text("http://localhost:1234/v1"))
                        .onSubmit(saveBaseURL)
                    HStack {
                        Spacer()
                        Button("Save Endpoint") { saveBaseURL() }
                            .help("Store this base URL for the selected provider")
                            .accessibilityLabel("Save the base URL")
                            .disabled(baseURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Endpoint")
                } footer: {
                    Text("An OpenAI-compatible server reachable from this Mac — LM Studio, a local proxy, or a self-hosted gateway.")
                }
            }

            if descriptor.needsAPIKey {
                Section {
                    // Never displayed in plain text and never logged — this
                    // field only ever writes into the Keychain.
                    SecureField(
                        "API Key", text: $apiKeyInput,
                        prompt: Text(savedKeyPresent ? "Saved — type to replace" : "Paste your key")
                    )
                    .accessibilityLabel("\(descriptor.displayName) API key")

                    HStack(spacing: Theme.Space.s) {
                        if showKeySavedConfirmation {
                            Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .motionTransition(.opacity)
                        }
                        Spacer()
                        if savedKeyPresent {
                            Button("Remove Key", role: .destructive) { removeKey() }
                                .help("Delete this provider's key from the Keychain")
                                .accessibilityLabel("Remove this provider's API key")
                        }
                        Button("Save Key") { saveKey() }
                            .help("Store this key in the macOS Keychain — never logged or written elsewhere")
                            .accessibilityLabel("Save the API key to the Keychain")
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .motion(Motion.smooth, value: showKeySavedConfirmation)
                } header: {
                    Text("API key")
                } footer: {
                    Text("Stored in the macOS Keychain only — never logged, printed, or displayed once saved.")
                }
            }

            Section("Model") {
                if !descriptor.models.isEmpty {
                    Picker("Suggested models", selection: suggestedModelBinding) {
                        Text("Custom…").tag("")
                        ForEach(descriptor.models) { option in
                            Text(option.label).tag(option.modelID)
                        }
                    }
                    .accessibilityLabel("Suggested models")
                }
                TextField(
                    "Model", text: $customModelInput,
                    prompt: Text(descriptor.defaultModel.isEmpty ? "Model name" : descriptor.defaultModel)
                )
                .accessibilityLabel("Model name")
                .onSubmit { commitModelName() }
                // Debounced, not per character: `selectModel` re-encodes and
                // rewrites the whole settings blob, republishes `AppModel`,
                // and re-reads which providers hold a key — a Keychain query
                // each — so typing a model name paid all of that per
                // keystroke.
                .onChange(of: customModelInput) { _, _ in
                    modelNameCommit?.cancel()
                    modelNameCommit = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        commitModelName()
                    }
                }
            }

            if descriptor.supportsReasoningEffort {
                Section("Reasoning effort") {
                    Picker("Effort", selection: effortBinding) {
                        ForEach(descriptor.efforts, id: \.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Reasoning effort")
                }
            }

            Section {
                Toggle("Analyze automatically when a pull request opens", isOn: autoAnalyzeBinding)
                    .help("Runs an analysis as soon as a pull request opens, if it is under the file limit below")
                    .accessibilityLabel("Analyze automatically when a pull request opens")
                Stepper(value: maxFilesBinding, in: 1...500, step: 5) {
                    Text("Skip PRs with more than \(model.autoAnalyzeMaxFiles) changed files")
                }
                .disabled(!model.autoAnalyzeOnOpen)
                .accessibilityLabel("Automatic analysis file limit, \(model.autoAnalyzeMaxFiles) files")

                Stepper(value: agentIdleTimeoutBinding, in: 30...900, step: 30) {
                    Text("Give a command-line agent \(Int(model.settingsSnapshot.aiAgentIdleTimeoutSeconds))s of silence before giving up")
                }
                .help("Idle time, not total time: a long analysis is fine, and this only fires when the agent stops producing output.")
                .accessibilityLabel("Agent idle timeout, \(Int(model.settingsSnapshot.aiAgentIdleTimeoutSeconds)) seconds")
            } header: {
                Text("Automatic analysis")
            } footer: {
                Text("A very large pull request costs the most to analyze and is the least likely to reduce to one useful overview. Past the limit nothing is sent until you press Analyze.")
            }

            Section("Test connection") {
                testSection
            }
        }
        .formStyle(.grouped)
        .onAppear { loadFieldsForCurrentProvider() }
        .task(id: model.providerID) { await refreshAgentAvailability(force: false) }
        // Leaving the pane must not lose a model name typed inside the
        // debounce window.
        .onDisappear { commitModelName() }
    }

    // MARK: - Apple Intelligence status

    @ViewBuilder
    private var appleIntelligenceSection: some View {
        let availability = AppleIntelligenceAvailability.current()
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(availability.isAvailable ? .green : .orange)
                Text(availability.explanation)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("On-device model")
        } footer: {
            // The reason to pick this one, and the reason not to, in the
            // order a reviewer needs them.
            Text("No key, no account, and no network request: the pull request never leaves this Mac. Its context window is the smallest of any provider here, so a large diff is trimmed before it is sent and a very large one is refused with a note rather than answered from a fragment.")
        }
    }

    // MARK: - Local agent status

    @ViewBuilder
    private func localAgentSection(spec: AgentBinarySpec) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(spec: spec))
                        .font(.callout)
                    if let detail = statusDetail(spec: spec) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Button("Check Again") {
                    Task { await refreshAgentAvailability(force: true) }
                }
                .disabled(isProbingAgent)
                .help("Look for the agent's command-line tool again")
                .accessibilityLabel("Check again whether this agent is installed")
                .accessibilityLabel("Check again whether \(spec.commandName) is installed")
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Local agent")
        } footer: {
            // The trade this provider makes, stated where the choice is made.
            Text("Reviewrr runs \(spec.commandName) on this Mac using your own login for it — no key is stored here. Each request gets an empty temporary folder and is stopped after \(Int(AgentEnvironment.defaultTimeout))s. A local agent runs with your account's privileges; only install ones you trust.")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isProbingAgent && agentAvailability == nil {
            ProgressView().controlSize(.small)
        } else if agentAvailability?.isAvailable == true {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func statusTitle(spec: AgentBinarySpec) -> String {
        guard let availability = agentAvailability else {
            return isProbingAgent ? "Looking for \(spec.commandName)…" : "\(spec.commandName) status unknown"
        }
        return availability.isAvailable ? "\(spec.commandName) is installed" : "\(spec.commandName) is not usable"
    }

    private func statusDetail(spec: AgentBinarySpec) -> String? {
        guard let availability = agentAvailability else { return nil }
        if let reason = availability.failureReason { return reason }
        let version = availability.version.map { "\($0) · " } ?? ""
        return version + (availability.path ?? "")
    }

    private func refreshAgentAvailability(force: Bool) async {
        guard let spec = descriptor.localAgent else {
            agentAvailability = nil
            return
        }
        isProbingAgent = true
        defer { isProbingAgent = false }
        // "Check again" means check again: the resolved path is memoized for
        // five minutes so the AI panel is not stat-ing the filesystem inside
        // its own initialiser, and someone who has just installed the CLI is
        // asking exactly the question that memo would answer wrongly.
        if force { AgentEnvironment.invalidateResolvedPaths() }
        agentAvailability = await AgentAvailabilityProbe.shared.availability(for: spec, refresh: force)
    }

    // MARK: - Test connection

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Prominent because it is this pane's one primary action, and
            // plain-titled because a glyph inside a macOS push button reads
            // as decoration next to the system's own buttons.
            Button("Test Connection") {
                Task { await model.testSelectedProvider() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTesting)
            .help("Send one short prompt to check the provider answers with these settings")
            .accessibilityLabel("Test the connection to this provider")

            switch model.testState {
            case .idle:
                EmptyView()
            case .running(let partial):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(partial.isEmpty ? "Connecting…" : partial)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            case .success(let providerName, let modelUsed, let elapsedMS, let firstLine, let usage):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(providerName) · \(modelUsed) · \(elapsedMS) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("“\(firstLine)”").font(.callout).italic()
                    if let usage, let label = usageLabel(usage) {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .motion(Motion.smooth, value: model.testState)
    }

    private var isTesting: Bool {
        if case .running = model.testState { return true }
        return false
    }

    private func usageLabel(_ usage: AIUsage) -> String? {
        var parts: [String] = []
        if let input = usage.inputTokens { parts.append("\(input) in") }
        if let output = usage.outputTokens { parts.append("\(output) out") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " tokens"
    }

    // MARK: - Bindings

    private var providerBinding: Binding<String> {
        Binding(
            get: { model.providerID },
            set: { newValue in
                model.selectProvider(newValue)
                loadFieldsForCurrentProvider()
            }
        )
    }

    private var suggestedModelBinding: Binding<String> {
        Binding(
            get: { descriptor.models.contains { $0.modelID == model.modelID } ? model.modelID : "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                customModelInput = newValue
                model.selectModel(newValue)
            }
        )
    }

    /// The idle budget a command-line agent gets. Lives here rather than only
    /// in `AI_AGENT_TIMEOUT_MS` because an environment variable is not a
    /// setting: the reviewer who hits the timeout is reading an error inside
    /// the app, not a shell profile.
    private var agentIdleTimeoutBinding: Binding<Double> {
        Binding(
            get: { model.settingsSnapshot.aiAgentIdleTimeoutSeconds },
            set: { model.setAgentIdleTimeout($0) }
        )
    }

    private var autoAnalyzeBinding: Binding<Bool> {
        Binding(get: { model.autoAnalyzeOnOpen }, set: { model.setAutoAnalyzeOnOpen($0) })
    }

    private var maxFilesBinding: Binding<Int> {
        Binding(get: { model.autoAnalyzeMaxFiles }, set: { model.setAutoAnalyzeMaxFiles($0) })
    }

    private var effortBinding: Binding<String> {
        Binding(get: { model.reasoningEffort }, set: { model.selectReasoningEffort($0) })
    }

    // MARK: - Field loading and persistence

    private func loadFieldsForCurrentProvider() {
        apiKeyInput = ""
        savedKeyPresent = KeychainStore.load(account: descriptor.keychainAccount)?.isEmpty == false
        baseURLInput = AIProviderPreferences.load().customBaseURLs[model.providerID] ?? ""
        customModelInput = model.modelID
        showKeySavedConfirmation = false
    }

    private func commitModelName() {
        modelNameCommit?.cancel()
        modelNameCommit = nil
        guard model.modelID != customModelInput else { return }
        model.selectModel(customModelInput)
    }

    private func saveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, account: descriptor.keychainAccount)
        apiKeyInput = ""
        savedKeyPresent = true
        showKeySavedConfirmation = true
        // The composer's model menu lists only providers that can answer;
        // this one just became one of them.
        model.refreshReadyProviders()
        // Self-dismissing rather than requiring a click to clear — this is
        // a confirmation, not a message that needs acknowledging.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            showKeySavedConfirmation = false
        }
    }

    private func removeKey() {
        KeychainStore.delete(account: descriptor.keychainAccount)
        savedKeyPresent = false
        showKeySavedConfirmation = false
    }

    private func saveBaseURL() {
        AIProviderPreferences.setBaseURL(baseURLInput, for: model.providerID)
    }
}
