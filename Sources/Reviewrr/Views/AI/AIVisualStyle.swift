import SwiftUI

/// A visual identity for AI-authored content — distinct from `Theme`'s
/// diff/GitHub-comment colors and from the reviewer's own drafts, so a
/// glance tells the reviewer who said what (see the AI-panel build rule:
/// "AI output must be visually distinct from GitHub comments and from the
/// reviewer's own drafts").
enum AIVisualStyle {
    /// Pinned sRGB, deliberately **not** `Color.purple` and never
    /// `Theme.accent`. `Theme.accent` is `Color.accentColor`, which follows
    /// the macOS accent in System Settings: with that set to Purple, the AI
    /// card, the review-summary card and the reviewer's own chat bubble
    /// would all be the same hue built the same way, and the rail switcher's
    /// two glyphs would collapse into one colour. The AI/GitHub separation
    /// is a product rule, so it cannot be allowed to turn on a system
    /// preference — this identity is fixed in both appearances.
    static let accent = Theme.dynamic(light: 0.42, 0.22, 0.72, dark: 0.71, 0.57, 0.99)
    static let tint = accent.opacity(0.12)
    static let border = accent.opacity(0.28)
    /// What to draw *on* a shape filled with `accent` — the rail's identity
    /// mark. `accent` is a deep purple in light mode and a bright lavender
    /// in dark, so a fixed white glyph would measure 7.3:1 in one appearance
    /// and about 1.6:1 in the other; this inverts with it and stays above
    /// 7:1 in both.
    static let onAccent = Theme.dynamic(light: 1.00, 1.00, 1.00, dark: 0.09, 0.05, 0.16)
    /// The identity colour as a chip pair, so a chip the AI panel owns is
    /// built from the same `StatusChip`/`PulsingStatusChip` shapes as every
    /// severity and check chip beside it rather than a one-off capsule.
    ///
    /// Chosen per appearance for the reason `StatusPalette` documents below,
    /// not derived as `accent` over `accent.opacity(0.14)`: that construction
    /// measures about 3.6:1 in dark mode at `caption2`, under the 4.5:1 small
    /// text needs. These two land at 7.4:1 and 6.7:1 and stay the same purple.
    static let palette = StatusPalette(
        label: Theme.dynamic(light: 0.36, 0.16, 0.62, dark: 0.80, 0.70, 1.00),
        fill: Theme.dynamic(light: 0.92, 0.88, 0.99, dark: 0.24, 0.16, 0.40)
    )
    /// The heuristic (no-provider) fallback gets its own color so it never
    /// reads as an AI opinion.
    static let heuristicAccent = StatusPalette.orange.label

    static func severityColor(_ severity: AnalysisSeverity) -> Color {
        severityPalette(severity).label
    }

    /// The chip colours for a severity. Label and fill are chosen together
    /// per appearance rather than derived as `hue` over `hue.opacity(0.2)`:
    /// system yellow on pale yellow measures roughly 1.4:1 at caption2, the
    /// smallest text in the rail, and blue and secondary were barely better.
    static func severityPalette(_ severity: AnalysisSeverity) -> StatusPalette {
        switch severity {
        case .blocker: return .red
        case .high: return .orange
        case .medium: return .amber
        case .low: return .blue
        case .info: return .neutral
        }
    }

    /// A distinct SF Symbol per severity so the badge never leans on color
    /// alone — a reviewer who can't distinguish red from orange still reads
    /// "blocker" from the glyph shape.
    static func severitySymbol(_ severity: AnalysisSeverity) -> String {
        switch severity {
        case .blocker: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "arrow.down.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    static func riskColor(_ risk: AnalysisRisk) -> Color {
        riskPalette(risk).label
    }

    static func riskPalette(_ risk: AnalysisRisk) -> StatusPalette {
        switch risk {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .amber
        case .low: return .green
        }
    }

    static func riskSymbol(_ risk: AnalysisRisk) -> String {
        switch risk {
        case .critical: return "flame.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "checkmark.circle.fill"
        }
    }
}

/// The two colours a small status chip needs, resolved per appearance.
///
/// Chips in the rail are drawn at `caption2`, the smallest text in the app,
/// so the label colour cannot be the system hue: `Color.yellow` on
/// `Color.yellow.opacity(0.2)` measures about 1.4:1 in light mode, `.blue`
/// about 2.2:1 and `.secondary` about 2.5:1 — all far under the 4.5:1 small
/// text needs. Each pair below darkens the label for light mode and keeps
/// the bright hue for dark, where the original construction was already
/// fine, and the fill is a real tint rather than a translucent wash so the
/// capsule still reads as a chip over whichever card it sits on.
///
/// Colour is never the only channel: every chip built from these also
/// carries a symbol or its own word.
struct StatusPalette: Equatable {
    let label: Color
    let fill: Color

