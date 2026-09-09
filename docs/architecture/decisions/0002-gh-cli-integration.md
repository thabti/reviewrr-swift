# ADR-0002: Use GitHub CLI as the GitHub access boundary

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

Reviewrr needs GitHub authentication, repository discovery, paginated PR reads, checks, diffs, discussions, and review submission. Implementing and securing a separate OAuth application would expand the MVP and duplicate credentials already managed by developers through `gh`.

## Decision

Use the installed `gh` executable as the only GitHub credential broker and network client in phase one.

- Use high-level commands when their JSON contract is sufficient.
- Use `gh api` REST/GraphQL for pagination, review threads, and atomic inline-review submission.
- Send and fixture an explicit supported GitHub API-version header for direct API calls.
- Always pass repository and host explicitly; do not depend on the process's current branch.
- Execute with argument arrays and context deadlines, never through a shell.
- Send structured write payloads using `gh api --input -` on stdin.
- Normalize outputs and failures inside one Go gateway.

## Consequences

### Positive

- Reviewrr does not acquire, refresh, store, or log GitHub tokens.
- Existing GitHub.com account and SSO behavior remains in `gh`.
- REST and GraphQL remain available without adding a second HTTP auth stack.

### Negative

- `gh` is an external prerequisite and its versions vary.
- CLI output, exit codes, rate limits, and API version changes require compatibility tests.
- GitHub Enterprise Server support cannot be assumed from GitHub.com tests.

## Guardrails

- Pin and enforce a minimum supported `gh` version.
- Capture versioned golden fixtures for every consumed JSON shape.
- Bound stdout/stderr and execution time.
- Categorize authentication, authorization, validation, rate-limit, timeout, cancellation, and malformed-output failures.
- Never expose a generic `RunGH(args)` method to React.

## Revisit when

- A hosted/team product requires webhooks, service accounts, or centralized synchronization.
- `gh` cannot provide a required stable endpoint or performance target.

## References

- [GitHub CLI manual](https://cli.github.com/manual/)
- [`gh pr list`](https://cli.github.com/manual/gh_pr_list)
- [`gh api`](https://cli.github.com/manual/gh_api)
- [Pull-request reviews REST API](https://docs.github.com/en/rest/pulls/reviews)
