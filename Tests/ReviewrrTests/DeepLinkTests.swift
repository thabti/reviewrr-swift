import XCTest

/// `reviewrr://owner/repo/number` — the link shape, and everything that
/// must not be mistaken for it.
final class DeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLink.parse(url)
    }

    private func reference(_ string: String) -> PRReference? {
        guard case .pullRequest(let reference)? = parse(string) else { return nil }
        return reference
    }

    // MARK: - The documented shape

    func testParsesTheCanonicalLink() {
        XCTAssertEqual(reference("reviewrr://acme/web-app/482"), PRReference(owner: "acme", repo: "web-app", number: 482))
    }

    func testSchemeIsCaseInsensitive() {
        // LaunchServices may hand back the scheme in any case.
        XCTAssertEqual(reference("REVIEWRR://acme/web-app/482")?.number, 482)
        XCTAssertEqual(reference("Reviewrr://acme/web-app/482")?.number, 482)
    }

    /// The owner arrives in the URL's authority component, which `URL.host`
    /// lowercases. Reviewrr keys drafts, viewed files, and the recent list on
    /// `owner/repo#number`, so a lowercased owner would split one pull
    /// request's local state in two.
    func testOwnerAndRepoKeepTheirCase() {
        let parsed = reference("reviewrr://Acme-Corp/Web-App/482")
        XCTAssertEqual(parsed?.owner, "Acme-Corp")
        XCTAssertEqual(parsed?.repo, "Web-App")
        XCTAssertEqual(parsed?.key, "Acme-Corp/Web-App#482")
    }

    func testAcceptsAGitHubStylePullPathAfterTheScheme() {
        XCTAssertEqual(reference("reviewrr://acme/web-app/pull/482"), PRReference(owner: "acme", repo: "web-app", number: 482))
        // …including when "pull" arrives in another case.
        XCTAssertEqual(reference("reviewrr://acme/web-app/PULL/482")?.number, 482)
    }

    func testIgnoresQueryAndFragment() {
        // Links pick these up passing through chat clients and trackers.
        XCTAssertEqual(reference("reviewrr://acme/web-app/482?utm_source=slack")?.number, 482)
        XCTAssertEqual(reference("reviewrr://acme/web-app/482#files")?.number, 482)
    }

    func testToleratesATrailingSlash() {
        XCTAssertEqual(reference("reviewrr://acme/web-app/482/")?.number, 482)
    }

    func testDecodesPercentEncodedSegments() {
        XCTAssertEqual(reference("reviewrr://acme/web%2Dapp/482")?.repo, "web-app")
        XCTAssertEqual(reference("reviewrr://my%2Eorg/repo.js/7")?.owner, "my.org")
    }

    // MARK: - What must be rejected

    func testRejectsOtherSchemes() {
        XCTAssertNil(parse("https://github.com/acme/web-app/pull/482"))
        XCTAssertNil(parse("reviewer://acme/web-app/482"), "a near-miss scheme is not this app's")
        XCTAssertNil(parse("reviewrrx://acme/web-app/482"))
    }

    func testRejectsTooFewOrTooManySegments() {
        XCTAssertNil(parse("reviewrr://acme/web-app"))
        XCTAssertNil(parse("reviewrr://acme"))
        XCTAssertNil(parse("reviewrr://"))
        XCTAssertNil(parse("reviewrr://acme/web-app/482/files"))
        XCTAssertNil(parse("reviewrr://acme/group/web-app/482"))
    }

    /// `Int("+482")` is 482 and `Int(" 5")` is nil but `Int("-3")` is -3 —
    /// so the number is checked as digits rather than handed to `Int` alone.
    func testRejectsNumbersThatAreNotPlainPositiveDigits() {
        XCTAssertNil(parse("reviewrr://acme/web-app/+482"))
        XCTAssertNil(parse("reviewrr://acme/web-app/-482"))
        XCTAssertNil(parse("reviewrr://acme/web-app/0"))
        XCTAssertNil(parse("reviewrr://acme/web-app/4.82"))
        XCTAssertNil(parse("reviewrr://acme/web-app/482a"))
        XCTAssertNil(parse("reviewrr://acme/web-app/latest"))
    }

    func testRejectsEmptyOwnerOrRepo() {
        XCTAssertNil(parse("reviewrr:///web-app/482"))
        XCTAssertNil(parse("reviewrr://acme//482"))
    }

    // MARK: - Generating links

    func testBuildsTheCanonicalLinkForAReference() {
        let url = DeepLink.url(for: PRReference(owner: "acme", repo: "web-app", number: 482))
        XCTAssertEqual(url?.absoluteString, "reviewrr://acme/web-app/482")
    }

    func testGeneratedLinkKeepsTheOwnersCase() {
        let url = PRReference(owner: "Acme-Corp", repo: "Web-App", number: 7).deepLinkURL
        XCTAssertEqual(url?.absoluteString, "reviewrr://Acme-Corp/Web-App/7")
    }

    /// The property that matters for sharing: a link Reviewrr produces is a
    /// link Reviewrr reads back as the same pull request.
    func testRoundTripsEveryReferenceShape() {
        let references = [
            PRReference(owner: "acme", repo: "web-app", number: 1),
            PRReference(owner: "Acme-Corp", repo: "Web.App", number: 482),
            PRReference(owner: "my.org", repo: "repo_name", number: 99_999),
            PRReference(owner: "a", repo: "b", number: 7),
        ]
        for reference in references {
            guard let url = DeepLink.url(for: reference) else {
                return XCTFail("no link for \(reference.key)")
            }
            XCTAssertEqual(DeepLink.parse(url), .pullRequest(reference), "round trip failed for \(url)")
        }
    }

    func testMalformedMessageNamesTheShapeThatWorks() {
        // The usual cause of a bad link is one built by hand, so the message
        // has to carry the answer.
        XCTAssertTrue(DeepLink.malformedMessage.contains("reviewrr://owner/repo/number"))
    }
}
