# ADR-0007: Expire regenerable state after seven days and retain human drafts

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

Managed mirrors, PR snapshots, file bodies, and AI transcripts can consume substantial disk. They are regenerable from GitHub or the configured agent. Human review drafts are user-created work and must not be treated as cache.

## Decision

- Use a sliding seven-day TTL based on the last explicit open of the associated project, branch, or PR.
- Background polling does not reset the TTL.
- Expire managed Git mirrors, detailed PR/file/discussion cache, ACP sessions/transcripts, structured AI results, and learned preference context.
- Apply a 5 GiB default budget to regenerable cache. If exceeded, prune least-recently-opened cache groups before their seven-day maximum age.
- Persist the project watchlist, personal PR status, preferences, and lightweight identifiers until explicit removal.
- Persist human-authored drafts until submission or explicit discard.
- When heavy context expires, retain each draft's original head SHA, semantic anchor, surrounding-context fingerprint, and text so reopening can rebuild context and attempt re-anchoring.
- Separate durable application data from regenerable platform cache directories.

## Consequences

### Positive

- Disk use naturally follows projects the reviewer actively opens.
- Reopening an expired project remains deterministic because GitHub is authoritative.
- Cache cleanup cannot destroy unsent human work.

### Negative

- Opening an expired PR requires network access and reconstruction before complete review.
- Watchlist metadata and protected drafts need separate cleanup and storage reporting.
- An actively opened large project may need to refetch older content sooner when the cache budget is reached.

## References

- [Apple application data and cache guidance](https://developer.apple.com/documentation/uikit/performing-one-time-setup-for-your-app)
- [Microsoft application and user data guidance](https://learn.microsoft.com/en-us/windows/apps/develop/data/store-and-retrieve-app-data)
