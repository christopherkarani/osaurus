#!/usr/bin/env bash
set -euo pipefail

MESSAGE_COUNT="${1:-5}"
LOOP_ITERATIONS="${2:-10}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${3:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e}"
mkdir -p "$OUT_DIR"

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TAG="seq-gap-$(date -u +'%Y%m%dT%H%M%SZ')"

PROBE_PRE_JSON="$OUT_DIR/probe-pre-seq-gap-$TAG.json"
PROBE_POST_JSON="$OUT_DIR/probe-post-seq-gap-$TAG.json"
RUN_LOG="$OUT_DIR/seq-gap-live-runs-$TAG.log"
HISTORY_JSON="$OUT_DIR/chat-history-seq-gap-$TAG.json"
SEQ_GAP_LOOP_LOG="$OUT_DIR/seq-gap-test-loops-$TAG.log"
SUMMARY_JSON="$OUT_DIR/e2e-seq-gap-resync-summary-$TAG.json"

record_summary() {
  local status="$1"
  local reason="$2"
  local pre_probe_ok="$3"
  local post_probe_ok="$4"
  local live_ok_runs="$5"
  local live_failed_runs="$6"
  local user_tagged_count="$7"
  local assistant_tagged_count="$8"
  local missing_assistant_indexes_json="$9"
  local seq1_pass="${10}"
  local seq1_fail="${11}"
  local seq2_pass="${12}"
  local seq2_fail="${13}"

  jq -n \
    --arg ts "$TS_UTC" \
    --arg tag "$TAG" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg preProbeOk "$pre_probe_ok" \
    --arg postProbeOk "$post_probe_ok" \
    --arg liveOkRuns "$live_ok_runs" \
    --arg liveFailedRuns "$live_failed_runs" \
    --arg userTaggedCount "$user_tagged_count" \
    --arg assistantTaggedCount "$assistant_tagged_count" \
    --argjson missingAssistantIndexes "$missing_assistant_indexes_json" \
    --arg seq1Pass "$seq1_pass" \
    --arg seq1Fail "$seq1_fail" \
    --arg seq2Pass "$seq2_pass" \
    --arg seq2Fail "$seq2_fail" \
    --arg probePre "$PROBE_PRE_JSON" \
    --arg probePost "$PROBE_POST_JSON" \
    --arg runLog "$RUN_LOG" \
    --arg history "$HISTORY_JSON" \
    --arg seqGapLoopLog "$SEQ_GAP_LOOP_LOG" \
    --argjson messageCount "$MESSAGE_COUNT" \
    --argjson loopIterations "$LOOP_ITERATIONS" \
    '
    {
      generatedAtUtc: $ts,
      tag: $tag,
      status: $status,
      reason: $reason,
      messageCount: $messageCount,
      loopIterations: $loopIterations,
      preProbeOk: ($preProbeOk == "true"),
      postProbeOk: ($postProbeOk == "true"),
      liveRunOkCount: ($liveOkRuns | tonumber),
      liveRunFailedCount: ($liveFailedRuns | tonumber),
      userTaggedCount: ($userTaggedCount | tonumber),
      assistantTaggedCount: ($assistantTaggedCount | tonumber),
      missingAssistantIndexes: $missingAssistantIndexes,
      seqGapRefreshLoopPasses: ($seq1Pass | tonumber),
      seqGapRefreshLoopFailures: ($seq1Fail | tonumber),
      seqGapEndRaceLoopPasses: ($seq2Pass | tonumber),
      seqGapEndRaceLoopFailures: ($seq2Fail | tonumber),
      preProbeArtifact: $probePre,
      postProbeArtifact: $probePost,
      runLogArtifact: $runLog,
      chatHistoryArtifact: $history,
      seqGapLoopLogArtifact: $seqGapLoopLog
    }
    ' > "$SUMMARY_JSON"
}

if ! openclaw gateway probe --json > "$PROBE_PRE_JSON"; then
  record_summary "failed" "pre-run gateway probe failed" "false" "false" "0" "0" "0" "0" "[]" "0" "0" "0" "0"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

PRE_PROBE_OK="$(jq -r '.ok // false' "$PROBE_PRE_JSON" 2>/dev/null || echo false)"

LIVE_OK_RUNS=0
LIVE_FAILED_RUNS=0
for i in $(seq 1 "$MESSAGE_COUNT"); do
  MSG="PR-E2E-06 tag=$TAG idx=$i. Reply with text that includes: ACK tag=$TAG idx=$i."
  RESP_JSON="$OUT_DIR/seq-gap-live-response-$TAG-$i.json"
  RESP_ERR="$OUT_DIR/seq-gap-live-response-$TAG-$i.err.log"

  STATUS="failed"
  if openclaw agent --agent main --message "$MSG" --json > "$RESP_JSON" 2> "$RESP_ERR"; then
    STATUS="$(jq -r '.status // "failed"' "$RESP_JSON" 2>/dev/null || echo failed)"
  fi

  if [[ "$STATUS" == "ok" ]]; then
    LIVE_OK_RUNS=$((LIVE_OK_RUNS + 1))
  else
    LIVE_FAILED_RUNS=$((LIVE_FAILED_RUNS + 1))
  fi

  printf '%s idx=%s status=%s response=%s stderr=%s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "$i" \
    "$STATUS" \
    "$RESP_JSON" \
    "$RESP_ERR" >> "$RUN_LOG"
