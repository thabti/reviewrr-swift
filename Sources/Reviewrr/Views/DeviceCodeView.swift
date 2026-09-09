import SwiftUI

/// The device code itself, at a size a reviewer can read across the room
/// while they type it into a browser, plus a countdown so an expiring code
/// never fails silently — GitHub gives this code a hard, short lifetime.
///
/// Shared by the sign-in screen and Settings' Account pane. Both show the
/// same code from the same state machine, and two copies of a countdown
/// drift apart the moment one of them is edited.
struct DeviceCodeView: View {
    let code: GitHubDeviceCode
    let onCopy: () -> Void
    let onOpenGitHub: () -> Void
    let onCancel: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(code.userCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Device code")
                .accessibilityValue(code.userCode)

            Text("Enter this code at \(code.verificationURI)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = code.expiresAt.timeIntervalSince(context.date)
                let text = Self.countdown(remaining)
                Label(text, systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining < 60 ? .orange : .secondary)
                    .accessibilityLabel(text)
            }

            HStack(spacing: 8) {
                Button {
                    onCopy()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .motion(Motion.snappy, value: copied)

                Button("Open GitHub", action: onOpenGitHub)
                    .buttonStyle(.borderedProminent)

                Button("Cancel", action: onCancel)

                ProgressView().controlSize(.small)
                    .accessibilityLabel("Waiting for authorization")
            }
        }
    }

    static func countdown(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Expired" }
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "Expires in %d:%02d", minutes, seconds)
    }
}
