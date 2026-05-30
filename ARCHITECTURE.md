# Architecture

mpp-swift implements the Machine Payments Protocol (MPP, the HTTP 402 "Payment"
scheme) as a set of focused SwiftPM products plus one isolated Rust FFI crate. This
document explains how the pieces fit, why the boundaries are where they are, and how
a payment flows end to end.

## Module layering

Products depend downward only; a consumer pulls just what it needs. Each product's
actual SwiftPM dependencies (verified against `Package.swift`):

| Product | Depends on (other MPP products) | Purpose |
|---|---|---|
| `MPPCore` | (none) | wire/data types: Challenge, Credential, Receipt, JCS, Amount, ProblemDetails. No crypto, no network |
| `MPPBodyDigest` | (none) | RFC 9530 Content-Digest (swift-crypto) |
| `MPPEVM` | (none) | EVM message-signing (pure Swift): Keccak-256, secp256k1 signer, EIP-712 proof/voucher, channel id, 0x-hex |
| `MPPClient` | `MPPCore` | the 402 client flow + the `MPPHTTPTransport` seam + URLSession |
| `MPPServer` | `MPPCore`, `MPPBodyDigest` | framework-agnostic 402 middleware: challenge mint/verify, replay, the verify pipeline |
| `MPPDiscovery` | `MPPCore` | OpenAPI x-payment-info parse/emit |
| `MPPTempo` | `MPPCore`, `MPPEVM`, `MPPClient` | Tempo rail: EVMRPC, TempoEscrow (getChannel read), ChannelAmount, OnChainChannel, the `TempoCloseTxBuilder` seam, the proof charge method |
| `MPPTempoServer` | `MPPTempo`, `MPPCore`, `MPPEVM`, `MPPServer` | Tempo SERVER side: proof verify, the 4-action SessionMethod, ChannelStore, RPCChannelStateProvider |

`MPPCore`, `MPPBodyDigest`, and `MPPEVM` are **independent roots** (no inter-MPP
dependencies); `MPPEVM` in particular is standalone EVM crypto and does not depend on
`MPPCore`. The rails compose them: `MPPTempo` = Core + EVM + Client, and
`MPPTempoServer` adds Server.

Separately, **`rust/tempo-tx-ffi`** is a Rust crate that builds + signs + RLP-encodes
the bespoke Tempo `0x76` transaction by binding Tempo's own `tempo-primitives`. It is
packaged into a `TempoTxFFI` xcframework and reached from Swift over a UniFFI boundary
by the **opt-in `MPPTempoFFI`** product (see below).

A non-EVM consumer (e.g. a future Stripe rail, or pure client/server/MCP) pulls
**none** of `MPPEVM`/`MPPTempo` and **no Rust**.

## The two-layer EVM split

EVM work divides into two very different crypto surfaces, kept apart on purpose:

