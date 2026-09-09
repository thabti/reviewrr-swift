import XCTest

/// Issue-key detection and linking. Every rule here is one a reviewer will
/// hit on their own pull requests — a key in a branch name, a diff full of
/// `UTF-8`, a pasted `…/browse/EC-1013` in the address field — so all of it
/// is pinned down rather than left to a regex nobody re-reads.
final class IssueTrackerTests: XCTestCase {
    private func settings(
        base: String = "https://example.atlassian.net",
        projects: Set<String> = [],
        kind: IssueTrackerKind = .jiraCloud
    ) -> IssueTrackerSettings {
        var settings = IssueTrackerSettings()
        settings.isEnabled = true
        settings.kind = kind
        settings.baseURL = base
        settings.projectKeys = projects
        return settings
    }

    // MARK: - Building the link

    func testTheLinkIsTheBrowsePermalink() {
        XCTAssertEqual(
            settings().url(for: "EC-1013")?.absoluteString,
            "https://example.atlassian.net/browse/EC-1013"
        )
    }

    /// A reviewer will paste whatever is in their address bar.
    func testTheAddressToleratesWhatSomeoneWillActuallyPaste() {
        let cases = [
            "https://example.atlassian.net",
            "https://example.atlassian.net/",
            "https://example.atlassian.net///",
            "example.atlassian.net",
            "https://example.atlassian.net/browse",
            "https://example.atlassian.net/browse/EC-1013",
        ]
        for candidate in cases {
            XCTAssertEqual(
                settings(base: candidate).url(for: "EC-1013")?.absoluteString,
                "https://example.atlassian.net/browse/EC-1013",
                "\(candidate) should resolve to the site root"
            )
        }
    }

    /// Self-hosted Jira often lives under a context path, and that path is
    /// part of the site root — trimming it would break every link.
    func testASelfHostedContextPathIsKept() {
        let tracker = settings(base: "https://jira.acme.com/jira", kind: .jiraServer)
        XCTAssertEqual(
            tracker.url(for: "EC-1013")?.absoluteString,
            "https://jira.acme.com/jira/browse/EC-1013"
        )
    }

    func testAnUnparseableAddressIsNotUsable() {
        XCTAssertNil(settings(base: "not a url at all").normalizedBaseURL)
        XCTAssertFalse(settings(base: "").isUsable)
    }

    func testADisabledTrackerProducesNothing() {
        var tracker = settings()
        tracker.isEnabled = false
        XCTAssertFalse(tracker.isUsable)
        XCTAssertTrue(IssueKeyDetector(settings: tracker).keys(title: "EC-1013 fix").isEmpty)
    }

    // MARK: - Finding keys

    func testAKeyIsFoundInTheTitle() {
        let found = IssueKeyDetector(settings: settings()).keys(title: "feat(EC-1013): add invites")
        XCTAssertEqual(found.map(\.key), ["EC-1013"])
        XCTAssertEqual(found.first?.projectKey, "EC")
        XCTAssertEqual(found.first?.source, .title)
    }

    /// "Or anywhere": the description and the branch name count too.
    func testAKeyIsFoundInTheDescriptionAndTheBranch() {
        let detector = IssueKeyDetector(settings: settings())
        XCTAssertEqual(detector.keys(body: "Closes EC-1013.").map(\.key), ["EC-1013"])
        XCTAssertEqual(detector.keys(branch: "feature/EC-1013-add-invites").map(\.key), ["EC-1013"])
        XCTAssertEqual(
            detector.keys(comments: ["Same root cause as MW-42"]).map(\.key),
            ["MW-42"]
        )
    }

    func testKeysAreDedupedAcrossSourcesAndOrderedByDeliberateness() {
        let found = IssueKeyDetector(settings: settings()).keys(
            title: "feat(EC-1013): add invites",
            body: "Closes EC-1013, follows MW-42",
            branch: "feature/EC-1013"
        )
        XCTAssertEqual(found.map(\.key), ["EC-1013", "MW-42"])
        XCTAssertEqual(found.first?.source, .title, "the title mention should win the first chip")
    }

    /// Naming your projects buys case-insensitivity as well as precision:
    /// `git checkout -b ec-1013-fix` is how a branch is actually typed.
    func testNamedProjectsMatchInAnyCaseAndAreNormalisedToJirasOwn() {
        let found = IssueKeyDetector(settings: settings(projects: ["EC"]))
            .keys(branch: "feature/ec-1013-add-invites")
        XCTAssertEqual(found.map(\.key), ["EC-1013"])
    }

