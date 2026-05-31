#!/usr/bin/env bash
# Forward subscription conformance: boot the mppx reference SUBSCRIPTION server, drive our
# Swift TempoSubscriptionMethod against it (sign + present a key authorization), tear it down.
#
#   Scripts/conformance/run-subscription.sh
#
# OFFLINE: subscription activation signs no on-chain transaction, so this needs only Node
# (no faucet / RPC / testnet). A PASS means the reference server accepted OUR signed
# TempoKeyAuthorization. Gated on MPP_CONFORMANCE_SUBSCRIPTION_URL, so `swift test` on its
# own stays hermetic.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8791}"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> booting mppx subscription server on port $PORT"
LOG="$(mktemp)"
PORT="$PORT" node "$HERE/subscription-server.mjs" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT
for _ in $(seq 1 300); do
  grep -q "listening" "$LOG" 2>/dev/null && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server failed to start:"; cat "$LOG"; exit 1; fi
  sleep 0.2
done
grep -q "listening" "$LOG" || { echo "server did not become ready:"; cat "$LOG"; exit 1; }
cat "$LOG"
ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"

echo "==> running the Swift subscription conformance test"
cd "$REPO"
MPP_CONFORMANCE_SUBSCRIPTION_URL="http://127.0.0.1:$ACTUAL_PORT/subscription" \
  swift test --filter ConformanceSubscriptionTests
echo "==> subscription conformance PASSED"
