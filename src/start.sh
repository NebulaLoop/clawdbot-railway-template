#!/usr/bin/env bash
# Boot wrapper that runs the Headroom context-compression proxy as a sidecar
# in front of the OpenClaw gateway to cut Anthropic token usage.
#
# Design principle: STRICTLY ADDITIVE AND FAIL-OPEN.
# If headroom is not installed, fails to start, or is not ready in time, the
# bot runs exactly as before, talking to Anthropic directly. Headroom can never
# take the bot down.
set -u

HEADROOM_BIN="/opt/headroom/bin/headroom"
PROXY_HOST="127.0.0.1"
PROXY_PORT="${HEADROOM_PROXY_PORT:-8787}"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
READY_TIMEOUT="${HEADROOM_READY_TIMEOUT:-30}"
LOG="/tmp/headroom.log"

# Returns 0 if something is listening on the proxy port.
port_open() {
  python3 - "$PROXY_HOST" "$PROXY_PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# Allow disabling headroom entirely without a rebuild: set HEADROOM_DISABLED=1.
if [ "${HEADROOM_DISABLED:-0}" = "1" ]; then
  echo "[headroom] disabled via HEADROOM_DISABLED=1 — using Anthropic directly"
elif [ -x "$HEADROOM_BIN" ]; then
  echo "[headroom] launching proxy on ${PROXY_URL} (watchdog-managed)"
  # Watchdog: keep the proxy alive for the life of the container.
  (
    while true; do
      HEADROOM_UPDATE_CHECK=off "$HEADROOM_BIN" proxy --port "$PROXY_PORT" >>"$LOG" 2>&1
      echo "[headroom] proxy exited (code $?); restarting in 3s" >>"$LOG"
      sleep 3
    done
  ) &

  ready=0
  i=0
  while [ "$i" -lt "$READY_TIMEOUT" ]; do
    if port_open; then ready=1; break; fi
    i=$((i + 1))
    sleep 1
  done

  if [ "$ready" = "1" ]; then
    export ANTHROPIC_BASE_URL="$PROXY_URL"
    echo "[headroom] ready — routing Anthropic via proxy (ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL})"
  else
    echo "[headroom] proxy not ready after ${READY_TIMEOUT}s — using Anthropic directly"
    echo "[headroom] last log lines:"
    tail -n 5 "$LOG" 2>/dev/null || true
  fi
else
  echo "[headroom] not installed — using Anthropic directly"
fi

# Hand off to the OpenClaw gateway wrapper (tini remains PID 1 via ENTRYPOINT).
exec node /app/src/server.js
