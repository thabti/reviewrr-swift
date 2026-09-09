# Architecture

Reviewrr is a native SwiftUI application for macOS 14 and later, built around a pull request as the
primary unit of review. There is no server: the app talks directly to GitHub and to whichever AI
provider the reviewer configures, and keeps local state in the Keychain, `UserDefaults`, and files
under Application Support.

> An earlier implementation of this product was a Vite/React web app with an optional Hono server.
> `docs/product-vision.md`, `docs/mvp-plan.md`, and `docs/architecture/**` still describe the product
> correctly; where they describe Go, Wails, React, or an HTTP server, this document supersedes them.

## Surfaces

```
Window
├── Sign in                no credential to work with
│     ├── Continue with GitHub — OAuth device flow
│     ├── a personal access token, folded away
│     └── the demo pull request, or continue without an account
├── Dashboard              no pull request open
│     ├── watched projects, per-project unread counts, freshness, errors
│     └── cross-repository PR inbox: buckets, filters, search, local status
└── Review workspace       a pull request is open
      ├── left    file tree, category filters, review progress
      ├── center  split/unified diff, drafts, inline threads
      └── right   AI (Ask · Analysis · Findings) | Conversation (timeline · checks)

└── Settings              a surface, not a floating window
      ├── sidebar  Account · General · Notifications · Integrations · Watchlist · AI · Data
      └── detail   the pane, with its heading pinned above it
```

Opening a PR replaces the whole surface rather than pushing a sheet, because review needs the window.
Settings works the same way and for the same reason: a tab bar caps out at six two-word labels, and a
fixed-width utility panel sat on top of the thing being configured while scrolling panes that would
have fit in the window behind it. `⌘,` and every "not configured" affordance in the app route through
`EnvironmentValues.openSettingsPane`, so a view that offers the remedy never has to hold `AppModel`.

The sign-in surface is skippable: the demo pull request and a read-only dashboard both work without
a credential, so a screen that could not be dismissed would misrepresent the app. It is checked last
of the surfaces that need an empty window — an open pull request or a load in flight is never
interrupted by it — and "not looked at the Keychain yet" counts as signed in, so a reviewer who has
a token never sees it flash past. The menu bar and ⌘K bring it back.

## Layers

| Layer | Location | Responsibility |
| --- | --- | --- |
| Transport | `Services/GitHubAPI.swift`, `GitLabAPI.swift` | One HTTP path per forge |
| Endpoint clients | `Services/GitHubClient.swift`, `GitLabClient.swift`, `GitHubAuth.swift`, `ChecksClient.swift`, `ThreadsClient.swift`, `Inbox/InboxService.swift`, `Inbox/GitLabInboxService.swift` | Which paths make which domain object |
| Forge dispatch | `Services/Forge.swift`, `ForgeClient.swift`, `ForgeCredential.swift`, `GitLabMapper.swift` | Which forge a host speaks, and how its payloads map onto the domain models |
| Feature models | `ViewModels/*.swift` | `@MainActor ObservableObject` state per feature |
| Views | `Views/**` | SwiftUI, grouped per feature |
| Persistence | `KeychainStore`, `DraftStore`, `WatchlistStore`, `LocalStatusStore`, `AnalysisCache`, `AppSettings` | Local state, each with one owner |

`ViewModels/` and `Services/` compile into the unit-test bundle, which excludes `Views/`; nothing in
those directories may reference a view type.

## Transport

`GitHubAPI` is the single place that builds a request, attaches auth, and turns a response into
either a decoded value or a normalized `GitHubError`. It provides typed `get`/`getAllPages`/`post`,
raw bodies, and GraphQL, and exposes the two response headers features actually need: rate-limit
budget and `X-OAuth-Scopes`.

