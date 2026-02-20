#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e}"
mkdir -p "$OUT_DIR"

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"

PROBE_JSON="$OUT_DIR/gateway-probe-$TS_SAFE.json"
STATUS_JSON="$OUT_DIR/channels-status-$TS_SAFE.json"
MATRIX_JSON="$OUT_DIR/e2e-matrix-$TS_SAFE.json"
MATRIX_MD="$OUT_DIR/e2e-matrix-$TS_SAFE.md"

run_json_with_recovery() {
  local out_file="$1"
  shift
  local err_file="${out_file%.json}.err.log"
  local attempts=5
  local n=1
  while [[ "$n" -le "$attempts" ]]; do
    if "$@" > "$out_file" 2> "$err_file"; then
      return 0
    fi
    if [[ "$n" -eq 1 ]]; then
      openclaw gateway start --json >/dev/null 2>&1 || true
    fi
    n=$((n + 1))
    sleep 1
  done
  echo "command_failed=$*" >&2
  echo "stderr_log=$err_file" >&2
  cat "$err_file" >&2
  return 1
}

run_json_with_recovery "$PROBE_JSON" openclaw gateway probe --json
run_json_with_recovery "$STATUS_JSON" openclaw gateway call channels.status --json

jq -n \
  --arg ts "$TS_UTC" \
  --arg probeFile "$PROBE_JSON" \
  --arg statusFile "$STATUS_JSON" \
  --slurpfile status "$STATUS_JSON" \
  '
  ($status[0]) as $s
  | {
      generatedAtUtc: $ts,
      probeArtifact: $probeFile,
      channelsStatusArtifact: $statusFile,
      channels: (
        ($s.channelOrder // [])
        | map(
            . as $channelId
            | ($s.channels[$channelId] // {}) as $channel
            | ($s.channelAccounts[$channelId] // []) as $accounts
            | {
                channelId: $channelId,
                channelLabel: ($s.channelLabels[$channelId] // $channelId),
                configured: ($channel.configured // false),
                running: ($channel.running // false),
                mode: ($channel.mode // null),
                accounts: $accounts,
                validation: {
                  outboundRequired: true,
                  inboundRequired: true,
                  restartReconnectRequired: true,
                  authRecoveryRequired: true,
                  seqGapResyncRequired: true
                }
              }
          )
      )
    }
  ' > "$MATRIX_JSON"

{
  echo "# OpenClaw Production E2E Validation Matrix"
  echo
  echo "- Generated (UTC): $TS_UTC"
  echo "- Probe artifact: \`$PROBE_JSON\`"
  echo "- Channel status artifact: \`$STATUS_JSON\`"
  echo "- Matrix JSON: \`$MATRIX_JSON\`"
  echo
  echo "| Channel | Configured | Running | Mode | Accounts |"
  echo "|---|---:|---:|---|---:|"
  jq -r '
    .channels[]
    | "| \(.channelId) | \(.configured) | \(.running) | \(.mode // "null") | \(.accounts | length) |"
  ' "$MATRIX_JSON"
} > "$MATRIX_MD"

echo "generated_at=$TS_UTC"
echo "probe_json=$PROBE_JSON"
echo "status_json=$STATUS_JSON"
echo "matrix_json=$MATRIX_JSON"
echo "matrix_md=$MATRIX_MD"
