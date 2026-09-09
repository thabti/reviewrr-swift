# S14 visual audit

Audit date: 2026-09-05. Reference: `design/code review.png`, supported by the other dark-editor references in `design/`.

Baseline evidence was captured at 1440x900, 1280x900, and 1728x1080 for `/demo`, `/facebook/react/pull/28000`, `/`, and `/settings`. The images are under `.browse/sessions/default/audit-*.png`.

## Findings

1. **The three-pane chrome does not share one vertical rhythm.** The left sidebar header is 32px, the center top bar is 44px, and the right tab header is 56px. Their controls and bottom borders land on different horizontal axes, so the workspace reads as three adjacent products instead of one tool. Use a shared 44px primary header, then keep secondary rows at 32px.
2. **Split diffs lose the review context at common widths.** On `/demo`, the 1440px and 1280px captures show a large empty field, while the changed code is pushed into a narrow strip at the far right. The table width is derived from twice the longest line, which moves the new side outside the initial viewport. Keep fixed gutters and a true 50/50 split in the visible center pane; clip or wrap code within its half instead of shifting the second half away.
3. **The center pane is too padded for a code-review workspace.** File blocks use 16px outer padding and 12px gaps, while the reference uses a denser editor canvas with roughly 8–12px insets and 8px gaps. The extra space reduces visible code and makes file cards feel detached. Reduce the canvas inset and inter-file spacing while preserving clear card boundaries.
4. **Primary hierarchy is compressed in the center header.** The PR title is only 14px and medium weight, while its state chip competes with it. At narrow widths, repository, branch, and file metadata also consume the title’s line. Increase title weight, keep metadata at 11px, and make the state chip compact and tonal so the title reads first.
5. **The right panel header and control stack overpower the summaries.** A 56px tab bar, an 40px progress row, and a 44px complexity row consume too much vertical space. Their filled controls are brighter than the summary titles. Align the tab bar to 44px, make utility rows 32px, and use quieter selected fills so the content regains priority.
6. **Summary-card hierarchy is reversed.** The complexity icon and line-range badge are visually stronger than truncated summary titles, and the active card adds both a strong fill and a ring. Titles should lead, ranges should read as metadata, and complexity must remain legible without color. Use labeled chevron shapes through `aria-label` and icon form, quieter range text, a restrained active border/accent, and consistent 8px card padding.
7. **Layer rows and summary rows use different density and selection languages.** Layer rows are 28px with a subtle fill; summary rows are taller cards with stronger borders and rings. This breaks the left-to-right reading relationship. Keep layers compact, bring summaries closer to a 36px collapsed row, and use the same low-contrast accent/border treatment for selected states.
8. **Diff details need stronger functional contrast.** Line numbers are faint, +/- markers nearly disappear, the add-comment affordance appears as an abrupt solid square, and the unmodified separator resembles a card row. Increase number and marker contrast slightly, use a consistent 150ms opacity/color transition, keep the hover affordance in the gutter without layout shift, and flatten gap separators into the diff surface. Preserve subtle emerald/red tints so syntax remains dominant.
9. **File headers are visually heavier than pane headers.** Their 40px height, multiple badges, two count labels, comment badge, and filled viewed button crowd long paths. Make file headers 36px, ensure the path owns the flexible space, keep metadata compact, and reserve the emerald fill for the completed viewed state.
10. **Home and settings feel softer and more spacious than the review surface.** The home hero uses a large glow and broad vertical gaps; settings uses 24px page gaps and rounded cards with roomy content. The contrast is not broken, but the product loses its dark-editor identity between routes. Tighten top chrome to 44px, reduce page/card gaps, use near-black token surfaces and subtle borders, and retain the current accessible form controls.
11. **Spacing utilities drift from the stated scale.** Custom UI uses `space-y-*`, 3px-like values, and mixed 10/12/14/16px icon sizes. This makes rhythm inconsistent and diverges from shadcn composition guidance. Prefer flex/grid `gap-*`, use 12px utility icons and 16px semantic icons, and standardize control transitions around 150ms.
12. **The token theme is neutral but not dark-editor deep.** Dark `background` and `card` are close enough that large blank areas look gray rather than near-black, while selected surfaces become comparatively loud. Refine the existing OKLCH semantic tokens, not component-specific colors, so a future light theme still works. Keep all emerald, red, amber, and violet accents semantic and state-bound.

## Fixed

