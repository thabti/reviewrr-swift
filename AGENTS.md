# AGENTS.md

Rules for anyone — human or agent — writing code in this repository.

Reviewrr is a **native SwiftUI macOS app**. Several documents under `docs/` were written for an
earlier React/Wails implementation: their product requirements still hold, their stack details do
not. `docs/swift-workplan.md` is the implementation plan of record.

## Stack

- SwiftUI, macOS 14 deployment target, Swift 5 language mode.
- **No third-party dependencies.** Foundation, SwiftUI, Security, UserNotifications only. Provider
  and GitHub APIs are called directly with `URLSession`.
- The Xcode project is generated: `project.yml` → `xcodegen generate`. Files added under
  `Sources/Reviewrr` are picked up automatically; never hand-edit `Reviewrr.xcodeproj`.
  `Supporting/Info.plist` is generated the same way — change the `info:` block in `project.yml`, not
  the plist. It exists as a real file rather than `GENERATE_INFOPLIST_FILE` because Xcode silently
  drops custom keys from a generated plist, and `ReviewrrGitHubClientID` is one.

```bash
make generate   # regenerate the project
make build      # debug build
make run        # build and launch
make test       # unit tests
```

Fast whole-module check without touching the project or build directory:

```bash
xcrun swiftc -typecheck -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target arm64-apple-macos14.0 $(find Sources/Reviewrr -name '*.swift')
```

## Layout

| Path | Contents |
| --- | --- |
| `Sources/Reviewrr/App` | `@main` entry point, scenes, commands |
| `Sources/Reviewrr/Models` | Domain types and Codable GitHub payload shapes |
| `Sources/Reviewrr/Services` | GitHub transport, Keychain, diff parsing, AI providers, polling |
| `Sources/Reviewrr/ViewModels` | `@MainActor` `ObservableObject` feature models |
| `Sources/Reviewrr/Views` | SwiftUI views, grouped per feature |
| `Sources/Reviewrr/Design` | `Theme` tokens |
| `Tests/ReviewrrTests` | XCTest unit tests |

`ViewModels/` and `Services/` compile into the unit-test bundle, which excludes `Views/`. **Nothing
in those two directories may reference a view type.**

## Shared contracts

Additive changes only — never rename or remove an existing field or exported signature.

- `Services/GitHubAPI.swift` — the single HTTP transport: request building, auth, error
  normalization, `Link` pagination, GraphQL, rate-limit and OAuth-scope headers, and `GitHubHost`
  for GitHub.com and Enterprise Server. Every GitHub-facing service goes through it.
- `Services/AppContext.swift` — how a feature model reaches the API, token, and settings. Take an
  `AppContext` in your initializer; use `AppContext.stub()` in tests.
- `Services/AI/AIEngine.swift` — the AI feature's entry point. Providers, prompts, the analysis
  cache, the session store, and the heuristic fallback are that module's business: reach them
  through `AIEngine` and the value types it returns, not directly. A view or view model that
  constructs a provider, assembles a prompt, or computes a cache key is in the wrong layer.
- `Models/Settings.swift` — `AppSettings` decodes field-by-field with defaults, so adding a property
  never invalidates a stored blob.
- `Services/KeychainStore.swift` — all secrets, keyed by account (`github-token`, `ai.<provider>`).
- `Design/Theme.swift` — colours, mono fonts, `reviewrrCard()`.

## Product rules that are not negotiable

- **GitHub is the source of truth.** Reviewrr caches and drafts locally; every write to GitHub is an
  explicit human action.
- **AI is read-only.** It never approves, rejects, posts a comment, or edits code. A reviewer turns
  an answer into a local draft. AI output stays visually distinct from GitHub comments and drafts.
- **No background daemon.** Polling runs only while the app is open.
- **Tokens live in the Keychain.** Never log, print, persist, or put a credential in an error
  message. Mask it when displaying.
- Never claim a capability the code does not have — repository-wide retrieval, resolved state, or
  freshness must be reported honestly, including when it is unavailable.

## Style

- Comments explain **why**, not what. Match the surrounding density and tone; the existing code
  documents non-obvious decisions (cache policy, error distinctions, retain cycles) and skips
  narration of the obvious.
- Feature state belongs in that feature's `ObservableObject`, not in `AppModel`.
- Errors must be actionable: GitHub's own message plus a remediation sentence.
- Every control has an accessibility label, a keyboard path, and a visible focus state. Light and
  dark must both work.
- Design for the empty, loading, error, offline, and no-token states — never leave one blank.

## Parallel work

When several agents work at once, `docs/swift-workplan.md` assigns files by track. Edit only files
your track owns; a type check will surface other tracks' in-progress files, which are theirs to fix,
not yours. Prefix new type names with their feature so parallel tracks do not collide.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`,
`test:`, `chore:`, with an optional scope — `feat(dashboard): watched project inbox`.
