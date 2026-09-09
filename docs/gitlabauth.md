# Reviewrr GitLab sign-in

How to point Reviewrr at a GitLab instance — gitlab.com or self-managed — and authenticate it with
an access token. The GitHub equivalent is [GitHub sign-in](githubauth.md); the shared parts
(Keychain storage, what a credential is scoped to) work the same way.

## Create the token

On your GitLab instance: **avatar ▸ Edit profile ▸ Access tokens** (older versions:
**User Settings ▸ Access Tokens**), or go straight to `https://your-instance/-/user_settings/personal_access_tokens`.

- **Name** — anything; "Reviewrr on <your Mac>" makes it obvious what to revoke later.
- **Expiry** — GitLab requires one and defaults to a year out on recent versions. Reviewrr reports
  an expired token as "GitLab rejected the access token as invalid or expired", so a short expiry is
  safe, just noisy.
- **Scopes** — this is the part that matters:

| Scope | Gives you | Enough for |
| --- | --- | --- |
| `api` | Full read **and write** API access | Everything: reading merge requests and diffs, posting draft notes, publishing a review, approving |
| `read_api` | Read-only API access | Reading merge requests, diffs, discussions, approvals, pipelines. **Cannot** post a comment, publish a review, or approve |

Pick `api` unless you want a deliberately read-only setup. Reviewrr's 403 message names this
directly, because it is the single most common misconfiguration: `read_api` looks like it works
right up to the moment you submit a review.

`read_user` and `read_repository` are **not** needed. Reviewrr reads file contents for
context expansion through the API, not over Git.

### Project and group access tokens

A **project access token** (Settings ▸ Access tokens on the project) works too, with the `api`
scope and at least the **Reporter** role — **Developer** if you want to approve merge requests.
It is scoped to that one project, so watching several projects means several tokens, and Reviewrr
holds one credential per *host*. Use a personal access token unless you specifically need the
narrower blast radius.

## Point Reviewrr at the instance

**Settings ▸ Account ▸ Host**, choose **GitLab**, and enter the instance:

| You have | Type this | Reviewrr derives |
| --- | --- | --- |
| gitlab.com | `gitlab.com` | `https://gitlab.com/api/v4` |
| A self-managed instance | `git.internal.example` | `https://git.internal.example/api/v4` |
| GitLab under a subdirectory | `https://internal.example/gitlab` | `https://internal.example/gitlab/api/v4` |
| A non-standard port | `git.internal.example:8443` | `https://git.internal.example:8443/api/v4` |

A bare hostname is assumed to be **HTTPS**. To reach an instance over plain HTTP you must type
`http://` explicitly — a credential sent in clear text should be a decision, not a default.

The subdirectory case is why a GitLab host keeps the path you type, unlike a GitHub Enterprise host,
which rebuilds its API root from the bare hostname: GitLab is commonly installed under a path on an
existing domain, and discarding it would send every request somewhere with no GitLab on it.

Paste the token and save; Reviewrr stores it for that host and immediately verifies it against
`/api/v4/user`, reporting the result in the pane.

Switching hosts behaves differently depending on what is already saved. If a credential for the new
host is already in the Keychain, Reviewrr verifies it *before* adopting the host, so a typo or an
unreachable instance leaves you where you were. If nothing is saved for it yet, the host is adopted
anyway — there is nothing to verify, and refusing to switch would leave you with nowhere to paste
the token. The pane says which happened.

