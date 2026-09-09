# ADR-0008: Render structured AI assistance only in the right panel

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

AI should support, not replace, human code review. Different ACP agents and models produce inconsistent prose, making a stable UI difficult. Automatically placing AI findings into the diff could blur authorship and overstate confidence.

## Decision

- Start automatic analysis only when the reviewer opens a PR with fewer than 30 changed files and the eligible textual context is within configured size limits.
- Never start AI during watched-project polling.
- Require one versioned JSON object with: scope, overview, review order, file summaries, findings, test gaps, architecture impact, reviewer questions, limitations, and skipped files.
- Bind every result to head SHA, agent, model, prompt/schema version, and analyzed-content hash.
- Validate against JSON Schema, request one repair on failure, then expose an honest unstructured fallback.
- Render AI only in the right panel. Findings may navigate to a file/line but never decorate the diff or create a comment.
- Render sections in a stable initial order: overview, review order, severity-sorted findings, test gaps, architecture impact, reviewer questions, file summaries, limitations, and skipped files.
- Reuse matching cached results immediately, extend them for new discussions/current-reviewer feedback/new context, and run fresh after revision, agent/model, schema, or completeness changes.
- Use all participant comments as facts, but learn temporary preferences only from the current reviewer's drafts, submitted comments, accepted findings, and dismissed findings.
- Expire learned preferences seven days after the project was last explicitly opened.

## Consequences

### Positive

- The frontend gets a stable rendering contract across Kiro and OpenCode.
- Human and AI authorship remain visually and behaviorally distinct.
- Reuse reduces latency and model cost while extension keeps results current.

### Negative

- Prompt-level structured output is probabilistic and requires validation/fallback UX.
- The 30-file rule also needs a separate size budget for unusually large files.
- Prompt/schema changes invalidate otherwise useful cached results.

## Revisit when

- ACP standardizes a portable structured-review result type.
- User research supports opt-in AI decorations without confusing human review ownership.
