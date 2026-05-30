# PR-E.1c step 2a: SwiftPM links the Rust 0x76 builder (macOS spike)

Running notes. Step 1 (#64) proved Swift -> UniFFI -> Rust end to end via a standalone
`swiftc` smoke binary. Step 2a proves the part the smoke binary did **not**: that
**SwiftPM itself** (`swift build` / `swift test`) can link the Rust staticlib through a
`binaryTarget` and reach the same byte-exact golden `0x76` close tx, exposed in Swift as a
type conforming to the existing `TempoCloseTxBuilder` seam.

## Scope of this slice (deliberately bounded)
- macOS, single arch (`aarch64-apple-darwin`) only. The plan flags xcframework packaging as
  "fiddly; spike macOS before all arches." x86_64 + iOS arches + the Linux `.so` are step 2b.
- Only the **close** op (the seam we already have). `buildOpenTx` / `buildTopUpTx` follow.

## Design decisions (and why)

### 1. binaryTarget = an `.xcframework` built in CI, not a committed blob
The Rust staticlib (`libtempo_tx_ffi.a`) + its C header/modulemap (`tempo_tx_ffiFFI`) are
packaged into `TempoTxFFI.xcframework` by `rust/tempo-tx-ffi/build-xcframework.sh`, written to
a **gitignored** `artifacts/` dir. Matches locked decision #3 (build-in-CI for provenance, no
binary checked in). The eventual *published* form is a GitHub-release-asset `url:`+`checksum:`
binaryTarget (always-declared, downloaded); out of scope here; noted as a follow-up.

### 2. The whole FFI surface is env-gated behind `MPP_TEMPO_FFI`
`Package.swift` only declares the binaryTarget + `MPPTempoFFI` product/target + its test target
when `MPP_TEMPO_FFI` is set. Rationale: a local-path `binaryTarget` whose `.xcframework` is
absent fails *every* `swift build` (which builds all targets), even for a consumer who only
wants `MPPCore`. Env-gating means the **default** build (every consumer, and all the existing
CI jobs) never references the artifact and pulls **zero Rust**, which is exactly the isolation
guarantee, now structurally provable rather than asserted. The dedicated FFI CI job sets the
env and builds the xcframework first.
- Tradeoff: until we ship a release-asset URL binaryTarget, a consumer who *wants* the FFI must
  build it from source with the env set. Acceptable pre-release; the URL form removes it later.

### 3. The UniFFI-generated Swift bindings are COMMITTED source, drift-checked in CI
`Sources/MPPTempoFFI/Generated/tempo_tx_ffi.swift` is committed (reviewable Swift, not a
binary). The C header + modulemap are NOT committed; they ride inside the xcframework, which
provides the `tempo_tx_ffiFFI` clang module the generated Swift imports. CI regenerates the
bindings and `git diff --exit-code`s them against the committed copy, so they can never silently
drift from the pinned `tempo-primitives@1.8.0` crate. Only the compiled `.a` is build-in-CI.

### 4. The Swift wrapper: `FFITempoCloseTxBuilder` conforms to `TempoCloseTxBuilder`
The seam is `buildCloseTransaction(voucher:signature:escrow:chainID:) async throws -> Data`. The
raw FFI needs more: nonce, gas/fee params, the sender private key. The wrapper holds the signing
key + a `FeeParameters` value and is injected with a `nonceProvider` closure
(`@Sendable (EthereumAddress) async throws -> UInt64`). It derives the sender address from the
private key (MPPEVM: secp256k1 pubkey -> Keccak -> address), reads the nonce via the provider,
then calls the FFI. **Deferred:** sourcing fee params from Tempo's gas/fee oracle over RPC (the
plan's open question: attodollar prices, TIP-20 fee tokens); that lands in PR-F with the live
settle e2e. Here fee params are injected, so the wrapper is fully testable with a stub nonce
provider and produces the byte-exact golden tx.

## Verification plan
- `MPP_TEMPO_FFI=1 swift test --filter MPPTempoFFI`: golden bytes through the typed wrapper AND
  through the seam conformer (stub nonce provider, fixed key/fee = the same fixed inputs as the
  Rust `close_tx_golden_bytes` test) assert the identical 351-byte hex.
- Default `swift build` / `swift test` (gate off): must resolve and pass with no Rust target in
  the graph (the isolation guarantee). CI keeps a gate-off leg.

## Open / deferred
- buildOpenTx / buildTopUpTx -> after close is wired.
- RPC-sourced fee params (gas/fee oracle) -> PR-F.
- Published release-asset (url+checksum) binaryTarget -> packaging follow-up.

---

# Step 2b: all Apple arches (PR feat/ws10-ffi-apple-arches)

The xcframework now carries every realistic Apple FFI-consumer slice, not just the
macOS-arm64 spike:
- **macOS**: universal (arm64 + x86_64), lipo'd.
- **iOS device**: arm64.
- **iOS simulator**: universal (arm64 + x86_64), lipo'd.

tvOS / watchOS / visionOS are out of scope (no FFI consumer there; such a build just
must not depend on `MPPTempoFFI`). Verified each slice with the xcframework Info.plist
(`SupportedPlatform` / `SupportedPlatformVariant`) plus `vtool`/`lipo` per slice; the iOS
device objects carry `LC_VERSION_MIN_IPHONEOS` (genuinely iOS, not mislabeled macOS).

