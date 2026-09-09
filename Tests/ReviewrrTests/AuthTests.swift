import XCTest

final class AuthTests: XCTestCase {
    // MARK: - Token kind detection

    func testDetectsClassicPAT() {
        XCTAssertEqual(GitHubTokenKind.detect("ghp_abcdefghijklmnopqrstuvwxyz0123456789"), .classicPAT)
    }

    func testDetectsFineGrainedPAT() {
        XCTAssertEqual(GitHubTokenKind.detect("github_pat_11ABCDEFG0abcdefghijklmnop"), .fineGrainedPAT)
    }

    func testDetectsOAuthToken() {
        XCTAssertEqual(GitHubTokenKind.detect("gho_16C7e42F292c6912E7710c838347Ae178B4a"), .oauthToken)
    }

    func testDetectsAppUserToServerToken() {
        XCTAssertEqual(GitHubTokenKind.detect("ghu_16C7e42F292c6912E7710c838347Ae178B4a"), .appUserToServer)
    }

    func testDetectsAppInstallationToken() {
        XCTAssertEqual(GitHubTokenKind.detect("ghs_16C7e42F292c6912E7710c838347Ae178B4a"), .appInstallation)
    }

    func testDetectsRefreshToken() {
        XCTAssertEqual(GitHubTokenKind.detect("ghr_16C7e42F292c6912E7710c838347Ae178B4a"), .refreshToken)
    }

