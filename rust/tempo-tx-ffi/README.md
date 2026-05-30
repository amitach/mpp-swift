# tempo-tx-ffi

The Tempo `0x76` transaction builder for mpp-swift: the one piece we deliberately do
not build in Swift. Swift could encode it, but the format is Tempo-specific and
evolving, so this crate builds, signs, and RLP-encodes the bespoke Tempo escrow
transactions (channel `open` / `topUp` / `close`) by binding Tempo's own
`tempo-primitives` crate. The output is byte-identical to the chain's canonical
implementation, and an upgrade is a version bump rather than a hand-maintained Swift
port we would have to keep in sync.

It is **not** a SwiftPM product. It is a Rust crate, exposed to Swift over an FFI
boundary (UniFFI + an Apple xcframework / Linux `.so`), linked into an **opt-in**
product so only a consumer that builds Tempo transactions links it (see "Isolation"
below). See [../../ARCHITECTURE.md](../../ARCHITECTURE.md) and the supply-chain
section of [../../SECURITY.md](../../SECURITY.md).

## Why a Rust FFI (not Swift)

The `0x76` format is bespoke to Tempo, evolving, and has no Swift implementation.
Hand-rolling it is the highest-drift, most dangerous work in the project (a wrong
byte is a broken or rejected payment). Binding `tempo-primitives` - the same library
the chain and the reference Rust SDK use - makes our transactions provably match the
canonical format and reduces upgrades to a version bump. Only *building a
transaction* needs this crate; reads, signatures, and the whole protocol flow stay
in Swift (see ARCHITECTURE.md).

## Isolation (only linked when you build Tempo transactions)

This crate is needed **only by a consumer that builds Tempo channel transactions** -
a wallet. A non-Tempo consumer, or a Tempo *server* that only verifies vouchers and
reads channel state, must not link the Rust binary at all. That is enforced
structurally, not by convention:

1. **Module graph.** The Swift wrapper that calls this crate (the
   `TempoCloseTxBuilder` conformer) lives in its **own opt-in SwiftPM product**,
   which is the only target that depends on the FFI binary. `MPPCore` / `MPPClient` /
   `MPPServer` / `MPPTempo` / `MPPTempoServer` do not depend on it, so a consumer
   that does not explicitly add the FFI product links zero Rust.
2. **The seam.** `MPPTempo` defines only the `TempoCloseTxBuilder` protocol;
   `RPCChannelStateProvider` takes a conformer **injected**. It references the
   protocol, never this crate - so the FFI is opt-in at construction time too. A
   server that never settles on-chain simply passes no builder.
3. **A guard.** A check keeps the core/server products from transitively pulling the
   FFI binary, so a future refactor cannot silently wire it into everyone.

## Build and test

Needs a Rust toolchain `>= 1.93` (the `tempo-primitives` MSRV):

```sh
rustup update stable
cargo test     # builds (clones tempo + compiles the tree) and runs the byte-golden test
cargo audit    # scans the dependency tree against the RustSec advisory DB
```

The first build is slow (it git-clones the tempo monorepo and compiles a large tree
incl. `revm`). CI runs `cargo test` on macOS and Linux and `cargo audit` once.

## Pinning and reproducibility

- `tempo-primitives` is pinned to an **exact git tag** (`@1.8.0`); the full
  transitive tree is locked in the committed `Cargo.lock`.
- `default-features = false` keeps the build **pure Rust** (no `c-kzg`/`blst` C
  deps), so it cross-compiles cleanly to an xcframework + `.so`.
- The golden test (`close_tx_golden_bytes`) locks the exact output and is the
  detector for a format change or a dependency bump that alters the bytes.

## Upgrading `tempo-primitives`

1. Bump the `tag` in `Cargo.toml`, run `cargo update -p tempo-primitives`.
2. `cargo test` - if the golden bytes are unchanged, the format did not change; if
   they differ, inspect the change and regenerate the golden deliberately.
3. `cargo audit`, then the live-Moderato check (the authoritative on-chain test).

We pin an exact tag and move deliberately; we do not float to "latest".
