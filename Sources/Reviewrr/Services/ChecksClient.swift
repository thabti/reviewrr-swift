import Foundation

/// Talks to GitHub's two overlapping CI surfaces — the modern Checks API
/// (GitHub Actions and most third-party apps) and the legacy commit-status
/// API (older CI integrations, deployment bots) — and normalizes both into
/// one `CheckRun` list so the rest of the app never has to know which
/// surface reported what.
struct ChecksClient {
    var api: GitHubAPI

    init(api: GitHubAPI) {
        self.api = api
    }

    /// Fetches every check for `headSha` and merges the two surfaces.
    /// Refresh is always explicit (called from `ConversationModel.refreshChecks()`) —
    /// this client never polls on its own.
    func fetchChecks(owner: String, repo: String, headSha: String, token: String?) async throws -> [CheckRun] {
        async let checkRuns = fetchCheckRuns(owner: owner, repo: repo, ref: headSha, token: token)
        async let legacy = fetchLegacyStatuses(owner: owner, repo: repo, ref: headSha, token: token)
        let (runs, statuses) = try await (checkRuns, legacy)
        return Self.merge(checkRuns: runs, legacyStatuses: statuses)
    }

    /// Combines the two surfaces: a CI provider migrating to the Checks API
    /// commonly reports both a check run and a legacy status for the same
    /// job, and the check run is strictly richer (lifecycle, output, app
    /// identity), so it wins and the duplicate status is dropped. Pure and
    /// side-effect-free so it's unit-testable without a network call.
    static func merge(checkRuns: [CheckRun], legacyStatuses: [CheckRun]) -> [CheckRun] {
        let checkRunNames = Set(checkRuns.map { $0.name.lowercased() })
        let dedupedStatuses = legacyStatuses.filter { !checkRunNames.contains($0.name.lowercased()) }
        return (checkRuns + dedupedStatuses).sorted { lhs, rhs in
            (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
        }
    }

    // MARK: - Checks API

    private struct CheckRunsResponse: Decodable {
        let totalCount: Int
        let checkRuns: [DTO]
        enum CodingKeys: String, CodingKey {
            case totalCount = "total_count"
            case checkRuns = "check_runs"
        }

        struct DTO: Decodable {
            struct Output: Decodable { let title: String?; let summary: String? }
            struct App: Decodable { let name: String? }
            let id: Int
            let name: String
            let status: String
            let conclusion: String?
            let startedAt: Date?
            let completedAt: Date?
            let htmlUrl: String?
            let detailsUrl: String?
            let output: Output?
            let app: App?
            enum CodingKeys: String, CodingKey {
                case id, name, status, conclusion, output, app
                case startedAt = "started_at"
                case completedAt = "completed_at"
                case htmlUrl = "html_url"
                case detailsUrl = "details_url"
            }
        }
    }

    private func fetchCheckRuns(owner: String, repo: String, ref: String, token: String?) async throws -> [CheckRun] {
        var collected: [CheckRunsResponse.DTO] = []
        var page = 1
        let perPage = 100
        // `total_count` bounds the crawl; `page > 10` is a hard backstop
        // against a malformed response looping forever.
        while page <= 10 {
            let response = try await api.get(
                CheckRunsResponse.self,
                path: "/repos/\(owner)/\(repo)/commits/\(ref)/check-runs",
                token: token,
                query: [
                    URLQueryItem(name: "per_page", value: String(perPage)),
                    URLQueryItem(name: "page", value: String(page)),
                ]
            )
            collected.append(contentsOf: response.checkRuns)
            if collected.count >= response.totalCount || response.checkRuns.isEmpty { break }
            page += 1
        }

        return collected.map { dto in
            CheckRun(
                id: "checkrun-\(dto.id)",
                name: dto.name,
                appName: dto.app?.name,
                status: CheckStatus(rawValue: dto.status) ?? .completed,
                conclusion: dto.conclusion.flatMap(CheckConclusion.init(rawValue:)),
                startedAt: dto.startedAt,
                completedAt: dto.completedAt,
                detailsURL: (dto.detailsUrl ?? dto.htmlUrl).flatMap(URL.init(string:)),
                outputTitle: dto.output?.title,
                outputSummary: dto.output?.summary,
                source: .checkRun
            )
        }
    }

    // MARK: - Legacy commit-status API

    private struct CombinedStatusResponse: Decodable {
        let statuses: [DTO]
        struct DTO: Decodable {
            let id: Int
            let state: String
            let description: String?
            let context: String
            let targetUrl: String?
            let createdAt: Date
            let updatedAt: Date
            enum CodingKeys: String, CodingKey {
                case id, state, description, context
                case targetUrl = "target_url"
                case createdAt = "created_at"
                case updatedAt = "updated_at"
            }
        }
    }

    private func fetchLegacyStatuses(owner: String, repo: String, ref: String, token: String?) async throws -> [CheckRun] {
        let response = try await api.get(
            CombinedStatusResponse.self,
            path: "/repos/\(owner)/\(repo)/commits/\(ref)/status",
            token: token
        )
        return response.statuses.map { dto in
            let (status, conclusion) = Self.mapLegacyState(dto.state)
            return CheckRun(
                id: "status-\(dto.id)",
                name: dto.context,
                appName: dto.context,
                status: status,
                conclusion: conclusion,
                startedAt: dto.createdAt,
                completedAt: status == .completed ? dto.updatedAt : nil,
                detailsURL: dto.targetUrl.flatMap(URL.init(string:)),
                outputTitle: nil,
                outputSummary: dto.description,
                source: .legacyStatus
            )
        }
    }

    /// The legacy API has no queued/in-progress distinction — only
    /// "pending", which maps to `.inProgress` since GitHub itself treats a
    /// pending status as CI-in-flight rather than unstarted. `"error"` and
    /// `"failure"` are distinct states in GitHub's model (infrastructure
    /// failure vs. a failed check) but both read as "this failed" here.
    static func mapLegacyState(_ state: String) -> (CheckStatus, CheckConclusion?) {
        switch state {
        case "success": return (.completed, .success)
        case "failure", "error": return (.completed, .failure)
        default: return (.inProgress, nil)
        }
    }
}
