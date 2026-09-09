import Foundation

/// Rate-limit state read off any response, so the UI can show remaining
/// budget before a request actually fails.
struct RateLimitInfo: Equatable {
    var limit: Int?
    var remaining: Int?
    var resetAt: Date?

    init?(_ response: HTTPURLResponse) {
        limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init)
        remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        if limit == nil && remaining == nil && resetAt == nil { return nil }
    }
}

/// A decoded body plus the metadata callers need from the envelope:
/// rate-limit budget and, for classic tokens, the granted OAuth scopes.
struct GitHubResponse<Value> {
    let value: Value
    let http: HTTPURLResponse

    var rateLimit: RateLimitInfo? { RateLimitInfo(http) }

    /// `X-OAuth-Scopes` is only sent for classic PATs and OAuth tokens.
    /// Fine-grained tokens and GitHub App tokens return no scope header.
    var oauthScopes: [String]? {
        guard let raw = http.value(forHTTPHeaderField: "X-OAuth-Scopes") else { return nil }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// GraphQL responses nest the payload under a top-level `data` key.
private struct GraphQLEnvelope<D: Decodable>: Decodable {
    let data: D
}

/// One `URLSession` per `ForgeHost`, shared by every `GitHubAPI` value
/// built for that host. `AppContext.api` deliberately builds a fresh
/// `GitHubAPI` struct on every call — that is how a token or host change
/// takes effect without re-wiring any already-constructed feature model —
/// so the session itself has to live outside the struct or every one of
/// those calls would open a new connection pool and defeat HTTP keep-alive.
/// `@unchecked Sendable` is honest here rather than silenced: `lock` is the
/// actual synchronization the compiler can't see across `sessions`, and
/// callers resolve `api()` from whatever context they already happen to be
/// on (background `Task`s among them), not only the main actor.
private final class GitHubSessionCache: @unchecked Sendable {
    static let shared = GitHubSessionCache()

    private let lock = NSLock()
    private var sessions: [ForgeHost: URLSession] = [:]

    func session(for host: ForgeHost) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[host] { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // No ETag/conditional-request cache of our own, so URLSession's
        // transparent HTTP cache must stay off too — otherwise review
        // state could silently render from disk (old diff, old comments)
        // with no visible error explaining why it is stale.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        sessions[host] = session
        return session
    }
}

/// The single HTTP transport every GitHub-facing service in the app shares:
/// URL building, auth headers, status/error normalization, `Link`
/// pagination, and GraphQL. Feature clients (`GitHubClient`, inbox, checks,
/// auth) sit on top of this rather than each re-implementing request
/// plumbing and error mapping.
///
/// Stateless by design: the token is passed per call, so a request can
/// never race a just-saved token held elsewhere. Cheap to copy: `host` is
/// a value type and `session` is a reference to the per-host shared
/// instance above, not a freshly built one.
struct GitHubAPI: Sendable {
    var host: ForgeHost
    /// HTTP Basic for a host behind a Basic-protected front door.
    ///
    /// Held on the value rather than passed per call, unlike `token`: Basic
    /// is host *configuration* that changes when a reviewer edits settings,
    /// not a per-request identity, so there is no just-saved-token race for
    /// it to lose. See `ForgeCredential.headers(for:)` for why a GitHub
    /// host cannot send Basic and a token at once.
    var basic: BasicCredential?
    private let session: URLSession

    init(host: ForgeHost = .dotCom, basic: BasicCredential? = nil, session: URLSession? = nil) {
        self.host = host
        self.basic = basic
        self.session = session ?? GitHubSessionCache.shared.session(for: host)
    }

    /// Configured once and reused for every decoded date rather than built
    /// per value: `ISO8601DateFormatter` construction sets up an internal
    /// calendar/timezone/locale and is expensive, and a 200-PR sync decodes
    /// on the order of 800 date values, so a fresh pair of formatters per
    /// value used to mean well over a thousand formatter constructions per
    /// sync. `date(from:)` on an already-configured instance is thread-safe,
    /// so sharing these across decodes (which can run on arbitrary threads)
    /// is safe. Two instances because GitHub mixes both shapes in one
    /// payload: fractional seconds on most timestamps, whole seconds on
    /// others.
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Request building

    /// `path` may be an absolute URL string (as returned in `Link` headers)
    /// or a path relative to the host's API root. Throws rather than
    /// force-unwrapping: `path` can originate from a server-supplied `Link`
    /// header, so a malformed value must surface as a diagnosable error
    /// rather than crash the app.
    func makeRequest(
        path: String,
        token: String?,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        accept: String = "application/vnd.github+json"
    ) throws -> URLRequest {
        let url: URL
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            guard let absolute = URL(string: path) else {
                throw GitHubError.apiError("Malformed URL from GitHub: \(path)")
            }
            url = absolute
        } else {
            url = host.apiBaseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GitHubError.apiError("Malformed URL from GitHub: \(url.absoluteString)")
        }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query
        }
        guard let finalURL = components.url else {
            throw GitHubError.apiError("Malformed URL from GitHub: \(url.absoluteString)")
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub asks every caller to identify itself; a stable User-Agent
        // also makes this app's traffic recognizable in support diagnostics.
        request.setValue("Reviewrr-Mac", forHTTPHeaderField: "User-Agent")
        for header in ForgeCredential(token: token, basic: basic).headers(for: host.forge) {
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
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw GitHubError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.network(URLError(.badServerResponse))
        }

        let hadToken = request.value(forHTTPHeaderField: "Authorization") != nil

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            // A 401 with no Authorization header means the caller never had a
            // token to send, not that GitHub rejected one — different fix.
            throw hadToken ? GitHubError.unauthorized : GitHubError.noToken
        case 403, 429:
            // GitHub reports both primary and secondary/abuse-detection rate
            // limits as 403s that do not always zero X-RateLimit-Remaining;
            // a Retry-After header or a rate-limit/abuse message is the tell.
            if let rateLimited = Self.rateLimitError(status: http.statusCode, response: http, data: data) {
                throw rateLimited
            }
            let message = Self.githubMessage(from: data) ?? "GitHub denied access to this resource."
            throw GitHubError.apiError("GitHub denied access (HTTP \(http.statusCode)): \(message) [\(Self.snippet(from: data))]")
        case 404:
            throw GitHubError.notFound(hadToken: hadToken)
        case 422:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var message = (json?["message"] as? String) ?? "GitHub rejected the request."
            if let errors = json?["errors"],
               let errorsData = try? JSONSerialization.data(withJSONObject: errors),
               let errorsString = String(data: errorsData, encoding: .utf8) {
                message += " Details: \(errorsString)"
            }
            throw GitHubError.validation("GitHub rejected the request (HTTP 422): \(message)")
        default:
            let message = Self.githubMessage(from: data) ?? "unknown error"
            throw GitHubError.apiError("GitHub API error \(http.statusCode): \(message) [\(Self.snippet(from: data))]")
        }
    }

