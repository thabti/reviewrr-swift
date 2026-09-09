import AppKit
import SwiftUI

enum Theme {
    static let accent = Color.accentColor

    /// Diff tints resolve per appearance. A single fixed value cannot work
    /// for both: a tint dark enough to sit under white code in dark mode is
    /// nearly black on a white page, and the pale version is invisible on a
    /// dark one.
    static let addedBackground = dynamic(light: 0.87, 0.96, 0.88, dark: 0.10, 0.22, 0.14)
    static let addedBackgroundStrong = dynamic(light: 0.62, 0.85, 0.65, dark: 0.14, 0.30, 0.18)
    static let removedBackground = dynamic(light: 0.995, 0.90, 0.90, dark: 0.26, 0.11, 0.12)
    static let removedBackgroundStrong = dynamic(light: 0.98, 0.72, 0.72, dark: 0.34, 0.14, 0.15)

    static let addedText = dynamic(light: 0.10, 0.50, 0.20, dark: 0.55, 0.85, 0.60)
    static let removedText = dynamic(light: 0.72, 0.15, 0.15, dark: 0.92, 0.55, 0.55)

    /// Resolves at draw time rather than at launch, so the app follows a
    /// mid-session appearance switch without rebuilding any view state.
    static func dynamic(
        light lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat,
        dark dr: CGFloat, _ dg: CGFloat, _ db: CGFloat
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: 1)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: 1)
        })
    }

    /// `secondaryLabelColor` already carries roughly half alpha, so an
    /// additional multiplier here painted line numbers at about a quarter
    /// strength — under 3:1 against the gutter in either appearance.
    static let gutterText = Color.secondary
    static let hunkSeparator = Color.secondary.opacity(0.12)

    static let cardBackground = Color(nsColor: .controlBackgroundColor)

    /// The single surface a column of list content paints.
    ///
    /// A column is one panel, not three. The project sidebar used to stack a
    /// `.bar`-material header, a `List(.sidebar)` drawing its own
    /// translucent grey, and a 40%-opacity wash on the container — three
    /// different surfaces in one 300pt column, which in light appearance
    /// read as a grey band between a white header and a white footer.
    ///
    /// Anything using this must also hide the list's own background with
    /// `.scrollContentBackground(.hidden)`, or the list paints over it.
    static let columnSurface = Color(nsColor: .controlBackgroundColor)
    /// The card edge is the same hairline every other surface uses; kept as
    /// its own name because `reviewrrCard` is a shared contract.
    static let cardStroke = hairline
    static let codeBackground = Color(nsColor: .textBackgroundColor).opacity(0.4)

    static let cornerRadius: CGFloat = 10

    // MARK: - Type scale

    /// Roles rather than raw point sizes. The review column had been picking
    /// 8, 9, 10, 11 and 12pt view by view, so a file row, the filter bar above
    /// it and the footer summarising it disagreed by a point for no reason.
    /// 8pt is gone and 10pt folded into `captionSize`: under 11pt, secondary
    /// text over a material background stops being readable at a glance.
    ///
    /// These are the *sizes*, exposed so a surface that scales its text can
    /// feed them to `Font.reviewrr(_:scale:)`; the `Font` tokens below are the
    /// unscaled forms the review column uses directly.
    static let captionSize: CGFloat = 11
    static let bodySize: CGFloat = 12

    /// Glyphs run a step below the text beside them: a symbol inks its whole
    /// point size, a lowercase letter inks about two thirds of it.
    static let iconSmallSize: CGFloat = 10
    static let iconMediumSize: CGFloat = 12

    static var caption: Font { .system(size: captionSize) }
    static var captionEmphasis: Font { .system(size: captionSize, weight: .semibold) }
    static var body: Font { .system(size: bodySize) }
    static var bodyMedium: Font { .system(size: bodySize, weight: .medium) }

    static var monoFont: Font { .system(size: bodySize, weight: .regular, design: .monospaced) }
    static var monoFontSmall: Font { .system(size: captionSize, weight: .regular, design: .monospaced) }

    // MARK: - Chips

    /// One pill for every chip in the app — category filters, GitHub labels,
    /// the "+3 more" affordance. They share rows, so a point of padding or a
    /// step of tint between them reads as two different kinds of object.
    /// Only the shape is shared: a GitHub label keeps its repository's colour.
    static let chipPaddingHorizontal: CGFloat = 8
    static let chipPaddingVertical: CGFloat = 3
    static let chipFillOpacity: Double = 0.18
    static let chipFillHoverOpacity: Double = 0.24
    static let chipStrokeOpacity: Double = 0.45

    // MARK: - Line selection

    /// One continuous rule in the gutter, and nothing else.
    ///
    /// The first attempt drew a wash, a fill behind the digits, a 3pt rail and
    /// hairline caps at each end of the range: three sides of a rectangle
    /// around a tinted interior, which is to say a box — and per-row segments
    /// that re-started at every row, so the "rail" read as a stack of them. It
    /// also duplicated the jump-to-line flash, which is already a 3pt accent
    /// rail plus a faint wash.
    ///
    /// A single vertical rule is what an editor uses for "this contiguous run
    /// of lines" (Xcode's change bar), and the gutter is the only column in a
    /// diff not already spoken for by green, red, or word-diff tint.
    ///
    /// 2pt, not 3, so it cannot be mistaken for the jump flash; whole points
    /// at full saturation, because a fractional width at partial alpha
    /// anti-aliases into two grey rows at 1x and reads as a smudge rather
    /// than as a deliberate mark.
    static let selectionRailWidth: CGFloat = 2
    /// Inset from the gutter's trailing edge, so the rule sits between the
    /// numbers and the code rather than against either.
    static let selectionRailInset: CGFloat = 5

    /// `selectedContentBackgroundColor`, not `accentColor`: it tracks window
    /// key state, the graphite appearance, and Increase Contrast, which a raw
    /// accent does not.
    static let selectionRail = Color(nsColor: .selectedContentBackgroundColor)

    // MARK: - States

    /// A file marked viewed is *done*, not disabled. On a 675-file pull
    /// request most of the tree ends up viewed, and dimming much further put
    /// the paths under 3:1 in dark mode — a tree you can't read is a tree you
    /// can't navigate back through.
    static let viewedDim: Double = 0.65

    /// The ring on a focused search field. Heavier than a hairline tint
    /// because it is the only thing distinguishing "typing filters the tree"
    /// from "typing fires a keyboard shortcut", and a 1pt accent stroke at
    /// half alpha all but disappears over the dark field fill.
    static let focusRing = Theme.accent.opacity(0.7)

    /// Vibrancy for surfaces that sit *over* content — panel headers, filter
    /// bars, sticky file headers. A material keeps the layering legible while
    /// scrolling, which a flat fill cannot do.
    ///
    /// Three depths, and only three: chrome that floats over scrolling
    /// content is `.bar`, a panel body is `.regularMaterial`, and a control
    /// inset into either is a *fill*, not a third material. Nesting blur
    /// inside blur is how a translucent app ends up with grey text — the
    /// backdrop of the inner material is the already-blurred outer one.
    static let barMaterial: Material = .bar
    static let panelMaterial: Material = .regularMaterial

    /// Hairlines, not borders. One 1pt stroke at this alpha wherever two
    /// surfaces meet — panel edges, card edges, control outlines. Derived
    /// from the label colour rather than a fixed grey so it inverts with the
    /// appearance instead of turning into a black scratch on a dark window.
    static let hairline = Color.primary.opacity(0.08)
    static let hairlineStrong = Color.primary.opacity(0.14)

    /// The fill under a control that sits on a bar or a panel: a search
    /// field, a segmented group, a hovered row. Low enough to read as a
    /// recess in the material rather than a second card stacked on it.
    static let controlFill = Color.primary.opacity(0.05)
    static let controlFillHover = Color.primary.opacity(0.08)

    /// Every inline control in a bar is exactly this tall, which is what
    /// makes the filter row a whole 44pt block (`Space.s` + 28 + `Space.s`)
    /// and lets it line up with the panel headers above and beside it.
    static let controlHeight: CGFloat = 28

    /// Vertical rule separating control *groups* inside a bar. Shorter than
    /// the bar so it reads as a gap between groups, not as a wall.
    static let controlDividerHeight: CGFloat = 16

    /// The width every leading glyph reserves in a list row — a file's
    /// status in the tree, a category in the progress footer. Glyphs differ
    /// in width by a couple of points, so without a fixed column the text
    /// beside them starts in a slightly different place on every row.
    static let glyphColumn: CGFloat = 14

    // MARK: - Layout rhythm

    /// A 4pt grid. macOS itself is laid out on one, and the app had been
    /// picking 5, 6, 7, 9, 10, 11 and 14pt gaps view by view — close enough
    /// to look accidental rather than intentional when two panels sit side by
    /// side.
    enum Space {
        /// Between a glyph and its label.
        static let xs: CGFloat = 4
        /// Between related controls in a row.
        static let s: CGFloat = 8
        /// Between rows inside one block; the standard inset from a panel edge.
        static let m: CGFloat = 12
        /// Between blocks.
        static let l: CGFloat = 16
        /// Between sections that are not related.
        static let xl: CGFloat = 24
    }

    /// Both panels' header bars are exactly this tall, so the left sidebar's
    /// summary and the right rail's identity line up across the window
    /// instead of missing each other by a couple of points.
    static let panelHeaderHeight: CGFloat = 44

    /// Three radii, by what the shape *is*: `cornerRadiusLarge` for a panel
    /// or a floating container, `cornerRadius` for a card, `cornerRadiusSmall`
    /// for a control or a chip. Anything nested inside one of those takes
    /// `concentricRadius` instead of a fourth number.
    ///
    /// Nested corners have to be concentric or the inner shape looks like it
    /// is sliding out of the outer one: an inset child's radius is its
    /// parent's, less the inset. Apple's own containers have gone
    /// increasingly rounded, and a hairline plus a material reads as a
    /// surface where a heavy border reads as a box.
    static let cornerRadiusLarge: CGFloat = 14
    static let cornerRadiusSmall: CGFloat = 7

    static func concentricRadius(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(2, outer - inset)
    }
}

