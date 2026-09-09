# Reviewrr MVP product and delivery plan

**Status:** proposed baseline  
**Planning posture:** HOLD  
**Last updated:** 2026-09-05

## Product statement

Reviewrr is a local-first desktop layer over GitHub pull requests. It combines a watched-project inbox, a revision-accurate diff-and-discussion workspace, durable human review drafts, and structured assistance from ACP-compatible coding agents.

The PR—not a working-tree checkout—is the primary review unit. The MVP is successful when one reviewer can follow roughly three to five projects, see PRs from all of them, open any PR at its latest head revision, perform a human code review with optional AI support, and submit a deliberate GitHub review without returning to the browser.

## Locked decisions

| Decision | MVP choice |
| --- | --- |
| Desktop framework | Stable Wails v2 |
| Native/backend language | Go |
| Frontend | React and TypeScript |
| Local persistence | SQLite, owned by Go |
| GitHub integration | Installed and authenticated `gh` CLI |
| Agent integration | ACP v1 client over stdio |
| Initial agents | Kiro and OpenCode; custom ACP commands are experimental |
| Agent selection | Reviewer chooses an available agent and model; remember the last success globally with optional project override |
| Project model | Persistent watchlist with one focused project/PR at a time |
| Repository materialization | Reviewrr-managed bare or partial Git mirrors; no managed working tree |
| Background work | Poll watched projects only while Reviewrr is running |
| Polling default | Every five minutes per project, staggered with ±20% jitter and exponential backoff up to 30 minutes |
| Notifications | In-app activity indicators on; native notifications off until explicitly enabled |
| Cache retention | Seven days after last explicit project, branch, or PR open |
| Cache budget | 5 GiB default for regenerable data; prune least-recently-opened data first when exceeded |
| Human draft retention | Until submitted or explicitly discarded; exempt from cache expiry |
| Resolved discussions | Visible but read-only in the MVP |
| First packaged target | Signed macOS build |
| Review writes | User-confirmed review submission only |
| Explicit exclusions | Merging PRs and modifying repository code |
| Planning scope | HOLD: deliver the defined MVP before expansion |
| Default implementation review | Codex |

## Current workspace baseline

The planning workspace is greenfield: it contains five files under `design/`, is not yet initialized as a Git repository, and has no application scaffold.

Observed local tools on 2026-09-05:

| Tool | Observed state |
| --- | --- |
| Go | 1.26.2, Darwin arm64 |
| Git | 2.50.1 (Apple Git-155) |
| Node.js | 22.23.2 |
| npm | 10.9.8 |
| GitHub CLI | 2.93.0 |
| SQLite CLI | 3.51.0 |
| Wails CLI | Not installed |

These observations are development prerequisites, not application version pins. Milestone 0 must choose and record supported version ranges.

## Design interpretation

The primary reference, [`design/code review.png`](../design/code%20review.png), establishes the workspace shape:

1. A left rail for watched projects, PR-level navigation, and a changed-file tree.
2. A central review surface for side-by-side or unified diffs, file tabs, line comments, and viewed state.
3. A right rail for AI summaries, explanations, and review findings. AI does not annotate the diff directly.
4. A top bar for repository/PR identity, search, synchronization state, and the submit-review action.

The MVP will preserve that hierarchy, but it will not implement the mockup's speculative concepts such as blast-radius scoring or architecture-impact scoring until they have defined inputs and measurable behavior.

## Target user and jobs

The initial user is an individual developer who routinely reviews PRs across approximately three to five GitHub projects they can access through GitHub CLI.

Their core jobs are:

- Reopen a recent project, choose a local project, or paste a GitHub project/PR URL.
- Maintain a small persistent watchlist and see PRs from every watched project in one application.
- See open, draft, closed, and merged PRs without permanently removing historical entries.
- Understand the scope of a PR before reading every line.
- Navigate changed files and inspect accurate base/head content.
- See issue comments, reviews, inline discussions, and resolution state in context.
- Ask an ACP agent to explain or review the current file, hunk, or PR.
- Choose between installed Kiro, OpenCode, and compatible custom agents and their available models.
- Turn their own conclusions into local draft comments.
- Submit a comment, approval, or request-changes review to GitHub.