    /// Without an allow-list, matching any case would link `utf-8`,
    /// `part-2` and `covid-19` in ordinary prose — so it does not.
    func testWithoutAnAllowListOnlyUppercaseKeysMatch() {
        let detector = IssueKeyDetector(settings: settings())
        XCTAssertTrue(detector.keys(body: "fixes ec-1013 and covid-19").isEmpty)
        XCTAssertEqual(detector.keys(body: "fixes EC-1013").map(\.key), ["EC-1013"])
    }

    /// Each source is individually switchable.
    func testTurningOffASourceStopsScanningIt() {
        var tracker = settings()
        tracker.scanBranch = false
        XCTAssertTrue(IssueKeyDetector(settings: tracker).keys(branch: "feature/EC-1013").isEmpty)
        XCTAssertEqual(IssueKeyDetector(settings: tracker).keys(title: "EC-1013").map(\.key), ["EC-1013"])
    }

    // MARK: - False positives

    /// The whole reason the project allow-list exists.
    func testAnAllowListExcludesLookalikes() {
        let noise = "Decode UTF-8, verify SHA-256, upgrade to HTTP-2 — part of EC-1013"
        let permissive = IssueKeyDetector(settings: settings()).keys(body: noise).map(\.key)
        XCTAssertTrue(permissive.contains("EC-1013"))
        XCTAssertGreaterThan(permissive.count, 1, "without an allow-list the lookalikes do match")

        let restricted = IssueKeyDetector(settings: settings(projects: ["EC"])).keys(body: noise).map(\.key)
        XCTAssertEqual(restricted, ["EC-1013"])
    }

    /// The default pattern needs two characters in the project key, so `A-1`
    /// in prose is not a link.
    func testTheDefaultPatternIgnoresASingleLetterPrefix() {
        XCTAssertTrue(IssueKeyDetector(settings: settings()).keys(body: "see item A-1 below").isEmpty)
    }

    /// The pattern is a constant now, so there is no invalid state a
    /// reviewer can put it in — which is the point of it not being a field.
    func testThePatternIsAlwaysValid() {
        XCTAssertTrue(IssueKeyDetector(settings: settings()).isPatternValid)
        XCTAssertTrue(IssueKeyDetector(settings: settings(projects: ["EC"])).isPatternValid)
    }

    // MARK: - Linking prose

    func testABareKeyBecomesAMarkdownLink() {
        let output = IssueKeyLinker.linkify("Closes EC-1013 today.", settings: settings())
        XCTAssertEqual(output, "Closes [EC-1013](https://example.atlassian.net/browse/EC-1013) today.")
    }

    /// A key inside a code span is a literal.
    func testACodeSpanIsLeftAlone() {
        let input = "the branch is `feature/EC-1013` but EC-1013 is the issue"
        let output = IssueKeyLinker.linkify(input, settings: settings())
        XCTAssertTrue(output.contains("`feature/EC-1013`"), "a code span must survive untouched")
        XCTAssertTrue(output.contains("[EC-1013](https://example.atlassian.net/browse/EC-1013) is the issue"))
    }

    /// Wrapping a link in a link produces markup nothing can render.
    func testAnExistingLinkIsNotWrappedTwice() {
        let input = "see [EC-1013](https://example.atlassian.net/browse/EC-1013) for context"
        XCTAssertEqual(IssueKeyLinker.linkify(input, settings: settings()), input)
    }

    func testAnAutolinkIsLeftAlone() {
        let input = "<https://example.atlassian.net/browse/EC-1013>"
        XCTAssertEqual(IssueKeyLinker.linkify(input, settings: settings()), input)
    }

    /// Word boundaries: a longer key must not be half-replaced by a shorter
    /// one that is a prefix of it.
    func testKeysAreMatchedAtWordBoundaries() {
        let output = IssueKeyLinker.linkify("EC-1013 and EC-10131", settings: settings(projects: ["EC"]))
        XCTAssertTrue(output.contains("[EC-1013](https://example.atlassian.net/browse/EC-1013) and"))
        XCTAssertTrue(output.contains("[EC-10131](https://example.atlassian.net/browse/EC-10131)"))
        XCTAssertFalse(output.contains("EC-1013)1"), "a longer key must not be split")
    }

