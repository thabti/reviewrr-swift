# ADR-0004: Integrate ACP through a review-only Go client boundary

- **Status:** accepted for MVP planning
- **Date:** 2026-09-05

## Context

Reviewrr should work with ACP-compatible coding agents rather than embed a model-provider SDK. The chosen desktop backend is Go. ACP has an official protocol and official SDKs for several languages, while Go implementations are community maintained.

The product explicitly excludes code modification. ACP agents, however, are normally capable coding tools and may request filesystem or terminal access.

## Decision

- Implement Reviewrr as an ACP v1 client in the Go host.
- Begin with a pinned `coder/acp-go-sdk` version behind a Reviewrr-owned adapter.
- Detect and support Kiro (`kiro-cli acp`) and OpenCode (`opencode acp`) first; launch one reviewer-selected agent/model at a time over stdio.
- Permit custom ACP commands as experimental integrations with explicit compatibility diagnostics.
- Create sessions against a disposable, revision-scoped review-context directory rather than the source worktree.
- Advertise only client capabilities that Reviewrr implements.
- Allow canonicalized reads only inside the review-context root.
- Deny filesystem writes and terminal creation/execution.
- Normalize session updates before emitting them to React.
- Treat all AI output as advisory; ACP has no path to the GitHub submission service.
- Render AI output only in the right panel; navigation to code is allowed, but inline AI decorations are not.

## Consequences

### Positive

- Agent choice is decoupled from the UI and GitHub workflow.
- Repository mutation is not required for explanations or review findings.
- Permission decisions and session state have one native owner.
- The SDK can be upgraded or replaced without changing product-facing contracts.

### Negative

- The community SDK may lag protocol changes.
- Materializing review context adds disk and lifecycle complexity.
- Protocol permission denial does not sandbox a subprocess at the OS level.
- Kiro, OpenCode, and custom agents may interpret review prompts and optional capabilities differently.

## Security statement

Reviewrr must describe configured ACP agents as trusted local processes. The disposable working directory and denied ACP permissions reduce accidental mutation; they do not protect against a malicious executable running with the user's account privileges.

## Revisit when

- An official Go SDK is released.
- ACP v2 stabilizes and provides capabilities required by Reviewrr.
- The product needs an enforceable OS sandbox for third-party agents.

## References

- [ACP v1 protocol overview](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/overview.mdx)
- [ACP community libraries](https://agentclientprotocol.com/libraries/community)
- [`coder/acp-go-sdk`](https://github.com/coder/acp-go-sdk)
- [Kiro ACP documentation](https://kiro.dev/docs/cli/acp/)
- [OpenCode ACP documentation](https://opencode.ai/docs/acp/)