## MVP experience

### 1. Open or add a project

- Start on a project launcher containing recent/watched projects, a native local-folder action, and a GitHub project/PR URL input.
- Resolve a chosen local folder to its Git root and canonical GitHub host/owner/repository.
- When a pasted URL has no registered local source, create a Reviewrr-managed bare or partial mirror in platform-standard application storage rather than a user working tree.
- Organize managed mirrors by host, owner, and repository and read exact commits without checking out branches.
- Verify that `git` and `gh` exist and that `gh` is authenticated for the repository host.
- Add a successfully resolved project to the watchlist until the reviewer explicitly removes it.
- Reject invalid URLs, non-repositories, unsupported remotes, clone failures, and inaccessible projects with actionable remediation.

### 2. Watch projects and organize the PR inbox

- Support a practical watchlist of roughly three to five projects without imposing a hard five-project limit.
- On launch, render cached PR metadata across the full watchlist, then stagger lightweight refreshes so projects do not synchronize in one burst.
- Poll PR summaries only while Reviewrr is open. Do not install a daemon, menu-bar helper, or background service.
- Default to one refresh per watched project every five minutes, staggered with ±20% jitter; exponentially back off failures and rate limits to a maximum 30-minute interval.
- Synchronize PR summaries for all states through paginated `gh api` requests.
- Group the default inbox by project; order projects by most recently opened and PRs within each project by latest GitHub activity.
- Keep open, draft, closed, and merged PRs discoverable. State changes alter badges and filters, not existence.
- Show new/updated counts per project and in-app activity toasts. Offer native notifications while the app is open but unfocused, disabled by default until the reviewer opts in.
- Suppress alerts and attention counts for locally ignored PRs.
- Filter by project, state, local review status, draft status, author, review request, review decision, label, and updated time.
- Search locally across every watched project by number, title, body, author, branches, and labels.
- Display freshness and errors instead of presenting stale data as current.

### 3. Review a pull request

- Load PR metadata, commits, CI/check status, changed files, reviews, issue comments, and inline review threads.
- Treat each head SHA as an immutable review snapshot backed by exact base/head Git objects.
- Switch the open workspace immediately when polling or refresh discovers a newer head SHA.
- Cancel or archive ACP work tied to the previous revision when the workspace switches.
- Organize changed paths as a folder tree with status and addition/deletion counts.
- Offer side-by-side and unified diff modes with syntax highlighting.
- Load complete base/head file content on demand when the patch alone is insufficient.
- Map every visible diff line to GitHub's `path`, `line`, `side`, and head commit SHA.
- Mark files viewed locally. Synchronizing GitHub's viewed state is deferred unless the chosen GitHub API contract is stable and testable.
- Track personal PR status as `In review`, `Reviewed`, or `Ignored`, with derived signals such as `Unseen` and `Updated since review`.
- Suggest or apply explainable transitions: meaningful interaction starts `In review`, and successful GitHub review submission sets `Reviewed`. Always permit undo or manual override.
- Keep an ignored PR ignored across new commits until the reviewer changes it.
- Handle renamed, deleted, binary, oversized, and truncated files without pretending content is available.

### 4. Read discussions

- Show general PR comments separately from formal reviews.
- Place inline review threads beside the associated diff line when the anchor still exists.
- Put outdated or unanchored threads in a clearly labeled section.
- Show author, timestamp, review state, replies, and resolved/unresolved state.
- Treat thread resolution as read-only in the MVP; Reviewrr displays GitHub's state but does not resolve or unresolve threads.
- Preserve discussion history in the cache across transient network failures.

### 5. Draft and submit a review