1. **Aligned primary chrome.** Sidebar, center, right-panel, home, settings, and loading-shell headers now use a shared 44px height. Their controls and borders land on one axis.
2. **Restored a visible split.** `SplitDiff` no longer derives a viewport-displacing width from the longest line. Its fixed gutters and code tracks remain 50/50 at all audited widths. One-sided changes show an intentional striped empty half instead of pushing the populated side away.
3. **Tightened the review canvas.** Center-pane insets moved from 16px to 12px, and file-block gaps moved from 12px to 8px. Overview surfaces use the same denser inset.
4. **Clarified top-bar hierarchy.** The PR title is now semibold, metadata remains muted at 11px, and open/merged/closed states use compact tonal badges instead of solid high-contrast blocks.
5. **Reduced right-panel chrome.** The tab header is 44px, progress is 32px, complexity controls are 36px, and utility controls use quieter 24px treatments.
6. **Rebalanced summary cards.** Collapsed cards are approximately 36px tall, titles lead with medium weight, line ranges use a quiet outline treatment, and active state uses one restrained accent/border. Low, medium, and high complexity now use three distinct Tabler shapes, not color alone.
7. **Unified row and selected-state language.** Summary rows now use the same compact radius, subtle border, and low-contrast selected fill as the left-side navigation.
8. **Improved diff legibility.** Line numbers and +/- markers gained measured contrast, diff tints were reduced, the gutter comment button uses a stable bordered hover affordance with a 150ms transition, and unmodified separators sit flatter in the diff surface.
9. **Reduced file-header weight.** File headers are 36px, paths own the flexible width, counts stay compact, and only the completed viewed state receives the emerald treatment.
10. **Brought home and settings into the workspace language.** Both routes now use 44px top chrome, tighter vertical gaps, subtler token surfaces, smaller neutral atmosphere, and lower-contrast card boundaries.
11. **Normalized composition spacing.** Custom stacks touched by this pass use flex/grid gaps instead of `space-y-*`; utility and semantic icons follow the existing 12px/16px scale.
12. **Deepened semantic dark tokens.** Background, card, popover, muted, accent, input, border, sidebar, and radius tokens now produce a near-black editor ground. No component-specific gray, hex, or RGB values were introduced, and the light token set remains valid.

## Proof

- After images: `.browse/sessions/default/after-{demo,real,home,settings}-{1440,1280,1728}.png`.
- The required overflow probe returned `[]` for all four routes at 1440x900, 1280x900, and 1728x1080.
- `pnpm exec tsc -p tsconfig.app.json --noEmit`: zero errors.
- `pnpm exec vitest run`: seven files and 44 tests passed. Vitest printed its existing non-failing future Vite native-config warning for `__dirname` in `vitest.config.ts`.
- Changed custom surfaces contain no `console.log`, `any`, or Lucide imports.

## Deliberately left alone

- Generated `src/components/ui/**`, store APIs, shared contracts, component exports, data flow, and review behavior were not changed.
- The application still forces dark mode. The existing light tokens were preserved so a future theme switch has a valid semantic base.
- Non-wrapped split lines are visually clipped within their equal half to keep both review sides present. Word wrap and unified view remain available when the complete long line is more important than side-by-side context.
- No new dependency, dev server, build, or Git command was run.
## S21 ship-readiness follow-up

Audit date: 2026-09-05.

- Captured and inspected current Home, Settings, and demo workspace screenshots at 1440x900 under
  `docs/img/`; the demo has separate dark and light captures.
- Rechecked Home, Settings, and Demo at 1440x900 and 1280x900 in dark and light themes. All 12
  combinations matched the selected theme, had no page-level horizontal overflow, and produced no
  runtime console errors.
- Rechecked the no-credential flow. Public PRs load under GitHub's anonymous limit, heuristic
  analysis runs without an AI key, and the private/unavailable PR state explains that repository
  access needs a token.
- `pnpm exec tsc -p tsconfig.app.json --noEmit` passed with zero errors.
- `pnpm exec vitest run` passed eight files and 50 tests. Vitest printed the existing non-failing
  future native-config warning for `__dirname` in `vitest.config.ts`.
- An unavailable PR causes six expected browser network 404 console entries because the GitHub client
  starts its parallel metadata, files, and comments requests before it knows the repository is
  unavailable. The user-facing error is clear; the requests originate in files outside S21 ownership.