    // MARK: - Typed helpers

    func get<T: Decodable>(_ type: T.Type, path: String, token: String?, query: [URLQueryItem] = []) async throws -> T {
        try await getResponse(type, path: path, token: token, query: query).value
    }

    func getResponse<T: Decodable>(
        _ type: T.Type, path: String, token: String?, query: [URLQueryItem] = []
    ) async throws -> GitHubResponse<T> {
        let (data, http) = try await send(try makeRequest(path: path, token: token, query: query))
        return GitHubResponse(value: try Self.decode(type, from: data, status: http.statusCode), http: http)
    }

    /// Follows GitHub's `Link: rel="next"` pagination. `maxPages` bounds a
    /// runaway crawl on very large collections.
    func getAllPages<T: Decodable>(
        _ type: T.Type,
        path: String,
        token: String?,
        query: [URLQueryItem] = [],
        perPage: Int = 100,
        maxPages: Int = 20
    ) async throws -> [T] {
        var results: [T] = []
        // The final count isn't known ahead of a `Link` header, but every
        // page holds at most `perPage` items, so reserving one page's worth
        // up front avoids at least the first few reallocations.
        results.reserveCapacity(perPage)
        var request: URLRequest? = try makeRequest(
            path: path, token: token, query: query + [URLQueryItem(name: "per_page", value: String(perPage))]
        )
        // Guards against a malformed or looping Link header.
        var seenURLs = Set<URL>()
        var pages = 0
        while let currentRequest = request, pages < maxPages {
            if let url = currentRequest.url {
                guard !seenURLs.contains(url) else { break }
                seenURLs.insert(url)
            }
            let (data, http) = try await send(currentRequest)
            let page = try Self.decode([T].self, from: data, status: http.statusCode)
            results.reserveCapacity(results.count + page.count)
            results.append(contentsOf: page)
            request = Self.nextPageRequest(from: http, previous: currentRequest)
            pages += 1
        }
        return results
    }

