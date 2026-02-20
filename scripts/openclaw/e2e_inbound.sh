#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: $0 <telegram-target> [wait-seconds] [out-dir]" >&2
  exit 64
fi

TARGET="$1"
WAIT_SECONDS="${2:-120}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${3:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e}"
mkdir -p "$OUT_DIR"

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"

PRE_STATUS_JSON="$OUT_DIR/channels-status-pre-inbound-$TS_SAFE.json"
POST_STATUS_JSON="$OUT_DIR/channels-status-post-inbound-$TS_SAFE.json"
SUMMARY_JSON="$OUT_DIR/e2e-inbound-summary-$TS_SAFE.json"

openclaw gateway call channels.status --json > "$PRE_STATUS_JSON"
PRE_INBOUND="$(jq -r '.channelAccounts.telegram[0].lastInboundAt // "null"' "$PRE_STATUS_JSON")"

echo "waiting_for_inbound_target=$TARGET"
echo "wait_seconds=$WAIT_SECONDS"

POST_INBOUND="$PRE_INBOUND"
POLL_INTERVAL=5
ITERATIONS=$((WAIT_SECONDS / POLL_INTERVAL))
if [[ "$ITERATIONS" -lt 1 ]]; then
  ITERATIONS=1
fi

for _ in $(seq 1 "$ITERATIONS"); do
  openclaw gateway call channels.status --json > "$POST_STATUS_JSON"
  POST_INBOUND="$(jq -r '.channelAccounts.telegram[0].lastInboundAt // "null"' "$POST_STATUS_JSON")"
  if [[ "$POST_INBOUND" != "null" && "$POST_INBOUND" != "$PRE_INBOUND" ]]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done

if [[ "$POST_INBOUND" == "null" || "$POST_INBOUND" == "$PRE_INBOUND" ]]; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg target "$TARGET" \
    --arg preInbound "$PRE_INBOUND" \
    --arg postInbound "$POST_INBOUND" \
    --arg preStatus "$PRE_STATUS_JSON" \
    --arg postStatus "$POST_STATUS_JSON" \
    --arg waitSeconds "$WAIT_SECONDS" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      status: "failed",
      reason: "lastInboundAt did not advance within wait window",
      waitSeconds: ($waitSeconds | tonumber),
      preLastInboundAt: $preInbound,
      postLastInboundAt: $postInbound,
      preStatusArtifact: $preStatus,
      postStatusArtifact: $postStatus
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

jq -n \
  --arg ts "$TS_UTC" \
  --arg target "$TARGET" \
  --arg preInbound "$PRE_INBOUND" \
  --arg postInbound "$POST_INBOUND" \
  --arg preStatus "$PRE_STATUS_JSON" \
  --arg postStatus "$POST_STATUS_JSON" \
  --arg waitSeconds "$WAIT_SECONDS" \
  '
  {
    generatedAtUtc: $ts,
    target: $target,
    status: "passed",
    waitSeconds: ($waitSeconds | tonumber),
    preLastInboundAt: $preInbound,
    postLastInboundAt: $postInbound,
    preStatusArtifact: $preStatus,
    postStatusArtifact: $postStatus
  }
  ' > "$SUMMARY_JSON"

echo "status=passed"
echo "summary_json=$SUMMARY_JSON"
echo "pre_status_json=$PRE_STATUS_JSON"
echo "post_status_json=$POST_STATUS_JSON"