**Cross-bindgen fix (Devin #65 carry-forward).** uniffi-bindgen must introspect a
HOST-runnable library. Step 2a generated bindings from the cross-compiled slice, which
only worked because the target triple equalled the host on the arm64 spike. The script
now builds a host-native dylib with no `--target` purely for bindgen, independent of
which arches it packages. Binding drift against the committed copy stays zero.

**Build cost.** Five arch compiles of the revm tree (~30s each cold) -> the rust-ffi
macOS CI leg goes from ~40s to ~2min; it is the non-required job, so acceptable. Devs
can `TEMPO_FFI_MACOS_ONLY=1 build-xcframework.sh` for fast local iteration (the gated
`swift test` only links the macOS slice).

CI: no workflow change needed; the macOS rust-ffi job already calls
`build-xcframework.sh`, which now `rustup target add`s the iOS/x86_64 targets itself and
uses the macos-15 runner's bundled iOS SDKs. Drift-check + gated test steps unchanged.

## Still deferred after 2b
- buildOpenTx / buildTopUpTx; RPC fee oracle (PR-F); published release-asset binaryTarget.

---

# Step 2c: Linux (PR feat/ws10-ffi-linux)

SwiftPM has NO library `binaryTarget` on Linux (only `.xcframework` / `.artifactbundle`),
so Linux cannot mirror the Apple xcframework path. Approach:
- **`CTempoTxFFI`** C target: the committed (drift-checked) C header + a `module.modulemap`
  exposing the `tempo_tx_ffiFFI` clang module the generated Swift imports. On Apple that
  module comes from the xcframework; on Linux it comes from this target. A one-line
  `shim.c` keeps it a buildable (not headers-only) target. The header is target-independent,
  so build-xcframework.sh (macOS) generates + commits it for both platforms.
- **`MPPTempoFFI` on Linux** links `libtempo_tx_ffi.a` directly via
  `linkerSettings.unsafeFlags` (`-L artifacts/linux -ltempo_tx_ffi` + the native libs from
  `rustc --print native-static-libs`: `-lm -ldl -lpthread -lrt -lutil -lgcc_s`; `-lc` is
  already on the Swift link line). `Package.swift` branches `#if os(Linux)` vs the Apple
  binaryTarget.
- **`build-linux-lib.sh`** builds the staticlib (no cdylib) into `artifacts/linux/`.
- **CI**: a new non-required `linux-ffi` job in the swift container (installs Rust +
  build-essential, builds the `.a`, runs the gated golden test). The macOS drift-check now
  also covers the committed C header.

**unsafeFlags caveat:** they make the package non-consumable as a *remote* dependency on
Linux, which is fine while the env gate already precludes remote consumption pre-release;
the release-asset stage removes both the gate and the unsafeFlags.

**Verified locally in the pinned CI swift container (Docker):** built the Linux `.a`
(351MB), and `MPP_TEMPO_FFI=1 swift test --filter MPPTempoFFITests` links it through
`CTempoTxFFI` + the seam and passes all 3 golden tests. The macOS path still passes and is
drift-clean. (Could not test Linux on the macOS dev host directly, so this was the de-risk.)

## Still deferred after 2c
- RPC fee oracle (PR-F); published release-asset binaryTarget.

---

# Step 2d: open + topUp builders (PR feat/ws10-ffi-open-topup)

Completes the channel-bookend API so the first published release asset has the full
builder set. Adds `build_open_tx` / `build_top_up_tx` to the Rust shim + their UniFFI
exports + Swift wrapper methods.

**Authoritative ABI (verified at source in mppx 0.6.28, the byte-parity reference):**
`escrow.abi.ts` + the client builder `ChannelOps.ts`. open and topUp are each a **two-call
`0x76` tx**, NOT single calls (the escrow pulls tokens via transferFrom, so each prepends
an ERC-20 `approve`):
- open: `[ approve(escrow, deposit) on token, open(payee, token, deposit, salt,
  authorizedSigner) on escrow ]`
- topUp: `[ approve(escrow, amount) on token, topUp(channelId, amount) on escrow ]`
- ABI subtlety: `topUp.additionalDeposit` is **uint256** (open.deposit / close.cumulative
  are uint128). Got this right; the golden would have been wrong otherwise.
See memory `reference_tempo_escrow_write_abi`.

**Byte-parity verification (beyond the RFC-6979 self-consistency golden):** each builder
test asserts, independently of the `sol!` path, that the tx contains the **canonical
ERC-20 approve selector `0x095ea7b3`** (a globally-known constant, so not circular) plus
the keccak-recomputed open/topUp selectors, in the right call order (approve before the
escrow call). That catches a wrong ABI/selector/order, which a self-consistency golden
alone cannot. The live-Moderato e2e (PR-F) remains the authoritative on-chain check.

**Right-primitive (not a parallel abstraction):** generalized the shipped
`FFITempoCloseTxBuilder` -> **`FFITempoTxBuilder`** with `buildOpen` / `buildTopUp` /
`buildClose` on one builder (they share the held key + fee + nonce machinery), still
conforming to the `TempoCloseTxBuilder` seam for the server's settle path. Rename is safe
pre-release (env-gated, no external consumers). `open`'s inputs are grouped into
`TempoOpenParameters` (kept the method under the 5-arg lint limit and reads better).

**Rust refactor:** extracted `build_signed_tx(calls)` + a `call()` helper so close/open/
topUp share the sign/encode path (the close golden is unchanged, proving the refactor is
byte-preserving).

**Verified:** cargo test (6 Rust goldens incl. structural), clippy clean; macOS gated
`swift test` (5, incl. open/topUp goldens); Linux in the pinned CI container (rebuilt the
`.a` for the new symbols, all 5 pass); swiftformat/swiftlint/em-dash clean.

## Still deferred after 2d
- RPC fee oracle (gas/fee params over RPC) + live Moderato settle/open e2e -> PR-F.
- Published release-asset url+checksum binaryTarget (lets an external consumer install
  the FFI without the env gate) -> the "publish" step.
