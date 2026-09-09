# Performance

The review workspace has one hard requirement: scrolling a diff must never
miss a frame. This is how that is measured, what the numbers currently are,
and what was slow when they were first taken.

## Running the benchmark

```
make bench                      # 300-file synthetic PR, frame probe on
make bench STRESS=675           # the size of the PR this app is used on
```

`make bench` builds **Release** — Debug numbers are meaningless here, because
unspecialised generics and bounds checking dominate — and launches the app on
a synthetic pull request with the frame probe running. Two environment
variables drive it, and both are off in an ordinary run:

| Variable | Effect |
| --- | --- |
| `REVIEWRR_STRESS=<files>` | Replaces the demo fixture's file list with `StressFixture`: `<files>` synthetic files, the first deliberately enormous. `1` means "the default size". Also opens the demo straight away and skips the large-file guard. |
| `REVIEWRR_PERF=1` | Turns on `PerfProbe`: per-view `body` counts and durations, the main-thread stall monitor, and a report on stderr every five seconds. |
| `REVIEWRR_PERF_SCROLL=<seconds>` | Runs the automated interaction pass below, `<seconds>` per phase, and prints a report per phase. Needs `REVIEWRR_PERF=1`. |

The pane scrolls itself rather than waiting for a trackpad: a benchmark that
needs a person is a benchmark nobody re-runs, and synthetic input events need
Accessibility permission a `build/` binary does not have. It opens the largest
file in the pull request and then runs three phases:

1. **row scroll** — three new rows per frame at 60Hz, up and down the file.
   This is a fling on a trackpad, and it is the number that answers "is
   scrolling smooth".
2. **file stepping** — a new file every 250ms, which is `j` held down.
3. **screen jump** — a whole screenful per frame. Nobody scrolls like this; it
   is the ceiling on how much work one frame can be asked for.

## What the probe measures

`PerfProbe.begin()`/`end(_:_:)` bracket a view's `body` — the count matters as
much as the duration, because a `body` that runs when nothing it draws has
changed is pure waste.

`StallMonitor` measures the main run loop's **busy interval**: from the moment
it wakes to the moment it sleeps again, via a `CFRunLoopObserver`. That is
main-thread occupancy, whoever caused it, so it catches the costs nobody
instrumented. It is deliberately *not* timer lateness — an idle Mac coalesces
timers, and a 4ms timer reports 20ms of "stall" that no reviewer would ever
see.

A `body` total that is a small fraction of the busy time means the cost is in
SwiftUI's own layout and attribute graph, not in the code you wrote. When that
happens, `sample Reviewrr 8 1 -file /tmp/sample.txt` during a phase gives the
real attribution.

## Current numbers

Release build, M-series Mac, 300-file synthetic PR, the open file 646 rows
across 34 hunks. "Over budget" counts run-loop passes longer than 16.7ms —
one frame at 60Hz.

| Phase | Passes over budget | p50 | p95 | worst |
| --- | --- | --- | --- | --- |
| row scroll (3 rows/frame) | 0.3–0.6% | 0.9ms | 11ms | 64ms |
| file stepping (one per 250ms) | 13–15% | 1.4ms | 147ms | 203ms |
| screen jump (one screen/frame) | ~10% | 2.5ms | 46ms | 100–260ms |

Run-to-run spread is a couple of points on the percentages and tens of
milliseconds on the worst case — the worst case is usually a single pass that
caught an unrelated system hiccup. Compare p50/p95 across runs, not worsts.

Scrolling is smooth: the main thread is idle for half of a continuous fling
and effectively never misses a frame. Opening a file still costs ~145ms on a
300-file pull request; the remaining time is SwiftUI's own graph and layout
(`AG::Subgraph::update` ~47% of samples, of which the pane's lazy stack is
~10%, text resolution ~6%, AppKit layout ~6%), with no single hotspot left in
this codebase.

## What was slow, and why

Taken in order of what the measurements actually indicted — which was not what
one would guess. Row `body` code was never more than ~1.5% of the main
thread's time; **the number of view-graph nodes per row** was the thing that
mattered, because SwiftUI's layout and dirty-propagation costs scale with it.

* **Nodes built to draw nothing.** Every gutter cell kept a `Button`, an
  `Image`, a help tag and an accessibility element mounted at `opacity(0)` for
  the hover "+", two per row. Every row built the jump-flash overlay — a
  stack, two rectangles and two modifiers — to draw nothing on 44 rows out of
  45. Every row held two `ForEach` nodes standing by to iterate empty thread
  and draft arrays, inside a `VStack` that existed only to stack them. All of
  it now appears in the tree only when it has something to show.
* **A gesture per gutter cell.** A unified row's two gutters select the same
  line on the same side, so the second `DragGesture` and its `@GestureState`
  were pure cost. One per row now, still scoped to the gutters.
* **Ninety `ObservableObject` subscriptions.** Each gutter cell observed
  `WorkspaceModel` to answer "am I selected?", so any change to any of its
  published properties re-rendered all of them. The selection is published
  once for the pane through the environment instead.
* **The sidebar re-rendering on every keystroke.** Every file row observed
  `AppModel`, so selecting a file rebuilt and re-laid-out all 300 rows.
  `FileLeafRow` is now a pure value view behind `.equatable()`, with a thin
  observing wrapper above it; unchanged rows are skipped entirely.
* **A filesystem walk inside a view body.** `AIPanelView.init` seeded its
  state from `AgentEnvironment.resolvePath`, which `stat`s a dozen
  directories, and the inspector rebuilds that view whenever the root view's
  body runs — 6% of the main thread while stepping through files. The
  resolution is memoized for five minutes, and "Check again" in Settings
  invalidates it.

Two things that looked obvious and measured as nothing, recorded so nobody
pays for them twice:

* **Pinning row heights.** Replacing `minHeight` with an exact height, so the
  lazy stack would not have to measure each row, changed the screen-jump
  figure from 12.9% to 12.0% — inside the noise — and risked clipping
  descenders. Reverted.
* **Bucketing lazy-stack children.** Grouping rows so the stack walks ~20
  children instead of 650 made things *worse*: row scroll went from 0.3% to
  4.0% over budget, because materializing a bucket costs more than the walk it
  saves. Reverted.
