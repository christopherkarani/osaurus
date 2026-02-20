#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/e2e}"
mkdir -p "$OUT_DIR"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"

TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"

PROBE_PRE_JSON="$OUT_DIR/probe-pre-auth-recovery-$TS_SAFE.json"
INVALID_STDOUT_LOG="$OUT_DIR/health-invalid-token-$TS_SAFE.stdout.log"
INVALID_STDERR_LOG="$OUT_DIR/health-invalid-token-$TS_SAFE.stderr.log"
HEALTH_VALID_JSON="$OUT_DIR/health-valid-token-$TS_SAFE.json"
PROBE_POST_JSON="$OUT_DIR/probe-post-auth-recovery-$TS_SAFE.json"
SUMMARY_JSON="$OUT_DIR/e2e-auth-recovery-summary-$TS_SAFE.json"

REMOTE_URL="$(jq -r '.gateway.remote.url // empty' "$CONFIG_PATH" 2>/dev/null || true)"
REMOTE_TOKEN="$(jq -r '.gateway.remote.token // empty' "$CONFIG_PATH" 2>/dev/null || true)"

if [[ "$REMOTE_URL" == "" || "$REMOTE_TOKEN" == "" ]]; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg configPath "$CONFIG_PATH" \
    --arg remoteUrl "$REMOTE_URL" \
    --arg remoteTokenPresent "$([[ "$REMOTE_TOKEN" != "" ]] && echo true || echo false)" \
    '
    {
      generatedAtUtc: $ts,
      status: "failed",
      reason: "remote URL/token missing from OpenClaw config; cannot verify token-correction path",
      configPath: $configPath,
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      remoteTokenPresent: ($remoteTokenPresent == "true")
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

if ! openclaw gateway probe --json > "$PROBE_PRE_JSON"; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg probePre "$PROBE_PRE_JSON" \
    --arg invalidStdout "$INVALID_STDOUT_LOG" \
    --arg invalidStderr "$INVALID_STDERR_LOG" \
    --arg healthValid "$HEALTH_VALID_JSON" \
    --arg probePost "$PROBE_POST_JSON" \
    '
    {
      generatedAtUtc: $ts,
      status: "failed",
      reason: "pre-auth-recovery probe failed",
      preProbeArtifact: $probePre,
      invalidTokenStdoutArtifact: $invalidStdout,
      invalidTokenStderrArtifact: $invalidStderr,
      validTokenHealthArtifact: $healthValid,
      postProbeArtifact: $probePost
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

set +e
openclaw gateway call health --url "$REMOTE_URL" --token invalid-smoke-token --json \
  > "$INVALID_STDOUT_LOG" \
  2> "$INVALID_STDERR_LOG"
INVALID_EXIT=$?
set -e

UNAUTHORIZED_VISIBLE="false"
if rg -qi "unauthorized|token mismatch" "$INVALID_STDOUT_LOG" "$INVALID_STDERR_LOG"; then
  UNAUTHORIZED_VISIBLE="true"
fi

VALID_HEALTH_OK="false"
if openclaw gateway call health --url "$REMOTE_URL" --token "$REMOTE_TOKEN" --json > "$HEALTH_VALID_JSON"; then
  VALID_HEALTH_OK="$(jq -r '.ok // false' "$HEALTH_VALID_JSON" 2>/dev/null || echo false)"
fi

POST_PROBE_OK="false"
if openclaw gateway probe --json > "$PROBE_POST_JSON"; then
  POST_PROBE_OK="$(jq -r '.ok // false' "$PROBE_POST_JSON" 2>/dev/null || echo false)"
fi

if [[ "$INVALID_EXIT" -eq 0 || "$UNAUTHORIZED_VISIBLE" != "true" || "$VALID_HEALTH_OK" != "true" || "$POST_PROBE_OK" != "true" ]]; then
  jq -n \
    --arg ts "$TS_UTC" \
    --arg invalidExit "$INVALID_EXIT" \
    --arg unauthorizedVisible "$UNAUTHORIZED_VISIBLE" \
    --arg validHealthOk "$VALID_HEALTH_OK" \
    --arg postProbeOk "$POST_PROBE_OK" \
    --arg probePre "$PROBE_PRE_JSON" \
    --arg invalidStdout "$INVALID_STDOUT_LOG" \
    --arg invalidStderr "$INVALID_STDERR_LOG" \
    --arg healthValid "$HEALTH_VALID_JSON" \
    --arg probePost "$PROBE_POST_JSON" \
    '
    {
      generatedAtUtc: $ts,
      status: "failed",
      reason: "auth failure/recovery criteria not met",
      invalidTokenExitCode: ($invalidExit | tonumber),
      unauthorizedVisible: ($unauthorizedVisible == "true"),
      validTokenHealthOk: ($validHealthOk == "true"),
      postProbeOk: ($postProbeOk == "true"),
      preProbeArtifact: $probePre,
      invalidTokenStdoutArtifact: $invalidStdout,
      invalidTokenStderrArtifact: $invalidStderr,
      validTokenHealthArtifact: $healthValid,
      postProbeArtifact: $probePost
    }
    ' > "$SUMMARY_JSON"
  echo "status=failed"
  echo "summary_json=$SUMMARY_JSON"
  exit 1
fi

jq -n \
  --arg ts "$TS_UTC" \
  --arg invalidExit "$INVALID_EXIT" \
  --arg probePre "$PROBE_PRE_JSON" \
  --arg invalidStdout "$INVALID_STDOUT_LOG" \
  --arg invalidStderr "$INVALID_STDERR_LOG" \
  --arg healthValid "$HEALTH_VALID_JSON" \
  --arg probePost "$PROBE_POST_JSON" \
  '
  {
    generatedAtUtc: $ts,
    status: "passed",
    invalidTokenExitCode: ($invalidExit | tonumber),
    unauthorizedVisible: true,
    validTokenHealthOk: true,
    postProbeOk: true,
    preProbeArtifact: $probePre,
    invalidTokenStdoutArtifact: $invalidStdout,
    invalidTokenStderrArtifact: $invalidStderr,
    validTokenHealthArtifact: $healthValid,
    postProbeArtifact: $probePost
  }
  ' > "$SUMMARY_JSON"

echo "status=passed"
echo "summary_json=$SUMMARY_JSON"
