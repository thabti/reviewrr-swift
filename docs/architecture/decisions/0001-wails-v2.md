# ADR-0001: Use Wails v2 for the desktop application

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

Reviewrr requires native directory selection, local Git access, subprocess management, SQLite, a rich diff UI, and cross-platform packaging. The user selected Go with React/TypeScript and Wails.

Wails v2 is the current stable release line and provides Go-to-JavaScript bindings, generated TypeScript models, runtime events, native dialogs, and Vite-based frontend development. Wails v3 is beta and would add avoidable API and packaging churn to the first product cut.

## Decision

Build the MVP on the latest compatible Wails v2 release. Use:

- Go for native and privileged capabilities.
- React/TypeScript for the embedded WebView UI.
- Generated Wails bindings for commands and domain DTOs.
- Wails runtime events for sync and ACP streams.

The application façade will keep Wails-specific APIs at the edge so a future Wails major-version migration does not leak through domain services.

## Consequences

### Positive

- One Go binary can embed frontend assets.
- Native filesystem and process operations stay out of the browser environment.
- Generated TypeScript definitions reduce cross-boundary drift.
- React and Monaco can implement the design's dense three-panel workspace.

### Negative

- System WebView differences require platform testing.
- Wails event subscriptions and generated bindings become explicit test surfaces.
- The project must track Wails v2 security and compatibility updates while v3 matures.

## Revisit when

- Wails v3 reaches stable and provides a documented migration path.
- A required Monaco or accessibility behavior cannot be made reliable in supported system WebViews.

## References

- [Wails v2 introduction](https://v2.wails.io/docs/introduction/)
- [Wails bindings](https://v2.wails.io/docs/howdoesitwork/)
- [Wails runtime events](https://wails.io/docs/reference/runtime/events/)
