import SwiftUI

/// The Analysis tab: every section of a structured result, rendered in the
/// order `docs/architecture/ai-review-result-v1.md` and `docs/mvp-plan.md`
/// §6 prescribe — overview, review order, findings, test gaps,
/// architecture impact, reviewer questions, file summaries, limitations,
/// skipped files.
struct AnalysisTabView: View {
    @Environment(\.openSettingsPane) private var openSettings
    @ObservedObject var model: AIModel
    var onNavigate: (String, Int) -> Void
    var onCreateDraft: (String, Int, DiffSide, String) -> Void

    /// Both cached rather than read in `body`: the configuration check
    /// touches the Keychain and the filesystem, and the display name is a
    /// scan of the provider registry. Refreshed on the two things that can
    /// change either — the selected provider, and coming back from the
    /// Settings window.
    @State private var providerConfigured = false
    @State private var providerName = ""
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                switch model.analysisState {
                case .idle:
                    firstRunState
                case .loading:
                    analyzingState
                case .failed(let message):
                    AIAnalysisFailureView(model: model, message: message)
                case .ready(let presentation):
                    if let carriedOver = model.carriedOverFromHeadSha {
                        carriedOverBanner(fromHeadSha: carriedOver)
                    }
                    AnalysisSourceLine(
                        source: presentation.source, providerID: presentation.providerID, model: presentation.model,
                        elapsedMS: presentation.elapsedMS, generatedAt: presentation.generatedAt
                    )
                    switch presentation.outcome {
                    case .structured(let result):
                        sections(for: result)
                    case .unstructured(let raw, let reason):
                        UnstructuredOutputView(raw: raw, reason: reason)
                    }
                }
            }
            .padding(Theme.Space.m)
            .motion(Motion.smooth, value: model.analysisState)
        }
        .onAppear(perform: refreshProvider)
        .onChange(of: model.providerID) { _, _ in refreshProvider() }
        .onChange(of: controlActiveState) { _, _ in refreshProvider() }
    }

    private func refreshProvider() {
        providerConfigured = model.isProviderConfigured
        providerName = AIProviderRegistry.descriptor(for: model.providerID).displayName
    }

    /// The analysis on screen describes an earlier revision, narrowed to the
    /// files that have not changed since. Said above the first finding: a
    /// reviewer who reads a finding first and the caveat second has already
    /// been misled.
    @ViewBuilder
    private func carriedOverBanner(fromHeadSha: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(AIVisualStyle.heuristicAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Carried over from revision \(String(fromHeadSha.prefix(7)))")
                    .font(.caption.weight(.semibold))
                Text("Only findings on files that have not changed since are shown. Re-run for the current revision.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Re-run") { Task { await model.analyze(force: true) } }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
                .help("Analyze the pull request again at its current revision")
                .accessibilityLabel("Re-run the analysis for the current revision")
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AIVisualStyle.heuristicAccent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// Nothing has run yet — the first thing a new reviewer sees in this
    /// app's most unfamiliar panel. So it says what an analysis actually
    /// produces, in the same three shapes the result really has, and what it
    /// will and will not do with the pull request; a bare "No analysis yet"
    /// left a reviewer to press a button and find out.
    ///
    /// Every line here is checkable against `AnalysisResult`: nothing claims
    /// repository-wide retrieval, and nothing implies the panel can post.
    private var firstRunState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(AIVisualStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(firstRunTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(firstRunMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                firstRunPoint("text.alignleft", "An overview of the change and a risk call")
                firstRunPoint("list.number", "The order to read the files in, and why")
                firstRunPoint("exclamationmark.magnifyingglass", "Findings ranked by severity, anchored to path:line")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.s)
            .background(
                Theme.controlFill,
                in: RoundedRectangle(
                    cornerRadius: Theme.concentricRadius(outer: Theme.cornerRadiusLarge, inset: Theme.Space.s),
                    style: .continuous
                )
            )

            if providerConfigured {
                Button("Analyze this pull request") { Task { await model.analyze(force: true) } }
                    .buttonStyle(.reviewrr(.primary, fullWidth: true))
                    .help("Send this pull request to \(providerName) and read back an analysis")
                    .accessibilityLabel("Analyze this pull request with \(providerName)")
            } else {
                // Offering Analyze here would be a button that cannot work.
                Button { openSettings(.ai) } label: {
                    Label("Set up \(providerName)", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.reviewrr(.primary, fullWidth: true))
                .help(model.providerConfigurationHint)
                .accessibilityLabel("Set up \(providerName) in Settings")
            }

            Label(
                "Read-only. Reviewrr sends the diff, the discussion, and your drafts; it never posts, approves, or edits. Turning a finding into a draft comment stays your call.",
                systemImage: "lock.shield"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AIVisualStyle.tint,
            in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(AIVisualStyle.border, lineWidth: 1)
        )
    }

    private var firstRunTitle: String {
        if !providerConfigured { return "No AI provider is set up yet" }
        return model.autoAnalysisSkip == nil ? "Get a read on this pull request" : "Waiting for you on this one"
    }

    private var firstRunMessage: String {
        if !providerConfigured { return model.providerConfigurationHint }
        if let skip = model.autoAnalysisSkip {
            return "\(skip.fileCount) changed files is more than the \(skip.threshold)-file limit for automatic analysis, so nothing has been sent yet."
        }
        return "\(providerName) reads the diff and the discussion on this PR and answers with:"
    }

    private func firstRunPoint(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AIVisualStyle.accent)
                .frame(width: 14)
        }
        .accessibilityElement(children: .combine)
    }

    /// No pulse here. The panel header carries the single in-flight
    /// indicator for the whole rail; a second one two inches below it read
    /// as two things happening at once.
    private var analyzingState: some View {
        EmptyStateView(
            systemImage: "sparkles",
            title: "Analyzing…",
            message: "\(providerName.isEmpty ? "The provider" : providerName) is reading this pull request. The result replaces this as soon as it lands."
        )
        .padding(.top, Theme.Space.xl)
    }

    @ViewBuilder
    private func sections(for result: AnalysisResult) -> some View {
        overview(result.overview)
        if !result.reviewOrder.isEmpty { reviewOrder(result.reviewOrder) }
        findings(result.findingsBySeverity)
        if !result.testGaps.isEmpty { testGaps(result.testGaps) }
        if !result.architectureImpact.isEmpty { architectureImpact(result.architectureImpact) }
        if !result.reviewerQuestions.isEmpty { reviewerQuestions(result.reviewerQuestions) }
        if !result.fileSummaries.isEmpty { fileSummaries(result.fileSummaries) }
        if !result.limitations.isEmpty { limitations(result.limitations) }
        if !result.scope.skippedFiles.isEmpty { skippedFiles(result.scope.skippedFiles) }
    }

    // MARK: - Sections

    @ViewBuilder
    private func overview(_ overview: AnalysisOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AISectionHeader(title: "Overview")
            Text(overview.title).font(.headline)
            Text(overview.summary).font(.callout)
            if !overview.intent.isEmpty {
                Text(overview.intent).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                RiskBadge(risk: overview.risk)
                Text("\(overview.reviewEffort.rawValue.capitalized) review effort")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reviewOrder(_ items: [AnalysisReviewOrderItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AISectionHeader(title: "Review order")
            ForEach(items.sorted { $0.priority < $1.priority }) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(item.priority)").font(Theme.monoFontSmall).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        pathButton(item.path) { onNavigate(item.path, 1) }
                        Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func findings(_ items: [AnalysisFinding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AISectionHeader(title: "Findings")
            if items.isEmpty {
                Text("No findings in the analyzed files.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items) { finding in
                    FindingRowView(
                        finding: finding, onNavigate: onNavigate,
                        onCreateDraft: { path, line, side, body in
                            onCreateDraft(path, line, side, body)
                            model.markFindingDrafted(id: finding.id)
                        },
                        alreadyDrafted: model.draftedFindingIDs.contains(finding.id)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A bare file path acting as a jump link — lighter-weight than
    /// `CitationJumpButton` (no icon, no padding) so it sits naturally
    /// inline in a dense list, but still ghost-styled so hovering it shows
    /// the same "this is clickable" fill every other AI jump link uses.
    ///
    /// One line, truncated at the *head*: a full repository path wrapped
    /// over two or three lines inside a bordered pill, and the informative
    /// end of a path is its tail. The `.help` still carries the whole thing.
    private func pathButton(_ path: String, action: @escaping () -> Void) -> some View {
        Button(path, action: action)
            .buttonStyle(.reviewrrGhost)
            .controlSize(.mini)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.head)
            .help("Jump to \(path)")
            .accessibilityLabel("Jump to \(path)")
    }

    @ViewBuilder
    private func testGaps(_ items: [AnalysisTestGap]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AISectionHeader(title: "Test gaps")
            ForEach(Array(items.enumerated()), id: \.offset) { _, gap in
                VStack(alignment: .leading, spacing: 2) {
                    Text(gap.title).font(.callout.weight(.semibold))
                    Text(gap.description).font(.caption).foregroundStyle(.secondary)
                    if !gap.paths.isEmpty {
                        Text(gap.paths.joined(separator: ", ")).font(Theme.monoFontSmall).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func architectureImpact(_ items: [AnalysisArchitectureImpact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AISectionHeader(title: "Architecture impact")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    RiskBadge(risk: item.risk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.area).font(.callout.weight(.semibold))
                        Text(item.impact).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reviewerQuestions(_ items: [AnalysisReviewerQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AISectionHeader(title: "Reviewer questions")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.question).font(.callout.weight(.semibold))
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                    if let path = item.path {
                        pathButton(path) { onNavigate(path, 1) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fileSummaries(_ items: [AnalysisFileSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AISectionHeader(title: "File summaries")
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    RiskBadge(risk: item.risk)
                    VStack(alignment: .leading, spacing: 2) {
                        pathButton(item.path) { onNavigate(item.path, 1) }
                        Text(item.role).font(.caption2).foregroundStyle(.secondary)
                        Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func limitations(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AISectionHeader(title: "Limitations")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func skippedFiles(_ items: [AnalysisSkippedFile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AISectionHeader(title: "Skipped files")
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(item.path).font(Theme.monoFontSmall).foregroundStyle(.secondary)
                    Text(item.reason.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
