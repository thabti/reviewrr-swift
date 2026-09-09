import Foundation

// The `reviewrr.ai-review.v1` result contract from
// `docs/architecture/ai-review-result-v1.md`. Reviewrr renders this shape
// verbatim in the AI right rail; it never becomes a diff decoration, a
// local draft, or a GitHub comment on its own — see `PRAnalyzer`.

enum AnalysisRisk: String, Codable, Equatable {
    case low, medium, high, critical
}

enum AnalysisReviewEffort: String, Codable, Equatable {
    case small, medium, large
}

/// Ordered worst-to-best so `sorted(by:)` on findings reads naturally as
/// "most severe first" without a separate comparator.
enum AnalysisSeverity: String, Codable, Equatable, CaseIterable, Comparable {
    case blocker, high, medium, low, info

    private var rank: Int {
        switch self {
        case .blocker: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .info: return 4
        }
    }

    static func < (lhs: AnalysisSeverity, rhs: AnalysisSeverity) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .blocker: return "Blocker"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .info: return "Info"
        }
    }
}

enum AnalysisCategory: String, Codable, Equatable {
    case correctness, security, performance, concurrency
    case dataIntegrity = "data_integrity"
    case maintainability, testing, documentation, other

    var label: String {
        switch self {
        case .correctness: return "Correctness"
        case .security: return "Security"
        case .performance: return "Performance"
        case .concurrency: return "Concurrency"
        case .dataIntegrity: return "Data integrity"
        case .maintainability: return "Maintainability"
        case .testing: return "Testing"
        case .documentation: return "Documentation"
        case .other: return "Other"
        }
    }
}

enum AnalysisSkipReason: String, Codable, Equatable {
    case binary, generated, vendor
    case sizeLimit = "size_limit"
    case contextLimit = "context_limit"
    case unsupported, unavailable

    var label: String {
        switch self {
        case .binary: return "Binary"
        case .generated: return "Generated"
        case .vendor: return "Vendor"
        case .sizeLimit: return "Too large"
        case .contextLimit: return "Over context budget"
        case .unsupported: return "Unsupported"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Reuse of an unchanged cached result is a Reviewrr delivery state, not a
/// new agent response — see the schema doc's "Cache identity and
/// extension" section. `analysisMode` describes what the *agent* produced;
/// `AnalysisSource` (in `PRAnalyzer.swift`) describes whether Reviewrr
/// actually called it this time.
enum AnalysisMode: String, Codable, Equatable {
    case fresh, extended
}

struct AnalysisSkippedFile: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var reason: AnalysisSkipReason
    var detail: String?
}

struct AnalysisScope: Codable, Equatable {
    var host: String
    var owner: String
    var repository: String
    var prNumber: Int
    var baseSha: String
    var headSha: String
    var agent: String
    var model: String
    var analysisMode: AnalysisMode
    var analyzedFiles: [String]
    var skippedFiles: [AnalysisSkippedFile]

    enum CodingKeys: String, CodingKey {
        case host, owner, repository, prNumber, baseSha, headSha, agent, model
        case analysisMode, analyzedFiles, skippedFiles
    }

    init(
        host: String, owner: String, repository: String, prNumber: Int, baseSha: String, headSha: String,
        agent: String, model: String, analysisMode: AnalysisMode,
        analyzedFiles: [String], skippedFiles: [AnalysisSkippedFile]
    ) {
        self.host = host
        self.owner = owner
        self.repository = repository
        self.prNumber = prNumber
        self.baseSha = baseSha
        self.headSha = headSha
        self.agent = agent
        self.model = model
        self.analysisMode = analysisMode
        self.analyzedFiles = analyzedFiles
        self.skippedFiles = skippedFiles
    }

    // A provider that omits or mangles `analyzedFiles`/`skippedFiles` (or
    // ships a schema written before we added a field) should not sink an
    // otherwise-usable response — those two arrays default to empty rather
    // than failing the whole decode. The scalar identity fields stay
    // required: a response with no `headSha` at all has nothing worth
    // validating against the current revision.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        owner = try container.decode(String.self, forKey: .owner)
        repository = try container.decode(String.self, forKey: .repository)
        prNumber = try container.decode(Int.self, forKey: .prNumber)
        baseSha = try container.decode(String.self, forKey: .baseSha)
        headSha = try container.decode(String.self, forKey: .headSha)
        agent = try container.decode(String.self, forKey: .agent)
        model = try container.decode(String.self, forKey: .model)
        analysisMode = try container.decode(AnalysisMode.self, forKey: .analysisMode)
        analyzedFiles = Self.lenientArray(container, .analyzedFiles)
        skippedFiles = Self.lenientArray(container, .skippedFiles)
    }

    /// A missing or malformed optional array decodes to empty rather than
    /// failing the whole container — see the `init(from:)` doc comment.
    private static func lenientArray<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        (try? container.decodeIfPresent([T].self, forKey: key)).flatMap { $0 } ?? []
    }
}