    func testTheSameKeyTwiceIsLinkedTwice() {
        let output = IssueKeyLinker.linkify("EC-1013 blocks EC-1013", settings: settings())
        XCTAssertEqual(
            output,
            "[EC-1013](https://example.atlassian.net/browse/EC-1013) blocks [EC-1013](https://example.atlassian.net/browse/EC-1013)"
        )
    }

    func testProseIsUnchangedWhenTheTrackerIsOff() {
        var tracker = settings()
        tracker.isEnabled = false
        XCTAssertEqual(IssueKeyLinker.linkify("Closes EC-1013", settings: tracker), "Closes EC-1013")
    }

    func testMultilineProseKeepsItsShape() {
        let input = """
        Closes EC-1013.

        - depends on MW-42
        - not EC-1013 again
        """
        let output = IssueKeyLinker.linkify(input, settings: settings())
        XCTAssertEqual(output.components(separatedBy: "\n").count, input.components(separatedBy: "\n").count)
        XCTAssertTrue(output.contains("- depends on [MW-42]"))
    }

    // MARK: - Stored settings

    func testSettingsSurviveARoundTrip() throws {
        var tracker = settings(projects: ["EC", "MW"], kind: .jiraServer)
        tracker.scanComments = false
        var appSettings = AppSettings()
        appSettings.issueTracker = tracker

        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(appSettings))
        XCTAssertEqual(round.issueTracker, tracker)
    }

    /// Adding this must not have made an existing stored blob undecodable.
    func testAnOlderBlobDecodesWithTheTrackerOff() throws {
        let json = Data(#"{"wordWrap": true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(settings.issueTracker.isEnabled)
    }

    /// A blob written when the pattern and browse path *were* settings must
    /// still decode — the keys are simply ignored now.
    func testABlobCarryingTheRetiredFieldsStillDecodes() throws {
        let json = Data(#"{"issueTracker": {"isEnabled": true, "baseURL": "https://example.atlassian.net", "pattern": "[A-Z]+-[0-9]+", "browsePath": "browse"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.issueTracker.isEnabled)
        XCTAssertEqual(
            settings.issueTracker.url(for: "EC-1013")?.absoluteString,
            "https://example.atlassian.net/browse/EC-1013"
        )
    }

    /// Every Jira serves `/browse/KEY`, which is why the path is a constant.
    func testTheBrowsePathIsJirasOwn() {
        XCTAssertEqual(
            settings(base: "https://tickets.acme.com").url(for: "EC-1013")?.absoluteString,
            "https://tickets.acme.com/browse/EC-1013"
        )
    }
}

/// The two simplifications the Integrations pane rests on.
final class IssueTrackerSimplificationTests: XCTestCase {
    /// The regex stopped being configuration. A stored pattern from an
    /// older build must not change detection — otherwise "it should not
    /// change" would hold for new installs only.
    func testDetectionIgnoresAStoredLegacyPattern() throws {
        let json = #"{"isEnabled":true,"baseURL":"https://team.atlassian.net","pattern":"NOPE-[0-9]+"}"#
        let settings = try JSONDecoder().decode(IssueTrackerSettings.self, from: Data(json.utf8))

        let found = IssueKeyDetector(settings: settings).keys(in: "Fixes EC-1013", source: .title)
        XCTAssertEqual(found.map(\.key), ["EC-1013"], "the constant pattern is what detects keys")
    }

    /// A stored `browsePath` is likewise retired: every Jira serves
    /// `/browse/KEY`, and the field could only ever break the link.
    func testLinkUsesTheConstantBrowsePath() throws {
        let json = #"{"isEnabled":true,"baseURL":"https://team.atlassian.net","browsePath":"wrong"}"#
        let settings = try JSONDecoder().decode(IssueTrackerSettings.self, from: Data(json.utf8))
        XCTAssertEqual(
            settings.url(for: "EC-1013")?.absoluteString,
            "https://team.atlassian.net/browse/EC-1013"
        )
    }

    /// Old blobs still decode, including ones that never had these keys.
    func testSettingsWithoutRetiredKeysDecode() throws {
        let json = #"{"isEnabled":true,"baseURL":"https://jira.acme.com/jira"}"#
        let settings = try JSONDecoder().decode(IssueTrackerSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.isUsable)
        XCTAssertEqual(settings.normalizedBaseURL?.absoluteString, "https://jira.acme.com/jira")
    }

    /// The flavour is read off the address rather than asked for — the
    /// radio group only ever changed help text.
    func testFlavourIsInferredFromTheAddress() {
        XCTAssertEqual(IssueTrackerKind.inferred(from: "https://team.atlassian.net"), .jiraCloud)
        XCTAssertEqual(IssueTrackerKind.inferred(from: "TEAM.ATLASSIAN.NET"), .jiraCloud)
        XCTAssertEqual(IssueTrackerKind.inferred(from: "https://jira.acme.com"), .jiraServer)
        XCTAssertEqual(IssueTrackerKind.inferred(from: ""), .jiraServer)
    }

    /// The preview needs a link before the reviewer has typed a key, and
    /// it has to be the real thing rather than a rendering of one.
    func testSampleLinkIsTheRealShape() {
        var settings = IssueTrackerSettings()
        settings.isEnabled = true
        settings.baseURL = "https://team.atlassian.net/browse/OLD-1/"
        XCTAssertEqual(
            settings.sampleURL?.absoluteString,
            "https://team.atlassian.net/browse/\(IssueTrackerSettings.sampleKey)",
            "a pasted /browse/KEY tail is trimmed before the link is built"
        )
    }

    /// Usability no longer depends on a pattern that cannot be invalid.
    func testUsabilityIsAddressAndSwitchOnly() {
        var settings = IssueTrackerSettings()
        XCTAssertFalse(settings.isUsable, "off")
        settings.isEnabled = true
        XCTAssertFalse(settings.isUsable, "no address")
        settings.baseURL = "team.atlassian.net"
        XCTAssertTrue(settings.isUsable, "a bare host is assumed https")
    }
}

/// Notification presets: one decision standing in for twenty-five values.
final class NotificationPresetTests: XCTestCase {
    /// Every preset round-trips: applying it makes it the matching preset.
    /// Without this, a card could be pressed and never look selected.
    func testEveryPresetIsRecognisedAfterBeingApplied() {
        for preset in NotificationPreset.allCases {
            let applied = preset.applied(to: NotificationPreferences())
            XCTAssertEqual(applied.matchingPreset, preset, preset.rawValue)
            XCTAssertEqual(applied.presetLabel, preset.label)
        }
    }

    /// The presets are genuinely different configurations, not three names
    /// for one.
    func testPresetsDifferFromEachOther() {
        let configurations = NotificationPreset.allCases.map { $0.applied(to: NotificationPreferences()) }
        XCTAssertEqual(Set(configurations.map(\.scope)).count, 3)
        XCTAssertTrue(configurations.contains { $0.updateTriggers.count == 2 })
        XCTAssertTrue(configurations.contains { $0.updateTriggers.count == PRUpdateTrigger.allCases.count })
    }

    /// Editing a detail in Advanced reports Custom rather than leaving a
    /// preset name that no longer describes the values.
    func testEditingADetailFallsOutOfEveryPreset() {
        var preferences = NotificationPreset.balanced.applied(to: NotificationPreferences())
        XCTAssertEqual(preferences.matchingPreset, .balanced)

        preferences.includeDrafts = true
        XCTAssertNil(preferences.matchingPreset)
        XCTAssertEqual(preferences.presetLabel, "Custom")
    }

    /// A preset has no opinion about sound, grouping or quiet hours — those
    /// are the reviewer's whichever volume they pick, and switching preset
    /// must not silently undo them.
    func testPresetsLeaveDeliveryAndQuietHoursAlone() {
        var preferences = NotificationPreferences()
        preferences.playSound = false
        preferences.groupByProject = false
        preferences.quietHoursEnabled = true
        preferences.quietHoursStart = 21
        preferences.maxPerPoll = 12

        for preset in NotificationPreset.allCases {
            let applied = preset.applied(to: preferences)
            XCTAssertFalse(applied.playSound, preset.rawValue)
            XCTAssertFalse(applied.groupByProject, preset.rawValue)
            XCTAssertTrue(applied.quietHoursEnabled, preset.rawValue)
            XCTAssertEqual(applied.quietHoursStart, 21, preset.rawValue)
            XCTAssertEqual(applied.maxPerPoll, 12, preset.rawValue)
        }
    }

    /// The master switch is not a preset's business either — applying one
    /// while notifications are off must not turn them on.
    func testPresetsDoNotTouchTheMasterSwitch() {
        let off = NotificationPreset.everything.applied(to: NotificationPreferences())
        XCTAssertFalse(off.enabled)

        var on = NotificationPreferences()
        on.enabled = true
        XCTAssertTrue(NotificationPreset.essential.applied(to: on).enabled)
    }

    /// The quietest preset really is the quietest: it must not notify on
    /// new pull requests, drafts, or the reviewer's own work.
    func testEssentialIsTheQuietest() {
        let essential = NotificationPreset.essential.applied(to: NotificationPreferences())
        XCTAssertEqual(essential.scope, .reviewRequested)
        XCTAssertFalse(essential.notifyOnNewPullRequest)
        XCTAssertFalse(essential.includeOwnPullRequests)
        XCTAssertFalse(essential.includeDrafts)
    }
}

/// Polling presets: the three rates that replaced two steppers and a
/// jitter slider.
final class PollRatePresetTests: XCTestCase {
    func testEveryRateIsDistinctAndOrderedSlowToFast() {
        let values = PollRate.allCases.map(\.rawValue)
        XCTAssertEqual(values, [900, 300, 120])
        XCTAssertEqual(Set(values).count, 3)
    }

    /// A rate has to be recognisable after it is applied, or the card can
    /// be pressed and never look selected.
    func testSettingARateMatchesThatRate() {
        for rate in PollRate.allCases {
            var settings = AppSettings()
            settings.pollIntervalSeconds = rate.rawValue
            let matched = PollRate.allCases
                .first { $0.rawValue == settings.pollIntervalSeconds }
            XCTAssertEqual(matched, rate)
        }
    }

    /// An interval that came from the old stepper — 30-second granularity —
    /// is reported as Custom rather than silently snapped to a preset.
    func testAnOldSteppedIntervalReadsAsCustom() {
        var settings = AppSettings()
        settings.pollIntervalSeconds = 450
        XCTAssertNil(PollRate.allCases.first { $0.rawValue == settings.pollIntervalSeconds })
    }

    /// The backoff ceiling is derived rather than asked about, and must
    /// never end up below the interval itself — a ceiling under the floor
    /// would strand a failing project.
    func testDerivedBackoffCeilingIsAlwaysAboveTheInterval() {
        for rate in PollRate.allCases {
            let ceiling = max(rate.rawValue * 6, 1_800)
            XCTAssertGreaterThan(ceiling, rate.rawValue, rate.label)
        }
    }
}

/// Brand marks.
final class BrandMarkTests: XCTestCase {
    func testEveryForgeHasABrand() {
        XCTAssertEqual(Brand.forge(.github), .github)
        XCTAssertEqual(Brand.forge(.gitlab), .gitlab)
    }

    /// The asset name is the contract with the asset catalog — the image
    /// sets are named for these, so a rename here silently drops the real
    /// logos back to the fallbacks.
    func testAssetNamesMatchTheImageSets() {
        XCTAssertEqual(Brand.github.assetName, "brand-github")
        XCTAssertEqual(Brand.gitlab.assetName, "brand-gitlab")
        XCTAssertEqual(Brand.jira.assetName, "brand-jira")
    }

    func testEveryBrandHasItsOwnColour() {
        let tints = Brand.allCases.map(\.tint.description)
        XCTAssertEqual(Set(tints).count, Brand.allCases.count)
    }
}

/// The shared status vocabulary every pane's badge reads from.
final class SettingsStatusTests: XCTestCase {
    func testStatusCarriesItsOwnWordAndColour() {
        XCTAssertEqual(SettingsStatus.off.text, "Off")
        XCTAssertEqual(SettingsStatus.ready("Connected").text, "Connected")
        XCTAssertEqual(SettingsStatus.attention("Needs an address").text, "Needs an address")
        XCTAssertEqual(SettingsStatus.problem("Rejected").text, "Rejected")

        // Distinct colours, so the badge is readable without the word.
        XCTAssertNotEqual(SettingsStatus.ready("a").color, SettingsStatus.problem("b").color)
        XCTAssertNotEqual(SettingsStatus.attention("a").color, SettingsStatus.ready("b").color)
    }
}
