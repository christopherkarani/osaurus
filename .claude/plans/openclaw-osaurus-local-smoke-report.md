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

---

## WS-E / E-02 Failure-Mode Smoke Checks

Date (UTC): 2026-02-20  
Scope: operator-visible recovery paths and deterministic resync behavior

| Scenario | Command(s) | Observed result | Status |
|---|---|---|---|
| Gateway restart while connected | `openclaw gateway restart --json` then `openclaw gateway probe --json` | Restart returned `ok: true`, and immediate probe returned `ok: true` with active successful target connection | PASS |
| Auth/token failure path | `openclaw gateway call health --token invalid-smoke-token --json` | Command failed with `unauthorized: device token mismatch` (exit `1`), then normal probe recovered to `ok: true` | PASS |
| Seq-gap/resync path determinism (active run + end-race windows) | `swift test --filter streamRunIntoTurn_sequenceGapTriggersConnectionRefresh` (10x loop), `swift test --filter streamRunIntoTurn_gapThenImmediateEnd_isDeterministicAcrossIterations` (10x loop) | Both loops passed `10/10`, validating deterministic refresh/resync behavior across ordering windows | PASS |

## E-02 Evidence Highlights

### Restart recovery

`openclaw gateway restart --json`:

```json
{
  "action": "restart",
  "ok": true,
  "result": "restarted"
}
```

Follow-up probe summary:

```json
{
  "ok": true,
  "primaryTargetId": "sshTunnel",
  "targetConnect": [
    { "id": "sshTunnel", "connectOk": true },
    { "id": "configRemote", "connectOk": true }
  ]
}
```

### Auth/token rejection + recovery

Bad-token call result:

```text
exit=1
gateway connect failed: Error: unauthorized: device token mismatch (rotate/reissue device token)
Gateway call failed: Error: gateway closed (1008): unauthorized: device token mismatch (rotate/reissue device token)
```

Post-failure probe remained healthy (`ok: true`), confirming no stuck disconnected state after rejected auth.

### Seq-gap/resync deterministic guard

Repeated race-sensitive checks:

```text
iterations_passed=10/10  (streamRunIntoTurn_sequenceGapTriggersConnectionRefresh)
iterations_passed=10/10  (streamRunIntoTurn_gapThenImmediateEnd_isDeterministicAcrossIterations)
```

These runs cover both active-run seq-gap refresh and immediate lifecycle-end interleaving, with no flake observed.

## E-02 Exit Criteria Verdict

All failure-mode scenarios passed with deterministic outcomes and verified recovery. WS-E `E-02` is complete.
