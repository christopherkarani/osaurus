#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/ops}"
mkdir -p "$OUT_DIR"

TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
METRICS_JSON="$OUT_DIR/ops-metrics-$TS_SAFE.json"

E2E_DIR="$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e"
SOAK_DIR="$ROOT_DIR/.claude/plans/artifacts/openclaw-production/soak"

LATEST_SEQ_GAP_SUMMARY="$(ls -1t "$E2E_DIR"/e2e-seq-gap-resync-summary-*.json 2>/dev/null | head -n 1 || true)"
LATEST_SOAK_SUMMARY="$(find "$SOAK_DIR" -maxdepth 2 -name summary.json -print 2>/dev/null | xargs ls -1t 2>/dev/null | head -n 1 || true)"

probe_tmp="$OUT_DIR/probe-$TS_SAFE.json"
probe_err="$OUT_DIR/probe-$TS_SAFE.err.log"
channels_tmp="$OUT_DIR/channels-$TS_SAFE.json"
channels_err="$OUT_DIR/channels-$TS_SAFE.err.log"

if ! openclaw gateway probe --json > "$probe_tmp" 2> "$probe_err"; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg reason "gateway probe failed while collecting ops metrics" \
    --arg stderr "$(sed -n '1,8p' "$probe_err" | tr '\n' ' ')" \
    '{generatedAtUtc:$ts, status:"failed", reason:$reason, stderr:$stderr}' > "$METRICS_JSON"
  echo "$METRICS_JSON"
  exit 1
fi

if ! openclaw gateway call channels.status --json > "$channels_tmp" 2> "$channels_err"; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg reason "channels.status failed while collecting ops metrics" \
    --arg stderr "$(sed -n '1,8p' "$channels_err" | tr '\n' ' ')" \
    '{generatedAtUtc:$ts, status:"failed", reason:$reason, stderr:$stderr}' > "$METRICS_JSON"
  echo "$METRICS_JSON"
  exit 1
fi

CURRENT_PROBE_OK="$(jq -r '.ok // false' "$probe_tmp")"
CURRENT_PRIMARY_TARGET_ID="$(jq -r '.primaryTargetId // "null"' "$probe_tmp")"
CURRENT_WARNINGS_JSON="$(jq -c '(.warnings // []) | map(.code // .message // "unknown")' "$probe_tmp")"
CURRENT_LAST_ERROR="$(jq -r '.channelAccounts.telegram[0].lastError // "null"' "$channels_tmp")"
CURRENT_LAST_INBOUND_AT="$(jq -r '.channelAccounts.telegram[0].lastInboundAt // "null"' "$channels_tmp")"
CURRENT_LAST_OUTBOUND_AT="$(jq -r '.channelAccounts.telegram[0].lastOutboundAt // "null"' "$channels_tmp")"

SOAK_MAX_CONSEC_FAILS=0
SOAK_RESTART_COUNT=0
SOAK_PROBE_FAIL_SAMPLES=0
SOAK_INBOUND_REGRESSIONS=1
SOAK_DUPLICATE_TRANSITIONS=1
if [[ -n "$LATEST_SOAK_SUMMARY" && -f "$LATEST_SOAK_SUMMARY" ]]; then
  SOAK_MAX_CONSEC_FAILS="$(jq -r '.maxConsecutiveProbeFails // 0' "$LATEST_SOAK_SUMMARY")"
  SOAK_RESTART_COUNT="$(jq -r '.restartCount // 0' "$LATEST_SOAK_SUMMARY")"
  SOAK_PROBE_FAIL_SAMPLES="$(jq -r '.probeFailSamples // 0' "$LATEST_SOAK_SUMMARY")"
  SOAK_INBOUND_REGRESSIONS="$(jq -r '.inboundTimestampRegressions // 0' "$LATEST_SOAK_SUMMARY")"
  SOAK_DUPLICATE_TRANSITIONS="$(jq -r '.duplicateInboundEventTransitions // 0' "$LATEST_SOAK_SUMMARY")"
fi

