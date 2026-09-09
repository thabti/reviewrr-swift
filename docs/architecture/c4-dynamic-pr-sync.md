# Watched-project synchronization flow

The synchronization flow is cached-first, staggered across watched projects, and active only while Reviewrr is open.

```mermaid
C4Dynamic
  title Dynamic diagram for launching Reviewrr and polling watched projects

  Person(reviewer, "Code Reviewer", "Follows several GitHub projects")
  Container(reactUi, "Review Workspace UI", "React, TypeScript", "Displays a project-grouped combined inbox")
  Component(projectService, "Project Service", "Go", "Owns watched project references")
  Component(syncOrchestrator, "Sync and Poll Orchestrator", "Go", "Staggers paginated project refreshes")
  Component(githubGateway, "GitHub Gateway", "Go", "Normalizes gh operations")
  Component(storage, "Storage Layer", "database/sql", "Owns cache transactions")
  ContainerDb(sqlite, "Local Database", "SQLite", "Last complete PR snapshot")
  System_Ext(ghCli, "GitHub CLI", "Authenticated API client")
  System_Ext(github, "GitHub", "PR source of truth")

  Rel(reviewer, reactUi, "1. Launches Reviewrr", "Desktop UI")
  Rel(reactUi, projectService, "2. Requests watched projects and cached inbox", "Wails binding")
  Rel(projectService, storage, "3. Loads watchlist, personal status, and last complete summaries")
  Rel(storage, sqlite, "4. Reads durable and cached state", "SQL")
  Rel(storage, reactUi, "5. Returns project-grouped cached PRs and freshness", "Wails response")
  Rel(projectService, syncOrchestrator, "6. Starts in-process staggered polling")
  Rel(syncOrchestrator, githubGateway, "7. Requests one watched project's all-state PR pages")
  Rel(githubGateway, ghCli, "8. Runs paginated gh api", "Process/stdout JSON")
  Rel(ghCli, github, "9. Fetches lightweight PR summaries", "HTTPS REST")
  Rel(githubGateway, syncOrchestrator, "10. Returns normalized pages or typed failure")
  Rel(syncOrchestrator, storage, "11. Replaces that project snapshot only after every page succeeds")
  Rel(storage, sqlite, "12. Commits PRs and sync metadata", "SQL transaction")
  Rel(syncOrchestrator, reactUi, "13. Emits grouped counts, alerts, freshness, or failure", "Wails event")
  Rel(syncOrchestrator, githubGateway, "14. Continues with the next project after jitter/backoff")
```

## Failure branches

- If authentication fails, cached data remains visible and is marked stale.
- If any page fails or is malformed, that project's previous complete summary snapshot remains active.
- Ignored PRs synchronize but do not create attention counts or notifications.
- Quitting Reviewrr cancels all poll operations and leaves no daemon or helper process.
- Polling does not extend the seven-day last-explicit-open cache TTL.

## Key

- Sequence numbers are part of relationship labels.
- SQLite commits occur only after a complete authoritative response for the requested scope.
