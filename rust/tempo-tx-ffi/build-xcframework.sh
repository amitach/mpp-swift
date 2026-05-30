#!/usr/bin/env bash
# Packages the tempo-tx-ffi Rust staticlib + its C header into an Apple
# `.xcframework` that SwiftPM consumes via a `binaryTarget`, and refreshes the
# committed UniFFI-generated Swift bindings. This is the build-in-CI artifact step
# (locked decision #3): nothing binary is committed; the xcframework is produced
# from the pinned `tempo-primitives` source on every run.
#
# Apple slices built (the realistic FFI consumer platforms; a wallet building 0x76
# txs runs on macOS / iOS):
#   - macOS:        universal (arm64 + x86_64), lipo'd
#   - iOS device:   arm64
#   - iOS simulator: universal (arm64 + x86_64), lipo'd
# tvOS / watchOS / visionOS slices are out of scope (no FFI consumer there yet); a
# build for those platforms simply must not depend on MPPTempoFFI. The Linux `.so`
# uses a different mechanism (not an xcframework) and lands in its own slice.
#
# Fast local iteration: set TEMPO_FFI_MACOS_ONLY=1 to build only the macOS slice (the
# gated `swift test` only links that one); CI always builds the full Apple set.
#
# Outputs (both gitignored except the committed, drift-checked bindings):
#   artifacts/TempoTxFFI.xcframework          - the binaryTarget
#   Sources/MPPTempoFFI/Generated/...swift    - drift-checked against the committed copy in CI
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)

PROFILE=${TEMPO_FFI_PROFILE:-debug}
CARGO_PROFILE_FLAG=""
[ "$PROFILE" = "release" ] && CARGO_PROFILE_FLAG="--release"
LIBNAME=libtempo_tx_ffi

# Build ONLY the staticlib for one target triple; echo the path to the produced .a.
# `cargo rustc --lib --crate-type staticlib` skips the crate's cdylib/rlib, so a cross
# target never links a `cdylib` against its SDK (the xcframework consumes only the .a);
# faster, and no iOS-dylib SDK-link fragility. The host build (for bindgen) still needs
# the cdylib, so it stays a plain `cargo build`.
build_target() {
  local target="$1"
  rustup target add "$target" >/dev/null
  # shellcheck disable=SC2086
  cargo rustc --lib --target "$target" --crate-type staticlib $CARGO_PROFILE_FLAG >&2
  echo "target/$target/$PROFILE/$LIBNAME.a"
}

# lipo several single-arch .a files into one fat archive; echo its path.
make_fat() {
  local out="$1"; shift
  mkdir -p "$(dirname "$out")"
  lipo -create "$@" -output "$out"
  echo "$out"
}

echo "==> host build (drives bindgen AND is reused as the macOS host-arch slice)"
# bindgen must INTROSPECT a host-runnable library, so build with no --target (a
# cross-compiled slice only works when its triple happens to match the host, which
# breaks once we add x86_64 / iOS arches). This same build IS the macOS host-arch
# staticlib, so the macOS universal slice reuses it rather than compiling the host arch
# twice; bindgen and that slice then can never come from divergent builds.
# shellcheck disable=SC2086
cargo build $CARGO_PROFILE_FLAG >&2
HOST_TRIPLE=$(rustc -vV | sed -n 's/^host: //p')
HOST_DYLIB="target/$PROFILE/$LIBNAME.dylib"
HOST_STATIC="target/$PROFILE/$LIBNAME.a"
rm -rf target/bindings
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "$HOST_DYLIB" --language swift --out-dir target/bindings

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

echo "==> build macOS slice (universal: arm64 + x86_64)"
# Reuse the host build for its arch; build only the other macOS arch. (xcodebuild is
# macOS-only, so the host is always *-apple-darwin; the fallback builds both explicitly
# for any unexpected host.)
case "$HOST_TRIPLE" in
  aarch64-apple-darwin) MACOS_OTHER=$(build_target x86_64-apple-darwin) ;;
  x86_64-apple-darwin) MACOS_OTHER=$(build_target aarch64-apple-darwin) ;;
  *) echo "unexpected host $HOST_TRIPLE: the xcframework build is macOS-only" >&2; exit 1 ;;
esac
MACOS_FAT=$(make_fat "target/universal/macos/$PROFILE/$LIBNAME.a" "$HOST_STATIC" "$MACOS_OTHER")

XCF_ARGS=(-library "$MACOS_FAT" -headers "$HDRS")

if [ "${TEMPO_FFI_MACOS_ONLY:-}" != "1" ]; then
  echo "==> build iOS device slice (arm64)"
  IOS_DEVICE=$(build_target aarch64-apple-ios)
  XCF_ARGS+=(-library "$IOS_DEVICE" -headers "$HDRS")

  echo "==> build iOS simulator slice (universal: arm64 + x86_64)"
  IOS_SIM_ARM=$(build_target aarch64-apple-ios-sim)
  IOS_SIM_X64=$(build_target x86_64-apple-ios)
  IOS_SIM_FAT=$(make_fat "target/universal/ios-sim/$PROFILE/$LIBNAME.a" "$IOS_SIM_ARM" "$IOS_SIM_X64")
  XCF_ARGS+=(-library "$IOS_SIM_FAT" -headers "$HDRS")
fi

echo "==> create TempoTxFFI.xcframework"
XCF="$REPO_ROOT/artifacts/TempoTxFFI.xcframework"
mkdir -p "$REPO_ROOT/artifacts"
rm -rf "$XCF"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$XCF"

echo "==> refresh committed Swift bindings + C header"
GEN="$REPO_ROOT/Sources/MPPTempoFFI/Generated"
mkdir -p "$GEN"
cp target/bindings/tempo_tx_ffi.swift "$GEN/tempo_tx_ffi.swift"
# The C header is committed for the Linux CTempoTxFFI module (Apple gets it from the
# xcframework instead). It is target-independent, so the macOS-generated copy is correct
# for Linux; both committed files are drift-checked in CI against this regeneration.
cp target/bindings/tempo_tx_ffiFFI.h "$REPO_ROOT/Sources/CTempoTxFFI/include/tempo_tx_ffiFFI.h"

echo "==> done: $XCF"
