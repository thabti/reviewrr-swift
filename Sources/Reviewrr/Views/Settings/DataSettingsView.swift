import AppKit
import SwiftUI

/// Everything Reviewrr keeps on this Mac, and how to remove it.
///
/// The pane lists each store separately because they are not equivalent.
/// Drafts are unsent human work — comments a reviewer wrote and has not
/// submitted — and deleting them destroys something no one can get back.
/// The AI caches are re-derivable: clearing them costs a provider call, not
/// a reviewer's thinking. Offering one button for both would have made the
/// cheap action carry the expensive action's warning, or the expensive one
/// carry the cheap one's ease.
struct DataSettingsView: View {
    @State private var stores: [Store] = []
    @State private var statusMessage: String?
    @State private var confirmingClearDrafts = false

    /// One directory on disk, as the pane presents it.
    private struct Store: Identifiable {
        var id: String { name }
        var name: String
        var directory: String
        var summary: String
        var byteCount: Int64

        var url: URL { Self.support.appendingPathComponent(directory, isDirectory: true) }

        static let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reviewrr", isDirectory: true)

        static let all: [Store] = [
            Store(
                name: "Drafts", directory: "drafts",
                summary: "Comments, review summaries, and viewed-file marks you have written but not submitted.",
                byteCount: 0
            ),
            Store(
                name: "Analyses", directory: "ai-analysis",
                summary: "Cached AI analyses, so reopening an unchanged revision costs no provider call.",
                byteCount: 0
            ),
            Store(
                name: "AI sessions", directory: "ai-sessions",
                summary: "Ask transcripts, and which findings you already drafted or set aside.",
                byteCount: 0
            ),
        ]
    }

    var body: some View {
        Form {
            Section {
                ForEach(stores) { store in
                    LabeledContent(store.name) {
                        HStack(spacing: Theme.Space.s) {
                            Text(store.byteCount == 0 ? "Empty" : Self.formatted(store.byteCount))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button("Reveal") { reveal(store) }
                                .help("Show this folder in Finder")
                                .controlSize(.small)
                                .accessibilityLabel("Reveal \(store.name) in Finder")
                        }
                    }
                    // Combined for reading, with the button offered as an
                    // action — a second `accessibilityLabel` on the button
                    // was also silently overriding the first.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(store.name), \(store.byteCount == 0 ? "empty" : Self.formatted(store.byteCount))")
                    .accessibilityAction(named: "Reveal in Finder") { reveal(store) }
                }
            } header: {
                Text("On this Mac")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(stores) { store in
                        Text("**\(store.name)** — \(store.summary)")
                    }
                }
            }

            Section {
                Button("Clear AI caches") { clearAICaches() }
                    .help("Delete stored analyses. Nothing on GitHub changes, and analyses can be run again.")
                    .accessibilityLabel("Clear stored AI analyses")
                    .accessibilityHint("Deletes cached analyses and Ask transcripts. Your drafts are not affected.")
            } header: {
                Text("Reset AI state")
            } footer: {
                Text("Analyses are re-derived on the next run and transcripts start fresh. Nothing you wrote is removed.")
            }

            Section {
                Button("Clear All Drafts…", role: .destructive) { confirmingClearDrafts = true }
                    .help("Delete every unsent draft comment on this Mac. This cannot be undone.")
                    .accessibilityLabel("Clear all draft comments")
                    .accessibilityHint("Asks for confirmation first")
                    .accessibilityHint("Deletes every saved draft comment, summary, and viewed mark for every pull request.")
                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .motionTransition(.opacity)
                }
            } header: {
                Text("Reset drafts")
            } footer: {
                Text("Deletes every locally saved draft comment, review summary, and viewed-file mark, for every pull request. This cannot be undone. Anything already submitted to GitHub is unaffected.")
            }
        }
        .formStyle(.grouped)
        .motion(Motion.smooth, value: statusMessage)
        .task { refreshSizes() }
        // An irreversible, all-pull-requests deletion earns a confirmation
        // step — the destructive button alone isn't enough friction for
        // something this final and this broad.
        .confirmationDialog(
            "Clear all local drafts?",
            isPresented: $confirmingClearDrafts,
            titleVisibility: .visible
        ) {
            Button("Clear All Drafts", role: .destructive) { clearDrafts() }
                .help("Delete every unsent draft comment on this Mac")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every draft comment, review summary, and viewed-file mark for every pull request on this Mac. It cannot be undone, and nothing already submitted to GitHub is affected.")
        }
    }

    // MARK: - Actions

    private func reveal(_ store: Store) {
        try? FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    private func clearAICaches() {
        var removed = 0
        for store in stores where store.directory != "drafts" {
            removed += removeJSON(in: store.url)
        }
        statusMessage = removed == 0 ? "No cached AI state to clear." : "Cleared \(removed) cached file(s)."
        refreshSizes()
    }

    private func clearDrafts() {
        guard let drafts = stores.first(where: { $0.directory == "drafts" }) else { return }
        let removed = removeJSON(in: drafts.url)
        statusMessage = removed == 0 ? "No drafts to clear." : "Cleared \(removed) draft file(s)."
        refreshSizes()
    }

    /// Only `.json` files, never the directory: another part of the app may
    /// hold the folder open, and removing the container out from under it is
    /// a worse failure than leaving an empty folder behind.
    private func removeJSON(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .reduce(into: 0) { total, file in
                if (try? FileManager.default.removeItem(at: file)) != nil { total += 1 }
            }
    }

    private func refreshSizes() {
        stores = Store.all.map { store in
            var sized = store
            sized.byteCount = Self.size(of: store.url)
            return sized
        }
    }

    private static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(into: 0) { total, file in
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
    }

    private static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
