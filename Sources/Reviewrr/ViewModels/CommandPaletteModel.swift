import Foundation

/// State for the ⌘K palette: the query, the ranked results, the highlighted
/// row, and which commands were run recently.
///
/// Holds no view code and no `AppModel` reference — commands arrive through
/// `provider`, so the palette can be driven by a fixture in tests.
@MainActor
final class CommandPaletteModel: ObservableObject {
    @Published var query: String = "" {
        didSet { if query != oldValue { rank() } }
    }
    @Published private(set) var results: [PaletteCommand] = []
    @Published var selectionIndex: Int = 0

    /// Supplies the current command set. Re-invoked every time the palette
    /// opens because half the commands describe live content.
    var provider: @MainActor () -> [PaletteCommand] = { [] }

    private var allCommands: [PaletteCommand] = []
    private(set) var recentIDs: [String] = []

    private static let recentsKey = "reviewrr.palette.recents"
    private static let maxRecents = 8

    init() {
        recentIDs = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Called when the palette appears. Resets the query so ⌘K is always the
    /// same gesture — reopening into a stale search is a small betrayal of
    /// muscle memory.
    ///
    /// `query`'s own `didSet` already re-ranks on a real change, so setting
    /// it to "" unconditionally here would double-rank the freshly fetched
    /// `allCommands` whenever the palette was left with text typed in it —
    /// `didSet` fires once for the reset, then this function would rank
    /// again. Ranking explicitly only in the branch where `didSet` can't
    /// fire (the query was already empty) keeps this to one `rank()` call
    /// either way.
    func open() {
        allCommands = provider()
        if query.isEmpty {
            rank()
        } else {
            query = ""
        }
    }

    func close() {
        // Clearing `allCommands` before `query` means any `didSet`-triggered
        // rank (when the palette closes with text still in the field) has
        // nothing to rank — cheap even though the empty-query path itself
        // is already just a sort, not a re-score.
        allCommands = []
        query = ""
        results = []
        selectionIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        // Wraps, because a palette is a short list and hitting the end is a
        // dead end otherwise.
        selectionIndex = (selectionIndex + delta + results.count) % results.count
    }

    var selectedCommand: PaletteCommand? {
        guard results.indices.contains(selectionIndex) else { return nil }
        return results[selectionIndex]
    }

    /// Runs the highlighted command. Returns false when there is nothing to
    /// run or it is disabled, so the caller can keep the palette open rather
    /// than dismissing on a no-op.
    @discardableResult
    func runSelected() -> Bool {
        guard let command = selectedCommand, command.isEnabled else { return false }
        remember(command.id)
        command.run()
        return true
    }

    @discardableResult
    func run(_ command: PaletteCommand) -> Bool {
        guard command.isEnabled else { return false }
        remember(command.id)
        command.run()
        return true
    }

    /// Results grouped for display, preserving rank order within each group
    /// and ordering groups by where their best result placed.
    var groupedResults: [(group: PaletteCommand.Group, commands: [PaletteCommand])] {
        var order: [PaletteCommand.Group] = []
        var buckets: [PaletteCommand.Group: [PaletteCommand]] = [:]
        for command in results {
            if buckets[command.group] == nil { order.append(command.group) }
            buckets[command.group, default: []].append(command)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func rank() {
        results = CommandMatcher.rank(allCommands, query: query, recentIDs: recentIDs)
        selectionIndex = 0
    }

    private func remember(_ id: String) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > Self.maxRecents { recentIDs = Array(recentIDs.prefix(Self.maxRecents)) }
        UserDefaults.standard.set(recentIDs, forKey: Self.recentsKey)
    }
}
