# OpenClaw Production Soak Report

Date (UTC): 2026-02-20  
Repository: `/Users/chriskarani/CodingProjects/Jarvis/osaurus`  
Scope: `PR-SOAK-01` and `PR-SOAK-02`

## Task Status

| Task ID | Status | Notes |
|---|---|---|
| `PR-SOAK-01` | PASS | Soak harness and stats scripts are implemented, executable, and validated with a live shakedown run. |
| `PR-SOAK-02` | PENDING | 24h minimum soak execution and anomaly analysis report pending. |

## PR-SOAK-01: Harness + Evidence Pipeline

### Added Scripts

- `scripts/openclaw/soak_harness.sh`
  - Periodic live traffic generation (`openclaw agent`)
  - Periodic gateway restarts
  - Periodic safe network-blip simulation (`kill -TERM` on discovered `sshTunnel` PID when present)
  - Periodic probe + `channels.status` sampling
  - Artifact persistence (`events.ndjson`, `probe.ndjson`, `channels.ndjson`, `traffic.ndjson`)
  - End-of-run summary generation via `soak_stats.sh`

- `scripts/openclaw/soak_stats.sh`
  - Computes probe health ratios and max consecutive probe failures
  - Counts restart/blip/traffic success-failure totals
  - Computes inbound timestamp regression and duplicate-transition signals
  - Emits machine-readable summary JSON

### Validation Command

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
./scripts/openclaw/soak_harness.sh 240 90 70 15 30
```

### Shakedown Evidence

- `run_id=soak-20260220T223929Z`
- `run_dir=/Users/chriskarani/CodingProjects/Jarvis/osaurus/.claude/plans/artifacts/openclaw-production/soak/soak-20260220T223929Z`
- `summary_json=/Users/chriskarani/CodingProjects/Jarvis/osaurus/.claude/plans/artifacts/openclaw-production/soak/soak-20260220T223929Z/summary.json`

Summary fields:

- `probeSamples=9`, `probeOkSamples=9`, `probeFailSamples=0`
- `maxConsecutiveProbeFails=0`, `potentialStuckState=false`
- `restartCount=2`
- `networkBlipCount=2`
- `trafficOkCount=3`, `trafficFailCount=2`
- `inboundTimestampRegressions=0`
- `duplicateInboundEventTransitions=0`

### Notes from Shakedown

- Two traffic sends failed during the accelerated run window; these are retained as anomaly examples for PR-SOAK-02 analysis.
- Both simulated blips recorded as failed PID kills (stale tunnel PID), but probe health remained stable and no stuck-state proxy condition triggered.

## PR-SOAK-02: Required Full-Duration Run (Pending)

Required acceptance gates remain:

1. Continuous soak runtime >= 24h (target 48h).
2. Periodic restart and network-blip events active during run.
3. Evidence-backed anomaly analysis with explicit PASS/FAIL for:
   - stuck-state proxy
   - unread-drift proxy
   - duplicate-notification proxy

Planned execution command template:

```bash
cd /Users/chriskarani/CodingProjects/Jarvis/osaurus
./scripts/openclaw/soak_harness.sh 172800 3600 2700 30 120
```
