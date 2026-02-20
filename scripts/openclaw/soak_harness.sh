#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: $0 <duration-seconds> [restart-interval-seconds] [blip-interval-seconds] [sample-interval-seconds] [traffic-interval-seconds] [out-dir]" >&2
  exit 64
fi

DURATION_SECONDS="$1"
RESTART_INTERVAL_SECONDS="${2:-1800}"
BLIP_INTERVAL_SECONDS="${3:-1200}"
SAMPLE_INTERVAL_SECONDS="${4:-30}"
TRAFFIC_INTERVAL_SECONDS="${5:-90}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${6:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/soak}"
RUN_ID="soak-$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_DIR="$OUT_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

META_JSON="$RUN_DIR/meta.json"
EVENT_LOG="$RUN_DIR/events.ndjson"
PROBE_LOG="$RUN_DIR/probe.ndjson"
CHANNELS_LOG="$RUN_DIR/channels.ndjson"
TRAFFIC_LOG="$RUN_DIR/traffic.ndjson"
SUMMARY_JSON="$RUN_DIR/summary.json"

START_EPOCH="$(date +%s)"
END_EPOCH="$((START_EPOCH + DURATION_SECONDS))"
NEXT_RESTART_EPOCH="$((START_EPOCH + RESTART_INTERVAL_SECONDS))"
NEXT_BLIP_EPOCH="$((START_EPOCH + BLIP_INTERVAL_SECONDS))"
NEXT_TRAFFIC_EPOCH="$((START_EPOCH + TRAFFIC_INTERVAL_SECONDS))"
TRAFFIC_INDEX=0

jq -n \
  --arg runId "$RUN_ID" \
  --arg startedAtUtc "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg durationSeconds "$DURATION_SECONDS" \
  --arg restartIntervalSeconds "$RESTART_INTERVAL_SECONDS" \
  --arg blipIntervalSeconds "$BLIP_INTERVAL_SECONDS" \
  --arg sampleIntervalSeconds "$SAMPLE_INTERVAL_SECONDS" \
  --arg trafficIntervalSeconds "$TRAFFIC_INTERVAL_SECONDS" \
  '
  {
    runId: $runId,
    startedAtUtc: $startedAtUtc,
    durationSeconds: ($durationSeconds | tonumber),
    restartIntervalSeconds: ($restartIntervalSeconds | tonumber),
    blipIntervalSeconds: ($blipIntervalSeconds | tonumber),
    sampleIntervalSeconds: ($sampleIntervalSeconds | tonumber),
    trafficIntervalSeconds: ($trafficIntervalSeconds | tonumber)
  }
  ' > "$META_JSON"

record_event() {
  local event_type="$1"
  local status="$2"
  local details="$3"
  jq -nc \
    --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg type "$event_type" \
    --arg status "$status" \
    --arg details "$details" \
    '{tsUtc:$ts, type:$type, status:$status, details:$details}' >> "$EVENT_LOG"
}

record_probe() {
  local probe_tmp="$RUN_DIR/probe-current.json"
  local probe_err="$RUN_DIR/probe-current.err.log"
  if openclaw gateway probe --json > "$probe_tmp" 2> "$probe_err"; then
    jq -nc \
      --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --argjson probe "$(cat "$probe_tmp")" \
      '{tsUtc:$ts, ok:($probe.ok // false), primaryTargetId:($probe.primaryTargetId // null), warnings:($probe.warnings // []), targets:($probe.targets // [])}' \
      >> "$PROBE_LOG"
  else
    jq -nc \
      --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --arg err "$(sed -n '1,6p' "$probe_err" | tr '\n' ' ')" \
      '{tsUtc:$ts, ok:false, error:$err}' >> "$PROBE_LOG"
  fi
}

