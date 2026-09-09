import SwiftUI

/// Reviewrr's button vocabulary.
///
/// macOS already has good buttons, and standard controls (`.bordered`,
/// `.borderedProminent`) stay the right answer inside sheets, forms, and
/// alerts — they inherit system tinting, focus rings, and control sizes for
/// free, and a reviewer recognizes them instantly.
///
/// These styles exist for the surfaces that are *not* a form: the dashboard's
/// primary calls to action, panel headers, filter chips, and toolbar-adjacent
/// actions, where the app needs a consistent hover and press response and a
/// slightly softer shape than a system push button. They deliberately keep
/// system behaviours a custom style usually loses: accent-color tinting,
/// disabled dimming, keyboard focus rings, and Reduce Motion.
enum ReviewrrButtonKind {
    /// The one action a surface most wants you to take.
    case primary
    /// Everything else with a visible container.
    case secondary
    /// Low-emphasis actions inside dense rows and panel headers.
    case ghost
    /// Irreversible or removing actions.
    case destructive
}

struct ReviewrrButtonStyle: ButtonStyle {
    var kind: ReviewrrButtonKind = .secondary
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Container(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }

    /// A `ButtonStyle` cannot hold state, and hover is state — so the body is
    /// a real view that can track it.
    private struct Container: View {
        let configuration: Configuration
        let kind: ReviewrrButtonKind
        let fullWidth: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        /// Padding comes off the same 4pt grid as the rest of the app; the
        /// odd 9pt large step used to make a large button a point taller
        /// than the 44pt bars it sat next to.
        private var verticalPadding: CGFloat {
            switch controlSize {
            case .mini, .small: return Theme.Space.xs
            case .large, .extraLarge: return Theme.Space.s
            default: return 6
            }
        }

        private var horizontalPadding: CGFloat {
            switch controlSize {
            case .mini, .small: return Theme.Space.s
            case .large, .extraLarge: return Theme.Space.l
            default: return Theme.Space.m
            }
        }

        private var tint: Color {
            switch kind {
            case .primary: return Theme.accent
            case .destructive: return .red
            case .secondary, .ghost: return .primary
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .destructive: return isEnabled ? .red : .secondary
            case .secondary, .ghost: return .primary
            }
        }

        private var background: some ShapeStyle {
            switch kind {
            case .primary:
                return AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.82 : (hovering ? 1 : 0.92)))
            case .secondary:
                return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.09 : 0.06)))
            // A ghost button has no resting container at all; hover is what
            // says it is a control, so it lands on the shared control fill
            // rather than a value of its own.
            case .ghost:
                return AnyShapeStyle(
                    configuration.isPressed
                        ? Color.primary.opacity(0.12)
                        : (hovering ? Theme.controlFillHover : Color.clear)
                )
            case .destructive:
                return AnyShapeStyle(Color.red.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.13 : 0.08)))
            }
        }

        /// One hairline treatment: a container that is always there keeps its
        /// edge, a ghost draws one only under the pointer. A row of seven
        /// outlined ghost buttons — which is what a toolbar of them used to
        /// be — reads as seven boxes rather than seven actions.
        private var stroke: Color {
            switch kind {
            case .primary: return .clear
            case .ghost: return hovering ? Theme.hairlineStrong : .clear
            case .secondary, .destructive: return hovering ? Theme.hairlineStrong : Theme.hairline
            }
        }

        var body: some View {
            configuration.label
                .font(Theme.bodyMedium)
                .foregroundStyle(foreground)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1)
                )
                // Pressing scales down rather than dimming: on a trackpad the
                // pointer often covers a small control, so the feedback has to
                // be visible around the cursor, not under it.
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous))
                .motion(Motion.snappy, value: configuration.isPressed)
                .motion(Motion.hover, value: hovering)
                .onHover { hovering = isEnabled && $0 }
                .onChange(of: isEnabled) { _, enabled in if !enabled { hovering = false } }
        }
    }
}

extension ButtonStyle where Self == ReviewrrButtonStyle {
    static var reviewrrPrimary: ReviewrrButtonStyle { ReviewrrButtonStyle(kind: .primary) }
    static var reviewrrSecondary: ReviewrrButtonStyle { ReviewrrButtonStyle(kind: .secondary) }
    static var reviewrrGhost: ReviewrrButtonStyle { ReviewrrButtonStyle(kind: .ghost) }
    static var reviewrrDestructive: ReviewrrButtonStyle { ReviewrrButtonStyle(kind: .destructive) }

    static func reviewrr(_ kind: ReviewrrButtonKind, fullWidth: Bool = false) -> ReviewrrButtonStyle {
        ReviewrrButtonStyle(kind: kind, fullWidth: fullWidth)
    }
}

/// A selectable pill — filters, segmented-ish toggles, category chips.
/// Distinct from a button because its *selected* state, not its press, is the
/// thing that matters, and it must read as selected without relying on colour
/// alone.
struct ReviewrrChipStyle: ButtonStyle {
    var isSelected: Bool
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        Container(configuration: configuration, isSelected: isSelected, tint: tint)
    }

    private struct Container: View {
        let configuration: Configuration
        let isSelected: Bool
        let tint: Color

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(isSelected ? Theme.captionEmphasis : Theme.caption)
                .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.85))
                .padding(.vertical, Theme.chipPaddingVertical)
                .padding(.horizontal, Theme.chipPaddingHorizontal)
                .background(
                    Capsule().fill(
                        isSelected
                            ? tint.opacity(hovering ? Theme.chipFillHoverOpacity : Theme.chipFillOpacity)
                            : (configuration.isPressed
                               ? Color.primary.opacity(0.12)
                               : (hovering ? Theme.controlFillHover : Theme.controlFill))
                    )
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? tint.opacity(Theme.chipStrokeOpacity) : Theme.hairline, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .contentShape(Capsule())
                .motion(Motion.snappy, value: configuration.isPressed)
                .motion(Motion.smooth, value: isSelected)
                .motion(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == ReviewrrChipStyle {
    static func reviewrrChip(selected: Bool, tint: Color = Theme.accent) -> ReviewrrChipStyle {
        ReviewrrChipStyle(isSelected: selected, tint: tint)
    }
}

/// Hover feedback for whole rows and cards: a faint fill plus a hairline, no
/// movement. Rows shifting under the pointer make a dense list feel unstable
/// and make click targets move away from the cursor.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Theme.cornerRadiusSmall
    var isSelected: Bool = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.accent.opacity(0.14)
                            : (hovering ? Theme.controlFill : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .motion(Motion.hover, value: hovering)
            .motion(Motion.smooth, value: isSelected)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Theme.cornerRadiusSmall, isSelected: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isSelected: isSelected))
    }
}
