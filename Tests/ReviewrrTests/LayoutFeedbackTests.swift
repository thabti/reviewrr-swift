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

    // MARK: Text that has to fit

    /// A gutter holding a glyph has to scale with the glyph.
    ///
    /// The sidebar's icon columns were fixed at 18pt while the symbols in
    /// them were `.reviewrr(13, scale:)`. At Extra Large that glyph draws at
    /// 16pt and a wide symbol — `tray.full`, `shippingbox` — is wider than
    /// it is tall, so it was clipped by a gutter that never grew.
    ///
    /// The floor is 1.2, not the unscaled ratio: rounding each side to a
    /// whole point moves the ratio by a few hundredths either way, and the
    /// number that matters is how wide a symbol actually draws. The widest
    /// SF Symbols are about 1.2× their point size, so a gutter at or above
    /// that clears them at every text size.
    func testAScaledGutterKeepsItsHeadroomOverTheGlyph() {
        let gutter: CGFloat = 18
        let glyph: CGFloat = 13

        for size in InterfaceTextSize.allCases {
            let ratio = Theme.scaled(gutter, size.scale) / Theme.scaled(glyph, size.scale)
            XCTAssertGreaterThanOrEqual(
                ratio, 1.2,
                "\(size.label) squeezes the gutter to \(ratio)× the glyph it holds"
            )
        }
    }

    /// Every dimension the views scale lands on a whole point, at every
    /// text size. A half-point text frame renders soft on a Retina display
    /// and the app's own note on `Theme.scaled` promises this.
    func testScaledDimensionsAreWholePoints() {
        for size in InterfaceTextSize.allCases {
            for base in stride(from: CGFloat(1), through: 80, by: 1) {
                let value = Theme.scaled(base, size.scale)
                XCTAssertEqual(value, value.rounded(), "\(base) at \(size.label) is \(value)")
                XCTAssertGreaterThanOrEqual(value, 1, "a dimension must never scale away to nothing")
            }
        }
    }

    /// The settings panes share one inset and one reading width.
    ///
    /// Three of them used to disagree — a hand-built pane at 16, the
    /// heading at 22, a grouped `Form` at its own 20 — so the left edge
    /// moved as the reviewer switched panes. macOS gives no API to read a
    /// form's inset back, so the value is pinned here instead.
    func testSettingsSurfaceSharesOneInset() {
        XCTAssertEqual(Theme.Settings.inset, 20, "matches a grouped Form's row inset")
        XCTAssertGreaterThan(Theme.Settings.contentWidth, 0)
    }
}
