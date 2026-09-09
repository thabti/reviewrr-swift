import XCTest

/// Host parsing for both forges, and the shapes that must not be confused.
final class ForgeHostTests: XCTestCase {
    func testGitLabParsesBareHostnameAsHTTPS() {
        let host = ForgeHost.gitlab("git.internal.example")
        XCTAssertEqual(host?.forge, .gitlab)
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://git.internal.example/api/v4"))
        XCTAssertEqual(host?.webBaseURL, URL(string: "https://git.internal.example"))
        XCTAssertEqual(host?.graphQLURL, URL(string: "https://git.internal.example/api/graphql"))
    }

    /// The subdirectory install, and the difference from GitHub Enterprise:
    /// a GitLab path is kept, because GitLab is commonly mounted under a
    /// path on an existing domain and dropping it would address a host with
    /// no GitLab on it.
    func testGitLabKeepsASubdirectoryPath() {
        let host = ForgeHost.gitlab("https://internal.example/gitlab")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://internal.example/gitlab/api/v4"))
        XCTAssertEqual(host?.webBaseURL, URL(string: "https://internal.example/gitlab"))
        XCTAssertEqual(host?.displayName, "internal.example/gitlab")
    }

    func testEnterpriseStillDiscardsItsPath() {
        let host = ForgeHost.enterprise("https://github.mycorp.com/some/path")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://github.mycorp.com/api/v3"))
        XCTAssertEqual(host?.forge, .github)
    }

    func testGitLabKeepsANonStandardPort() {
        let host = ForgeHost.gitlab("git.internal.example:8443")
        XCTAssertEqual(host?.apiBaseURL, URL(string: "https://git.internal.example:8443/api/v4"))
    }

    /// Plain HTTP has to be asked for: a credential sent in clear text
    /// should be a decision, not what a bare hostname silently does.
    func testExplicitHTTPIsHonouredAndNeverInferred() {
        XCTAssertEqual(
            ForgeHost.gitlab("http://git.internal.example")?.apiBaseURL,
            URL(string: "http://git.internal.example/api/v4")
        )
        XCTAssertEqual(ForgeHost.gitlab("git.internal.example")?.apiBaseURL.scheme, "https")
    }

    func testGitLabTrimsTrailingSlashes() {
        XCTAssertEqual(
            ForgeHost.gitlab("https://internal.example/gitlab/")?.apiBaseURL,
            URL(string: "https://internal.example/gitlab/api/v4")
        )
    }

    func testRejectsGarbageAndUnsupportedSchemes() {
        XCTAssertNil(ForgeHost.gitlab(""))
        XCTAssertNil(ForgeHost.gitlab("   "))
        XCTAssertNil(ForgeHost.gitlab("not a host at all"))
        XCTAssertNil(ForgeHost.gitlab("ftp://git.internal.example"))
    }

    /// The cache-key bug this replaced: `String.hashValue` is seeded per
    /// process, so a filename built from it changed on every launch — the
    /// inbox cache never hit once and leaked a file per run. This value has
    /// to be a pure function of the host.
    func testIdentityKeyIsStableAndDistinguishesHosts() {
        let a = ForgeHost.gitlab("git.internal.example")!
        let b = ForgeHost.gitlab("git.internal.example")!
        let other = ForgeHost.gitlab("git.other.example")!

        XCTAssertEqual(a.identityKey, b.identityKey)
        XCTAssertNotEqual(a.identityKey, other.identityKey)
        XCTAssertNotEqual(a.identityKey, ForgeHost.dotCom.identityKey)
        XCTAssertTrue(a.identityKey.hasPrefix("gitlab-"))
        XCTAssertTrue(ForgeHost.dotCom.identityKey.hasPrefix("github-"))
        // Filesystem- and Keychain-safe: it names a file and a Keychain
        // account.
        XCTAssertNil(a.identityKey.rangeOfCharacter(from: CharacterSet.alphanumerics.union(["-"]).inverted))
    }

    func testWebURLUsesEachForgesOwnPathShape() {
        XCTAssertEqual(
            ForgeHost.dotCom.webURL(owner: "acme", repo: "web", number: 7)?.absoluteString,
            "https://github.com/acme/web/pull/7"
        )
        XCTAssertEqual(
            ForgeHost.gitlab("git.example")!.webURL(owner: "group/sub", repo: "proj", number: 7)?.absoluteString,
            "https://git.example/group/sub/proj/-/merge_requests/7"
        )
    }

