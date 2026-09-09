import SwiftUI

/// Jira: one address, and a preview of the link it builds.
///
/// ## What this pane used to ask for
///
/// A regular expression, a browse path, a Cloud/Server radio group, four
/// scan toggles, an allow-list and a sample-text field — nine controls to
/// turn `EC-1013` into a hyperlink. The regex was the worst of them: Jira's
/// key shape does not vary between installations, so the field could only
/// ever be left alone or broken, and a reviewer who broke it got silence.
/// It is a constant now (`IssueTrackerSettings.pattern`), the browse path
/// with it, and the flavour is read off the address instead of asked for.
///
/// What is left is the only thing that genuinely differs per team: where
/// their Jira lives. Everything else on screen exists to show that the
/// address works — the preview is the confirmation, and it is the biggest
/// thing in the pane for that reason.
struct IntegrationsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showsAdvanced = false

    private var tracker: Binding<IssueTrackerSettings> {
        Binding(
            get: { model.settings.issueTracker },
            set: {
                model.settings.issueTracker = $0
                model.persistSettings()
            }
        )
    }

    private var settings: IssueTrackerSettings { model.settings.issueTracker }
    private var hasAddress: Bool { !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                connectionCard
                if settings.isEnabled {
                    addressField
                    previewCard
                    whereItAppears
                    advanced
                }
                privacyNote
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connection

    /// The one switch, with the product's identity attached to it.
    ///
    /// A `Form` row reading "Link issue keys to Jira" told a reviewer what
    /// the toggle did but nothing about what they would get. The mark, the
    /// name and a one-line promise do that in the space the row occupied.
    private var connectionCard: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            BrandTile(brand: .jira, isActive: settings.isUsable)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text("Jira")
                        .font(.system(size: 17, weight: .semibold))
                    statusBadge
                }
                Text("Issue keys in a pull request become links you can click — in the header, on inbox rows, and inside descriptions and comments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.s)

            Toggle("", isOn: tracker.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Link issue keys to Jira")
        }
        .padding(Theme.Space.l)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !settings.isEnabled {
            badge("Off", color: .secondary)
        } else if settings.isUsable {
            badge("Connected", color: .green)
        } else {
            badge("Needs an address", color: .orange)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.4)))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    // MARK: - Address

    /// The one field that genuinely differs per team, at the size that
    /// implies it is the only thing to fill in.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionLabel("Your Jira address", systemImage: "link")

            TextField(settings.detectedKind.placeholder, text: tracker.baseURL)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 11)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                        .strokeBorder(addressBorderColor)
                )
                .accessibilityLabel("Jira address")

            addressFeedback
        }
    }

    private var addressBorderColor: Color {
        guard hasAddress else { return Theme.hairline }
        return settings.normalizedBaseURL == nil ? .orange.opacity(0.7) : Theme.addedText.opacity(0.5)
    }

    /// Confirmation, correction, or a nudge — never nothing.
    @ViewBuilder
    private var addressFeedback: some View {
        if !hasAddress {
            Text("Paste the address you use in the browser. Anything after it — /browse, a ticket key, a trailing slash — is trimmed for you.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let normalized = settings.normalizedBaseURL {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.addedText)
                Text("\(settings.detectedKind.detectedLabel) · \(normalized.host ?? normalized.absoluteString)")
                    .foregroundStyle(.secondary)
            }
            .font(Theme.caption)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("That is not a web address yet. It should look like \(settings.detectedKind.placeholder)")
                    .foregroundStyle(.secondary)
            }
            .font(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Preview

    /// What the address produces, shown as the thing itself.
    ///
    /// This is the whole point of the pane: every other field is a guess
    /// until a real key resolves to a real URL. It was a `Form` row at the
    /// bottom under a sample-text box; it is now the largest element on
    /// screen, and clickable, so "does this work" is answered by pressing
    /// it rather than by waiting for the next pull request.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionLabel("What a link will look like", systemImage: "eye")

            HStack(spacing: Theme.Space.m) {
                Text(IssueTrackerSettings.sampleKey)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.4)))
                    .foregroundStyle(Theme.accent)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                if let url = settings.sampleURL {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 5) {
                            Text(url.absoluteString)
                                .font(Theme.monoFontSmall)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Open it — this is exactly the link Reviewrr will build")
                    .accessibilityLabel("Open \(url.absoluteString)")
                } else {
                    Text("Add an address above")
                        .font(Theme.monoFontSmall)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                    .strokeBorder(Theme.hairline)
            )

            if settings.sampleURL != nil {
                Text("Press it to check it opens the right Jira. Reviewrr cannot verify the link for you — it never calls the API.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Where it appears

    private var whereItAppears: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionLabel("Reviewrr looks for keys in", systemImage: "text.magnifyingglass")
            FlowLayout(spacing: 6) {
                ForEach(scanSummary, id: \.label) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                            .font(.caption2)
                        Text(item.label)
                            .font(Theme.caption)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 4)
                    .background(Theme.controlFill, in: Capsule())
                    .foregroundStyle(item.isOn ? .secondary : .tertiary)
                    .overlay(
                        Capsule().strokeBorder(item.isOn ? Theme.hairline : .clear)
                    )
                    // A struck-through chip says "not scanned" without
                    // needing a second colour or a second row.
                    .strikethrough(!item.isOn, color: .secondary)
                }
            }
        }
    }

    private var scanSummary: [(label: String, symbol: String, isOn: Bool)] {
        [
            ("Title", "textformat", true),
            ("Description", "text.alignleft", true),
            ("Branch name", "arrow.branch", settings.scanBranch),
            ("Comments", "bubble.left", settings.scanComments),
        ]
    }

    // MARK: - Advanced

    /// The two settings that remain genuinely optional, out of the way.
    ///
    /// Both exist for one situation each — a diff full of `UTF-8` and
    /// `SHA-256`, and a team that does not want branch names scanned — and
    /// neither is worth a row on a pane a reviewer visits once.
    private var advanced: some View {
        AdvancedSection(
            summary: "Restrict which projects link, and where keys are looked for",
            itemCount: 3,
            isExpanded: $showsAdvanced
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Only link these projects")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("EC, MW — blank for any", text: projectKeysText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Allowed project keys")
                    Text(settings.projectKeys.isEmpty
                         ? "Any key shaped like \(IssueTrackerSettings.sampleKey) becomes a link. Name your projects if a diff full of UTF-8 and SHA-256 starts linking."
                         : "Only \(settings.projectKeys.sorted().joined(separator: ", ")).")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Only the two that anyone turns off.
                //
                // The title and description toggles are gone: a key written
                // in the title of a pull request is the most deliberate
                // mention there is, and nobody wants it left unlinked. They
                // stay on in the model. What remains is the pair with real
                // trade-offs — a branch name full of ticket numbers, and
                // comment threads on a very chatty pull request.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also look in")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Toggle("Branch names", isOn: tracker.scanBranch)
                        .help("Rescues the key that was only ever written in feature/EC-1013-add-invites")
                    Toggle("Comments and review threads", isOn: tracker.scanComments)
                    Text("The title and description are always scanned.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    /// The set edited as a comma-separated list. A token field would be
    /// prettier, but this is a field a reviewer fills in once, from a list
    /// they already have in their head.
    private var projectKeysText: Binding<String> {
        Binding(
            get: { settings.projectKeys.sorted().joined(separator: ", ") },
            set: { text in
                let keys = text
                    .split(whereSeparator: { ", ;".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
                tracker.wrappedValue.projectKeys = Set(keys)
            }
        )
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "lock.shield")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text("Links only. Reviewrr never calls the Jira API and stores no Jira credential, so a self-hosted instance behind a VPN works exactly as well as Atlassian's cloud.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xs)
    }
}

/// An integration's mark: a big rounded tile, lit when the integration is
/// actually working.
///
/// Shared with the Notifications pane so the two read as the same family of
/// screen rather than two people's idea of a settings pane.
struct IntegrationMark: View {
    let systemImage: String
    let tint: Color
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isActive
                        ? [tint.opacity(0.30), tint.opacity(0.12)]
                        : [Color.secondary.opacity(0.16), Color.secondary.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((isActive ? tint : .secondary).opacity(0.35))
            )
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isActive ? tint : Color.secondary)
            )
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
    }
}
