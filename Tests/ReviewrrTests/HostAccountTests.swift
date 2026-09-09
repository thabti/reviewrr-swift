import XCTest

/// The Account pane's host list. Pure, so the rules that decide what a
/// reviewer sees — which hosts, in what order, what each one says it has —
/// are checkable without a Keychain or a window.
final class HostAccountTests: XCTestCase {
    private func enterprise(_ host: String) -> ForgeHost {
        guard let candidate = ForgeHost.enterprise(host) else {
            fatalError("the fixture host \(host) should parse")
        }
        return candidate
    }

    private func gitlab(_ host: String) -> ForgeHost {
        guard let candidate = ForgeHost.gitlab(host) else {
            fatalError("the fixture host \(host) should parse")
        }
        return candidate
    }

    private func accounts(
        active: ForgeHost,
        known: [ForgeHost],
        credentials: [String: (token: String?, basic: BasicCredential?)] = [:]
    ) -> [HostAccount] {
        HostAccount.all(active: active, known: known) { host in
            credentials[host.identityKey] ?? (nil, nil)
        }
    }

    /// GitHub.com is always listed, even on a build that has only ever been
    /// pointed at an appliance: it is the default host and the fallback when
    /// another is removed.
    func testDotComIsAlwaysListedFirst() {
        let list = accounts(active: enterprise("github.acme.com"), known: [])
        XCTAssertEqual(list.first?.host.identityKey, ForgeHost.dotCom.identityKey)
        XCTAssertEqual(list.count, 2)
    }

    /// The host in use is never the one missing, even before it has been
    /// added to the known list.
    func testTheActiveHostIsListedEvenWhenNotYetKnown() {
        let appliance = enterprise("github.acme.com")
        let list = accounts(active: appliance, known: [])
        XCTAssertTrue(list.contains { $0.host.identityKey == appliance.identityKey })
        XCTAssertEqual(list.filter(\.isActive).count, 1)
        XCTAssertEqual(list.first(where: \.isActive)?.host.identityKey, appliance.identityKey)
    }

    func testHostsAreNotDuplicated() {
        let appliance = enterprise("github.acme.com")
        let list = accounts(active: appliance, known: [appliance, .dotCom, appliance])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.id)).count, 2)
    }

    /// Alphabetical after GitHub.com, so the list does not reorder itself as
    /// hosts are added and removed.
    func testAddedHostsAreSortedByName() {
        let list = accounts(
            active: .dotCom,
            known: [gitlab("z.example.com"), enterprise("a.example.com"), gitlab("m.example.com")]
        )
        XCTAssertEqual(list.first?.host.identityKey, ForgeHost.dotCom.identityKey)
        let names = list.dropFirst().map(\.host.displayName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    // MARK: - What a card says

    func testACardReportsTheTokenItHas() {
        let list = accounts(
            active: .dotCom,
            known: [],
            credentials: [ForgeHost.dotCom.identityKey: (token: "ghp_abcdefghijklmnop", basic: nil)]
        )
        let dotCom = try? XCTUnwrap(list.first)
        XCTAssertEqual(dotCom?.hasCredential, true)
        XCTAssertEqual(dotCom?.credentialSummary, GitHubCredentialMasking.mask("ghp_abcdefghijklmnop"))
    }

    func testACardReportsBasicOnItsOwn() {
        let appliance = enterprise("github.acme.com")
        let list = accounts(
            active: .dotCom,
            known: [appliance],
            credentials: [appliance.identityKey: (token: nil, basic: BasicCredential(username: "reviewer", password: "secret"))]
        )
        let card = list.first { $0.host.identityKey == appliance.identityKey }
        XCTAssertEqual(card?.hasCredential, true)
        XCTAssertEqual(card?.credentialSummary, "HTTP Basic as reviewer")
    }

    func testACardReportsBothWhenBothAreSaved() {
        let list = accounts(
            active: .dotCom,
            known: [],
            credentials: [
                ForgeHost.dotCom.identityKey: (
                    token: "ghp_abcdefghijklmnop",
                    basic: BasicCredential(username: "reviewer", password: "secret")
                )
            ]
        )
        XCTAssertEqual(
            list.first?.credentialSummary,
            "\(GitHubCredentialMasking.mask("ghp_abcdefghijklmnop")) · HTTP Basic as reviewer"
        )
    }

    func testAHostWithNothingSavedSaysSo() {
        let list = accounts(active: .dotCom, known: [])
        XCTAssertEqual(list.first?.hasCredential, false)
        XCTAssertEqual(list.first?.credentialSummary, "No credential saved")
    }

    // MARK: - What can be done to a card

    /// GitHub.com can be signed out of but never removed: a Reviewrr with no
    /// hosts has nowhere to put the next token.
    func testDotComIsNeverRemovable() {
        let list = accounts(active: .dotCom, known: [enterprise("github.acme.com")])
        XCTAssertEqual(list.first?.isRemovable, false)
        XCTAssertEqual(list.last?.isRemovable, true)
    }

    func testEachHostIsLabelledByWhatItIs() {
        let list = accounts(
            active: .dotCom,
            known: [enterprise("github.acme.com"), gitlab("git.internal.example")]
        )
        let labels = Dictionary(uniqueKeysWithValues: list.map { ($0.host.displayName, $0.kindLabel) })
        XCTAssertEqual(labels[ForgeHost.dotCom.displayName], "GitHub.com")
        XCTAssertEqual(labels["github.acme.com"], "GitHub Enterprise")
        XCTAssertEqual(labels["git.internal.example"], "GitLab (self-managed)")
    }
}
