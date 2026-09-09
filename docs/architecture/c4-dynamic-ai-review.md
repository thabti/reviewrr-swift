# Structured ACP review flow

This flow starts only when the reviewer opens an eligible PR. Agent output is advisory, appears only in the right panel, and is bound to the exact PR head revision.

```mermaid
C4Dynamic
  title Dynamic diagram for structured ACP review on PR open

  Person(reviewer, "Code Reviewer", "Opens a PR and performs the human review")
  Container(reactUi, "Review Workspace UI", "React, TypeScript", "Displays diff and structured right-panel analysis")
  Component(diffService, "Diff Service", "Go", "Owns exact revision content and eligibility inputs")
  Component(aiPipeline, "AI Review Pipeline", "Go", "Chooses reuse, extension, or fresh analysis")
  Component(acpManager, "ACP Manager and Policy", "Go plus ACP adapter", "Owns process lifecycle and read-only permissions")
  Component(schemaValidator, "Result Validator", "Go", "Validates the versioned JSON response and requests one repair")
  ContainerDb(reviewStore, "AI Review Store", "SQLite and local cache", "Stores revision-scoped results, hashes, and lineage")
  System_Ext(acpAgent, "Selected ACP Agent", "Kiro, OpenCode, or experimental custom command")

  Rel(reviewer, reactUi, "1. Opens a PR")
  Rel(reactUi, diffService, "2. Requests exact base/head content and discussions", "Wails binding")
  Rel(diffService, aiPipeline, "3. Supplies revision context, file count, exclusions, and size")
  Rel(aiPipeline, reviewStore, "4. Checks eligibility and a revision/agent/model/schema/content cache key")
  Rel(reviewStore, aiPipeline, "5. Returns reusable result or extension lineage when available")
  Rel(aiPipeline, acpManager, "6. Starts fresh or extension analysis only when needed")
  Rel(acpManager, acpAgent, "7. Negotiates ACP v1 and creates a revision-scoped session", "ACP/stdio")
  Rel(acpManager, acpAgent, "8. Sends bounded context and the required JSON contract", "ACP/JSON-RPC")
  Rel(acpAgent, acpManager, "9. Streams progress and a terminal response", "ACP session/update")
  Rel(acpManager, schemaValidator, "10. Supplies the normalized terminal response")
  Rel(schemaValidator, acpAgent, "11. Requests one schema repair only when invalid", "ACP/JSON-RPC")
  Rel(schemaValidator, reviewStore, "12. Persists valid structured output or labeled fallback")
  Rel(reviewStore, reactUi, "13. Returns reused, extended, or fresh result with provenance", "Wails event")
  Rel(reactUi, reviewer, "14. Renders advisory sections; a finding can navigate to code")
```

## Eligibility and reuse rules

- Automatic analysis runs only after an explicit PR open, only for PRs with fewer than 30 changed files, and only while the bounded text/context budget is satisfied.
- Binary, generated, vendor, oversized, or unavailable files are excluded and recorded in `skippedFiles`.
- Polling never starts an agent.
- A result is reusable only when head SHA, agent, model, prompt/schema version, and content hash match.
- New discussions, reviewer feedback, or newly available relevant context can extend an existing result. A revision, agent/model, schema, or incomplete-result change requires fresh analysis.
- Reused, extended, fresh, invalid, and fallback states remain visible to the reviewer.

## Failure branches

- Ineligible PR: do not start ACP; explain the file-count, content-size, or unsupported-file reason and retain manual file/selection actions.
- Unsupported ACP version, model, or required capability: fail with an actionable compatibility or setup explanation.
- Agent requests a path outside the disposable context root, a filesystem write, or a terminal: deny and record normalized metadata.
- Invalid JSON: issue exactly one repair prompt; if it remains invalid, preserve and clearly label the unstructured fallback.
- Agent exit or malformed protocol data: terminate the connection, preserve useful received output, and keep the human review workspace usable.
- PR head change: cancel active work, archive its result under the old SHA, switch the UI immediately, and evaluate the new revision independently.

## Trust statement

ACP permission handling controls protocol-mediated actions; it does not sandbox the operating-system process. Reviewrr launches only a reviewer-selected agent and makes that trust boundary explicit.

## Key

- The AI response contract is defined in [AI review result v1](ai-review-result-v1.md).
- Findings exist only in the right panel. Navigation to a diff line does not create an annotation, draft, or GitHub comment.
- The disposable agent context is separate from both a user's source worktree and Reviewrr's managed Git mirror.
