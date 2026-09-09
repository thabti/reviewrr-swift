import SwiftUI

struct AIAnalysisFailureView: View {
    @ObservedObject var model: AIModel
    let message: String
    @State private var showDetails = false
    @Environment(\.openSettingsPane) private var openSettings

    private var isTimeout: Bool {
        let text = message.lowercased()
        return text.contains("timeout") || text.contains("timed out") || text.contains("did not answer") || text.contains("stopped waiting")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isTimeout ? "Analysis timed out" : "Analysis couldn’t finish",
                  systemImage: isTimeout ? "clock.badge.exclamationmark" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(isTimeout
                 ? "The agent stopped responding before the analysis finished. Try again, or increase the agent idle timeout in AI Settings for a longer run."
                 : "Review the error details below. You can retry the analysis or check your provider configuration in AI Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { retryButton; settingsButton }
                VStack(alignment: .leading) { retryButton; settingsButton }
            }
            DisclosureGroup("Error Details", isExpanded: $showDetails) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
    }

    private var retryButton: some View {
        Button { Task { await model.analyze(force: true) } } label: {
            Label("Retry Analysis", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isAnalyzing)
        .help(model.isAnalyzing ? "An analysis is already running" : "Send this pull request to the provider again")
        .accessibilityLabel("Retry the analysis")
    }

    private var settingsButton: some View {
        // The settings screen, not a sheet of its own: a 560×640 panel over
        // the failure it is meant to fix was both smaller than the pane needs
        // and a second place the same settings live.
        Button { openSettings(.ai) } label: {
            Label("AI Settings", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
        .help("Change the provider, model, or credentials")
        .accessibilityLabel("Open AI settings")
    }
}
