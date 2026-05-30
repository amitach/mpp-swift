#!/usr/bin/env bash
# The dependency-graph GUARD for the Tempo 0x76 FFI isolation.
#
# The Rust shim is opt-in: it must NEVER appear in the default package graph, so a
# consumer who depends on MPPCore / MPPClient / MPPServer / MPPTempo (or anything
# else) pulls ZERO Rust. This asserts that structurally: with the `MPP_TEMPO_FFI`
# gate UNSET, no FFI target or product exists in the resolved manifest. If wiring
# ever leaks the FFI into the default graph, this fails the build.
set -euo pipefail
cd "$(dirname "$0")/.."

# Evaluate the manifest with the gate explicitly OFF (the default consumer view).
unset MPP_TEMPO_FFI
desc=$(swift package describe --type json)

leaked=$(printf '%s' "$desc" | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = [t["name"] for t in d.get("targets", [])] + [p["name"] for p in d.get("products", [])]
leaked = [n for n in names if "TempoTxFFI" in n or n == "MPPTempoFFI"]
print(",".join(sorted(set(leaked))))
')

if [ -n "$leaked" ]; then
  echo "::error::FFI isolation broken: the default package graph contains [$leaked]." >&2
  echo "The Rust 0x76 builder must stay behind the MPP_TEMPO_FFI gate so non-FFI" >&2
  echo "consumers link no Rust. Keep MPPTempoFFI / TempoTxFFIBinary out of the" >&2
  echo "default targets/products." >&2
  exit 1
fi

echo "FFI isolation OK: no Rust target/product in the default package graph."