struct AnalysisOverview: Codable, Equatable {
    var title: String
    var summary: String
    var intent: String
    var risk: AnalysisRisk
    var reviewEffort: AnalysisReviewEffort
}

struct AnalysisReviewOrderItem: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var priority: Int
    var reason: String
}

struct AnalysisFileSummary: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var role: String
    var summary: String
    var risk: AnalysisRisk
}

struct AnalysisFinding: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var severity: AnalysisSeverity
    var category: AnalysisCategory
    var confidence: Double
    var path: String?
    var side: DiffSide?
    var startLine: Int?
    var endLine: Int?
    var evidence: String
    var explanation: String
    var suggestion: String?

    /// `path:line` (or `path:start-end`), the anchor form the UI turns into
    /// navigation and a draft-comment starting point. Nil when the finding
    /// has no code anchor.
    var citation: String? {
        guard let path, let startLine else { return nil }
        if let endLine, endLine != startLine { return "\(path):\(startLine)-\(endLine)" }
        return "\(path):\(startLine)"
    }
}

struct AnalysisTestGap: Codable, Equatable {
    var title: String
    var description: String
    var paths: [String]
}

struct AnalysisArchitectureImpact: Codable, Equatable {
    var area: String
    var impact: String
    var risk: AnalysisRisk
}

struct AnalysisReviewerQuestion: Codable, Equatable {
    var question: String
    var reason: String
    var path: String?
}

struct AnalysisResult: Codable, Equatable {
    static let currentSchemaVersion = "reviewrr.ai-review.v1"

    var schemaVersion: String
    var scope: AnalysisScope
    var overview: AnalysisOverview
    var reviewOrder: [AnalysisReviewOrderItem]
    var fileSummaries: [AnalysisFileSummary]
    var findings: [AnalysisFinding]
    var testGaps: [AnalysisTestGap]
    var architectureImpact: [AnalysisArchitectureImpact]
    var reviewerQuestions: [AnalysisReviewerQuestion]
    var limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion, scope, overview, reviewOrder, fileSummaries, findings
        case testGaps, architectureImpact, reviewerQuestions, limitations
    }

    /// Manual `init(from:)` so a response missing an optional section (a
    /// provider's "partial" output, or a schema that predates a field we
    /// later added) degrades to an empty array instead of failing decode
    /// entirely — the doc's "empty arrays are valid" rule extends to
    /// sections a response simply left out. `schemaVersion`, `scope`, and
    /// `overview` stay required: without them there is nothing to validate
    /// or render.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        scope = try container.decode(AnalysisScope.self, forKey: .scope)
        overview = try container.decode(AnalysisOverview.self, forKey: .overview)
        reviewOrder = Self.lenientArray(container, .reviewOrder)
        fileSummaries = Self.lenientArray(container, .fileSummaries)
        findings = Self.lenientArray(container, .findings)
        testGaps = Self.lenientArray(container, .testGaps)
        architectureImpact = Self.lenientArray(container, .architectureImpact)
        reviewerQuestions = Self.lenientArray(container, .reviewerQuestions)
        limitations = Self.lenientArray(container, .limitations)
    }

    /// A missing or malformed optional array decodes to empty rather than
    /// failing the whole container — see the doc comment above.
    private static func lenientArray<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        (try? container.decodeIfPresent([T].self, forKey: key)).flatMap { $0 } ?? []
    }

    init(
        schemaVersion: String = AnalysisResult.currentSchemaVersion,
        scope: AnalysisScope,
        overview: AnalysisOverview,
        reviewOrder: [AnalysisReviewOrderItem] = [],
        fileSummaries: [AnalysisFileSummary] = [],
        findings: [AnalysisFinding] = [],
        testGaps: [AnalysisTestGap] = [],
        architectureImpact: [AnalysisArchitectureImpact] = [],
        reviewerQuestions: [AnalysisReviewerQuestion] = [],
        limitations: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.overview = overview
        self.reviewOrder = reviewOrder
        self.fileSummaries = fileSummaries
        self.findings = findings
        self.testGaps = testGaps
        self.architectureImpact = architectureImpact
        self.reviewerQuestions = reviewerQuestions
        self.limitations = limitations
    }

    /// Findings in the order the schema doc prescribes for rendering:
    /// most severe first, ties broken by higher evidence confidence.
    var findingsBySeverity: [AnalysisFinding] {
        findings.sorted {
            $0.severity == $1.severity ? $0.confidence > $1.confidence : $0.severity < $1.severity
        }
    }
}

/// What Reviewrr actually stores and renders: the validated structured
/// result, or — when parsing and one repair attempt both fail — the raw
/// text labeled honestly as unstructured rather than silently discarded.
enum AnalysisOutcome: Codable, Equatable {
    case structured(AnalysisResult)
    case unstructured(raw: String, reason: String)
}
