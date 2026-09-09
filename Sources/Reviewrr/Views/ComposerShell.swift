import SwiftUI

/// The shape every text composer in the app wears: a card holding the text,
/// a row of small contextual chips along the bottom, and one round action
/// button at the trailing edge.
///
/// One shell, three uses — asking the assistant, replying to a thread,
/// drafting an inline comment — because they are the same gesture and used to
/// look like three unrelated controls: a bordered editor with a prominent
/// push button, a plain field with two text buttons, and a bare `TextEditor`
/// with a save button underneath.
///
/// `tint` is what keeps them apart where it matters. The assistant's is the
/// pinned AI purple; a reply or a draft comment takes the accent, because
/// nothing the reviewer writes should wear the colour this app uses to mean
/// "a model said this".
struct ComposerShell<Chips: View, Action: View>: View {
    let placeholder: String
    /// Shown at the bottom-right of the text area, above the chips — the
    /// reference's context ring lives here. Only pass something real; an
    /// invented percentage is worse than an empty corner.
    var badge: String?
    var tint: Color = Theme.accent
    var isFocused: Bool = false
    var minHeight: CGFloat = 56
    @ViewBuilder var text: () -> AnyView
    @ViewBuilder var chips: () -> Chips
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ZStack(alignment: .topTrailing) {
                text()
                    .frame(minHeight: minHeight, alignment: .topLeading)
                if let badge {
                    Text(badge)
                        .font(Theme.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.controlFill, in: Capsule())
                        .accessibilityHidden(true)
                }
            }

            HStack(spacing: Theme.Space.xs) {
                chips()
                Spacer(minLength: Theme.Space.s)
                action()
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                // Focus is a ring on the card, not on the text box inside it:
                // the card *is* the control, and a second border around an
                // inner field reads as a box in a box.
                .strokeBorder(isFocused ? tint.opacity(0.65) : Theme.hairline, lineWidth: isFocused ? 1.5 : 1)
        )
        .motion(Motion.hover, value: isFocused)
        // The shell already knows whether the reviewer is typing in it, and
        // its send button is the one control that must only claim ⌘⏎ while
        // they are — see `ComposerSendButton`. Published through the
        // environment rather than passed down: this shell has three call
        // sites and the button is built by each of them, so a parameter is
        // a thing a fourth one can forget, and forgetting it is silent.
        .environment(\.composerIsFocused, isFocused)
        .accessibilityElement(children: .contain)
    }

    /// The placeholder, drawn behind an empty editor.
    ///
    /// Says what the field takes *and* how to send it: a multi-line composer
    /// has to teach that Return makes a newline and ⌘Return sends, or the
    /// reviewer discovers it by accidentally sending half a sentence.
    static func placeholderText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
    }
}

/// Focus, from the enclosing `ComposerShell` down to its send button.
private struct ComposerFocusKey: EnvironmentKey {
    /// A send button outside a shell claims nothing — better a button that
    /// needs a click than a ⌘⏎ that fires in a composer nobody is typing in.
    static let defaultValue = false
}

extension EnvironmentValues {
    var composerIsFocused: Bool {
        get { self[ComposerFocusKey.self] }
        set { self[ComposerFocusKey.self] = newValue }
    }
}

/// The round send button from the reference: one filled circle at the
/// trailing edge, which becomes a stop button while work is in flight.
///
/// ⌘⏎ is claimed **only while the composer this button belongs to has
/// focus**. Up to three of these are mounted at once — the AI rail, an
/// inline comment composer, a thread reply — and each used to bind ⌘⏎
/// unconditionally, alongside the Review menu's own. So a reviewer typing an
/// inline comment, taught by that composer's own placeholder that ⌘⏎ files
/// it as a draft, could instead open the Submit Review form or send a
/// half-written question to a model.
struct ComposerSendButton: View {
    var tint: Color = Theme.accent
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var sendHelp: String
    var busyHelp: String = "Stop"
    var onSend: () -> Void
    var onStop: (() -> Void)?

    @Environment(\.composerIsFocused) private var isComposerFocused

    var body: some View {
        Button {
            if isBusy { onStop?() } else { onSend() }
        } label: {
            ZStack {
                Circle()
                    .fill(isBusy ? Color.secondary.opacity(0.25) : tint.opacity(isEnabled ? 1 : 0.3))
                Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isBusy ? Color.primary : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!isBusy && !isEnabled)
        .keyboardShortcut(isComposerFocused ? Shortcut.sendComposer.keyboardShortcut : nil)
        .help(isBusy ? busyHelp : sendHelp)
        .accessibilityLabel(isBusy ? busyHelp : sendHelp)
        .motion(Motion.snappy, value: isBusy)
        .motion(Motion.smooth, value: isEnabled)
    }
}

/// A small inline control in a composer's bottom row — a scope picker, a
/// model name, a file tag count. Reads as a chip, not a push button.
struct ComposerChip<Content: View>: View {
    var systemImage: String?
    var tint: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            content()
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, Theme.chipPaddingHorizontal)
        .padding(.vertical, Theme.chipPaddingVertical)
        .background(Theme.controlFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
