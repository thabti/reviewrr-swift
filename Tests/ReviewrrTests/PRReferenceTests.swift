import XCTest

final class PRReferenceTests: XCTestCase {
    func testParsesFullURL() {
        let ref = PRReference.parse("https://github.com/acme/web-app/pull/482")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testParsesShorthand() {
        let ref = PRReference.parse("acme/web-app#482")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testTrimsWhitespace() {
        let ref = PRReference.parse("  acme/web-app#482  \n")
        XCTAssertEqual(ref?.number, 482)
    }

    func testParsesURLWithTrailingSlash() {
        let ref = PRReference.parse("https://github.com/acme/web-app/pull/482/")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testParsesFilesSuffix() {
        let ref = PRReference.parse("https://github.com/acme/web-app/pull/482/files")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testParsesDiffSuffix() {
        let ref = PRReference.parse("https://github.com/acme/web-app/pull/482.diff")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testParsesPatchSuffix() {
        let ref = PRReference.parse("https://github.com/acme/web-app/pull/482.patch")
        XCTAssertEqual(ref?.owner, "acme")
        XCTAssertEqual(ref?.repo, "web-app")
        XCTAssertEqual(ref?.number, 482)
    }

    func testRejectsGarbage() {
        XCTAssertNil(PRReference.parse(""))
        XCTAssertNil(PRReference.parse("not a pr"))
        XCTAssertNil(PRReference.parse("acme/web-app#not-a-number"))
        XCTAssertNil(PRReference.parse("https://github.com/acme/web-app/issues/482"))
        XCTAssertNil(PRReference.parse("https://gitlab.com/acme/web-app/pull/482"))
    }

    /// `key` is forge-neutral and stays on the reference — it identifies a
    /// change to the draft store and the recent list, not to a server.
    ///
    /// The API path moved to the clients: it used to live here as
    /// `apiPath`, hardcoded to GitHub's `/repos/…/pulls/…`, which put one
    /// forge's URL grammar on a model both forges share. See
    /// `ForgeAbstractionTests.testReferenceCarriesNoForgeSpecificPath`.
    func testKeyIsForgeNeutral() {
        let ref = PRReference(owner: "acme", repo: "web-app", number: 482)
        XCTAssertEqual(ref.key, "acme/web-app#482")
    }
}
