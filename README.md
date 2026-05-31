# mpp-swift

The Swift SDK for the [Machine Payments Protocol (MPP)](https://mpp.dev): pay for, and charge for, machine-to-machine API calls over HTTP 402.

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2013%20%7C%20iOS%2016%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201%20%7C%20Linux-lightgrey.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

MPP standardizes machine-to-machine payments using a **challenge → credential → receipt** flow: a server answers `402 Payment Required` with a `WWW-Authenticate: Payment` challenge, the client replies with an `Authorization: Payment` credential, and the server returns the resource plus a `Payment-Receipt`. It works over HTTP, JSON-RPC/MCP, and WebSocket, with pluggable payment rails (Tempo, Stripe, and more).

This is the canonical Swift implementation of the protocol. The **client** and **server** are independent: a Swift client can pay any MPP server in any language, and a Swift server can charge any client.

> **Status:** early development (pre-1.0), built one module at a time with a strict quality bar (spec-traced tests, cross-SDK conformance vs the reference SDKs, no flaky tests). The protocol core, body-digest, server middleware, the 402 client flow, and the EVM message-signing layer (Keccak-256, secp256k1, EIP-712 proof + session voucher) are implemented. The Tempo rail is well advanced: the zero-amount proof charge, the session-channel server (open/topUp/voucher/close), the blob-free on-chain layer (a JSON-RPC client, the escrow `getChannel` read, and an RPC-backed channel-state provider), and the bespoke `0x76` transaction builder (open/topUp/close, an opt-in Rust FFI to Tempo's own `tempo-primitives`, linking on macOS/iOS/Linux) are all in. The full write path is **proven on-chain**: a gated end-to-end test opens and closes a real payment channel against the live Moderato testnet. The 402 channel-payment **client** (`TempoChannelMethod`: open/voucher/topUp/close, an injected deposit policy, on-chain channel recovery, and a separate access-key signer) is in, and the whole channel rail is **cross-SDK conformance-proven against the reference SDK in both directions, live on Moderato** (open → voucher → close, settled on-chain). Subscriptions, then Stripe, discovery (parser done), MCP, proxy, and WebSocket follow. See the module table below.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/amitach/mpp-swift", from: "0.0.1")
```

Then depend on the products you need (you pull only those):

```swift
.product(name: "MPPCore", package: "mpp-swift"),
```

A consumer that **builds** Tempo channel transactions (a wallet) additionally depends on
`MPPTempoFFI`; on Apple this downloads the checksum-pinned `tempo-tx-ffi` xcframework (no
Rust toolchain). Every other product links zero Rust.

## Modules

| Product | Status | Purpose |
|---|---|---|
| `MPPCore` | available | Protocol primitives: Challenge, Credential, JCS, Amount, ProblemDetails, RouteBinding, multi-challenge parsing |
| `MPPBodyDigest` | available | RFC 9530 `Content-Digest` (SHA-256) |
| `MPPServer` | available | Framework-agnostic middleware over `swift-http-types`: challenge mint, replay, verify pipeline |
| `MPPClient` | available | The 402 client flow (send → parse → select → build → retry); concrete transports in progress |
| `MPPEVM` | available | EVM message-signing + JSON-RPC: Keccak-256, secp256k1 recoverable signer, EIP-712 zero-amount proof + `did:pkh` source, session voucher, channel id, `0x`-hex codec |
| `MPPTempo` | available | Tempo rail: zero-amount proof charge; the **402 channel-payment client `TempoChannelMethod`** (auto open + accumulating vouchers, client-initiated topUp/close, an injected deposit policy, on-chain channel recovery, optional access-key signer) behind the `TempoOpenTxBuilder` / `TempoTopUpTxBuilder` / `TempoCloseTxBuilder` seams; the `EVMRPC` JSON-RPC client; the escrow `getChannel` read (`TempoEscrow` → `OnChainChannel`); `ChannelAmount`. The `0x76` builders are the `rust/tempo-tx-ffi` FFI (below); the `TempoChannelSession` actor (in `MPPTempoFFI`) is the direct-wallet lifecycle. Cross-SDK conformance-proven both directions, live |
| `MPPTempoServer` | available | Tempo SERVER side: zero-amount proof verify, the 4-action `SessionMethod` (open/topUp/voucher/close), `ChannelStore`, and `RPCChannelStateProvider` (reads + relays signed txs + settle via the seam). A session reuses one challenge across its lifecycle, so the verifier honours `PaymentMethodServer.reusesChallenge` (the channel-store cumulative is the anti-replay) |
| `MPPDiscovery` | in progress | OpenAPI `x-payment-info` discovery (parser + emitter done) |
| `MPPMCP` | planned | JSON-RPC / Model Context Protocol binding |
| `MPPProxy` / `MPPWebSocket` | planned | 402-protected reverse proxy; WebSocket transport |
| `MPPStripe` | planned | Stripe rail (Shared Payment Token charge) |
| `MPPVapor` / `MPPHummingbird` | planned | Server framework adapters |

The bespoke Tempo `0x76` transaction (channel open/topUp/close) is the one piece we deliberately do **not** build in Swift. Swift could encode it, but the format is Tempo-specific and evolving, so binding Tempo's own `tempo-primitives` (the chain's canonical implementation) gives byte-for-byte parity and turns an upgrade into a version bump, instead of a drift-prone Swift port we would have to chase by hand. It is produced by **`rust/tempo-tx-ffi`** and exposed to Swift over an FFI boundary. It is **only needed by a consumer that builds Tempo channel transactions** (a wallet): a non-Tempo consumer, or a Tempo server that only verifies and reads, should link none of it. It builds all three channel-bookend transactions (`open` / `topUp` / `close`) and is wired into the Swift package behind the dedicated opt-in **`MPPTempoFFI`** product (the `FFITempoTxBuilder`), so only a transaction-building consumer pulls the binary and the default graph links zero Rust (see [ARCHITECTURE.md](ARCHITECTURE.md)). It links on macOS (universal), iOS (device + simulator), and Linux. It is a **build input that ships in the artifact** (unlike the dev-only npm test tooling); its dependency tree is pinned (`Cargo.lock`), built in CI on macOS and Linux, byte-golden-tested, and `cargo audit`-scanned. Its output is **proven on-chain**: a gated live Moderato e2e opens and closes a real channel through it. It is **published as a checksummed GitHub-release xcframework** (`.github/workflows/release-ffi.yml`, tag `tempo-tx-ffi-v*`), so an external Apple consumer installs it with **no env var and no Rust toolchain**. The from-source `MPP_TEMPO_FFI` path remains for dev/CI, and a Linux consumer always builds from source (SwiftPM has no Linux library binary artifact). See [SECURITY.md](SECURITY.md#rust-ffi-the-0x76-transaction-builder).

## Development (running locally)

**Prerequisites:** a Swift 6 toolchain (Xcode 16+ on macOS, or the Swift 6 toolchain on Linux). The Rust FFI crate additionally needs a Rust toolchain `>= 1.93` (`rustup update stable`), but only if you build *that* crate - the Swift package builds and tests with no Rust.

```sh
git clone https://github.com/amitach/mpp-swift && cd mpp-swift
swift build            # builds all products
swift test             # runs the full suite (hermetic; no network)
```

Both must pass on macOS and Linux. Lint matches CI:

```sh
swiftformat --lint .   # formatting
swiftlint --strict     # style; zero warnings
```

**Cross-SDK conformance** (exercises the wire format against the reference TypeScript SDK; needs Node):

```sh
Scripts/conformance/run.sh             # offline, vs a local mppx server
Scripts/conformance/run.sh --testnet   # against the live Moderato node
```

**Live-chain tests** (read path against the real Moderato testnet) are gated so the default suite stays hermetic; opt in with an env var:

```sh
MPP_MODERATO_E2E=1 swift test --filter Moderato
```

**The Rust FFI crate** (the `0x76` transaction builder) is separate from the Swift package:

```sh
cd rust/tempo-tx-ffi
cargo test     # builds the crate (clones tempo + compiles the tree) and runs the byte-golden test
cargo audit    # scans the Rust dependency tree against the RustSec advisory DB
```

CI runs all of the above; the Swift `Tests` jobs and the `Rust FFI` job both run on macOS **and** Linux. See [the architecture overview](ARCHITECTURE.md) for how the pieces fit and [SECURITY.md](SECURITY.md) for the supply-chain posture.

## Design

- **Client and server are separate products:** depend on one without the other.
- **Spec is the source of truth.** The SDK defaults to the published MPP drafts; where an interoperating peer diverges, the divergence is handled explicitly via a compatibility configuration, never silently inherited.
- **Conventions follow the Swift ecosystem**: Apple's API Design Guidelines and the `swift-*` package norms.

## License

Dual-licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

### Acknowledgments

This product includes software developed by Marcin Krzyzanowski (https://krzyzanowskim.com/), the [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) library, used for Keccak-256.

Security policy: see [SECURITY.md](SECURITY.md). Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md).
