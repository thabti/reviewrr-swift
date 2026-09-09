# Tasks

The working board for Reviewrr's UI, UX and correctness defects.

Product owns this file. Developers own the code and the **Status** and **Dev notes** of the
task they picked up. One task, one owner, one commit.

## How this works

1. A task lands here with a **symptom** — what a person using the app actually experiences —
   not a description of the code. If it cannot be written as a symptom, it is not a task yet.
2. A developer takes a task, sets `Status: in progress`, and puts their name/agent id in **Owner**.
3. When done they set `Status: needs review`, fill in **Dev notes** with what changed and how
   they proved it, and stop. Product verifies and moves it to `done`.
4. A task that turns out not to be real gets `Status: rejected` and a one-line reason. Rejecting
   a task is a good outcome — it means we did not spend a day on a guess.

**Status values:** `open` · `in progress` · `needs review` · `done` · `rejected` · `blocked`

**Severity:** `S1` loses work or produces a wrong review decision · `S2` blocks a core task ·
`S3` confusing or degraded · `S4` polish

## Rules for whoever picks these up

- Read `AGENTS.md` first. No third-party dependencies. `Views/` is not compiled into the test
  bundle, so anything you want to test belongs in `Models/`, `Services/`, `ViewModels/` or
  `Design/`.
- `make test` must pass before you hand a task back. Say the number of tests in your notes.
- A fix for a defect class gets a regression test that pins the *rule*, not the numbers.
- Do not fix things not on your task. Found something new? Add a task, keep going on yours.
- Comments explain *why*, in the house style: what broke, what it cost, why this shape.

### File ownership — read this before starting

`ViewModels/AppModel.swift`, `DashboardModel.swift` and `Views/DiffView.swift` are each touched
by several tasks. **One agent owns a file at a time.** The waves below are grouped so no two
concurrent owners share a file. If your task needs a file another wave owns, say so and stop
rather than editing it.

---

## S1 — loses work, or causes a wrong review decision

### T-010 · An unreadable draft file is silently replaced with an empty one
- **Severity:** S1 · **Area:** Services/DraftStore, AppModel · **Status:** needs review · **Owner:** dev-A (recovered)
- **Symptom:** A reviewer has 8 inline comments and a summary staged on a pull request. The draft
  file stops decoding for any reason. They open that pull request: the shelf is empty, the diff
  shows no drafts, and there is no error. About a second later the file on disk has been
  **overwritten** with an empty draft. Work that was merely unreadable is now erased.
- **Repro:** Truncate or hand-edit any file under `Application Support/Reviewrr/drafts/…`, then
  open that pull request.
- **Cause (verified):** `DraftStore.load:23-32` swallows every decode error with `try?` and
  returns `ReviewDraft()`. `AppModel.performLoad:961` assigns it and `:977` calls `persistDraft()`
  unconditionally, writing the empty draft over the same path.
- **Fix:** Make `DraftStore.load` distinguish absent from unreadable — return an enum
  (`.absent` / `.decoded` / `.unreadable`). On `.unreadable`: rename the file to
  `…json.corrupt-<timestamp>` rather than letting it be overwritten, set `draftSaveError` so the
  existing banner and Retry in `RootView.swift:163` surface it, and skip the `persistDraft()` at
  `performLoad:977`. Never overwrite a draft the app could not read.
- **Test:** a store-level test that an undecodable file survives a load and is renamed, not lost.

### T-011 · A future release will eat every staged review, because drafts alone lack tolerant decoding
- **Severity:** S1 · **Area:** Models/Draft, LocalPRStatus · **Status:** needs review · **Owner:** dev-A (recovered)
- **Symptom:** Ships as "the update ate my reviews." Add one non-optional field to `ReviewDraft`
  in any future version and every reviewer's staged review, on every pull request, fails to
  decode on first launch — then T-010 overwrites each one as they open it.
- **Cause (verified):** `Forge.swift:78-85` documents this exact trap and eight types have a
  hand-written `init(from:)` because of it — `ForgeHost`, `WatchedProject`, `AISession`,
  `AnalysisCacheEntry`, `ChatMessage`, `AppSettings`, `NotificationPreferences`, `IssueTracker`.
  `ReviewDraft` (`Models/Draft.swift:52-65`), `DraftComment` (`:3-34`) and `LocalPRStatus`
  (`Models/LocalPRStatus.swift:26-34`) use synthesized `Codable`. A Swift synthesized decoder
  throws `keyNotFound` for a missing key **even when the property has a default**.
  `LocalPRStatus` is decoded as a whole dictionary, so one bad entry loses the entire
  read/reviewed/ignored map.
- **Fix:** Add `CodingKeys` + `init(from:)` + `encode(to:)` to those three types in the exact
  style of `WatchedProject.swift:84-108`. Add a `schemaVersion` to `ReviewDraft` so a future
  breaking change can be migrated rather than guessed at.
- **Test:** decode a payload missing each newly-added key and assert the defaults survive. Note
  `DraftStoreTests.swift:20` currently bakes in the opposite assumption — update it.

### T-012 · On a nested GitLab group, drafts can never save and the reviewer is trapped in the workspace
- **Severity:** S1 · **Area:** Services/DraftStore, AnalysisCache, AISessionStore · **Status:** needs review · **Owner:** dev-A (recovered)
- **Symptom:** A reviewer at a GitLab shop opens `platform/payments/api!318`, types 8 comments,
  and gets a red banner saying *"Your review could not be saved locally. Check available disk
  space and folder permissions"* — a wrong diagnosis that Retry can never clear. They click back
  to the dashboard: nothing happens. They force-quit. All 8 comments are gone.
- **Repro:** Any GitLab project one or more subgroups deep. Top-level `group/project` works,
  which is why this passes a smoke test.
- **Cause (verified):** For GitLab, `PRReference.owner` is the full group path
  (`GitLabAPI.swift:165-167`, `GitLabInboxService.swift:167-173`). `DraftStore.fileURL:20` builds
  `"\(owner)_\(repo)_\(number).json"`, so the name contains a `/`,
  `appendingPathComponent` keeps it, and the write lands in a directory that is never created —
  `NSCocoaErrorDomain 4 / ENOENT`. Then `closePR:798`, `loadDemo:822` and `performLoad:919` all
  begin `guard persistDraft() else { return }`, so **every navigation out silently no-ops**.
  `AnalysisCache.swift:107` and `AISessionStore.swift:80` have the same path bug under `try?`, so
  AI analysis and Ask transcripts silently never persist for these projects either.
- **Fix:** One shared `fileName(for:)` helper that cannot produce a path separator — prefer a
  SHA-256 of `host.identityKey + reference.key`, matching `ForgeHost.identityKey`
  (`Forge.swift:190-194`) — used by all three stores. Include a one-shot migration that renames
  existing files, or every current GitHub draft orphans (see T-050). **Separately**, make
  navigation not depend on a successful save: a failed save must not be able to trap someone in
  the workspace. That is the part that turns a bug into lost work.
- **Test:** `fileName(for:)` never contains `/`, and two references differing only by group depth
  do not collide.
- **Related:** T-034 (the same slash assumption rejects pasted GitLab URLs), T-050, T-051.
- **Recovery note:** dev-A was killed by the stall watchdog *while running the test suite*, after a
  wait-loop it had spawned deadlocked (a `pgrep -f` pattern that matched the waiter's own command
  line, so it could never exit). It filed no report. I killed the loop, ran the suite myself — 736
  passing — and reviewed the diff against all three S1s rather than trusting the green. The work
  is complete. This is recorded because an un-reported agent's work needs *more* scrutiny before
  it ships, not less.
