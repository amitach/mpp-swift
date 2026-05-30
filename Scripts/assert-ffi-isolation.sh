#!/usr/bin/env bash
# The dependency-graph GUARD for the Tempo 0x76 FFI isolation.
#
# The Rust shim is opt-in: no NON-FFI product may pull it in. A consumer of MPPCore /
# MPPClient / MPPServer / MPPTempo / MPPTempoServer (etc.) must link ZERO Rust. This
# asserts that as the durable invariant: walk each non-FFI library product's target
# dependency closure and fail if it reaches `MPPTempoFFI` or the `TempoTxFFIBinary`.
#
# This holds in BOTH regimes: pre-publish (MPPTempoFFI is only declared behind the
# MPP_TEMPO_FFI gate, so it is usually absent), and post-publish (MPPTempoFFI is
# always declared with a url+checksum binaryTarget, but nothing else depends on it).
# Checking the closure, not mere presence, is what stays correct once a release is wired.
set -euo pipefail
cd "$(dirname "$0")/.."

# Evaluate the manifest with the from-source gate explicitly OFF (the default consumer
# view). A configured release asset, if any, is still represented as the binaryTarget.
unset MPP_TEMPO_FFI
desc=$(swift package describe --type json)

printf '%s' "$desc" | python3 -c '
import json, sys

d = json.load(sys.stdin)
RUST = {"MPPTempoFFI", "TempoTxFFIBinary", "CTempoTxFFI"}

deps = {t["name"]: t.get("target_dependencies", []) for t in d.get("targets", [])}

def closure(start):
    seen, stack = set(), list(start)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(deps.get(n, []))
    return seen

leaks = []
for p in d.get("products", []):
    if p["name"] == "MPPTempoFFI":
        continue  # the FFI product is allowed to contain Rust; nothing else may.
    reached = closure(p.get("targets", []))
    hit = sorted(reached & RUST)
    if hit:
        leaks.append(p["name"] + " -> " + ", ".join(hit))

if leaks:
    print("::error::FFI isolation broken: a non-FFI product reaches Rust:", file=sys.stderr)
    for line in leaks:
        print("  " + line, file=sys.stderr)
    sys.exit(1)

print("FFI isolation OK: no non-FFI product reaches the Rust FFI in its dependency closure.")
'
