import SwiftUI

/// The AI right rail: Ask, Analysis, and Findings. This view is AI only —
/// GitHub comment/thread conversation UI lives in `Views/Conversation/**`
/// and is reached through the rail switcher in the inspector column's
/// toolbar.
///
/// AI is strictly read-only here: `onNavigate` moves the central diff to a
/// line, and `onCreateDraft` hands a citation to the workspace so a human
/// can turn it into a local draft comment. Neither this view nor `AIModel`
/// ever posts to GitHub or edits code — which is exactly why the panel
/// wears the purple AI identity from top to bottom: nothing in it should
/// ever be mistaken for something GitHub said.
struct AIPanelView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: AIModel
    /// Which panel the inspector is showing. Bound rather than local: the
    /// switcher in this panel's header is how the reviewer reaches the
    /// conversation panel, so it has to change the inspector's own state.
    @Binding var rail: AppModel.InspectorRail
    var onNavigate: (String, Int) -> Void
    var onCreateDraft: (String, Int, DiffSide, String) -> Void

    @State private var tab: Tab = .ask
    /// Whether the selected provider is usable. Cached rather than read in
    /// `body`: the panel re-renders on every streamed chunk, and the check
    /// touches the Keychain and the filesystem. Refreshed when the provider
    /// changes and whenever this window's active state does — which is what
    /// happens on the way back from the Settings window, so a key saved
    /// there is reflected here without the reviewer doing anything else.
    @State private var providerConfigured: Bool
    /// Who would answer, in display terms. Cached for the same reason:
    /// `AIProviderRegistry.descriptor(for:)` is a linear scan of the
    /// registry, and the header asked it three times per render.
    @State private var providerLabel: AIProviderLabel
    /// The shape of the current analysis, reduced to the handful of facts
    /// the header prints. Derived once per analysis rather than per render:
    /// finding counts and worst-severity need a pass over the findings, and
    /// `body` runs on every chunk of a streaming *Ask* answer, which cannot
    /// change any of this.
    @State private var facts: AIAnalysisFacts
    @Environment(\.controlActiveState) private var controlActiveState

    enum Tab: String, CaseIterable, Identifiable {
        case ask = "Ask"
        case analysis = "Analysis"
        case findings = "Findings"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .ask: return "bubble.and.sparkles"
            case .analysis: return "doc.text.magnifyingglass"
            case .findings: return "exclamationmark.magnifyingglass"
            }
        }

        var help: String {
            switch self {
            case .ask: return "Ask a question about this pull request"
            case .analysis: return "The full structured analysis"
            case .findings: return "Findings only, ranked by severity"
            }
        }
    }

    init(
        model: AIModel,
        rail: Binding<AppModel.InspectorRail>,
        onNavigate: @escaping (String, Int) -> Void,
        onCreateDraft: @escaping (String, Int, DiffSide, String) -> Void
    ) {
        self.model = model
        self._rail = rail
        self.onNavigate = onNavigate
        self.onCreateDraft = onCreateDraft
        _providerConfigured = State(initialValue: model.isProviderConfigured)
        _providerLabel = State(initialValue: AIProviderLabel(providerID: model.providerID, modelID: model.modelID))
        _facts = State(initialValue: AIAnalysisFacts(state: model.analysisState))
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorIdentityHeader(
                rail: .ai,
                subtitle: { subtitleLine },
                // Empty: the rail switcher sits in the inspector's own
                // toolbar band, above this header, so it is not repeated
                // inside each panel.
                trailing: { EmptyView() },
                status: { statusStrip }
            )
            InspectorTabBar(tabs: tabs, selection: $tab, tint: AIVisualStyle.accent)

            Group {
                switch tab {
                case .ask:
                    AskTabView(model: model, onNavigate: onNavigate)
                case .analysis:
                    AnalysisTabView(model: model, onNavigate: onNavigate, onCreateDraft: onCreateDraft)
                case .findings:
                    FindingsTabView(model: model, onNavigate: onNavigate, onCreateDraft: onCreateDraft)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .id(tab)
            // A cross-fade, not a slide. Switching tabs inside a panel is
            // not content arriving from off-screen, and the app no longer
            // slides anything sideways — the surface swap on opening a pull
            // request was the last one, and it reads as an overlay.
            .motionTransition(.opacity)
            .motion(Motion.smooth, value: tab)
        }
        .onChange(of: model.providerID) { _, _ in refreshProvider() }
        .onChange(of: model.modelID) { _, _ in refreshProvider() }
        .onChange(of: controlActiveState) { _, _ in providerConfigured = model.isProviderConfigured }
        // Comparing the whole `AnalysisState` here would mean an equality
        // pass over every finding on every render; the stamp is the cheap
        // identity of a result, which is all that has to change to make the
        // facts stale.
        .onChange(of: analysisStamp) { _, _ in
            facts = AIAnalysisFacts(state: model.analysisState)
        }
    }

    /// A cheap identity for the current analysis, for change detection.
    /// Two different results never share one: a run stamps its own
    /// completion time.
    private var analysisStamp: String {
        switch model.analysisState {
        case .idle: return "idle"
        case .loading: return "loading"
        case .failed(let message): return "failed:\(message.count)"
        case .ready(let presentation):
            return "ready:\(presentation.generatedAt.timeIntervalSinceReferenceDate):\(presentation.providerID)"
        }
    }

    private func refreshProvider() {
        providerConfigured = model.isProviderConfigured
        providerLabel = AIProviderLabel(providerID: model.providerID, modelID: model.modelID)
    }

    private var tabs: [InspectorTab<Tab>] {
        Tab.allCases.map { tab in
            InspectorTab(
                value: tab, title: tab.rawValue, symbol: tab.symbol, help: tab.help,
                badge: tab == .findings ? facts.findingCount : nil,
                badgeDescription: { "\($0) finding\($0 == 1 ? "" : "s")" }
            )
        }
    }

    // MARK: - Identity line

    /// The one line under the panel's name. It always opens with the
    /// capability statement, because "read-only" is the fact that keeps
    /// everything below it from being mistaken for something that acts on
    /// GitHub, and then says what state the analysis is actually in —
    /// including, on first run, that nothing has been sent anywhere yet.
    @ViewBuilder
    private var subtitleLine: some View {
        HStack(spacing: 0) {
            Text("Read-only · ")
            switch facts.kind {
            case .none:
                Text(model.autoAnalysisSkip == nil ? "nothing analyzed yet" : "waiting for you to ask")
            case .running:
                Text("reading this pull request")
            case .failed:
                Text("last run failed")
            case .unstructured, .clean, .findings:
                Text(facts.sourceLabel.lowercased() + ", ")
                if let generatedAt = facts.generatedAt {
                    Text(generatedAt, style: .relative)
                    Text(" ago")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitleAccessibilityLabel)
    }

    private var subtitleAccessibilityLabel: String {
        switch facts.kind {
        case .none:
            return model.autoAnalysisSkip == nil
                ? "Read-only. Nothing analyzed yet."
                : "Read-only. Automatic analysis stood down; waiting for you to ask."
        case .running: return "Read-only. Reading this pull request."
        case .failed: return "Read-only. The last analysis failed."
        case .unstructured, .clean, .findings: return "Read-only. Analysis \(facts.sourceLabel.lowercased())."
        }
    }

    // MARK: - Status strip

    /// Which model would answer, whether it can, what its last answer looks
    /// like, and the one action worth offering — the facts a reviewer needs
    /// before trusting anything in the panel, so they sit above the tabs
    /// rather than behind one.
    ///
    /// The row this replaces printed the selected provider and model
    /// unconditionally and offered a prominent Analyze next to them, having
    /// consulted nothing about whether a key, a base URL, or an installed
    /// binary existed. On first run that named a provider that could not
    /// answer, and the reviewer found out by pressing the button and reading
    /// a red caption.
    private var statusStrip: some View {
        HStack(spacing: Theme.Space.s) {
            providerMenu
            Spacer(minLength: Theme.Space.xs)
            // The state and the action keep their width in a 400pt column;
            // the provider id truncates before either of them gives ground.
            stateChip.layoutPriority(1)
            primaryAction.layoutPriority(1)
        }
        .motion(Motion.smooth, value: providerConfigured)
        .motion(Motion.smooth, value: facts)
    }

    private var providerMenu: some View {
        Menu {
            Picker("AI provider", selection: providerBinding) {
                ForEach(AIProviderRegistry.all) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: providerConfigured ? "cpu" : "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(providerConfigured ? Color.secondary : StatusPalette.orange.label)
                Text(providerLabel.name)
                    .font(.system(size: Theme.captionSize, weight: .medium))
                    .lineLimit(1)
                Text(providerConfigured ? providerLabel.model : "Not configured")
                    .font(.system(size: Theme.captionSize - 1))
                    .foregroundStyle(providerConfigured ? Color.secondary : StatusPalette.orange.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        // Not `fixedSize()`: a long model id used to push the chip and the
        // button off the right edge of a 400pt column. The name holds, the
        // id truncates in the middle, and the actions keep their room.
        .frame(maxWidth: 160, alignment: .leading)
        .help(providerHelp)
        .accessibilityLabel(providerAccessibilityLabel)
    }

    /// What the last analysis amounts to, in one chip: how many findings and
    /// how bad the worst one is, or the honest alternative when there are
    /// none, when the reply could not be parsed, or when the run failed.
    /// Colour is never carrying this alone — each chip states its own count
    /// and severity in words, with a distinct glyph behind it.
    @ViewBuilder
    private var stateChip: some View {
        switch facts.kind {
        case .none:
            EmptyView()
        case .running:
            // The panel's single in-flight indicator. The tab bodies below
            // say what they are waiting for in words instead — one pulse
            // per panel, at the top, where the state of the whole rail
            // belongs.
            PulsingStatusChip(text: "Analyzing…", palette: AIVisualStyle.palette)
                .help("An analysis is running for this pull request")
                .accessibilityLabel("Analyzing this pull request")
        case .failed:
            StatusChip(text: "Failed", systemImage: "exclamationmark.triangle.fill", palette: .red)
                .help("The last analysis failed — open the Analysis tab for the provider's message")
                .accessibilityLabel("The last analysis failed")
        case .unstructured:
            StatusChip(text: "Unparsed", systemImage: "text.badge.xmark", palette: .orange)
                .help("The provider replied, but not in the structured shape Reviewrr can rank")
                .accessibilityLabel("The provider's reply could not be parsed into a structured analysis")
        case .clean:
            StatusChip(text: "No findings", systemImage: "checkmark.seal.fill", palette: .green)
                .help("The analysis flagged nothing in the files it read")
                .accessibilityLabel("No findings in the analyzed files")
        case .findings(let count, let worst):
            StatusChip(
                text: "\(count) · \(worst.label)",
                systemImage: AIVisualStyle.severitySymbol(worst),
                palette: AIVisualStyle.severityPalette(worst)
            )
            .help("\(count) finding\(count == 1 ? "" : "s"), most severe: \(worst.label)")
            .accessibilityLabel("\(count) finding\(count == 1 ? "" : "s"), most severe \(worst.label)")
        }
    }

    /// The primary action stays in the app's accent colour rather than AI
    /// purple. Purple in this app means "a model said this"; a button is
    /// something the *reviewer* does, and the one thing this panel must
    /// never do is blur those two.
    @ViewBuilder
    private var primaryAction: some View {
        if model.isAnalyzing {
            Button("Cancel") { model.cancel() }
                .buttonStyle(.reviewrrSecondary)
                .controlSize(.small)
                .help("Stop the in-flight analysis")
                .accessibilityLabel("Stop the in-flight analysis")
        } else if !providerConfigured {
            // The remedy instead of the button that cannot work yet.
            Button { openSettings(.ai) } label: {
                Label("Set up", systemImage: "gearshape")
                    .font(.system(size: Theme.captionSize, weight: .medium))
            }
            .buttonStyle(.reviewrrPrimary)
            .controlSize(.small)
            .help(model.providerConfigurationHint)
            .accessibilityLabel("Set up \(providerLabel.name) in Settings")
        } else if facts.hasResult {
            Button {
                Task { await model.analyze(force: true) }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
                    .font(.system(size: Theme.captionSize, weight: .medium))
            }
            .buttonStyle(.reviewrrSecondary)
            .controlSize(.small)
            .help("Discard this result and analyze the pull request again")
            .accessibilityLabel("Re-run the analysis")
        } else {
            Button(facts.kind == .failed ? "Retry" : "Analyze") {
                Task { await model.analyze(force: true) }
            }
            .buttonStyle(.reviewrrPrimary)
            .controlSize(.small)
            .help("Send this pull request to \(providerLabel.name) and read back an analysis")
            .accessibilityLabel(facts.kind == .failed ? "Retry the analysis" : "Analyze this pull request")
        }
    }

    private var providerHelp: String {
        providerConfigured
            ? "AI provider: \(providerLabel.name), model \(providerLabel.model)"
            : model.providerConfigurationHint
    }

    private var providerAccessibilityLabel: String {
        providerConfigured
            ? "AI provider, \(providerLabel.name), model \(providerLabel.model)"
            : "AI provider, \(providerLabel.name), not configured"
    }

    private var providerBinding: Binding<String> {
        Binding(get: { model.providerID }, set: { model.selectProvider($0) })
    }
}

/// The provider and model the header prints, resolved once per selection.
private struct AIProviderLabel: Equatable {
    let name: String
    let model: String

    init(providerID: String, modelID: String) {
        let descriptor = AIProviderRegistry.descriptor(for: providerID)
        name = descriptor.displayName
        if !modelID.isEmpty {
            model = modelID
        } else if !descriptor.defaultModel.isEmpty {
            model = descriptor.defaultModel
        } else {
            // The ACP agents pick their own model from an account-specific
            // list, so there is no id to show — say that rather than render
            // a gap.
            model = "agent default"
        }
    }
}

/// Everything the header says about the current analysis, flattened out of
/// `AIModel.AnalysisState` so no render has to walk the findings again.
///
/// Nothing here is ever inferred: `.clean` is only produced by a structured
/// result that really carries zero findings, and a reply that could not be
/// parsed stays `.unstructured` rather than being counted as either.
private struct AIAnalysisFacts: Equatable {
    enum Kind: Equatable {
        case none
        case running
        case failed
        case unstructured
        case clean
        case findings(count: Int, worst: AnalysisSeverity)
    }

    var kind: Kind = .none
    var generatedAt: Date?
    var sourceLabel: String = ""

    var findingCount: Int {
        if case .findings(let count, _) = kind { return count }
        return 0
    }

    /// Whether there is a result on screen to re-run *over*. A failure is
    /// not one: the action there is Retry, not Re-run.
    var hasResult: Bool {
        switch kind {
        case .unstructured, .clean, .findings: return true
        case .none, .running, .failed: return false
        }
    }

    init(state: AIModel.AnalysisState) {
        switch state {
        case .idle:
            kind = .none
        case .loading:
            kind = .running
        case .failed:
            kind = .failed
        case .ready(let presentation):
            generatedAt = presentation.generatedAt
            switch presentation.source {
            case .cache: sourceLabel = "Cached"
            case .fresh: sourceLabel = "Fresh"
            case .heuristic: sourceLabel = "Heuristic"
            }
            switch presentation.outcome {
            case .unstructured:
                kind = .unstructured
            case .structured(let result):
                if let worst = result.findings.map(\.severity).min() {
                    kind = .findings(count: result.findings.count, worst: worst)
                } else {
                    kind = .clean
                }
            }
        }
    }

}
