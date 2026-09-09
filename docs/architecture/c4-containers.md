# Container architecture

This diagram separates the watched-project UI, native Go host, durable database, and seven-day managed review cache from external processes.

```mermaid
C4Container
  title Container diagram for Reviewrr MVP

  Person(reviewer, "Code Reviewer", "Reviews GitHub pull requests")
  System_Ext(localRepo, "Local Git Repository", "Opened without changing refs or files")
  System_Ext(ghCli, "GitHub CLI", "Authenticated GitHub command and API client")
  System_Ext(github, "GitHub", "PR and review source of truth")
  System_Ext(acpAgent, "ACP Coding Agent", "User-selected advisory agent process")

  System_Boundary(reviewrr, "Reviewrr Desktop Application") {
    Container(reactUi, "Review Workspace UI", "React, TypeScript, Monaco", "Project-grouped PR inbox, human diff review, drafts, and right-panel AI")
    Container(goHost, "Native Application Host", "Go, Wails v2", "Coordinates watchlist polling, Git mirrors, GitHub, review, and ACP workflows")
    ContainerDb(sqlite, "Local Database", "SQLite", "Watchlist, PR metadata, personal state, durable drafts, and sync metadata")
    ContainerDb(reviewCache, "Managed Review Cache", "Bare Git plus bounded files", "Exact PR objects, file bodies, ACP context, and seven-day AI data")
  }

  Rel(reviewer, reactUi, "Navigates and confirms review actions", "Native WebView")
  Rel(reactUi, goHost, "Invokes commands and receives streamed events", "Wails bindings/events")
  Rel(goHost, sqlite, "Reads and transactionally writes normalized state", "SQL")
  Rel(goHost, reviewCache, "Creates partial mirrors and prunes expired review artifacts", "git/filesystem")
  Rel(goHost, localRepo, "Optionally discovers project identity", "Read-only git/filesystem")
  Rel(goHost, ghCli, "Polls project summaries and executes typed GitHub operations", "Process/stdin/stdout JSON")
  Rel(ghCli, github, "Reads PRs and submits confirmed reviews", "HTTPS REST/GraphQL")
  Rel(goHost, acpAgent, "Initializes, prompts, cancels, and handles permissions", "ACP v1/JSON-RPC/stdio")
  Rel(acpAgent, reviewCache, "Reads allowed review context", "Filesystem")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Container responsibilities

| Container | Durable | May write source repository | May write GitHub |
| --- | --- | --- | --- |
| React UI | No | No | No |
| Go host | Process lifetime | No | Only after human submit confirmation, through `gh` |
| SQLite | Yes | Not applicable | No |
| Managed review cache | Rebuildable after seven inactive days | No; separate application cache | No |

## Key

- **Container:** a separately executing application or data store.
- **System boundary:** code and data shipped as Reviewrr.
- **External system:** local software/data not packaged as an internal Reviewrr container.