    static let red = StatusPalette(
        label: Theme.dynamic(light: 0.62, 0.08, 0.08, dark: 1.00, 0.56, 0.54),
        fill: Theme.dynamic(light: 0.98, 0.87, 0.86, dark: 0.36, 0.13, 0.13)
    )
    static let orange = StatusPalette(
        label: Theme.dynamic(light: 0.60, 0.30, 0.00, dark: 1.00, 0.72, 0.36),
        fill: Theme.dynamic(light: 0.99, 0.90, 0.80, dark: 0.34, 0.21, 0.06)
    )
    static let amber = StatusPalette(
        label: Theme.dynamic(light: 0.48, 0.33, 0.00, dark: 0.99, 0.84, 0.38),
        fill: Theme.dynamic(light: 0.99, 0.93, 0.75, dark: 0.32, 0.25, 0.05)
    )
    static let blue = StatusPalette(
        label: Theme.dynamic(light: 0.08, 0.32, 0.72, dark: 0.52, 0.76, 1.00),
        fill: Theme.dynamic(light: 0.88, 0.92, 0.99, dark: 0.13, 0.21, 0.38)
    )
    static let green = StatusPalette(
        label: Theme.dynamic(light: 0.06, 0.42, 0.20, dark: 0.44, 0.86, 0.55),
        fill: Theme.dynamic(light: 0.85, 0.95, 0.87, dark: 0.11, 0.28, 0.16)
    )
    static let neutral = StatusPalette(
        label: Theme.dynamic(light: 0.33, 0.33, 0.35, dark: 0.78, 0.78, 0.80),
        fill: Theme.dynamic(light: 0.90, 0.90, 0.91, dark: 0.26, 0.26, 0.28)
    )
}

/// The one capsule every status chip in the rail is built from — severity,
/// risk, review state — so they cannot drift apart in shape, padding, or
/// contrast.
struct StatusChip: View {
    let text: String
    var systemImage: String?
    let palette: StatusPalette
    var weight: Font.Weight = .semibold

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage).labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(weight))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(palette.fill, in: Capsule())
        .foregroundStyle(palette.label)
    }
}

/// `StatusChip` with its glyph replaced by a breathing dot: the same
/// capsule, padding and contrast, so live work never reads as a different
/// kind of object from a settled verdict beside it.
///
/// The dot only ever appears where something is genuinely in flight — an
/// analysis running, checks still executing on the head commit. A looping
/// animation with nothing behind it is a claim the app cannot back.
struct PulsingStatusChip: View {
    let text: String
    let palette: StatusPalette

    var body: some View {
        HStack(spacing: 5) {
            ActivityDot(color: palette.label, size: 5)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(palette.fill, in: Capsule())
        .foregroundStyle(palette.label)
    }
}

struct SeverityBadge: View {
    let severity: AnalysisSeverity

    var body: some View {
        StatusChip(
            text: severity.label.uppercased(),
            systemImage: AIVisualStyle.severitySymbol(severity),
            palette: AIVisualStyle.severityPalette(severity),
            weight: .bold
        )
        .accessibilityLabel("Severity: \(severity.label)")
    }
}

struct RiskBadge: View {
    let risk: AnalysisRisk

    var body: some View {
        StatusChip(
            text: risk.rawValue.capitalized,
            systemImage: AIVisualStyle.riskSymbol(risk),
            palette: AIVisualStyle.riskPalette(risk)
        )
        .accessibilityLabel("Risk: \(risk.rawValue)")
    }
}

struct AISectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A one-line summary of where the current analysis came from — cached,
/// freshly generated, or the offline heuristic fallback — plus attribution
/// so the reviewer never mistakes a pattern scan for an AI opinion.
struct AnalysisSourceLine: View {
    let source: AnalysisSource
    let providerID: String
    let model: String
    let elapsedMS: Int
    let generatedAt: Date

