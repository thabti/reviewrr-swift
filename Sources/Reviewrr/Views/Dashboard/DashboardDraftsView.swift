import SwiftUI

/// Local work stays visible independently of inbox filters and GitHub sync.
struct DashboardDraftsView: View {
    let reviews: [DashboardReviewDraft]
    let onResume: (PRReference) -> Void
    var onClear: ([PRReference]) -> Void = { _ in }
    var clearError: String?
    @State private var pendingClear: [PRReference] = []
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Continue Reviewing", systemImage: "square.and.pencil")
                    .font(.headline)
                Text("\(reviews.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("Local drafts · Not submitted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear All…", role: .destructive) {
                    pendingClear = reviews.map(\.reference)
                    showClearConfirmation = true
                }
                .disabled(reviews.isEmpty)
                .help("Clear all local draft reviews")
            }
            if let clearError {
                Label(clearError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if reviews.isEmpty {
                EmptyStateView(
                    systemImage: "square.and.pencil",
                    title: "No reviews in progress",
                    message: "Open a pull request to start reviewing. Your comments, summary, and viewed files save automatically on this Mac."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(reviews) { review in
                            HStack(spacing: 4) {
                            Button { onResume(review.reference) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(review.draft.title ?? review.reference.key)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        Text("\(review.reference.key) · \((review.draft.comments.count + (review.draft.pendingComments?.count ?? 0))) comments · \(review.draft.viewedFiles.count) files viewed")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if !review.draft.summary.isEmpty {
                                            Text(review.draft.summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if let date = review.draft.savedAt {
                                        Text(date, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .help("Last saved \(date.formatted())")
                                    }
                                    Label("Resume", systemImage: "chevron.right")
                                        .font(.callout)
                                        .foregroundStyle(Theme.accent)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Resume review: \(review.reference.key), \(review.draft.title ?? ""), \((review.draft.comments.count + (review.draft.pendingComments?.count ?? 0))) draft comments")
                            Button(role: .destructive) {
                                pendingClear = [review.reference]
                                showClearConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .padding(.trailing, 12)
                            .help("Clear draft review for \(review.reference.key)")
                            .accessibilityLabel("Clear draft review for \(review.reference.key)")
                            }
                            if review.id != reviews.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert(pendingClear.count == 1 ? "Clear this draft review?" : "Clear \(pendingClear.count) draft reviews?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { pendingClear = [] }
            Button("Clear Drafts", role: .destructive) {
                onClear(pendingClear)
                pendingClear = []
            }
        } message: {
            Text("This removes local comments, unfinished replies, the review summary, and viewed-file progress. It cannot be undone. GitHub comments and submitted reviews are unchanged.")
        }
    }
}