`ForgeHost` selects GitHub.com, a GitHub Enterprise Server appliance (`https://host/api/v3`,
`/api/graphql`), or a GitLab instance (`https://host[/path]/api/v4`). It is persisted in
`AppSettings`, so every client picks up a host change without re-wiring. A GitLab host keeps any
path it was given, because GitLab is commonly installed under a subdirectory; an Enterprise host
rebuilds its API root from the bare hostname. See [Forges](#forges).

Errors are distinguished so remediation can differ: `noToken` (no credential was sent) versus
`unauthorized` (one was and GitHub rejected it); `notFound(hadToken:)`, because a private repository
404s exactly like a missing one; primary and secondary rate limits, including the `Retry-After`
variety that does not zero `X-RateLimit-Remaining`; validation errors carrying GitHub's own
`errors` payload; and decoding failures naming the key and path that did not match.

GraphQL exists for the three things REST cannot express: a PR's aggregate `reviewDecision`,
thread-level `isResolved`, and check rollups batched per project. Every GraphQL path degrades to
REST-only data with the missing state honestly labelled rather than guessed.

## Wiring

`AppModel` owns the loaded PR, the local draft, and one instance of each feature model. It hands
them an `AppContext` — closures for `api()`, `token()`, `saveToken()`, `forgetToken()`, `basic()`,
`saveBasic()`, `reloadCredential()`, `settings()`, and `updateSettings()` — so values resolve at call
time and a test can substitute `AppContext.stub()`.

`saveToken` both stores and publishes, deliberately as one closure: when they were separate, the
device flow wrote the Keychain itself and forgot to publish, so a successful sign-in reached the
Account pane and nothing else until the next launch.

```
AppModel
├── DashboardModel     watchlist, inbox, polling, activity
├── AuthModel          credential, scopes, host, device flow
├── WorkspaceModel     file tree, filters, progress, navigation  (shared instance)
├── ConversationModel  threads, replies, resolution, timeline, checks
└── AIModel            providers, analysis, ask
```

`WorkspaceModel` is a shared instance because the file tree and the diff pane are siblings under the
split view with no common ancestor to hang an environment object from.

Cross-feature connections are made in exactly one place each: loading a PR configures the workspace,
AI, and conversation models and marks the PR opened; a successful review submission marks it
reviewed; and the conversation model's thread state is bridged into the file tree so the badge can
show unresolved counts instead of raw thread counts.

## Loading a pull request

1. `PRReference.parse` accepts a PR URL (with `/files`, `.diff`, or `.patch` suffixes) or
   `owner/repo#123`.
2. `AppModel.load` fetches PR metadata, files, issue comments, reviews, and review comments
   concurrently, following `Link` pagination.
3. Patches are parsed into typed hunks and numbered lines by `DiffParser`; the split view pairs
   deletion and addition runs into replace rows.
4. Drafts for that PR are loaded from disk; the submit flow re-validates anchors against the current
   patch before anything is sent.
5. Threads and checks load alongside rather than blocking the diff.

Public PRs read without a token, subject to the anonymous rate limit. Private PRs and review
submission need a credential with repository access.

## Dashboard and polling

The watchlist is a persistent list of `owner/repo` entries in Application Support. Each project syncs
its PRs (all states) and is enriched by one batched GraphQL query for review decision, check rollup,
and diff stats — the REST list endpoint omits those. Reviewer buckets (needs review, assigned,
authored, participated) come from the search API across every repository the token can see. On a
GitLab host the same rows come from typed filters on `/merge_requests` instead, and "participated"
is empty — GitLab has no "merge requests I commented on" filter to stand behind it.

Polling runs only while the app is open. Each project has its own interval (default five minutes)
staggered with ±20% jitter and backed off exponentially to thirty minutes on failure or rate
limiting. Refreshes coalesce, cancel cleanly, and never block the UI. There is no daemon and no
background service.

Local review status (`In review`, `Reviewed`, `Ignored`) is Reviewrr's own state, persisted next to
the watchlist. Opening a PR starts `In review`; a successful submission sets `Reviewed`; an ignored
PR stays ignored across new commits. `Unseen` and `Updated since review` are derived, not stored.

## AI

Providers implement one protocol (`complete`, optionally `stream`) and are described by a registry:
Anthropic, OpenAI, OpenRouter, an OpenAI-compatible endpoint, and local Ollama. Keys live in the
Keychain under per-provider accounts and go straight to the provider — never to Reviewrr.

Analysis produces the versioned `reviewrr.ai-review.v1` result documented in
`docs/architecture/ai-review-result-v1.md`: scope, overview, review order, file summaries, findings
with `path:line` evidence, test gaps, architecture impact, reviewer questions, limitations, and
skipped files. Invalid output gets one repair attempt, then falls back to clearly labelled
unstructured text. Context is PR-scoped and explicitly bounded — there is no repository-wide
retrieval today — and the lead file is truncated to fit rather than dropped, so an analysis is never
run against an empty diff. Results cache by PR key, head SHA, provider, model, prompt version, and
content hash.

With no provider configured, a heuristic analyzer runs instead: layer grouping, per-hunk summaries,
complexity estimates, and a scan for leaked credentials, disabled TLS, `eval`, focused or skipped
tests, conflict markers, debug statements, empty catches, and suppressed checks. It is labelled as
heuristic, never as AI.

AI is read-only throughout. It cannot approve, reject, post, or edit; a reviewer turns a cited answer
into a local draft comment by an explicit action, and AI output is styled distinctly from GitHub
comments and from the reviewer's own drafts.

## Deep links

`reviewrr://{owner}/{repo}/{number}` — for example `reviewrr://acme/web-app/482` — opens a pull
request from anywhere on the Mac that can hold a link: a chat message, `open` in a terminal, a
Shortcut, a bookmark. The scheme is registered as a Viewer URL type, so a link launches the app when
it is not already running. `reviewrr://acme/web-app/pull/482` is accepted as well, so pasting a
GitHub path after the scheme works.

A link names no GitHub host. It resolves against whichever host Reviewrr is configured for, so the
same link works for everyone on a team and no appliance hostname leaks into a chat message.

The owner arrives in the URL's authority component, which `URL.host` lowercases. `DeepLink.parse`
reads it out of the raw string instead: Reviewrr keys drafts, viewed-file state, and the recent list
on `owner/repo#number`, and a lowercased owner would quietly split one pull request's local state in
two. The number is checked as digits rather than handed to `Int`, which would accept `+482` and
`-3`.

A link that arrives with no credential to fetch it is held, not dropped: the sign-in screen appears,
and the pull request opens as soon as a token lands. Clicking a link and landing on a sign-in screen
that then forgets what you clicked is the worst version of this feature.

Links are produced from the inbox row's context menu, the Review menu, and ⌘K — a link nobody can
produce is a link nobody sends. The demo has no link: its fixture repository does not exist, so one
would resolve nowhere.

## Forges

Reviewrr speaks to GitHub (github.com and Enterprise Server) and to GitLab (gitlab.com and
self-managed). A host record carries a `forge`, and that is what the parts that genuinely differ
branch on — API roots, auth headers, pagination, and the word for a proposed change.

The domain models stay GitHub-shaped, because GitHub came first and duplicating them per forge would
mean every view knowing which service a review came from. GitLab is *mapped* onto them:

| GitLab | Becomes | Note |
| --- | --- | --- |
| Merge request (`iid`) | `PullRequest` (`number`) | The `iid` is what a reviewer types; the global `id` is not |
| `/diffs` entries | `PRFile` | GitLab sends no line counts, so they are counted from the patch |
| Discussion | `ReviewThread` | Replies get the root note's id, so the app's own `groupedIntoThreads()` rebuilds GitLab's grouping |
| Note `resolved` | `ThreadsClient.ThreadState` | The same type GitHub's GraphQL resolution produces, so the whole conversation panel is shared |
| Approval | `Review(.approved)` | Nothing maps to `.changesRequested` — GitLab has no rejection object |
| Pipeline job | `CheckRun` | Jobs, not pipelines: "which job failed" is the reviewer's question |
| Draft note + `bulk_publish` | An atomic review submission | The endpoint that makes GitLab fit the app's stage-then-submit model |

`ForgeClient` dispatches, method for method against `GitHubClient`'s surface, so `AppModel`'s
five-way load fan-out, the draft store, and the diff pane needed no changes to review a merge
request. Two protocols cover the other capabilities — `ForgeInboxProviding` (watched-project rows,
reviewer buckets, project validation) and `ForgeDirectoryProviding` (what this credential can see) —
and `ForgeServices` is the single place that maps a forge to an implementation. Before that, three
`switch host.forge` statements sat in `DashboardModel` and one in `RepositoryPickerModel`, each
constructing a different service with different arguments; a third forge meant a fourth arm in each,
and the odds of adding one and forgetting another grow with every call site.

No forge's URL grammar lives on a shared model. `PRReference` carries `owner`, `repo`, `number` and
a `key`; it used to answer `apiPath` as `/repos/owner/repo/pulls/n`, which quietly assumed which
server a reference was for. `GitHubClient.pullRequestPath` and `GitLabAPI.mergeRequestPath` own
their own shapes.

## Three hosts at once

GitHub.com, a GitHub Enterprise appliance and a self-managed GitLab work **at the same time**, not
one at a time:

| Concern | How it is per host |
| --- | --- |
| Credentials | `ForgeCredentialStore`, keyed by `ForgeHost.identityKey`; github.com keeps its legacy account name so existing installs stay signed in |
| Watched projects | `WatchedProject` carries its own `host`, and each project syncs against **that** host — not whichever one is selected |
| Reviewer buckets | Fetched concurrently from every host with a credential and merged; one unreachable host is named rather than blanking the queue |
| Caches | Drafts, inbox and repository caches all key on the host |
| Opening a change | The inbox row carries its host, and `AppModel.open(_:host:)` adopts it |

`DashboardModel.syncHosts` is the active host plus the host of every watched project, derived rather
than stored: the watchlist already records each project's host, so a separate list of configured
hosts in settings would be a second source of truth to drift out of agreement with it.

The active host still exists, because a review *is* a session on one server — the workspace, the
draft store, the conversation panel and the AI panel all read it. Opening a row from another host
switches it, so all of them agree at once.

Three things have no GitLab equivalent and are reported as absent rather than approximated:
"request changes" (GitLab has approval and its absence), the inbox's "participated" bucket (no
"merge requests I commented on" filter), and device-code sign-in (GitLab's OAuth needs a registered
redirect URI this app does not have).