    /// A host blob written before GitLab support has no `forge` key and
    /// must decode as GitHub rather than failing — the same tolerance the
    /// rest of the settings blob has.
    func testDecodesAHostWrittenBeforeForgeExisted() throws {
        let json = """
        {"displayName": "GitHub.com", "apiBaseURL": "https://api.github.com",
         "webBaseURL": "https://github.com", "graphQLURL": "https://api.github.com/graphql"}
        """
        let host = try JSONDecoder().decode(ForgeHost.self, from: Data(json.utf8))
        XCTAssertEqual(host.forge, .github)
        XCTAssertTrue(host.isDotCom)
    }
}

/// The credential model, and the one place the two parts collide.
final class ForgeCredentialTests: XCTestCase {
    func testBasicHeaderIsRFC7617Base64() {
        let basic = BasicCredential(username: "aladdin", password: "opensesame")
        // The RFC's own example vector.
        XCTAssertEqual(basic.headerValue, "Basic YWxhZGRpbjpvcGVuc2VzYW1l")
    }

    func testBasicHeaderEncodesNonASCIIAsUTF8() {
        let basic = BasicCredential(username: "user", password: "pässwörd")
        let encoded = String(basic.headerValue.dropFirst("Basic ".count))
        let decoded = String(data: Data(base64Encoded: encoded)!, encoding: .utf8)
        XCTAssertEqual(decoded, "user:pässwörd")
    }

    func testMaskedDescriptionNeverContainsThePassword() {
        let basic = BasicCredential(username: "deploy", password: "hunter2-very-secret")
        XCTAssertFalse(basic.maskedDescription.contains("hunter2"))
        XCTAssertTrue(basic.maskedDescription.contains("deploy"))
    }

    func testCredentialTrimsAndNormalizesEmptyParts() {
        XCTAssertFalse(ForgeCredential(token: "   ").hasToken)
        XCTAssertEqual(ForgeCredential(token: "  glpat-abc  ").token, "glpat-abc")
        XCTAssertFalse(ForgeCredential(basic: BasicCredential(username: " ", password: "")).hasBasic)
        XCTAssertTrue(ForgeCredential(token: nil, basic: nil).isEmpty)
    }

    /// GitLab keeps its token in `PRIVATE-TOKEN`, so Basic and the token
    /// both travel. This is the whole reason a proxied GitLab can work.
    func testGitLabSendsBothPartsOnOneRequest() {
        let credential = ForgeCredential(
            token: "glpat-xyz", basic: BasicCredential(username: "u", password: "p")
        )
        let headers = credential.headers(for: .gitlab)
        XCTAssertEqual(headers.first { $0.name == "PRIVATE-TOKEN" }?.value, "glpat-xyz")
        XCTAssertEqual(headers.first { $0.name == "Authorization" }?.value, credential.basic?.headerValue)
        XCTAssertTrue(credential.basicIsSent(for: .gitlab))
    }

    /// GitHub has no token header, so both want `Authorization` and only
    /// one can win. The token wins, because it is what GitHub itself
    /// checks — and the UI is told the Basic part is not being sent.
    func testGitHubTokenDisplacesBasicAndSaysSo() {
        let credential = ForgeCredential(
            token: "ghp_xyz", basic: BasicCredential(username: "u", password: "p")
        )
        let headers = credential.headers(for: .github)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?.value, "Bearer ghp_xyz")
        XCTAssertFalse(credential.basicIsSent(for: .github))
    }

    func testGitHubFallsBackToBasicWhenThereIsNoToken() {
        let credential = ForgeCredential(basic: BasicCredential(username: "u", password: "p"))
        XCTAssertEqual(credential.headers(for: .github).first?.name, "Authorization")
        XCTAssertTrue(credential.headers(for: .github).first?.value.hasPrefix("Basic ") ?? false)
        XCTAssertTrue(credential.basicIsSent(for: .github))
    }

    func testNoCredentialSendsNoAuthHeaders() {
        XCTAssertTrue(ForgeCredential.none.headers(for: .github).isEmpty)
        XCTAssertTrue(ForgeCredential.none.headers(for: .gitlab).isEmpty)
    }

    /// github.com keeps the account name it always had, so an existing
    /// install is not silently signed out by the move to per-host storage.
    func testDotComKeepsItsLegacyKeychainAccount() {
        XCTAssertEqual(
            ForgeCredentialStore.tokenAccount(for: .dotCom),
            ForgeCredentialStore.legacyGitHubTokenAccount
        )
        let gitlab = ForgeHost.gitlab("git.example")!
        XCTAssertNotEqual(ForgeCredentialStore.tokenAccount(for: gitlab), ForgeCredentialStore.legacyGitHubTokenAccount)
        XCTAssertNotEqual(
            ForgeCredentialStore.tokenAccount(for: gitlab),
            ForgeCredentialStore.basicAccount(for: gitlab)
        )
    }
}

