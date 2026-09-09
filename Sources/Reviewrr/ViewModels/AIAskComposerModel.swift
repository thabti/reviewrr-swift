import Foundation

@MainActor
final class AIAskComposerModel: ObservableObject {
    @Published var text = ""
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var taggedPaths: [String] = []
    @Published var selectedIndex = 0
    @Published var dismissed = false
    @Published var focusRequest = 0
    @Published var paths: [String] = []

    var mentionRange: NSRange? {
        guard !dismissed, selection.length == 0 else { return nil }
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let prefix = ns.substring(to: caret) as NSString
        let at = prefix.range(of: "@", options: .backwards)
        guard at.location != NSNotFound else { return nil }
        if at.location > 0 {
            let previous = prefix.substring(with: NSRange(location: at.location - 1, length: 1))
            guard previous.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return nil }
        }
        let query = prefix.substring(from: at.location + 1)
        guard query.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return NSRange(location: at.location, length: caret - at.location)
    }

    var matches: [String] {
        guard let range = mentionRange else { return [] }
        let query = (text as NSString).substring(with: range).dropFirst().lowercased()
        return paths.filter { !taggedPaths.contains($0) && (query.isEmpty || $0.lowercased().contains(query)) }
            .sorted { lhs, rhs in
                let left = (lhs as NSString).lastPathComponent.lowercased().hasPrefix(query)
                let right = (rhs as NSString).lastPathComponent.lowercased().hasPrefix(query)
                return left == right ? lhs.localizedStandardCompare(rhs) == .orderedAscending : left
            }
    }

    var scope: AIScope { taggedPaths.isEmpty ? .wholePR : .files(taggedPaths) }

    func update(text: String, selection: NSRange) {
        if self.text != text || self.selection != selection {
            dismissed = false
            selectedIndex = 0
        }
        self.text = text
        self.selection = selection
    }

    func choose(_ path: String) {
        guard paths.contains(path), let range = mentionRange else { return }
        if !taggedPaths.contains(path) { taggedPaths.append(path) }
        text = (text as NSString).replacingCharacters(in: range, with: "")
        selection = NSRange(location: range.location, length: 0)
        selectedIndex = 0
        focusRequest += 1
    }

    func showPicker() {
        let ns = text as NSString
        let caret = min(selection.location, ns.length)
        let separator = caret > 0 && ns.substring(with: NSRange(location: caret - 1, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " : ""
        let insertion = separator + "@"
        text = ns.replacingCharacters(in: NSRange(location: caret, length: min(selection.length, ns.length - caret)), with: insertion)
        selection = NSRange(location: caret + insertion.utf16.count, length: 0)
        dismissed = false
        selectedIndex = 0
        focusRequest += 1
    }

    func handle(_ command: String) -> Bool {
        guard mentionRange != nil else { return false }
        switch command {
        case "cancelOperation:": dismissed = true
        case "moveUp:": selectedIndex = max(0, selectedIndex - 1)
        case "moveDown:": selectedIndex = min(max(0, matches.count - 1), selectedIndex + 1)
        case "insertNewline:", "insertTab:":
            if matches.indices.contains(selectedIndex) { choose(matches[selectedIndex]) }
        default: return false
        }
        return true
    }

    func reset() {
        text = ""
        selection = NSRange(location: 0, length: 0)
        taggedPaths = []
        dismissed = false
        selectedIndex = 0
    }
}