A credential is per host and always was — there was simply nowhere to put a second one before.
`ForgeCredentialStore` keys the Keychain by `ForgeHost.identityKey`, and github.com keeps the account
name it has always used so an existing install is not silently signed out. A credential has two
independent parts: a token, and HTTP Basic for an instance behind a Basic-protected front door.
GitLab carries both on one request (token in `PRIVATE-TOKEN`, Basic in `Authorization`); GitHub
cannot, since a token needs `Authorization` itself, so there the token wins and the Account pane says
the Basic credential is not being sent.

TLS uses the system trust store, with no code that could weaken validation. A private CA is trusted
by installing it on the Mac, and an untrusted certificate is reported as itself — naming the host and
that remedy — rather than as a generic network error.

## Signing in

Sign-in is the OAuth **device flow**, not a browser redirect. GitHub's authorization-code flow
requires a `client_secret` on the token exchange and does not support PKCE, so an app with no server
of its own cannot use it without shipping a secret inside the bundle — where it is not a secret. The
device flow exchanges a device code using only the public client ID. That is why signing in shows a
code to type on github.com rather than opening a redirect URL, and why no client secret appears
anywhere in this repository.

The client ID *is* public — it travels in every OAuth URL — so baking it into the bundle is correct.
`GitHubOAuthApp` resolves it from three places, most specific first:

| Source | Set by | Notes |
| --- | --- | --- |
| Typed into Settings | The reviewer | Wins: the only one changeable without a rebuild or relaunch |
| `REVIEWRR_GITHUB_CLIENT_ID` | The environment | The development override, like `REVIEWRR_GITHUB_TOKEN` |
| `ReviewrrGitHubClientID` | The build, via Info.plist | How a distributed build ships a working button |

An empty value and an unexpanded `$(REVIEWRR_GITHUB_CLIENT_ID)` both read as "not configured" rather
than being sent to GitHub as a client ID. This repository ships no OAuth app of its own, so a build
stamps one in with `xcodebuild … REVIEWRR_GITHUB_CLIENT_ID=…`; with none, sign-in offers a personal
access token and a field to paste a client ID into. The client-ID field is hidden entirely on a
configured build — nobody should need to know what an OAuth client ID is to sign in.

The requested scope is `repo read:org`, exactly what `GitHubScopeEvaluator` calls sufficient, so a
token obtained by signing in passes the Account pane's own scope check.

## Local storage

Nothing outside the Keychain is encrypted; the user account is the security boundary.

| Where | Contents |
| --- | --- |
| Keychain (`com.sabeur.reviewrr`) | GitHub token, per-provider AI keys |
| `UserDefaults` `reviewrr.settings` | Appearance, diff layout, hidden categories, host, polling, notifications, AI provider/model |
| `UserDefaults` `reviewrr.auth` | The reviewer-supplied OAuth client ID, for builds that ship without one |
| `~/Library/Application Support/Reviewrr/drafts/` | Unsent review drafts and viewed-file state, per PR |
| `~/Library/Application Support/Reviewrr/watchlist.json` | Watched projects |
| `~/Library/Application Support/Reviewrr/local-pr-status.json` | Local review status per PR |
| Application Support (analysis cache) | Cached AI analyses keyed by revision and model |

Drafts are never expired automatically — they survive until submitted or explicitly discarded.

## Drafts and submission

A draft comment records the PR key, path, side, line, and the head SHA visible when it was written.
Before submitting, every comment is re-validated against the current patch: the file must still be in
the PR, the line must fall inside a current hunk on the requested side, and the body must be
non-empty. The summary and all valid comments go to GitHub as one review. A failed submission leaves
every draft intact; a confirmed success clears them.

Reviewrr never exposes merge, checkout, commit, push, or code-edit actions.
