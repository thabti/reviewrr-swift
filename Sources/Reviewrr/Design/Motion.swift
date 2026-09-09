import SwiftUI

/// One vocabulary of motion, so a row re-sorting, a panel swapping, and a
/// button being pressed all feel like the same application.
///
/// Everything here is a spring rather than a fixed curve. Reviewrr animates
/// values that change *while the reviewer is looking at them* — inbox rows
/// re-sorting mid-poll, unread counts ticking, streamed AI text growing — and
/// a spring retargets from its current velocity instead of restarting, so an
/// interrupted animation never snaps.
enum Motion {
    /// Direct manipulation: presses, hovers, toggles, disclosure.
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.86)
    /// Content changing under the reviewer: rows, filters, badges, counts.
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.9)
    /// Whole surfaces: dashboard to workspace, panel swaps, sheets.
    static let surface = Animation.spring(response: 0.55, dampingFraction: 0.92)
    /// Pointer feedback only — short enough that it never lags the cursor.
    static let hover = Animation.easeOut(duration: 0.13)

    /// A looping pulse for "work is happening" affordances (syncing,
    /// streaming). Deliberately slow: a fast pulse reads as an error.
    static let pulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
}

/// Applies an animation unless the reviewer has asked the system for less
/// motion, in which case the value still changes — instantly.
///
/// Reduce Motion is a real accessibility setting on macOS, not a preference
/// to route around: vestibular sensitivity makes movement genuinely
/// unpleasant. Every animated surface in Reviewrr goes through this.
private struct ReduceMotionAware<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ReduceMotionAware(animation: animation, value: value))
    }

    /// A transition that respects Reduce Motion by falling back to a plain
    /// cross-fade, which carries no directional movement.
    func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(ReduceMotionTransition(transition: transition))
    }
}

private struct ReduceMotionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transition: AnyTransition

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

extension AnyTransition {
    /// Panels and surfaces entering from the side they conceptually live on.
    static var reviewrrPanel: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        )
    }

    /// List rows appearing: a small rise plus fade reads as "this arrived"
    /// without the jarring height animation a scale transition causes.
    static var reviewrrRow: AnyTransition {
        .asymmetric(
            insertion: .offset(y: 6).combined(with: .opacity),
            removal: .opacity
        )
    }
}

/// A quiet "this is live" indicator: a dot that breathes while work is in
/// flight and holds still when it is not.
struct ActivityDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color = Theme.accent
    var active: Bool = true
    var size: CGFloat = 6

    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(active && pulsing && !reduceMotion ? 0.35 : 1)
            .scaleEffect(active && pulsing && !reduceMotion ? 0.82 : 1)
            .animation(active && !reduceMotion ? Motion.pulse : nil, value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}
