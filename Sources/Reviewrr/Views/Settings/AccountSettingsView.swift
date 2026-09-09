import SwiftUI

/// The Account pane: current credential, its scope/capability diagnostics,
/// rate-limit budget, a per-repository access check, Enterprise host
/// switching, and OAuth device sign-in. Every failure path here renders
/// GitHub's own message plus a remediation sentence — never a spinner that
/// silently stops.
struct AccountSettingsView: View {
    @ObservedObject var auth: AuthModel
    @EnvironmentObject private var model: AppModel

    @State private var tokenInput = ""
    @State private var hostInput = ""
    /// Which kind of host the "Add a host" section is describing.
    ///
    /// Enterprise by default: GitHub.com is always present and needs no
    /// adding, so it is not one of the choices.
    @State private var hostKind: AddHostKind = .enterprise
    @State private var basicUsername = ""
    @State private var basicPassword = ""
    @State private var checkOwner = ""
    @State private var checkRepo = ""
    @State private var diagnosticsExpanded = false
    /// Opens itself when a Basic credential already exists — see
    /// `basicAuthSection`.
    @State private var basicExpanded = false

    private static let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        Form {
            keychainAccessNotice

            // One section per host, not a segmented picker.
            //
            // The picker described a *selection*: everything under it — the
            // credential, its state, and a Sign Out button floating above all
            // of it — silently belonged to whichever segment was chosen, and
            // a reviewer with a token on github.com and another on an
            // appliance could see one at a time with no way to tell the other
            // still existed. A host is a thing on screen now, and the actions
            // that apply to a host live inside it.
            ForEach(auth.hostAccounts) { account in
                hostSection(account)
            }

            addHostSection

            // Scopes, rate limit and the access probe are diagnostics: read
            // once when something is wrong, never during normal use. Stacked
            // open they tripled the length of the pane.
            Section {
                DisclosureGroup("Diagnostics", isExpanded: $diagnosticsExpanded) {
                    if case .verified(let verification) = auth.credentialState {
                        scopesContent(verification)
                        rateLimitContent
                    } else {
                        Text("Verify a credential to see its scopes and rate limit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    repositoryAccessContent
                }
                .help("Scopes, rate limit, and a per-repository access check for \(auth.currentHost.displayName)")
            } footer: {
                Text("Diagnostics apply to \(auth.currentHost.displayName), the host in use.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task {
            auth.refreshHostAccounts()
            await auth.verify()
        }
        .onAppear {
            if let basic = auth.basicCredential {
                basicUsername = basic.username
                basicExpanded = true
            }
            basicUsername = auth.basicCredential?.username ?? ""
        }
    }

    // MARK: - One host

    /// A host, its credential, and everything that can be done to it.
    ///
    /// The section header carries identity and the "in use" badge; the
    /// credential editor only appears for the host actually in use, because
    /// saving a token is an action on the session and verifying one needs the
    /// host it will be sent to.
    @ViewBuilder
    private func hostSection(_ account: HostAccount) -> some View {
        Section {
            hostSummaryRow(account)

            if account.isActive {
                credentialEditor
                basicAuthDisclosure
                if auth.currentHost.isGitHub {
                    deviceFlowDisclosure
                }
            }

            hostActions(account)
        } header: {
            hostHeader(account)
        } footer: {
            if account.isActive {
                Text(storageExplanation)
                    .font(.caption)
            }
        }
    }

    private func hostHeader(_ account: HostAccount) -> some View {
        HStack(spacing: Theme.Space.s) {
            // The forge's own mark rather than an SF Symbol. A list of
            // hosts is exactly where a reviewer scans for "which one is the
            // GitLab" — the vendor's shape answers that faster than any
            // glyph, and faster than reading the hostname.
            BrandGlyph(brand: .forge(account.host.forge), size: 16)
            Text(account.host.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if account.isActive {
                StatusChip(text: "In use", systemImage: "checkmark.circle.fill", palette: .green)
            }
            Spacer(minLength: 0)
            Text(account.kindLabel)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.host.displayName), \(account.kindLabel)\(account.isActive ? ", in use" : "")")
    }

    /// Who this host signs in as. For the active host this is the verified
    /// answer; for the others it is what is in the Keychain, which is all
    /// that can be known without spending a request on it.
    @ViewBuilder
    private func hostSummaryRow(_ account: HostAccount) -> some View {
        if account.isActive {
            credentialStatusView
        } else if account.hasCredential {
            VStack(alignment: .leading, spacing: 2) {
                Label("Credential saved", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                Text(account.credentialSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Label("No credential saved", systemImage: "key.slash")
                .foregroundStyle(.secondary)
                .help("Switch to this host to add one — a credential belongs to the host it was issued by")
        }
    }

    /// The buttons that act on this host. Sign-out is here, inside the host
    /// it signs out of, rather than at the top of the pane above all of them.
    @ViewBuilder
    private func hostActions(_ account: HostAccount) -> some View {
        HStack {
            if !account.isActive {
                Button("Use This Host") { auth.use(host: account.host) }
                    .buttonStyle(.borderedProminent)
                    .help("Switch Reviewrr to \(account.host.displayName) and use its saved credential")
                    .accessibilityLabel("Use \(account.host.displayName)")
            } else {
                Button("Verify") { Task { await auth.verify() } }
                    .disabled(auth.maskedActiveToken == nil && auth.basicCredential == nil)
                    .help("Check this credential against \(account.host.displayName) again")
            }

            Spacer(minLength: 0)

            if account.hasCredential {
                Button("Sign Out", role: .destructive) { auth.signOut(host: account.host) }
                    .help("Remove \(account.host.displayName)'s credential from this Mac. It is not revoked on the server.")
                    .accessibilityLabel("Sign out of \(account.host.displayName)")
            }

            if account.isRemovable {
                Button("Remove", role: .destructive) { auth.forget(host: account.host) }
                    .help(account.isActive
                          ? "Forget \(account.host.displayName) and its credential, and go back to GitHub.com"
                          : "Forget \(account.host.displayName) and its credential")
                    .accessibilityLabel("Remove \(account.host.displayName)")
            }
        }
    }

    // MARK: - Adding a host

    /// Adding a host is its own act, with its own section.
    ///
    /// It used to be two extra controls that appeared inside the picker when
    /// a non-default segment was chosen, which made "switch to Enterprise"
    /// and "tell me the Enterprise URL" the same gesture.
    private var addHostSection: some View {
        Section {
            Picker("Kind", selection: $hostKind) {
                Text("GitHub Enterprise").tag(AddHostKind.enterprise)
                Text("GitLab").tag(AddHostKind.gitlab)
            }
            .pickerStyle(.radioGroup)
            .accessibilityLabel("Kind of host to add")

            TextField(
                "Hostname or URL",
                text: $hostInput,
                prompt: Text(hostKind == .gitlab ? "git.internal.example" : "github.mycompany.com")
            )
            .help("A bare hostname is assumed to be HTTPS; type http:// explicitly to use it. A path is kept, for an instance installed under a subdirectory.")
            .accessibilityLabel("Hostname or URL of the host to add")

            HStack {
                Button("Add & Use") {
                    Task {
                        switch hostKind {
                        case .gitlab: await auth.useGitLabHost(hostInput)
                        case .enterprise: await auth.useEnterpriseHost(hostInput)
                        }
                        auth.refreshHostAccounts()
                        hostInput = ""
                    }
                }
                .buttonStyle(.borderedProminent)
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
        } header: {
            Text("Add a host")
        } footer: {
            Text("Each host keeps its own credential in the Keychain; adding one never carries a credential over. Enterprise needs a token saved for the host you are on before it can be verified against the new one.")
                .font(.caption)
        }
    }

    // MARK: - Keychain access

    /// What to say when the Keychain refuses this build.
    ///
    /// A refusal used to be indistinguishable from "no token saved": the app
    /// looked signed out, and asked again on the next launch. It now says
    /// what happened, offers the two things that actually help, and stops
    /// asking on its own.
    @ViewBuilder
    private var keychainAccessNotice: some View {
        switch model.tokenSource {
        case .denied(let denial):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label(deniedHeadline(denial), systemImage: "key.slash")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(deniedExplanation(denial))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try the Keychain again") { model.retryKeychain() }
                        .help("Ask macOS for the stored token once more")
                    if !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Use for this session") {
                            let value = tokenInput
                            tokenInput = ""
                            model.useSessionToken(value)
                            Task { await auth.verify() }
                        }
                        .help("Use the token above for this run only, without storing it")
                    }
                }
            }
        case .session:
            Label("Using a token for this session only — it is not stored", systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let status):
            Label("The Keychain returned error \(status).", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .environment:
            Label(
                "Using the token in $\(AppModel.tokenEnvironmentVariable) — the Keychain is not touched",
                systemImage: "terminal"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .unread, .keychain, .missing:
            EmptyView()
        }
    }

    private func deniedHeadline(_ denial: KeychainDenial) -> String {
        switch denial {
        case .userDeclined: return "Keychain access was denied"
        case .interactionNotAllowed: return "The Keychain could not be unlocked"
        case .authenticationFailed: return "The Keychain refused this build"
        }
    }

    private func deniedExplanation(_ denial: KeychainDenial) -> String {
        switch denial {
        case .userDeclined, .authenticationFailed:
            return """
            macOS ties a stored secret to the exact build that saved it. This copy is signed ad hoc, so every rebuild looks like a different app and macOS asks again — approving does not help the next build. Reviewrr will not ask again on its own.\n\nThree ways out, best first: sign the app with a stable development certificate; or run it with \(AppModel.tokenEnvironmentVariable) set in the environment, which skips the Keychain entirely; or paste a token below and use it for this session.
            """
        case .interactionNotAllowed:
            return "Unlock your login keychain in Keychain Access, then try again. Reviewrr will not ask repeatedly on its own."
        }
    }

    private var storageExplanation: String {
        switch model.tokenSource {
        case .session:
            return "Held in memory for this run only — not written to the Keychain, a file, or a log."
        default:
            return "Stored in the macOS Keychain only — never logged, printed, or written anywhere else."
        }
    }

    // MARK: - Credential

    /// The token field for the host in use.
    ///
    /// Only ever the active host: saving a token stores it for the host
    /// Reviewrr is pointed at, and verifying one needs a host to send it to.
    /// Editing another host's token in place would need a second, invisible
    /// notion of "which host am I editing".
    @ViewBuilder
    private var credentialEditor: some View {
        SecureField(
            auth.currentHost.isGitLab ? "Access token (glpat-…)" : "Personal access token",
            text: $tokenInput
        )
        .textContentType(.password)
        .accessibilityLabel("\(auth.currentHost.forge.displayName) access token")

        HStack {
            Button("Save Token") {
                let value = tokenInput
                tokenInput = ""
                Task {
                    await auth.save(token: value)
                    auth.refreshHostAccounts()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Store this token in the Keychain for \(auth.currentHost.displayName) and verify it")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var credentialStatusView: some View {
        switch auth.credentialState {
        case .signedOut:
            Label("Signed out", systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.secondary)
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…")
            }
            .accessibilityElement(children: .combine)
        case .verified(let verification):
            VStack(alignment: .leading, spacing: 4) {
                Label("Signed in as \(verification.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(verification.kind.label) · \(verification.maskedToken)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let masked, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Verification failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("\(masked): \(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Scopes & capabilities

    @ViewBuilder
    private func scopesContent(_ verification: GitHubCredentialVerification) -> some View {
        Group {
            if let scopes = verification.scopes {
                Text(scopes.isEmpty ? "No scopes granted." : scopes.joined(separator: ", "))
                    .font(Theme.monoFontSmall)
                    .textSelection(.enabled)
                    .foregroundStyle(scopes.isEmpty ? .secondary : .primary)
            } else if let note = verification.capabilityNote {
                Text(note)
                    .font(.caption)
            }
            Label(
                verification.scopeSufficiency.summary,
                systemImage: verification.scopeSufficiency.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
            )
            .foregroundStyle(verification.scopeSufficiency.needsAttention ? .orange : .secondary)
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Rate limit

    @ViewBuilder
    private var rateLimitContent: some View {
        Group {
            if let rateLimit = auth.rateLimit {
                budgetRow(title: "Core", budget: rateLimit.core)
                budgetRow(title: "Search", budget: rateLimit.search)
            } else {
                Text("Rate limit unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func budgetRow(title: String, budget: GitHubRateLimitSnapshot.Budget) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(budget.remaining) / \(budget.limit) remaining")
                Text("Resets \(Self.relativeFormatter.localizedString(for: budget.resetAt, relativeTo: .now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Repository access check

    @ViewBuilder
    private var repositoryAccessContent: some View {
        Group {
            HStack {
                TextField(auth.currentHost.isGitLab ? "group/subgroup" : "owner", text: $checkOwner)
                    .accessibilityLabel(auth.currentHost.isGitLab ? "Project group path" : "Repository owner")
                Text("/")
                TextField(auth.currentHost.isGitLab ? "project" : "repository", text: $checkRepo)
                    .accessibilityLabel(auth.currentHost.isGitLab ? "Project name" : "Repository name")
                Button("Check") {
                    Task { await auth.checkRepositoryAccess(owner: checkOwner, repo: checkRepo) }
                }
                .disabled(
                    checkOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || checkRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            repositoryAccessStatusView

            Text("Answers \"can this token see this repository\" directly, without opening it in the review workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var repositoryAccessStatusView: some View {
        switch auth.repositoryCheckState {
        case .idle:
            EmptyView()
        case .checking(let owner, let repo):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking \(owner)/\(repo)…")
            }
        case .succeeded(let access):
            Label(
                "\(access.fullName) is visible — \(access.isPrivate ? "private" : "public") repository.",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .failed(let owner, let repo, let message):
            Label("\(owner)/\(repo): \(message)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// The kinds of host that can be *added*.
    ///
    /// GitHub.com is not among them: it is always present, listed first, and
    /// cannot be removed — a segment for it only ever meant "switch back",
    /// which the host's own card does now.
    enum AddHostKind: String, CaseIterable, Identifiable {
        case enterprise, gitlab

        var id: String { rawValue }
    }

    // MARK: - HTTP Basic

    /// For an instance behind a Basic-protected front door.
    ///
    /// Shown for every host, because a GitHub Enterprise appliance can sit
    /// behind one too — but the note under it is honest about the fact that
    /// on GitHub a token displaces Basic, since both need `Authorization`.
    /// HTTP Basic, for the hosts that sit behind it.
    ///
    /// Folded away by default. It is the rarer of the two credentials — most
    /// hosts want a token — and open by default it put two more text fields
    /// between the token field and everything else. It opens itself when a
    /// Basic credential is already saved, so an existing setup is never
    /// hidden from the person who set it up.
    /// HTTP Basic for the host in use, folded away until it is needed.
    private var basicAuthDisclosure: some View {
        Group {
            DisclosureGroup(isExpanded: $basicExpanded) {
                LabeledContent("Username") {
                    TextField("", text: $basicUsername, prompt: Text("username"))
                        .labelsHidden()
                        .accessibilityLabel("HTTP Basic username")
                }
                LabeledContent("Password") {
                    SecureField("", text: $basicPassword, prompt: Text("password or token"))
                        .labelsHidden()
                        .accessibilityLabel("HTTP Basic password")
                }

                HStack {
                    Button("Save") {
                        Task {
                            await auth.saveBasicCredential(
                                BasicCredential(username: basicUsername, password: basicPassword)
                            )
                            basicPassword = ""
                        }
                    }
                    .disabled(basicUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Store these in the Keychain for \(auth.currentHost.displayName) and re-verify")
                    .accessibilityLabel("Save the HTTP Basic credential")

                    if auth.basicCredential != nil {
                        Button("Remove", role: .destructive) {
                            Task {
                                await auth.saveBasicCredential(nil)
                                basicUsername = ""
                                basicPassword = ""
                            }
                        }
                        .help("Delete this host's Basic credential from this Mac")
                        .accessibilityLabel("Remove the HTTP Basic credential")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("HTTP Basic")
                    if let basic = auth.basicCredential {
                        // The state belongs on the collapsed row: "saved but
                        // not sent" is the one thing a reviewer has to be
                        // told without opening anything.
                        StatusChip(
                            text: auth.basicIsSent ? basic.maskedDescription : "Not sent",
                            systemImage: auth.basicIsSent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                            palette: auth.basicIsSent ? .green : .amber
                        )
                    }
                }
            }
            .help(basicExplanation)
        }
    }

    private var basicExplanation: String {
        switch auth.currentHost.forge {
        case .gitlab:
            return """
                Gets requests through a Basic-protected proxy in front of the instance. It does not sign you in to \
                GitLab: GitLab's API does not accept Basic auth, so an access token is needed as well. Basic travels \
                in Authorization, the token in PRIVATE-TOKEN, so both are sent.
                """
        case .github:
            return """
                For an appliance behind a Basic-protected proxy. GitHub has no separate token header, so Basic and a \
                token both need Authorization and cannot both be sent — when a token is saved, it wins and Basic is \
                not sent. Stored in the Keychain per host.
                """
        }
    }

    // MARK: - Device flow

    /// Browser sign-in, folded away: it is one of two ways to get a
    /// credential and the other one is the field directly above it.
    private var deviceFlowDisclosure: some View {
        DisclosureGroup("Sign in with a browser") {
            // The client-ID field only appears when this build has no ID of
            // its own to use. A configured build already works, and putting
            // an OAuth client ID in front of someone who never needs to
            // think about one is the fastest way to make sign-in look hard.
            if auth.requiresClientIDFromUser {
                TextField("OAuth client ID", text: $auth.deviceFlowClientID)
                    .accessibilityLabel("OAuth client ID for device sign-in")

                if !auth.hasDeviceFlowClientID {
                    Text(AuthModel.missingClientIDMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let provenance = auth.clientIDProvenance {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            deviceFlowStatusView
        }
    }

    @ViewBuilder
    private var deviceFlowStatusView: some View {
        switch auth.deviceFlowState {
        case .idle:
            Button("Continue with GitHub…") { Task { await auth.startDeviceFlow() } }
                .disabled(!auth.hasDeviceFlowClientID)

        case .requestingCode:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Requesting a device code…")
            }

        case .awaitingAuthorization(let code):
            DeviceCodeView(
                code: code,
                onCopy: { auth.copyToPasteboard(code.userCode) },
                onOpenGitHub: { auth.openVerificationURI(code.verificationURIComplete ?? code.verificationURI) },
                onCancel: { auth.cancelDeviceFlow() }
            )

        case .succeeded:
            Label("Signed in.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Device sign-in failed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { Task { await auth.startDeviceFlow() } }
                    .disabled(!auth.hasDeviceFlowClientID)
            }
        }
    }
}
