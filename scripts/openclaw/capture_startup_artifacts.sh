#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_ROOT="${1:-$ROOT_DIR/.claude/plans/artifacts/openclaw-production/startup}"
LOG_WINDOW_MINUTES="${LOG_WINDOW_MINUTES:-30}"
TS_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TS_SAFE="$(date -u +'%Y%m%dT%H%M%SZ')"
BUNDLE_DIR="$OUT_ROOT/startup-$TS_SAFE"

mkdir -p "$BUNDLE_DIR"

OSAURUS_SUPPORT_ROOT="$HOME/Library/Application Support/com.dinoki.osaurus"
OSAURUS_RUNTIME_DIR="$OSAURUS_SUPPORT_ROOT/runtime"
OSAURUS_PROVIDERS_DIR="$OSAURUS_SUPPORT_ROOT/providers"
OPENCLAW_DIAG_PATH="$HOME/Library/Logs/OpenClaw/diagnostics.jsonl"

redact_text_stream() {
  sed -E \
    -e 's/([Aa]uthorization[[:space:]]*:[[:space:]]*[Bb]earer[[:space:]]+)[^[:space:]",;]+/\1<redacted>/g' \
    -e 's/([Aa]pi[_-]?[Kk]ey[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1<redacted>/g' \
    -e 's/([Tt]oken[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1<redacted>/g' \
    -e 's/([Ss]ecret[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1<redacted>/g' \
    -e 's/([Pp]assword[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1<redacted>/g'
}

copy_text_redacted() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    redact_text_stream < "$src" > "$dst"
    return 0
  fi
  return 1
}

redact_json_file() {
  local src="$1"
  local dst="$2"

  if [[ ! -f "$src" ]]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    jq --sort-keys '
      def walk(f):
        . as $in
        | if type == "object" then
            reduce keys[] as $k ({}; . + { ($k): ($in[$k] | walk(f)) }) | f
          elif type == "array" then
            map(walk(f)) | f
          else
            f
          end;
      walk(
        if type == "object" then
          with_entries(
            if (.key | ascii_downcase | test("authorization|api[_-]?key|apikey|token|secret|password|bearer"))
            then .value = "<redacted>"
            else .
            end
          )
        elif type == "string" then
          if test("(?i)^bearer[[:space:]]+")
          then "Bearer <redacted>"
          else .
          end
        else
          .
        end
      )
    ' "$src" > "$dst"
  else
    redact_text_stream < "$src" > "$dst"
  fi
}

resolve_openclaw_launch_log_path() {
  local plist_path="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
  if [[ -f "$plist_path" ]]; then
    local stdout_path
    local stderr_path
    stdout_path="$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$plist_path" 2>/dev/null || true)"
    if [[ -n "$stdout_path" ]]; then
      printf '%s\n' "$stdout_path"
      return 0
    fi
    stderr_path="$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$plist_path" 2>/dev/null || true)"
    if [[ -n "$stderr_path" ]]; then
      printf '%s\n' "$stderr_path"
      return 0
    fi
  fi
  printf '%s\n' '/tmp/openclaw/openclaw-gateway.log'
}

# 1) Osaurus startup diagnostics file
if ! copy_text_redacted \
  "$OSAURUS_RUNTIME_DIR/startup-diagnostics.jsonl" \
  "$BUNDLE_DIR/osaurus-startup-diagnostics.jsonl"
then
  echo "missing: $OSAURUS_RUNTIME_DIR/startup-diagnostics.jsonl" > "$BUNDLE_DIR/osaurus-startup-diagnostics.missing"
fi

# 2) Osaurus unified logs for a bounded window
if command -v log >/dev/null 2>&1; then
  log show --style compact \
    --last "${LOG_WINDOW_MINUTES}m" \
    --predicate '(process == "osaurus" OR process == "Osaurus")' \
    > "$BUNDLE_DIR/osaurus-unified.log.raw" \
    2> "$BUNDLE_DIR/osaurus-unified.log.stderr" || true
  if [[ -f "$BUNDLE_DIR/osaurus-unified.log.raw" ]]; then
    redact_text_stream < "$BUNDLE_DIR/osaurus-unified.log.raw" > "$BUNDLE_DIR/osaurus-unified.log"
    rm -f "$BUNDLE_DIR/osaurus-unified.log.raw"
  fi
else
  echo "missing: macOS 'log' utility" > "$BUNDLE_DIR/osaurus-unified.log.missing"
fi

# 3) OpenClaw diagnostics JSONL
if ! copy_text_redacted "$OPENCLAW_DIAG_PATH" "$BUNDLE_DIR/openclaw-diagnostics.jsonl"; then
  echo "missing: $OPENCLAW_DIAG_PATH" > "$BUNDLE_DIR/openclaw-diagnostics.missing"
fi

# 4) OpenClaw launch agent log (matches OpenClawLaunchAgent.logPath())
OPENCLAW_LAUNCH_LOG_PATH="$(resolve_openclaw_launch_log_path)"
if ! copy_text_redacted "$OPENCLAW_LAUNCH_LOG_PATH" "$BUNDLE_DIR/openclaw-launch-agent.log"; then
  echo "missing: $OPENCLAW_LAUNCH_LOG_PATH" > "$BUNDLE_DIR/openclaw-launch-agent.missing"
fi

# 5) Effective provider configs (redacted)
mkdir -p "$BUNDLE_DIR/providers"
if ! redact_json_file "$OSAURUS_PROVIDERS_DIR/remote.json" "$BUNDLE_DIR/providers/remote.redacted.json"; then
  echo "missing: $OSAURUS_PROVIDERS_DIR/remote.json" > "$BUNDLE_DIR/providers/remote.redacted.missing"
fi
if ! redact_json_file "$OSAURUS_PROVIDERS_DIR/mcp.json" "$BUNDLE_DIR/providers/mcp.redacted.json"; then
  echo "missing: $OSAURUS_PROVIDERS_DIR/mcp.json" > "$BUNDLE_DIR/providers/mcp.redacted.missing"
fi

cat > "$BUNDLE_DIR/manifest.txt" <<MANIFEST
generatedAtUtc=$TS_UTC
bundleDir=$BUNDLE_DIR
osaurusSupportRoot=$OSAURUS_SUPPORT_ROOT
logWindowMinutes=$LOG_WINDOW_MINUTES
openClawLaunchLogPath=$OPENCLAW_LAUNCH_LOG_PATH
MANIFEST

echo "generated_at=$TS_UTC"
echo "bundle_dir=$BUNDLE_DIR"
echo "manifest=$BUNDLE_DIR/manifest.txt"
echo "openclaw_launch_log_path=$OPENCLAW_LAUNCH_LOG_PATH"
