#!/usr/bin/env bash
# Packages the tempo-tx-ffi Rust staticlib + its C header into an Apple
# `.xcframework` that SwiftPM consumes via a `binaryTarget`, and refreshes the
# committed UniFFI-generated Swift bindings. This is the build-in-CI artifact step
# (locked decision #3): nothing binary is committed; the xcframework is produced
# from the pinned `tempo-primitives` source on every run.
#
# macOS spike: a single arch (aarch64-apple-darwin) for now. x86_64-apple-darwin +
# iOS device/sim arches + the Linux `.so` follow in the next slice; this script gains
# more `-library` legs then.
#
# Outputs (both gitignored):
#   artifacts/TempoTxFFI.xcframework          - the binaryTarget
#   Sources/MPPTempoFFI/Generated/...swift    - drift-checked against the committed copy in CI
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)

TARGET=${TEMPO_FFI_TARGET:-aarch64-apple-darwin}
PROFILE=${TEMPO_FFI_PROFILE:-debug}
CARGO_PROFILE_FLAG=""
[ "$PROFILE" = "release" ] && CARGO_PROFILE_FLAG="--release"

echo "==> rustup target add $TARGET (idempotent)"
rustup target add "$TARGET" >/dev/null

echo "==> cargo build --target $TARGET ($PROFILE)"
# shellcheck disable=SC2086
cargo build --target "$TARGET" $CARGO_PROFILE_FLAG

OUT="target/$TARGET/$PROFILE"
STATIC="$OUT/libtempo_tx_ffi.a"
DYLIB="$OUT/libtempo_tx_ffi.dylib"

echo "==> generate UniFFI Swift bindings"
# bindgen introspects a built library; use the cdylib for the host-runnable bindgen.
rm -rf target/bindings
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "$DYLIB" --language swift --out-dir target/bindings

echo "==> assemble the xcframework headers dir"
# The binaryTarget exposes a clang module named `tempo_tx_ffiFFI` (what the generated
# Swift imports). The xcframework convention wants the map at Headers/module.modulemap.
# Write a minimal map (the bindgen's `use "Darwin"`/_Builtin_* lines are unneeded and
# can fail to resolve inside an xcframework module context).
HDRS=target/xcframework-headers
rm -rf "$HDRS" && mkdir -p "$HDRS"
cp target/bindings/tempo_tx_ffiFFI.h "$HDRS/"
cat > "$HDRS/module.modulemap" <<'EOF'
module tempo_tx_ffiFFI {
    header "tempo_tx_ffiFFI.h"
    export *
}
EOF

echo "==> create TempoTxFFI.xcframework"
XCF="$REPO_ROOT/artifacts/TempoTxFFI.xcframework"
mkdir -p "$REPO_ROOT/artifacts"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$STATIC" -headers "$HDRS" \
  -output "$XCF"

echo "==> refresh committed Swift bindings"
GEN="$REPO_ROOT/Sources/MPPTempoFFI/Generated"
mkdir -p "$GEN"
cp target/bindings/tempo_tx_ffi.swift "$GEN/tempo_tx_ffi.swift"

echo "==> done: $XCF"
