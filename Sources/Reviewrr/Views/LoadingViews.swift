import SwiftUI

/// One placeholder bar. Breathes rather than shimmers: a gradient sweep on
/// a few hundred bars costs real frames, while an opacity pulse staggered by
/// row reads as the same "content is arriving" wave for almost nothing — and
/// it collapses to a still bar under Reduce Motion.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 10
    var delay: Double = 0
    var tint: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: min(4, height / 2), style: .continuous)
            .fill(tint.opacity(0.09))
            .frame(width: width, height: height)
            .opacity(breathing && !reduceMotion ? 1 : 0.45)
            .animation(reduceMotion ? nil : Motion.pulse.delay(delay), value: breathing)
            .onAppear { breathing = true }
            .accessibilityHidden(true)
    }
}

/// The screen shown while a pull request is being fetched.
///
/// A screen, not a scrim and not a dialog: opening a pull request replaces
/// the window's contents, so this fills the window the way the workspace
/// does — same header height, same insets, same rhythm — and the swap into
/// the real workspace is a straight cut with nothing sliding.
///
/// Deliberately still. A skeleton that pulses where content will land is
/// decoration claiming to be data, and it moves for the whole wait. What a
/// reviewer wants is what is happening and how far along it is: which
/// repository, which of the five requests have come back, how long it
/// has taken, and a way out if the answer is "too long".
struct PRLoadingView: View {
    var reference: PRReference?
    var completedStages: Set<PRLoadStage> = []
    var startedAt: Date?
    /// Which service is being asked. The screen used to say "GitHub"
    /// unconditionally, which became a lie the moment the app learned to talk
    /// to GitLab — and this screen exists precisely to tell the reviewer the
    /// truth about what is happening.
    var forge: Forge = .github
    var hostName: String?
    var onCancel: (() -> Void)?

    private var stages: [PRLoadStage] { PRLoadStage.allCases }

    /// Progress towards the workspace opening — the two requests it waits
    /// for, not all five. A bar that sat at 40% while the diff was already in
    /// hand was measuring the wrong thing.
    private var progress: Double {
        let gating = stages.filter(\.gatesTheWorkspace)
        guard !gating.isEmpty else { return 1 }
        let done = gating.filter(completedStages.contains).count
        return Double(done) / Double(gating.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Matches the workspace's own header metrics, so opening a pull request
    /// does not shift the chrome the moment it lands.
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if let onCancel {
                Button(action: onCancel) {
                    Label("Dashboard", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.reviewrrGhost)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .help("Stop opening this pull request and go back to the dashboard")
                .accessibilityLabel("Stop opening this pull request")
            }

            Text("Opening pull request")
                .font(Theme.captionEmphasis)

            if let reference {
                Text(reference.key)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(reference.key)
            }

            Spacer(minLength: Theme.Space.s)

            if let startedAt {
                // Digits ticking, not motion: the difference between "this
                // started a second ago" and "this has been going a minute"
                // is the difference between waiting and giving up.
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Time elapsed")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.panelHeaderHeight)
        .background(Theme.barMaterial)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    // The pull request is the hero — it is what the reviewer
                    // asked for and the only thing on screen they recognise.
                    Text(reference?.key ?? "Opening pull request")
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Determinate, and it moves only when a request actually
                    // lands. An indeterminate bar would animate continuously
                    // while saying nothing about how far along this is.
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 320)
                        .accessibilityLabel("\(completedStages.count) of \(stages.count) requests answered")
                }

                VStack(spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        stageRow(stage)
                        if index < stages.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                )
            }
            // Wide enough to fill the window rather than float in the middle
            // of it, capped where a row of five words would otherwise stretch
            // past the eye's comfortable line length on a 27-inch display.
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Theme.Space.xl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        let where_ = hostName.map { "\(forge.displayName) · \($0)" } ?? forge.displayName
        return "Fetching from \(where_). The workspace opens as soon as the diff is in; "
            + "comments and \(PRLoadStage.threads.label(for: forge).lowercased()) follow it."
    }

    private func stageRow(_ stage: PRLoadStage) -> some View {
        let done = completedStages.contains(stage)
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: Theme.iconMediumSize))
                .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(stage.label(for: forge))
                .font(Theme.body)
                .foregroundStyle(done ? .primary : .secondary)
            Spacer(minLength: Theme.Space.s)
            // All five requests go out together, so an unfinished one is
            // in flight, not queued. "Waiting" implied a turn it was taking.
            Text(done ? "Loaded" : (stage.gatesTheWorkspace ? "Loading…" : "Follows"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(done ? "\(stage.label(for: forge)) loaded" : "\(stage.label(for: forge)) is still being fetched")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label(for: forge)): \(done ? "loaded" : "loading")")
    }

    private var accessibilityLabel: String {
        let name = reference.map { "pull request \($0.key)" } ?? "pull request"
        let gating = stages.filter(\.gatesTheWorkspace)
        let done = gating.filter(completedStages.contains).count
        return "Opening \(name) from \(forge.displayName), \(done) of \(gating.count) required requests loaded"
    }
}

/// The in-place refresh indicator: a floating pill, not a dimming scrim.
/// Re-fetching an already-open pull request leaves the diff readable — the
/// reviewer keeps their place, and only the "this is being refreshed" fact
/// is new information.
struct LoadingOverlay: View {
    var message: String = "Loading pull request…"

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                ActivityDot(color: Theme.accent, size: 6)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.barMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.top, 10)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .motionTransition(.reviewrrRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The right rail's loading state: a few placeholder cards where the
/// threads or checks will land. Same reasoning as `PRLoadingView` at panel
/// scale — the shape of what is coming, not a spinner in the middle of an
/// empty column.
struct PanelLoadingList: View {
    var message: String
    var rows: Int = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                ActivityDot(color: Theme.accent, size: 6)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<rows, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SkeletonBar(width: 16, height: 16, delay: Double(index) * 0.08)
                        SkeletonBar(width: 90, height: 9, delay: Double(index) * 0.08)
                    }
                    SkeletonBar(height: 8, delay: Double(index) * 0.08 + 0.04)
                    SkeletonBar(width: 180, height: 8, delay: Double(index) * 0.08 + 0.08)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reviewrrCard()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