1. **Message-signing layer - pure Swift (`MPPEVM`).** Small fixed EIP-712 structs
   (the zero-amount proof, the session voucher) signed with vetted Swift libraries
   (`swift-secp256k1` over Bitcoin Core's `libsecp256k1`; Keccak via `CryptoSwift`).
   No Rust.
2. **Transaction layer - Rust FFI (`rust/tempo-tx-ffi`).** The bespoke Tempo `0x76`
   transaction (channel open/topUp/close) is an evolving, chain-specific format with
   no Swift implementation. Rather than hand-roll it (drift-prone, and a wrong byte
   is a broken payment), we bind Tempo's **own** `tempo-primitives` crate so our
   output is byte-identical to the chain's canonical implementation.

## What needs the FFI, and what does not

This is the load-bearing distinction. **The Rust FFI is needed only to *build* a
`0x76` transaction.** Everything else is Swift.

| Operation | Layer | Needs the Rust FFI? |
|---|---|---|
| Sign / verify a zero-amount proof | MPPEVM (Swift) | no |
| Sign / verify a session voucher | MPPEVM (Swift) | no |
| Read channel state (`eth_call getChannel`) | MPPTempo (Swift) | no |
| Broadcast / poll / read over JSON-RPC | MPPTempo `EVMRPC` (Swift) | no |
| The whole 402 flow, the session server | MPPCore/Server (Swift) | no |
| **Open / topUp / close / settle a channel** | builds a `0x76` tx | **yes** |

Consequences:

- A **payment server / verifier** never builds a transaction, so it runs with **no
  Rust toolchain and no FFI binary**.
- A **wallet** (e.g. Kapsicum, which opens and closes its own channels) ships the FFI
  binary - but only invokes it at the channel bookends; the frequent operations
  (signing vouchers, reading state) stay native Swift.

## The on-chain vertical (MPPTempo / MPPTempoServer)

The blob-free Swift plumbing, all merged:

- **`EVMRPC`**: a minimal JSON-RPC client over the shared `MPPHTTPTransport` seam:
  `eth_call`, `eth_sendRawTransaction`, `eth_getTransactionReceipt`,
  `eth_getTransactionCount`, `eth_estimateGas`, `eth_gasPrice`. TLS-enforced
  (`TransportSecurity`, shared with the 402 flow), fail-closed parsing.
- **`TempoEscrow`**: encodes the `getChannel(bytes32)` view call and decodes its
  eight ABI words into an **`OnChainChannel`** (read path; no FFI).
- **`RPCChannelStateProvider`** (`ChannelStateProvider`) - `channelState` reads via
  `TempoEscrow`; `broadcastOpen`/`broadcastTopUp` relay the client's already-signed
  transaction, poll for the receipt, then read state; `settle` delegates to an
  injected **`TempoCloseTxBuilder`** and broadcasts the result.
- **`SessionMethod`**: the server's 4-action session credential handler
  (open / topUp / voucher / close) over the `ChannelStore`.

The one seam the FFI fills:

- **`TempoCloseTxBuilder`**: a one-method protocol (`buildCloseTransaction`). The
  **`MPPTempoFFI`** product's `FFITempoCloseTxBuilder` conforms to it, calling the
  UniFFI bindings to the Rust shim; a server that never settles on-chain itself needs
  no conformer.

### Linking the Rust shim, and keeping it opt-in

`MPPTempoFFI` is the **only** target that links Rust. It depends on a `binaryTarget`
(the `TempoTxFFI` xcframework: the `tempo-tx-ffi` staticlib + its C header) and carries
the committed, drift-checked UniFFI-generated Swift bindings. Both the product and the
binaryTarget are declared only when the **`MPP_TEMPO_FFI`** environment variable is set,
so the default package graph (every other product, and the non-FFI CI jobs) references
no xcframework and pulls **zero Rust**. `Scripts/assert-ffi-isolation.sh` asserts this
invariant in CI: the default graph must contain no `MPPTempoFFI` / `TempoTxFFIBinary`.
The xcframework is built in CI from the pinned `tempo-primitives` source
(`rust/tempo-tx-ffi/build-xcframework.sh`), never committed as a binary. It carries
macOS (universal arm64 + x86_64), iOS device (arm64), and iOS simulator (universal)
slices. (Remaining: the Linux `.so` (a different link mechanism, not an xcframework),
the `open` / `topUp` builders, and the published release-asset url+checksum binaryTarget
that lets an external consumer install the FFI without the env gate.)

## A session, end to end

```
Client (wallet)                                Server
  fund (faucet RPC) ─── EVMRPC ──▶ chain
  build open tx ─── tempo-tx-ffi (FFI) ──▶ signed 0x76 bytes
  broadcast ─── EVMRPC.sendRawTransaction ──▶ chain
                                               reads OnChainChannel (TempoEscrow)
  per request: sign voucher (MPPEVM) ─────────▶ verify voucher (MPPEVM), serve
        (many vouchers; no chain, no FFI)
  close: present final voucher ───────────────▶ SessionMethod.close
                                               settle: TempoCloseTxBuilder (FFI) builds
                                               the close 0x76 tx ─▶ EVMRPC broadcast ─▶ chain
```

Reads and signatures are Swift; only the two transaction-building steps cross into
Rust.

## The FFI boundary (`rust/tempo-tx-ffi`)

- **What it does:** `build_close_tx(...) -> raw 2718 bytes` (open/topUp to follow).
  It builds a `TempoTransaction` directly via `tempo-primitives` (not `tempo-alloy`,
  which would pull a reqwest/tokio RPC stack), signs the hash with `k256`, and RLP-
  encodes. The escrow call data is ABI-encoded in-crate via `alloy-sol-types`.
- **Pinned + reproducible:** an exact git tag (`tempo-primitives@1.8.0`) plus a
  committed `Cargo.lock`. `default-features = false` keeps it pure Rust (no
  `c-kzg`/`blst` C deps), so it cross-compiles cleanly.
- **Verified:** a byte-exact golden test (deterministic RFC-6979 signing) locks the
  output and detects any format change; it runs in CI on macOS and Linux, and the
  bytes match on both. The live-Moderato test is the authoritative on-chain check.
- **Packaging (in progress):** the crate is wrapped with UniFFI and built into an
  Apple xcframework + a Linux `.so`. The artifact is built in CI from pinned source
  (provenance), not committed as an opaque blob.
- **Isolation - only linked when you build transactions (planned).** *Current state:*
  the crate is standalone and **not yet wired into the Swift package** (`Package.swift`
  references no Rust; `swift build` runs no `cargo`), so no Swift target links any Rust
  today. *Design for the wiring slice:* the `TempoCloseTxBuilder` conformer that calls
  the FFI will live in its **own opt-in product**, the only target depending on the FFI
  binary; `MPPTempo` defines just the seam and everything else references the protocol
  (injected), so a non-Tempo consumer or a verify/read-only Tempo server links no Rust.
  A dependency-graph guard (a check that the core/server products do not transitively
  pull the binary) lands with that wiring, so the isolation is enforced, not assumed.

See [SECURITY.md](SECURITY.md) for the supply-chain controls around the Rust surface,
and [REVIEW.md](REVIEW.md) for how to review changes.