    /// Fetches every page, but concurrently rather than one after another.
    ///
    /// GitHub's `Link` header names the last page on the very first
    /// response, so the page count is known after one round trip and the
    /// rest can be fetched in parallel. Sequential pagination is why a
    /// 577-repository account took six serial round trips — roughly a
    /// second and a half of waiting — before anything could render.
    ///
    /// Concurrency is capped: GitHub's secondary rate limits punish a burst,
    /// and past a handful of connections there is nothing left to win.
    func getAllPagesConcurrently<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        token: String?,
        query: [URLQueryItem] = [],
        perPage: Int = 100,
        maxPages: Int = 10,
        maxConcurrent: Int = 4
    ) async throws -> [T] {
        let pagedQuery = query + [URLQueryItem(name: "per_page", value: String(perPage))]
        let (firstData, firstResponse) = try await send(try makeRequest(path: path, token: token, query: pagedQuery))
        var results = try Self.decode([T].self, from: firstData, status: firstResponse.statusCode)

        let lastPage = min(Self.lastPageNumber(from: firstResponse) ?? 1, maxPages)
        guard lastPage > 1 else { return results }

        // Indexed so the assembled result keeps GitHub's ordering — the
        // caller sorts by activity, but a stable order still matters for
        // tests and for anything that pages through the result.
        var pages: [Int: [T]] = [:]
        try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            var next = 2
            func addTask(page: Int) {
                group.addTask {
                    let request = try self.makeRequest(
                        path: path, token: token,
                        query: pagedQuery + [URLQueryItem(name: "page", value: String(page))]
                    )
                    let (data, response) = try await self.send(request)
                    return (page, try Self.decode([T].self, from: data, status: response.statusCode))
                }
            }
            while next <= lastPage && next < 2 + maxConcurrent {
                addTask(page: next)
                next += 1
            }
            while let (page, items) = try await group.next() {
                pages[page] = items
                if next <= lastPage {
                    addTask(page: next)
                    next += 1
                }
            }
        }
        for page in 2...lastPage {
            results.append(contentsOf: pages[page] ?? [])
        }
        return results
    }

    /// The `page` value of the `rel="last"` link, when GitHub sent one. A
    /// single-page response has no `last` link at all.
    static func lastPageNumber(from response: HTTPURLResponse) -> Int? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let segments = part.split(separator: ";")
            guard segments.count >= 2, segments[1].contains("rel=\"last\"") else { continue }
            let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">"),
                  let url = URL(string: String(urlPart.dropFirst().dropLast())),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let pageValue = components.queryItems?.first(where: { $0.name == "page" })?.value,
                  let page = Int(pageValue)
            else { continue }
            return page
        }
        return nil
    }

    @discardableResult
    func post<Body: Encodable, T: Decodable>(
        _ type: T.Type, path: String, token: String?, body: Body, method: String = "POST"
    ) async throws -> T {
        let data = try Self.encoder.encode(body)
        let (responseData, http) = try await send(try makeRequest(path: path, token: token, method: method, body: data))
        return try Self.decode(type, from: responseData, status: http.statusCode)
    }

    /// A raw response body, for endpoints whose useful representation is not
    /// JSON (`application/vnd.github.raw`, `.diff`, `.patch`).
    func rawString(path: String, token: String?, query: [URLQueryItem] = [], accept: String) async throws -> String {
        let (data, _) = try await send(try makeRequest(path: path, token: token, query: query, accept: accept))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - GraphQL

    /// GraphQL covers what REST cannot express: a PR's aggregate
    /// `reviewDecision`, thread-level `isResolved`, and cross-repository
    /// review search in one round trip.
    func graphQL<T: Decodable>(
        _ type: T.Type, query: String, variables: [String: Any] = [:], token: String?
    ) async throws -> T {
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: host.graphQLURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Reviewrr-Mac", forHTTPHeaderField: "User-Agent")
        for header in ForgeCredential(token: token, basic: basic).headers(for: host.forge) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let (data, http) = try await send(request)
        // GraphQL reports failures inside a 200 body, so errors must be read
        // from the payload rather than the status code.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            throw GitHubError.apiError("GitHub GraphQL error: \(messages.isEmpty ? Self.snippet(from: data) : messages)")
        }
        return try Self.decode(GraphQLEnvelope<T>.self, from: data, status: http.statusCode).data
    }

    // MARK: - Shared diagnostics

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, status: Int) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GitHubError.decoding(
                "Unexpected response from GitHub (HTTP \(status)): \(describe(decodingError: error)) — body: \(snippet(from: data))"
            )
        }
    }

    /// Detects both primary (`429`, or `403` with `X-RateLimit-Remaining: 0`)
    /// and secondary/abuse-detection (`403` with `Retry-After`, or a message
    /// mentioning rate limiting/abuse) rate limits.
    static func rateLimitError(status: Int, response: HTTPURLResponse, data: Data) -> GitHubError? {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let retryAfterHeader = response.value(forHTTPHeaderField: "Retry-After")
        let message = githubMessage(from: data)?.lowercased() ?? ""
        let looksRateLimited = status == 429
            || remaining == "0"
            || retryAfterHeader != nil
            || message.contains("rate limit")
            || message.contains("abuse detection")
        guard looksRateLimited else { return nil }

        if let resetHeader = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let epoch = Double(resetHeader) {
            return .rateLimited(resetAt: Date(timeIntervalSince1970: epoch))
        }
        if let retryAfterHeader, let seconds = Double(retryAfterHeader) {
            return .rateLimited(resetAt: Date().addingTimeInterval(seconds))
        }
        return .rateLimited(resetAt: nil)
    }

    static func githubMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["message"] as? String
    }

    /// A short, single-line, alert-safe excerpt of a raw body — long enough
    /// to diagnose an unexpected shape without attaching a debugger.
    static func snippet(from data: Data, limit: Int = 240) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, non-UTF8 body>"
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "<empty body>" }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// A focused description of *why* decoding failed — which key/type, at
    /// what path — rather than Swift's verbose default `DecodingError` dump.
    static func describe(decodingError error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "expected \(type) at \"\(path(context))\" — \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \"\(path(context))\" — \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing key \"\(key.stringValue)\" at \"\(path(context))\" — \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "corrupted data at \"\(path(context))\" — \(context.debugDescription)"
        @unknown default:
            return String(describing: decodingError)
        }
    }

    static func nextPageRequest(from response: HTTPURLResponse, previous: URLRequest) -> URLRequest? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let segments = part.split(separator: ";")
            guard segments.count >= 2, segments[1].contains("rel=\"next\"") else { continue }
            let urlPart = segments[0].trimmingCharacters(in: .whitespaces)
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">"),
                  let url = URL(string: String(urlPart.dropFirst().dropLast())) else { continue }
            var next = previous
            next.url = url
            return next
        }
        return nil
    }
}
