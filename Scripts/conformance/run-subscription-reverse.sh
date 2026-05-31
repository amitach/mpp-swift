#!/usr/bin/env bash
# Reverse subscription conformance: boot OUR Swift server (MPPConformanceServer +
# TempoSubscriptionVerifier), have the reference mppx CLIENT activate a subscription against
# it (sign + present a key authorization), tear it down.
#
#   Scripts/conformance/run-subscription-reverse.sh
#
# OFFLINE: activation settles no transaction, so this needs only Node (no faucet / RPC). A
# PASS means OUR verifier accepted the reference client's signed TempoKeyAuthorization.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8792}"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> building + booting the Swift conformance server on port $PORT"
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
ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"

echo "==> the mppx client activates a subscription against our server"
SERVER_URL="http://127.0.0.1:$ACTUAL_PORT/subscription" node "$HERE/subscription-reverse-client.mjs"
echo "==> reverse subscription conformance PASSED"
