# GitHub review submission flow

Review submission is the only GitHub write in the MVP. It is explicit, revision checked, atomic, and recoverable.

```mermaid
C4Dynamic
  title Dynamic diagram for submitting a GitHub pull-request review

  Person(reviewer, "Code Reviewer", "Owns review content and final intent")
  Container(reactUi, "Review Workspace UI", "React, TypeScript", "Collects summary, event, and drafts")
  Component(reviewService, "Draft and Review Service", "Go", "Validates and submits reviews")
  Component(diffService, "Diff Service", "Go", "Validates line anchors")
  Component(githubGateway, "GitHub Gateway", "Go", "Executes typed gh operations")
  Component(storage, "Storage Layer", "database/sql", "Persists drafts and reconciled state")
  ContainerDb(sqlite, "Local Database", "SQLite", "Durable review drafts")
  System_Ext(ghCli, "GitHub CLI", "Authenticated GitHub API client")
  System_Ext(github, "GitHub", "Review source of truth")

  Rel(reviewer, reactUi, "1. Reviews final destination, event, summary, and comment count")
  Rel(reactUi, reviewService, "2. Confirms submission", "Wails binding")
  Rel(reviewService, storage, "3. Loads durable drafts, carry-confirmation state, and expected head SHA")
  Rel(storage, sqlite, "4. Reads one consistent draft snapshot", "SQL transaction")
  Rel(reviewService, githubGateway, "5. Fetches current PR head SHA")
  Rel(githubGateway, ghCli, "6. Runs read request", "Process/stdout JSON")
  Rel(ghCli, github, "7. Reads current revision", "HTTPS")
  Rel(reviewService, diffService, "8. Validates every anchor and carried-draft confirmation against that revision")
  Rel(reviewService, githubGateway, "9. Sends one review payload if revision and anchors match")
  Rel(githubGateway, ghCli, "10. Streams JSON payload through stdin", "gh api --input -")
  Rel(ghCli, github, "11. Creates one review with inline comments", "HTTPS REST")
  Rel(githubGateway, reviewService, "12. Returns normalized review or typed failure")
  Rel(reviewService, storage, "13. On success, stores review and clears submitted drafts")
  Rel(storage, sqlite, "14. Commits reconciliation", "SQL transaction")
  Rel(reviewService, reactUi, "15. Returns success, stale-head block, or recoverable failure", "Wails response")
```

## Invariants

- Head-SHA mismatch stops before the GitHub write.
- Invalid or missing line coordinates stop before the GitHub write.
- Carried drafts require explicit confirmation; ambiguous, orphaned, or old-revision drafts cannot enter the payload.
- Summary and review event are human-confirmed immediately before the write.
- Failure before confirmed success leaves local drafts unchanged.
- An ambiguous timeout triggers reconciliation before a retry is offered.
- No ACP component participates in this flow.

## Key

- The only outbound write is step 11.
- Review text is JSON data on stdin, never shell syntax or command-line flags.
