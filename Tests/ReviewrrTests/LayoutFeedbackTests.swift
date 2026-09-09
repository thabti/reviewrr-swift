import CoreGraphics
import XCTest

/// These cover a crash, not a preference. The diff pane measured its own
/// width and published it into its own subtree's environment; inside a
/// NavigationSplitView column that loop reached AppKit mid-constraint-pass
/// and aborted the process.
final class LayoutFeedbackTests: XCTestCase {
    func testSubPointRemeasurementIsNotPublished() {
        // The turn of the loop that has to stop: a width that rounds to the
        // same point cannot change what is drawn.
        XCTAssertFalse(
            LayoutFeedback.shouldPublish(measured: 800.4, current: 800, minimumChange: 1, requiresNonNegative: true)
        )
        XCTAssertFalse(
            LayoutFeedback.shouldPublish(measured: 800, current: 800, minimumChange: 1, requiresNonNegative: true)
        )
    }

    func testARealResizeIsPublished() {
        XCTAssertTrue(
            LayoutFeedback.shouldPublish(measured: 801, current: 800, minimumChange: 1, requiresNonNegative: true)
        )
        XCTAssertTrue(
            LayoutFeedback.shouldPublish(measured: 640, current: 800, minimumChange: 1, requiresNonNegative: true)
        )
    }

    func testNonFiniteMeasurementsAreDropped() {
        // A proposed size of .infinity genuinely reaches a view during
        // layout, and NaN comes out of a collapsed pass.
        for bad in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertFalse(
                LayoutFeedback.shouldPublish(measured: bad, current: 800, minimumChange: 1),
                "\(bad) must not be published"
            )
        }
    }

    func testNegativeSizesAreDroppedButNegativeOffsetsAreNot() {
        XCTAssertFalse(
            LayoutFeedback.shouldPublish(measured: -10, current: 800, minimumChange: 1, requiresNonNegative: true)
        )
        // A scroll offset legitimately goes negative when content is dragged
        // past its leading edge.
        XCTAssertTrue(
            LayoutFeedback.shouldPublish(measured: -10, current: 0, minimumChange: 0.5)
        )
    }

    func testAStuckNonFiniteCurrentValueIsAlwaysReplaced() {
        // Without this the view keeps a poisoned width forever, because
        // every comparison against NaN is false.
        XCTAssertTrue(LayoutFeedback.shouldPublish(measured: 800, current: .nan, minimumChange: 1))
        XCTAssertTrue(LayoutFeedback.shouldPublish(measured: 800, current: .infinity, minimumChange: 1))
    }

    func testTheFirstMeasurementFromZeroIsPublished() {
        // Every pane starts at 0 and must accept its first real width.
        XCTAssertTrue(
            LayoutFeedback.shouldPublish(measured: 1_200, current: 0, minimumChange: 1, requiresNonNegative: true)
        )
    }
}
