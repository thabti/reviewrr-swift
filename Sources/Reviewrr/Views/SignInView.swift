import SwiftUI

/// The window's fourth surface: what a signed-out reviewer sees instead of
/// a dashboard that can't load anything.
///
/// It takes over the whole window rather than appearing as a sheet over the
/// dashboard, for the same reason the review workspace does: an empty
/// dashboard behind a sign-in sheet is a promise the app cannot keep until
/// there is a credential, and dimming it just makes the emptiness harder to
/// read.
///
/// ## What goes first
///
/// The card leads with the **host**, because every field under it means
/// something different depending on the answer — a token for github.com is
/// not a token for a self-managed GitLab, and a reviewer whose team is on
/// GitLab should not have to find Settings before they can sign in at all.
///
/// Then the credential path that *works on this build*. A build with an
/// OAuth client ID leads with "Continue with GitHub" and folds the token
/// away; a build without one leads with the token field and demotes the
/// button, because a prominent primary button that cannot be pressed is
/// how the previous version of this screen stranded people.
///
/// Below the card, the two ways to look around without an account: the
/// offline demo, and a read-only dashboard. Sign-in is skippable because
/// those genuinely work.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var auth: AuthModel

    @State private var tokenInput = ""
    @State private var hostInput = ""
    @State private var hostKind: HostKind = .dotCom
    @State private var isTokenPathExpanded = false

    /// The three host shapes, in the order a reviewer is likely to want
    /// them. Mirrors the Account pane's picker so the two never disagree.
    enum HostKind: String, CaseIterable, Identifiable {
        case dotCom, enterprise, gitlab

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dotCom: return "GitHub.com"
            case .enterprise: return "Enterprise"
            case .gitlab: return "GitLab"
            }
        }

        var needsHostField: Bool { self != .dotCom }

        var placeholder: String {
            switch self {
            case .dotCom: return ""
            case .enterprise: return "github.mycompany.com"
            case .gitlab: return "git.internal.example"
            }
        }

        static func current(_ host: ForgeHost) -> HostKind {
            if host.isGitLab { return .gitlab }
            return host.isDotCom ? .dotCom : .enterprise
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: 460)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.xl)
                    // Centred in the window rather than pinned to the top,
                    // with the scroll view as the fallback when the window
                    // is shorter than the card. The previous version glued
                    // everything to the top edge of a 900pt window and left
                    // two thirds of it empty.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(background)
        .onAppear {
            hostKind = HostKind.current(auth.currentHost)
            hostInput = auth.currentHost.isDotCom ? "" : auth.currentHost.displayName
        }
    }

    // MARK: - Background

    /// A quiet wash behind the card: the window's own colour, one soft
    /// radial highlight above the mark, and nothing else. Enough to stop a
    /// 1440pt window reading as a flat void, short of decoration that would
    /// compete with the one thing on screen.
    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [Theme.accent.opacity(0.12), .clear],
                center: .init(x: 0.5, y: 0.28),
                startRadius: 0,
                endRadius: 520
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: Theme.Space.xl) {
            header
            card
            escapeHatches
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Space.m) {
            appMark

            VStack(spacing: 6) {
                Text("Reviewrr")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                // Both forges are supported, so the promise is written in
                // both vocabularies rather than GitHub's alone.
                Text("Review pull and merge requests without leaving your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The app's mark as a rounded tile rather than a bare glyph — the
    /// shape a Mac app's identity is expected to arrive in.
    private var appMark: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accent)
            )
            .frame(width: 68, height: 68)
            .shadow(color: Theme.accent.opacity(0.25), radius: 18, y: 6)
            .accessibilityHidden(true)
    }

    // MARK: - The card

    private var card: some View {
        VStack(spacing: 0) {
            hostRow
            Divider().overlay(Theme.hairline)
            credentialRows
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    // MARK: Host

    private var hostRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            fieldLabel("Where do you review?")

            Picker("Host", selection: $hostKind) {
                ForEach(HostKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Code review host")
            .onChange(of: hostKind) { _, kind in
                if kind == .dotCom {
                    auth.useDotComHost()
                    hostInput = ""
                }
            }

            if hostKind.needsHostField {
                HStack(spacing: Theme.Space.s) {
                    TextField("", text: $hostInput, prompt: Text(hostKind.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(hostKind.label) hostname or URL")
                        .onSubmit(applyHost)

                    Button("Connect", action: applyHost)
                        .buttonStyle(.bordered)
                        .disabled(hostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if case .validating = auth.hostSwitchState {
                        ProgressView().controlSize(.small)
                    }
                }

                if case .failed(let message) = auth.hostSwitchState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Signed in to \(auth.currentHost.displayName).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.l)
    }

    private func applyHost() {
        Task {
            switch hostKind {
            case .gitlab: await auth.useGitLabHost(hostInput)
            case .enterprise: await auth.useEnterpriseHost(hostInput)
            case .dotCom: break
            }
        }
    }

    // MARK: Credential

    /// Ordered by what can actually succeed on this build: whichever path
    /// works is the prominent one.
    @ViewBuilder
    private var credentialRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch auth.deviceFlowState {
            case .awaitingAuthorization(let code):
                DeviceCodeView(
                    code: code,
                    onCopy: { auth.copyToPasteboard(code.userCode) },
                    onOpenGitHub: { auth.openVerificationURI(code.verificationURIComplete ?? code.verificationURI) },
                    onCancel: { auth.cancelDeviceFlow() }
                )

            case .requestingCode:
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Asking GitHub for a code…").font(.callout)
                }
                .accessibilityElement(children: .combine)

            case .succeeded:
                Label("Signed in.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .idle, .failed:
                if canUseDeviceFlow {
                    deviceFlowFirst
                } else {
                    tokenFirst
                }
            }
        }
        .padding(Theme.Space.l)
    }

    /// Device sign-in is only offered where it can work: a GitHub host, with
    /// a client ID this build actually has.
    private var canUseDeviceFlow: Bool {
        auth.currentHost.isGitHub && auth.hasDeviceFlowClientID
    }

    /// The configured-build path: one button, and the token folded away.
    private var deviceFlowFirst: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button {
                Task { await auth.startDeviceFlow() }
            } label: {
                Label("Continue with GitHub", systemImage: "arrow.up.forward.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Opens github.com to approve a short code. Reviewrr asks for \(GitHubAuth.defaultDeviceFlowScope).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            deviceFlowFailure

            orDivider

            DisclosureGroup(isExpanded: $isTokenPathExpanded) {
                tokenField.padding(.top, Theme.Space.s)
            } label: {
                Text("Use an access token instead").font(.callout)
            }
        }
    }

    /// The unconfigured-build path: the token *is* the way in, so it is the
    /// form, not a footnote. This is the case the previous screen got wrong.
    private var tokenFirst: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            tokenField

            if auth.currentHost.isGitHub {
                orDivider

                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task { await auth.startDeviceFlow() }
                    } label: {
                        Label("Continue with GitHub", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(true)

                    Text("Unavailable: this build ships no OAuth client ID. \(clientIDHint)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("", text: $auth.deviceFlowClientID, prompt: Text("Ov23li…"))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("OAuth client ID")
                            Text("Public by design — it travels in every OAuth URL. Reviewrr never asks for a client secret.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Add an OAuth client ID").font(.caption)
                    }
                }

                deviceFlowFailure
            }
        }
    }

    private var clientIDHint: String {
        "Create a GitHub OAuth App with device flow enabled to enable it."
    }

    @ViewBuilder
    private var deviceFlowFailure: some View {
        if case .failed(let message) = auth.deviceFlowState, auth.hasDeviceFlowClientID {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            fieldLabel(auth.currentHost.isGitLab ? "GitLab access token" : "Personal access token")

            HStack(spacing: Theme.Space.s) {
                SecureField("", text: $tokenInput, prompt: Text(tokenPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .accessibilityLabel("\(auth.currentHost.forge.displayName) access token")
                    .onSubmit(saveToken)

                // Return submits the token only when the token *is* the
                // primary path; otherwise it belongs to the GitHub button.
                if canUseDeviceFlow {
                    Button("Sign In", action: saveToken)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedToken.isEmpty)
                } else {
                    Button("Sign In", action: saveToken)
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedToken.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }

            Text(scopeHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if case .verifying = auth.credentialState {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Verifying…").font(.caption)
                }
            }

            if case .failed(let masked, let message) = auth.credentialState {
                Label("\(masked): \(message)", systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keychainNotice
        }
    }

    private var tokenPlaceholder: String {
        auth.currentHost.isGitLab ? "glpat-…" : "ghp_… or github_pat_…"
    }

    private var scopeHint: String {
        switch auth.currentHost.forge {
        case .github:
            return "Needs the \(GitHubScopeEvaluator.repoScope) and \(GitHubScopeEvaluator.orgReadScope) scopes. \(storageExplanation)"
        case .gitlab:
            return "Needs the \"api\" scope — \"read_api\" can read but cannot post a review. \(storageExplanation)"
        }
    }

    private var storageExplanation: String {
        switch model.tokenSource {
        case .denied:
            return "The Keychain has refused this build, so it is held in memory for this run only."
        default:
            return "Stored in the macOS Keychain only."
        }
    }

    private var orDivider: some View {
        HStack(spacing: Theme.Space.s) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("or")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private var trimmedToken: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveToken() {
        let value = trimmedToken
        guard !value.isEmpty else { return }
        tokenInput = ""
        Task { await auth.save(token: value) }
    }

    /// The Keychain refusal, said here as well as in Settings: this is the
    /// screen where it bites, because a reviewer who signs in and finds
    /// themselves signed out next launch needs to know why before it
    /// happens twice.
    @ViewBuilder
    private var keychainNotice: some View {
        if case .denied = model.tokenSource {
            VStack(alignment: .leading, spacing: 4) {
                Label("This Mac's Keychain won't store a credential for this build", systemImage: "key.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Signing in still works for this run. To make it stick, sign the app with a stable development certificate, or launch it with $\(AppModel.tokenEnvironmentVariable) set.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try the Keychain again") { model.retryKeychain() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Without an account

    private var escapeHatches: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.l) {
                Button {
                    model.loadDemo()
                } label: {
                    Label("Open the demo", systemImage: "sparkles.rectangle.stack")
                }
                Button {
                    model.isSignInDismissed = true
                } label: {
                    Label("Skip for now", systemImage: "arrow.right")
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Theme.accent)

            Text("The demo runs entirely offline. Without a credential the dashboard stays empty.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
