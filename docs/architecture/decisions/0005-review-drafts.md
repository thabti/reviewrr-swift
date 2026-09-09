# ADR-0005: Keep drafts local and submit one atomic GitHub review

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

Reviewers need to collect several inline comments before choosing comment, approve, or request changes. Creating remote comments as the user types would produce unwanted notifications, expose incomplete thinking, and complicate recovery. GitHub's create-review API supports a summary and inline comments in one request.

Diff anchors can become invalid when a PR is force-pushed or updated. A timeout during submission can also leave the client uncertain whether GitHub accepted the review.

## Decision

- Store all in-progress review comments locally in SQLite.
- Bind each inline draft to repository, PR number, head SHA, path, line, side, and optional range.
- Store a surrounding-context fingerprint suitable for re-anchoring after a new revision.
- Require explicit user confirmation of destination, review event, summary, and comment count.
- Re-fetch the current head SHA immediately before writing.
- Switch the workspace immediately when the head SHA changes.
- Re-display unique exact contextual matches as carried but unconfirmed, keep ambiguous candidates in previous-revision drafts, and retain deleted/unmatched drafts as orphaned.
- Require explicit confirmation before any carried draft can be submitted; never silently submit a remap.
- Send the summary and comments as one create-review request using `gh api --input -`.
- Clear drafts only after a successful response is reconciled into SQLite.
- After an ambiguous timeout, search recent reviews for a matching reviewer, head SHA, time window, and content fingerprint before permitting retry.

## Consequences

### Positive

- Incomplete thoughts remain private and recoverable.
- GitHub receives one coherent review and notification event.
- Stale line comments cannot be accidentally applied to a new revision.
- ACP suggestions remain outside the write path until the reviewer edits them.

### Negative

- Drafts are available only on the current device in phase one.
- A force push may require manual re-anchoring when contextual matching is ambiguous.
- Timeout reconciliation adds logic and still needs an honest uncertain state when evidence is inconclusive.

## Revisit when

- Cross-device drafts or collaboration become requirements.
- GitHub adds a stable draft-review synchronization contract that improves recovery without premature notifications.

## References

- [GitHub pull-request reviews REST API](https://docs.github.com/en/rest/pulls/reviews)
