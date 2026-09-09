import Foundation

/// One `URLSession` per GitLab host, for the same reason `GitHubAPI` has
/// one: `AppContext.api()` builds a fresh transport value on every call so
/// a host or credential change takes effect without re-wiring any feature
/// model, and a session built per value would defeat HTTP keep-alive.
private final class GitLabSessionCache: @unchecked Sendable {
    static let shared = GitLabSessionCache()

    private let lock = NSLock()
    private var sessions: [ForgeHost: URLSession] = [:]

    func session(for host: ForgeHost) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[host] { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // Same reasoning as the GitHub transport: with no conditional-request
        // cache of our own, URLSession's transparent cache must stay off, or
        // review state could render from disk with no visible staleness.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Deliberately no `URLSessionDelegate`, which is what it would take
        // to weaken TLS validation. A self-hosted instance with a private CA
        // is trusted by installing that CA on the Mac — see
        // `GitLabError.tlsUntrusted` for what the app says when it isn't.
        let session = URLSession(configuration: config)
        sessions[host] = session
        return session
    }
}

/// What went wrong talking to GitLab.
///
/// A separate vocabulary from `GitHubError` rather than a shared one: the
/// remedies differ (a project path is not an `owner/repo`, a self-hosted
/// instance can fail in ways github.com cannot), and a message that says
/// "GitHub" to someone using GitLab reads as a bug in the app.
enum GitLabError: LocalizedError {
    case noCredential
    case unauthorized(sentBasic: Bool)
    /// GitLab returns 403 for a token whose scopes are too narrow, which is
    /// the most common misconfiguration: `read_api` cannot post a review.
    case forbidden(String)
    case notFound(hadCredential: Bool)
    case validation(String)
    case apiError(String)
    case network(Error)
    case decoding(String)
    /// The instance's certificate is not trusted by this Mac. Named
    /// separately because the fix is neither the token nor the URL.
    case tlsUntrusted(host: String)
    /// Reviewrr asked for something this GitLab does not have — an endpoint
    /// added in a later version, or a feature (merge request approvals) that
    /// is Premium-only.
    case unsupportedByInstance(String)
    /// The instance failed on its own side. Carries the endpoint, because
    /// that is the only part a reviewer or an admin can act on.
    case serverError(status: Int, endpoint: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noCredential:
            return "No GitLab credential configured — add an access token in Settings ▸ Account."
        case .unauthorized(let sentBasic):
            if sentBasic {
                return """
                    GitLab rejected the credential (HTTP 401). If this instance is behind HTTP Basic auth, \
                    check the username and password; note that GitLab's own API does not accept Basic auth, \
                    so an access token is needed as well.
                    """
            }
            return "GitLab rejected the access token as invalid or expired. Update it in Settings ▸ Account."
        case .forbidden(let message):
            return "GitLab denied access (HTTP 403): \(message) A token needs the \"api\" scope to read and review; \"read_api\" alone cannot post a review."
        case .notFound(let hadCredential):
            if hadCredential {
                return "Not found on GitLab. Check the project path and merge request number, or whether this token can see that project."
            }
            return "Not found on GitLab. If the project is private, add an access token with \"api\" scope in Settings ▸ Account."
        case .validation(let message):
            return message
        case .apiError(let message):
            return message
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let message):
            return message
        case .tlsUntrusted(let host):
            return """
                The certificate for \(host) is not trusted by this Mac. If your organization uses its own \
                certificate authority, install that root certificate in Keychain Access (or have it deployed \
                by MDM), then try again. Reviewrr will not skip certificate validation.
                """
        case .unsupportedByInstance(let message):
            return message
        case .serverError(let status, let endpoint, let detail):
            return """
                GitLab returned HTTP \(status) for \(endpoint) — the instance failed on its own side, \
                so this is not something a different token or URL fixes. Detail: \(detail). \
                Retrying may work; if it does not, this endpoint is worth showing to whoever runs the instance.
                """
        }
    }
}

/// The HTTP transport every GitLab-facing service shares: URL building,
/// project-path encoding, auth headers, status/error normalization, and
/// GitLab's page-header pagination.
///
/// Deliberately parallel in shape to `GitHubAPI` — same statelessness with
/// respect to the token, same per-host session, same "decode with a
/// diagnosable message" contract — so the two can sit behind one protocol
/// without either pretending to be the other.
struct GitLabAPI: Sendable {
    var host: ForgeHost
    /// See `GitHubAPI.basic`: host configuration, not a per-request
    /// identity. On GitLab this travels alongside the token rather than
    /// competing with it, because the token uses `PRIVATE-TOKEN`.
    var basic: BasicCredential?
    private let session: URLSession

    init(host: ForgeHost, basic: BasicCredential? = nil, session: URLSession? = nil) {
        self.host = host
        self.basic = basic
        self.session = session ?? GitLabSessionCache.shared.session(for: host)
    }

