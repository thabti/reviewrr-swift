import Foundation

/// Per-file triage signals derived once from a `PRFile`, independent of any
/// diff line data — everything here is pure path/patch inspection so it's
/// cheap enough to run over every file in a 200-file PR up front.
struct FileClassification: Equatable {
    let category: FileCategory
    /// Every added/removed line, once whitespace is stripped, has a match
    /// on the other side: the change only re-indented or re-wrapped code.
    let isFormattingOnly: Bool
    /// Enough changed lines that rendering the full diff immediately is
    /// worth guarding behind a "show anyway?" affordance.
    let isLargeFile: Bool
    /// GitHub omitted `patch` (binary content, or a diff too large to
    /// return inline) — there is nothing to render as a line-level diff.
    let isBinaryOrEmpty: Bool
    let isRename: Bool
}

/// Classifies changed files into `FileCategory` buckets and derives triage
/// signals, purely from path/filename patterns and the patch text GitHub
/// already returned. No I/O, no repository access — this has to run for
/// every file in a large PR without ever blocking the UI.
enum FileClassifier {
    /// Above this many changed lines, a file is flagged "large" so the diff
    /// view can offer a "show anyway?" affordance instead of laying out a
    /// huge patch immediately.
    static let largeFileChangeThreshold = 800

    static func classify(_ file: PRFile) -> FileClassification {
        FileClassification(
            category: category(for: file.filename),
            isFormattingOnly: isFormattingOnly(patch: file.patch),
            isLargeFile: file.changes > largeFileChangeThreshold,
            isBinaryOrEmpty: file.patch == nil,
            isRename: file.status == .renamed
        )
    }

    /// Everything `classify` derives except `isFormattingOnly`.
    ///
    /// The formatting check reads the *whole patch* — splitting it into
    /// lines, allocating a string per line, stripping whitespace and sorting
    /// both sides. Across a 675-file pull request with forty thousand changed
    /// lines that is the single most expensive thing on the load path, and it
    /// was running on the main actor before the diff could draw. Nothing the
    /// reviewer sees first depends on it: the category (pure path work) is
    /// what filters and sorts the tree, and the formatting flag only adds a
    /// glyph. So the tree is built from this, and the flag is filled in by a
    /// background pass a moment later.
    static func quickClassify(_ file: PRFile) -> FileClassification {
        FileClassification(
            category: category(for: file.filename),
            isFormattingOnly: false,
            isLargeFile: file.changes > largeFileChangeThreshold,
            isBinaryOrEmpty: file.patch == nil,
            isRename: file.status == .renamed
        )
    }

    /// True when every removed line has a whitespace-insensitive match
    /// among the added lines (and vice versa) — i.e. the only thing that
    /// changed is indentation, wrapping, or trailing whitespace. Order is
    /// ignored on purpose: a re-indent can shift line order without
    /// changing content (e.g. a formatter reflowing a parameter list).
    static func isFormattingOnly(patch: String?) -> Bool {
        guard let patch, !patch.isEmpty else { return false }

        var removed: [String] = []
        var added: [String] = []
        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") || line.hasPrefix("\\ No newline") { continue }
            if line.hasPrefix("+") { added.append(String(line.dropFirst())) }
            else if line.hasPrefix("-") { removed.append(String(line.dropFirst())) }
        }
        guard !removed.isEmpty, removed.count == added.count else { return false }

        func normalize(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let normalizedRemoved = removed.map(normalize).sorted()
        let normalizedAdded = added.map(normalize).sorted()
        return normalizedRemoved == normalizedAdded
    }

    // MARK: - Category rules

