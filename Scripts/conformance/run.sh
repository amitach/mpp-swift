#!/usr/bin/env bash
# Cross-SDK conformance run: boot the mppx reference server, drive the Swift client
# against it via the MPP_CONFORMANCE_URL-gated test, then tear the server down.
#
#   Scripts/conformance/run.sh            # local self-contained mppx server
#   Scripts/conformance/run.sh --testnet  # mppx server against Moderato (42431)
#
# The Swift test is skipped unless MPP_CONFORMANCE_URL is set, so this script is the
# only thing that needs Node; `swift test` on its own stays pure-Swift.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8788}"
MODE="local"
[ "${1:-}" = "--testnet" ] && MODE="testnet"

echo "==> installing harness deps"
(cd "$HERE" && npm install --no-audit --no-fund --loglevel=error)

echo "==> booting mppx server ($MODE) on port $PORT"
LOG="$(mktemp)"
PORT="$PORT" CONFORMANCE_MODE="$MODE" node "$HERE/server.mjs" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 50); do
  grep -q "listening" "$LOG" 2>/dev/null && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server failed to start:"; cat "$LOG"; exit 1; fi
  sleep 0.2
done
grep -q "listening" "$LOG" || { echo "server did not become ready:"; cat "$LOG"; exit 1; }
cat "$LOG"

echo "==> running the gated Swift conformance test"
cd "$REPO"
MPP_CONFORMANCE_URL="http://127.0.0.1:$PORT/proof" \
  swift test --filter ConformanceProofTests
echo "==> conformance PASSED ($MODE)"