    /// GitLab timestamps are ISO 8601, with fractional seconds on some
    /// fields (`created_at` on notes) and whole seconds on others. Two
    /// pre-built formatters for the same reason `GitHubAPI` has them: a
    /// large merge request decodes hundreds of dates, and
    /// `ISO8601DateFormatter` is expensive to construct.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601WholeSeconds = ISO8601DateFormatter()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: string) ?? iso8601WholeSeconds.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized GitLab date: \(string)")
        }
        return decoder
    }()

    static let encoder = JSONEncoder()

    // MARK: - Project identity

    /// GitLab addresses a project by its full path, URL-encoded into a
    /// single path segment: `group/subgroup/project` becomes
    /// `group%2Fsubgroup%2Fproject`.
    ///
    /// This is the one piece of GitLab's shape that has no GitHub analogue —
    /// GitHub has exactly two levels, GitLab has arbitrarily nested groups —
    /// and it is why `PRReference.owner` carries the whole group path for a
    /// GitLab reference.
    static func encodedProjectPath(owner: String, repo: String) -> String {
        let full = owner.isEmpty ? repo : "\(owner)/\(repo)"
        // `urlHostAllowed` would leave "/" intact, which is exactly what
        // must not survive: the slash has to become %2F so the whole path is
        // one segment.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return full.addingPercentEncoding(withAllowedCharacters: allowed) ?? full
    }

    func projectPath(_ reference: PRReference) -> String {
        Self.encodedProjectPath(owner: reference.owner, repo: reference.repo)
    }

    func mergeRequestPath(_ reference: PRReference) -> String {
        "/projects/\(projectPath(reference))/merge_requests/\(reference.number)"
    }

    // MARK: - Request building

    func makeRequest(
        path: String,
        token: String?,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) throws -> URLRequest {
        let url: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let absolute = URL(string: path) else {
                throw GitLabError.apiError("Malformed URL from GitLab: \(path)")
            }
            url = absolute
        } else {
            // `appendingPathComponent` would percent-encode the %2F in an
            // already-encoded project path back into %252F, addressing a
            // project literally named "group/project". The URL is assembled
            // as a string so the encoding done above survives.
            let base = host.apiBaseURL.absoluteString
            let joined = path.hasPrefix("/") ? base + path : base + "/" + path
            guard let built = URL(string: joined) else {
                throw GitLabError.apiError("Malformed URL from GitLab: \(joined)")
            }
            url = built
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitLabError.apiError("Malformed URL from GitLab: \(url.absoluteString)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let finalURL = components.url else {
            throw GitLabError.apiError("Malformed URL from GitLab: \(url.absoluteString)")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Reviewrr-Mac", forHTTPHeaderField: "User-Agent")
        for header in ForgeCredential(token: token, basic: basic).headers(for: .gitlab) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Sending

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let urlError = error as? URLError {
                if urlError.code == .cancelled { throw CancellationError() }
                // The distinctive self-hosted failure: a private CA nobody
                // installed. Reported as itself rather than as "network
                // error", because the fix is in Keychain Access.
                if Self.isTLSTrustFailure(urlError) {
                    throw GitLabError.tlsUntrusted(host: request.url?.host ?? host.displayName)
                }
            }
            throw GitLabError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitLabError.network(URLError(.badServerResponse))
        }

        let sentToken = request.value(forHTTPHeaderField: "PRIVATE-TOKEN") != nil
        let sentBasic = request.value(forHTTPHeaderField: "Authorization") != nil
        let hadCredential = sentToken || sentBasic

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            guard hadCredential else { throw GitLabError.noCredential }
            throw GitLabError.unauthorized(sentBasic: sentBasic && !sentToken)
        case 403:
            throw GitLabError.forbidden(Self.message(from: data) ?? "The credential is not allowed to do that.")
        case 404:
            throw GitLabError.notFound(hadCredential: hadCredential)
        case 400, 409, 422:
            let message = Self.message(from: data) ?? "GitLab rejected the request."
            throw GitLabError.validation("GitLab rejected \(endpoint(request)) (HTTP \(http.statusCode)): \(message)")
        case 429:
            throw GitLabError.apiError("GitLab rate limit hit (HTTP 429) on \(endpoint(request)). Try again shortly.")
        case 500...599:
            // A 5xx is the instance's problem, not the request's — but which
            // endpoint produced it is the only thing that makes it
            // actionable, and the message used to omit it entirely. A bare
            // "GitLab API error 500" could have come from any of the six
            // calls opening a merge request fans out to.
            let message = Self.message(from: data) ?? "no message"
            throw GitLabError.serverError(
                status: http.statusCode,
                endpoint: endpoint(request),
                detail: message
            )
        default:
            let message = Self.message(from: data) ?? "unknown error"
            throw GitLabError.apiError(
                "GitLab API error \(http.statusCode) on \(endpoint(request)): \(message) [\(Self.snippet(from: data))]"
            )
        }
    }

    /// `GET /projects/x%2Fy/merge_requests/7/diffs` — the method and path
    /// of a request, for an error message that has to be actionable.
    ///
    /// The query string is deliberately dropped: it adds length without
    /// adding identity, and a credential must never reach a message even by
    /// accident (this transport sends credentials as headers, and this keeps
    /// that true if one ever moves).
    private func endpoint(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? "an unknown path"
        return "\(method) \(path)"
    }

    /// The `URLError` codes that mean "the server's certificate was not
    /// trusted", as opposed to any other transport failure.
    static func isTLSTrustFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .secureConnectionFailed,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// GitLab reports errors as `{"message": …}` or `{"error": …}`, and
    /// `message` is sometimes a string and sometimes a keyed object of
    /// field errors. All three shapes reduced to one sentence.
    static func message(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let message = json["message"] as? [String: Any] {
            let parts = message.map { key, value -> String in
                if let list = value as? [Any] {
                    return "\(key): \(list.map { "\($0)" }.joined(separator: ", "))"
                }
                return "\(key): \(value)"
            }
            return parts.sorted().joined(separator: "; ")
        }
        if let messages = json["message"] as? [Any] {
            return messages.map { "\($0)" }.joined(separator: "; ")
        }
        return nil
    }

    static func snippet(from data: Data, limit: Int = 200) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "<\(data.count) bytes>" }
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw GitLabError.decoding(describe(error, type: type, status: status, data: data))
        } catch {
            throw GitLabError.decoding("Could not decode \(type) from GitLab (HTTP \(status)): \(error.localizedDescription)")
        }
    }

    /// Names the key and path that did not match, like the GitHub transport
    /// does: a self-hosted instance may be several versions behind, and
    /// "expected String, found null at merge_requests[0].author" is the
    /// difference between a bug report and a shrug.
    private static func describe<T>(_ error: DecodingError, type: T.Type, status: Int, data: Data) -> String {
        let detail: String
        switch error {
        case .keyNotFound(let key, let context):
            detail = "missing key \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(let expected, let context):
            detail = "expected \(expected) at \(path(context))"
        case .valueNotFound(let expected, let context):
            detail = "no value for \(expected) at \(path(context))"
        case .dataCorrupted(let context):
            detail = "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            detail = "\(error)"
        }
        return "Could not decode \(type) from GitLab (HTTP \(status)): \(detail). [\(snippet(from: data))]"
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
        return joined.isEmpty ? "the top level" : joined
    }

    // MARK: - Typed helpers

    func get<T: Decodable>(_ type: T.Type, path: String, token: String?, query: [URLQueryItem] = []) async throws -> T {
        let (data, http) = try await send(try makeRequest(path: path, token: token, query: query))
        return try Self.decode(type, from: data, status: http.statusCode)
    }

    /// Follows GitLab's page headers rather than `Link`.
    ///
    /// GitLab sends both, but `X-Next-Page` is the documented one and is
    /// present on every paginated response including the last (empty there),
    /// so it needs no parsing of a header grammar. `maxPages` bounds a
    /// runaway crawl the same way the GitHub transport's does.
    func getAllPages<T: Decodable>(
        _ type: T.Type,
        path: String,
        token: String?,
        query: [URLQueryItem] = [],
        perPage: Int = 100,
        maxPages: Int = 20
    ) async throws -> [T] {
        var results: [T] = []
        results.reserveCapacity(perPage)
        var page = 1
        var pages = 0
        while pages < maxPages {
            let paged = query + [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            let (data, http) = try await send(try makeRequest(path: path, token: token, query: paged))
            results += try Self.decode([T].self, from: data, status: http.statusCode)
            pages += 1
            guard
                let next = http.value(forHTTPHeaderField: "X-Next-Page"),
                let nextPage = Int(next.trimmingCharacters(in: .whitespaces)),
                nextPage > page
            else { break }
            page = nextPage
        }
        return results
    }

    func post<Body: Encodable, T: Decodable>(
        _ type: T.Type, path: String, token: String?, body: Body
    ) async throws -> T {
        let encoded = try Self.encoder.encode(body)
        let (data, http) = try await send(
            try makeRequest(path: path, token: token, method: "POST", body: encoded)
        )
        return try Self.decode(type, from: data, status: http.statusCode)
    }

    /// For endpoints whose useful answer is the status code — GitLab's
    /// `bulk_publish` returns an empty body on success.
    @discardableResult
    func postNoContent<Body: Encodable>(path: String, token: String?, body: Body?) async throws -> HTTPURLResponse {
        let encoded = try body.map { try Self.encoder.encode($0) }
        let (_, http) = try await send(
            try makeRequest(path: path, token: token, method: "POST", body: encoded)
        )
        return http
    }

    @discardableResult
    func put<Body: Encodable, T: Decodable>(
        _ type: T.Type, path: String, token: String?, body: Body
    ) async throws -> T {
        let encoded = try Self.encoder.encode(body)
        let (data, http) = try await send(
            try makeRequest(path: path, token: token, method: "PUT", body: encoded)
        )
        return try Self.decode(type, from: data, status: http.statusCode)
    }
}
