import CoreGraphics

/// Guards a measured layout value on its way back into the view tree.
///
/// A view that measures itself with a `GeometryReader` (or a preference) and
/// then publishes that measurement into its own subtree's environment has
/// built a feedback loop: the new layout re-measures, reports a value a hair
/// different, and invalidates again. Inside a `NavigationSplitView` column
/// each turn of that loop tells AppKit a child's min/max size changed, and a
/// turn that lands while AppKit is already inside
/// `updateConstraintsForSubtreeIfNeeded` throws an Objective-C exception no
/// Swift code can catch — the process aborts.
///
/// The loop is broken by refusing to publish a value that cannot change the
/// layout: a sub-point remeasurement, or a non-finite number from a
/// collapsed or detached layout pass.
enum LayoutFeedback {
    /// Whether `measured` is worth writing back to state.
    ///
    /// - Parameters:
    ///   - measured: The value just measured.
    ///   - current: What state already holds.
    ///   - minimumChange: The smallest difference that could alter the
    ///     rendered result. Sizes round to the point, so one point is the
    ///     honest floor for a width; a scroll offset that positions pinned
    ///     content can justify less.
    ///   - requiresNonNegative: True for sizes, which can never be negative;
    ///     false for offsets, which legitimately can.
    static func shouldPublish(
        measured: CGFloat,
        current: CGFloat,
        minimumChange: CGFloat,
        requiresNonNegative: Bool = false
    ) -> Bool {
        // Not `!isNaN`: infinities are just as unusable as NaN, and a
        // proposed size of `.infinity` does reach a view during layout.
        guard measured.isFinite else { return false }
        if requiresNonNegative && measured < 0 { return false }
        // A `current` that is somehow non-finite must be replaced, or the
        // view is stuck with it for the rest of its life.
        guard current.isFinite else { return true }
        return abs(measured - current) >= minimumChange
    }
}