    func testDetectsLegacyClassic40HexToken() {
        XCTAssertEqual(GitHubTokenKind.detect("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .legacyClassic)
        XCTAssertEqual(GitHubTokenKind.detect("0123456789abcdef0123456789abcdef01234567"), .legacyClassic)
    }

    func testUnrecognizedFormatsFallThrough() {
        XCTAssertEqual(GitHubTokenKind.detect(""), .unrecognized)
        XCTAssertEqual(GitHubTokenKind.detect("not-a-token"), .unrecognized)
        // 40 characters but not all hex — must not be mistaken for legacy classic.
        XCTAssertEqual(GitHubTokenKind.detect("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"), .unrecognized)
    }

    func testTrimsWhitespaceBeforeDetecting() {
        XCTAssertEqual(GitHubTokenKind.detect("  ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"), .classicPAT)
    }

    func testOnlyClassicAndOAuthKindsReportScopesViaHeader() {
        XCTAssertTrue(GitHubTokenKind.classicPAT.reportsScopesViaHeader)
        XCTAssertTrue(GitHubTokenKind.oauthToken.reportsScopesViaHeader)
        XCTAssertTrue(GitHubTokenKind.legacyClassic.reportsScopesViaHeader)
        XCTAssertFalse(GitHubTokenKind.fineGrainedPAT.reportsScopesViaHeader)
        XCTAssertFalse(GitHubTokenKind.appUserToServer.reportsScopesViaHeader)
        XCTAssertFalse(GitHubTokenKind.appInstallation.reportsScopesViaHeader)
        XCTAssertFalse(GitHubTokenKind.refreshToken.reportsScopesViaHeader)
        XCTAssertFalse(GitHubTokenKind.unrecognized.reportsScopesViaHeader)
    }

    // MARK: - Masking

    func testMasksClassicPATWithPrefixAndLastFourCharacters() {
        XCTAssertEqual(GitHubCredentialMasking.mask("ghp_abcdefghijklmnopqrstuvwxyz1a2b"), "ghp_••••1a2b")
    }

    func testMasksFineGrainedPATWithItsLongerPrefix() {
        XCTAssertEqual(GitHubCredentialMasking.mask("github_pat_11ABCDEF00000000000000wxyz"), "github_pat_••••wxyz")
    }

    func testMasksLegacyOrUnrecognizedTokensWithNoPrefix() {
        XCTAssertEqual(GitHubCredentialMasking.mask("0123456789abcdef0123456789abcdef01234567"), "••••4567")
        XCTAssertEqual(GitHubCredentialMasking.mask("short"), "••••hort")
    }

    func testMaskNeverContainsTheRawTokenBody() {
        let token = "ghp_thisIsASecretTokenValue9999"
        let masked = GitHubCredentialMasking.mask(token)
        XCTAssertFalse(masked.contains("thisIsASecretTokenValue"))
    }

    // MARK: - Scope sufficiency

    func testSufficientWhenRepoAndOrgReadBothGranted() {
        let result = GitHubScopeEvaluator.evaluate(scopes: ["repo", "read:org"], kind: .classicPAT)
        XCTAssertEqual(result, .sufficient)
        XCTAssertFalse(result.needsAttention)
    }

    func testPublicRepoScopeCountsAsRepoAccess() {
        let result = GitHubScopeEvaluator.evaluate(scopes: ["public_repo", "read:org"], kind: .oauthToken)
        XCTAssertEqual(result, .sufficient)
    }

    func testMissingOrgReadOnly() {
        let result = GitHubScopeEvaluator.evaluate(scopes: ["repo"], kind: .classicPAT)
        XCTAssertEqual(result, .missingOrgRead)
        XCTAssertTrue(result.needsAttention)
    }

    func testMissingRepoAccessOnly() {
        let result = GitHubScopeEvaluator.evaluate(scopes: ["read:org"], kind: .classicPAT)
        XCTAssertEqual(result, .missingRepoAccess)
        XCTAssertTrue(result.needsAttention)
    }

    func testMissingBothScopes() {
        let result = GitHubScopeEvaluator.evaluate(scopes: [], kind: .classicPAT)
        XCTAssertEqual(result, .missingBoth)
        XCTAssertTrue(result.needsAttention)
    }

    func testNilScopesTreatedAsNoneGranted() {
        XCTAssertEqual(GitHubScopeEvaluator.evaluate(scopes: nil, kind: .classicPAT), .missingBoth)
    }

    func testFineGrainedAndAppTokensReportNotReportedRegardlessOfScopesArray() {
        XCTAssertEqual(GitHubScopeEvaluator.evaluate(scopes: ["repo"], kind: .fineGrainedPAT), .notReported)
        XCTAssertEqual(GitHubScopeEvaluator.evaluate(scopes: nil, kind: .appInstallation), .notReported)
        XCTAssertFalse(GitHubScopeSufficiency.notReported.needsAttention)
    }

    // MARK: - ForgeHost.enterprise parsing

    func testEnterpriseParsesBareHostname() {
        let host = ForgeHost.enterprise("github.mycorp.com")
        XCTAssertEqual(host?.displayName, "github.mycorp.com")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://github.mycorp.com/api/v3"))
        XCTAssertEqual(host?.webBaseURL, URL(string: "https://github.mycorp.com"))
        XCTAssertEqual(host?.graphQLURL, URL(string: "https://github.mycorp.com/api/graphql"))
        XCTAssertFalse(host?.isDotCom ?? true)
    }

    func testEnterpriseParsesFullHTTPSURL() {
        let host = ForgeHost.enterprise("https://github.mycorp.com")
        XCTAssertEqual(host?.displayName, "github.mycorp.com")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://github.mycorp.com/api/v3"))
    }

    func testEnterpriseParsesURLWithPathByKeepingOnlyTheHost() {
        // Any path component on the input is discarded — the host always
        // rebuilds its own well-known API/web/GraphQL roots from the bare
        // host, not whatever path the reviewer happened to paste.
        let host = ForgeHost.enterprise("https://github.mycorp.com/some/enterprise/path")
        XCTAssertEqual(host?.displayName, "github.mycorp.com")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://github.mycorp.com/api/v3"))
        XCTAssertEqual(host?.webBaseURL, URL(string: "https://github.mycorp.com"))
    }

    func testEnterpriseRejectsEmptyAndGarbageInput() {
        XCTAssertNil(ForgeHost.enterprise(""))
        XCTAssertNil(ForgeHost.enterprise("   "))
        XCTAssertNil(ForgeHost.enterprise("not a valid host at all"))
    }

    func testEnterpriseTrimsWhitespace() {
        let host = ForgeHost.enterprise("  github.mycorp.com  \n")
        XCTAssertEqual(host?.displayName, "github.mycorp.com")
    }

    // MARK: - Device flow: success responses

    func testParsesDeviceCodeFixture() throws {
        let json = """
        {
            "device_code": "3584d83530557fdd1f46af8289938c8ef79f9dc5",
            "user_code": "WDJB-MJHT",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 5
        }
        """
        let code = try GitHubAuth.parseDeviceCode(from: Data(json.utf8))
        XCTAssertEqual(code.deviceCode, "3584d83530557fdd1f46af8289938c8ef79f9dc5")
        XCTAssertEqual(code.userCode, "WDJB-MJHT")
        XCTAssertEqual(code.verificationURI, "https://github.com/login/device")
        XCTAssertNil(code.verificationURIComplete)
        XCTAssertEqual(code.interval, 5)
        XCTAssertGreaterThan(code.expiresAt, Date())
    }

    func testDeviceCodeIntervalIsFlooredToAtLeastFiveSeconds() throws {
        let json = """
        {"device_code":"abc","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}
        """
        let code = try GitHubAuth.parseDeviceCode(from: Data(json.utf8))
        XCTAssertEqual(code.interval, 5)
    }

    func testParsesSuccessfulDeviceTokenFixture() throws {
        let json = """
        {"access_token":"gho_16C7e42F292c6912E7710c838347Ae178B4a","token_type":"bearer","scope":"repo,read:org"}
        """
        let result = try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8))
        XCTAssertEqual(result, .success(token: "gho_16C7e42F292c6912E7710c838347Ae178B4a"))
    }