extension Theme {
    /// Rounds a scaled dimension to a whole point. Text and image frames must
    /// land on whole points: `11.5 * 1.12` renders soft, `13` renders sharp.
    /// Every scaled size in the app goes through this.
    static func scaled(_ base: CGFloat, _ scale: CGFloat) -> CGFloat {
        max(1, (base * scale).rounded())
    }
}

extension Font {
    /// A system font at a scaled, pixel-aligned size.
    static func reviewrr(
        _ base: CGFloat, scale: CGFloat = 1, weight: Font.Weight = .regular, design: Font.Design = .default
    ) -> Font {
        .system(size: Theme.scaled(base, scale), weight: weight, design: design)
    }
}

/// How large interface text renders, as a multiplier applied by the views
/// that opt in. A scale rather than a second set of font constants: the type
/// hierarchy stays intact, it just gets bigger or smaller as a whole.
private struct ReviewrrTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var reviewrrTextScale: CGFloat {
        get { self[ReviewrrTextScaleKey.self] }
        set { self[ReviewrrTextScaleKey.self] = newValue }
    }
}

extension View {
    /// A soft-elevated container. Elevation here is a hairline and a very
    /// small shadow rather than a heavy drop shadow: macOS cards read as
    /// *cut into* the window, not floating above it.
    func reviewrrCard(elevated: Bool = false) -> some View {
        self
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevated ? 0.12 : 0), radius: elevated ? 8 : 0, y: elevated ? 2 : 0)
    }
}
