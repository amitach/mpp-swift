#!/usr/bin/env bash
# Reverse subscription conformance, LIVE on Moderato: boot OUR Swift server
# (MPPConformanceServer's /subscription-live route, ActivatingSubscriptionVerifier +
# TempoSubscriptionRenewer over the FFI charge builder), have the reference mppx CLIENT activate
# a subscription against it with a faucet-funded payer, and have OUR server settle period 0
# on-chain (charge-on-activate). A PASS means the mppx client's signed key authorization was
# accepted AND our renewer settled the recurring transferWithMemo on-chain.
#
#   Scripts/conformance/run-subscription-live.sh
#
# Live + funded: the mppx client's payer (the keychain root) is faucet-funded so the
# transferWithMemo moves its TIP-20 to the recipient. Gated on MPP_TEMPO_FFI (the charge
# builder). Needs Node + network to the testnet.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PORT="${PORT:-8795}"
# The mppx subscription client's hardcoded payer key (subscription-reverse-client.mjs); fund it.
PAYER_KEY="0x$(printf '00%.0s' {1..31})09"
# Our server's gas sponsor (fee payer). The access key's per-period spending limit equals the
# charge amount, so the renewer cannot also pay gas from that limit; this faucet-funded account
# signs the fee-payer signature and pays gas instead. Fixed key for determinism, funded each run.
FEE_PAYER_KEY="0x$(printf '00%.0s' {1..31})0a"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> funding the mppx client payer via the faucet (native gas + TIP-20)"
OPERATOR_KEY="$PAYER_KEY" node "$HERE/fund-operator.mjs"

echo "==> funding our gas sponsor (fee payer) via the faucet (native gas)"
OPERATOR_KEY="$FEE_PAYER_KEY" node "$HERE/fund-operator.mjs"

echo "==> building + booting the Swift conformance server on port $PORT (FFI-gated)"
(cd "$REPO" && MPP_TEMPO_FFI=1 swift build --target MPPConformanceServer)
LOG="$(mktemp)"
(cd "$REPO" && MPP_TEMPO_FFI=1 CONFORMANCE_VERBOSE=1 PORT="$PORT" \
  CONFORMANCE_FEE_PAYER_KEY="$FEE_PAYER_KEY" \
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

ACTUAL_PORT=$(grep -oE 'listening http://127\.0\.0\.1:[0-9]+' "$LOG" | grep -oE '[0-9]+$')
ACTUAL_PORT="${ACTUAL_PORT:-$PORT}"

echo "==> running the mppx reference client against our /subscription-live"
SERVER_URL="http://127.0.0.1:$ACTUAL_PORT/subscription-live" node "$HERE/subscription-reverse-client.mjs"

# The client PASSes only on a 200, which our server returns only after the on-chain charge
# settled (a revert throws in verify -> 402, not 200). Confirm the charge in the server log.
echo "==> server charge log:"
grep -E "ACTIVATED \(subscription-live\)|CHARGED \(subscription-live\)" "$LOG" || {
  echo "no on-chain charge logged:"; cat "$LOG"; exit 1; }
grep -q "CHARGED (subscription-live) renewed" "$LOG" || {
  echo "renewal did not settle on-chain:"; cat "$LOG"; exit 1; }
echo "==> reverse subscription LIVE conformance PASSED"
