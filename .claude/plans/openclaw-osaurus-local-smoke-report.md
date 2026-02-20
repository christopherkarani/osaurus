# OpenClaw Osaurus Local Smoke Report

Date (UTC): 2026-02-20 19:46:03Z  
Repo: `/Users/chriskarani/CodingProjects/Jarvis/osaurus`  
Scope: WS-E / E-01 local gateway smoke validation

## Environment

- OpenClaw CLI: `2026.2.17`
- Gateway target: `ws://127.0.0.1:18789` via `sshTunnel`
- Session key used for chat verification: `agent:main:main`

## Checkpoints

| Checkpoint | Command(s) | Observed result | Status |
|---|---|---|---|
| Start gateway service | `openclaw gateway start --json` | `ok: true`, `result: "started"`, `service.loaded: true` | PASS |
| Reachable gateway connection | `openclaw gateway probe --json` | `ok: true`, `primaryTargetId: "sshTunnel"`, active target connect success | PASS |
| Chat run with tool activity | `openclaw agent --agent main --message 'Use one available tool, then return the final answer for 2+2.' --json` | Returned `status: "ok"` and assistant output confirming tool usage with final `2 + 2 = 4` | PASS |
| Tool event is recorded in gateway history | `openclaw gateway call chat.history --params '{"sessionKey":"agent:main:main","limit":5}' --json` | History includes assistant `toolCall` (`name: "session_status"`) and matching `toolResult` before final assistant text | PASS |
| Connected-clients presence metadata path | `openclaw gateway call system-event ... --json` then `openclaw gateway call system-presence --json` | Presence list includes emitted node row (`host: "osaurus-smoke"`, `mode: "osaurus"`, `deviceId`, `roles`, `scopes`) alongside gateway self row | PASS |
| Notification source freshness baseline | Repeated `openclaw gateway call channels.status --json` reads | Telegram account state stayed `running=true`, `mode=polling`, `lastInboundAt` stable (`null` -> `null`) with no startup flood signal | PASS |

## Evidence Highlights

### Gateway start and probe

`openclaw gateway start --json` returned:

```json
{
  "action": "start",
  "ok": true,
  "result": "started",
  "service": { "loaded": true }
}
```

Probe summary extraction returned:

```json
{
  "ok": true,
  "primaryTargetId": "sshTunnel",
  "warnings": [],
  "targetConnect": [
    { "id": "sshTunnel", "active": true, "connectOk": true, "connectError": null }
  ]
}
```

### Chat stream + tool call/result trace

Agent command returned `status: "ok"` with text:

```text
✅ Used `session_status` as the one tool.

**2 + 2 = 4**
```

`chat.history` captured the same run and included:

- user prompt: `Use one available tool, then return the final answer for 2+2.`
- assistant `toolCall`: `session_status`
- `toolResult` for that tool call
- final assistant text with `2 + 2 = 4`

### Presence row metadata

After emitting a smoke `system-event`, `system-presence` returned a node entry with:

- `host: "osaurus-smoke"`
- `mode: "osaurus"`
- `deviceId: "osaurus-smoke-node"`
- `roles: ["operator"]`
- `scopes: ["operator.admin"]`

This confirms the metadata path used by the connected-clients UI row.

## Notes

- Sandbox-local loopback/network operations required elevated execution in this environment (`EPERM` without escalation).  
- Multiple-gateway warning may appear when both ssh tunnel and direct remote target are reachable; the active target still connected successfully for the smoke checks.

## E-01 Exit Criteria Verdict

All local smoke runbook checkpoints passed without code workarounds. WS-E `E-01` is complete.
