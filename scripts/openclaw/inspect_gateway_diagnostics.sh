#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${1:-$HOME/Library/Application Support/com.dinoki.osaurus/runtime/startup-diagnostics.jsonl}"
LINES="${LINES:-400}"

if [[ ! -f "$LOG_PATH" ]]; then
  echo "diagnostics file not found: $LOG_PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to inspect diagnostics" >&2
  exit 1
fi

tail -n "$LINES" "$LOG_PATH" | jq -c '
  select(
    (.component == "openclaw-gateway-connection")
    or
    (.component == "openclaw-manager"
      and (
        (.event | startswith("openclaw.connect"))
        or (.event | startswith("openclaw.reconnect"))
        or (.event | startswith("openclaw.poll.reconnect"))
      )
    )
    or
    (.component == "openclaw-session-manager"
      and (
        (.event | startswith("session.create"))
        or (.event | startswith("session.patch"))
      )
    )
    or
    (.component == "work-session"
      and (
        (.event | startswith("work.model.prepare"))
      )
    )
  )
  | {
      ts,
      level,
      component,
      event,
      context
    }
'
