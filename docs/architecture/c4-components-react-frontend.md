# React frontend components

The frontend owns interaction and presentation state. All durable and privileged operations cross the typed Wails boundary.

```mermaid
C4Component
  title Component diagram for the Reviewrr React application

  Person(reviewer, "Code Reviewer", "Navigates and confirms review actions")
  Container(goHost, "Native Application Host", "Go, Wails v2", "Owns privileged operations and durable state")

  Container_Boundary(reactUi, "Review Workspace UI: React and TypeScript") {
    Component(desktopShell, "Desktop Shell", "React", "Project launcher, layout, notifications, routing, and errors")
    Component(prInbox, "Watched-Project Inbox", "React", "Project-grouped all-state PR search, filters, and personal status")
    Component(reviewNavigation, "Review Navigation", "React", "Overview and changed-file folder tree")
    Component(diffWorkspace, "Diff Workspace", "Monaco Diff Editor", "File tabs, hunks, lines, and decorations")
    Component(discussionLayer, "Discussion Layer", "React", "Anchored, outdated, and general discussions")
    Component(reviewComposer, "Review Composer", "React forms", "Draft comments, summary, event, and confirmation")
    Component(acpPanel, "ACP Review Panel", "React", "Structured findings, agent/model choice, reuse state, and follow-ups")
    Component(clientState, "Client State", "Query cache plus UI store", "Remote/cache queries and ephemeral selection")
    Component(wailsAdapter, "Wails Adapter", "Generated TypeScript bindings", "Typed commands and versioned event subscriptions")
  }

  Rel(reviewer, desktopShell, "Opens repositories and arranges the workspace")
  Rel(desktopShell, prInbox, "Shows PRs across watched projects")
  Rel(desktopShell, reviewNavigation, "Shows selected PR navigation")
  Rel(desktopShell, diffWorkspace, "Shows selected file changes")
  Rel(desktopShell, acpPanel, "Shows AI assistance")
  Rel(prInbox, clientState, "Reads filters, results, and freshness")
  Rel(reviewNavigation, clientState, "Changes selected section and file")
  Rel(diffWorkspace, clientState, "Reads diff state and writes line selection")
  Rel(discussionLayer, diffWorkspace, "Decorates anchored lines")
  Rel(reviewComposer, diffWorkspace, "Creates drafts from selected anchors")
  Rel(acpPanel, diffWorkspace, "Reads selection context and navigates findings to code")
  Rel(clientState, wailsAdapter, "Loads durable data and starts operations")
  Rel(wailsAdapter, goHost, "Invokes commands and receives events", "Wails bindings/events")
  Rel(reviewComposer, wailsAdapter, "Saves drafts and confirms submission")
  Rel(acpPanel, wailsAdapter, "Starts, prompts, and cancels ACP sessions")

  UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

## Interaction constraints

- The three primary panels remain independently resizable and keyboard reachable.
- PR and file navigation must not discard unsaved local drafts.
- AI output, GitHub content, and local human drafts use distinct visual treatments and labels.
- AI findings stay in the right panel and never create diff decorations or comments.
- A submit action always opens a final confirmation showing destination repository, PR number, head revision, event, summary, and comment count.
- Error boundaries isolate Monaco and ACP rendering failures from the PR inbox and draft composer.

## Key

- Components are frontend feature boundaries bundled into one React application.
- The Wails adapter is the only frontend component aware of generated native bindings and raw event names.
