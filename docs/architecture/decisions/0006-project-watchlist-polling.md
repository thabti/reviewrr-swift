# ADR-0006: Use a watched-project inbox with in-process polling

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

The target reviewer usually follows three to five projects. They need visibility across those projects while focusing on one PR at a time. A single-repository start screen would hide relevant activity, while a permanent background daemon would add lifecycle, privacy, packaging, and resource complexity.

## Decision

- Persist a project watchlist until the reviewer explicitly removes entries.
- Accept projects from recent items, a local folder, or a pasted GitHub project/PR URL.
- Show a combined inbox grouped by project, with projects ordered by last explicit open and PRs by latest GitHub activity.
- Retain open, draft, closed, and merged PR metadata and distinguish them with state badges and filters.
- Poll lightweight PR summaries for all watched projects only while the Wails process is running.
- Render cached results first, then stagger refreshes with jitter, coalescing, and rate-limit backoff.
- Default to a five-minute interval per project with ±20% jitter and exponential failure/rate-limit backoff capped at 30 minutes.
- Group alerts by project; keep in-app indicators enabled, make native notifications opt-in, and suppress notifications and attention counts for locally ignored PRs.

## Consequences

### Positive

- Reviewers get one launch point for their normal project set.
- The app remains useful before the first network refresh completes.
- No helper process consumes resources or accesses GitHub while the application is closed.

### Negative

- New PRs are not discovered while Reviewrr is closed.
- Polling must coordinate several repositories without wasting GitHub rate limits.
- All-state history requires strong filtering and virtualization as metadata grows.

## Revisit when

- Users explicitly request menu-bar/background notifications.
- Organization-scale project counts make polling impractical.
