import SwiftUI

/// One finding: severity/category/confidence always visible, with evidence,
/// explanation, and the jump/draft actions revealed on expansion so a dense
/// findings list reads as scannable headlines first — a wall of raw model
/// text defeats the "quiet companion" goal just as badly as no findings UI
/// at all. Only findings anchored to code get the disclosure at all; an
/// unanchored finding has nothing further to show.
struct FindingRowView: View {
    let finding: AnalysisFinding
    var onNavigate: (String, Int) -> Void
    var onCreateDraft: (String, Int, DiffSide, String) -> Void
    /// Whether the reviewer already turned this finding into a draft. A
    /// review runs over days: offering "Draft comment" again on something
    /// they dealt with yesterday is how a panel loses their trust.
    var alreadyDrafted: Bool = false

    /// Collapsed by default, which is what "scannable headlines first" in
    /// the doc comment above actually requires — expanding everything made
    /// the list the wall of model text it was meant to avoid. Blocker and
    /// high open on arrival: those are the ones a reviewer is going to read
    /// anyway, and making them ask for the evidence buys nothing.
    @State private var expanded: Bool

    init(
        finding: AnalysisFinding,
        onNavigate: @escaping (String, Int) -> Void,
        onCreateDraft: @escaping (String, Int, DiffSide, String) -> Void,
        alreadyDrafted: Bool = false
    ) {
        self.finding = finding
        self.onNavigate = onNavigate
        self.onCreateDraft = onCreateDraft
        self.alreadyDrafted = alreadyDrafted
        _expanded = State(initialValue: finding.severity == .blocker || finding.severity == .high)
    }

    private var isExpandable: Bool { !finding.evidence.isEmpty || finding.suggestion?.isEmpty == false || finding.citation != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(finding.title).font(.callout.weight(.semibold))
            if expanded {
                Text(finding.explanation).font(.callout).foregroundStyle(.secondary)
                if !finding.evidence.isEmpty {
                    Text(finding.evidence)
                        .font(Theme.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 6))
                }
                if let suggestion = finding.suggestion, !suggestion.isEmpty {
                    Text("Suggestion: \(suggestion)").font(.caption).foregroundStyle(.secondary)
                }
                if let path = finding.path, let line = finding.startLine, let citation = finding.citation {
                    HStack(spacing: 8) {
                        CitationJumpButton(label: citation, fullPath: path) { onNavigate(path, line) }
                        if alreadyDrafted {
                            Label("Drafted", systemImage: "checkmark.bubble")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .help("You already drafted a comment from this finding")
                                .accessibilityLabel("Already drafted a comment from this finding")
                        } else {
                            DraftFromAIButton(target: citation) { onCreateDraft(path, line, finding.side ?? .right, draftBody) }
                        }
                    }
                }
            } else {
                Text(finding.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aiCard()
        .motion(Motion.snappy, value: expanded)
        // The card owns the expand toggle and (when anchored) the jump and
        // draft buttons; `.combine` flattened all three out of VoiceOver's
        // reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(finding.severity.label) finding: \(finding.title)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            SeverityBadge(severity: finding.severity)
            Text(finding.category.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.0f%% confidence", finding.confidence * 100))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if isExpandable {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
                .help(expanded ? "Collapse finding" : "Expand finding")
                .accessibilityLabel(expanded ? "Collapse finding" : "Expand finding")
                .motion(Motion.snappy, value: expanded)
            }
        }
    }

    private var draftBody: String {
        guard let suggestion = finding.suggestion, !suggestion.isEmpty else { return finding.explanation }
        return "\(finding.explanation)\n\nSuggestion: \(suggestion)"
    }
}

/// The Findings tab: every finding from the current analysis, most severe
/// first — the schema doc's prescribed order — with nothing else. The
/// Analysis tab shows the same findings inline as one section among many.
struct FindingsTabView: View {
    @ObservedObject var model: AIModel
    var onNavigate: (String, Int) -> Void
    var onCreateDraft: (String, Int, DiffSide, String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch model.analysisState {
                case .idle:
                    idleState
                case .loading:
                    loadingState
                case .failed(let message):
                    AIAnalysisFailureView(model: model, message: message)
                case .ready(let presentation):
                    content(for: presentation)
                }
            }
            .padding(Theme.Space.m)
            .motion(Motion.smooth, value: model.analysisState)
        }
    }

    /// The Analysis tab owns the full first-run pitch; repeating it here
    /// would be the same paragraph twice behind two tabs. This says what
    /// this tab specifically holds, and offers the same one action.
    private var idleState: some View {
        VStack(spacing: Theme.Space.m) {
            EmptyStateView(
                systemImage: "checkmark.seal",
                title: "No findings yet",
                message: "Once an analysis runs, everything it flagged lands here — worst first, each anchored to a line you can jump to."
            )
            Button("Analyze this pull request") { Task { await model.analyze(force: true) } }
                .buttonStyle(.reviewrrPrimary)
                .controlSize(.small)
                .help("Send this pull request to the selected AI provider and read back an analysis")
                .accessibilityLabel("Analyze this pull request")
        }
        .padding(.top, Theme.Space.xl)
    }

    /// No pulse: the panel header carries the one in-flight indicator for
    /// the whole rail, so this states what it is waiting for instead.
    private var loadingState: some View {
        EmptyStateView(
            systemImage: "sparkles",
            title: "Analyzing…",
            message: "Findings appear here as soon as the provider answers."
        )
        .padding(.top, Theme.Space.xl)
    }

    @ViewBuilder
    private func content(for presentation: AIModel.AnalysisPresentation) -> some View {
        AnalysisSourceLine(
            source: presentation.source, providerID: presentation.providerID, model: presentation.model,
            elapsedMS: presentation.elapsedMS, generatedAt: presentation.generatedAt
        )
        switch presentation.outcome {
        case .structured(let result):
            let findings = result.findingsBySeverity
            if findings.isEmpty {
                EmptyStateView(systemImage: "checkmark.seal", title: "No findings", message: "The analysis didn't flag anything in the analyzed files.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            } else {
                ForEach(findings) { finding in
                    FindingRowView(
                        finding: finding, onNavigate: onNavigate,
                        onCreateDraft: { path, line, side, body in
                            onCreateDraft(path, line, side, body)
                            model.markFindingDrafted(id: finding.id)
                        },
                        alreadyDrafted: model.draftedFindingIDs.contains(finding.id)
                    )
                        .motionTransition(.reviewrrRow)
                }
            }
        case .unstructured(let raw, let reason):
            UnstructuredOutputView(raw: raw, reason: reason)
        }
    }
}

/// The honest fallback when parsing and one repair attempt both failed:
/// the raw text, clearly labeled as unstructured rather than silently
/// discarded or presented as if it had parsed.
struct UnstructuredOutputView: View {
    let raw: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unstructured response", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AIVisualStyle.heuristicAccent)
            Text("The provider's response couldn't be parsed into a structured analysis: \(reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(raw)
                .font(Theme.monoFontSmall)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aiCard()
    }
}
