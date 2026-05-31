#!/usr/bin/env bash
# Cross-SDK MCP conformance (reverse): OUR Swift MCP client (MPPMCPConformanceClient) spawns the
# reference mppx `mcp-sdk` SERVER (mcp-server.mjs) over a real stdio transport and pays its
# payment-gated tool with a zero-amount Tempo proof. Our client reads mppx's -32042 challenge,
# builds the credential, and reads back the receipt mppx mints. OFFLINE and deterministic
# (ecrecover, no RPC), same hardening as the other offline conformance jobs.
#
#   Scripts/conformance/run-mcp-reverse.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> building the Swift MCP client (MPPMCPConformanceClient)"
(cd "$REPO" && swift build --product MPPMCPConformanceClient)
BIN="$(cd "$REPO" && swift build --product MPPMCPConformanceClient --show-bin-path)/MPPMCPConformanceClient"
test -x "$BIN" || { echo "client binary not found: $BIN"; exit 1; }

echo "==> running our Swift client against the mppx mcp-sdk server (stdio)"
MPPX_MCP_SERVER="$HERE/mcp-server.mjs" "$BIN"
echo "==> MCP reverse conformance PASSED"
