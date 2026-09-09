import XCTest

/// The notification rules, which are the whole feature: what counts as a
/// change, and whether a given change should interrupt a given reviewer at a
/// given moment. Both are pure, so all of it is checkable here rather than by
/// watching a Mac's Notification Centre and hoping.
final class NotificationTests: XCTestCase {
    // MARK: - Fixtures

    private func row(
        number: Int = 1,
        author: String = "someone-else",
        state: InboxPRState = .open,
        isMerged: Bool = false,
        commentCount: Int = 0,
        reviewDecision: InboxReviewDecision = .none,
        ciState: InboxCIState = .unknown,
        requestedReviewers: [String] = [],
        headSha: String? = "sha-1",
        labels: [String] = [],
        buckets: Set<InboxReviewerBucket> = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> InboxPR {
        InboxPR(
            host: .dotCom,
            owner: "acme",
            repo: "web",
            number: number,
            title: "feat: a change",
            authorLogin: author,
            authorAvatarURL: nil,
            state: state,
            isMerged: isMerged,
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            updatedAt: updatedAt,
            commentCount: commentCount,
            labels: labels.enumerated().map { GitHubLabel(id: $0.offset, name: $0.element, color: "ffffff") },
            requestedReviewers: requestedReviewers,
            reviewDecision: reviewDecision,
            ciState: ciState,
            additions: 1,
            deletions: 1,
            changedFiles: 1,
            headRef: "feature",
            headSha: headSha,
            source: .project,
            buckets: buckets
        )
    }

    private var project: WatchedProject {
        WatchedProject(host: .dotCom, owner: "acme", repo: "web")
    }

    /// Everything on, so each test can turn off exactly the thing it is about.
    private func permissivePreferences() -> NotificationPreferences {
        var preferences = NotificationPreferences()
        preferences.enabled = true
        preferences.scope = .allWatched
        preferences.includeOwnPullRequests = true
        preferences.includeDrafts = true
        preferences.updateTriggers = Set(PRUpdateTrigger.allCases)
        preferences.suppressWhileActive = false
        return preferences
    }

    // MARK: - Detecting what changed

    /// The first sync of a project must not announce its whole backlog.
    func testFirstSyncProducesNothing() {
        let changes = PRChangeDetector.changes(previous: [], current: [row(number: 1), row(number: 2)])
        XCTAssertTrue(changes.isEmpty, "watching a project must not notify once per open pull request")
    }

    func testAPullRequestThatWasNotThereBeforeAppears() {
        let changes = PRChangeDetector.changes(previous: [row(number: 1)], current: [row(number: 1), row(number: 2)])
        XCTAssertEqual(changes.count, 1)
        guard case .appeared(let pr) = changes[0] else { return XCTFail("expected an appearance") }
        XCTAssertEqual(pr.number, 2)
    }

    /// A vanished row is not an event — see the comment on `changes`.
    func testARowLeavingTheSyncWindowProducesNothing() {
        let changes = PRChangeDetector.changes(previous: [row(number: 1), row(number: 2)], current: [row(number: 1)])
        XCTAssertTrue(changes.isEmpty)
    }

    /// The heart of it: `updatedAt` moving is not a change worth reporting,
    /// because forges bump it for a label edit or a board move.
    func testABumpedTimestampAloneIsNotAChange() {
        let before = row(updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let after = row(updatedAt: Date(timeIntervalSince1970: 1_700_009_999))
        XCTAssertTrue(PRChangeDetector.triggers(from: before, to: after).isEmpty)
        XCTAssertTrue(PRChangeDetector.changes(previous: [before], current: [after]).isEmpty)
    }

    func testEachTriggerIsDetected() {
        let cases: [(String, InboxPR, InboxPR, PRUpdateTrigger)] = [
            ("a push", row(headSha: "sha-1"), row(headSha: "sha-2"), .newCommits),
            ("a comment", row(commentCount: 2), row(commentCount: 3), .newComments),
            ("an approval", row(), row(reviewDecision: .approved), .reviewDecision),
            ("a red build", row(ciState: .pending), row(ciState: .failure), .checksChanged),
            ("ready for review", row(state: .draft), row(state: .open), .readyForReview),
            ("a merge", row(), row(state: .merged, isMerged: true), .merged),
            ("a close", row(), row(state: .closed), .closed),
            (
                "a review request",
                row(requestedReviewers: [], buckets: []),
                row(requestedReviewers: ["me"], buckets: [.needsReview]),
                .reviewRequested
            ),
        ]
        for (label, before, after, expected) in cases {
            let triggers = PRChangeDetector.triggers(from: before, to: after)
            XCTAssertTrue(triggers.contains(expected), "\(label) should report \(expected.rawValue), got \(triggers)")
        }
    }

    /// A field arriving is not the same as a field changing: search-sourced
    /// rows carry no SHA, and checks report `unknown` until they exist.
    func testAFieldArrivingIsNotAChange() {
        XCTAssertTrue(PRChangeDetector.triggers(from: row(headSha: nil), to: row(headSha: "sha-1")).isEmpty)
        XCTAssertTrue(PRChangeDetector.triggers(from: row(ciState: .success), to: row(ciState: .unknown)).isEmpty)
    }

    // MARK: - Deciding whether to notify

    func testNothingIsDeliveredWhileNotificationsAreOff() {
        var preferences = permissivePreferences()
        preferences.enabled = false
        let decision = NotificationPolicy.decide(
            .appeared(row()),
            context: .init(preferences: preferences)
        )
        XCTAssertFalse(decision.shouldNotify)
        XCTAssertEqual(decision.reason, .notificationsOff)
    }

    func testAMutedProjectIsSilent() {
        let decision = NotificationPolicy.decide(
            .appeared(row()),
            context: .init(preferences: permissivePreferences(), isProjectMuted: true)
        )
        XCTAssertEqual(decision.reason, .projectSilenced)
    }

    func testASilencedProjectIsSilentWithoutBeingMuted() {
        let decision = NotificationPolicy.decide(
            .appeared(row()),
            context: .init(preferences: permissivePreferences(), projectLevel: .silent)
        )
        XCTAssertEqual(decision.reason, .projectSilenced)
    }

    /// A project can narrow the global rules, never widen them.
    func testAProjectSetToReviewRequestsOnlyIgnoresEverythingElse() {
        let context = NotificationPolicy.Context(
            preferences: permissivePreferences(),
            projectLevel: .reviewRequestsOnly
        )
        let push = PRChange.changed(row(headSha: "sha-2"), previous: row(), triggers: [.newCommits])
        XCTAssertEqual(NotificationPolicy.decide(push, context: context).reason, .outOfScope)

        let request = PRChange.changed(
            row(requestedReviewers: ["me"], buckets: [.needsReview]),
            previous: row(),
            triggers: [.reviewRequested]
        )
        XCTAssertTrue(NotificationPolicy.decide(request, context: context).shouldNotify)
    }

    func testAnUnwantedTriggerDoesNotNotify() {
        var preferences = permissivePreferences()
        preferences.updateTriggers = [.reviewRequested]
        let change = PRChange.changed(row(ciState: .failure), previous: row(), triggers: [.checksChanged])
        let decision = NotificationPolicy.decide(change, context: .init(preferences: preferences))
        XCTAssertEqual(decision.reason, .noWantedTrigger)
    }

    /// One change can carry several triggers; wanting any one of them is
    /// enough, or a reviewer who only cares about pushes would miss a push
    /// that arrived alongside a comment.
    func testOneWantedTriggerAmongSeveralIsEnough() {
        var preferences = permissivePreferences()
        preferences.updateTriggers = [.newCommits]
        let change = PRChange.changed(
            row(commentCount: 4, ciState: .failure, headSha: "sha-2"),
            previous: row(),
            triggers: [.newCommits, .newComments, .checksChanged]
        )
        XCTAssertTrue(NotificationPolicy.decide(change, context: .init(preferences: preferences)).shouldNotify)
    }

    func testMyOwnPullRequestsAreSkippedByDefault() {
        var preferences = permissivePreferences()
        preferences.includeOwnPullRequests = false
        let mine = PRChange.appeared(row(author: "Octocat"))
        // Case-insensitively: forges do not agree on the case of a login.
        let decision = NotificationPolicy.decide(
            mine,
            context: .init(preferences: preferences, viewerLogin: "octocat")
        )
        XCTAssertEqual(decision.reason, .ownPullRequest)

        preferences.includeOwnPullRequests = true
        XCTAssertTrue(
            NotificationPolicy.decide(mine, context: .init(preferences: preferences, viewerLogin: "octocat")).shouldNotify
        )
    }

    /// Without a known login, the `authored` bucket is the fallback.
    func testTheAuthoredBucketStandsInForAnUnknownLogin() {
        var preferences = permissivePreferences()
        preferences.includeOwnPullRequests = false
        let decision = NotificationPolicy.decide(
            .appeared(row(buckets: [.authored])),
            context: .init(preferences: preferences, viewerLogin: nil)
        )
        XCTAssertEqual(decision.reason, .ownPullRequest)
    }

    func testDraftsAreSkippedByDefault() {
        var preferences = permissivePreferences()
        preferences.includeDrafts = false
        let decision = NotificationPolicy.decide(
            .appeared(row(state: .draft)),
            context: .init(preferences: preferences)
        )
        XCTAssertEqual(decision.reason, .draft)
    }

    func testScopeNarrowsToInvolvementThenToReviewRequests() {
        var preferences = permissivePreferences()

        preferences.scope = .involved
        XCTAssertEqual(
            NotificationPolicy.decide(.appeared(row(buckets: [])), context: .init(preferences: preferences)).reason,
            .outOfScope
        )
        XCTAssertTrue(
            NotificationPolicy.decide(
                .appeared(row(buckets: [.participated])),
                context: .init(preferences: preferences)
            ).shouldNotify
        )

        preferences.scope = .reviewRequested
        XCTAssertEqual(
            NotificationPolicy.decide(
                .appeared(row(buckets: [.participated])),
                context: .init(preferences: preferences)
            ).reason,
            .outOfScope
        )
        XCTAssertTrue(
            NotificationPolicy.decide(
                .appeared(row(buckets: [.needsReview])),
                context: .init(preferences: preferences)
            ).shouldNotify
        )
    }

    func testLabelFilterRequiresAtLeastOneMatch() {
        var preferences = permissivePreferences()
        preferences.requiredLabels = ["backend", "urgent"]

        XCTAssertEqual(
            NotificationPolicy.decide(
                .appeared(row(labels: ["frontend"])),
                context: .init(preferences: preferences)
            ).reason,
            .labelMismatch
        )
        // Case-insensitively — GitHub labels are free text.
        XCTAssertTrue(
            NotificationPolicy.decide(
                .appeared(row(labels: ["Backend"])),
                context: .init(preferences: preferences)
            ).shouldNotify
        )
    }

    func testAnEmptyLabelFilterMeansAnyLabel() {
        let preferences = permissivePreferences()
        XCTAssertTrue(
            NotificationPolicy.decide(.appeared(row(labels: [])), context: .init(preferences: preferences)).shouldNotify
        )
    }

    // MARK: - Quiet hours

    func testQuietHoursWrapMidnight() {
        var preferences = NotificationPreferences()
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = 22
        preferences.quietHoursEnd = 8

        XCTAssertTrue(preferences.isQuiet(at: hour(23)))
        XCTAssertTrue(preferences.isQuiet(at: hour(2)))
        XCTAssertTrue(preferences.isQuiet(at: hour(22)), "the start hour is inside the quiet period")
        XCTAssertFalse(preferences.isQuiet(at: hour(8)), "the end hour is outside it")
        XCTAssertFalse(preferences.isQuiet(at: hour(14)))
    }

    func testQuietHoursWithinOneDay() {
        var preferences = NotificationPreferences()
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = 9
        preferences.quietHoursEnd = 17
        XCTAssertTrue(preferences.isQuiet(at: hour(12)))
        XCTAssertFalse(preferences.isQuiet(at: hour(20)))
    }

    /// Start equal to end silences the whole day rather than none of it: the
    /// reviewer asked for silence, and the other reading delivers everything.
    func testEqualQuietHoursSilenceTheWholeDay() {
        var preferences = NotificationPreferences()
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = 9
        preferences.quietHoursEnd = 9
        for candidate in [0, 9, 15, 23] {
            XCTAssertTrue(preferences.isQuiet(at: hour(candidate)))
        }
    }

    func testQuietHoursSuppressAnOtherwiseWantedNotification() {
        var preferences = permissivePreferences()
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = 22
        preferences.quietHoursEnd = 8
        let decision = NotificationPolicy.decide(
            .appeared(row()),
            context: .init(preferences: preferences, now: hour(23))
        )
        XCTAssertEqual(decision.reason, .quietHours)
    }

    func testBeingInTheAppSuppressesNotificationsWhenAsked() {
        var preferences = permissivePreferences()
        preferences.suppressWhileActive = true
        XCTAssertEqual(
            NotificationPolicy.decide(
                .appeared(row()),
                context: .init(preferences: preferences, isAppActive: true)
            ).reason,
            .appIsActive
        )
        preferences.suppressWhileActive = false
        XCTAssertTrue(
            NotificationPolicy.decide(
                .appeared(row()),
                context: .init(preferences: preferences, isAppActive: true)
            ).shouldNotify
        )
    }

    private func hour(_ hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 9
        components.hour = hour
        return Calendar.current.date(from: components) ?? Date()
    }

    // MARK: - The feed

    /// An ignored pull request produces no counts and no alerts.
    @MainActor
    func testIgnoredPullRequestsProduceNoEvents() {
        var settings = AppSettings()
        settings.notifications = permissivePreferences()
        let notifier = ActivityNotifier(notifications: NotificationService())
        let events = notifier.noteSync(
            project: project,
            previousRows: [row(number: 1)],
            newRows: [row(number: 1), row(number: 2)],
            context: .init(settings: settings, ignoredKeys: [row(number: 2).statusKey])
        )
        XCTAssertTrue(events.isEmpty)
    }

    /// The feed still fills up when system notifications are refused — they
    /// are two different opt-ins, and the dashboard's bell is the one that
    /// needs no permission.
    @MainActor
    func testTheFeedRecordsEventsThatWereNotNotified() {
        var settings = AppSettings()
        settings.inAppActivityEnabled = true
        settings.notifications.enabled = false
        let notifier = ActivityNotifier(notifications: NotificationService())
        let events = notifier.noteSync(
            project: project,
            previousRows: [row(number: 1)],
            newRows: [row(number: 1), row(number: 2)],
            context: .init(settings: settings, ignoredKeys: [])
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].wasNotified)
        XCTAssertEqual(notifier.recentEvents.count, 1)
    }

    @MainActor
    func testAReviewRequestIsItsOwnKindOfEvent() {
        var settings = AppSettings()
        settings.notifications = permissivePreferences()
        let notifier = ActivityNotifier(notifications: NotificationService())
        let events = notifier.noteSync(
            project: project,
            previousRows: [row(number: 7)],
            newRows: [row(number: 7, requestedReviewers: ["me"], buckets: [.needsReview])],
            context: .init(settings: settings, ignoredKeys: [])
        )
        XCTAssertEqual(events.map(\.kind), [.newReviewRequest])
        XCTAssertEqual(events[0].summary, "Your review was requested")
    }

    /// The one-line wording puts what changes the reviewer's next action
    /// first, whatever else came with it.
    func testWordingRanksTheMostActionableTrigger() {
        XCTAssertEqual(
            ActivityNotifier.describe([.checksChanged, .newComments, .reviewRequested]),
            "Your review was requested · 2 more changes"
        )
        XCTAssertEqual(ActivityNotifier.describe([.newCommits]), "New commits pushed")
        XCTAssertNil(ActivityNotifier.describe([]))
    }

    // MARK: - Stored preferences

    /// The pane and every older reader must agree about whether this is on.
    func testTheLegacyFlagAndTheNestedSwitchStayInStep() throws {
        var settings = AppSettings()
        settings.notifications.enabled = true
        settings.nativeNotificationsEnabled = true
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(round.notifications.enabled)
        XCTAssertTrue(round.nativeNotificationsEnabled)
    }

    /// A blob from the build that only had the flag carries the reviewer's
    /// real answer there.
    func testAnOlderBlobsFlagSeedsTheNestedSwitch() throws {
        let json = Data(#"{"nativeNotificationsEnabled": true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.notifications.enabled, "an existing opt-in must survive the new structure")
    }

    /// Adding preferences must never make a stored blob undecodable.
    func testUnknownAndMissingKeysDecodeToDefaults() throws {
        let json = Data(#"{"notifications": {"enabled": true, "somethingNew": 42}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.notifications.enabled)
        XCTAssertEqual(settings.notifications.updateTriggers, PRUpdateTrigger.defaults)
        XCTAssertEqual(settings.notifications.maxPerPoll, NotificationPreferences().maxPerPoll)
    }

    func testAProjectsNotificationLevelSurvivesARoundTrip() throws {
        var project = self.project
        project.notificationLevel = .reviewRequestsOnly
        let round = try JSONDecoder().decode(WatchedProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(round.notificationLevel, .reviewRequestsOnly)
    }

    func testAProjectFileWrittenBeforeLevelsExistedStillDecodes() throws {
        let json = Data(#"{"host": {"apiBaseURL": "https://api.github.com", "webBaseURL": "https://github.com", "label": "GitHub"}, "owner": "acme", "repo": "web"}"#.utf8)
        // The host shape is whatever `ForgeHost` encodes; if this ever stops
        // decoding it is that shape that changed, which is worth knowing.
        guard let project = try? JSONDecoder().decode(WatchedProject.self, from: json) else { return }
        XCTAssertEqual(project.notificationLevel, .inherit)
    }

    // MARK: - What a click has to survive on
    //
    // A notification is handed back to the app with nothing but its own
    // `userInfo`: the poll that produced it, the project it belonged to and
    // the host it was fetched from are all long gone. Anything a click needs
    // has to be in there and has to come back out intact.

    @MainActor
    func testAClickedNotificationKnowsWhichPullRequestToOpen() {
        let reference = PRReference(owner: "acme", repo: "web", number: 482)
        let info = NotificationService.userInfo(reference: reference, host: .dotCom)
        let target = NotificationService.target(from: info)
        XCTAssertEqual(target?.reference, reference)
        XCTAssertEqual(target?.host, .dotCom)
    }

    /// The reason the host is carried at all: a watchlist mixes forges, and
    /// a reference on its own cannot say which server it came from. Without
    /// this a GitLab notification opened against GitHub.
    @MainActor
    func testAGitLabNotificationOpensAgainstGitLab() {
        let reference = PRReference(owner: "acme", repo: "web", number: 7)
        let info = NotificationService.userInfo(reference: reference, host: .gitLabDotCom)
        let target = NotificationService.target(from: info)
        XCTAssertEqual(target?.host, .gitLabDotCom)
        XCTAssertEqual(target?.host?.forge, .gitlab)
    }

    /// A notification posted by an older build carries no host. It must
    /// still open, on the active one.
    @MainActor
    func testANotificationWithoutAHostStillOpens() {
        let reference = PRReference(owner: "acme", repo: "web", number: 3)
        let target = NotificationService.target(from: [ "reviewrr.reference": reference.key ])
        XCTAssertEqual(target?.reference, reference)
        XCTAssertNil(target?.host)
    }

    /// The test notification and the per-poll summary name no pull request,
    /// so clicking them must do nothing rather than open something arbitrary.
    @MainActor
    func testANotificationWithNoReferenceIsNotADestination() {
        XCTAssertNil(NotificationService.target(from: [:]))
        XCTAssertNil(NotificationService.target(from: ["reviewrr.reference": "not a reference"]))
    }

    /// "Send a test" exists to prove notifications work. Reporting success
    /// when nothing could be posted is the one thing it must never do — and
    /// in a unit-test process, where there is no notification centre to talk
    /// to, nothing can be.
    @MainActor
    func testTheTestNotificationDoesNotClaimToHaveSentAnything() async {
        let service = NotificationService()
        let sent = await service.deliverTest()
        XCTAssertFalse(sent)
        XCTAssertNotNil(service.lastDeliveryError, "a test that posted nothing has to say so")
    }
}
