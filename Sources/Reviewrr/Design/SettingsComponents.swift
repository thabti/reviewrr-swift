import SwiftUI

/// The shared shape of every settings pane.
///
/// ## Who this is for
///
/// Reviewrr's reviewer is a working engineer who opened Settings to get one
/// thing working — a token, a Jira link, quieter notifications — and wants
/// to leave. They are not tuning; they are setting up. Every pane therefore
/// answers three questions in the same order:
///
/// 1. **What is this, and is it on?** One card, with the vendor's mark at a
///    size you cannot miss, a status word, and the switch.
/// 2. **What is the one decision?** Preset cards, when there is a spectrum
///    to pick a point on, or a single field when there is exactly one thing
///    that differs per team.
/// 3. **Anything else?** Behind an `AdvancedSection`, which stays shut.
///
/// The panes shared none of this before: each was a `Form` of `Section`s
/// with a different idea of what a heading, a helper line and a disabled
/// state looked like, and reading two of them felt like reading two apps.

// MARK: - Hero

/// The card a pane opens with: mark, name, status, and the master switch.
struct SettingsHero<Trailing: View, Body: View>: View {
    let title: String
    let subtitle: String
    let tile: AnyView
    var status: SettingsStatus?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Body

    init(
        title: String,
        subtitle: String,
        tile: AnyView,
        status: SettingsStatus? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Body = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tile = tile
        self.status = status
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                tile

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Space.s) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                        if let status { StatusBadge(status: status) }
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Space.s)
                trailing()
            }
            content()
        }
        .padding(Theme.Space.l)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }
}

/// One word about whether a feature is actually working, in one vocabulary
/// across every pane.
enum SettingsStatus: Equatable {
    case off
    case ready(String)
    case attention(String)
    case problem(String)

    var text: String {
        switch self {
        case .off: return "Off"
        case .ready(let text), .attention(let text), .problem(let text): return text
        }
    }

    var color: Color {
        switch self {
        case .off: return .secondary
        case .ready: return .green
        case .attention: return .orange
        case .problem: return .red
        }
    }
}

struct StatusBadge: View {
    let status: SettingsStatus

    var body: some View {
        Text(status.text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(status.color.opacity(0.4)))
            .foregroundStyle(status.color)
            .accessibilityLabel(status.text)
    }
}

// MARK: - Presets

/// One choice on a spectrum, as a card big enough to read at a glance.
///
/// Cards rather than a radio group or a segmented control because the thing
/// being chosen has a *consequence* that needs a sentence — "a few a day",
/// "every five minutes" — and a radio label has room for a name only.
struct PresetCard: View {
    let systemImage: String
    let title: String
    let summary: String
    /// The one-word consequence: how loud, how often, how much.
    let hint: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(height: 30)

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(summary)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(Theme.Space.m)
            .background(
                isSelected ? Theme.accent.opacity(0.10) : Theme.cardBackground,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.7) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary)
        .accessibilityLabel([title, summary, hint].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A row of preset cards, with a Custom badge when the values behind them
/// no longer match any one.
struct PresetRow<Content: View>: View {
    let question: String
    var isCustom: Bool = false
    var customHelp: String = "The settings in Advanced no longer match any of these"
    @ViewBuilder var cards: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 5) {
                Text(question)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isCustom {
                    Text("Custom")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .help(customHelp)
                }
            }
            HStack(spacing: Theme.Space.s) { cards() }
        }
    }
}

// MARK: - Advanced

/// The drawer everything optional lives in.
///
/// ## Why it is not a `DisclosureGroup`
///
/// A bare disclosure group gives a triangle and a label, and the label
/// carries no information about whether opening it is worth the trouble.
/// This one is a whole row that reacts to the pointer, names what is inside
/// *and* what the current values amount to, and says how many things are in
/// there — so a reviewer can decide not to open it, which is the outcome
/// most of them want.
struct AdvancedSection<Content: View>: View {
    let summary: String
    var itemCount: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Advanced")
                                .font(.callout.weight(.medium))
                            if let itemCount, !isExpanded {
                                Text("\(itemCount)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Theme.controlFill, in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(summary)
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Text(isExpanded ? "Hide" : "Show")
                        .font(Theme.caption)
                        .foregroundStyle(isHovering ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                }
                .padding(Theme.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("Advanced settings. \(summary)")
            .accessibilityValue(isExpanded ? "Shown" : "Hidden")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    content()
                }
                .padding(Theme.Space.l)
            }
        }
        .background(
            (isHovering && !isExpanded ? Theme.controlFillHover : Theme.cardBackground.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }
}

/// A titled group inside Advanced, so a drawer with four unrelated things
/// in it reads as four things rather than one long list.
struct AdvancedGroup<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) { content() }
            if let note {
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page

/// The scroll container every pane uses, so they share a width, a rhythm
/// and a maximum measure.
struct SettingsPage<Content: View>: View {
    var maxWidth: CGFloat = Theme.Settings.contentWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                content()
            }
            .padding(Theme.Settings.inset)
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A labelled row for a single field, used where a pane has exactly one
/// thing to fill in.
struct SettingsField<Content: View>: View {
    let title: String
    var systemImage: String?
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(title)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
            if let note {
                Text(note)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