    static func category(for path: String) -> FileCategory {
        let ns = path as NSString
        let filename = ns.lastPathComponent
        let ext = ns.pathExtension.lowercased()
        let lowerPath = path.lowercased()
        let lowerFilename = filename.lowercased()

        // Rules are ordered by specificity: an unambiguous filename (a
        // lockfile, a Dockerfile) always wins over a generic extension
        // rule, and structural directory conventions (migrations, infra,
        // tests) are checked before the broad language-by-extension pass.
        if isLockfile(filename: filename, lowerFilename: lowerFilename) { return .lockfile }
        if isGenerated(lowerPath: lowerPath, lowerFilename: lowerFilename) { return .generated }
        if isMigration(lowerPath: lowerPath, lowerFilename: lowerFilename) { return .migration }
        if isInfra(lowerPath: lowerPath, filename: filename, ext: ext) { return .infra }
        if isTest(lowerPath: lowerPath, lowerFilename: lowerFilename) { return .test }
        if isDocs(lowerPath: lowerPath, filename: filename, ext: ext) { return .docs }
        if isConfig(filename: filename, ext: ext) { return .config }
        if let source = sourceCategory(lowerPath: lowerPath, ext: ext) { return source }
        return .other
    }

    private static let lockfileNames: Set<String> = [
        "Package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "Podfile.lock", "Gemfile.lock", "Cargo.lock", "composer.lock", "poetry.lock",
        "Pipfile.lock", "go.sum", "mix.lock", "flake.lock",
    ]

    private static func isLockfile(filename: String, lowerFilename: String) -> Bool {
        lockfileNames.contains(filename) || lowerFilename.hasSuffix(".lock")
    }

    private static func isGenerated(lowerPath: String, lowerFilename: String) -> Bool {
        if lowerPath.contains("__snapshots__") { return true }
        if lowerPath.hasPrefix("generated/") || lowerPath.contains("/generated/") { return true }
        if lowerFilename.contains("generated") { return true }
        if lowerFilename.hasSuffix(".pb.go") || lowerFilename.hasSuffix(".pb.cc") || lowerFilename.hasSuffix(".pb.h") { return true }
        if lowerFilename.hasSuffix("_pb2.py") || lowerFilename.hasSuffix("_pb2_grpc.py") { return true }
        if lowerFilename.hasSuffix(".g.dart") { return true }
        if lowerFilename.hasSuffix(".min.js") || lowerFilename.hasSuffix(".min.css") { return true }
        if lowerPath.contains("/dist/") || lowerPath.hasPrefix("dist/") { return true }
        if lowerPath.contains("/build/") || lowerPath.hasPrefix("build/") { return true }
        if lowerPath.contains("/.next/") || lowerPath.contains("/out/") { return true }
        return false
    }

