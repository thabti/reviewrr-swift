# Reviewrr MVP architecture

## Purpose

This document defines the proposed architecture for a greenfield Reviewrr MVP. The repository currently contains design references only; all application boundaries below are planned rather than descriptions of existing code.

Reviewrr is a single-user desktop system built around a small persistent watchlist of projects and one focused PR workspace. Its job is to coordinate three worlds without conflating them:

- Local project folders or Reviewrr-managed Git mirrors, which provide exact PR revision content without a managed working tree.
- GitHub, which remains authoritative for PRs, discussions, checks, and submitted reviews.
- A user-selected ACP coding agent, which provides advisory explanations and findings but cannot publish a review.

## Architecture principles

1. **Human review is authoritative.** AI text is never a GitHub write until the reviewer makes it an editable draft and explicitly submits it.
2. **The source worktree is immutable to Reviewrr.** No checkout, branch update, commit, push, merge, or file edit is part of the application contract.
3. **GitHub credentials stay with `gh`.** Reviewrr invokes `gh`; it never asks for or persists a GitHub token.
4. **SQLite is a cache and local work store.** GitHub data can be rebuilt; human drafts require durable preservation.
5. **External protocols are isolated.** GitHub CLI output, GitHub API data, and ACP messages are normalized before reaching the UI or domain logic.
6. **Freshness is visible.** Cached, refreshing, stale, partial, and failed states are different product states.
7. **Failure is scoped.** A GitHub sync or ACP process failure must not take down repository browsing or lose drafts.
8. **The PR revision is the review unit.** Every diff, discussion anchor, draft, and AI result is bound to an exact head SHA.
9. **Regenerable data expires; human work does not.** Seven-day cleanup can remove mirrors and AI/cache state, never unsent human drafts.

## Runtime shape

The Wails application ships as one desktop executable with embedded frontend assets. At runtime it contains:

- A React/TypeScript WebView application for navigation, diff rendering, discussions, drafts, and ACP output.
- A Go host for all filesystem, subprocess, SQLite, GitHub, diff parsing, and ACP responsibilities.
- A per-user SQLite database under the OS application-data directory.
- Reviewrr-managed bare/partial Git mirrors and disposable revision-scoped review context under the OS cache directory.

External executables remain separate processes:

- `git` is used for read-only local discovery and for fetching/reading Reviewrr-managed bare mirrors. It never updates a user's worktree or refs.
- `gh` authenticates and communicates with GitHub.
- The configured ACP agent communicates with Reviewrr over newline-delimited JSON-RPC on stdio.

## Boundary ownership

| Capability | Owner | Contract |
| --- | --- | --- |
| Native directory picker | Wails/Go host | Returns a user-selected absolute path |
| Project watchlist | Go project service | Persists monitored GitHub project references until explicit removal |
| Repository validation | Go project service | Read-only discovery for user repositories; no ref or worktree mutation |
| Managed Git mirrors | Go mirror service | Creates/fetches bare or partial mirrors in Reviewrr cache storage |
| In-process polling | Go poll scheduler | Staggered summary refreshes only while Reviewrr runs |
| GitHub authentication | `gh` | Reviewrr consumes status and errors, never tokens |
| GitHub reads/writes | Go GitHub gateway via `gh` | Typed request arguments and JSON response normalization |
| Local persistence | Go storage layer | SQLite transactions and embedded migrations |
| Diff interpretation | Go diff service | Canonical file/hunk/line model shared with UI and submissions |
| Desktop UI | React/TypeScript | Calls generated Wails bindings and subscribes to named events |
| Agent process lifecycle | Go ACP manager | Start, initialize, prompt, cancel, stop, and recover |
| Structured AI output | Go AI review pipeline | Prompt/schema versioning, validation, repair, caching, and extension |
| Agent permissions | Go ACP policy | Read-oriented allowlist; write and terminal requests denied |
| GitHub submission intent | Human reviewer | Explicit confirmation of event, summary, and comments |

## Proposed application modules

Names describe logical ownership and may become Go packages or frontend feature folders after the Wails scaffold is created.

### Go host