- Create, edit, and delete local inline draft comments.
- Keep drafts across restarts and associate them with the PR head SHA and exact diff anchor.
- On an immediate revision switch, preserve all drafts and attempt to re-anchor them using rename metadata and surrounding code context rather than line number alone.
- Show unique exact matches inline with a `Carried from previous revision` badge, but require confirmation before submission.
- Keep ambiguous matches in a `Previous revision drafts` section with suggested locations; retain deleted/unmatched context as orphaned drafts.
- Exempt all unsent human drafts from seven-day cache cleanup; retain them until submission or explicit discard.
- Require a non-empty summary and an explicit event: comment, approve, or request changes.
- Before submission, refresh the PR head SHA and block any unconfirmed, ambiguous, or stale anchor.
- Submit the summary and inline comments as one GitHub review through `gh api`.
- Retain all drafts if submission fails; clear them only after GitHub confirms success.
- Never expose merge, update-branch, checkout, commit, push, or code-edit actions.

### 6. Use ACP assistance

- Detect Kiro (`kiro-cli acp`) and OpenCode (`opencode acp`) as first-class agents; allow a custom command/arguments as an experimental integration.
- Present available agents and models before analysis, including setup, authentication, compatibility, and capability problems.
- Remember the last successful agent/model globally and permit a per-project override.
- Negotiate ACP version and capabilities, then create one session per repository/PR/revision context.
- Automatically start analysis when a PR is opened and has fewer than 30 changed files, subject to a bounded diff/context size and binary/generated/vendor exclusions.
- Never run AI merely because background polling discovered a PR.
- Provide focused follow-up actions: explain selection, explain file, review file, and extend analysis.
- Stream agent messages, tool activity, status, and failures into the right rail.
- Offer only read-oriented client capabilities. Deny filesystem writes and terminal creation.
- Render AI findings only in the right panel. A finding may navigate to a line, but it never becomes an inline annotation.
- Require the versioned [AI review result v1](architecture/ai-review-result-v1.md) JSON response describing scope, overview, review order, file summaries, findings, test gaps, architecture impact, reviewer questions, limitations, and skipped files.
- Validate the JSON against the requested schema, attempt one repair prompt on failure, and otherwise render the response as clearly labeled unstructured output.
- Reuse a matching cached analysis immediately when head SHA, agent, model, prompt/schema version, and content hash match.
- Extend cached analysis when new discussions, human feedback, or additional relevant context arrive. Run fresh after a revision, agent/model, schema, or completeness change.
- Keep AI suggestions visually distinct from GitHub comments and user-authored drafts. Never copy or publish them automatically.
- Render the first result in this order: overview, review order, findings by severity, test gaps, architecture impact, reviewer questions, file summaries, limitations, and skipped files.
- Cancel a running turn and recover from agent exit without losing the human review state.

### 7. Learn temporarily from human review behavior

- Supply all current PR discussions to AI as factual review context.
- Learn temporary reviewer preferences only from the current reviewer's submitted comments, draft edits, accepted findings, and dismissed findings.
- Treat submitted comments as stronger signals than unfinished drafts.
- Never infer the current reviewer's preferences from other participants' comments.
- Make temporary learning inspectable and immediately clearable.
- Expire learned AI context seven days after the associated project was last explicitly opened.

## Data freshness and offline behavior

GitHub remains the source of truth. SQLite is a local read model and draft store.

- On application launch: render cached watchlist metadata, then stagger a lightweight refresh for each watched project.
- On project or PR open: refresh its last-access time, show cached content immediately, prioritize its synchronization, and materialize missing exact Git objects.
- On manual refresh: synchronize watched-project summaries first and the selected PR details second.
- While open: poll summaries conservatively with jitter, coalescing, cancellation, and rate-limit backoff.
- While closed: perform no work and receive no updates.
- On partial failure: commit no partial aggregate for the failed scope; retain the previous complete snapshot and record the error.
- Offline: browsing cached PRs, diffs, discussions, AI transcripts, and drafts works; GitHub submission and uncached content do not.
- Revision changes: switch immediately to the new head; re-anchor exact draft matches, preserve ambiguous drafts separately, and block them from submission until confirmed.

## Retention model

