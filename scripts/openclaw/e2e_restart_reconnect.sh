#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: $0 <telegram-target> [out-dir]" >&2
  exit 64
fi

TARGET="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${2:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e}"
mkdir -p "$OUT_DIR"

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"

PROBE_PRE_JSON="$OUT_DIR/probe-pre-restart-$TS_SAFE.json"
RESTART_JSON="$OUT_DIR/gateway-restart-$TS_SAFE.json"
PROBE_POST_JSON="$OUT_DIR/probe-post-restart-$TS_SAFE.json"
OUTBOUND_PRE_SUMMARY="$OUT_DIR/outbound-pre-restart-$TS_SAFE.json"
OUTBOUND_POST_SUMMARY="$OUT_DIR/outbound-post-restart-$TS_SAFE.json"
OUTBOUND_PRE_LOG="$OUT_DIR/outbound-pre-restart-$TS_SAFE.log"
OUTBOUND_POST_LOG="$OUT_DIR/outbound-post-restart-$TS_SAFE.log"
PROBE_POST_ERR="$OUT_DIR/probe-post-restart-$TS_SAFE.err.log"
SUMMARY_JSON="$OUT_DIR/e2e-restart-reconnect-summary-$TS_SAFE.json"
POST_PROBE_ATTEMPTS=12
POST_PROBE_SLEEP_SECONDS=2

record_failure() {
  local reason="$1"
  local post_probe_ok="$2"
  local pre_status="$3"
  local post_status="$4"

  jq -n \
    --arg ts "$TS_UTC" \
    --arg target "$TARGET" \
    --arg reason "$reason" \
    --arg preStatus "$pre_status" \
    --arg postStatus "$post_status" \
    --arg postProbeOk "$post_probe_ok" \
    --arg probePre "$PROBE_PRE_JSON" \
    --arg restart "$RESTART_JSON" \
    --arg probePost "$PROBE_POST_JSON" \
    --arg probePostErr "$PROBE_POST_ERR" \
    --arg outboundPre "$OUTBOUND_PRE_SUMMARY" \
    --arg outboundPost "$OUTBOUND_POST_SUMMARY" \
    --arg outboundPreLog "$OUTBOUND_PRE_LOG" \
    --arg outboundPostLog "$OUTBOUND_POST_LOG" \
    --argjson probeAttempts "$POST_PROBE_ATTEMPTS" \
    --argjson probeSleepSeconds "$POST_PROBE_SLEEP_SECONDS" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      status: "failed",
      reason: $reason,
      probePostOk: ($postProbeOk == "true"),
      outboundPreStatus: $preStatus,
      outboundPostStatus: $postStatus,
      probePostAttempts: $probeAttempts,
      probePostSleepSeconds: $probeSleepSeconds,
      probePreArtifact: $probePre,
      restartArtifact: $restart,
      probePostArtifact: $probePost,
      probePostStderrArtifact: $probePostErr,
      outboundPreArtifact: $outboundPre,
      outboundPostArtifact: $outboundPost,
      outboundPreLogArtifact: $outboundPreLog,
      outboundPostLogArtifact: $outboundPostLog
    }
    ' > "$SUMMARY_JSON"

  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
}

copy_or_synthesize_outbound_summary() {
  local outbound_log="$1"
  local outbound_summary="$2"
  local phase="$3"
  local outbound_exit="$4"
  local src_summary
  src_summary="$(grep '^summary_json=' "$outbound_log" | tail -n 1 | cut -d= -f2- || true)"

  if [[ -n "$src_summary" && -f "$src_summary" ]]; then
    cp "$src_summary" "$outbound_summary"
    return
  fi

  jq -n \
    --arg ts "$TS_UTC" \
    --arg phase "$phase" \
    --arg target "$TARGET" \
    --arg exitCode "$outbound_exit" \
    --arg log "$outbound_log" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      phase: $phase,
      status: "failed",
      reason: "outbound validation failed before summary artifact was emitted",
      outboundExitCode: ($exitCode | tonumber),
      outboundLogArtifact: $log
    }
    ' > "$outbound_summary"
}