- **Application façade:** the small set of Wails-bound commands available to React.
- **Project service:** resolves local folders or GitHub URLs, owns the persistent watchlist, and tracks last explicit access.
- **Mirror service:** creates host/owner/repository bare or partial mirrors, fetches exact PR commits, and expires regenerable objects.
- **GitHub gateway:** invokes `gh` with argument arrays, parses JSON, normalizes errors, and applies timeouts/cancellation.
- **Synchronization orchestrator:** sequences summary/detail refreshes and commits complete snapshots.
- **Poll scheduler:** staggers watched-project summary refreshes while the desktop process is running and stops on exit.
- **Diff service:** parses patches, retrieves full base/head files, and owns GitHub line anchoring.
- **Discussion service:** normalizes issue comments, reviews, replies, outdated threads, and resolution state.
- **Draft/review service:** persists local drafts, validates the current head, builds an atomic review payload, and reconciles submissions.
- **Agent registry:** detects Kiro and OpenCode, discovers models/capabilities, and validates experimental custom commands.
- **ACP manager:** launches the selected agent/model, owns the connection/session lifecycle, and emits session updates.
- **AI review pipeline:** builds the versioned JSON prompt, validates/repairs results, and decides between reuse, extension, and fresh analysis.
- **Feedback memory:** separates team discussion context from temporary current-reviewer preference signals and applies seven-day expiry.
- **ACP policy:** advertises capabilities and responds to permission, filesystem, and terminal requests.
- **Storage layer:** owns migrations, queries, transactions, retention, and cache rebuild.
- **Event publisher:** emits versioned events for sync progress and ACP streaming through the Wails runtime.

### React application

- **Desktop shell:** project launcher, global layout, routing, panel sizing, notifications, and error boundaries.
- **PR inbox:** project-grouped all-state search, filters, local review status, activity counts, freshness, and project focus.
- **Review navigation:** overview, changed-file folder tree, discussion counts, and local viewed state.
- **Diff workspace:** file tabs, Monaco diff editor, hunk navigation, line selection, and comment decorations.
- **Discussion layer:** anchored threads plus outdated/unanchored discussion views.
- **Review composer:** local drafts, summary, event choice, validation, and submit confirmation.
- **ACP panel:** structured overview/findings, file navigation, streamed states, agent/model choice, follow-ups, and cancellation.
- **Client state:** server/cache queries plus ephemeral selection, tab, and layout state.

## Wails contract

React uses generated Wails bindings for request/response operations. Long-running work returns quickly with an operation identifier and reports progress through Wails events.

Planned event families:

- `sync.started`, `sync.progress`, `sync.completed`, `sync.failed`
- `poll.started`, `poll.projectUpdated`, `poll.failed`, `poll.stopped`
- `pr.revisionChanged`, `draft.reanchored`, `retention.completed`
- `acp.connection`, `acp.session`, `acp.update`, `acp.completed`, `acp.failed`

Every event should carry a schema version, repository identifier, operation/session identifier, and timestamp. React must unsubscribe listeners when their owning screen unmounts. Database rows—not an event replay buffer—provide durable state after restart.

## GitHub integration contract

All calls use `exec.CommandContext`-style process execution with a deadline, a bounded output buffer, and no shell.

| Purpose | Preferred command surface |
| --- | --- |
| CLI health and host auth | `gh version`, `gh auth status --hostname <host>` |
| Repository identity | `gh repo view --json ... --repo <host/owner/repo>` |
| Managed mirror creation | `gh repo clone <url> <explicit-path> -- --bare --filter=blob:none` after capability proof |
| Exact PR revision | Bounded `git fetch` into the managed mirror using GitHub PR refs or resolved head/base SHAs |
| Paginated PR summaries | `gh api --paginate` against the pulls endpoint |
| Enriched selected PR | `gh pr view <number> --json ... --repo <owner/repo>` |
| Checks | `gh pr checks <number> --json ... --repo <owner/repo>` |
| Unified diff | `gh pr diff <number> --patch --color never --repo <owner/repo>` |
| Full file content | `gh repo read-file <path> --ref <sha> --repo <owner/repo>` |
| Reviews/comments | Versioned REST and GraphQL requests through `gh api` |
| Atomic review submit | `gh api --method POST ... --input -` |

For direct API calls, the gateway sends an explicit supported GitHub API-version header and records that version with contract fixtures. The gateway translates process outcomes into stable categories: missing executable, unauthenticated, forbidden, not found, validation failure, rate limited, timed out, cancelled, malformed response, and unknown failure. Raw stderr may be retained only in redacted diagnostic logs.

## SQLite model

SQLite is configured with foreign keys, WAL mode, a busy timeout, and explicit migrations. One Go-owned connection layer performs all writes.

Proposed data groups:

