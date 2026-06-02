#!/usr/bin/env bash
# Proxy cross-SDK conformance: boot OUR Swift server (MPPConformanceServer), which hosts an
# MPPProxy in front of a free in-server origin, and have the reference mppx CLIENT pay a route
# THROUGH the proxy over real HTTP. The proxy mints the 402, verifies the foreign Tempo proof,
# forwards the verified request to the origin, and relays its body with a Payment-Receipt. This
# proves a foreign client pays THROUGH our proxy, not only a directly gated endpoint. Offline and
# deterministic: the zero-amount proof is ecrecover, no Tempo RPC. Dev-only.
#
# Unlike run-reverse.sh, the port must be fixed: the proxy forwards to the origin on this same
# server's port, so it is pinned up front (PORT=0 ephemeral is not supported for the proxy route).
#
#   Scripts/conformance/run-proxy.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8797}"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> building + booting the Swift conformance server (proxy host) on port $PORT"
(cd "$REPO" && swift build --target MPPConformanceServer)
LOG="$(mktemp)"
(cd "$REPO" && PORT="$PORT" swift run MPPConformanceServer) >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

for _ in $(seq 1 120); do
  grep -q "listening" "$LOG" 2>/dev/null && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server failed to start:"; cat "$LOG"; exit 1; fi
  sleep 0.5
done
grep -q "listening" "$LOG" || { echo "server did not become ready:"; cat "$LOG"; exit 1; }
cat "$LOG"

# The proxy pins its origin URL to the requested port, so the bound port equals $PORT here; parse
# it from the log anyway to stay consistent with the other run scripts.
ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"

echo "==> the mppx client pays GET /proxy/echo/resource through the proxy"
SERVER_URL="http://127.0.0.1:$ACTUAL_PORT/proxy/echo/resource" node "$HERE/proxy-client.mjs"
echo "==> proxy conformance PASSED"
