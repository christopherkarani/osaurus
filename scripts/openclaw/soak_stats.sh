#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: $0 <soak-run-dir>" >&2
  exit 64
fi

RUN_DIR="$1"
PROBE_LOG="$RUN_DIR/probe.ndjson"
CHANNELS_LOG="$RUN_DIR/channels.ndjson"
EVENT_LOG="$RUN_DIR/events.ndjson"
TRAFFIC_LOG="$RUN_DIR/traffic.ndjson"

for required in "$PROBE_LOG" "$CHANNELS_LOG" "$EVENT_LOG" "$TRAFFIC_LOG"; do
  if [[ ! -f "$required" ]]; then
    echo "missing required soak artifact: $required" >&2
    exit 66
  fi
done

PROBE_TOTAL="$(jq -s 'length' "$PROBE_LOG")"
PROBE_OK="$(jq -s '[.[] | select(.ok == true)] | length' "$PROBE_LOG")"
PROBE_FAIL="$(jq -s '[.[] | select(.ok != true)] | length' "$PROBE_LOG")"
MAX_CONSEC_PROBE_FAILS="$(jq -s '
  reduce .[] as $item ({cur:0,max:0};
    if $item.ok == true
      then .cur = 0
      else .cur = (.cur + 1) | .max = (if .cur > .max then .cur else .max end)
    end
  ) | .max
' "$PROBE_LOG")"

RESTART_COUNT="$(jq -s '[.[] | select(.type == "gateway_restart")] | length' "$EVENT_LOG")"
BLIP_COUNT="$(jq -s '[.[] | select(.type == "network_blip")] | length' "$EVENT_LOG")"
TRAFFIC_OK_COUNT="$(jq -s '[.[] | select(.status == "ok")] | length' "$TRAFFIC_LOG")"
TRAFFIC_FAIL_COUNT="$(jq -s '[.[] | select(.status != "ok")] | length' "$TRAFFIC_LOG")"

TIMESTAMP_REGRESSION_COUNT="$(jq -s '
  reduce .[] as $row (
    {last:null, regressions:0};
    ($row.lastInboundAt // null) as $current
    | if ($current == null)
      then .
      elif (.last == null)
      then .last = $current
      elif (($current | tonumber) < (.last | tonumber))
      then .last = $current | .regressions = (.regressions + 1)
      else .last = $current
      end
  ) | .regressions
' "$CHANNELS_LOG")"

DUPLICATE_INBOUND_EVENT_COUNT="$(jq -s '
  reduce .[] as $row (
    {seen: {}, duplicates: 0, previous: null};
    ($row.lastInboundAt // null) as $current
    | if ($current == null or $current == .previous)
      then .previous = $current
      else
        .duplicates = (if (.seen[$current] // false) then .duplicates + 1 else .duplicates end)
        | .seen[$current] = true
        | .previous = $current
      end
  ) | .duplicates
' "$CHANNELS_LOG")"

POTENTIAL_STUCK_STATE="false"
if [[ "$MAX_CONSEC_PROBE_FAILS" -ge 5 ]]; then
  POTENTIAL_STUCK_STATE="true"
fi

jq -n \
  --arg runDir "$RUN_DIR" \
  --arg probeTotal "$PROBE_TOTAL" \
  --arg probeOk "$PROBE_OK" \
  --arg probeFail "$PROBE_FAIL" \
  --arg maxConsecutiveProbeFails "$MAX_CONSEC_PROBE_FAILS" \
  --arg restartCount "$RESTART_COUNT" \
  --arg blipCount "$BLIP_COUNT" \
  --arg trafficOk "$TRAFFIC_OK_COUNT" \
  --arg trafficFail "$TRAFFIC_FAIL_COUNT" \
  --arg inboundRegressions "$TIMESTAMP_REGRESSION_COUNT" \
  --arg duplicateInboundEvents "$DUPLICATE_INBOUND_EVENT_COUNT" \
  --arg potentialStuck "$POTENTIAL_STUCK_STATE" \
  '
  {
    runDir: $runDir,
    probeSamples: ($probeTotal | tonumber),
    probeOkSamples: ($probeOk | tonumber),
    probeFailSamples: ($probeFail | tonumber),
    maxConsecutiveProbeFails: ($maxConsecutiveProbeFails | tonumber),
    restartCount: ($restartCount | tonumber),
    networkBlipCount: ($blipCount | tonumber),
    trafficOkCount: ($trafficOk | tonumber),
    trafficFailCount: ($trafficFail | tonumber),
    inboundTimestampRegressions: ($inboundRegressions | tonumber),
    duplicateInboundEventTransitions: ($duplicateInboundEvents | tonumber),
    potentialStuckState: ($potentialStuck == "true")
  }
  '