/// GitLab's URL and error shapes.
final class GitLabAPITests: XCTestCase {
    private let host = ForgeHost.gitlab("git.internal.example")!

    /// GitLab addresses a project by its full path encoded into one
    /// segment. The slash *must* become %2F, or the request addresses a
    /// path that does not exist.
    func testProjectPathEncodesNestedGroupsIntoOneSegment() {
        XCTAssertEqual(
            GitLabAPI.encodedProjectPath(owner: "platform/backend", repo: "api-gateway"),
            "platform%2Fbackend%2Fapi-gateway"
        )
        XCTAssertEqual(GitLabAPI.encodedProjectPath(owner: "acme", repo: "web"), "acme%2Fweb")
    }

    func testMergeRequestPathUsesTheEncodedProject() {
        let api = GitLabAPI(host: host)
        let reference = PRReference(owner: "platform/backend", repo: "api-gateway", number: 482)
        XCTAssertEqual(api.mergeRequestPath(reference), "/projects/platform%2Fbackend%2Fapi-gateway/merge_requests/482")
    }

    /// The bug this guards: `appendingPathComponent` re-encodes the %2F
    /// into %252F, which addresses a project literally named "a/b".
    func testRequestURLDoesNotDoubleEncodeTheProjectPath() throws {
        let api = GitLabAPI(host: host)
        let reference = PRReference(owner: "platform/backend", repo: "api-gateway", number: 7)
        let request = try api.makeRequest(path: api.mergeRequestPath(reference), token: "glpat-x")
        let url = request.url!.absoluteString
        XCTAssertTrue(url.contains("platform%2Fbackend%2Fapi-gateway"), url)
        XCTAssertFalse(url.contains("%252F"), url)
    }

