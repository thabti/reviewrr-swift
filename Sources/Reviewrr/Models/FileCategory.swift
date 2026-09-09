import SwiftUI

/// Coarse triage bucket for a changed file. Used to hide noise (lockfiles,
/// generated code) by default, to prioritize application code when sorting,
/// and to give the file tree/filter bar a consistent chip vocabulary.
///
/// Raw values are persisted in `AppSettings.hiddenFileCategories`, so they
/// must stay stable once shipped — treat renaming a case as a breaking change.
enum FileCategory: String, Codable, CaseIterable, Equatable, Hashable, Identifiable {
    case source
    case test
    case docs
    case config
    case generated
    case lockfile
    case migration
    case infra
    case frontend
    case backend
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: return "Source"
        case .test: return "Tests"
        case .docs: return "Docs"
        case .config: return "Config"
        case .generated: return "Generated"
        case .lockfile: return "Lockfiles"
        case .migration: return "Migrations"
        case .infra: return "Infra"
        case .frontend: return "Frontend"
        case .backend: return "Backend"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .test: return "checkmark.seal"
        case .docs: return "book"
        case .config: return "gearshape"
        case .generated: return "wand.and.stars"
        case .lockfile: return "lock"
        case .migration: return "cylinder.split.1x2"
        case .infra: return "server.rack"
        case .frontend: return "macwindow"
        case .backend: return "cpu"
        case .other: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .source: return .blue
        case .test: return .green
        case .docs: return .purple
        case .config: return .orange
        case .generated: return .gray
        case .lockfile: return .brown
        case .migration: return .pink
        case .infra: return .indigo
        case .frontend: return .teal
        case .backend: return .cyan
        case .other: return .secondary
        }
    }

    /// Ascending sort key for "category priority" ordering: application code
    /// a reviewer actually needs to judge comes first, structural/support
    /// files next, and pure noise (generated output, lockfiles) last.
    var reviewPriority: Int {
        switch self {
        case .source: return 0
        case .frontend: return 1
        case .backend: return 2
        case .migration: return 3
        case .infra: return 4
        case .config: return 5
        case .test: return 6
        case .docs: return 7
        case .other: return 8
        case .generated: return 9
        case .lockfile: return 10
        }
    }
}
