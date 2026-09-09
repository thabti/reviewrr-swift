# Notifications

Reviewrr can post a macOS notification when a watched project changes. Polling
runs only while the app is open — there is no background daemon and no push
channel, so nothing arrives while Reviewrr is quit.

Everything below lives in **Settings ▸ Notifications** (⌘, then Notifications,
or "Notification Settings" in the command palette).

## Permission

The permission prompt goes up when the reviewer turns notifications on, and at
no other time. An unprompted panel at launch is the fastest way to be refused
permanently, and a refusal is much harder to come back from than a switch.

The pane reports what macOS currently thinks, including the state that looks
exactly like a broken app: **allowed, but banners are off**. It offers a link
straight to System Settings ▸ Notifications, a "Check Again", and a **test
notification** so the reviewer can see what their settings actually produce
without waiting for a real pull request.

Clicking a notification opens that pull request in Reviewrr — the same
destination a `reviewrr://` deep link reaches.

## What counts as a change

A poll only ever sees two snapshots of a row, so "updated" has to be derived.
A bumped `updatedAt` is deliberately **not** a notification: forges move it for
a label edit, a board move, or a description tweak, and an alert that says only
"something happened" is one a reviewer turns off entirely.

Instead each real change is named, and each is a separate switch:

| Trigger | Derived from | On by default |
| --- | --- | --- |
| New commits | the head SHA moved | yes |
| New comments | the comment count went up | no |
| Review approved or changes requested | the review decision changed | yes |
| Checks passed or failed | the CI state changed | no |
| Draft marked ready for review | draft → open | yes |
| Merged | not merged → merged | yes |
| Closed without merging | live → closed | yes |
| Your review is requested | the reviewer joined the requested list | yes |

Comments and checks are off by default: a chatty pull request or a flaky
pipeline would otherwise notify all afternoon.

Two cases that look like changes and are not, both guarded: a **field
arriving** (search-sourced rows carry no head SHA, and checks report `unknown`
until they exist) and a project's **first sync**, which has nothing to compare
against — watching a repository must not notify once per open pull request.

## Which pull requests

- **Scope** — everything on watched projects, only ones you're involved in
  (review requested, assigned, authored, or commented on), or only reviews
  requested from you.
- **Your own pull requests** — off by default. You know you opened it, and its
  checks and review activity are the loudest source there is. Recognised by
  login where one is known, and by the `authored` bucket otherwise.
- **Drafts** — off by default.
- **Labels** — an optional allow-list. Empty means any label, which the pane
  says rather than leaving to inference.

## How they arrive

Sound on or off; one Notification Centre thread per project; and a cap — past
*n* changes in one poll, a single summary instead of a stack of banners, for
the reviewer who comes back from lunch to a forty-row sync.

**Stay quiet while I'm using Reviewrr** is on by default: the activity is
already on screen, and the dashboard's bell has it either way.

**Quiet hours** silence a window of the day. A start later than the end wraps
midnight (22 → 8), and a start *equal* to the end silences the whole day — the
reviewer asked for silence, and the other reading delivers everything, which is
the wrong direction to be wrong in.

## Per project

A watched project can narrow the global rules, never widen them:

- **Follow global settings** (default)
- **Only when my review is requested** — for the one repository that is too
  busy to hear about in full
- **Never notify** — silent, but still counted and still in the feed

Muting is the blunter instrument, and it is in this pane as well as on the
dashboard sidebar and in the command palette: a muted project contributes
nothing at all — no notifications, no unread counts, no activity feed entries.
The bell button beside each project toggles it.

## Notifications need polling

They come from polling and nowhere else, so the pane says so when polling is
off — with a switch to turn it back on — rather than leaving a screen of live
controls that cannot fire.

## Two separate opt-ins

The dashboard's **activity feed** (the bell) and **system notifications** are
independent. The feed needs no permission and records everything a poll found,
marking which entries also went out as notifications. Refusing notifications at
the OS level never costs the reviewer the feed.

## Where the rules live

- `Models/NotificationPreferences.swift` — the settings, and quiet hours.
- `Models/PRChange.swift` — `PRChangeDetector` (what moved) and
  `NotificationPolicy` (whether it should interrupt anyone). Both pure, both
  covered by `Tests/ReviewrrTests/NotificationTests.swift`.
- `Services/NotificationService.swift` — permission, delivery, foreground
  presentation, click-through.
- `Services/Inbox/ActivityNotifier.swift` — the feed, per-poll batching, and
  the wording.

The split is deliberate: "should this notify?" is a rule with a dozen inputs,
and a rule that can only be checked by watching Notification Centre is a rule
nobody checks.