- **Product review of dev-A's work (T-010 / T-011 / T-012 / T-050 / T-051):** all present and
  better than briefed. Filenames are now `SHA256(host.identityKey|reference.key)`, so a path
  separator is structurally impossible and the underscore collision is gone. The host directory
  moved to `identityKey` with a real migration that **only stamps the directory when every file
  moved**, so a half-migration retries instead of orphaning. `DraftLoad` distinguishes
  `.absent` / `.decoded` / `.unreadable`, quarantining a bad file as `…json.corrupt-<timestamp>`,
  and `performLoad` now writes only `if stored.isWritable`. Tolerant decoders on all three types,
  with a `schemaVersion` so the *next* scheme change is migratable rather than guessed at.
  **Beyond the brief:** an `unsavedDrafts` in-memory holding area, so a draft whose file cannot be
  written is neither lost nor able to trap the reviewer — `closePR` now says in a comment exactly
  what the old `guard` cost. 30 tests in `DraftStoreTests`.

### T-013 · A failed discussion fetch renders as "No discussion yet", so reviewers approve blocked pull requests
- **Severity:** S1 · **Area:** AppModel, ConversationModel · **Status:** open · **Owner:** —
- **Symptom:** A token loses `repo` scope, or one call is rate-limited. A reviewer opens a pull
  request that has 14 threads and a "changes requested" review. The diff loads fine. The
  conversation panel says *"From GitHub · 0 threads"* and *"No discussion yet."* The Reviewers row
  vanishes. The file tree shows no comment badges. **They approve a pull request someone else has
  already blocked**, or rewrite comments that already exist.
- **Repro:** Downgrade the token after sign-in, or block `/issues/{n}/comments` at a proxy, then
  open any pull request.
- **Cause (verified):** `AppModel.swift:880/885/890` — `(try? await …) ?? []` on all three
  discussion fetches, each followed by `completedLoadStages.insert(…)`, so the load screen ticks
  the stage green anyway. `ConversationModel.load:92` then sets `loadPhase = .loaded`
  unconditionally. `LoadPhase.failed` exists and `ConversationTimelineView.swift:42-44` renders
  it — and **nothing in the entire codebase ever assigns it** (`grep "loadPhase = "` returns only
  `.loading` and `.loaded`). The dead branch is proof this was intended and never wired.
- **Fix:** Carry a `Result` per call into `ConversationModel.load`; assign `.failed` when all
  three fail and show a per-source warning when only some do; do not insert a `PRLoadStage` for a
  call that threw. Wording: *"Couldn't load this pull request's discussion — comments, reviews and
  threads are missing, not absent."* with a Retry that re-runs `loadDiscussion`.
- **Note:** "absent" and "we did not ask" being different claims is already written down as a
  principle at `ConversationPanelView.swift:104-110`. This task and T-027 are where the code
  contradicts it.

---

## S2 — blocks a core task

### T-020 · Two overlapping loads can land you on the wrong pull request, and Cancel stops working
- **Severity:** S2 · **Area:** AppModel · **Status:** open · **Owner:** —
- **Symptom:** Press ⌘R twice on an open pull request and the refresh indicator disappears while
  the refresh is still running. Open a pull request from the dashboard, then click a notification
  or a `reviewrr://` link while it loads: the opening screen and its Cancel button vanish, you
  stare at the dashboard with no spinner for the whole second load, and the workspace pops in
  abruptly. Open A, then B, then C quickly and **you can end up looking at B's diff having asked
  for C**.
- **Repro:** ⌘R twice in a row on an open pull request. Reliable because the menu-bar Refresh
  (`ReviewrrApp.swift:128-135`) has no `.disabled`, unlike the toolbar button
  (`RootView.swift:273`), and macOS routes ⌘R to the menu item.
- **Cause (verified):** `AppModel.load:908-916` does `loadTask = nil` unconditionally after
  `await task.value`, destroying the handle to whichever task replaced it — so `cancelLoad()`
  becomes a permanent no-op and a third load cancels nothing. `performLoad` has **no** generation
  or reference check before it commits, so the last finisher wins. The superseded task's
  `defer` (`:930-934`) then clears `isLoading`/`loadingReference` that the successor's prologue
  just set, and the successor never sets them again.
- **Fix:** `if loadTask === task { loadTask = nil }`. Add a `loadGeneration` counter: capture it
  before the fetches and `guard generation == loadGeneration` before both the commit block
  (`:958`) and the `defer` body. Add `try Task.checkCancellation()` after the files land (`:948`)
  so a Cancel that arrives with the responses does not commit anyway.
- **Also:** remove the ⌘R shortcut from the menu item or disable it while loading — see T-072.

### T-021 · Unwatching a project during a sync brings its pull requests back for the session
- **Severity:** S2 · **Area:** DashboardModel · **Status:** needs review · **Owner:** dev-D
- **Symptom:** Refresh the dashboard, then immediately remove a project. Its pull requests come
  back into the inbox's count but not its groups, so the header permanently reads "47 pull
  requests" over 31 visible rows, keyboard selection can land on an invisible row, and the ghosts
  are written to the cache so they return at next launch. Nothing can clear them — the project is
  gone from the sidebar, so no refresh will ever overwrite that cache key.
- **Cause (verified):** `refreshProjectCoalesced:555-562` wraps each refresh in `Task {}`, which
  is not a child of the poll loop, so `stop()`/`restartPolling()` never cancels an in-flight
  network refresh. `removeProject:309-318` clears the cache and restarts polling but does not
  cancel `inFlightProjectRefresh[project.key]`, and `performProjectRefresh:586` writes
  `projectRowsCache[project.key]` without re-checking the project is still watched. The comment at
  `:314-317` says this was fixed — only the scheduling half was.
- **Fix:** In `performProjectRefresh`, after the `await` and before the write:
  `guard projects.contains(where: { $0.key == project.key }) else { return false }`. Cancel the
  in-flight task from `removeProject`, `toggleMute` and `stop`.
- **Same mechanism:** signing out does not stop an in-flight sync, so it can still write rows and
  fire a notification *after* sign-out. Cover that in the same task.
- **Correction from dev-D (accepted):** the `projects.contains` guard alone does **not** cover
  sign-out, because the project stays watched — the cancellation check is what covers it, so
  `stop()` cancelling *and* a post-`await` cancellation guard are both load-bearing. Cancelling
  from `toggleMute` must be conditional on the project ending up *muted*; cancelling on unmute
  would kill a legitimate manual refresh.
- **Dev notes (dev-D):** Split the commit half into `commitProjectRows(_:for:)`, guarded on
  `!Task.isCancelled && projects.contains(key)`; it returns the previous rows or `nil` when
  refused, so a refused commit also suppresses the activity notification.
  `cancelInFlightRefresh(for:)` from `removeProject` and from `toggleMute` when muting;
  `cancelInFlightRefreshes()` from `stop()` (the sign-out path). Corrected the misleading comment
  that claimed this was already fixed. Two adjacent bugs the cancel made reachable, fixed too:
  the coalescing dictionaries cleared their entry unconditionally on resume and could
  un-register a successor task (now identity-checked), and `performBucketsRefresh` treated "every
  host cancelled" as "every host has nothing" and wrote an empty queue to the cache after
  sign-out. Ghost rows from earlier builds self-heal on the first completed sync. Tests:
  `testRefreshLandingAfterRemovalWritesNoRows`, `testCancelledRefreshWritesNoRows`.

