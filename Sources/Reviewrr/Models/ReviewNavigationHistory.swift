import Foundation

struct ReviewNavigationHistory {
    enum Destination: Equatable {
        case dashboard
        case demo
        case pullRequest(PRReference, ForgeHost)
    }

    private(set) var entries: [Destination] = [.dashboard]
    private(set) var index = 0
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    mutating func visit(_ destination: Destination) {
        guard entries[index] != destination else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(destination)
        if entries.count > 100 { entries.removeFirst() }
        index = entries.count - 1
    }

    func destination(offset: Int) -> Destination? {
        let target = index + offset
        guard entries.indices.contains(target) else { return nil }
        return entries[target]
    }

    mutating func commit(offset: Int) {
        guard destination(offset: offset) != nil else { return }
        index += offset
    }
}