- Project watchlist references and lightweight preferences persist until the reviewer removes them.
- Managed Git mirrors, exact PR snapshots, full file bodies, detailed GitHub cache, ACP sessions/transcripts, and learned AI context use a sliding seven-day TTL based on explicit project, branch, or PR opens.
- Background polling does not reset the seven-day access clock.
- Bound regenerable storage to 5 GiB by default. When the budget is exceeded, prune least-recently-opened cache groups before their seven-day maximum age; never prune protected human drafts.
- Opening an expired project recreates its missing mirror and cache from GitHub.
- Human-authored drafts never expire automatically. When heavy context is removed, retain the draft text, original head SHA, semantic anchor, and surrounding-context fingerprint required for later re-anchoring.
- Ignored/reviewed/in-review state persists with the project reference unless explicitly reset.

## Safety and privacy requirements

- Invoke executables with argument arrays, never through a shell-interpolated command string.
- Send GitHub request bodies to `gh api --input -` over stdin so review text cannot become command syntax.
- Do not read, store, or log GitHub tokens; `gh` owns authentication.
- Redact credentials and likely secrets from structured logs.
- Store durable state under the OS application-data directory and regenerable mirrors/snapshots under the OS cache directory. Treat this as Reviewrr's logical managed `.reviewrr` space; never create `.reviewrr` inside a reviewed working tree.
- Do not send repository content to an ACP agent before the reviewer selects and starts that agent.
- Label ACP agents as trusted local processes: protocol permission denial is not an OS sandbox.
- Do not claim that a read-only ACP policy prevents a malicious subprocess from accessing files available to the user's OS account.

## Non-goals for phase one

- Merging, rebasing, updating, checking out, committing, pushing, or editing code.
- Hosting an ACP agent or calling model-provider APIs directly.
- Automatically publishing AI findings.
- Autonomous review submission.
- Team accounts, shared annotations, billing, or a hosted synchronization service.
- GitHub webhooks or a background daemon while Reviewrr is closed.
- Automatic AI analysis of PRs discovered only through polling.
- General-purpose IDE features, integrated terminals, debugging, or code execution.
- Bitbucket, GitLab, Azure DevOps, or non-GitHub remotes.
- Analytics scores whose definitions are not yet testable.

## Delivery sequence

This is a milestone plan, not a task DAG. A milestone exits only when its end-to-end behavior and failure paths are demonstrable.

### Milestone 0 — Technical proof and contracts

Prove the riskiest boundaries before building the full interface.

- Initialize version control without moving or rewriting the existing design assets.
- Install and pin a supported Wails v2 toolchain, then create a minimal React/TypeScript desktop shell.
- Validate typed Go-to-TypeScript bindings and Go-to-React event streaming.
- Prove SQLite migrations and WAL-mode startup/recovery.
- Prove local-folder and GitHub URL discovery, Reviewrr-managed bare/partial mirroring, exact PR-ref fetching, paginated PR retrieval, diff retrieval, thread retrieval, and review submission against a disposable test repository.
- Prove ACP v1 initialization, session creation, structured JSON output, streaming, cancellation, and permission denial with both Kiro and OpenCode.
- Freeze normalized domain contracts only after these spikes pass.

**Exit:** one developer machine can perform every external round trip with captured fixtures and no repository worktree mutation.

### Milestone 1 — Watched projects and combined PR inbox

- Implement the launcher for recent projects, local folder selection, and GitHub project/PR URL entry.
- Implement project resolution, persistent watchlist management, and Reviewrr-managed mirror lifecycle.
- Implement the SQLite schema, migrations, repositories, and transaction boundaries.
- Add `gh` health/auth checks and normalized error categories.
- Implement staggered, in-process-only polling across watched projects with coalescing and rate-limit backoff.
- Synchronize all-state PR summaries and expose cached-first loading.
- Build the project-grouped, searchable/filterable PR inbox, state badges, project counts, alerts, and freshness indicators.
- Add local `In review`, `Reviewed`, and `Ignored` status with explainable automatic transitions.

**Exit:** the user can follow three to five projects, restart Reviewrr, and search their combined cached PR list; polling runs only while the application is open.

### Milestone 2 — Review workspace

