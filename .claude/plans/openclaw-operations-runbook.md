# OpenClaw Operations Runbook

Date (UTC): 2026-02-20  
Repository: `/Users/chriskarani/CodingProjects/Jarvis/osaurus`

## Task Status

| Task ID | Status | Notes |
|---|---|---|
| `PR-OPS-01` | PASS | Monitoring + alert evaluator is implemented with fixed thresholds/windows and synthetic trigger proof. |
| `PR-OPS-02` | PENDING | Operator run procedures (restart/token rotation/incident response) pending finalization. |

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
