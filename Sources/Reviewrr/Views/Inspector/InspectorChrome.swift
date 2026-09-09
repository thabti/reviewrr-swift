import SwiftUI

/// Shared chrome for the right rail.
///
/// The rail used to open with three stacked segmented controls — rail, tab,
/// then whatever the panel added — so the two panels were distinguishable
/// only by reading their labels, and roughly a fifth of the column was
/// spent before any content appeared. Stripping that back left the opposite
/// problem: a hairline stripe over a title, which said almost nothing about
/// the one surface in the app that is *not* GitHub.
///
/// What is here now is one header field per rail — an identity line and a
/// live-state strip sharing a single tinted material — followed by the tab
/// bar. Two bands, 80pt, which is three points less than the identity
/// header plus provider row it replaces, and it carries the provider, the
/// model, whether either is usable, the age and shape of the current
/// analysis, and the primary action.
extension AppModel.InspectorRail {
    var tint: Color {
        switch self {
        // Purple is the AI identity everywhere in the app (`AIVisualStyle`),
        // so the rail that hosts AI output wears it too.
        case .ai: return AIVisualStyle.accent
        case .conversation: return Theme.accent
        }
    }

    var title: String {
        switch self {
        case .ai: return "Assistant"
        case .conversation: return "Conversation"
        }
    }

    var help: String {
        switch self {
        case .ai: return "AI assistant — ask, analyze, findings"
        case .conversation: return "GitHub conversation, reviews, and checks"
        }
    }

    /// Only the AI rail gets a mark filled with its identity colour. Its
    /// purple is pinned sRGB in both appearances, so a glyph drawn on it can
    /// be guaranteed to contrast; `Theme.accent` follows whatever the
    /// reviewer picked in System Settings, and white on the yellow accent
    /// measures about 1.5:1. The conversation rail therefore takes the same
    /// tile, size and glyph weight in a tinted-fill form — siblings in
    /// geometry, and deliberately the quieter of the two, because it is the
    /// rail that shows what GitHub said rather than what a model said.
    var usesFilledMark: Bool { self == .ai }
}

/// Fixed dimensions the two rails share so their headers, and therefore
/// their tab bars and content, line up across the window.
enum InspectorChrome {
    /// `Theme.Space.s` + `Theme.controlHeight` + `Theme.Space.s` — the same
    /// arithmetic that makes `Theme.panelHeaderHeight` 44, so the mark is
    /// exactly one control tall inside the identity line.
    static let markSize: CGFloat = Theme.controlHeight

    /// The live-state strip under the identity line: one control, inset by
    /// the smallest step on the grid.
    static let statusStripHeight: CGFloat = Theme.controlHeight + Theme.Space.xs * 2
}

/// A panel's identity field: its mark and name, one line of live state
/// beneath, whatever control the panel owns on the right (the rail
/// switcher), and a status strip carrying the facts and the primary action.
///
/// The mark, the wash and the top edge are all built from `rail.tint`, so
/// the AI rail is unmistakably not the GitHub one from the first pixel of
/// the column — which is the whole point of a surface whose output must
/// never be confused with a GitHub comment.
struct InspectorIdentityHeader<Subtitle: View, Trailing: View, Status: View>: View {
    let rail: AppModel.InspectorRail
    /// One line of live state. A closure rather than a `String` so a panel
    /// can put a self-updating relative date in it without this view owning
    /// a timer.
    @ViewBuilder var subtitle: () -> Subtitle
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                InspectorIdentityMark(rail: rail)

