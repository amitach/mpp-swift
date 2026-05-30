# Architecture

mpp-swift implements the Machine Payments Protocol (MPP, the HTTP 402 "Payment"
scheme) as a set of focused SwiftPM products plus one isolated Rust FFI crate. This
document explains how the pieces fit, why the boundaries are where they are, and how
a payment flows end to end.

## Module layering

Products depend downward only; a consumer pulls just what it needs.

```
MPPCore            wire/data types (Challenge, Credential, Receipt, JCS, Amount,
  │                ProblemDetails), no crypto, no network
  ├── MPPBodyDigest      RFC 9530 Content-Digest (swift-crypto)
  ├── MPPServer          framework-agnostic 402 middleware (swift-http-types):
  │                      challenge mint/verify, replay, the verify pipeline
  ├── MPPClient          the 402 client flow + the MPPHTTPTransport seam + URLSession
  ├── MPPEVM             EVM message-signing + helpers (pure Swift): Keccak-256,
  │                      secp256k1 signer, EIP-712 proof/voucher, channel id, 0x-hex
  └── MPPDiscovery       OpenAPI x-payment-info parse/emit
        │
      MPPTempo           Tempo rail (depends on MPPCore + MPPEVM + MPPClient):
        │                EVMRPC (JSON-RPC), TempoEscrow (getChannel read),
        │                ChannelAmount, OnChainChannel, TempoCloseTxBuilder seam,
        │                the zero-amount proof charge method
        └── MPPTempoServer   Tempo SERVER side (also depends on MPPServer):
                             proof verify, the 4-action SessionMethod, ChannelStore,
                             RPCChannelStateProvider

rust/tempo-tx-ffi      Rust crate (NOT a SwiftPM product): builds + signs + RLP-
                       encodes the bespoke Tempo 0x76 transaction, binding Tempo's
                       own tempo-primitives. Reached from Swift over an FFI boundary.
```

A non-EVM consumer (e.g. a future Stripe rail, or pure client/server/MCP) pulls
**none** of MPPEVM/MPPTempo and **no Rust**.

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
  Swift wrapper around `rust/tempo-tx-ffi` conforms to it; a server that never settles
  on-chain itself needs no conformer.

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
- **Isolation - only linked when you build transactions.** The `TempoCloseTxBuilder`
  conformer that calls the FFI lives in its **own opt-in product**, the only target
  depending on the FFI binary. `MPPTempo` defines just the seam; everything else
  references the protocol, not the crate. So a non-Tempo consumer, or a Tempo server
  that only verifies and reads, links **no Rust**: the dependency graph and the
  injected seam enforce it, and a guard keeps the core/server products from
  transitively pulling the binary.

See [SECURITY.md](SECURITY.md) for the supply-chain controls around the Rust surface,
and [REVIEW.md](REVIEW.md) for how to review changes.