| Group | Representative records | Authority |
| --- | --- | --- |
| Project watchlist | optional local path, host, owner/name, source type, last opened, poll state | Local |
| PR summaries | identity, state, branches, author, labels, counts, decisions, timestamps | GitHub cache |
| PR snapshots | head/base SHA, commits, checks, changed files, unified diff | GitHub cache |
| Discussions | issue comments, reviews, inline comments, replies, resolution/outdated state | GitHub cache |
| Local review state | `In review`/`Reviewed`/`Ignored`, derived attention signals, viewed files, active tab, panel state | Local |
| Drafts | body, path, line, side, optional range, head SHA, context fingerprint, carry state | Local and durable |
| Agent registry | detected command/version, capabilities, models, last selection, project override | Local |
| ACP records | agent/model, session ID, revision, prompt/schema version, normalized transcript entries | Local with seven-day TTL |
| AI review results | scope, structured JSON, content hash, validation state, extension lineage | Local with seven-day TTL |
| Feedback memory | factual team context references and current-reviewer preference signals | Local with seven-day TTL |
| Submission attempts | content fingerprint, target revision, outcome, returned review ID | Local |
| Sync state | last complete refresh, attempted refresh, error, source version | Local |

Managed mirrors, large file bodies, and disposable ACP review workspaces live in bounded platform cache directories, with only metadata and content hashes in SQLite. These directories are Reviewrr's logical managed `.reviewrr` space and never appear inside a reviewed working tree.

## Synchronization semantics

- On launch, cached PR metadata from every watched project renders before a staggered refresh begins.
- Watched-project summary refreshes and selected-PR detail refreshes are separate transactional scopes.
- Polling exists only in the Wails process and stops completely when the application closes.
- Polling does not reset last-explicit-open retention timestamps.
- Each scope writes to staging rows or an in-memory aggregate, then replaces the previous snapshot in one transaction.
- Cancellation or any failed page preserves the previous complete snapshot.
- Records carry GitHub `updated_at`, a local `fetched_at`, and the PR head SHA.
- User drafts and viewed state are never deleted by cache replacement.
- Deleted remote objects are removed only after a complete authoritative listing for that scope.
- Concurrent refreshes for the same scope are coalesced; a newer manual request cancels or follows the older request deterministically.
- New/updated activity produces grouped in-app alerts; native notifications are opt-in and appear only while the app is open but unfocused. Ignored PRs remain silent.
- Each project defaults to a five-minute poll interval with ±20% jitter; failures and rate limits back off exponentially to at most 30 minutes.

## Diff and comment anchoring

The Go diff service is the single source of truth for both rendering and GitHub payloads.

For every parsed line it records:

- File path and change type.
- Hunk header and position within the file patch.
- Old line number when present.
- New line number when present.
- GitHub side (`LEFT` or `RIGHT`).
- The PR head SHA used to produce the mapping.

When a newer head appears, the UI switches immediately. Drafts remain attached to their original head SHA and context fingerprint. Unique exact context matches—including supported renames—appear inline as carried but unconfirmed. Ambiguous candidates stay in a previous-revision section, and deleted/unmatched context remains orphaned. The application never silently submits a remapped comment.

The application re-fetches the current head immediately before submission and requires every carried draft to be explicitly confirmed.

## ACP integration contract

The Go host acts as the ACP client and uses a pinned community Go SDK behind a Reviewrr-owned adapter. ACP v1 is the initial compatibility target. Kiro (`kiro-cli acp`) and OpenCode (`opencode acp`) are first-class acceptance targets; custom commands are experimental.

Session context is revision scoped:

- Repository identity and PR metadata.
- Base/head SHAs.
- The selected diff, hunk, file, or PR summary requested by the reviewer.
- Relevant existing discussions.
- A disposable review-context directory, not the source worktree, as the session working directory.

Opening an eligible PR automatically starts analysis only when it has fewer than 30 changed files and remains within configured text/context limits. Background polling never starts an agent. The reviewer chooses among detected agents and models; Reviewrr remembers the last successful global selection with an optional project override.

The prompt requires a versioned JSON object containing analysis scope, overview, review order, file summaries, findings, test gaps, architecture impact, reviewer questions, limitations, and skipped files. Reviewrr validates it, requests one repair when invalid, and otherwise exposes an unstructured fallback. Findings render only in the AI panel; selection may navigate to code but never decorates or comments on the diff.

The exact field-level response and validation contract is [AI review result v1](ai-review-result-v1.md).

The initial panel order is overview, review order, severity-sorted findings, test gaps, architecture impact, reviewer questions, file summaries, limitations, and skipped files.

