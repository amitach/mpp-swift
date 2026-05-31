#!/usr/bin/env bash
# Reverse channel conformance: boot OUR Swift server (MPPConformanceServer's /session route,
# backed by SessionMethod + RPCChannelStateProvider), have the reference mppx CLIENT open a
# channel against it, voucher, and close, live on Moderato, then assert it settled.
#
#   Scripts/conformance/run-session-reverse.sh
#
# Live + funded: the server's operator (faucet-funded here) relays/settles on-chain; the
# mppx client funds its own deposit. The server's /session route is gated on MPP_TEMPO_FFI
# (the close builder) + CONFORMANCE_OPERATOR_KEY. Needs Node + network to the testnet.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8799}"
# Fixed operator key for determinism; funded fresh from the faucet each run. Not a real fund.
OPERATOR_KEY="0x$(printf '00%.0s' {1..31})06"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> funding the server operator via the faucet"
OPERATOR_KEY="$OPERATOR_KEY" node "$HERE/fund-operator.mjs"

echo "==> building + booting the Swift session server on port $PORT (FFI-gated)"
(cd "$REPO" && MPP_TEMPO_FFI=1 swift build --target MPPConformanceServer)
LOG="$(mktemp)"
(cd "$REPO" && MPP_TEMPO_FFI=1 CONFORMANCE_OPERATOR_KEY="$OPERATOR_KEY" PORT="$PORT" \
  swift run MPPConformanceServer) >"$LOG" 2>&1 &
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

echo "==> running the mppx reference client against our /session"
SERVER_URL="http://127.0.0.1:$ACTUAL_PORT/session" node "$HERE/session-reverse-client.mjs"
echo "==> reverse session conformance PASSED"
