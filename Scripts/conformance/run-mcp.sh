#!/usr/bin/env bash
# Cross-SDK MCP conformance (forward): the reference mppx `mcp-sdk` CLIENT pays OUR Swift MCP
# server (MPPMCPConformanceServer), which the Node client spawns over a real stdio transport.
# The mppx client pays the zero-amount Tempo proof 402 our server issues and reads back the
# receipt our server mints. OFFLINE and deterministic (ecrecover, no RPC), same hardening as the
# other offline conformance jobs: no secrets, npm ci --ignore-scripts against the lockfile.
#
#   Scripts/conformance/run-mcp.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

echo "==> installing harness deps (pinned, no install scripts)"
if [ -f "$HERE/package-lock.json" ]; then
  (cd "$HERE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
else
  (cd "$HERE" && npm install --ignore-scripts --no-audit --no-fund --loglevel=error)
fi

echo "==> building the Swift MCP server (MPPMCPConformanceServer)"
(cd "$REPO" && swift build --product MPPMCPConformanceServer)
BIN="$(cd "$REPO" && swift build --product MPPMCPConformanceServer --show-bin-path)/MPPMCPConformanceServer"
test -x "$BIN" || { echo "server binary not found: $BIN"; exit 1; }

echo "==> running the mppx mcp-sdk client against it (stdio)"
SWIFT_MCP_SERVER="$BIN" node "$HERE/mcp-client.mjs"
echo "==> MCP conformance PASSED"