- Synchronize selected-PR details, files, checks, reviews, and discussions.
- Fetch and retain exact base/head Git objects in a managed mirror without creating a working tree.
- Parse unified diffs into stable file/hunk/line models.
- Build folder-tree navigation and the Monaco-based diff viewer.
- Load full base/head content on demand and handle special file states.
- Render current and outdated inline threads at correct anchors.

**Exit:** representative PR fixtures—including rename, delete, binary, large, and force-pushed cases—render without incorrect line anchors.

### Milestone 3 — Human review workflow

- Add local file-viewed state and durable inline drafts.
- Add review summary/event composition.
- Add immediate revision switching plus exact, ambiguous, and orphaned draft re-anchoring states.
- Add pre-submit head-SHA and carried-draft confirmation checks.
- Submit one atomic review and reconcile the returned review/comments into SQLite.
- Add failure-safe retry behavior without duplicate submissions.

**Exit:** a reviewer can submit a multi-comment review to a disposable GitHub repository, and simulated 401, 403, 422, timeout, and head-change failures preserve recoverable drafts.

### Milestone 4 — ACP explanation and review

- Add Kiro/OpenCode discovery, model selection, compatibility diagnostics, custom-agent configuration, and lifecycle management.
- Materialize disposable, revision-scoped review context outside the source repository.
- Define and version the AI-review JSON Schema, prompts, validator, one-shot repair, and unstructured fallback.
- Automatically analyze eligible opened PRs and stream normalized ACP updates into the right rail.
- Add smart result reuse/extension plus explain/review follow-up actions.
- Add seven-day temporary learning from the current reviewer's feedback while treating team discussions as factual context only.
- Implement cancel, crash recovery, unsupported capability handling, and deny-by-default permissions.

**Exit:** Kiro and OpenCode each return schema-valid right-panel analysis for an eligible opened PR; invalid output recovers predictably, cached analysis reuses correctly, and no AI output or capability can create a GitHub comment or source edit.

### Milestone 5 — Hardening and distributable MVP

- Add keyboard navigation, screen-reader names, focus management, contrast checks, and panel resizing.
- Add structured local logs, support diagnostics, and cache reset/rebuild actions.
- Test large PR behavior, multi-project rate limits, seven-day expiry, retained drafts, corrupted cache recovery, process cancellation, and application restarts.
- Package and sign the first supported desktop target.
- Write installation checks for `git`, `gh`, and an ACP agent.

**Exit:** the release checklist passes on the selected target OS and a new user can complete the primary flow from installation through review submission.

## Test strategy

| Layer | Required coverage |
| --- | --- |
| Go domain | Diff parsing, revision switching, contextual re-anchoring, personal status transitions, TTL rules, stale-head checks, and error normalization |
| Go integrations | Golden JSON fixtures for `gh`; fake executables for clone/fetch, exit codes, malformed output, timeouts, and pagination |
| SQLite | Migration upgrades, constraints, transactional replacement, WAL recovery, protected-draft retention, and corrupted-cache rebuild |
| ACP | Kiro/OpenCode acceptance plus a fake agent for capability negotiation, JSON conformance/repair, reuse, extension, permissions, cancellation, and crash behavior |
| React | Component tests for project-grouped inbox, tree navigation, filters, personal status, revision changes, carried drafts, structured AI cards, stale/error states, and permission prompts |
| Contract | Generated Wails TypeScript bindings checked for drift in CI |
| End to end | Disposable local repositories and a dedicated GitHub test repository; no production PRs |
| Accessibility | Keyboard-only primary flow plus automated accessibility checks |

## Product acceptance scenarios