                VStack(alignment: .leading, spacing: 0) {
                    Text(rail.title)
                        .font(.system(size: 15, weight: .semibold))
                    subtitle()
                        .font(.system(size: Theme.captionSize - 0.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                Spacer(minLength: Theme.Space.s)
                trailing()
            }
            .frame(height: Theme.panelHeaderHeight)

            status()
                .frame(height: InspectorChrome.statusStripHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.m)
        .background(identityField)
        .overlay(alignment: .top) { edge }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Material for depth, a tint gradient for identity. The gradient is a
    /// colour wash *over* one material, not a stack of translucent fills
    /// imitating blur: the vibrancy is real, and the tint only says whose
    /// surface this is.
    private var identityField: some View {
        Rectangle()
            .fill(Theme.panelMaterial)
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: rail.tint.opacity(0.20), location: 0),
                        .init(color: rail.tint.opacity(0.07), location: 0.55),
                        .init(color: rail.tint.opacity(0.02), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    /// The rail's colour at full strength along the very top of the column,
    /// fading out to the right. Two points, so it costs no layout height and
    /// still says which rail is open when the header scrolls under a sheet.
    private var edge: some View {
        LinearGradient(
            colors: [rail.tint, rail.tint.opacity(0.25)],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

/// The rail's mark: a rounded tile carrying the rail's glyph in SF Symbols'
/// hierarchical rendering, so the sparkles read as one object with depth
/// rather than a flat sticker.
struct InspectorIdentityMark: View {
    let rail: AppModel.InspectorRail

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
    }

    var body: some View {
        shape
            .fill(fill)
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 1))
            .overlay {
                Image(systemName: rail.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(glyph)
            }
            .frame(width: InspectorChrome.markSize, height: InspectorChrome.markSize)
            .shadow(color: rail.usesFilledMark ? rail.tint.opacity(0.28) : .clear, radius: 4, y: 1)
            // The title beside it says "Assistant" already; a second
            // announcement of the same fact is noise in VoiceOver.
            .accessibilityHidden(true)
    }

    private var fill: LinearGradient {
        LinearGradient(
            colors: rail.usesFilledMark
                ? [rail.tint, rail.tint.opacity(0.78)]
                : [rail.tint.opacity(0.24), rail.tint.opacity(0.10)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var strokeColor: Color {
        rail.usesFilledMark ? Color.white.opacity(0.18) : rail.tint.opacity(0.35)
    }

    private var glyph: Color {
        // On the filled mark the glyph sits on the identity colour itself,
        // which is a deep purple in light mode and a bright lavender in
        // dark — so it has to invert with the appearance, not stay white.
        rail.usesFilledMark ? AIVisualStyle.onAccent : rail.tint
    }
}

/// Native segmented selection keeps both destinations named and keyboard accessible.
struct InspectorRailSwitcher: View {
    @Binding var selection: AppModel.InspectorRail

    var body: some View {
        Picker("Side panel", selection: $selection) {
            ForEach(AppModel.InspectorRail.allCases) { rail in
                Text(rail.title).tag(rail)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 220)
        .accessibilityLabel("Side panel content")
        .help("Switch between the AI assistant and GitHub conversation")
    }
}

struct InspectorTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let symbol: String
    var help: String?
    /// Rendered as a count pill — omit or pass 0 for none. Nil and 0 are
    /// both "no pill", but they are not the same fact: nil is how a panel
    /// says it cannot count something honestly, so nothing here should ever
    /// turn a nil into a zero.
    var badge: Int? = nil
    /// What the pill's number counts, for VoiceOver — "2 unresolved" rather
    /// than "Conversation, 2". Falls back to the bare number.
    var badgeDescription: ((Int) -> String)? = nil
    /// A red dot for "something in here needs attention" (a failing check),
    /// which is a different claim from "there are N of these".
    var alert: Bool = false

    var id: Value { value }
}

/// Underlined text tabs, tinted with the panel's identity colour.
struct InspectorTabBar<Value: Hashable>: View {
    let tabs: [InspectorTab<Value>]
    @Binding var selection: Value
    var tint: Color = Theme.accent

    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        // The buttons carry `Space.s` of their own padding, so this inset
        // lands the first label on the same `Space.m` gutter the header
        // title and every content block below use.
        .padding(.horizontal, Theme.Space.xs)
        .overlay(alignment: .bottom) { Divider() }
        .motion(Motion.snappy, value: selection)
    }

    private func tabButton(_ tab: InspectorTab<Value>) -> some View {
        let isSelected = tab.value == selection
        return Button {
            selection = tab.value
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: Theme.iconSmallSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(tab.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                if let badge = tab.badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? tint.opacity(0.16) : Theme.controlFillHover, in: Capsule())
                        .contentTransition(.numericText())
                }
                if tab.alert {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? tint : Color.secondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(tint)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "inspector.tab.indicator", in: indicator)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.help ?? tab.title)
        .accessibilityLabel(accessibilityLabel(tab))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func accessibilityLabel(_ tab: InspectorTab<Value>) -> String {
        var label = tab.title
        if let badge = tab.badge, badge > 0 {
            label += ", " + (tab.badgeDescription?(badge) ?? "\(badge)")
        }
        if tab.alert { label += ", needs attention" }
        return label
    }
}