Tokens live in the **macOS Keychain**, one item per host, so a GitHub.com token, a GitHub Enterprise
token and a GitLab token coexist. Nothing is written to a file or a log. See
[the Keychain notes](githubauth.md#sign-in-works-but-reviewrr-is-signed-out-again-next-launch) if
this Mac's Keychain refuses a development build.

## HTTP Basic auth in front of the instance

Reviewrr can send an HTTP Basic username and password alongside the token
(**Settings ▸ Account ▸ HTTP Basic**). Be clear on what that is for:

- **It gets you through a Basic-protected front door** — nginx, Apache, or a corporate proxy in
  front of GitLab. Basic travels in `Authorization`, the token in `PRIVATE-TOKEN`, so both are on
  every request and neither displaces the other.
- **It does not authenticate you to GitLab.** GitLab's `/api/v4` does not accept
  `Authorization: Basic`. Basic works for Git-over-HTTP (`git clone` with a token as the password)
  and for the container registry — not the REST API. A Basic-only setup gets a 401 from GitLab
  itself, and Reviewrr's 401 message says exactly that when it sees Basic sent without a token.

So: Basic **and** a token for a proxied instance; token alone otherwise.

On a GitHub host the two cannot coexist — GitHub has no separate token header, so both would need
`Authorization`, and HTTP has no second one. There, a token wins and the Account pane says the Basic
credential is not being sent. GitLab has no such conflict.

## Private certificate authorities

Reviewrr uses the Mac's system trust store and **does not** skip certificate validation — there is
no toggle, and no code that could weaken it. If your instance uses a private CA, install that root
certificate in Keychain Access (or have it deployed by MDM) and mark it trusted for SSL.

Until then, requests fail with a message naming the host and that remedy, rather than a generic
network error — a private CA nobody installed is the distinctive self-hosted failure and deserves
its own sentence.

## Project paths, not owner/repo

GitHub has exactly two levels, `owner/repo`. GitLab has arbitrarily nested groups, so a project is
addressed by its full path: `platform/backend/api-gateway`. Reviewrr carries the whole group path in
the owner position and URL-encodes it into one segment (`platform%2Fbackend%2Fapi-gateway`) the way
the API requires. Anywhere you would type `owner/repo` for GitHub — the watchlist, a merge request
reference — type the full project path for GitLab.

## What each failure means

| Reviewrr says | Cause | Fix |
| --- | --- | --- |
| No GitLab credential configured | Nothing saved for this host | Add a token in Settings ▸ Account |
| GitLab rejected the access token as invalid or expired (401) | Revoked, expired, or mistyped token | Issue a new token |
| 401 mentioning Basic auth | Basic sent with no token — GitLab's API does not accept Basic | Add an access token as well |
| GitLab denied access (403) | Token scope too narrow, or role too low | Use `api` scope; Developer role to approve |
| Not found (404) | Wrong project path or MR number, or the token cannot see the project | Check the full group path; GitLab returns 404 rather than 403 for projects you cannot see |
| The certificate for … is not trusted | Private CA not installed on this Mac | Install the root CA in Keychain Access |
| This GitLab does not allow approving through the API | Approvals are a paid feature, or your role is below Developer | Nothing to fix on a Free tier — reading a merge request still works, and comments and the summary are published even when the approval cannot be |

GitLab, like GitHub, returns **404 rather than 403** for a project you are not allowed to see, so
"not found" and "not permitted" are indistinguishable from outside. Check the path first, then the
token's scope.

## Revoking

Signing out in Reviewrr removes the token from this Mac's Keychain only — it does **not** revoke it
on GitLab. Revoke it where you made it: **Edit profile ▸ Access tokens ▸ Revoke**.

## What works, and what GitLab has no equivalent for

Reading and reviewing a merge request works end to end: the diff, discussions, approvals, pipeline
jobs, inline comments, and publishing a review. Inline comments are staged as GitLab **draft notes**
and published together in one `bulk_publish`, which is what makes a review arrive at once rather
than as a trickle of notifications — the same promise the GitHub path makes.

Three things do not map, and Reviewrr does not pretend otherwise:

- **"Request changes" has no GitLab object.** GitLab has approval and the absence of it. That event
  publishes your comments and summary and withdraws your approval if you had given one; it never
  invents a rejection.
- **"Participated" is missing from the inbox.** GitLab has no "merge requests I commented on"
  filter, so that bucket is empty rather than approximated with something that means something else.
- **Sign in with a device code is GitHub-only.** GitLab's OAuth needs a registered application with
  a redirect URI, which this app has none of, so the section is absent on a GitLab host rather than
  present and permanently broken. Use an access token.

A GitLab **multi-line** comment is anchored with a `line_range`, and for a range placed on context
lines GitLab may reject the anchor. When it does, its own validation message is surfaced rather than
the comment being silently re-anchored to a line you did not choose.

## See also

- [GitHub sign-in](githubauth.md) — the GitHub side, and the Keychain notes both share
- [Architecture](architecture.md) — the forge abstraction, transport, and storage
