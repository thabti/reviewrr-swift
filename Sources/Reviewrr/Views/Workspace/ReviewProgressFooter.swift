import SwiftUI

/// Sidebar footer: how much of the PR has been marked viewed, overall and
/// per category. Deliberately plain — a fraction and a bar, no streaks or
/// scores — review progress is a personal reading aid, not a game.
///
/// Collapsed, the block is a round 44pt — the same height as the identity
/// row and the filter row at the top of the column, so the sidebar reads as
/// one rhythm from top to bottom. The bar runs the full width between the
/// panel insets: it is a measure of the whole review, and a progress bar
/// that stops short of its own container looks like it stalled.
struct ReviewProgressFooter: View {
    let progress: ReviewProgress
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            summaryButton
            ProgressBar(fraction: progress.overallFraction, tint: DiffTextColor.added(colorScheme))

            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(progress.byCategory) { category in
                        categoryRow(category)
                    }
                }
                .padding(.top, Theme.Space.xs)
                .motionTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var summaryButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Text("Reviewed")
                    .font(Theme.captionEmphasis)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.s)
                // The count ticking is the app's main sense of forward
                // momentum through a review — worth a numeric roll
                // rather than a plain re-render.
                Text(verbatim: "\(progress.overallViewed)/\(progress.overallTotal)")
                    .font(Theme.monoFontSmall)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motion(Motion.smooth, value: progress.overallViewed)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: Theme.iconMediumSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide the per-category breakdown" : "Show the per-category breakdown")
        .accessibilityLabel("Review progress, \(progress.overallViewed) of \(progress.overallTotal) files viewed")
        .accessibilityAddTraits(.isButton)
    }

    private func categoryRow(_ category: CategoryProgress) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: category.category.symbolName)
                .font(.system(size: Theme.iconSmallSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(category.category.tint)
                .frame(width: Theme.glyphColumn)
                .help(category.category.label)
                .accessibilityHidden(true)
            Text(category.category.label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text("\(category.viewed)/\(category.total)")
                .font(Theme.monoFontSmall)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .motion(Motion.smooth, value: category.viewed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.category.label), \(category.viewed) of \(category.total) viewed")
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairlineStrong)
                Capsule().fill(tint.opacity(0.7))
                    .frame(width: proxy.size.width * max(0, min(1, fraction)))
                    .motion(Motion.smooth, value: fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
