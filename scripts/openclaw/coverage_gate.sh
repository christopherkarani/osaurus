#!/usr/bin/env bash
set -euo pipefail

THRESHOLD_PERCENT="${1:-${OPENCLAW_COVERAGE_THRESHOLD:-69}}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${2:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/coverage}"

RUN_OUTPUT="$("$ROOT_DIR/scripts/openclaw/coverage_openclaw.sh" "$THRESHOLD_PERCENT" "$OUT_DIR")"
printf '%s\n' "$RUN_OUTPUT"

SUMMARY_JSON="$(printf '%s\n' "$RUN_OUTPUT" | awk -F= '/^summary_json=/{print $2}' | tail -n 1)"
if [[ -z "$SUMMARY_JSON" || ! -f "$SUMMARY_JSON" ]]; then
  echo "coverage gate failed: summary artifact missing" >&2
  exit 65
fi

STATUS="$(jq -r '.status // "failed"' "$SUMMARY_JSON")"
LINE_COVERAGE_PERCENT="$(jq -r '.metrics.lineCoveragePercent // 0' "$SUMMARY_JSON")"
FORMATTED_COVERAGE="$(printf '%.2f' "$LINE_COVERAGE_PERCENT")"

if [[ "$STATUS" != "passed" ]]; then
  echo "coverage gate failed: OpenClaw-critical line coverage ${FORMATTED_COVERAGE}% is below threshold ${THRESHOLD_PERCENT}%." >&2
  exit 1
fi

echo "coverage gate passed: OpenClaw-critical line coverage ${FORMATTED_COVERAGE}% meets threshold ${THRESHOLD_PERCENT}%."