done

openclaw gateway call chat.history --params '{"sessionKey":"agent:main:main","limit":400}' --json > "$HISTORY_JSON"

USER_TAGGED_COUNT="$(jq -r --arg tag "$TAG" '[.messages[] | select(.role == "user") | [.content[]? | .text // ""] | join(" ") | select(contains($tag))] | length' "$HISTORY_JSON")"
ASSISTANT_TAGGED_COUNT="$(jq -r --arg tag "$TAG" '[.messages[] | select(.role == "assistant") | [.content[]? | select(.type == "text") | .text // ""] | join(" ") | select(contains($tag))] | length' "$HISTORY_JSON")"

ASSISTANT_INDEXES_JSON="$(jq -r --arg tag "$TAG" '
  .messages[]
  | select(.role == "assistant")
  | ([.content[]? | select(.type == "text") | .text // ""] | join(" ")) as $text
  | select($text | contains($tag))
  | (try ($text | capture("idx=(?<idx>[0-9]+)").idx) catch empty)
' "$HISTORY_JSON" | sort -n | uniq | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"

if [[ "$ASSISTANT_INDEXES_JSON" == "" ]]; then
  ASSISTANT_INDEXES_JSON="[]"
fi

MISSING_ASSISTANT_INDEXES_JSON="$(jq -n \
  --argjson expected "$MESSAGE_COUNT" \
  --argjson seen "$ASSISTANT_INDEXES_JSON" \
  '[(range(1; ($expected + 1))) as $i | select(($seen | index($i)) == null)]')"

SEQ1_PASS=0
SEQ1_FAIL=0
SEQ2_PASS=0
SEQ2_FAIL=0
echo "loop_start_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$SEQ_GAP_LOOP_LOG"

pushd "$ROOT_DIR/Packages/OsaurusCore" >/dev/null
for i in $(seq 1 "$LOOP_ITERATIONS"); do
  echo "seq_gap_refresh_iteration=$i" >> "$SEQ_GAP_LOOP_LOG"
  if swift test --filter streamRunIntoTurn_sequenceGapTriggersConnectionRefresh >> "$SEQ_GAP_LOOP_LOG" 2>&1; then
    SEQ1_PASS=$((SEQ1_PASS + 1))
  else
    SEQ1_FAIL=$((SEQ1_FAIL + 1))
    break
  fi
done

for i in $(seq 1 "$LOOP_ITERATIONS"); do
  echo "seq_gap_end_race_iteration=$i" >> "$SEQ_GAP_LOOP_LOG"
  if swift test --filter streamRunIntoTurn_gapThenImmediateEnd_isDeterministicAcrossIterations >> "$SEQ_GAP_LOOP_LOG" 2>&1; then
    SEQ2_PASS=$((SEQ2_PASS + 1))
  else
    SEQ2_FAIL=$((SEQ2_FAIL + 1))
    break
  fi
done
popd >/dev/null

POST_PROBE_OK="false"
if openclaw gateway probe --json > "$PROBE_POST_JSON"; then
  POST_PROBE_OK="$(jq -r '.ok // false' "$PROBE_POST_JSON" 2>/dev/null || echo false)"
fi

if [[ \
  "$PRE_PROBE_OK" != "true" || \
  "$POST_PROBE_OK" != "true" || \
  "$LIVE_FAILED_RUNS" -ne 0 || \
  "$USER_TAGGED_COUNT" -ne "$MESSAGE_COUNT" || \
  "$ASSISTANT_TAGGED_COUNT" -lt "$MESSAGE_COUNT" || \
  "$MISSING_ASSISTANT_INDEXES_JSON" != "[]" || \
  "$SEQ1_PASS" -lt "$LOOP_ITERATIONS" || \
  "$SEQ2_PASS" -lt "$LOOP_ITERATIONS" \
  ]]; then
  record_summary \
    "failed" \
    "seq-gap/resync validation criteria not met" \
    "$PRE_PROBE_OK" \
    "$POST_PROBE_OK" \
    "$LIVE_OK_RUNS" \
    "$LIVE_FAILED_RUNS" \
    "$USER_TAGGED_COUNT" \
    "$ASSISTANT_TAGGED_COUNT" \
    "$MISSING_ASSISTANT_INDEXES_JSON" \
    "$SEQ1_PASS" \
    "$SEQ1_FAIL" \
    "$SEQ2_PASS" \
    "$SEQ2_FAIL"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

record_summary \
  "passed" \
  "live traffic completed without tagged-message loss and seq-gap resync loops were stable" \
  "$PRE_PROBE_OK" \
  "$POST_PROBE_OK" \
  "$LIVE_OK_RUNS" \
  "$LIVE_FAILED_RUNS" \
  "$USER_TAGGED_COUNT" \
  "$ASSISTANT_TAGGED_COUNT" \
  "$MISSING_ASSISTANT_INDEXES_JSON" \
  "$SEQ1_PASS" \
  "$SEQ1_FAIL" \
  "$SEQ2_PASS" \
  "$SEQ2_FAIL"

echo "status=passed"
echo "summary_json=$SUMMARY_JSON"