    func testRequestCarriesTokenInPrivateTokenAndBasicInAuthorization() throws {
        let api = GitLabAPI(host: host, basic: BasicCredential(username: "u", password: "p"))
        let request = try api.makeRequest(path: "/user", token: "glpat-x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "glpat-x")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") ?? false)
    }

    func testQueryItemsSurviveOnAnEncodedPath() throws {
        let api = GitLabAPI(host: host)
        let request = try api.makeRequest(
            path: "/projects/a%2Fb/repository/files/src%2Fmain.swift",
            token: nil,
            query: [URLQueryItem(name: "ref", value: "main")]
        )
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("?ref=main"))
    }

    /// GitLab reports an error as a string `message`, a string `error`, or a
    /// keyed object of field errors. All three have to reach the reviewer.
    func testErrorMessageIsReadFromEveryShapeGitLabUses() {
        XCTAssertEqual(GitLabAPI.message(from: Data(#"{"message":"404 Not found"}"#.utf8)), "404 Not found")
        XCTAssertEqual(GitLabAPI.message(from: Data(#"{"error":"insufficient_scope"}"#.utf8)), "insufficient_scope")
        XCTAssertEqual(
            GitLabAPI.message(from: Data(#"{"message":{"base":["Note can't be blank"]}}"#.utf8)),
            "base: Note can't be blank"
        )
        XCTAssertNil(GitLabAPI.message(from: Data("not json".utf8)))
    }

    /// A 500 says nothing actionable unless it says *which* call produced
    /// it — opening a merge request fans out to six.
    func testServerErrorNamesTheEndpointAndBlamesTheInstance() {
        let message = GitLabError.serverError(
            status: 500,
            endpoint: "GET /api/v4/projects/a%2Fb/merge_requests/7/diffs",
            detail: "500 Internal Server Error"
        ).errorDescription ?? ""

        XCTAssertTrue(message.contains("merge_requests/7/diffs"), message)
        XCTAssertTrue(message.contains("HTTP 500"))
        // The point of the wording: a 5xx is not fixed by a different token
        // or URL, and saying so stops the reviewer re-checking their token.
        XCTAssertTrue(message.contains("instance failed on its own side"))
        XCTAssertFalse(message.contains("scope"), "a 5xx is not a permissions problem")
    }

    /// A private CA nobody installed is *the* self-hosted failure, and its
    /// fix is in Keychain Access — not in the token or the URL — so it must
    /// not be reported as a generic network error.
    func testTLSTrustFailuresAreToldApartFromOtherNetworkErrors() {
        XCTAssertTrue(GitLabAPI.isTLSTrustFailure(URLError(.serverCertificateUntrusted)))
        XCTAssertTrue(GitLabAPI.isTLSTrustFailure(URLError(.serverCertificateHasUnknownRoot)))
        XCTAssertTrue(GitLabAPI.isTLSTrustFailure(URLError(.secureConnectionFailed)))
        XCTAssertFalse(GitLabAPI.isTLSTrustFailure(URLError(.timedOut)))
        XCTAssertFalse(GitLabAPI.isTLSTrustFailure(URLError(.cannotFindHost)))
    }

    func testTLSErrorNamesTheHostAndTheRemedy() {
        let message = GitLabError.tlsUntrusted(host: "git.internal.example").errorDescription ?? ""
        XCTAssertTrue(message.contains("git.internal.example"))
        XCTAssertTrue(message.contains("Keychain Access"))
        XCTAssertTrue(message.contains("not skip certificate validation"))
    }

    /// A 401 with Basic but no token is the predictable outcome of a
    /// Basic-only setup, because GitLab's API does not accept Basic. The
    /// message has to say that rather than blame the token.
    func testBasicOnlyUnauthorizedExplainsGitLabDoesNotAcceptBasic() {
        let message = GitLabError.unauthorized(sentBasic: true).errorDescription ?? ""
        XCTAssertTrue(message.contains("does not accept Basic auth"))
        let tokenMessage = GitLabError.unauthorized(sentBasic: false).errorDescription ?? ""
        XCTAssertTrue(tokenMessage.contains("invalid or expired"))
    }

    func testForbiddenNamesTheScopeThatIsMissing() {
        let message = GitLabError.forbidden("insufficient scope").errorDescription ?? ""
        XCTAssertTrue(message.contains("\"api\" scope"))
        XCTAssertTrue(message.contains("read_api"))
    }
}

/// GitLab's payloads, translated onto the app's GitHub-shaped models.
final class GitLabMapperTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try GitLabAPI.decoder.decode(type, from: Data(json.utf8))
    }

    private let mergeRequestJSON = """
    {
      "id": 9001, "iid": 482, "title": "Add rate limiting",
      "description": "Adds a token bucket.",
      "state": "opened", "draft": false,
      "author": {"id": 5, "username": "alice", "name": "Alice", "avatar_url": "https://a/avatar.png", "web_url": "https://git/alice"},
      "created_at": "2026-01-02T03:04:05.000Z",
      "updated_at": "2026-01-03T03:04:05Z",
      "merged_at": null, "closed_at": null,
      "web_url": "https://git.internal.example/platform/api/-/merge_requests/482",
      "labels": ["backend", "urgent"],
      "sha": "deadbeef",
      "diff_refs": {"base_sha": "base1", "head_sha": "head1", "start_sha": "start1"},
      "source_branch": "alice/rate-limit", "target_branch": "main",
      "changes_count": "3", "user_notes_count": 4,
      "detailed_merge_status": "mergeable", "has_conflicts": false,
      "reviewers": [{"id": 6, "username": "bob", "name": "Bob", "avatar_url": null, "web_url": null}],
      "assignees": []
    }
    """

    func testMapsAMergeRequestOntoPullRequest() throws {
        let mr = try decode(GLMergeRequest.self, mergeRequestJSON)
        let pr = GitLabMapper.pullRequest(mr)

        XCTAssertEqual(pr.number, 482, "the iid is the number a reviewer types, not the global id")
        XCTAssertEqual(pr.id, 9001)
        XCTAssertEqual(pr.title, "Add rate limiting")
        XCTAssertEqual(pr.state, .open)
        XCTAssertFalse(pr.draft)
        XCTAssertEqual(pr.user.login, "alice")
        XCTAssertEqual(pr.headRef, "alice/rate-limit")
        XCTAssertEqual(pr.headSha, "head1", "the diff ref, not the MR's sha field")
        XCTAssertEqual(pr.baseRef, "main")
        XCTAssertEqual(pr.mergeable, true, "derived from has_conflicts, GitLab's only true equivalent")
        XCTAssertEqual(pr.labels.map(\.name), ["backend", "urgent"])
        XCTAssertEqual(pr.requestedReviewers?.map(\.login), ["bob"])
        XCTAssertEqual(pr.comments, 4)
    }

    func testMergedAndClosedStatesMapOntoTwoStates() throws {
        for (state, expected) in [("opened", PRState.open), ("closed", .closed), ("merged", .closed), ("locked", .closed)] {
            let mr = try decode(GLMergeRequest.self, mergeRequestJSON.replacingOccurrences(of: "\"state\": \"opened\"", with: "\"state\": \"\(state)\""))
            XCTAssertEqual(GitLabMapper.pullRequest(mr).state, expected, state)
            XCTAssertEqual(GitLabMapper.pullRequest(mr).merged, state == "merged", state)
        }
    }

    /// `work_in_progress` is what `draft` was called before GitLab 14, and
    /// a self-managed instance may be that old.
    func testFallsBackToWorkInProgressForDraft() throws {
        let json = mergeRequestJSON.replacingOccurrences(of: "\"draft\": false", with: "\"work_in_progress\": true")
        XCTAssertTrue(GitLabMapper.pullRequest(try decode(GLMergeRequest.self, json)).draft)
    }

    /// GitLab caps the count it will compute and reports "3+"; the digits
    /// are a floor, not a total, and must still parse.
    func testChangesCountParsesGitLabsCappedForm() {
        XCTAssertEqual(GitLabMapper.parseChangesCount("3"), 3)
        XCTAssertEqual(GitLabMapper.parseChangesCount("1000+"), 1000)
        XCTAssertNil(GitLabMapper.parseChangesCount(nil))
        XCTAssertNil(GitLabMapper.parseChangesCount("many"))
    }

    /// GitLab sends no line counts at all, so they are counted from the
    /// patch — and the `+++`/`---` headers must not be counted as content.
    func testCountsLinesFromThePatchAndSkipsFileHeaders() {
        let patch = """
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,3 +1,4 @@
         context
        -removed
        +added one
        +added two
        """
        let counts = GitLabMapper.lineCounts(in: patch)
        XCTAssertEqual(counts.additions, 2)
        XCTAssertEqual(counts.deletions, 1)
        let empty = GitLabMapper.lineCounts(in: nil)
        XCTAssertEqual(empty.additions, 0)
        XCTAssertEqual(empty.deletions, 0)
    }

    func testFileStatusFromGitLabsBooleanFlags() throws {
        func file(_ extra: String) throws -> PRFile {
            let json = """
            {"old_path": "a.swift", "new_path": "b.swift", "new_file": false,
             "renamed_file": false, "deleted_file": false, "diff": "@@ -1 +1 @@\\n+x\\n"\(extra)}
            """
            return GitLabMapper.file(from: try decode(GLDiff.self, json))
        }
        XCTAssertEqual(try file("").status, .modified)
        XCTAssertEqual(try file(", \"new_file\": true").status, .modified, "later keys do not override earlier duplicates")

        let added = GitLabMapper.file(from: try decode(GLDiff.self, """
        {"old_path": "a", "new_path": "a", "new_file": true, "renamed_file": false, "deleted_file": false, "diff": "+x"}
        """))
        XCTAssertEqual(added.status, .added)

        let renamed = GitLabMapper.file(from: try decode(GLDiff.self, """
        {"old_path": "old.swift", "new_path": "new.swift", "new_file": false, "renamed_file": true, "deleted_file": false, "diff": ""}
        """))
        XCTAssertEqual(renamed.status, .renamed)
        XCTAssertEqual(renamed.previousFilename, "old.swift")
        XCTAssertEqual(renamed.filename, "new.swift")
    }

    func testBinaryDiffHasNoPatchLikeGitHubs() throws {
        let file = GitLabMapper.file(from: try decode(GLDiff.self, """
        {"old_path": "logo.png", "new_path": "logo.png", "new_file": false, "renamed_file": false, "deleted_file": false, "diff": null}
        """))
        XCTAssertTrue(file.isBinaryOrTooLarge)
        XCTAssertEqual(file.additions, 0)
    }

    /// A label id has to be stable across launches: `hashValue` is seeded
    /// per process, which would make SwiftUI treat every label as new on
    /// every launch.
    func testLabelIDsAreStableAcrossProcesses() {
        let a = GitLabMapper.label(GLLabelStub("backend"))
        XCTAssertEqual(a.id, GitLabMapper.label(GLLabelStub("backend")).id)
        XCTAssertNotEqual(a.id, GitLabMapper.label(GLLabelStub("frontend")).id)
        XCTAssertGreaterThan(a.id, 0)
        // Same string, same digest, every run — asserted against a literal
        // so a change in the hash is caught rather than silently churning
        // every stored label id.
        XCTAssertEqual(GitLabMapper.fnv1a("backend"), GitLabMapper.fnv1a("backend"))
    }

    private func GLLabelStub(_ name: String) -> GLLabel {
        try! decode(GLLabel.self, "\"\(name)\"")
    }

    func testLabelDecodesBothTheStringAndDetailedShapes() throws {
        XCTAssertEqual(try decode(GLLabel.self, "\"urgent\"").name, "urgent")
        // `##"…"##`: the payload contains `"#`, which would end a `#"…"#`
        // raw string early.
        let detailed = try decode(GLLabel.self, ##"{"name":"urgent","color":"#ff0000"}"##)
        XCTAssertEqual(detailed.name, "urgent")
        XCTAssertEqual(GitLabMapper.label(detailed).color, "ff0000", "the # is stripped for the UI's hex parser")
    }

    // MARK: Discussions

    private let discussionsJSON = """
    [
      {
        "id": "abc123def", "individual_note": false,
        "notes": [
          {"id": 101, "body": "This needs a guard.", "system": false, "resolvable": true, "resolved": false,
           "created_at": "2026-01-02T10:00:00.000Z",
           "author": {"id": 5, "username": "alice", "name": null, "avatar_url": null, "web_url": null},
           "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "src/a.swift",
                        "new_path": "src/a.swift", "position_type": "text", "old_line": null, "new_line": 42}},
          {"id": 102, "body": "Agreed.", "system": false, "resolvable": true, "resolved": false,
           "created_at": "2026-01-02T11:00:00.000Z",
           "author": {"id": 6, "username": "bob", "name": null, "avatar_url": null, "web_url": null},
           "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "src/a.swift",
                        "new_path": "src/a.swift", "position_type": "text", "old_line": null, "new_line": 42}}
        ]
      },
      {
        "id": "resolved1", "individual_note": false,
        "notes": [
          {"id": 200, "body": "Fixed.", "system": false, "resolvable": true, "resolved": true,
           "created_at": "2026-01-02T12:00:00.000Z",
           "author": {"id": 5, "username": "alice", "name": null, "avatar_url": null, "web_url": null},
           "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "src/b.swift",
                        "new_path": "src/b.swift", "position_type": "text", "old_line": 7, "new_line": null}}
        ]
      },
      {
        "id": "toplevel1", "individual_note": true,
        "notes": [
          {"id": 300, "body": "Looks good overall.", "system": false,
           "created_at": "2026-01-02T13:00:00.000Z",
           "author": {"id": 6, "username": "bob", "name": null, "avatar_url": null, "web_url": null},
           "position": null}
        ]
      },
      {
        "id": "system1", "individual_note": true,
        "notes": [
          {"id": 400, "body": "changed the description", "system": true,
           "created_at": "2026-01-02T14:00:00.000Z",
           "author": {"id": 5, "username": "alice", "name": null, "avatar_url": null, "web_url": null},
           "position": null}
        ]
      }
    ]
    """

    private func discussions() throws -> [GLDiscussion] {
        try decode([GLDiscussion].self, discussionsJSON)
    }

    func testDiffAnchoredNotesBecomeReviewCommentsWithTheRightSide() throws {
        let comments = GitLabMapper.reviewComments(from: try discussions(), mergeRequestURL: "https://git/mr/1")
        XCTAssertEqual(comments.count, 3, "two in one thread, one resolved thread; top-level and system excluded")

        let right = comments.first { $0.id == 101 }
        XCTAssertEqual(right?.side, .right)
        XCTAssertEqual(right?.line, 42)
        XCTAssertEqual(right?.path, "src/a.swift")
        XCTAssertEqual(right?.htmlUrl, "https://git/mr/1#note_101")

        let left = comments.first { $0.id == 200 }
        XCTAssertEqual(left?.side, .left, "old_line only means the left-hand side")
        XCTAssertEqual(left?.line, 7)
    }

    /// The join that let GitLab reuse the workspace unchanged: replies are
    /// given the root note's id, so the app's own `groupedIntoThreads()`
    /// rebuilds GitLab's discussions.
    func testRepliesPointAtTheirDiscussionRootSoExistingGroupingWorks() throws {
        let comments = GitLabMapper.reviewComments(from: try discussions(), mergeRequestURL: "https://git/mr/1")
        XCTAssertNil(comments.first { $0.id == 101 }?.inReplyToId)
        XCTAssertEqual(comments.first { $0.id == 102 }?.inReplyToId, 101)

        let threads = comments.groupedIntoThreads()
        XCTAssertEqual(threads.count, 2)
        let thread = threads.first { $0.rootId == 101 }
        XCTAssertEqual(thread?.comments.map(\.id), [101, 102])
    }

    func testTopLevelNotesBecomeIssueCommentsAndSystemNotesAreDropped() throws {
        let comments = GitLabMapper.issueComments(from: try discussions(), mergeRequestURL: "https://git/mr/1")
        XCTAssertEqual(comments.map(\.id), [300], "system activity is never rendered as somebody's remark")
        XCTAssertEqual(comments.first?.user.login, "bob")
    }

    func testThreadStatesCarryResolutionAndTheDiscussionID() throws {
        let states = GitLabMapper.threadStates(from: try discussions())
        XCTAssertEqual(states.count, 2)

        let open = states.first { $0.nodeId == "abc123def" }
        XCTAssertEqual(open?.isResolved, false)
        XCTAssertEqual(open?.commentDatabaseIds, [101, 102], "matched to threads by comment id, like the GitHub path")

        let resolved = states.first { $0.nodeId == "resolved1" }
        XCTAssertEqual(resolved?.isResolved, true)
        XCTAssertNil(resolved?.resolvedByLogin, "GitLab does not say who resolved a discussion")
    }

    /// Reusing `ThreadsClient.merge` is the point of producing `ThreadState`
    /// at all — this is the assertion that GitLab data flows through the
    /// existing conversation pipeline.
    func testGitLabStatesMergeThroughTheExistingConversationPipeline() throws {
        let discussions = try self.discussions()
        let threads = GitLabMapper.reviewComments(from: discussions, mergeRequestURL: "https://git/mr/1")
            .groupedIntoThreads()
        let (merged, nodeIds) = ThreadsClient.merge(
            restThreads: threads, states: GitLabMapper.threadStates(from: discussions)
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(nodeIds[101], "abc123def", "the resolve call gets GitLab's discussion id back")
        XCTAssertEqual(merged.first { $0.rootId == 200 }?.isResolved, true)
        XCTAssertEqual(merged.first { $0.rootId == 101 }?.isResolved, false)
    }

    func testOutdatedNoteHasNoLineOnEitherSide() throws {
        let json = """
        [{"id": "d1", "individual_note": false, "notes": [
          {"id": 1, "body": "stale", "system": false, "created_at": "2026-01-02T10:00:00.000Z",
           "author": {"id": 1, "username": "a", "name": null, "avatar_url": null, "web_url": null},
           "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "f", "new_path": "f",
                        "position_type": "text", "old_line": null, "new_line": null}}]}]
        """
        let states = GitLabMapper.threadStates(from: try decode([GLDiscussion].self, json))
        XCTAssertEqual(states.first?.isOutdated, true)
    }

    /// An image or file discussion is not a line comment and must not be
    /// placed on the diff as though it were.
    func testNonTextPositionsAreNotMappedAsLineComments() throws {
        let json = """
        [{"id": "d1", "individual_note": false, "notes": [
          {"id": 1, "body": "on the image", "system": false, "created_at": "2026-01-02T10:00:00.000Z",
           "author": {"id": 1, "username": "a", "name": null, "avatar_url": null, "web_url": null},
           "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "a.png",
                        "new_path": "a.png", "position_type": "image", "old_line": null, "new_line": null}}]}]
        """
        let comments = GitLabMapper.reviewComments(from: try decode([GLDiscussion].self, json), mergeRequestURL: "u")
        XCTAssertTrue(comments.isEmpty)
    }

    // MARK: Approvals

    func testApprovalsBecomeApprovedReviews() throws {
        let approvals = try decode(GLApprovals.self, """
        {"approvals_required": 2, "approvals_left": 1, "approved": false,
         "approved_by": [{"user": {"id": 5, "username": "alice", "name": null, "avatar_url": null, "web_url": "https://git/alice"}}]}
        """)
        let reviews = GitLabMapper.reviews(from: approvals)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.first?.state, .approved)
        XCTAssertEqual(reviews.first?.user.login, "alice")
        XCTAssertNil(reviews.first?.submittedAt, "GitLab carries no per-approver timestamp; nil beats redating it")
    }

    func testNoApprovalsMeansNoReviewsRatherThanARejection() throws {
        let approvals = try decode(GLApprovals.self, #"{"approvals_required": 1, "approvals_left": 1, "approved_by": []}"#)
        XCTAssertTrue(GitLabMapper.reviews(from: approvals).isEmpty)
    }

    // MARK: CI

    func testPipelineStatusesMapOntoTheAppsThreeStateLifecycle() {
        for raw in ["created", "waiting_for_resource", "preparing", "pending", "scheduled"] {
            XCTAssertEqual(GitLabMapper.checkStatus(for: raw), .queued, raw)
        }
        XCTAssertEqual(GitLabMapper.checkStatus(for: "running"), .inProgress)
        for raw in ["success", "failed", "canceled", "skipped", "manual"] {
            XCTAssertEqual(GitLabMapper.checkStatus(for: raw), .completed, raw)
        }
    }

    func testJobConclusions() {
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "success", allowFailure: false), .success)
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "failed", allowFailure: false), .failure)
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "canceled", allowFailure: false), .cancelled)
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "skipped", allowFailure: false), .skipped)
        // A manual job is waiting for a person, not still running — a
        // pipeline finished except for a manual deploy must not read as
        // in progress forever.
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "manual", allowFailure: false), .actionRequired)
    }

    /// An `allow_failure` job is advisory. Reporting it as a failure would
    /// make a green pipeline look broken.
    func testAllowedFailureIsNeutralNotFailing() {
        XCTAssertEqual(GitLabMapper.checkConclusion(for: "failed", allowFailure: true), .neutral)
        XCTAssertFalse(CheckConclusion.neutral.isFailing)
        XCTAssertTrue(CheckConclusion.failure.isFailing)
    }

    func testJobBecomesACheckRunNamespacedByPipeline() throws {
        let job = try decode(GLJob.self, """
        {"id": 77, "name": "rspec", "stage": "test", "status": "failed",
         "started_at": "2026-01-02T10:00:00.000Z", "finished_at": "2026-01-02T10:05:00.000Z",
         "web_url": "https://git/-/jobs/77", "allow_failure": false}
        """)
        let run = GitLabMapper.checkRun(from: job, pipelineID: 9)
        XCTAssertEqual(run.id, "gitlab-job-9-77", "namespaced so a re-run pipeline cannot collide")
        XCTAssertEqual(run.name, "rspec")
        XCTAssertEqual(run.appName, "test")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.conclusion, .failure)
        XCTAssertTrue(run.isFailing)
        XCTAssertEqual(run.duration, 300)
    }

    func testPipelineFallbackRunWhenJobsCannotBeRead() throws {
        let pipeline = try decode(GLPipeline.self, """
        {"id": 9, "sha": "abc", "ref": "main", "status": "running",
         "web_url": "https://git/-/pipelines/9", "created_at": "2026-01-02T10:00:00.000Z"}
        """)
        let run = GitLabMapper.checkRun(from: pipeline)
        XCTAssertEqual(run.id, "gitlab-pipeline-9")
        XCTAssertEqual(run.status, .inProgress)
        XCTAssertNil(run.conclusion)
        XCTAssertNil(run.completedAt, "a running pipeline has not completed")
    }

    // MARK: Vocabulary

    /// The `#8,045` bug: interpolating an `Int` into a `Text` goes through
    /// `LocalizedStringKey`, which formats for the locale and adds a
    /// grouping separator. An identifier is not a quantity. The views now
    /// use `Text(verbatim:)`; this pins the expectation that a formatted
    /// number and a verbatim one differ, so the reason for that call is
    /// visible rather than looking like a stylistic choice.
    func testIdentifiersMustNotBeGrouped() {
        let number = 8045
        // What the buggy path produced, in a locale that groups.
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        XCTAssertEqual(formatter.string(from: NSNumber(value: number)), "8,045")
        // What an identifier must render as.
        XCTAssertEqual("#\(number)", "#8045")
    }

    func testForgeVocabularyMatchesEachService() {
        XCTAssertEqual(Forge.github.changeNoun, "pull request")
        XCTAssertEqual(Forge.gitlab.changeNoun, "merge request")
        XCTAssertEqual(Forge.gitlab.changeNounAbbreviation, "MR")
        XCTAssertEqual(Forge.github.changeNounAbbreviation, "PR")
    }
}
