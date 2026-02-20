#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/ops}"
METRICS_JSON="${2:-}"
mkdir -p "$OUT_DIR"

if [[ -z "$METRICS_JSON" ]]; then
  METRICS_JSON="$("$ROOT_DIR/scripts/openclaw/ops_metrics_collect.sh" "$OUT_DIR")"
fi

if [[ ! -f "$METRICS_JSON" ]]; then
  echo "metrics file not found: $METRICS_JSON" >&2
  exit 66
fi

TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')-$(uuidgen | cut -d- -f1)"
ALERTS_JSON="$OUT_DIR/ops-alerts-$TS_SAFE.json"

DISCONNECT_MAX_CONSEC_FAILS=3
DISCONNECT_WINDOW_MINUTES=15
SEQ_GAP_FAIL_WINDOW_HOURS=24
NOTIFICATION_ANOMALY_WINDOW_HOURS=24

CURRENT_PROBE_OK="$(jq -r '.disconnectReconnect.currentProbeOk // false' "$METRICS_JSON")"
MAX_CONSEC_FAILS="$(jq -r '.disconnectReconnect.latestSoakMaxConsecutiveProbeFails // 0' "$METRICS_JSON")"
SEQ_REFRESH_FAILS="$(jq -r '.seqGapResync.refreshLoopFailures // 1' "$METRICS_JSON")"
SEQ_END_FAILS="$(jq -r '.seqGapResync.endRaceLoopFailures // 1' "$METRICS_JSON")"
SEQ_MISSING="$(jq -r '.seqGapResync.missingAssistantIndexesCount // 1' "$METRICS_JSON")"
NOTIF_REGRESSIONS="$(jq -r '.notificationIngestion.inboundTimestampRegressions // 1' "$METRICS_JSON")"
NOTIF_DUPES="$(jq -r '.notificationIngestion.duplicateInboundEventTransitions // 1' "$METRICS_JSON")"
NOTIF_LAST_ERROR="$(jq -r '.notificationIngestion.latestChannelLastError // "null"' "$METRICS_JSON")"

disconnect_status="ok"
disconnect_reason="disconnect/reconnect health is within threshold"
if [[ "$CURRENT_PROBE_OK" != "true" || "$MAX_CONSEC_FAILS" -ge "$DISCONNECT_MAX_CONSEC_FAILS" ]]; then
  disconnect_status="alert"
  disconnect_reason="probe health failed or max consecutive failures exceeded threshold"
fi

seq_gap_status="ok"
seq_gap_reason="seq-gap/resync checks are stable"
if [[ "$SEQ_REFRESH_FAILS" -gt 0 || "$SEQ_END_FAILS" -gt 0 || "$SEQ_MISSING" -gt 0 ]]; then
  seq_gap_status="alert"
  seq_gap_reason="seq-gap/resync failures or missing assistant indexes detected"
fi

notification_status="ok"
notification_reason="notification ingestion signals are stable"
if [[ "$NOTIF_REGRESSIONS" -gt 0 || "$NOTIF_DUPES" -gt 0 || "$NOTIF_LAST_ERROR" != "null" ]]; then
  notification_status="alert"
  notification_reason="notification ingestion anomaly signals detected"
fi

jq -n \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg metrics "$METRICS_JSON" \
  --arg disconnectStatus "$disconnect_status" \
  --arg disconnectReason "$disconnect_reason" \
  --arg disconnectMaxConsecutiveFails "$DISCONNECT_MAX_CONSEC_FAILS" \
  --arg disconnectWindowMinutes "$DISCONNECT_WINDOW_MINUTES" \
  --arg seqGapStatus "$seq_gap_status" \
  --arg seqGapReason "$seq_gap_reason" \
  --arg seqGapWindowHours "$SEQ_GAP_FAIL_WINDOW_HOURS" \
  --arg notificationStatus "$notification_status" \
  --arg notificationReason "$notification_reason" \
  --arg notificationWindowHours "$NOTIFICATION_ANOMALY_WINDOW_HOURS" \
  --arg currentProbeOk "$CURRENT_PROBE_OK" \
  --arg maxConsecFails "$MAX_CONSEC_FAILS" \
  --arg seqRefreshFails "$SEQ_REFRESH_FAILS" \
  --arg seqEndFails "$SEQ_END_FAILS" \
  --arg seqMissing "$SEQ_MISSING" \
  --arg notifRegressions "$NOTIF_REGRESSIONS" \
  --arg notifDupes "$NOTIF_DUPES" \
  --arg notifLastError "$NOTIF_LAST_ERROR" \
  '
  {
    generatedAtUtc: $ts,
    metricsArtifact: $metrics,
    thresholds: {
      disconnectReconnect: {
        maxConsecutiveProbeFails: ($disconnectMaxConsecutiveFails | tonumber),
        detectionWindowMinutes: ($disconnectWindowMinutes | tonumber)
      },
      seqGapResync: {
        maxFailureCount: 0,
        detectionWindowHours: ($seqGapWindowHours | tonumber)
      },
      notificationIngestion: {
        maxInboundTimestampRegressions: 0,
        maxDuplicateInboundEventTransitions: 0,
        detectionWindowHours: ($notificationWindowHours | tonumber)
      }
    },
    alerts: [
      {
        id: "disconnect_reconnect_failure",
        status: $disconnectStatus,
        severity: (if $disconnectStatus == "alert" then "high" else "none" end),
        reason: $disconnectReason,
        metrics: {
          currentProbeOk: ($currentProbeOk == "true"),
          maxConsecutiveProbeFails: ($maxConsecFails | tonumber)
        }
      },
      {
        id: "seq_gap_resync_frequency",
        status: $seqGapStatus,
        severity: (if $seqGapStatus == "alert" then "high" else "none" end),
        reason: $seqGapReason,
        metrics: {
          refreshLoopFailures: ($seqRefreshFails | tonumber),
          endRaceLoopFailures: ($seqEndFails | tonumber),
          missingAssistantIndexesCount: ($seqMissing | tonumber)
        }
      },
      {
        id: "notification_ingestion_anomaly",
        status: $notificationStatus,
        severity: (if $notificationStatus == "alert" then "medium" else "none" end),
        reason: $notificationReason,
        metrics: {
          inboundTimestampRegressions: ($notifRegressions | tonumber),
          duplicateInboundEventTransitions: ($notifDupes | tonumber),
          latestChannelLastError: (if $notifLastError == "null" then null else $notifLastError end)
        }
      }
    ]
  }
  ' > "$ALERTS_JSON"

echo "$ALERTS_JSON"