    private static func isMigration(lowerPath: String, lowerFilename: String) -> Bool {
        if lowerPath.hasPrefix("migrations/") || lowerPath.contains("/migrations/") { return true }
        if lowerPath.contains("/migrate/") { return true } // Rails-style db/migrate
        if lowerPath.contains("alembic") && lowerPath.contains("/versions/") { return true }
        // Timestamp-prefixed SQL migration filenames, e.g. "20230501120000_add_x.sql".
        if lowerFilename.hasSuffix(".sql"), lowerFilename.range(of: #"^\d{4,}[-_]"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static let infraExactNames: Set<String> = ["Dockerfile", "Makefile", "Jenkinsfile", "Vagrantfile", "Procfile"]

    private static func isInfra(lowerPath: String, filename: String, ext: String) -> Bool {
        if infraExactNames.contains(filename) || filename.hasPrefix("Dockerfile.") { return true }
        if lowerPath.hasPrefix(".github/") || lowerPath.contains("/.github/") { return true }
        if lowerPath.hasPrefix(".circleci/") || lowerPath.hasPrefix(".gitlab-ci") { return true }
        if lowerPath.hasSuffix("docker-compose.yml") || lowerPath.hasSuffix("docker-compose.yaml") { return true }
        if ext == "tf" || ext == "tfvars" { return true }
        if lowerPath.contains("/k8s/") || lowerPath.contains("/helm/") || lowerPath.contains("/terraform/") { return true }
        if lowerPath.contains("/workflows/"), ext == "yml" || ext == "yaml" { return true }
        return false
    }

    private static func isTest(lowerPath: String, lowerFilename: String) -> Bool {
        if lowerPath.hasPrefix("test/") || lowerPath.contains("/test/") { return true }
        if lowerPath.hasPrefix("tests/") || lowerPath.contains("/tests/") { return true }
        if lowerPath.contains("__tests__") { return true }
        if lowerPath.hasPrefix("spec/") || lowerPath.contains("/spec/") { return true }
        if lowerFilename.hasSuffix("_test.go") || lowerFilename.hasSuffix("_test.py") { return true }
        if lowerFilename.hasPrefix("test_"), lowerFilename.hasSuffix(".py") { return true }
        for suffix in [".test.ts", ".test.tsx", ".test.js", ".test.jsx", ".spec.ts", ".spec.tsx", ".spec.js", ".spec.jsx"] {
            if lowerFilename.hasSuffix(suffix) { return true }
        }
        for suffix in ["tests.swift", "test.swift", "test.java", "tests.java", "test.kt", "tests.kt"] {
            if lowerFilename.hasSuffix(suffix) { return true }
        }
        if lowerFilename.hasSuffix("_spec.rb") || lowerFilename == "spec_helper.rb" { return true }
        return false
    }

    private static let docsExactNames: Set<String> = [
        "README", "README.md", "CHANGELOG", "CHANGELOG.md", "LICENSE", "LICENSE.md",
        "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "NOTICE",
    ]

    private static func isDocs(lowerPath: String, filename: String, ext: String) -> Bool {
        if docsExactNames.contains(filename) { return true }
        if ["md", "mdx", "rst", "adoc"].contains(ext) { return true }
        if lowerPath.hasPrefix("docs/") || lowerPath.contains("/docs/") { return true }
        return false
    }

    private static let configExactNames: Set<String> = [
        "package.json", "tsconfig.json", "tsconfig.base.json", ".eslintrc", ".eslintrc.json",
        ".eslintrc.js", ".prettierrc", ".editorconfig", "pyproject.toml", "setup.cfg",
        "requirements.txt", "Gemfile", "go.mod", "Cargo.toml", "composer.json",
        "build.gradle", "build.gradle.kts", "pom.xml", "project.yml", ".npmrc", ".nvmrc",
        "Rakefile", "Package.swift", "Podfile",
    ]

    private static func isConfig(filename: String, ext: String) -> Bool {
        if configExactNames.contains(filename) { return true }
        if filename.hasPrefix(".env") { return true }
        return ["json", "yaml", "yml", "toml", "ini", "cfg", "properties", "plist"].contains(ext)
    }

    private static let frontendExtensions: Set<String> = [
        "tsx", "jsx", "vue", "svelte", "css", "scss", "sass", "less", "html", "htm",
    ]
    private static let backendExtensions: Set<String> = [
        "go", "java", "kt", "kts", "py", "rb", "php", "cs", "ex", "exs", "erl",
    ]
    private static let genericSourceExtensions: Set<String> = [
        "swift", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "sql", "sh", "bash", "zsh",
    ]

    /// JS/TS has no fixed home ecosystem, so a path convention (component
    /// directories vs. a server/api directory) decides frontend vs. backend
    /// before falling back to generic `source`.
    private static func sourceCategory(lowerPath: String, ext: String) -> FileCategory? {
        if frontendExtensions.contains(ext) { return .frontend }
        if ["ts", "js", "mjs", "cjs"].contains(ext) {
            if lowerPath.contains("/components/") || lowerPath.contains("/pages/")
                || lowerPath.contains("/views/") || lowerPath.contains("frontend/")
                || lowerPath.contains("client/") || lowerPath.contains("web/") {
                return .frontend
            }
            if lowerPath.contains("server/") || lowerPath.contains("backend/") || lowerPath.contains("api/") {
                return .backend
            }
            return .source
        }
        if backendExtensions.contains(ext) { return .backend }
        if genericSourceExtensions.contains(ext) { return .source }
        return nil
    }
}
