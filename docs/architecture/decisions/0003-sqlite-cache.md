# ADR-0003: Use SQLite as a local cache and durable draft store

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

GitHub connectivity, rate limits, and large PR payloads make a network-only UI slow and fragile. Reviewrr also needs drafts and local viewed state to survive restarts. A hosted database is incompatible with the local-first single-user MVP.

## Decision

Use one per-user SQLite database owned exclusively by the Go host.

- GitHub-derived rows form a rebuildable local read model with seven-day heavy-content retention.
- Draft comments, project watchlist references, personal PR status, preferences, and viewed state are locally authoritative.
- Embedded, forward-only migrations run at startup.
- Enable foreign keys, WAL mode, and a busy timeout.
- Replace synchronized aggregates transactionally only after all required pages succeed.
- Store managed bare/partial Git mirrors, large file bodies, and disposable ACP context in a bounded platform cache referenced by content hash.
- Never apply automatic cache expiry to unsent human drafts.

Prefer a pure-Go SQLite driver for simpler cross-platform packaging, subject to the Milestone 0 compatibility proof.

## Consequences

### Positive

- Cached-first screens remain fast and useful offline.
- Human drafts survive GitHub and ACP failures.
- SQL constraints and transactions support consistent aggregate replacement.
- No database service needs installation or operation.

### Negative

- Schema migrations and corruption recovery become product responsibilities.
- Cached state can be stale and must always expose freshness.
- Managed mirrors, large diffs, and file content need retention and disk-budget policies.

## Recovery rules

- Run an integrity check when corruption is suspected, not on every launch.
- Offer a rebuild that preserves/export drafts before replacing the cache.
- Never clear drafts as part of ordinary synchronization or cache pruning.
- Expire regenerable mirrors, PR detail, ACP transcripts/results, and feedback memory seven days after last explicit project/branch/PR access; polling does not extend the TTL.
- Keep the last complete snapshot when a refresh fails.

## Revisit when

- Multi-device or team-shared review state becomes a product requirement.
- Data size or query load exceeds a bounded single-user desktop profile.
