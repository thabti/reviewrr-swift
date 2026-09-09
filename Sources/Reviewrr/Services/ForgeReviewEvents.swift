import Foundation

/// One review outcome, described as the forge in front of the reviewer can
/// actually perform it.
///
/// GitHub's three events are not GitLab's. GitLab has approval and the
/// absence of approval: there is no rejection object, and nothing a review
/// can do to hold a merge. The submit form offered GitHub's three verbatim
/// to both forges, so a GitLab reviewer picked "Request changes", read
/// *"Blocks merging until changes are made"* in red, submitted, saw success —
/// and watched the merge request merge an hour later. All that had happened
/// was the comments being published and the reviewer's own approval
/// withdrawn, which is the most GitLab can be asked for.
///
/// The wording is the fix, so it lives in this layer rather than in the
/// form: here the claims are unit-testable, and one source keeps the
/// segment, the submit button, its tooltip and its accessibility label from
/// drifting apart the way three copies of the same sentence do.
struct ForgeReviewAction: Equatable, Identifiable {
    /// What is sent, and what a draft persists. GitHub's vocabulary is the
    /// wire vocabulary because the domain models are GitHub-shaped; the
    /// GitLab client maps it (see `GitLabClient.submitReview`).
    let event: ReviewEvent
    /// The picker's segment, and the submit button.
    let label: String
    /// The line under the picker: what pressing the button does, and where
    /// this forge stops being able to do it.
    let detail: String
    let systemImage: String
    let emphasis: Emphasis
    /// A whole sentence, for the tooltip and the accessibility label.
    /// `"\(label) this merge request"` does not survive a label that is
    /// already a verb phrase — "Revoke approval this merge request".
    let actionDescription: String

    var id: String { event.rawValue }

    /// How much weight the choice carries. Not a `Color`: this type compiles
    /// into the test bundle, where the wording is asserted, and the mapping
    /// to a colour is the form's business.
    ///
    /// `blocking` is a claim about the *forge*, not about how strongly the
    /// reviewer disagrees — it means "this stops a merge", and only GitHub
    /// has an event that does.
    enum Emphasis: Equatable {
        case neutral
        case affirmative
        case blocking
        case caution
    }
}

extension ForgeReviewAction {
    /// Every outcome this forge can perform, in the order the picker shows
    /// them.
    ///
    /// Built from `ReviewEvent.allCases` so a new event cannot be added
    /// without deciding what it means on both forges — the previous
    /// `ForEach(ReviewEvent.allCases)` in the form is exactly how GitHub's
    /// three ended up being offered to GitLab unexamined.
    static func all(on forge: Forge) -> [ForgeReviewAction] {
        ReviewEvent.allCases.map { action(for: $0, on: forge) }
    }

    static func action(for event: ReviewEvent, on forge: Forge) -> ForgeReviewAction {
        switch forge {
        case .github: return githubAction(for: event)
        case .gitlab: return gitLabAction(for: event)
        }
    }

    private static func githubAction(for event: ReviewEvent) -> ForgeReviewAction {
        switch event {
        case .comment:
            return ForgeReviewAction(
                event: .comment,
                label: "Comment",
                detail: "Leaves feedback without approving or blocking.",
                systemImage: "bubble.left",
                emphasis: .neutral,
                actionDescription: "Comment on this pull request"
            )
        case .approve:
            return ForgeReviewAction(
                event: .approve,
                label: "Approve",
                detail: "Approves the pull request as ready to merge.",
                systemImage: "checkmark.seal.fill",
                emphasis: .affirmative,
                actionDescription: "Approve this pull request"
            )
        case .requestChanges:
            return ForgeReviewAction(
                event: .requestChanges,
                label: "Request changes",
                detail: "Blocks merging until changes are made.",
                systemImage: "exclamationmark.triangle.fill",
                emphasis: .blocking,
                actionDescription: "Request changes on this pull request"
            )
        }
    }

    /// GitLab's side, and the reason this type exists.
    ///
    /// `.requestChanges` is kept as the *selector* for the third segment
    /// rather than dropped, for two reasons. A reviewer who has approved
    /// needs some way to take that back, and withdrawing an approval is the
    /// only thing GitLab records as "not from me". And a draft saved with
    /// `event == .requestChanges` — written on a GitHub host, or before this
    /// change — would otherwise select a segment the picker no longer shows,
    /// which SwiftUI renders as a segmented control with nothing selected
    /// while the submit button still sends the event.
    ///
    /// So the segment stays and stops lying: GitLab's own word for what
    /// happens, and one sentence naming the mechanism the reviewer was
    /// reaching for and cannot have.
    private static func gitLabAction(for event: ReviewEvent) -> ForgeReviewAction {
        switch event {
        case .comment:
            return ForgeReviewAction(
                event: .comment,
                label: "Comment",
                detail: "Leaves feedback without approving the merge request.",
                systemImage: "bubble.left",
                emphasis: .neutral,
                actionDescription: "Comment on this merge request"
            )
        case .approve:
            return ForgeReviewAction(
                event: .approve,
                label: "Approve",
                detail: "Approves the merge request as ready to merge.",
                systemImage: "checkmark.seal.fill",
                emphasis: .affirmative,
                actionDescription: "Approve this merge request"
            )
        case .requestChanges:
            return ForgeReviewAction(
                event: .requestChanges,
                label: "Revoke approval",
                // "Reviewrr cannot block a merge" rather than "GitLab
                // cannot": what a *review* can do to a merge depends on the
                // instance's version and tier, and this sentence has to be
                // true on all of them. What it describes is the button the
                // reviewer is about to press, which is the claim that
                // matters and the one the app can stand behind.
                detail: """
                    Publishes your comments and takes back your approval if you gave one. \
                    Reviewrr cannot block a merge on GitLab — to hold this merge request, \
                    mark it as a draft there.
                    """,
                systemImage: "arrow.uturn.backward",
                emphasis: .caution,
                actionDescription: "Publish your comments and revoke your approval of this merge request"
            )
        }
    }
}
