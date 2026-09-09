# Testing AI providers

This guide verifies that Reviewrr reaches the selected provider, accepts its response, renders a real
analysis, and sends Ask questions through the same provider.

## Point the app at a provider

Open **Settings > AI provider**. Configuration is saved in `reviewrr.settings` in this browser's
`localStorage`.

| Selection | Configuration |
| --- | --- |
| Heuristic mode | Select **Heuristic mode**. It makes no model request. |
| Anthropic | Select **Anthropic**, enter an Anthropic key, and choose a model. The browser calls Anthropic directly. |
| OpenAI | Select **OpenAI**, enter an OpenAI key, model, and supported effort. The browser calls OpenAI directly. |
| OpenRouter | Select **OpenRouter**, enter its key and model. Leave Base URL blank for the default endpoint. |
| OpenAI-compatible | Select **OpenAI-compatible**, enter the endpoint root and model, plus a key when the endpoint requires one. |
| Claude Agent SDK | Select **Claude Agent SDK**, model, and effort. The local API must report `claudeAgent: true`. |
| Codex worker | Select **Codex worker**, model, and effort. The local API must report `codex: true`. |

For a deterministic browser automation setup, preserve the existing state and replace only the selected
provider configuration:

```js
const persisted = JSON.parse(localStorage.getItem('reviewrr.settings'))
persisted.state.aiProvider = 'codex'
persisted.state.aiModel = 'gpt-5.6-sol'
persisted.state.providers.codex = {
  ...persisted.state.providers.codex,
  model: 'gpt-5.6-sol',
  effort: 'low',
}
localStorage.setItem('reviewrr.settings', JSON.stringify(persisted))
localStorage.removeItem('reviewrr.analysis')
location.reload()
```

Clearing `reviewrr.analysis` forces a fresh analysis without removing the GitHub token or review
drafts.

## Check the local server

Check availability first:

```bash
curl -sS http://localhost:8787/api/health
```

A usable Codex setup contains `"ok":true` and `"codex":true`. A usable Claude Agent setup contains
`"claudeAgent":true`.

Check non-streaming Codex:

```bash
curl -sS -X POST http://localhost:8787/api/ai/agent \
  -H 'content-type: application/json' \
  --data '{"provider":"codex","model":"gpt-5.6-sol","effort":"low","messages":[{"role":"user","content":"Reply with exactly: AGENT_OK"}]}'
```

Expected body:

```json
{"text":"AGENT_OK\n"}
```

Check streaming Codex:

```bash
curl -N -X POST http://localhost:8787/api/ai/agent/stream \
  -H 'content-type: application/json' \
  --data '{"provider":"codex","model":"gpt-5.6-sol","effort":"low","messages":[{"role":"user","content":"Reply with exactly: AGENT_OK"}]}'
```

The stream sends output in `data:` records and finishes with an `event: done` record containing a JSON
object with `text`.

Check Claude Agent SDK by changing the provider and model:

```bash
curl -sS -X POST http://localhost:8787/api/ai/agent \
  -H 'content-type: application/json' \
  --data '{"provider":"claude-agent","model":"claude-sonnet-5","effort":"low","messages":[{"role":"user","content":"Reply with exactly: AGENT_OK"}]}'
```

Use `/api/ai/agent/stream` instead of `/api/ai/agent` for its SSE check.

The server proxy can check server-held API keys independently of browser providers:

```bash
curl -sS -X POST http://localhost:8787/api/ai/proxy \
  -H 'content-type: application/json' \
  --data '{"provider":"openai","model":"gpt-5.6","system":"Reply exactly as requested.","messages":[{"role":"user","content":"Reply with exactly: PROXY_OK"}],"json":false,"maxTokens":32}'
```

Replace `openai` with `anthropic` and choose a configured Anthropic model to test that server key.
Browser-selected Anthropic, OpenAI, OpenRouter, and OpenAI-compatible providers do not use this proxy.

## Check Settings diagnostics

Select **Test** in the AI provider card. Server providers use SSE. A healthy result shows:

- `Connected`;
- the provider and exact model;
- latency in milliseconds;
- the first reply line, normally `SETTINGS_OK`; and
- token count only when the provider response includes usage metadata.

The current agent endpoint does not report usage, so Codex and Claude Agent omit the token row.

## Verify a real analysis and Ask

1. Clear only `reviewrr.analysis`.
2. Open a live pull request, such as
   `http://localhost:5173/facebook/react/pull/28000`.
3. In browser network tools, confirm `GET /api/health`, then
   `POST /api/ai/agent` with a 200 response.
4. Wait for **Reading order** and at least one summary. The overview must discuss the supplied PR, not
   say `AI unavailable` or identify heuristic fallback.
5. Inspect `reviewrr.analysis`. The PR entry must contain non-empty `layers` and `summaries`.
   Codex currently records `provider: "openai"` because the frozen analysis contract maps the Codex
   server worker to its OpenAI family.
6. Open **Ask** and send: `What does this change and what should I review first?`
7. Confirm a second `POST /api/ai/agent` and a specific answer grounded in the diff.
8. Check browser errors. Vite connection and React DevTools notices are expected in development;
   runtime exceptions are not.

The S32 verification of `facebook/react#28000` produced one layer and one summary. Analysis took
21,460 ms. Ask took 9,239 ms and began: "This only modernizes one internal React Refresh test;
production behavior is unchanged."

## Failure modes and meanings

These results were reproduced against the local server during S32:

| Result | Meaning and action |
| --- | --- |
| HTTP 400, `effort must be "low", "medium", "high", "xhigh", or "max"` | The agent request omitted or sent an invalid effort. Current client adapters always send a valid value and fall back to `medium`. |
| HTTP 501, `Claude Agent SDK requires ANTHROPIC_API_KEY` | The Claude worker cannot start because the server lacks its required key. Configure the server, restart it outside this test flow, and confirm `claudeAgent: true`. |
| `SSE error` in Settings | The stream connected, then the worker failed. The current server SSE error event includes its message but not a numeric HTTP status. |
| `Local AI worker 502` or `AI provider request failed` | The worker started but the provider process failed. Re-run the small curl probe and inspect server-side diagnostics. |
| `the model response was not valid JSON` in an analysis overview | The model response could not be parsed. Reviewrr then renders heuristic fallback with the failure reason. Outer prose and Markdown fences are accepted when they contain one valid JSON object. |
| `the model returned no layers` | JSON parsing succeeded, but the required analysis structure was empty. Reviewrr uses heuristic fallback. |
| Analysis falls back at 90 seconds | `src/lib/ai/analyze.ts` still owns a 90-second browser abort, while the server default is 120 seconds. The analysis orchestrator must adopt provider streaming and a timeout longer than the server worker limit. |

A test harness can also invalidate evidence by sharing one browser session across workers. S32's
default session was navigated to `/demo` by another worker during the first run, so final evidence used
an isolated `s32` session with the same saved profile settings.
