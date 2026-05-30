#!/usr/bin/env bash
# Forward channel conformance: boot the mppx reference SESSION server (live on Moderato),
# drive our Swift TempoChannelMethod against it (open -> voucher -> close), tear it down.
#
#   Scripts/conformance/run-session.sh
#
# Live + funded: the mppx server relays/settles on Moderato (42431) with a faucet-funded
# operator, and the Swift client funds its own channel deposit from the faucet. Gated on
# MPP_CONFORMANCE_SESSION_URL (the test) and MPP_TEMPO_FFI (the client's open-tx builder),
# so `swift test` on its own stays hermetic. Needs Node + network to the testnet.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8790}"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> booting mppx session server on port $PORT (funds its operator via the faucet first)"
LOG="$(mktemp)"
PORT="$PORT" node "$HERE/session-server.mjs" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

# Faucet funding + mining can take a while, so wait up to ~120s for "listening".
for _ in $(seq 1 600); do
  grep -q "listening" "$LOG" 2>/dev/null && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server failed to start:"; cat "$LOG"; exit 1; fi
  sleep 0.2
done
grep -q "listening" "$LOG" || { echo "server did not become ready:"; cat "$LOG"; exit 1; }
cat "$LOG"

ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"

echo "==> running the gated Swift session conformance test (FFI + live Moderato)"
cd "$REPO"
MPP_TEMPO_FFI=1 \
MPP_CONFORMANCE_SESSION_URL="http://127.0.0.1:$ACTUAL_PORT/session" \
  swift test --filter ConformanceSessionTests
echo "==> session conformance PASSED"
