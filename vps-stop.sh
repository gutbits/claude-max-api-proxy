#!/usr/bin/env bash
# Stop the Claude Max API proxy on VPS.
set -euo pipefail

PID_FILE="${HOME}/.claude-max-api-proxy.pid"
PORT="${CLAUDE_MAX_PROXY_PORT:-3456}"

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" && echo "Stopped proxy (PID $pid)"
  fi
  rm -f "$PID_FILE"
else
  echo "No PID file found."
fi

if command -v lsof >/dev/null 2>&1; then
  lsof -ti:"$PORT" 2>/dev/null | xargs -r kill 2>/dev/null && echo "Freed port $PORT" || true
fi

echo "Done."
