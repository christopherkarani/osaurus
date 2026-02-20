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
MESSAGE="PR-E2E-02 outbound proof $TS_UTC"

PRE_STATUS_JSON="$OUT_DIR/channels-status-pre-outbound-$TS_SAFE.json"
POST_STATUS_JSON="$OUT_DIR/channels-status-post-outbound-$TS_SAFE.json"
SEND_JSON="$OUT_DIR/telegram-send-$TS_SAFE.json"
SEND_ERR="$OUT_DIR/telegram-send-$TS_SAFE.err.log"
SUMMARY_JSON="$OUT_DIR/e2e-outbound-summary-$TS_SAFE.json"

openclaw gateway call channels.status --json > "$PRE_STATUS_JSON"
PRE_OUTBOUND="$(jq -r '.channelAccounts.telegram[0].lastOutboundAt // "null"' "$PRE_STATUS_JSON")"

if ! openclaw message send \
  --channel telegram \
  --target "$TARGET" \
  --message "$MESSAGE" \
  --json > "$SEND_JSON" 2> "$SEND_ERR"; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg target "$TARGET" \
    --arg message "$MESSAGE" \
    --arg preOutbound "$PRE_OUTBOUND" \
    --arg preStatus "$PRE_STATUS_JSON" \
    --arg sendJson "$SEND_JSON" \
    --arg sendErr "$SEND_ERR" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      message: $message,
      status: "failed",
      reason: "openclaw message send failed",
      preLastOutboundAt: $preOutbound,
      preStatusArtifact: $preStatus,
      sendStdoutArtifact: $sendJson,
      sendStderrArtifact: $sendErr
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  echo "send_err=$SEND_ERR"
  exit 1
fi

POST_OUTBOUND="null"
for _ in $(seq 1 15); do
  openclaw gateway call channels.status --json > "$POST_STATUS_JSON"
  POST_OUTBOUND="$(jq -r '.channelAccounts.telegram[0].lastOutboundAt // "null"' "$POST_STATUS_JSON")"
  if [[ "$POST_OUTBOUND" != "null" && "$POST_OUTBOUND" != "$PRE_OUTBOUND" ]]; then
    break
  fi
  sleep 2
done

if [[ "$POST_OUTBOUND" == "null" || "$POST_OUTBOUND" == "$PRE_OUTBOUND" ]]; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg target "$TARGET" \
    --arg message "$MESSAGE" \
    --arg preOutbound "$PRE_OUTBOUND" \
    --arg postOutbound "$POST_OUTBOUND" \
    --arg preStatus "$PRE_STATUS_JSON" \
    --arg postStatus "$POST_STATUS_JSON" \
    --arg sendJson "$SEND_JSON" \
    --arg sendErr "$SEND_ERR" \
    '
    {
      generatedAtUtc: $ts,
      target: $target,
      message: $message,
      status: "failed",
      reason: "lastOutboundAt did not advance",
      preLastOutboundAt: $preOutbound,
      postLastOutboundAt: $postOutbound,
      preStatusArtifact: $preStatus,
      postStatusArtifact: $postStatus,
      sendStdoutArtifact: $sendJson,
      sendStderrArtifact: $sendErr
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

jq -n \
  --arg ts "$TS_UTC" \
  --arg target "$TARGET" \
  --arg message "$MESSAGE" \
  --arg preOutbound "$PRE_OUTBOUND" \
  --arg postOutbound "$POST_OUTBOUND" \
  --arg preStatus "$PRE_STATUS_JSON" \
  --arg postStatus "$POST_STATUS_JSON" \
  --arg sendJson "$SEND_JSON" \
  --arg sendErr "$SEND_ERR" \
  '
  {
    generatedAtUtc: $ts,
    target: $target,
    message: $message,
    status: "passed",
    preLastOutboundAt: $preOutbound,
    postLastOutboundAt: $postOutbound,
    preStatusArtifact: $preStatus,
    postStatusArtifact: $postStatus,
    sendStdoutArtifact: $sendJson,
    sendStderrArtifact: $sendErr
  }
  ' > "$SUMMARY_JSON"

echo "status=passed"
echo "summary_json=$SUMMARY_JSON"
echo "pre_status_json=$PRE_STATUS_JSON"
echo "post_status_json=$POST_STATUS_JSON"
echo "send_json=$SEND_JSON"
echo "send_err=$SEND_ERR"
