# Jira issue links

A pull request usually says which ticket it belongs to — in the title, in the
description, or only in the branch name. Reviewrr finds those keys and turns
them into links to your Jira.

Configured in **Settings ▸ Integrations** (⌘, then Integrations, or "Jira Issue
Links" in the command palette). Off until an address is set.

## Cloud and self-hosted

Both build the same permalink, `<address>/browse/<KEY>`:

| | Address | Example link |
| --- | --- | --- |
| Jira Cloud | `https://your-team.atlassian.net` | `https://your-team.atlassian.net/browse/EC-1013` |
| Jira Server / Data Center | `https://jira.example.com`, context path included (`…/jira`) | `https://jira.acme.com/jira/browse/EC-1013` |

The address field tolerates what a reviewer will actually paste: a trailing
slash, several of them, a missing scheme, or a whole `…/browse/EC-1013` copied
from an open issue. The pane shows the normalised address it will use.

**Reviewrr never calls the Jira API.** It builds links and nothing else — no
Jira credential is asked for or stored, so an instance behind a VPN works
exactly as well as Atlassian's cloud, and a pull request's title is never sent
to a tracker.

If a proxy rewrites Jira's permalink path, `browsePath` is configurable
(`browse` by default).

## Recognising a key

A regular expression, defaulting to Jira's own shape:

```
[A-Z][A-Z0-9]{1,9}-[0-9]+
```

Two characters minimum in the project key, because a one-letter prefix turns
every `A-1` in prose into a link. An invalid pattern — which a reviewer editing
this field will pass through on the way to a valid one — means "no matches",
never a crash.

**Naming your projects is the cure for false positives.** A diff full of
`UTF-8`, `SHA-256` and `HTTP-2` matches the pattern; an allow-list of project
keys (`EC, MW`) matches nothing but your own.

The pane carries a live preview: type a sample line and it shows every key
found and the exact URL each one will open. Every other field in it is a guess
until that link works.

## Where it looks

Individually switchable: the title, the description, the branch name, and
comments and review threads. All on by default — "anywhere" is the point, and a
key that was only ever written in `feature/EC-1013-add-invites` is exactly the
one worth rescuing.

Keys are deduped across sources and ordered title → description → branch, so
the most deliberate mention wins the first chip.

## Where the links appear

- **Pull request header** — every key it mentions, as chips. Right-click to
  copy the link or the key.
- **Inbox rows** — the first key only. The inbox is a scanning surface; the
  pull request's own header has the full set.
- **Descriptions, comments and review threads** — bare keys in prose become
  links in place.
- **Command palette** — "Open EC-1013 in Jira", one per key, searchable by key
  or project.

Prose linking is a Markdown rewrite before parsing, which is why a key works in
a table cell or a list item with no extra code. Three things it must not touch,
and does not: a key inside a code span or fenced block (that is code), a key
that is already a link (wrapping a link in a link renders as neither), and a
key that is part of a longer one — `EC-1013` never half-matches inside
`EC-10131`.

## Where the rules live

- `Models/IssueTracker.swift` — the settings, the normalised address, and
  `IssueKeyDetector`.
- `Models/IssueKeyLinker.swift` — the prose rewrite, including the code-span
  and existing-link guards.
- `Views/IssueKeyChips.swift` — the chips, and the `issueTracker` environment
  value they read.

Both models are pure and covered by `Tests/ReviewrrTests/IssueTrackerTests.swift`.