    // MARK: - Device flow: error codes

    func testAuthorizationPendingIsTreatedAsPending() throws {
        let json = #"{"error":"authorization_pending","error_description":"still waiting"}"#
        let result = try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8))
        XCTAssertEqual(result, .pending(retryIntervalOverride: nil))
    }

    func testSlowDownIsTreatedAsPending() throws {
        let json = #"{"error":"slow_down","error_description":"polling too fast"}"#
        let result = try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8))
        XCTAssertEqual(result, .pending(retryIntervalOverride: nil))
    }

    func testExpiredTokenIsTerminalWithDetail() throws {
        let json = #"{"error":"expired_token","error_description":"the code expired"}"#
        let result = try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8))
        XCTAssertEqual(result, .failed(.expiredToken, detail: "the code expired"))
    }

    func testAccessDeniedIsTerminal() throws {
        let json = #"{"error":"access_denied"}"#
        let result = try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8))
        XCTAssertEqual(result, .failed(.accessDenied, detail: nil))
    }

    func testExpiredAndAccessDeniedAreDistinctTerminalMessages() {
        XCTAssertNotEqual(GitHubDeviceFlowErrorCode.expiredToken.message, GitHubDeviceFlowErrorCode.accessDenied.message)
        XCTAssertNotEqual(GitHubDeviceFlowErrorCode.authorizationPending.message, GitHubDeviceFlowErrorCode.slowDown.message)
    }

    func testMalformedDeviceTokenResponseThrowsRatherThanCrashing() {
        let json = "{}"
        XCTAssertThrowsError(try GitHubAuth.parseDeviceTokenResponse(from: Data(json.utf8)))
    }

    // MARK: - Auth preferences round-trip (UserDefaults, not the Keychain)

    func testAuthPreferencesDefaultsToEmptyClientID() {
        XCTAssertEqual(AuthPreferences().deviceFlowClientID, "")
    }

    func testAuthPreferencesSaveAndLoadRoundTrips() {
        var prefs = AuthPreferences.load()
        let original = prefs.deviceFlowClientID
        defer {
            prefs.deviceFlowClientID = original
            prefs.save()
        }
        prefs.deviceFlowClientID = "Iv1.test-client-id"
        prefs.save()
        XCTAssertEqual(AuthPreferences.load().deviceFlowClientID, "Iv1.test-client-id")
    }
}

