#!/usr/bin/env bash
# Cross-SDK CLI conformance: boot the reference mppx server, then drive the SHIPPED
# `mpp` BINARY against it over real HTTP and assert it settles a zero-amount proof.
#
#   Scripts/conformance/run-cli.sh
#
# The library client already has its own cross-SDK test (run.sh -> ConformanceProofTests).
# This run targets the built executable instead, so it proves the artifact a user installs
# speaks the wire: 402 challenge -> select method -> authorize -> build credential -> re-send
# -> receipt, end to end, against the reference server (not an in-process stub transport).
#
# The zero-amount proof is identity-only (EIP-712 ecrecover), so no Tempo RPC is contacted;
# the run is fully offline and self-contained.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-0}" # 0 => OS-assigned ephemeral port (read back from the server log)

# Any key works: a zero-amount proof attests control of its own wallet. Fixed for
# determinism (the key=1 wallet the Swift conformance suite uses).
KEY1="0x0000000000000000000000000000000000000000000000000000000000000001"

echo "==> building the mpp binary"
cd "$REPO"
swift build --product mpp >/dev/null
MPP="$(swift build --product mpp --show-bin-path)/mpp"
[ -x "$MPP" ] || { echo "mpp binary not found at $MPP"; exit 1; }

echo "==> installing harness deps (pinned, no install scripts)"
# --ignore-scripts blocks postinstall hooks (the main npm install-time attack vector);
# mppx/viem are pure JS so nothing needs a build step. `npm ci` against the committed
# lockfile for a reproducible tree; fall back to `npm install` only if it is absent.
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> booting mppx server on port $PORT"
LOG="$(mktemp)"
PORT="$PORT" CONFORMANCE_MODE="local" node "$HERE/server.mjs" >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LOG"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  grep -q "listening" "$LOG" 2>/dev/null && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "server failed to start:"; cat "$LOG"; exit 1; fi
  sleep 0.2
done
grep -q "listening" "$LOG" || { echo "server did not become ready:"; cat "$LOG"; exit 1; }

# Use the actually-bound port from the log, not the requested one (PORT=0 => ephemeral).
ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"
URL="http://127.0.0.1:$ACTUAL_PORT/proof"
echo "server listening on $ACTUAL_PORT"

# 1) Happy path: the binary settles the zero-amount proof. --max-amount 0 keeps the
#    headless `auto` authorizer bounded (it never silently approves an unbounded spend);
#    --insecure permits the loopback http endpoint.
echo "==> [1/2] mpp pay settles the proof"
set +e
OUT=$(MPP_PRIVATE_KEY="$KEY1" "$MPP" pay "$URL" --approve auto --max-amount 0 --insecure --json)
RC=$?
set -e
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
# The server returns 200 only once the proof verifies (the 402 challenge otherwise), so a
# 200 plus a receipt reference in the envelope is settlement. Assert the top-level --json
# fields (paid:true lives inside the escaped `body` string, not the envelope).
case "$OUT" in
  *'"status":200'*) ;;
  *) echo "FAIL: response status was not 200"; exit 1 ;;
esac
case "$OUT" in
  *'"ok":true'*) ;;
  *) echo "FAIL: --json envelope did not report success"; exit 1 ;;
esac
case "$OUT" in
  *'"reference"'*) ;;
  *) echo "FAIL: no receipt reference in the --json envelope"; exit 1 ;;
esac

# 2) Fail-closed exit-code parity: with no key the binary exits 69 (no payment method),
#    matching the curl-like exit-code contract, rather than silently doing nothing.
echo "==> [2/2] mpp pay with no key exits 69"
set +e
env -u MPP_PRIVATE_KEY -u MPP_STRIPE_SPT \
  "$MPP" pay "$URL" --approve auto --max-amount 0 --insecure >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 69 ] || { echo "FAIL: expected exit 69 (no payment method), got $RC"; exit 1; }

echo "==> CLI conformance PASSED"
