#!/usr/bin/env bash
# Cross-SDK MCP conformance (reverse): OUR Swift MCP client (MPPMCPConformanceClient) spawns the
# reference mppx `mcp-sdk` SERVER (mcp-server.mjs) over a real stdio transport and pays its
# payment-gated tool with a zero-amount Tempo proof.
#
# EXPECTED TO FAIL while the MCP SDK pin is swift-sdk #291. mppx emits -32042 with
# data.challenges; that decoder maps every -32042 to URL elicitation and drops
# data.challenges, so MCPPaymentClient never sees the challenge. The binding still emits
# the same wire codes (do not "fix" this by changing -32042). Not run in CI until the SDK
# preserves data.challenges on -32042. Forward conformance (run-mcp.sh) still applies:
# mppx reads our raw JSON-RPC frame.
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