/// Which OAuth client ID "Continue with GitHub" ends up using, and why.
///
/// Resolution is pure so these run without a bundle, an environment, or
/// `UserDefaults` — the three things the live `current()` reads.
final class GitHubOAuthAppTests: XCTestCase {
    func testUsesTheBundledClientIDWhenThatIsAllThereIs() {
        let app = GitHubOAuthApp.resolve(userProvided: nil, environment: nil, bundled: "Ov23libundled")
        XCTAssertEqual(app.clientID, "Ov23libundled")
        XCTAssertEqual(app.source, .bundled)
        XCTAssertTrue(app.isConfigured)
    }

    func testEnvironmentOverridesTheBundledClientID() {
        let app = GitHubOAuthApp.resolve(userProvided: nil, environment: "Ov23lienv", bundled: "Ov23libundled")
        XCTAssertEqual(app.clientID, "Ov23lienv")
        XCTAssertEqual(app.source, .environment)
    }

    /// The typed value wins over both: it is the only one of the three a
    /// reviewer can change without a rebuild or a relaunch, so ignoring it
    /// would make the Settings field look broken.
    func testUserProvidedClientIDWinsOverEnvironmentAndBundle() {
        let app = GitHubOAuthApp.resolve(userProvided: "Ov23liuser", environment: "Ov23lienv", bundled: "Ov23libundled")
        XCTAssertEqual(app.clientID, "Ov23liuser")
        XCTAssertEqual(app.source, .userProvided)
    }

    func testNoClientIDAnywhereIsUnconfiguredRatherThanEmptyString() {
        let app = GitHubOAuthApp.resolve(userProvided: nil, environment: nil, bundled: nil)
        XCTAssertEqual(app, .unconfigured)
        XCTAssertFalse(app.isConfigured)
        XCTAssertTrue(app.clientID.isEmpty)
    }

    func testBlankAndWhitespaceOnlyValuesFallThroughToTheNextSource() {
        let app = GitHubOAuthApp.resolve(userProvided: "   ", environment: "\n", bundled: "Ov23libundled")
        XCTAssertEqual(app.source, .bundled, "an empty field is not a choice of client ID")
    }

    /// `INFOPLIST_KEY_ReviewrrGitHubClientID: "$(REVIEWRR_GITHUB_CLIENT_ID)"`
    /// reaches the bundle verbatim when the build setting is undefined. It
    /// must read as "not configured" — sending it to GitHub would come back
    /// as `incorrect_client_credentials` and look like a Reviewrr bug.
    func testUnsubstitutedBuildSettingIsNotTreatedAsAClientID() {
        XCTAssertNil(GitHubOAuthApp.sanitize("$(REVIEWRR_GITHUB_CLIENT_ID)"))
        let app = GitHubOAuthApp.resolve(
            userProvided: nil, environment: nil, bundled: "$(REVIEWRR_GITHUB_CLIENT_ID)"
        )
        XCTAssertEqual(app, .unconfigured)
    }

    func testSanitizeTrimsSurroundingWhitespaceButRejectsInteriorWhitespace() {
        XCTAssertEqual(GitHubOAuthApp.sanitize("  Ov23liXXXX \n"), "Ov23liXXXX")
        // A pasted line break inside the value would otherwise become an
        // unexplained HTTP 401 rather than a visible "add a client ID".
        XCTAssertNil(GitHubOAuthApp.sanitize("Ov23li\nXXXX"))
        XCTAssertNil(GitHubOAuthApp.sanitize("Ov23li XXXX"))
    }

    func testRequestedScopeMatchesWhatTheScopeEvaluatorCallsSufficient() {
        let granted = GitHubOAuthApp.scope.split(separator: " ").map(String.init)
        XCTAssertEqual(
            GitHubScopeEvaluator.evaluate(scopes: granted, kind: .oauthToken),
            .sufficient,
            "a token obtained by signing in must pass the Account pane's own scope check"
        )
    }
}