record_channels() {
  local channels_tmp="$RUN_DIR/channels-current.json"
  local channels_err="$RUN_DIR/channels-current.err.log"
  if openclaw gateway call channels.status --json > "$channels_tmp" 2> "$channels_err"; then
    jq -nc \
      --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --argjson status "$(cat "$channels_tmp")" \
      '
      {
        tsUtc: $ts,
        accountId: ($status.channelAccounts.telegram[0].accountId // null),
        running: ($status.channelAccounts.telegram[0].running // null),
        mode: ($status.channelAccounts.telegram[0].mode // null),
        lastInboundAt: ($status.channelAccounts.telegram[0].lastInboundAt // null),
        lastOutboundAt: ($status.channelAccounts.telegram[0].lastOutboundAt // null),
        lastError: ($status.channelAccounts.telegram[0].lastError // null)
      }
      ' >> "$CHANNELS_LOG"
  else
    jq -nc \
      --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --arg err "$(sed -n '1,6p' "$channels_err" | tr '\n' ' ')" \
      '{tsUtc:$ts, running:null, mode:null, lastInboundAt:null, lastOutboundAt:null, lastError:$err}' >> "$CHANNELS_LOG"
  fi
}

run_restart() {
  local restart_out="$RUN_DIR/restart-$(date -u +'%Y%m%dT%H%M%SZ').json"
  local restart_err="$RUN_DIR/restart-$(date -u +'%Y%m%dT%H%M%SZ').err.log"
  if openclaw gateway restart --json > "$restart_out" 2> "$restart_err"; then
    record_event "gateway_restart" "ok" "$restart_out"
  else
    record_event "gateway_restart" "failed" "$(sed -n '1,6p' "$restart_err" | tr '\n' ' ')"
  fi
}

run_network_blip() {
  local probe_tmp="$RUN_DIR/blip-probe-$(date -u +'%Y%m%dT%H%M%SZ').json"
  local probe_err="$RUN_DIR/blip-probe-$(date -u +'%Y%m%dT%H%M%SZ').err.log"
  local tunnel_pid=""
  if openclaw gateway probe --json > "$probe_tmp" 2> "$probe_err"; then
    tunnel_pid="$(jq -r '.targets[]? | select(.id=="sshTunnel") | .tunnel.pid // empty' "$probe_tmp")"
  fi

  if [[ "$tunnel_pid" =~ ^[0-9]+$ ]]; then
    if kill -TERM "$tunnel_pid" 2>/dev/null; then
      record_event "network_blip" "ok" "killed sshTunnel pid=$tunnel_pid"
    else
      record_event "network_blip" "failed" "failed to kill sshTunnel pid=$tunnel_pid"
    fi
  else
    record_event "network_blip" "skipped" "sshTunnel pid unavailable"
  fi
}

run_traffic() {
  TRAFFIC_INDEX=$((TRAFFIC_INDEX + 1))
  local msg="PR-SOAK-01 run=$RUN_ID idx=$TRAFFIC_INDEX. Reply with ACK run=$RUN_ID idx=$TRAFFIC_INDEX."
  local response_json="$RUN_DIR/traffic-response-$TRAFFIC_INDEX.json"
  local response_err="$RUN_DIR/traffic-response-$TRAFFIC_INDEX.err.log"
  local status="failed"
  if openclaw agent --agent main --message "$msg" --json > "$response_json" 2> "$response_err"; then
    status="$(jq -r '.status // "failed"' "$response_json" 2>/dev/null || echo failed)"
  fi

  jq -nc \
    --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg idx "$TRAFFIC_INDEX" \
    --arg status "$status" \
    --arg response "$response_json" \
    --arg stderr "$response_err" \
    '{tsUtc:$ts, idx:($idx|tonumber), status:$status, responseArtifact:$response, stderrArtifact:$stderr}' >> "$TRAFFIC_LOG"
}

record_event "run_start" "ok" "started soak run $RUN_ID"

while true; do
  NOW_EPOCH="$(date +%s)"
  if [[ "$NOW_EPOCH" -ge "$END_EPOCH" ]]; then
    break
  fi

  if [[ "$NOW_EPOCH" -ge "$NEXT_RESTART_EPOCH" ]]; then
    run_restart
    NEXT_RESTART_EPOCH="$((NOW_EPOCH + RESTART_INTERVAL_SECONDS))"
  fi

  if [[ "$NOW_EPOCH" -ge "$NEXT_BLIP_EPOCH" ]]; then
    run_network_blip
    NEXT_BLIP_EPOCH="$((NOW_EPOCH + BLIP_INTERVAL_SECONDS))"
  fi

  if [[ "$NOW_EPOCH" -ge "$NEXT_TRAFFIC_EPOCH" ]]; then
    run_traffic
    NEXT_TRAFFIC_EPOCH="$((NOW_EPOCH + TRAFFIC_INTERVAL_SECONDS))"
  fi

  record_probe
  record_channels
  sleep "$SAMPLE_INTERVAL_SECONDS"
done

record_event "run_end" "ok" "completed soak run $RUN_ID"

"$ROOT_DIR/scripts/openclaw/soak_stats.sh" "$RUN_DIR" > "$SUMMARY_JSON"

echo "run_id=$RUN_ID"
echo "run_dir=$RUN_DIR"
echo "summary_json=$SUMMARY_JSON"