### T-022 · Refreshing while checks load leaves the Checks panel spinning forever
- **Severity:** S2 · **Area:** ConversationModel · **Status:** open · **Owner:** —
- **Symptom:** Open a pull request and press ⌘R while the conversation is still loading. The
  Conversation rail shows a pulsing "Loading checks…" chip and the Checks tab shows "Loading
  checks…" **forever**, with "Refresh checks" greyed out. Only a full refresh that completes, or
  a relaunch, recovers it.
- **Cause (verified):** `ConversationModel.refreshChecks:136-154` sets `checksLoadPhase = .loading`,
  and its `catch is CancellationError` branch comments "leave the phase as-is" — which is
  `.loading`. Cancellation genuinely reaches it: both API layers normalise `URLError(.cancelled)`
  into `CancellationError` (`GitHubAPI.swift:200`, `GitLabAPI.swift:245`). Then
  `ConversationPanelView.swift:97` disables the only retry affordance on exactly that value.
- **Fix:** Set `checksLoadPhase = .idle` in the cancellation branch (`.idle` renders "Checks not
  loaded" and re-enables Refresh), or restore the pre-call phase. Gate the Refresh button on
  something that cannot get stuck.

### T-023 · Clicking an AI citation does nothing, and `n` silently skips a whole file
- **Severity:** S2 · **Area:** AppModel · **Status:** open · **Owner:** —
- **Symptom:** Two symptoms, one cause. (a) Click a citation or a finding in the AI panel — no
  scroll, no error, nothing. (b) Press `n` at the last change of a file right after opening it and
  it jumps *past* the next file's changes entirely, landing two files ahead.
- **Repro:** Intermittent by nature — the race window is one patch parse, so it is most hittable
  on large files, which are the ones that matter.
- **Cause (verified):** `AppModel.ensureParsed:590` does `guard !parsingPaths.contains(path) else
  { return }` — it returns **without the file parsed** when a parse is already in flight. Every
  caller then reads `parsedFiles[path]` and treats `nil` as "no changes": `DiffView.jump:287-294`
  bails before scrolling, and `stepChange:700-730` calls `enterFile(candidate, hunks: [])` which
  returns nil and `continue`s past the file. The competing parse is the app's own — the pane's
  `.task(id:)` at `DiffView.swift:609` for (a), `prefetchNeighbours:605` for (b).
- **Fix:** Make `ensureParsed` **await** the in-flight parse instead of bailing: replace
  `parsingPaths: Set<String>` with `parsingTasks: [String: Task<…, Never>]` and return
  `await existing.value` when one is present.
- **Note:** T-060 wants `parsingPaths` deleted for a different reason. Same property — **do both
  in this task**, and derive any UI need from the task dictionary's keys.

### T-024 · Quitting leaves the AI CLI agent running and billing
- **Severity:** S2 · **Area:** Services/AI/AgentProcess · **Status:** open · **Owner:** —
- **Symptom:** Start an analysis or an Ask with a CLI provider, then ⌘Q. `ps -o pid,ppid,command`
  shows the `claude`/`codex`/`kiro` process still running with `ppid 1`, still working its API
  call and still costing money. It dies only when it next writes to the closed pipe, which for an
  agent that is thinking rather than streaming can be minutes.
- **Cause (verified):** No quit hook terminates live sessions — the only
  `willTerminateNotification` observer (`AppModel.swift:301-307`) just flushes the draft. Children
  are spawned with `POSIX_SPAWN_SETPGROUP` into their own process group
  (`AgentProcess.swift:151-156`), deliberately outside the app's group, so they receive nothing
  when the app dies and are reparented to `launchd`.
- **Fix:** A process-wide registry on `AgentProcessSession` (a locked static dictionary, inserted
  in `launch`, removed in the reaper) plus `AgentProcess.terminateAll()`, called from the existing
  `willTerminateNotification` observer alongside `flushPendingDraftSave()`.

### T-025 · On GitLab, "Request changes" says it blocks the merge. It does not.
- **Severity:** S2 · **Area:** Views/SubmitReviewForm, GitLabClient · **Status:** needs review · **Owner:** dev-B
- **Symptom:** A reviewer on GitLab picks "Request changes", reads the red copy *"Blocks merging
  until changes are made"*, submits, and sees success. The merge request is **not blocked** and
  merges an hour later.
- **Cause (verified):** `SubmitReviewForm.swift:149` is `ForEach(ReviewEvent.allCases)` with no
  forge awareness — the string `gitlab` does not appear in the file. `GitLabClient:319-325`
  publishes the comments and then `try? await unapprove(...)`, discarding even that failure.
- **Fix:** Make the picker host-aware. On GitLab either drop `.requestChanges` or relabel it and
  tell the truth: *"Publishes your comments and withdraws your approval. GitLab has no way to
  block a merge from a review."* The forge-vocabulary machinery (`Forge.changeNoun*`) already
  exists — use it.
- **Product note:** this is the one finding that makes the app *lie* about an outcome. It matters
  more than its severity number suggests.
- **Dev notes (dev-B):** The picker now draws `ForgeReviewAction.all(on:)` off the same host
  `AppModel.forgeClient` submits through, so picker and submit path cannot disagree; label,
  caption, icon, colour, button title, tooltip and accessibility label all derive from that one
  value, so the three copies of the sentence cannot drift. GitHub's wording is byte-for-byte
  unchanged. On GitLab the third segment is **"Revoke approval"** in amber.
- **Three product rulings on dev-B's wording questions:**
  1. *"…takes back your approval **if you gave one**"* — **keep.** `unapprove` is still swallowed
     (`try?`), so the copy must not promise what the code may not do. Revisit when T-026 lands.
  2. *"**Reviewrr cannot** block a merge on GitLab"* rather than my *"GitLab has no way to"* —
     **keep dev-B's.** My wording was factually wrong: GitLab 17.x has a reviewer
     `requested_changes` state and Premium can be configured to hold a merge on it. Reviewrr
     implements none of that, so the narrow claim is true on every instance and the absolute one
     would be a new lie on some. Good catch.
  3. **Three segments kept on GitLab** instead of dropping `.requestChanges` — **accepted.**
     Dropping the tag leaves a `Picker` whose selection matches nothing (SwiftUI renders nothing
     selected) while submit still sends `REQUEST_CHANGES`, because a draft persisted on a GitHub
     host can already hold that event. The alternative is silently rewriting a reviewer's saved
     intent on open. Relabelling also keeps a real capability — withdrawing an approval has no
     other control in the app.

### T-026 · A partly-failed GitLab submit invites you to double-post every comment
- **Severity:** S2 · **Area:** GitLabClient, AppModel · **Status:** open · **Owner:** — ·
  **Priority: take this first in wave 2**
- **Symptom:** A reviewer submits 9 inline comments, a summary and Approve to a Community-edition
  GitLab. The comments and summary land; `/approve` 404s because approvals are paid. The popover
  says "The comments and summary were published" — and still shows "9 inline comments" with a live
  Approve button. They press it again and the merge request gets **9 duplicate comments**.
- **Cause (verified):** GitLab submission is four sequential writes
  (`GitLabClient:283-330`). Anything after `bulk_publish` throws as a whole-review failure, and
  `AppModel.submitReview:1161-1186` leaves `draft.comments` untouched. The client's own error text
  (`:434`) is honest; the app's state contradicts it.
- **Fix:** Throw a typed partial-success error naming the stages that completed. In
  `submitReview`, clear the draft for the completed stages before setting `submitError`, and word
  it: *"Your comments and summary were published. The approval did not go through — approve on
  GitLab, or try again (your comments will not be re-sent)."*
- **Now load-bearing for T-025 (dev-B):** the GitLab segment is labelled "Revoke approval", so a
  silently swallowed `unapprove` failure is a *fresh* lie on a control that now names that exact
  outcome. Making it honest is one line, but every throw out of `submitReview` lands in the
  double-post path above — so T-026 must land before that line, not after. **When it does,
  `unapprove`'s 404 must stay swallowed:** "there was no approval to withdraw" is genuinely not a
  failure of the review.

### T-027 · A denied GitLab pipeline query renders as "no CI on this project"
- **Severity:** S2 · **Area:** GitLabClient · **Status:** needs review · **Owner:** dev-B
- **Symptom:** A `read_api`-scoped GitLab token cannot read pipelines. The pipeline is red. The
  reviewer reads *"No checks reported — this commit has no CI checks or commit statuses"*, and
  approves.
- **Cause (verified):** `GitLabClient.fetchChecks:217-221` catches `serverError, forbidden,
  notFound` and returns `[]`; `refreshChecks` then sets `.loaded`. The plumbing to say "we did not
  ask" exists and is correct one layer up — this lower layer erases the distinction.
  `fetchReviews:193-199` does the same to approvals.
- **Fix:** Do not flatten to `[]`. Throw so `refreshChecks` can set
  `.failed("GitLab would not report pipelines for this merge request (HTTP 403). Reading CI needs
  a token with the \"api\" scope.")`. Same for approvals.
- **Related:** T-013 — same defect class, different surface.
- **Correction from dev-B (accepted):** I briefed this as needing follow-up wiring in
  `ConversationModel`. **It does not** — `refreshChecks:132-134` already ends in
  `catch { checksLoadPhase = .failed(...) }` with the cancellation branch correctly ahead of it,
  and both the chip and the Checks tab switch on the phase before believing the rollup. The checks
  half is therefore complete end to end. The **approvals** half is still erased one layer up, but
  in `AppModel.loadDiscussion:877/885`, which is T-013's fix — and because that `try?` makes
  today's behaviour byte-identical, dev-B's change carries no regression while T-013 is unwritten.
- **Dev notes (dev-B):** A private `couldNotRead(_:remedy:error:)` re-throws naming the fact that
  went missing, since GitLab names no endpoint on 401/403/404 and five requests are in flight
  while a merge request opens; `.forbidden` stays `.forbidden` so its `"api"`-scope advice still
  lands, 404 maps to `.unsupportedByInstance`, 5xx passes through as it already carries its
  endpoint. Deliberately still returning a true empty: an empty `/pipelines` list, and a readable
  pipeline whose `/jobs` are denied (reported as one run) — throwing there would trade one false
  claim for another. Tests drive the real client through a stubbed `URLSession` rather than
  asserting on message strings.

### T-028 · Sign Out deletes the token with no confirmation, one control away from Verify
- **Severity:** S2 · **Area:** Views/Settings/AccountSettingsView, ProjectSidebarView · **Status:** needs review · **Owner:** dev-D
- **Symptom:** In Settings ▸ Account the reviewer means to press "Verify" and hits "Sign Out" one
  control to the right. The personal access token is deleted from the Keychain immediately, with
  no confirmation and no undo — and GitHub will never show that token again, so they must create a
  new one. "Remove" additionally drops the host. Removing a watched project is the same: one
  click, no prompt, and its mute and notification settings go with it.
- **Cause (verified):** The app has exactly three confirmation dialogs
  (`DataSettingsView.swift:118`, `DashboardDraftsView.swift:104`, `RootView.swift:181`) and none
  of these three actions is among them. `AccountSettingsView.swift:180/186/559`,
  `ProjectSidebarView.swift:508`.
- **Fix:** `.confirmationDialog` on all three. Wording for sign-out: *"Sign out of
  gitlab.internal? The access token is deleted from this Mac's Keychain and cannot be recovered —
  GitHub will not show it again. Nothing is revoked on the server."*
- **Correction from dev-D (accepted):** my cause block said three existing confirmation dialogs;
  there are **two**. `RootView.swift:181` is `.alert("Couldn't load pull request")` with a single
  OK — an error alert, not a confirmation. The voice to match is `DataSettingsView.swift:118` and
  `DashboardDraftsView.swift:104`. My cause block also **missed two more unconfirmed sign-outs** —
  see T-080.
- **Product decision:** dev-D declined to confirm the HTTP Basic "Remove", arguing its secret is a
  proxy password the reviewer holds elsewhere rather than a one-time-shown token, and that it sits
  inside a collapsed disclosure next to Save rather than beside Verify. **Accepted — leave it
  unconfirmed.** Confirming the harmless one is what trains people to dismiss the dangerous one.
- **Dev notes (dev-D):** One `pendingHostAction` state routed through a single
  `.confirmationDialog` on the `Form` (two stacked dialogs do not present reliably in SwiftUI).
  Improved on my suggested wording in three ways worth keeping: the forge name comes from
  `host.forge.displayName` (saying "GitHub" over a GitLab host was simply wrong), the message
  names the *masked token* because the pane can show two hosts' credentials, and it adds a line
  for the HTTP Basic credential that `signOut` also deletes — which my wording missed. The project
  removal dialog counts the watched projects that will be stranded, which "Remove" gave no hint
  of.

### T-029 · Pressing `/` traps the keyboard in the file filter with no way out
- **Severity:** S2 · **Area:** Views/Workspace/FilterBarView, DiffView · **Status:** needs review · **Owner:** dev-C
- **Symptom:** Reviewer presses `/`, types `auth`, then presses `j` to jump to the first match.
  The `j` is appended to the filter text ("authj"), the tree empties, and Escape does nothing.
  Every navigation key — j/k/n/p/v/u/? — is dead until they reach for the mouse and click the diff.
- **Cause (verified):** `/` sets `workspace.searchFieldFocusRequested` (`DiffView.swift:440`),
  `FilterBarView.swift:76-80` moves focus into the `TextField`, and that field has no
  `.onKeyPress(.escape)` and nothing else releases focus. This is a local inconsistency, not a
  missing pattern: both dashboard search fields already do it right
  (`ProjectSidebarView.swift:157-164`, `InboxFilterBar.swift:108-112` — clear on first Escape,
  release focus on second).
- **Fix:** Add the same Escape handler to `FilterBarView.searchRow`. To actually restore diff
  navigation, also add a flag mirroring `searchFieldFocusRequested` that `DiffContainerView`
  observes to re-assert `containerFocused` — today it is set once in `.task`
  (`DiffView.swift:237`) and never re-asserted, which is probably also why keys can feel dead
  after dismissing a sheet.
- **Dev notes (dev-C):** Two-step Escape copied from `ProjectSidebarView`, with the decision itself
  lifted into the testable layer as `WorkspaceModel.escapeInFileFilter(typed:)` — which **cannot
  return "do nothing"**, since that was the bug. Added `diffFocusRequested`, the mirror of
  `searchFieldFocusRequested`, so `DiffContainerView` can re-assert `containerFocused` instead of
  asserting it once in `.task` and never again; it is also raised when the shortcuts sheet or the
  ⌘K palette closes, which closes out the watch-list item about j/k feeling dead afterwards.
  `isTypingInTextControl` untouched and reused as the guard so a focused composer keeps its caret.

### T-030 · ⌘⏎ is bound four times over; the wrong thing happens when you file a comment
- **Severity:** S2 · **Area:** Views/ComposerShell, ReviewrrApp · **Status:** needs review · **Owner:** dev-C
- **Symptom:** A reviewer types an inline comment in the diff — the placeholder itself teaches
  "⌘⏎ to add it as a draft" — presses ⌘⏎, and instead of the draft landing, the Submit Review
  popover opens or their half-written AI question is sent.
- **Cause (verified):** Four unconditional bindings, up to three live at once because the side
  panel and a diff composer are mounted together: `ComposerShell.swift:105` (used by the AI
  composer, the inline comment composer and thread replies), `CommentViews.swift:136`,
  `SubmitReviewForm.swift:379`, and `ReviewrrApp.swift:140`'s menu item, which is enabled whenever
  a pull request is open. `ComposerSendButton` takes an `isEnabled` but no focus parameter.
- **Fix:** Give `ComposerSendButton` an `isFocused` and bind the shortcut only when focused.
  Move the menu item's ⌘⏎ to ⇧⌘⏎, or drop it, so a menu item cannot shadow a focused composer.
- **Deviation from the brief (accepted):** dev-C used an environment value `\.composerIsFocused`
  published by `ComposerShell` rather than the `isFocused` parameter I specified. The reasoning is
  better than my instruction: the inline comment composer's send button is at
  `CommentViews.swift:279`, which dev-C was not allowed to edit, so a parameter defaulting to
  `false` would have silently stripped ⌘⏎ from **the exact composer this task is about** — and the
  shell already knows the answer, so no future call site can forget to pass it.
- **Known regression, tracked in T-035:** the draft-comment editor's Done button lost its
  unconditional ⌘⏎ and has no focus state to gate a new one. That binding was never advertised and
  edits still commit via Done, click-away or `onDisappear`, so nothing is lost — but whoever takes
  T-035 should convert that editor to `ComposerShell` + `ComposerSendButton` and give the key back.
- **Behaviour change worth knowing:** ⌘⏎ no longer opens Submit Review from the diff with nothing
  focused — that is ⇧⌘⏎ now. ⌘⏎ inside the Submit Review form still submits.

### T-031 · "Expand all" on a large gap hangs the window
- **Severity:** S2 · **Area:** Views/DiffView · **Status:** open · **Owner:** —
- **Symptom:** Clicking "Expand all" on a wide gap freezes the window for seconds, then holds
  every revealed row in memory for as long as the gap is open. A 5,000-line file with two hunks
  has a ~4,900-line gap.
- **Cause (verified):** `DiffView.swift:972` builds the revealed lines into a plain `VStack` that
  is a single child of the enclosing `LazyVStack` (`:529`), so nothing virtualises — every line
  becomes a full row view with two gutters, a drag gesture, a context menu and an accessibility
  element. `:1028`'s button sets `revealedTop = total`, the entire gap.
- **Second bug, same site:** `DiffParser.gapLines` runs inside `expandedContent`, i.e. inside
  `body`, and `GapSeparatorView` holds `@EnvironmentObject var model: AppModel` — so once any gap
  is expanded, **every** visible gap separator in the file rebuilds its whole gap array on every
  `AppModel` publish, each `DiffLine.init` re-running tab expansion. `gapRows` also calls
  `pairedForSplitView()` uncached in `body`, the exact cost `UnifiedDiffView.swift:44-49`
  documents avoiding for real hunks.
- **Fix:** Reveal in bounded chunks (cap or drop "Expand all"); hoist revealed rows into
  `rowStack`'s `ForEach` so the `LazyVStack` virtualises them; memoize `gapLines` per
  `(path, hunkIndex)` in `WorkspaceModel` next to `pairedRows`.

### T-032 · Opening or refreshing a pull request SHA-256s the whole diff on the main actor before the first frame
- **Severity:** S2 · **Area:** AppModel, AIModel, Services/AI · **Status:** open · **Owner:** —
- **Symptom:** The workspace's first frame is delayed on every open **and** every ⌘R — precisely
  the moment the reviewer is already waiting. Cost scales with total diff bytes.
- **Cause (verified):** `AppModel.performLoad:1014` calls `ai.configure(...)` with no suspension
  point after `self.files = loadedFiles`, so SwiftUI cannot draw until all of this finishes on the
  main actor: `AIReviewSituation.swift:87` SHA-256s **every file's full patch** and formats each
  digest with `String(format: "%02x", …)` — 675 files × 32 bytes = 21,600 `String(format:)` calls;
  `Prompts.swift:58` walks every file taking `String.count` (grapheme clusters!) over each whole
  patch; and three `Data(contentsOf:)` + `JSONDecoder` round trips, with `AnalysisCache.loadAll`
  run **twice**.
- **Fix:** In `AIModel.configure`, keep only what the first frame needs; move `engine.situation`
  and `engine.cachedResult` into a nonisolated async step that publishes when it lands. Replace
  both hex loops with a table-based encoder. Use `patch.utf8.count`, not `patch.count`.

### T-033 · A streaming AI answer re-parses all its own markdown on every chunk
- **Severity:** S2 · **Area:** AIModel, Views/Conversation/MarkdownText · **Status:** open · **Owner:** —
- **Symptom:** The AI rail janks and the layout churns while an answer streams, worst exactly when
  the answer is longest and most useful. An answer containing a code fence is the worst case.
- **Cause (verified):** `AIModel.appendChunk:351` appends to a `@Published` array with no
  buffering, so every provider chunk republishes and re-runs the bubble's `body`. That body
  recomputes `MarkdownText.segments` (`MarkdownText.swift:57`, a computed property read from
  `body`), rebuilds `AttributedString(markdown:)` (`:388`), and re-highlights **every code-fence
  line** (`:304`) bypassing the `SyntaxHighlightCache` the diff rows use. `stripInlineHTML`
  (`MarkdownSegment.swift:371`) is ~100 whole-string passes, ~76 of them case-insensitive. Cost
  per chunk is O(length so far), so the stream is O(n²).
- **Fix:** Buffer in `appendChunk` and flush on a ~50–100 ms tick or at newline boundaries.
  Memoize `segments` and `blocks` (compute in `.task(id: text)` into `@State`). Route
  `MarkdownCodeBlock` through `SyntaxHighlightCache`.

### T-034 · Pasting a GitHub Enterprise or GitLab link is rejected as invalid
- **Severity:** S2 · **Area:** Models/PullRequest, OpenPullRequestSheet · **Status:** open · **Owner:** —
- **Symptom:** ⌘O, paste the merge request link a teammate sent, and get *"That isn't a pull
  request URL or owner/repo#number."* The Open button stays dead and the tooltip repeats the same
  false claim. There is **no input at all** that opens a nested-group GitLab merge request by hand.
- **Cause (verified):** `PRReference.parse:18-37` accepts a URL only when the host
  `contains("github.com")` and `parts[2] == "pull"`, then falls back to requiring exactly two
  slash-separated parts. So GHES URLs, GitLab `/-/merge_requests/` URLs and
  `group/subgroup/project#42` are all rejected — the last being a shape the app's own GitLab
  mapper produces.
- **Fix:** Parse against the active and known hosts' `webBaseURL` rather than a hardcoded
  `github.com`, accept `/-/merge_requests/<iid>`, and allow an owner of any depth (last path
  segment is the repo). Until then the sheet's copy must name shapes that actually work.
- **Related:** T-012 — same slash assumption, different consequence.

### T-035 · Rewriting a staged comment and pressing ⌘Q loses the rewrite
- **Severity:** S2 · **Area:** Views/CommentViews · **Status:** open · **Owner:** —
- **Symptom:** A reviewer clicks Edit on a staged comment, rewrites it over two minutes, then
  presses ⌘Q without clicking Done. On relaunch the old text is back and the rewrite is gone.
- **Cause (verified):** `DraftCommentRow` writes back only from `commitEdit()`
  (`CommentViews.swift:90-94`), reachable from Done or `onDisappear`. Unlike the inline *composer*,
  which mirrors into `WorkspaceModel.composerText` on every keystroke (`:299-301`), the edit
  editor has no mirror — so `model.draft` is never touched, `flushPendingDraftSave()` is
  `guard draftSaveTask != nil else { return }`, and the terminate handler is a no-op.
- **Fix:** Mirror on change the way the composer does, or hold the in-flight edit in
  `WorkspaceModel` and fold it in from `flushPendingDraftSave()`.
- **Note:** this is a regression risk zone — the local-`@State` editor is itself a deliberate
  performance fix (commit `be6a2b7`). Keep the local editor; add an unpublished mirror. Do not
  reintroduce a per-keystroke write to `model.draft`.

### T-036 · Watchlist and read/reviewed marks fail silently
- **Severity:** S2 · **Area:** Services/Inbox/WatchlistStore, LocalStatusStore · **Status:** needs review · **Owner:** dev-D
- **Symptom:** The volume is full, or the app's folder lost write permission. The reviewer adds
  five projects, mutes two, marks a dozen pull requests reviewed. Everything looks right for the
  whole session. Next launch: empty watchlist, every pull request unread again, no explanation.
- **Cause (verified):** `WatchlistStore.swift:43-44` and `LocalStatusStore.swift:41-42` are
  `try?` on both encode and write, and `DashboardModel.persistProjects`/`persistLocalStatus`
  return `Void`, so no caller can tell. `DraftStore` got a `saveChecked` twin and a UI banner;
  these did not.
- **Fix:** Throwing twins mirroring `DraftStore.saveChecked`, and a published error surfaced the
  way `draftSaveError` is at `RootView.swift:163`.
- **Correction from dev-D (accepted):** the encode half of my premise is theoretical —
  `JSONEncoder` on these types will not throw in practice; the real failure is the write. The
  checked twins report both, which costs nothing.
- **Dev notes (dev-D):** `saveProjectsChecked`/`saveChecked` throwing twins, silent versions kept
  as `try?` wrappers per the additive-contract rule. `DashboardModel` gained
  `saveError` + `retrySave()`, with two private flags so Retry writes exactly what failed and one
  file recovering does not clear the other's warning. The in-memory change is never rolled back —
  the reviewer's intent stands and the banner says it is not on disk yet. Extracted a shared
  `SaveFailureBanner` in `RootView`; the dashboard banner is a separate view **on purpose**,
  because `AppModel` holds `dashboard` without republishing it, so a flag read straight off
  `model.dashboard` in `RootView.body` would not redraw. Added a `DashboardPersistence` closure
  seam (same rationale as `AppContext`) so the new tests never touch the developer's real
  Application Support — which also opens the door to T-081.

### T-004 · Public repository has no licence, so nobody may use it
- **Severity:** S2 · **Area:** repo · **Status:** blocked · **Owner:** —
- **Symptom:** A developer finds Reviewrr on GitHub, wants to build or contribute, and finds no
  `LICENSE`. With no licence the default is all rights reserved: they legally cannot use, fork or
  ship it. The README invites contributions that cannot legally be accepted.
- **Fix:** Add `LICENSE` and reference it from `README.md`. Product recommends **MIT** — shortest,
  most permissive, the norm for a developer tool, and the least friction for adoption.
- **Blocked on:** the repository owner confirming the licence in writing. A developer must not
  pick one; it is a legal commitment, not a code change.

### T-080 · Two more Sign Outs delete the token with no confirmation
- **Severity:** S2 · **Area:** App/ReviewrrApp, CommandRegistry · **Status:** open · **Owner:** —
- **Found by:** dev-D, while fixing T-028 — my cause block for T-028 missed both.
- **Symptom:** T-028 put a confirmation on the Settings button, but the menu bar's "Sign Out of
  GitHub" (`ReviewrrApp.swift:73`) and the ⌘K palette's "Sign Out"
  (`CommandRegistry.swift:503-509`) both still call `auth.signOut()` immediately. The palette one
  is worse than the button ever was: it is two keystrokes and a fuzzy match away, so a reviewer
  typing "si" to reach "Show inspector" can delete their token by pressing Return.
- **Fix:** Needs pending-confirmation state on `AuthModel` or `AppModel` so a menu command and a
  palette command can raise the same dialog the Settings pane now uses. Do not duplicate the
  dialog three times — one source, three triggers.

### T-081 · The test suite writes the developer's real Application Support files
- **Severity:** S3 · **Area:** Tests · **Status:** open · **Owner:** —
- **Found by:** dev-D.
- **Symptom:** `testIgnoredPullRequestsLeaveTheBadge` and its neighbours call `setLocalStatus` /
  `applyProjectRowsForTesting`, which reach `LocalStatusStore` and `InboxCacheStore` on disk. So
  `make test` mutates the watchlist and reviewed marks of whoever runs it — this already bit us
  once this project, when a test read the developer's real watchlist.
- **Fix:** dev-D added a `DashboardPersistence` closure seam (same rationale as `AppContext`) for
  exactly this. Point the existing tests at it. Cheap, and it stops the suite having side effects
  on the machine that runs it.

### T-082 · Two services are parked in temporary files
- **Severity:** S4 · **Area:** Services · **Status:** open · **Owner:** —
- **Found by:** dev-B, deliberately, to respect file ownership during wave 1.
- **Symptom:** No user symptom — housekeeping with a deadline. `ForgeReviewAction` lives in
  `Services/ForgeReviewEvents.swift` and `ForgeHost.blobURL` in `Services/ForgeBlobURL.swift`
  because their natural homes (`Models/Draft.swift`, `Services/Forge.swift`) were owned by other
  tracks. Nothing else needs to change when they move.
- **Fix:** Move them next to `ReviewEvent` and `webURL` once those files are free, and delete the
  two files.
- **Third parked item (dev-C):** `markViewedAndAdvance` is declared as an `extension AppModel`
  inside `ViewModels/WorkspaceModel.swift`, because `AppModel.swift` was owned by another track.
  It belongs next to `stepChange`. **Live conflict risk:** if the `AppModel` owner adds a method
  of the same name this wave, the build breaks on a duplicate — check before committing.

### T-083 · `ReviewEvent.requestChanges` now means two different things
- **Severity:** S3 · **Area:** Models/Draft · **Status:** open · **Owner:** —
- **Found by:** dev-B.
- **Symptom:** After T-025 the case is GitHub's blocking event *and* GitLab's revoke-approval
  selector, and its rawValue `REQUEST_CHANGES` is never sent to GitLab. It works, but the next
  person to read it will not believe it, and the next forge added will make it worse.
- **Fix:** A distinct `.revokeApproval` case. Needs a draft-decoding story for events persisted
  under the old meaning, so it belongs with T-011's tolerant decoding rather than on its own.

### T-084 · A failed check fetch shows no CI dot rather than a warning
- **Severity:** S3 · **Area:** Views/PRHeaderView · **Status:** open · **Owner:** —
- **Found by:** dev-B, while fixing T-027.
- **Symptom:** With T-027 landed the Checks panel now says "Couldn't load checks" honestly, but
  `PRHeaderView` hides its CI dot when `overallState == .noChecks`, and on failure `checks` and
  `checkRollup` keep their previous values. So the toolbar chip — the at-a-glance signal — shows
  nothing at all rather than saying it does not know. An omission, not a false claim, which is why
  it is S3 and not S2.
- **Fix:** A warning glyph in the chip for the unknown state. Fold into T-052, which is already
  rebuilding that dot to stop relying on colour alone.

---

## S3 — confusing or degraded

- **T-040** · The saved-reviews shelf lists only the *active* host's drafts, so a reviewer with
  two hosts sees an Enterprise draft vanish when they switch to github.com and reasonably concludes
  it was lost (it is recoverable by reopening the pull request, which is why this is not S2).
  `DashboardModel.swift:58` calls `savedReviews(host: context.host)` while the inbox itself polls
  every host. Fix: iterate the same host set the poller uses, tag each draft with its host, and
  make `clearSavedReviews` host-aware or it will write a discard marker into the wrong directory.
- **T-041** · Host identity is case- and port-sensitive, so re-adding `GitHub.Acme.com` as
  `github.acme.com` orphans every draft, the token and every watched project — the files are still
  on disk and unreachable from the UI. `Forge.swift:154-174` `normalizedBase` lowercases the scheme
  but never the host, and keeps an explicit `:443`. Fix there plus `WatchedProject.makeKey`.
- **T-042** · "Show N unmodified lines" fails silently — no spinner, no message, no clue whether
  the app is slow, offline, or unauthorised. `AppModel.expandContext:1040-1051` has an empty catch
  *and* a silent nil return, and there is no in-flight state so the button does not even dim.
- **T-043** · The inbox's "Open on GitHub" and "Copy GitHub Link" build a 404 for every GitLab row
  by hardcoding `/pull/`, bypassing `ForgeHost.webURL(owner:repo:number:)` which already handles
  `/-/merge_requests/`. `InboxPanelView.swift:353-356`. `Components.swift:227-235` has the same
  hardcoding for blob URLs. **Status:** needs review · **Owner:** dev-B. Menu items are now named
  for *that row's* forge, since one inbox holds rows from every configured host. On my dash-less
  blob question dev-B built the canonical `/-/blob/` form rather than relying on a legacy
  redirect — correct call: a link that works only while a deprecated redirect survives breaks on
  the next upgrade. Tests cover a nested group across a bare host, a subdirectory install and a
  non-standard port, and a filename containing a space and a `#`.
- **T-044** · "Search all of GitHub" in the add-project sheet queries the **active** host and
  token rather than the one being browsed, and swallows the failure — the spinner flashes and
  nothing changes. Success-with-no-results and total failure render identically.
  `RepositoryPickerModel.swift:157-185`.
- **T-045** · The load-failure alert has a single OK button. When a token expires, the message
  itself says "Update it in Settings" and offers no way to get there, and the load the reviewer
  wanted has no Retry. `RootView.swift:181-185`. Add Try Again / Open Settings / Cancel.
- **T-046** · *(assigned to dev-E, which stalled before making a single edit — back to `open`,
  nothing salvaged)* The README claims "errors name the endpoint that failed". `GitHubAPI` never does —
  not in `send:227-239`, not in `decode:421-427` — so a 403 during a pull-request open could be
  any of six calls. GitLab does it for 400/409/422/429/5xx but not 401/403/404 or decoding
  failures. Fix both, or soften the README.
- **T-047** · GitLab's missing "Participated" bucket is indistinguishable from "you have not
  participated in anything", and for a mixed GitHub+GitLab reviewer the bucket silently contains
  only GitHub rows. `GitLabInboxService.swift:152-156` returns nil → `[]`, and
  `InboxPanelView.swift:196-204` skips empty sections. Report per-bucket support and render an
  explicit disabled section.
- **T-048** · The shortcuts sheet — the app's own discovery surface for a keyboard-driven tool —
  is wrong in four ways at once: a duplicate `ForEach` id on `"v"` means the un-mark behaviour
  never renders and SwiftUI logs an undefined-results warning (`ShortcutsSheet.swift:16-17,49`);
  it advertises ⌘. for Cancel, which nothing binds (`:26`); its own Done button promises Esc in
  the tooltip and binds Return, and the sheet has no `.cancelAction` — the only dismissible
  surface in the app that doesn't (`:38-41`); and it documents 4 of ~16 ⌘ bindings, **omitting
  ⌘K**, a headline feature. Fix: derive the sheet from one source shared with `ReviewrrCommands`
  and `CommandRegistry` so the three cannot drift again.
  **Status:** needs review · **Owner:** dev-C.
  **Correction (dev-C):** my claim that "nothing binds ⌘." was half wrong — it *is* bound, in
  `OpenPullRequestSheet.swift:98` as a stop-alias for Cancel. What was actually wrong is that the
  sheet advertised it under "Submit review", where nothing binds it. Now listed against the sheet
  that owns it.
  **Dev notes:** One catalog in `Models/Shortcut.swift` (35 declarations, one exhaustive switch),
  feeding all 14 menu chords, all 14 palette labels, `DiffView`'s bare-key set and the nav bar's
  tooltips. `display` is *derived from the chord*, so advertising a key the app does not bind is
  structurally impossible. 32 printed rows now cover every ⌘ binding including ⌘K; ids unique by
  construction; Escape added via the house `.cancelAction`-in-`.background` pattern while Done
  keeps Return.
  **New constraint on everyone:** dev-C's test reads `Sources/` back from `#filePath`, so any
  hand-written `.keyboardShortcut("x", modifiers:)` anywhere must now be declared in `Shortcut`
  (`.defaultAction`/`.cancelAction` exempt). That is the point — but it means T-074 and anything
  adding a chord will hit a failing test with instructions. Both assertions were mutation-tested.
- **T-049** · ⇧⌘V and bare `v` are documented as one action and do two different things — the
  nav-bar tooltip teaches ⇧⌘V for "mark viewed", but ⇧⌘V does not advance, so a reviewer who
  presses it twice **un-marks the file they just finished**. **Status:** needs review ·
  **Owner:** dev-C — made to agree rather than renamed: one `markViewedAndAdvance(_:)` behind the
  key, the menu item, the palette command and the nav-bar tick, with state-dependent labels. A
  test pins that two triggers of one behaviour carry one identical sentence.
- **T-050** · `DraftStore` keys its host directory on base64 rather than the `identityKey` every
  other store uses, so (a) two hosts differing only in case collide on a case-insensitive volume
  and (b) the obvious future cleanup silently orphans every Enterprise and GitLab draft. Change it
  **now**, with a one-shot rename, before more drafts accumulate. Coordinate with T-012.
- **T-051** · Two GitLab projects can collide onto one draft file, because `owner_repo_number.json`
  is ambiguous when group or project paths contain underscores — `a_b/c` and `a/b_c` both produce
  `a_b_c_1.json`. Subsumed by T-012's hashed filename; verify it is covered.
- **T-052** · **Status:** needs review · **Owner:** product (self-authored — wants a second pair
  of eyes, and runtime verification I could not do: no Screen Recording permission on this
  machine, so this is build-verified and read-verified only). The rollup is now a glyph per state
  reusing **the same symbols the per-check rows already use**, so the chip and the list it
  summarises cannot disagree; colour reinforces the shape instead of carrying it. Pending stays
  the only state that moves — the app's "nothing loops without a reason" rule — but it is now the
  glyph that pulses and its shape is a *dotted* ring, so "pending" survives a screenshot and
  Reduce Motion, which the old pulsing dot did not. The reviewer ring got the same treatment: a
  badge glyph for approved and changes-requested only, since "commented" and "pending" are not
  verdicts and badging them would bury the two that are. Original finding: CI rollup state in the
  toolbar chip was a 6pt dot whose only channel is hue —
  red/green at 6pt with identical shape is the textbook colour-blindness failure, and it is the
  chip's only signal. `PRHeaderView.swift:305-339`. The per-check rows already do this correctly
  with a glyph *and* a word *and* a tint (`ChecksListView.swift:77-85`) — copy that. Reviewer
  approval state has the same colour-only problem (`PRHeaderView.swift:215-221`).
- **T-060** · `AppModel.parsingPaths` is `@Published` but **has no reader anywhere in the app** —
  the pane tests `parsedFiles[…] == nil` instead. Because `ObservableObject` invalidation is
  object-wide, each insert and remove is a whole-window invalidation, and they straddle an `await`
  so they cannot coalesce: one `j` press asks for ~6–8 render passes, four of them for files the
  reviewer is not looking at. Delete it. Also early-out in `refreshCanvasWidth` and narrow its
  `onChange` to the open file so a prefetched neighbour cannot resize the pane. **Do this inside
  T-023**, which rewrites the same property.
- **T-061** · Every materialised diff row still holds `@ObservedObject WorkspaceModel.shared` to
  read one flag, so a gutter drag re-renders every visible row per pointer step, and the file
  filter's debounce does the same. `DiffView.swift:1055`, `UnifiedDiffView.swift:63`,
  `DiffView.swift:748`. `docs/performance.md` records this exact fix for `DiffLineGutter` via an
  environment key — it stopped one level short of the row.
- **T-062** · Every `n`/`p` press re-pairs the whole open file, ignoring the memo sitting next to
  it: `DiffNavigator.rowIdentity` (`WorkspaceModel.swift:326`) calls `pairedForSplitView()`
  uncached while `WorkspaceModel.pairedRows` (`:1111`) is the memoized version of identical work.
- **T-063** · `recomputeRows()` JSON-encodes and rewrites the entire merged inbox synchronously on
  the main actor at the end of every project sync and every buckets sync.
  `DashboardModel.swift:731-737`.
- **T-064** · The drafts directory grows forever — no prune, no TTL, no cap, unlike every other
  cache — and `persistDraft` re-reads and decodes **every file in it** on each typing pause, on
  the main actor. After a year of markers that is a visible hitch while typing a comment.
  `DraftStore.swift:48-76`, `AppModel.swift:1101`. `LocalStatusStore`'s dictionary is unbounded too.
- **T-002** · Every AI request sends a dead URL as this app's identity.
  **Status:** needs review · **Owner:** dev-agent-1 — *see Done candidates below.*

---

## S4 — polish

- **T-070** · A `.failed` Keychain status shows a bare integer (*"The Keychain returned error
  -25300."*) while every sibling case in the same switch gets a headline, an explanation and two
  buttons. `AccountSettingsView.swift:291`; `SignInView.swift:484` handles only `.denied`, so
  `.failed` shows nothing at all there.
- **T-071** · Clear-drafts reports success when deletion failed: `removeJSON` swallows each
  per-file failure and counts only successes, so a permissions failure shows the green *"No drafts
  to clear."* while the size column beside it still reads 4 MB.
  `DataSettingsView.swift:147-163`.
- **T-072** · ⌘R is bound in four places and ⌘O in three, several live simultaneously. Harmless
  today except that the menu item is never `.disabled` while the toolbar buttons are — which is
  what makes T-020 reliably reproducible. Keep the shortcut on the menu item only.
  **Still open, and dev-C's new collision test does not catch it:** all four ⌘R sites invoke the
  *same action*, so the catalog holds one entry and the collision rule stays quiet. Duplicate
  binding *sites* for one action remain unguarded. Fix alongside T-020, whose repro depends on it.
- **T-073** · GitHub-only vocabulary on GitLab surfaces: "N pull requests", "Open on GitHub", "No
  GitHub token", "Checking GitHub…", "Opening pull request", "Couldn't load pull request". The
  `Forge.changeNoun*` machinery exists and is used correctly in two places; these sites never
  adopted it. `InboxPanelView.swift:34,342`, `ProjectSidebarView.swift:110,507`,
  `AddProjectSheet.swift:127`, `LoadingViews.swift:91,128`, `RootView.swift:181`,
  `OpenPullRequestSheet.swift:21,26`.
- **T-074** · The Help menu is `CommandGroup(replacing: .help)` containing one item that is
  disabled on the dashboard — so Help opens to a single greyed-out row. Also macOS convention for
  help is ⌘? not ⌘/. `ReviewrrApp.swift:164-168`. The shortcuts sheet has no pull-request
  dependency and could open from anywhere. **Promoted from S4 to S3 (dev-C):** the sheet now
  documents dashboard bindings too (⌘F, ⇧⌘F), so the app's keyboard documentation covers the
  dashboard while being *unreachable* from it. Note the chord change must go through
  `Models/Shortcut.swift` or dev-C's scan test will fail — by design.
- **T-075** · The shortcuts sheet claims ←/→ collapse and expand folders in the file tree, but
  directory rows are deliberately untagged in a `List(selection:)`, so keyboard focus never lands
  on a disclosure triangle. `ShortcutsSheet.swift:12` vs `FileTreeView.swift:71-86`.
  **Verify by hand before changing** — this one is code-reasoned, not runtime-confirmed.
- **T-076** · The one hint that a comment-only review needs a summary is rendered in `.tertiary`
  `caption2` — validation state styled as decoration. `SubmitReviewForm.swift:202-204`.
- **T-077** · Dead code: `DraftStore.save(_:for:)` and `clear(for:)` have no callers and are
  hardwired to `host: .dotCom`, so whoever reaches for `save` next will silently write GitLab
  drafts into the github.com directory. Also `DiffContainerView.openFileIndex`
  (`DiffView.swift:71`) has no call site. Delete all three.
- **T-005** · The review workspace's own sidebar still looks non-native — the dashboard column now
  gets the system's vibrant sidebar material, the workspace file tree paints `.bar` over
  `.sidebar`, so the left column changes texture as you enter a pull request. Product decision on
  which is right, then a small change.
- **T-003** · README pins a test count that goes stale. **Status:** needs review ·
  **Owner:** dev-agent-1.

---

## Needs product verification

- **T-002**, **T-003** — dev-agent-1, in the working tree, `make test` 676 passing.

## Watch list — reported but not yet a task

- `GitLabInboxService.bucketQuery(.needsReview):141-147` emits a duplicated `scope` key **and**
  `reviewer_id=Any`, which means "has any reviewer", not "I am the reviewer". If GitLab honours
  the last `scope`, the GitLab "Needs review" bucket lists merge requests *assigned to* the
  reviewer rather than *awaiting their review* — i.e. review requests may never reach the inbox,
  with nothing on screen to say so. **Needs checking against a live instance before it becomes a
  task.** If confirmed it is S1: the inbox is the product's front door.
- Whether j/k work immediately after dismissing the ⌘K palette or the shortcuts sheet.
  `containerFocused` is asserted once and never re-asserted; T-029's fix should cover it.

## Done

*(nothing yet)*

## Rejected

*(nothing yet)*
