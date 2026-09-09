# Reviewrr GitHub sign-in

Everything Reviewrr does with GitHub goes through one credential. This document is the guide to it:
how a reviewer signs in, how a build ships a working sign-in button, what each failure means, and
where the code lives.

Three ways in, in the order the sign-in screen offers them:

- **Continue with GitHub.** The OAuth device flow. Approve a short code on github.com and Reviewrr
  receives a token with exactly the scopes it needs. Nothing to paste, nothing to configure — on a
  build that ships an OAuth client ID.
- **A personal access token.** Folded away on the sign-in screen, and always available in
  Settings ▸ Account. The answer for someone who already has a token, whose organization requires
  one, or who is running a build with no client ID.
- **Neither.** The demo pull request runs entirely offline, and the dashboard can be reached
  read-only. Sign-in is skippable because those two things genuinely work without a credential.

Reviewrr never asks for a client secret, and there is nowhere to put one. See
[Why the device flow](#why-the-device-flow-and-not-a-browser-redirect).

## For a reviewer

### Signing in with GitHub

1. Open Reviewrr. With no credential, the window shows the sign-in screen. If it doesn't — you are
   already signed in — use **Reviewrr ▸ Sign In to GitHub…**, or ⌘K and search "sign in".
2. Click **Continue with GitHub**. Reviewrr asks GitHub for a device code and shows it at a size you
   can read from across the room, with a countdown: GitHub gives the code a short, hard lifetime.
3. Click **Open GitHub** (or copy the code and go to the URL shown), enter the code, and approve the
   scopes.
4. Reviewrr is polling while you do that. Approval lands within a few seconds and the window becomes
   the dashboard.

If the code expires before you approve it, the screen says so and offers to start over. Nothing is
left behind — the expired device code is useless to anyone.

A `reviewrr://` deep link clicked while signed out is **held, not dropped**: the sign-in screen
appears, and the pull request the link asked for opens as soon as a token lands. See
[Deep links](architecture.md#deep-links).

### Signing in with a personal access token

Create one at **github.com ▸ Settings ▸ Developer settings ▸ Personal access tokens**, then paste it
into **Use a personal access token instead** on the sign-in screen, or Settings ▸ Account.

| Token type | Grant it | Notes |
| --- | --- | --- |
| Classic | `repo` (or `public_repo` for public repositories only) and `read:org` | Reports its scopes to Reviewrr, so Settings ▸ Account can check them for you |
| Fine-grained | Repository access to the repositories you review, plus "Pull requests: read and write". "Contents: read" as well, for expanding context beyond the diff | Reports **no** scopes — use the repository access check in Settings ▸ Account to confirm what it can see |

`read:org` is what lets organization-owned repositories resolve correctly. Without it a repository
you can see on the web may not resolve in Reviewrr.

Reviewrr recognizes each token format by its prefix (`ghp_`, `github_pat_`, `gho_`, `ghu_`, `ghs_`,
`ghr_`, and pre-2021 40-character hex) and tells you which kind it is holding. Anywhere a token
appears it is masked as `ghp_••••1a2b` — enough to tell two saved tokens apart, never the secret.

### One card per host

Settings ▸ Account lists every host Reviewrr knows — GitHub.com first, always, then whatever you
have added — as a separate card. Each card carries that host's own credential and the actions that
apply to it: **Use This Host**, **Verify**, **Sign Out**, **Remove**.

It used to be a segmented picker with one Sign Out button above it. That described a *selection*:
the credential, its state and the button all silently belonged to whichever segment was chosen, and
someone with a token on github.com and another on an appliance could see one at a time with no way
to tell the other still existed — while the button that removed a credential sat above all of them,
saying nothing about which one it would remove.

The host in use carries an **In use** badge, and it is the only card with a token field: saving a
token stores it for the host Reviewrr is pointed at, and verifying one needs a host to send it to.
Switch to a host first, then paste its token. **Add a host** is its own section at the end, so
"switch to my appliance" and "tell me my appliance's URL" are no longer the same gesture.

GitHub.com can be signed out of but never removed — a Reviewrr with no hosts has nowhere to put the
next token. Removing the host you are using falls back to GitHub.com rather than leaving the app
pointed at a host it no longer knows.

### Checking a credential

Settings ▸ Account answers the three questions worth asking, without opening a pull request:

- **Who am I?** The verified login, the token kind, and the masked token.
- **Can this token do the job?** Granted scopes and a verdict on them — or, for token kinds that
  report no scopes, a note saying so instead of a blank space where a scope list would be.
- **Can it see a specific repository?** Type an owner and repository and Reviewrr probes it
  directly, reporting whether it is visible and whether it is private.

The pane also shows your remaining core and search rate-limit budget and when it resets, so you can
see a limit coming rather than discovering it as a failed request.

### Signing out

**Reviewrr ▸ Sign Out of GitHub**, ⌘K, or Settings ▸ Account. This removes the credential from this
Mac and returns the window to the sign-in screen.

**It does not revoke the token on GitHub.** If a token may have leaked, revoke it at
github.com/settings/tokens. A token obtained by device flow is revoked under
github.com/settings/applications, by revoking the OAuth app's access.

### GitHub Enterprise Server

Settings ▸ Account ▸ Add a host takes a hostname or a full URL. Reviewrr derives the API, GraphQL
and web endpoints from it (`https://host/api/v3`, `/api/graphql`, and `https://host` respectively).

A credential is host-specific and does not carry over, so Reviewrr verifies the current token
against the candidate host **before** saving it: a typo or an unreachable appliance leaves you where
you were rather than stranded on a host that cannot work. Device flow works against Enterprise
Server too — the OAuth app has to exist on that appliance, and its client ID goes in the same place.

## For whoever packages a build

This repository ships **no OAuth app of its own**, so a build straight from a clone has no working
"Continue with GitHub" button — it offers the personal-access-token route and a field to paste a
client ID into. To ship a build where sign-in works out of the box:

### 1. Create the OAuth app

On github.com ▸ Settings ▸ Developer settings ▸ **OAuth Apps** ▸ New OAuth App:

- Any name, homepage URL, and callback URL. The device flow does not use the callback, but GitHub
  requires the field.
- **Enable Device Flow.** This is the setting that matters. Without it every attempt comes back as
  `device_flow_disabled`.

Copy the **Client ID** (`Ov23li…`, or `Iv1.…` for a GitHub App). Do **not** generate a client
secret; nothing here can use one.

### 2. Give it to the build

```bash
xcodebuild -project Reviewrr.xcodeproj -scheme Reviewrr -destination 'platform=macOS' \
  REVIEWRR_GITHUB_CLIENT_ID=Ov23liXXXXXXXXXXXXXX build
```

That lands in the app bundle's `Info.plist` as `ReviewrrGitHubClientID`. A client ID is public by
design — it travels in every OAuth URL — so baking it into a distributed bundle is correct. Verify
it took:

```bash
/usr/libexec/PlistBuddy -c "Print :ReviewrrGitHubClientID" \
  "$(...)/Reviewrr.app/Contents/Info.plist"
```

`Supporting/Info.plist` is generated from the `info:` block in `project.yml` by `xcodegen generate`,
like the project file itself. Change `project.yml`, never the plist. It exists as a real file rather
than `GENERATE_INFOPLIST_FILE` because Xcode silently drops custom keys from a generated plist —
`ReviewrrGitHubClientID` is one, and the failure mode was an app that shipped with no client ID no
matter what the build passed in.

### Where the client ID is read from

`GitHubOAuthApp.resolve` checks three sources, most specific first:

| Source | Set by | Why it sits here |
| --- | --- | --- |
| Settings ▸ Account field | The reviewer, at runtime | Wins: the only one changeable without a rebuild or a relaunch, so ignoring it would make the field look broken |
| `REVIEWRR_GITHUB_CLIENT_ID` | The environment | The development override, mirroring `REVIEWRR_GITHUB_TOKEN` |
| `ReviewrrGitHubClientID` | The build, via `Info.plist` | How a distributed build ships a working button |

Two values are rejected rather than sent to GitHub as a client ID: an empty one, and an unexpanded
`$(REVIEWRR_GITHUB_CLIENT_ID)`, which reaches the bundle verbatim when the build setting is
undefined. Both read as "not configured", which is a sentence the sign-in screen can act on;
`incorrect_client_credentials` from GitHub is not.

Interior whitespace is rejected too. GitHub client IDs contain none, and a pasted line break would
otherwise become an unexplained HTTP 401.

On a build that has a client ID, the client-ID field is hidden entirely. Nobody should need to know
what an OAuth client ID is in order to sign in.

## How it works

### Why the device flow, and not a browser redirect

GitHub's authorization-code flow requires a `client_secret` on the token exchange and **does not
support PKCE**. A Mac app with no server of its own cannot use it without shipping a secret inside
the app bundle — where it is not a secret, because anyone with the bundle has it.

The device flow (RFC 8628) exchanges a device code for a token using only the public client ID. That
is exactly the shape this app needs, and it is why signing in shows a code to type on github.com
rather than opening a redirect URL. If you are wondering where to add the client secret: nowhere.
There is no code path that would use one.

### The exchange

Both requests are form-encoded `POST`s to the **web** host, not the API host — `https://github.com`
for GitHub.com, `https://your-appliance` for Enterprise Server.

1. `POST /login/device/code` with `client_id` and `scope`. GitHub returns a device code, the
   `user_code` the reviewer types, a verification URI, a lifetime, and a minimum poll interval.
   Reviewrr floors that interval at 5 seconds.
2. `POST /login/oauth/access_token` with `client_id`, `device_code`, and
   `grant_type=urn:ietf:params:oauth:grant-type:device_code`, repeatedly, until it answers.

The screen shows the code immediately and polls in the background, so the reviewer is never waiting
on a spinner before they have something to do. Polling stops on success, on any terminal error, when
the code expires, or when the reviewer cancels — and sign-out cancels an in-flight flow.

The requested scope is `repo read:org`: precisely what Reviewrr's own scope evaluator calls
sufficient, so a token obtained by signing in passes the Account pane's check rather than arriving
with a warning badge.

### What each device-flow answer means

| GitHub says | Reviewrr does |
| --- | --- |
| `authorization_pending` | Keeps polling. This is the normal answer while the reviewer is still on github.com |
| `slow_down` | Keeps polling, 5 seconds slower each time it is told to |
| `expired_token` | Stops: "The device code expired before it was approved. Start over." |
| `access_denied` | Stops: authorization was denied on GitHub |
| `incorrect_client_credentials` | Stops: the configured client ID is invalid |
| `incorrect_device_code` | Stops: the device code is invalid or was already used |
| `unsupported_grant_type` | Stops: GitHub rejected this grant type |
| `device_flow_disabled` | Stops: **Enable Device Flow is off on the OAuth app.** Turn it on |
| Anything unrecognized | Stops and shows GitHub's own `error_description` |

Every terminal state reaches the reviewer as text with a remedy. None of them is a spinner that
quietly stops.

### Where the credential lives

| Where | What |
| --- | --- |
| Keychain, service `com.sabeur.reviewrr`, account `github-token` | The token. Never logged, printed, or written anywhere else |
| `$REVIEWRR_GITHUB_TOKEN` | Checked **before** the Keychain, which is then not touched at all |
| Memory only | A token used "for this session" after the Keychain refused this build |
| `UserDefaults` `reviewrr.auth` | The reviewer-supplied OAuth client ID. Not a secret |

The Keychain is read on first use, not at launch: on a build whose signature macOS does not
recognize, reading it puts a modal approval panel in front of the reviewer before the window has
drawn. It is resolved once the window is up instead, so the panel is a response to opening the app.

Until that read returns, Reviewrr assumes there **is** a credential. The sign-in screen therefore
never flashes past someone who is already signed in.

## When something goes wrong

### "This build ships without a GitHub OAuth client ID"

Expected on a build from a clone. Either paste a personal access token, or paste a client ID into
the field below the message. See [For whoever packages a build](#for-whoever-packages-a-build).

### Sign-in works, but Reviewrr is signed out again next launch

macOS ties a Keychain item to the exact build that saved it. This project's development builds are
signed ad hoc, so **every rebuild looks like a different application** asking for another
application's secret. Approving does not help the next build, and Reviewrr deliberately stops asking
rather than looping.

Three ways out, best first:

1. Sign the app with a stable development certificate. The item's ACL then matches across rebuilds
   and macOS stops asking. This is the durable fix.
2. Run it with `REVIEWRR_GITHUB_TOKEN` set in the environment. The Keychain is never touched, and
   nothing is stored.
3. Paste a token and use it for this session. It lives in memory and is written nowhere.

Reviewrr tells these apart on purpose: "nothing is stored" and "this build was refused" used to be
the same empty result, so the app looked signed out and asked again on the next launch.

Reviewrr tries the data-protection keychain first, which scopes items to the application's identity
and never shows an approval panel — it needs a real signing identity, so an ad-hoc build falls back
to the legacy keychain, detected once and remembered for the process.

### "Verification failed" on a token that works on the web

In order of likelihood:

- The token is for a **different host**. A credential is host-specific; check Settings ▸ Account ▸
  GitHub host.
- A **fine-grained** token without the repository selected, or without "Pull requests: read and
  write". Use the repository access check to confirm what it can actually see.
- **`read:org` missing** on a classic token, with an organization-owned repository.
- The token was **revoked or expired**. GitHub returns 401 for both.

### A repository 404s

GitHub returns 404 for "does not exist" and for "exists, and you cannot see it" — they are
indistinguishable by design, so nothing can tell you which one it is. Check the repository access
probe in Settings ▸ Account, then the token's repository permissions.

### Sign-in succeeded but the dashboard is empty

The dashboard shows *watched projects*, which is a separate list you add to (Settings ▸ Watchlist, or
the dashboard's add-project sheet). A working credential does not populate it.

## Code map

| File | Holds |
| --- | --- |
| `Sources/Reviewrr/Services/GitHubOAuthApp.swift` | Client-ID resolution and precedence, and why the device flow |
| `Sources/Reviewrr/Services/GitHubAuth.swift` | Device-flow requests and parsing, `/user` and `/rate_limit`, the repository probe, token-kind detection, masking, scope evaluation |
| `Sources/Reviewrr/ViewModels/AuthModel.swift` | The state machine: verification, polling, host switching, sign-out |
| `Sources/Reviewrr/Views/SignInView.swift` | The sign-in surface |
| `Sources/Reviewrr/Views/DeviceCodeView.swift` | The code, countdown, and copy/open/cancel controls, shared by that surface and Settings |
| `Sources/Reviewrr/Views/Settings/AccountSettingsView.swift` | Settings ▸ Account |
| `Sources/Reviewrr/Services/KeychainStore.swift` | Keychain access, and the difference between "nothing stored" and "refused" |
| `Sources/Reviewrr/ViewModels/AppModel.swift` | Token source of record, the sign-in gate rule |
| `Tests/ReviewrrTests/AuthTests.swift` | Token kinds, masking, scope verdicts, host parsing, device-flow fixtures, client-ID precedence, the gate truth table |

`AppContext.saveToken` both stores and publishes, deliberately as one closure. When they were
separate, the device flow wrote the Keychain itself and forgot to publish — a successful sign-in
reached Settings ▸ Account and nothing else until the app was relaunched.

## See also

- [Architecture](architecture.md) — surfaces, transport, wiring, storage
- [`AGENTS.md`](../AGENTS.md) — stack and non-negotiable product rules
