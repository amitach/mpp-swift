#!/usr/bin/env bash
# Builds tempo-tx-ffi, generates the UniFFI Swift bindings, and runs a Swift smoke
# test that calls the FFI and asserts the byte-exact golden 0x76 close tx. This is
# the end-to-end proof that Swift -> UniFFI -> Rust -> tempo-primitives works and
# stays byte-identical to the in-crate Rust golden. Runs on macOS and Linux.
#
# The xcframework / Linux .so packaging + the SwiftPM binaryTarget wiring build on
# the same artifacts; this script is the integration's reproducible, CI-runnable core.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> cargo build (staticlib + cdylib + bindgen)"
cargo build

case "$(uname -s)" in
  Darwin) LIB=target/debug/libtempo_tx_ffi.dylib ;;
  *)      LIB=target/debug/libtempo_tx_ffi.so ;;
esac

echo "==> generate Swift bindings"
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "$LIB" --language swift --out-dir target/bindings

echo "==> compile + run the Swift FFI smoke test"
out=$(mktemp -d)
# Link the STATIC archive by full path (not -l, which would prefer the .dylib and
# leave the binary needing it on the loader path at runtime). A self-contained,
# dylib-free binary that runs anywhere.
case "$(uname -s)" in
  Darwin) STATIC=target/debug/libtempo_tx_ffi.a; SYS=(-framework Security -framework CoreFoundation -framework SystemConfiguration) ;;
  *)      STATIC=target/debug/libtempo_tx_ffi.a; SYS=() ;;
esac
swiftc -I target/bindings \
  -Xcc -fmodule-map-file=target/bindings/tempo_tx_ffiFFI.modulemap \
  target/bindings/tempo_tx_ffi.swift swift-smoke/main.swift \
  "$STATIC" "${SYS[@]}" \
  -o "$out/ffi_smoketest"
"$out/ffi_smoketest"
