# Contributing

Read [`AGENTS.md`](../AGENTS.md) first — it defines the stack, layout, shared contracts, and the
product rules that are not negotiable. This page covers conventions and validation.

## Commands

```bash
make generate   # regenerate Reviewrr.xcodeproj from project.yml
make build      # debug build
make run        # build and launch
make test       # unit tests
make bench      # release build on a synthetic 300-file PR, frame probe on
make clean      # remove build/ and the generated project
```

Anything that touches the review workspace's rendering should be measured
before and after — see [performance](performance.md) for `make bench`, the
budgets it reports, and what turned out to be slow.

While iterating, a whole-module type check is much faster than a build and touches neither the
project nor `build/`:

```bash
xcrun swiftc -typecheck -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 $(find Sources/Reviewrr -name '*.swift')
```

## UI conventions

- Colours, mono fonts, and card chrome come from `Design/Theme.swift`. No literal hex or RGB in
  feature views.
- Keep the compact review-workspace density: subtle borders, small rounded cards, monospace diff
  content.
- Support light, dark, and system appearance.
- Every control needs a visible label or `accessibilityLabel`, a keyboard path, and a visible focus
  state.
- Design the empty, loading, error, offline, and no-token states — never leave one blank.
- Errors show GitHub's own message plus a remediation sentence. Never a spinner that silently stops.

## State

Feature state belongs in that feature's `@MainActor ObservableObject`, constructed with an
`AppContext`. `AppModel` holds the loaded PR, the draft, and one instance of each feature model, and
is the only place cross-feature connections are made.

Persist only what must survive a relaunch, and use the existing owner for it: `AppSettings` for
preferences, `KeychainStore` for secrets, `DraftStore` for unsent review work, `WatchlistStore` and
`LocalStatusStore` for the dashboard, `AnalysisCache` for AI results.

Never imply that anything outside the Keychain is encrypted. GitHub tokens go to GitHub; AI keys go
to the selected provider.

## Adding a GitHub call

Go through `GitHubAPI` — it already handles auth headers, host selection, status and error
normalization, `Link` pagination, GraphQL, and rate-limit headers. Add the endpoint to the client
that owns that domain (`GitHubClient`, `ChecksClient`, `ThreadsClient`, `InboxService`,
`GitHubAuth`) rather than issuing a request directly.

Use GraphQL only where REST cannot answer the question, and always degrade to REST-only data with the
missing state labelled honestly rather than assumed.

## Adding an AI provider

Implement `AIProvider` (`complete`, optionally `stream`), register its metadata and models in
`AIProviderRegistry`, and store its key under `KeychainStore.Account.aiProvider(id)`. Keep the
request direct — no SDKs — with an explicit timeout, cancellation, bounded body size, and errors that
preserve the provider's own message without leaking the key. Then document it in
[`ai-providers.md`](ai-providers.md).

## Tests

`Tests/ReviewrrTests` compiles `Models`, `Services`, `ViewModels`, and `Design` directly into the
bundle — `Views/` is excluded, which is why nothing in those directories may reference a view type.

Test pure behaviour: parsing, classification, filtering, merge and rollup logic, interval maths,
state transitions, and codec round trips. Use `AppContext.stub()` instead of touching the network.
Add a focused test beside the behaviour it covers.

Run `make test` before handing work off. For UI work, run the app and check the affected surfaces at
1440×900 and 1280×900 in both appearances: no horizontal overflow, no console exceptions, keyboard
and focus behaviour intact, and readable split and unified diffs.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`,
`test:`, `chore:`, with an optional scope.

```text
fix(diff): keep split sides visible at narrow widths
```
