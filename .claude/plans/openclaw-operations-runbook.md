# OpenClaw Operations Runbook

Date (UTC): 2026-02-20  
Repository: `/Users/chriskarani/CodingProjects/Jarvis/osaurus`

## Task Status

| Task ID | Status | Notes |
|---|---|---|
| `PR-OPS-01` | PASS | Monitoring + alert evaluator is implemented with fixed thresholds/windows and synthetic trigger proof. |
| `PR-OPS-02` | PASS | Restart, token-rotation, and incident-response run procedures are finalized with exact command workflows and expected outcomes. |

## PR-OPS-01 Monitoring and Alerting

### Monitoring Collection

Command:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
./scripts/openclaw/ops_metrics_collect.sh
```

Latest metrics artifact:

- `.claude/plans/artifacts/openclaw-production/ops/ops-metrics-20260220T230112Z.json`

### Alert Evaluation

Command:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
./scripts/openclaw/ops_alert_eval.sh .claude/plans/artifacts/openclaw-production/ops .claude/plans/artifacts/openclaw-production/ops/ops-metrics-20260220T230112Z.json
```

Latest live alerts artifact:

- `.claude/plans/artifacts/openclaw-production/ops/ops-alerts-20260220T230202Z-93856597.json`

### Alert Definitions (Thresholds + Windows)

1. `disconnect_reconnect_failure`
   - Trigger when:
     - current probe `ok=false`, or
     - latest soak `maxConsecutiveProbeFails >= 3`
   - Detection window: 15 minutes
   - Severity: high

2. `seq_gap_resync_frequency`
   - Trigger when:
     - `seqGapRefreshLoopFailures > 0`, or
     - `seqGapEndRaceLoopFailures > 0`, or
     - `missingAssistantIndexesCount > 0`
   - Detection window: 24 hours
   - Severity: high

3. `notification_ingestion_anomaly`
   - Trigger when:
     - `inboundTimestampRegressions > 0`, or
     - `duplicateInboundEventTransitions > 0`, or
     - `latestChannelLastError != null`
   - Detection window: 24 hours
   - Severity: medium

### Synthetic Trigger Proof

Command:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
./scripts/openclaw/ops_alert_synthetic.sh
```

Passing synthetic summary artifact:

- `.claude/plans/artifacts/openclaw-production/ops/synthetic-20260220T230145Z/synthetic-summary.json`

Recorded synthetic expectations:

- `healthyAllOk=true`
- `disconnectAlertTriggered=true`
- `seqGapAlertTriggered=true`
- `notificationAlertTriggered=true`

## PR-OPS-02 Operator Procedures

### Restart Procedure

Commands:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
openclaw gateway restart --json
openclaw gateway probe --json | jq '{ok,primaryTargetId,warnings:(.warnings|map(.code)),targetConnect:(.targets|map({id,active,connectOk:.connect.ok,connectError:.connect.error}))}'
```

Expected outcome:

- Restart command returns `ok=true` and `result="restarted"`.
- Probe returns `ok=true` and active target `connectOk=true`.

Mapped evidence:

- `.claude/plans/artifacts/openclaw-production/e2e/gateway-restart-20260220T212518Z.json`
- `.claude/plans/artifacts/openclaw-production/e2e/probe-post-restart-20260220T212518Z.json`

### Token Rotation / Auth Recovery Procedure

Commands:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
CONFIG_PATH="$HOME/.openclaw/openclaw.json"
REMOTE_URL="$(jq -r '.gateway.remote.url // empty' "$CONFIG_PATH")"
REMOTE_TOKEN="$(jq -r '.gateway.remote.token // empty' "$CONFIG_PATH")"

# failure injection: invalid token must be rejected
openclaw gateway call health --url "$REMOTE_URL" --token invalid-smoke-token --json

# corrected token path: should recover
openclaw gateway call health --url "$REMOTE_URL" --token "$REMOTE_TOKEN" --json
openclaw gateway probe --json | jq '{ok,primaryTargetId,warnings:(.warnings|map(.code))}'
```

Expected outcome:

- Invalid-token call exits non-zero with explicit unauthorized message.
- Corrected-token call returns `ok=true`.
- Probe remains `ok=true` after correction.

Mapped evidence:

- `.claude/plans/artifacts/openclaw-production/e2e/health-invalid-token-20260220T213213Z.stderr.log`
- `.claude/plans/artifacts/openclaw-production/e2e/health-valid-token-20260220T213213Z.json`
- `.claude/plans/artifacts/openclaw-production/e2e/probe-post-auth-recovery-20260220T213213Z.json`

### Incident Response Procedure

Commands:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
METRICS_JSON="$(./scripts/openclaw/ops_metrics_collect.sh)"
ALERTS_JSON="$(./scripts/openclaw/ops_alert_eval.sh .claude/plans/artifacts/openclaw-production/ops "$METRICS_JSON")"
jq '.alerts' "$ALERTS_JSON"
```

Decision matrix:

1. If `disconnect_reconnect_failure` is `alert`:
   - Execute restart procedure.
   - Re-run metrics + alerts.
2. If `seq_gap_resync_frequency` is `alert`:
   - Execute: `./scripts/openclaw/e2e_seq_gap_resync.sh 5 10`
   - Re-run metrics + alerts.
3. If `notification_ingestion_anomaly` is `alert`:
   - Execute: `./scripts/openclaw/soak_stats.sh <latest-soak-run-dir>`
   - Investigate ingress regressions/duplicates in summary and `events.ndjson`.

Expected outcome:

- Healthy systems return all three alerts with `status="ok"`.
- Synthetic checks can force each alert path for drill validation.

Mapped evidence:

- `.claude/plans/artifacts/openclaw-production/ops/ops-metrics-20260220T230112Z.json`
- `.claude/plans/artifacts/openclaw-production/ops/ops-alerts-20260220T230202Z-93856597.json`
- `.claude/plans/artifacts/openclaw-production/ops/synthetic-20260220T230145Z/synthetic-summary.json`
