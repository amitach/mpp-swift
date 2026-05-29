#!/usr/bin/env bash
# Reverse cross-SDK conformance: boot OUR Swift server (MPPConformanceServer, backed
# by TempoProofVerifier), have the reference mppx CLIENT pay it over real HTTP, and
# assert the proof verified. The mirror of run.sh (which drives our client against
# the mppx server). Offline and deterministic: the zero-amount proof is ecrecover,
# no Tempo RPC. Dev-only; the Swift server is an internal executable target.
#
#   Scripts/conformance/run-reverse.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8799}"

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

echo "==> the mppx client pays our server"
SERVER_URL="http://127.0.0.1:$PORT/proof" node "$HERE/reverse-client.mjs"
echo "==> reverse conformance PASSED"