    private var label: String {
        switch source {
        case .cache: return "Cached"
        case .fresh: return "Fresh"
        case .heuristic: return "Heuristic (no AI provider configured)"
        }
    }

    private var attribution: String {
        if providerID == HeuristicAnalyzer.agentID { return label }
        let displayName = AIProviderRegistry.descriptor(for: providerID).displayName
        let modelPart = model.isEmpty ? "" : " · \(model)"
        return "\(label) · \(displayName)\(modelPart) · \(elapsedMS) ms"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source == .heuristic ? "wand.and.stars" : "sparkles")
                .foregroundStyle(source == .heuristic ? AIVisualStyle.heuristicAccent : AIVisualStyle.accent)
            Text(attribution)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(generatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The shared AI-content container — purple tint plus a hairline border
    /// — so every AI-authored block (chat bubble, finding, raw-output
    /// fallback) reads as one visual family, distinct from a GitHub comment
    /// card and from a reviewer's own draft.
    func aiCard(cornerRadius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(AICardBackground(cornerRadius: cornerRadius))
    }
}

private struct AICardBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AIVisualStyle.tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AIVisualStyle.border, lineWidth: 1)
            )
    }
}

/// A `path:line` citation rendered as a tappable jump link. Ghost-styled
/// rather than `.link` blue text: its hover fill (from `.reviewrrGhost`)
/// makes the click target obvious without borrowing the same blue GitHub
/// uses for its own comment links, which would blur the two together.
/// A place in the diff the model referred to, as a reference the reviewer
/// can follow.
///
/// The file name and line lead, because that is what identifies the place;
/// the directory is present but quiet, because a repo path is long and the
/// reviewer already knows which repository they are in. The whole row is the
/// target — a reference should not need aiming at.
struct SourceReferenceRow: View {
    let path: String
    let startLine: Int
    let endLine: Int
    let action: () -> Void

    private var fileName: String { (path as NSString).lastPathComponent }

    /// The directory, with a trailing slash, or nil at the repository root.
    private var directory: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent + "/"
    }

    private var lineLabel: String {
        endLine > startLine ? "\(startLine)–\(endLine)" : "\(startLine)"
    }

    private var anchor: String { "\(path):\(lineLabel)" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AIVisualStyle.accent)
                HStack(spacing: 0) {
                    if let directory {
                        Text(directory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(0)
                    }
                    Text(fileName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(":\(lineLabel)")
                        .foregroundStyle(AIVisualStyle.accent)
                        .layoutPriority(1)
                }
                .font(Theme.monoFontSmall)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.reviewrrGhost)
        .controlSize(.small)
        .help("Open \(anchor)")
        .accessibilityLabel("Source reference, \(anchor)")
        .accessibilityHint("Opens this line in the diff")
    }
}

struct CitationJumpButton: View {
    let label: String
    let fullPath: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "arrow.right.circle")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.reviewrrGhost)
        .controlSize(.small)
        .help("Jump to \(fullPath)")
    }
}

/// The "turn this into a draft comment" action, used where the AI output
/// being drafted from is one specific point: a finding has a title, an
/// explanation and a suggestion, which make a comment body a reviewer would
/// actually send.
///
/// Deliberately *not* offered next to an Ask citation. An answer is prose
/// about several places at once, so drafting "from" one of its citations
/// pasted the whole answer onto a single line — a comment no reviewer would
/// send and no author could act on. Those citations are source references
/// instead; see `SourceReferenceRow`.
struct DraftFromAIButton: View {
    let target: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Draft comment", systemImage: "text.bubble")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.reviewrrGhost)
        .controlSize(.small)
        .help("Turn this into a draft comment on \(target)")
        .accessibilityLabel("Turn this into a draft comment on \(target)")
    }
}

/// A line Reviewrr itself added to an Ask transcript — that the revision
/// moved, most often.
///
/// Deliberately not a bubble: it is not something the reviewer asked or the
/// model answered, and dressing it as either would put words in one of their
/// mouths.
struct TranscriptNoticeRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reviewrr note: \(text)")
    }
}