/// `AuthModel`'s side of signing in: that a credential obtained here is
/// published app-wide, not just stored.
@MainActor
final class AuthModelSignInTests: XCTestCase {
    /// A context that records what it was asked to store, standing in for
    /// `AppModel`'s Keychain-plus-publish wiring.
    private final class Recorder {
        var token: String?
        var basic: BasicCredential?
        var saveCount = 0
        var forgetCount = 0

        var context: AppContext {
            AppContext(
                api: { GitHubAPI() },
                token: { [self] in token },
                saveToken: { [self] value in
                    token = value
                    saveCount += 1
                },
                forgetToken: { [self] in
                    token = nil
                    forgetCount += 1
                },
                basic: { [self] in basic },
                saveBasic: { [self] value in basic = value },
                reloadCredential: {},
                credentialFor: { [self] host in
                    HostCredential(host: host, credential: ForgeCredential(token: token, basic: basic))
                },
                knownHosts: { [.dotCom] },
                settings: { AppSettings() },
                updateSettings: { _ in }
            )
        }
    }

    /// `AuthModel` writes the client-ID field straight to `UserDefaults`, so
    /// every test here restores what was there.
    private func withCleanClientID(_ body: (AuthModel) async -> Void) async {
        var prefs = AuthPreferences.load()
        let original = prefs.deviceFlowClientID
        defer {
            prefs.deviceFlowClientID = original
            prefs.save()
        }
        prefs.deviceFlowClientID = ""
        prefs.save()
        await body(AuthModel(context: Recorder().context))
    }

    /// The bug this guards: sign-in used to write the Keychain directly and
    /// skip the context, so a credential reached Settings and nothing else.
    /// Verification then fails (no network in tests) — which is fine; the
    /// assertion is that the token was *published* before that.
    func testSavingATokenPublishesItThroughTheContext() async {
        let recorder = Recorder()
        let model = AuthModel(context: recorder.context)

        await model.save(token: "  ghp_published0123456789  ")

        XCTAssertEqual(recorder.token, "ghp_published0123456789", "trimmed, and stored via the context")
        XCTAssertEqual(recorder.saveCount, 1)
    }

    func testSavingAnEmptyTokenStoresNothing() async {
        let recorder = Recorder()
        let model = AuthModel(context: recorder.context)

        await model.save(token: "   \n ")

        XCTAssertNil(recorder.token)
        XCTAssertEqual(recorder.saveCount, 0)
    }

    func testSignOutForgetsTheCredentialThroughTheContextAndResetsState() async {
        let recorder = Recorder()
        recorder.token = "ghp_alreadysignedin00"
        let model = AuthModel(context: recorder.context)
        XCTAssertTrue(model.isSignedIn)

        model.signOut()

        XCTAssertEqual(recorder.forgetCount, 1)
        XCTAssertNil(recorder.token)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertEqual(model.credentialState, .signedOut)
        XCTAssertNil(model.rateLimit)
        XCTAssertEqual(model.repositoryCheckState, .idle)
        XCTAssertEqual(model.deviceFlowState, .idle, "an in-flight device flow must not outlive sign-out")
    }

    /// Starting sign-in with nothing configured has to say what to do about
    /// it, not stall on a spinner — and must not reach the network.
    func testStartingSignInWithNoClientIDFailsWithGuidance() async {
        await withCleanClientID { model in
            // Only meaningful on a build that has no ID of its own. A build
            // configured with one would (correctly) reach for the network
            // here, so there is nothing to assert about it.
            guard model.requiresClientIDFromUser else { return }

            await model.startDeviceFlow()

            XCTAssertEqual(model.deviceFlowState, .failed(AuthModel.missingClientIDMessage))
            XCTAssertFalse(model.hasDeviceFlowClientID)
        }
    }

    func testTypingAClientIDMakesSignInAvailable() async {
        await withCleanClientID { model in
            XCTAssertFalse(model.hasDeviceFlowClientID)
            model.deviceFlowClientID = "Ov23litypedbyhand"
            XCTAssertTrue(model.hasDeviceFlowClientID)
            XCTAssertEqual(model.oauthApp.source, .userProvided)
            XCTAssertNil(model.clientIDProvenance, "the field they typed into is already on screen")
        }
    }
}

