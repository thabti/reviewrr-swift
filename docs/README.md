# Reviewrr documentation

Reviewrr is a native SwiftUI app for macOS: a dashboard of watched projects and a cross-repository
pull-request inbox, a focused review workspace over the diff, and AI available when a reviewer wants
deeper context.

## Current

- [`README.md`](../README.md) — the project's front page: what it is, how to run it, what it supports
- [User journey](user-journey.md) — the review loop end to end, mapped to the code that implements it
- [Architecture](architecture.md) — surfaces, layers, transport, wiring, storage
- [Work plan](swift-workplan.md) — implementation plan of record and file ownership
- [Roadmap](roadmap.md) — what is built, what is bounded, what is planned
- [Product vision](product-vision.md) — the problem, positioning, and principles
- [GitHub sign-in](githubauth.md) — signing in, shipping an OAuth client ID, and what each failure means
- [GitLab sign-in](gitlabauth.md) — pointing Reviewrr at a GitLab instance and authenticating with a token
- [Jira issue links](issue-tracker.md) — finding issue keys in a pull request and linking them
- [Notifications](notifications.md) — what interrupts a reviewer, and the rules behind it
- [AI providers](ai-providers.md) — the provider matrix and how to add one
- [Performance](performance.md) — the scroll-frame budget, how to measure it, and what was slow
- [Contributing](contributing.md) — conventions and validation
- [`AGENTS.md`](../AGENTS.md) — stack, layout, shared contracts, non-negotiable product rules

## Historical

These predate the current macOS implementation. They describe a Go backend, a Wails or browser
runtime, and a SQLite cache that the code does not have. Read them for the product thinking, not for
the implementation. Two are exceptions: [AI review result v1](architecture/ai-review-result-v1.md)
is the schema the app implements today, and the ACP boundary in
[ADR-0004](architecture/decisions/0004-acp-review-only.md) is the boundary the Swift `ACPClient`
enforces — in the app itself rather than in a Go host.

- [MVP product and delivery plan](mvp-plan.md)
- [Testing AI providers](testing-ai.md) — the browser build's local AI server; the macOS app spawns
  agent CLIs directly instead, see [AI providers](ai-providers.md)
- [Architecture overview](architecture/README.md)
- [System context](architecture/c4-context.md)
- [Container architecture](architecture/c4-containers.md)
- [Go backend components](architecture/c4-components-go-backend.md)
- [React frontend components](architecture/c4-components-react-frontend.md)
- [Pull-request synchronization flow](architecture/c4-dynamic-pr-sync.md)
- [ACP-assisted review flow](architecture/c4-dynamic-ai-review.md)
- [AI review result v1](architecture/ai-review-result-v1.md)
- [GitHub review submission flow](architecture/c4-dynamic-submit-review.md)
- [Desktop deployment](architecture/c4-deployment.md)

### Architecture decisions

- [ADR-0001: Wails v2 desktop architecture](architecture/decisions/0001-wails-v2.md)
- [ADR-0002: GitHub access through `gh`](architecture/decisions/0002-gh-cli-integration.md)
- [ADR-0003: SQLite as a local cache](architecture/decisions/0003-sqlite-cache.md)
- [ADR-0004: ACP review-only boundary](architecture/decisions/0004-acp-review-only.md)
- [ADR-0005: Local drafts and atomic review submission](architecture/decisions/0005-review-drafts.md)
- [ADR-0006: Watched projects and in-process polling](architecture/decisions/0006-project-watchlist-polling.md)
- [ADR-0007: Seven-day cache retention with durable human drafts](architecture/decisions/0007-retention-policy.md)
- [ADR-0008: Structured right-panel AI review](architecture/decisions/0008-structured-ai-review.md)

## Historical screenshots

- [First-run home](img/home.png)
- [Settings](img/settings.png)
- [Demo workspace, dark](img/demo-dark.png)
- [Demo workspace, light](img/demo-light.png)

These captures show the earlier browser UI at 1440x900 and have not been retaken for the macOS app.
The files in [`design/`](../design/) remain historical layout references.
