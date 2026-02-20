#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/ops}"
mkdir -p "$OUT_DIR"

TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_DIR="$OUT_DIR/synthetic-$TS_SAFE"
mkdir -p "$RUN_DIR"

make_metrics_fixture() {
  local path="$1"
  local disconnect_probe_ok="$2"
  local disconnect_consec_fails="$3"
  local seq_refresh_fails="$4"
  local seq_end_fails="$5"
  local seq_missing="$6"
  local notif_regressions="$7"
  local notif_dupes="$8"
  local notif_last_error="$9"

  jq -n \
    --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg disconnectProbeOk "$disconnect_probe_ok" \
    --arg disconnectConsecFails "$disconnect_consec_fails" \
    --arg seqRefreshFails "$seq_refresh_fails" \
    --arg seqEndFails "$seq_end_fails" \
    --arg seqMissing "$seq_missing" \
    --arg notifRegressions "$notif_regressions" \
    --arg notifDupes "$notif_dupes" \
    --arg notifLastError "$notif_last_error" \
    '
    {
      generatedAtUtc: $ts,
      disconnectReconnect: {
        currentProbeOk: ($disconnectProbeOk == "true"),
        currentPrimaryTargetId: "sshTunnel",
        currentWarnings: [],
        sourceSoakSummary: "synthetic",
        latestSoakMaxConsecutiveProbeFails: ($disconnectConsecFails | tonumber),
        latestSoakRestartCount: 0,
        latestSoakProbeFailSamples: ($disconnectConsecFails | tonumber)
      },
      seqGapResync: {
        sourceSeqGapSummary: "synthetic",
        refreshLoopFailures: ($seqRefreshFails | tonumber),
        endRaceLoopFailures: ($seqEndFails | tonumber),
        missingAssistantIndexesCount: ($seqMissing | tonumber)
      },
      notificationIngestion: {
        latestChannelLastError: (if $notifLastError == "null" then null else $notifLastError end),
        latestLastInboundAt: null,
        latestLastOutboundAt: null,
        sourceSoakSummary: "synthetic",
        inboundTimestampRegressions: ($notifRegressions | tonumber),
        duplicateInboundEventTransitions: ($notifDupes | tonumber)
      }
    }
    ' > "$path"
}

HEALTHY_METRICS="$RUN_DIR/metrics-healthy.json"
DISCONNECT_METRICS="$RUN_DIR/metrics-disconnect-fault.json"
SEQ_GAP_METRICS="$RUN_DIR/metrics-seq-gap-fault.json"
NOTIFICATION_METRICS="$RUN_DIR/metrics-notification-fault.json"

make_metrics_fixture "$HEALTHY_METRICS" "true" "0" "0" "0" "0" "0" "0" "null"
make_metrics_fixture "$DISCONNECT_METRICS" "false" "4" "0" "0" "0" "0" "0" "null"
make_metrics_fixture "$SEQ_GAP_METRICS" "true" "0" "1" "0" "0" "0" "0" "null"
make_metrics_fixture "$NOTIFICATION_METRICS" "true" "0" "0" "0" "0" "1" "2" "ingest lag spike"

HEALTHY_ALERTS="$("$ROOT_DIR/scripts/openclaw/ops_alert_eval.sh" "$RUN_DIR" "$HEALTHY_METRICS")"
DISCONNECT_ALERTS="$("$ROOT_DIR/scripts/openclaw/ops_alert_eval.sh" "$RUN_DIR" "$DISCONNECT_METRICS")"
SEQ_GAP_ALERTS="$("$ROOT_DIR/scripts/openclaw/ops_alert_eval.sh" "$RUN_DIR" "$SEQ_GAP_METRICS")"
NOTIFICATION_ALERTS="$("$ROOT_DIR/scripts/openclaw/ops_alert_eval.sh" "$RUN_DIR" "$NOTIFICATION_METRICS")"

HEALTHY_ALL_OK="$(jq -r '([.alerts[] | select(.status != "ok")] | length) == 0' "$HEALTHY_ALERTS")"
DISCONNECT_TRIGGERED="$(jq -r '[.alerts[] | select(.id == "disconnect_reconnect_failure" and .status == "alert")] | length' "$DISCONNECT_ALERTS")"
SEQ_GAP_TRIGGERED="$(jq -r '[.alerts[] | select(.id == "seq_gap_resync_frequency" and .status == "alert")] | length' "$SEQ_GAP_ALERTS")"
NOTIFICATION_TRIGGERED="$(jq -r '[.alerts[] | select(.id == "notification_ingestion_anomaly" and .status == "alert")] | length' "$NOTIFICATION_ALERTS")"

SUMMARY_JSON="$RUN_DIR/synthetic-summary.json"
jq -n \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg healthyAllOk "$HEALTHY_ALL_OK" \
  --arg disconnectTriggered "$DISCONNECT_TRIGGERED" \
  --arg seqGapTriggered "$SEQ_GAP_TRIGGERED" \
  --arg notificationTriggered "$NOTIFICATION_TRIGGERED" \
  --arg healthyAlerts "$HEALTHY_ALERTS" \
  --arg disconnectAlerts "$DISCONNECT_ALERTS" \
  --arg seqGapAlerts "$SEQ_GAP_ALERTS" \
  --arg notificationAlerts "$NOTIFICATION_ALERTS" \
  '
  {
    generatedAtUtc: $ts,
    status: (
      if ($healthyAllOk == "true")
        and (($disconnectTriggered | tonumber) > 0)
        and (($seqGapTriggered | tonumber) > 0)
        and (($notificationTriggered | tonumber) > 0)
      then "passed"
      else "failed"
      end
    ),
    healthyAllOk: ($healthyAllOk == "true"),
    disconnectAlertTriggered: (($disconnectTriggered | tonumber) > 0),
    seqGapAlertTriggered: (($seqGapTriggered | tonumber) > 0),
    notificationAlertTriggered: (($notificationTriggered | tonumber) > 0),
    healthyAlertsArtifact: $healthyAlerts,
    disconnectAlertsArtifact: $disconnectAlerts,
    seqGapAlertsArtifact: $seqGapAlerts,
    notificationAlertsArtifact: $notificationAlerts
  }
  ' > "$SUMMARY_JSON"

echo "$SUMMARY_JSON"
