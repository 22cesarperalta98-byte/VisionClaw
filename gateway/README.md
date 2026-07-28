# VisionClaw Gateway (hosted action agent, beta)

Run VisionClaw's action agent in the cloud so users don't have to install and
host a local agent on their own machine. The gateway speaks the exact protocol
the iOS/Android apps already use (OpenAI-compatible `/v1/chat/completions` +
the WebSocket event channel), and drives
[Anthropic Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview)
behind it: one durable session per user, a mounted long-term memory store, a
per-user credential vault, and a hosted sandbox for tool execution (web search,
files, bash) — no sandbox infrastructure to operate.

```
iOS / Android app  (unchanged)
  ├── POST /v1/chat/completions ─┐
  └── ws:// events ◄─────────┐   │
                             │   ▼
                        this gateway
                             │
                             ▼
              Anthropic Managed Agents (beta)
                1 shared agent config + environment
                1 session + memory store + vault per user
```

## Quick start

```bash
cd gateway
npm install
cp .env.example .env        # set ANTHROPIC_API_KEY and GATEWAY_TOKENS
npm run provision           # creates the shared environment + agent (once)
npm run dev                 # gateway on :8788
```

`GATEWAY_TOKENS` maps client tokens to user ids, e.g.
`GATEWAY_TOKENS="s3cret-a:alice,s3cret-b:bob"`. Each user's session, memory
store, and vault are provisioned lazily on first request (or eagerly via
`npm run provision -- alice bob`).

**App setup** (Settings → Agent): host = `http://<gateway-host>`, port = `8788`,
gateway token = the user's token. Local self-hosted mode keeps working — this
is an alternative backend, not a replacement.

## Endpoints

| Route | Purpose |
|---|---|
| `GET /v1/chat/completions` | reachability probe (the app's connection check) |
| `POST /v1/chat/completions` | one agent turn. Sends only the newest user message — the managed session owns durable history (server-side compaction included). With `"stream": true`, responds with OpenAI-style SSE chunks generated live from the agent's output |
| `POST /context` | queue voice-session context (`{"context": "..."}`); it attaches to the user's next turn as a system-level event (the API rejects standalone system messages) |
| `GET /tasks?limit=N` | recent delegated tasks + results, for the app's Recent Tasks view |
| `ws://host:port` | event channel; same protocol-v3 handshake as the local gateway. Late task results arrive as `heartbeat` events, scheduled-task summaries as `cron` events |

## Two-speed turns

`POST /v1/chat/completions` waits up to `QUICK_ANSWER_TIMEOUT_MS` (default 30s).
If the agent is still working, the call returns an acknowledgement immediately
and the final result is pushed over the WebSocket when it lands — the voice
layer never blocks on a long task. The same budget applies to streaming
requests: past it, the stream closes with an acknowledgement chunk and the
final text arrives as a proactive event.

## Notes and roadmap

- Managed Agents is an Anthropic **beta**; quotas apply (notably scheduled
  deployments are capped per organization).
- Memory is a per-user mounted store of small text files, versioned and
  redactable server-side.
- Roadmap: connected-app OAuth flows storing credentials into per-user vaults,
  scheduled reminders via deployments, tool-permission prompts surfaced as
  spoken confirmations, Android parity for the backend switcher.
