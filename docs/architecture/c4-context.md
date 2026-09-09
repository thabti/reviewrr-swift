# System context

This diagram shows Reviewrr as a local desktop system that watches several GitHub projects while focusing on one PR revision at a time.

```mermaid
C4Context
  title System Context diagram for Reviewrr MVP

  Person(reviewer, "Code Reviewer", "Reviews GitHub pull requests")

  System(reviewrr, "Reviewrr", "Local-first desktop PR review workspace")
  System_Ext(localRepo, "Optional Local Git Repository", "Existing project source selected by the reviewer")
  System_Ext(ghCli, "GitHub CLI", "Owns GitHub authentication and API access")
  System_Ext(github, "GitHub", "Authoritative PRs, discussions, checks, and reviews")
  System_Ext(acpAgent, "ACP Coding Agent", "Provides advisory code explanations and review findings")

  Rel(reviewer, reviewrr, "Maintains watched projects and performs human reviews", "Desktop UI")
  Rel(reviewrr, localRepo, "Optionally resolves project identity", "Read-only git/filesystem")
  Rel(reviewrr, ghCli, "Polls watched projects, fetches PR revisions, and submits confirmed reviews", "Process/stdin/stdout")
  Rel(ghCli, github, "Authenticates and invokes APIs", "HTTPS")
  Rel(reviewrr, acpAgent, "Starts review sessions and exchanges updates", "ACP v1/JSON-RPC/stdio")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Notes

- GitHub is the remote source of truth.
- Reviewrr does not receive or store the token used by `gh`.
- Reviewrr polls watched projects only while the desktop application is open.
- The ACP agent cannot submit a GitHub review or annotate the diff; only the reviewer can trigger GitHub comments through Reviewrr.
- “Read-only repository” is a Reviewrr contract. A configured local agent is a trusted process unless separately sandboxed.

## Key

- **Person:** the human reviewer.
- **System:** Reviewrr, the product being designed.
- **External system:** software or data owned outside Reviewrr's runtime boundary.
- **Arrow:** initiator and purpose of a one-way interaction.