/// When the window shows the sign-in screen instead of the dashboard.
@MainActor
final class SignInGateTests: XCTestCase {
    private func needsSignIn(
        token: String? = nil,
        source: AppModel.TokenSource,
        isDismissed: Bool = false
    ) -> Bool {
        AppModel.needsSignIn(token: token, source: source, isDismissed: isDismissed)
    }

    func testNothingStoredMeansSignIn() {
        XCTAssertTrue(needsSignIn(source: .missing))
    }

    func testAKeychainRefusalStillOffersSignIn() {
        // The token could not be read, so there is nothing to work with —
        // and the sign-in screen is where the refusal gets explained.
        XCTAssertTrue(needsSignIn(source: .denied(.userDeclined)))
        XCTAssertTrue(needsSignIn(source: .failed(errSecDecode)))
    }

    /// The flash this exists to prevent: the Keychain is read on first
    /// appearance, not in `init`, so "not looked yet" must not be read as
    /// "signed out" for the frames before it answers.
    func testAnUnreadKeychainIsNotYetGroundsForSignIn() {
        XCTAssertFalse(needsSignIn(source: .unread))
    }

    func testAnyCredentialSourceCountsAsSignedIn() {
        XCTAssertFalse(needsSignIn(token: "ghp_stored0123456789", source: .keychain))
        XCTAssertFalse(needsSignIn(token: "ghp_fromenv0123456789", source: .environment))
        // A session token exists only in memory after a Keychain refusal —
        // still a working credential, so still no gate.
        XCTAssertFalse(needsSignIn(token: "ghp_session0123456789", source: .session))
    }

    func testAnEmptyTokenIsNotACredential() {
        XCTAssertTrue(needsSignIn(token: "", source: .keychain))
    }

    /// "Continue without signing in" has to actually continue: the demo and
    /// the read-only dashboard both work, and a screen that came straight
    /// back would be lying about that.
    func testDismissingTheScreenKeepsItDismissedEvenWithNoCredential() {
        XCTAssertFalse(needsSignIn(source: .missing, isDismissed: true))
        XCTAssertFalse(needsSignIn(source: .denied(.userDeclined), isDismissed: true))
    }
}
/// The Keychain's own statuses, mapped to what the app tells the reviewer.
///
/// The distinction these cover is the whole point: "nothing is stored" and
/// "this build was refused" used to be the same `nil`, so the app looked
/// signed out and asked again on the next launch.
final class KeychainOutcomeTests: XCTestCase {
    func testDenialStatusesAreToldApartFromAMissingItem() {
        XCTAssertEqual(KeychainStore.denial(for: errSecUserCanceled), .userDeclined)
        XCTAssertEqual(KeychainStore.denial(for: errSecInteractionNotAllowed), .interactionNotAllowed)
        XCTAssertEqual(KeychainStore.denial(for: errSecInteractionRequired), .interactionNotAllowed)
        XCTAssertEqual(KeychainStore.denial(for: errSecAuthFailed), .authenticationFailed)

        XCTAssertNil(KeychainStore.denial(for: errSecItemNotFound), "nothing stored is not a refusal")
        XCTAssertNil(KeychainStore.denial(for: errSecSuccess))
    }

    func testReadResultsCarryTheRightMeaning() {
        let token = Data("ghp_example".utf8)
        XCTAssertEqual(KeychainStore.readResult(status: errSecSuccess, data: token), .value("ghp_example"))
        XCTAssertEqual(KeychainStore.readResult(status: errSecItemNotFound, data: nil), .notFound)
        XCTAssertEqual(KeychainStore.readResult(status: errSecUserCanceled, data: nil), .denied(.userDeclined))

        // A success with no data is a fault, not an empty token.
        XCTAssertEqual(KeychainStore.readResult(status: errSecSuccess, data: nil), .failed(errSecSuccess))
        // Anything unrecognised keeps its status so a report can name it.
        XCTAssertEqual(KeychainStore.readResult(status: errSecDecode, data: nil), .failed(errSecDecode))
    }
}