Results reuse when head SHA, agent/model, prompt/schema version, and content hash match. They extend when new discussions, current-reviewer feedback, or newly available relevant context arrives. A revision, agent/model, schema, or completeness change requires fresh analysis.

All participant comments are factual context. Only the active reviewer's draft edits, submitted comments, accepted findings, and dismissed findings become temporary preference signals. These signals expire seven days after the project was last explicitly opened.

The client advertises only capabilities Reviewrr actually implements. It denies filesystem-write and terminal requests. Read requests are restricted to the disposable context root with canonical-path and symlink checks.

This is a product safety boundary, not a hostile-process sandbox. A locally launched agent inherits OS permissions unless the agent or operating system provides a stronger sandbox. The UI must disclose that fact before launching a newly configured agent.

## Review submission contract

The review service uses one atomic GitHub create-review request containing:

- The current PR head commit ID.
- A non-empty user-authored summary.
- One event: `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`.
- Zero or more validated inline comments with exact diff coordinates.

The JSON payload is streamed through stdin. Drafts remain until a successful GitHub response is normalized and committed locally. After an ambiguous timeout, the service first reconciles recent reviews using reviewer identity, head SHA, timestamp, and a local content fingerprint before offering retry.

## Security and privacy

- No GitHub tokens in application configuration, SQLite, events, or logs.
- No shell invocation or string-built commands.
- Explicit process timeouts, cancellation, output limits, and child cleanup.
- Path canonicalization before any repository or ACP file access.
- No following symlinks outside the allowed review-context root.
- Content sent to an agent is visible in the UI and limited to the selected review scope by default.
- Logs contain identifiers and state transitions, not source content, review bodies, secrets, or full subprocess output.
- Cache reset deletes rebuildable GitHub/ACP artifacts separately from human drafts.
- Seven-day cleanup removes managed mirrors, heavy GitHub/PR cache, ACP sessions/transcripts, AI results, and learned context, while preserving watchlist references, local review status, and human drafts.
- Regenerable cache has a 5 GiB default budget. Least-recently-opened cache groups may be pruned before seven days when the budget is exceeded; seven days is a maximum lifetime, not a guaranteed minimum.

## Observability and support

Local structured logs should record operation IDs, durations, exit categories, row counts, and state transitions. A diagnostics view may display:

- Wails/Reviewrr version and OS.
- `git`, `gh`, SQLite, and configured ACP agent versions.
- Authentication status without token material.
- Database migration and integrity status.
- Last sync attempts and normalized errors.
- Cache size and review-workspace size.

Diagnostics export must be previewable and redacted before writing a support bundle.

## Architecture diagrams

- [System context](c4-context.md)
- [Containers](c4-containers.md)
- [Go backend components](c4-components-go-backend.md)
- [React frontend components](c4-components-react-frontend.md)
- [PR synchronization](c4-dynamic-pr-sync.md)
- [ACP-assisted review](c4-dynamic-ai-review.md)
- [AI review result v1](ai-review-result-v1.md)
- [Review submission](c4-dynamic-submit-review.md)
- [Desktop deployment](c4-deployment.md)

## Decisions

- [ADR-0001: Wails v2 desktop architecture](decisions/0001-wails-v2.md)
- [ADR-0002: GitHub access through `gh`](decisions/0002-gh-cli-integration.md)
- [ADR-0003: SQLite as a local cache](decisions/0003-sqlite-cache.md)
- [ADR-0004: ACP review-only boundary](decisions/0004-acp-review-only.md)
- [ADR-0005: Local drafts and atomic review submission](decisions/0005-review-drafts.md)
- [ADR-0006: Watched projects and in-process polling](decisions/0006-project-watchlist-polling.md)
- [ADR-0007: Seven-day cache retention with durable human drafts](decisions/0007-retention-policy.md)
- [ADR-0008: Structured right-panel AI review](decisions/0008-structured-ai-review.md)

## External references

- [Wails v2 documentation](https://v2.wails.io/docs/introduction/)
- [GitHub CLI manual](https://cli.github.com/manual/)
- [GitHub pull-request reviews REST API](https://docs.github.com/en/rest/pulls/reviews)
- [ACP v1 protocol overview](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/overview.mdx)
- [ACP community libraries](https://agentclientprotocol.com/libraries/community)
- [`coder/acp-go-sdk`](https://github.com/coder/acp-go-sdk)
- [Kiro ACP documentation](https://kiro.dev/docs/cli/acp/)
- [OpenCode ACP documentation](https://opencode.ai/docs/acp/)
