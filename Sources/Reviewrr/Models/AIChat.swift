import Foundation

enum ChatRole: String, Codable {
    case system, user, assistant
}

struct ChatMessage: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    let role: ChatRole
    var content: String
    /// Set once a streaming assistant reply finishes, so the UI can stop
    /// showing a typing indicator on this specific bubble.
    var isStreaming: Bool = false
    var taggedFiles: [String]?

    enum CodingKeys: String, CodingKey { case id, role, content, isStreaming, taggedFiles }

    init(role: ChatRole, content: String, isStreaming: Bool = false, taggedFiles: [String]? = nil) {
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.taggedFiles = taggedFiles
    }

    // Backward-compatible decode: older persisted/fixture messages have no
    // `isStreaming` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(ChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        taggedFiles = try container.decodeIfPresent([String].self, forKey: .taggedFiles)
    }
}

/// What an Ask question or answer is scoped to. `.wholePR` and `.file` are
/// the original cases and must stay source-compatible; `.selection` is an
/// addition for a reviewer-highlighted line range within one file.
/// `Hashable` so it can back a SwiftUI `Picker` selection directly.
enum AIScope: Hashable {
    case wholePR
    case file(String)
    case files([String])
    case selection(path: String, startLine: Int, endLine: Int)

    var label: String {
        switch self {
        case .wholePR: return "Whole PR"
        case .files(let paths): return "\(paths.count) files"
        case .file(let name): return (name as NSString).lastPathComponent
        case .selection(let path, let start, let end):
            let name = (path as NSString).lastPathComponent
            return start == end ? "\(name):\(start)" : "\(name):\(start)-\(end)"
        }
    }

    /// The file path this scope is anchored to, if any — used to bound the
    /// context Reviewrr sends for the question.
    var paths: [String] {
        switch self {
        case .wholePR: return []
        case .files(let paths): return paths
        case .file(let path), .selection(let path, _, _): return [path]
        }
    }

    var path: String? {
        switch self {
        case .wholePR, .files: return nil
        case .file(let path): return path
        case .selection(let path, _, _): return path
        }
    }
}