SEQ_GAP_REFRESH_FAILS=1
SEQ_GAP_END_RACE_FAILS=1
SEQ_GAP_MISSING_INDEXES=1
if [[ -n "$LATEST_SEQ_GAP_SUMMARY" && -f "$LATEST_SEQ_GAP_SUMMARY" ]]; then
  SEQ_GAP_REFRESH_FAILS="$(jq -r '.seqGapRefreshLoopFailures // 0' "$LATEST_SEQ_GAP_SUMMARY")"
  SEQ_GAP_END_RACE_FAILS="$(jq -r '.seqGapEndRaceLoopFailures // 0' "$LATEST_SEQ_GAP_SUMMARY")"
  SEQ_GAP_MISSING_INDEXES="$(jq -r '.missingAssistantIndexes | length // 0' "$LATEST_SEQ_GAP_SUMMARY")"
fi

jq -n \
  --arg ts "$TS_UTC" \
  --arg currentProbeOk "$CURRENT_PROBE_OK" \
  --arg currentPrimaryTargetId "$CURRENT_PRIMARY_TARGET_ID" \
  --argjson currentWarnings "$CURRENT_WARNINGS_JSON" \
  --arg latestSoakSummary "${LATEST_SOAK_SUMMARY:-}" \
  --arg latestSoakMaxConsecutiveProbeFails "$SOAK_MAX_CONSEC_FAILS" \
  --arg latestSoakRestartCount "$SOAK_RESTART_COUNT" \
  --arg latestSoakProbeFailSamples "$SOAK_PROBE_FAIL_SAMPLES" \
  --arg latestSeqGapSummary "${LATEST_SEQ_GAP_SUMMARY:-}" \
  --arg seqGapRefreshFailures "$SEQ_GAP_REFRESH_FAILS" \
  --arg seqGapEndRaceFailures "$SEQ_GAP_END_RACE_FAILS" \
  --arg seqGapMissingAssistantIndexes "$SEQ_GAP_MISSING_INDEXES" \
  --arg latestChannelLastError "$CURRENT_LAST_ERROR" \
  --arg latestLastInboundAt "$CURRENT_LAST_INBOUND_AT" \
  --arg latestLastOutboundAt "$CURRENT_LAST_OUTBOUND_AT" \
  --arg inboundRegressions "$SOAK_INBOUND_REGRESSIONS" \
  --arg duplicateTransitions "$SOAK_DUPLICATE_TRANSITIONS" \
  '
  {
    generatedAtUtc: $ts,
    disconnectReconnect: {
      currentProbeOk: ($currentProbeOk == "true"),
      currentPrimaryTargetId: (if $currentPrimaryTargetId == "null" then null else $currentPrimaryTargetId end),
      currentWarnings: $currentWarnings,
      sourceSoakSummary: (if ($latestSoakSummary | length) == 0 then null else $latestSoakSummary end),
      latestSoakMaxConsecutiveProbeFails: ($latestSoakMaxConsecutiveProbeFails | tonumber),
      latestSoakRestartCount: ($latestSoakRestartCount | tonumber),
      latestSoakProbeFailSamples: ($latestSoakProbeFailSamples | tonumber)
    },
    seqGapResync: {
      sourceSeqGapSummary: (if ($latestSeqGapSummary | length) == 0 then null else $latestSeqGapSummary end),
      refreshLoopFailures: ($seqGapRefreshFailures | tonumber),
      endRaceLoopFailures: ($seqGapEndRaceFailures | tonumber),
      missingAssistantIndexesCount: ($seqGapMissingAssistantIndexes | tonumber)
    },
    notificationIngestion: {
      latestChannelLastError: (if $latestChannelLastError == "null" then null else $latestChannelLastError end),
      latestLastInboundAt: (if $latestLastInboundAt == "null" then null else $latestLastInboundAt end),
      latestLastOutboundAt: (if $latestLastOutboundAt == "null" then null else $latestLastOutboundAt end),
      sourceSoakSummary: (if ($latestSoakSummary | length) == 0 then null else $latestSoakSummary end),
      inboundTimestampRegressions: ($inboundRegressions | tonumber),
      duplicateInboundEventTransitions: ($duplicateTransitions | tonumber)
    }
  }
  ' > "$METRICS_JSON"

echo "$METRICS_JSON"
