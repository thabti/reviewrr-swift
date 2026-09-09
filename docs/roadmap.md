# Reviewrr roadmap

This maps the product specification's MVP buckets to the macOS app as it exists today. Statuses
describe the implementation, not the ambition:

- **Done** — present in the current codebase, even where it is deliberately a small slice.
- **Partial** — a working path exists with a stated boundary.
- **Planned** — not implemented.

The app opens on a dashboard: watched projects plus a cross-repository PR inbox. Opening a row moves
the window into the review workspace.

## Must have

| Capability | Status | Current state and boundary |
| --- | --- | --- |
| GitHub auth | **Done** | Keychain-stored credential with token-kind detection (`ghp_`, `github_pat_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, legacy 40-hex), scope and capability diagnostics, rate-limit readout, per-repository access check, and an RFC 8628 OAuth device flow. The device flow needs a reviewer-supplied OAuth client ID — Reviewrr ships none. |
| GitHub Enterprise Server | **Done** | Host switching to `https://host/api/v3` and `/api/graphql`, validated by verifying the credential against that host before saving. |
| Organization and repository selection | **Partial** | A persistent watchlist of `owner/repo` projects, added by pasting a repo URL, PR URL, or `owner/repo`, validated before it is added. There is no organization browser. |
| Unified PR inbox | **Done** | Per-project sync of all PR states plus reviewer buckets (needs review, assigned, authored, participated) from the search API, grouped by project or bucket, with filters, local search, freshness, and per-project unread counts. |
| Polling | **Done** | Per-project intervals with ±20% jitter, exponential backoff to thirty minutes, coalescing and cancellation — only while the app is running. No daemon. |
| Notifications | **Done** | In-app activity events on by default; native notifications opt-in and suppressed for muted projects and ignored PRs. |
| PR detail | **Done** | Three-pane workspace: file tree, diff, and a right rail with AI and Conversation panels. |
| Excellent diff viewer | **Done** | Split and unified, word-level intra-line highlighting, sticky file headers, lazy per-file blocks, context expansion, explicit binary/large/renamed/deleted handling, and guards for pathological files. |
| File navigation | **Done** | Folder tree with collapsed single-child chains, three sort orders, path search, and keyboard movement. |
| File filtering and triage | **Done** | Eleven categories classified from path and patch (lock files and generated files hidden by default) with a visible count of what is hidden, plus formatting-only and large-file signals. |
| Review progress | **Done** | Viewed-file tracking with per-category progress in the sidebar footer. |
| GitHub comments | **Done** | Existing threads with resolution and outdated state, inline replies, resolve/unresolve, a merged conversation timeline, and local line-anchored drafts. |
| Review submission | **Done** | Comment, approve, or request changes as one review; anchors re-validated against the current patch; drafts retained on failure. |
| CI status | **Done** | Check runs and legacy commit statuses merged into one list with a rollup shown in the PR header. |
| Basic AI question interface | **Done** | Ask scoped to the whole PR, a file, or a selection, streaming, with `path:line` citations that navigate and an explicit "turn this into a draft comment" action. |
| Structured AI analysis | **Done** | The versioned `reviewrr.ai-review.v1` result with validation, one repair attempt, an honest unstructured fallback, revision-keyed caching, and a heuristic analyzer when no provider is configured. |
| Multiple AI providers | **Done** | Anthropic, OpenAI, OpenRouter, any OpenAI-compatible endpoint, and local Ollama, with keys in the Keychain and a streaming connection test. |
| Repository-aware AI context | **Planned** | Context is PR-scoped: metadata, changed files and patches, comments, drafts, and the current analysis. No repository-wide semantic index or code search. |

## Could have

| Capability | Status | Current state and boundary |
| --- | --- | --- |
| Keyboard shortcuts | **Done** | `j`/`k` files, `n`/`p` hunks, `v` viewed, `u` layout, `/` search, `?` shortcuts sheet, plus ⌘O and ⌘R. |
| PR search | **Done** | Local search across every cached inbox row. Server-side search beyond the reviewer buckets is not exposed. |
| Saved filters | **Planned** | Filter state is session state; the hidden-category default persists, named filters do not. |
| GitHub notifications ingestion | **Planned** | The inbox is the mechanism; the notifications API is not read. |
| Slack integration | **Planned** | No connector. |

## Later

| Capability | Status |
| --- | --- |
| Deep code indexing, git-history reasoning, dependency graphs | **Planned** |
| Jira/Linear context | **Planned** |
| Team analytics | **Planned** — review progress is personal workspace state, not team reporting |
| CLI integration | **Planned** |
| Local repository integration | **Planned** |
| Reviewer-preference learning (`mvp-plan.md` §7) | **Planned** |
| Extended analysis that carries findings across revisions | **Planned** — the schema models it; the analyzer only produces fresh results and exact-match cache reuse |
| Signed, notarized distribution | **Planned** — the build is ad-hoc signed with the sandbox off, which is why the Keychain item survives rebuilds |

## Context-engine direction

The next AI context layer should combine semantic retrieval with deterministic code search; vector
similarity alone is not reliable for exact symbols, callers, interfaces, or line-level evidence. An
eventual model-agnostic investigator would call bounded tools such as `search_code`, `read_file`,
`find_symbol`, `find_references`, `search_documentation`, `inspect_git_history`, `inspect_commit`,
`inspect_pr`, `find_similar_implementation`, and `trace_call_path`.

That is direction, not current functionality.
