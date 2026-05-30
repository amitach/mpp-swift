#!/usr/bin/env bash
# Builds the tempo-tx-ffi staticlib for the Linux host into artifacts/linux/, the
# archive MPPTempoFFI links on Linux (where SwiftPM has no library binaryTarget, so the
# Apple xcframework path does not apply; build-xcframework.sh is macOS-only).
#
# Only the staticlib is built (`cargo rustc --lib --crate-type staticlib`): no cdylib,
# and the UniFFI Swift bindings + C header are committed (generated on macOS by
# build-xcframework.sh, drift-checked there), so Linux does not regenerate them.
#
# Output (gitignored): artifacts/linux/libtempo_tx_ffi.a
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)

PROFILE=${TEMPO_FFI_PROFILE:-debug}
CARGO_PROFILE_FLAG=""
[ "$PROFILE" = "release" ] && CARGO_PROFILE_FLAG="--release"

echo "==> cargo rustc --lib --crate-type staticlib ($PROFILE)"
# shellcheck disable=SC2086
cargo rustc --lib --crate-type staticlib $CARGO_PROFILE_FLAG

TARGET_DIR=${CARGO_TARGET_DIR:-target}
mkdir -p "$REPO_ROOT/artifacts/linux"
cp "$TARGET_DIR/$PROFILE/libtempo_tx_ffi.a" "$REPO_ROOT/artifacts/linux/libtempo_tx_ffi.a"
echo "==> done: $REPO_ROOT/artifacts/linux/libtempo_tx_ffi.a"