1. **Combined launch:** start with five watched projects; cached PRs from all projects appear immediately, followed by staggered refresh and accurate per-project counts.
2. **Closed behavior:** quit the app and create a PR remotely; no polling or notification occurs until the next launch.
3. **URL-first review:** paste an unregistered PR URL; Reviewrr creates a managed mirror, fetches exact base/head objects, and opens the PR without a working tree.
4. **All-state history:** close and merge PRs; they remain searchable with updated state badges.
5. **Immediate revision:** create drafts and push a new head; the workspace switches immediately, exact contextual matches appear carried and unconfirmed, and ambiguous/deleted anchors remain preserved outside the current diff.
6. **Ignored stability:** ignore a PR and push new commits; it updates silently without regaining attention counts or notifications.
7. **Seven-day expiry:** expire an inactive project; mirrors, detailed cache, ACP transcripts, and learned context are removed while the watchlist, personal state, and human drafts remain.
8. **Structured AI:** open an eligible PR using both Kiro and OpenCode; valid JSON renders right-panel sections, invalid JSON receives one repair attempt, and no AI finding annotates the diff.
9. **Smart reuse:** reopen the same revision and agent/model; cached analysis appears immediately and extends only when new review context exists.
10. **Atomic review:** submit a summary plus confirmed inline comments; GitHub receives one review, and local drafts are cleared only after a confirmed response.
11. **Submission failure:** revoke write permission or trigger validation failure; Reviewrr shows the reason and retains every draft.
12. **Agent safety:** an agent requests filesystem write or terminal access; Reviewrr denies it and records the denial without interrupting human review.

## Main risks and mitigations

| Risk | Mitigation |
| --- | --- |
| GitHub line anchors become invalid after a force push | Switch immediately, preserve old anchors, reattach only unique contextual matches, and require confirmation before submission |
| `gh` JSON or exit behavior changes | Pin minimum supported CLI version, normalize at one gateway, and keep contract fixtures |
| Polling several projects consumes rate limits or produces alert fatigue | Fetch summaries only, stagger with jitter/backoff, group alerts, and silence ignored PRs |
| Managed mirrors consume disk | Use partial/bare mirrors, a seven-day last-opened TTL, bounded storage reporting, and deterministic recreation |
| Large PRs overwhelm the WebView | Lazy-load files, virtualize lists/lines, bound cache payloads, and degrade special files explicitly |
| ACP Go SDK lags the protocol | Hide it behind an internal adapter, pin a version, and run protocol contract tests |
| Kiro and OpenCode return structurally different text | Require a versioned JSON Schema, validate, repair once, and retain an honest fallback |
| AI feedback learning captures another person's preferences | Use team comments as facts but learn preferences only from the active reviewer's behavior; expire after seven days |
| “Read-only” agent is mistaken for a sandbox | Use disposable context, deny ACP mutation capabilities, and disclose the trusted-process boundary |
| SQLite cache is partially refreshed | Replace aggregates transactionally and retain the last complete snapshot on failure |
| Duplicate review submission after an ambiguous timeout | Reconcile recent reviews by user, head SHA, and a locally generated submission fingerprint before retry |

## Proposed MVP cut line

The first releasable cut ends after Milestone 5 with:

- One focused PR at a time within a persistent watchlist designed around three to five projects.
- Recent/local/URL project entry and Reviewrr-managed bare/partial mirrors for URL-only projects.
- A project-grouped all-state PR inbox with polling only while the app is open.
- GitHub.com support through `gh`.
- Kiro and OpenCode as tested agents, one chosen agent/model per analysis, and experimental custom ACP commands.
- Automatic structured AI analysis only when an opened PR has fewer than 30 files and passes content-size limits.
- Seven-day expiry for regenerable caches and AI learning, with human drafts retained until submitted or discarded.
- macOS as the first packaged and signed target, while keeping Go and frontend code portable.

GitHub Enterprise Server, Windows/Linux packaging, multiple simultaneous agents, semantic repository indexing, polling while closed, and organization-wide dashboards should begin only after the core review loop is stable.

## Product defaults to validate with users

The architecture uses these defaults so implementation can proceed; usability testing may tune them without changing the core boundaries:

- Signed macOS package first.
- Five-minute per-project polling with ±20% jitter and backoff up to 30 minutes.
- In-app activity indicators enabled and native notifications opt-in.
- A 5 GiB regenerable-cache budget with least-recently-opened pruning; seven days remains the maximum retention age.
- Resolved-thread state displayed read-only.
- AI sections ordered as overview, review order, severity-sorted findings, test gaps, architecture impact, reviewer questions, file summaries, limitations, and skipped files.