run_outbound_phase() {
  local phase="$1"
  local outbound_log="$2"
  local outbound_summary="$3"
  local outbound_exit=0

  if ./scripts/openclaw/e2e_outbound.sh "$TARGET" > "$outbound_log" 2>&1; then
    outbound_exit=0
  else
    outbound_exit=$?
  fi

  copy_or_synthesize_outbound_summary "$outbound_log" "$outbound_summary" "$phase" "$outbound_exit"
}

if ! openclaw gateway probe --json > "$PROBE_PRE_JSON"; then
  record_failure "pre-restart gateway probe command failed" "false" "not-run" "not-run"
  exit 1
fi

run_outbound_phase "pre-restart" "$OUTBOUND_PRE_LOG" "$OUTBOUND_PRE_SUMMARY"

if ! openclaw gateway restart --json > "$RESTART_JSON"; then
  PRE_STATUS="$(jq -r '.status // "failed"' "$OUTBOUND_PRE_SUMMARY")"
  record_failure "gateway restart command failed" "false" "$PRE_STATUS" "not-run"
  exit 1
fi

POST_PROBE_OK="false"
for _ in $(seq 1 "$POST_PROBE_ATTEMPTS"); do
  if openclaw gateway probe --json > "$PROBE_POST_JSON" 2> "$PROBE_POST_ERR"; then
    POST_PROBE_OK="$(jq -r '.ok // false' "$PROBE_POST_JSON" 2>/dev/null || echo false)"
    if [[ "$POST_PROBE_OK" == "true" ]]; then
      break
    fi
  fi
  sleep "$POST_PROBE_SLEEP_SECONDS"
done

PRE_STATUS="$(jq -r '.status' "$OUTBOUND_PRE_SUMMARY")"
if [[ "$POST_PROBE_OK" == "true" ]]; then
  run_outbound_phase "post-restart" "$OUTBOUND_POST_LOG" "$OUTBOUND_POST_SUMMARY"
else
  jq -n \
    --arg ts "$TS_UTC" \
    --arg target "$TARGET" \
    --arg log "$OUTBOUND_POST_LOG" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      phase: "post-restart",
      status: "failed",
      reason: "outbound validation skipped because post-restart gateway probe never became healthy",
      outboundLogArtifact: $log
    }
    ' > "$OUTBOUND_POST_SUMMARY"
fi

POST_STATUS="$(jq -r '.status' "$OUTBOUND_POST_SUMMARY")"

if [[ "$POST_PROBE_OK" != "true" || "$PRE_STATUS" != "passed" || "$POST_STATUS" != "passed" ]]; then
  record_failure \
    "restart/reconnect validation did not satisfy healthy probe + resumed outbound traffic" \
    "$POST_PROBE_OK" \
    "$PRE_STATUS" \
    "$POST_STATUS"
  exit 1
fi

jq -n \
  --arg ts "$TS_UTC" \
  --arg target "$TARGET" \
  --arg probePre "$PROBE_PRE_JSON" \
  --arg restart "$RESTART_JSON" \
  --arg probePost "$PROBE_POST_JSON" \
  --arg probePostErr "$PROBE_POST_ERR" \
  --arg outboundPre "$OUTBOUND_PRE_SUMMARY" \
  --arg outboundPost "$OUTBOUND_POST_SUMMARY" \
  --arg outboundPreLog "$OUTBOUND_PRE_LOG" \
  --arg outboundPostLog "$OUTBOUND_POST_LOG" \
  --argjson probeAttempts "$POST_PROBE_ATTEMPTS" \
  --argjson probeSleepSeconds "$POST_PROBE_SLEEP_SECONDS" \
  '
  {
    generatedAtUtc: $ts,
    target: $target,
    status: "passed",
    probePostAttempts: $probeAttempts,
    probePostSleepSeconds: $probeSleepSeconds,
    probePreArtifact: $probePre,
    restartArtifact: $restart,
    probePostArtifact: $probePost,
    probePostStderrArtifact: $probePostErr,
    outboundPreArtifact: $outboundPre,
    outboundPostArtifact: $outboundPost,
    outboundPreLogArtifact: $outboundPreLog,
    outboundPostLogArtifact: $outboundPostLog
  }
  ' > "$SUMMARY_JSON"

echo "status=passed"
echo "summary_json=$SUMMARY_JSON"
