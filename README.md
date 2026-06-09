# mpp-swift

The Swift SDK for the [Machine Payments Protocol (MPP)](https://mpp.dev): pay for, and charge for, machine-to-machine API calls over HTTP 402.

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2013%20%7C%20iOS%2016%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201%20%7C%20Linux-lightgrey.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/amitach/mpp-swift)

MPP standardizes machine-to-machine payments using a **challenge → credential → receipt** flow: a server answers `402 Payment Required` with a `WWW-Authenticate: Payment` challenge, the client replies with an `Authorization: Payment` credential, and the server returns the resource plus a `Payment-Receipt`. It works over HTTP, JSON-RPC/MCP, and WebSocket, with pluggable payment rails (Tempo, Stripe, and more).

This is the canonical Swift implementation of the protocol. The **client** and **server** are independent: a Swift client can pay any MPP server in any language, and a Swift server can charge any client.

An auto-generated code wiki is browsable at **[DeepWiki](https://deepwiki.com/amitach/mpp-swift)** for a quick tour of the codebase. The official badge above keeps it auto-refreshed weekly, but it can still lag the newest modules; this README and [ARCHITECTURE.md](ARCHITECTURE.md) are the authoritative, current references.

> **Status:** broad and feature-complete to the 1.0 conformance line (the package is still tagged `0.0.x`; cutting the 1.0 tag is the remaining step), built one module at a time with a strict quality bar (spec-traced tests, cross-SDK conformance vs the reference SDKs, no flaky tests). The protocol core, body-digest, server middleware, the 402 client flow, and the EVM message-signing layer (Keccak-256, secp256k1, EIP-712 proof + session voucher) are implemented. The Tempo rail is well advanced: the zero-amount proof charge, the session-channel server (open/topUp/voucher/close), the blob-free on-chain layer (a JSON-RPC client, the escrow `getChannel` read, and an RPC-backed channel-state provider), and the bespoke `0x76` transaction builder (open/topUp/close, an opt-in Rust FFI to Tempo's own `tempo-primitives`, linking on macOS/iOS/Linux) are all in. The full write path is **proven on-chain**: a gated end-to-end test opens and closes a real payment channel against the live Moderato testnet. The 402 channel-payment **client** (`TempoChannelMethod`: open/voucher/topUp/close, an injected deposit policy, on-chain channel recovery, and a separate access-key signer) is in, and the whole channel rail is **cross-SDK conformance-proven against the reference SDK in both directions, live on Moderato** (open → voucher → close, settled on-chain). Discovery (parse + generate + validate), the 402-protected reverse proxy (`MPPProxy`, with a live Hummingbird binding `MPPHummingbird`), and the JSON-RPC / MCP binding (`MPPMCP`, cross-SDK conformance-proven both directions over stdio) are in. The **subscription rail** is in, end to end: a signed Tempo key authorization (`TempoKeyAuthorization`, RLP, byte-verified against the chain's own codec), the client (`TempoSubscriptionMethod`) and server (`TempoSubscriptionVerifier`, which re-encodes the expected authorization and compares so it never trusts the client decode), a `SubscriptionStore` with a two-phase atomic renewal engine, and a **concrete on-chain renewer** (`TempoSubscriptionRenewer` over an `AccessKeyStore` + the `0x76` charge builder) that settles the recurring `transferWithMemo` live, with **fee-payer gas sponsorship** so the charge fits the access key's spending limit. It is **cross-SDK conformance-proven against the reference SDK in both directions** (activation offline, and a recurring charge settled live on Moderato). **Metered streaming** is in too: a pay-as-you-go `SessionStream` that meters chunks against a channel over both **Server-Sent Events** and **WebSocket** frames, with cross-SDK codec parity for both, plus a **live WebSocket transport** (`MPPWebSocket` orchestration + `MPPWebSocketLive` swift-websocket adapters, server and client) that drives a metered session over a real socket. The **Stripe rail** is in (`MPPStripe` client + `MPPStripeServer`: a Shared Payment Token charge into a PaymentIntent, full Connect parity, **live-verified** against a real test-mode charge), and so is the **x402-on-Base rail** (`MPPX402` / `MPPX402Server`: an EIP-3009 `transferWithAuthorization` over USDC on Base, a version-negotiated bridge between MPP and x402 for v1 and v2, and an x402-facilitator settler). A server can also render a self-contained **HTML payment page** (`MPPHTML` / `MPPHTMLServer`: multi-method tabs + a service worker, content-negotiated by the middleware) for a human-facing 402. Server **hardening** is in -- single-use replay, idempotency (409), rate limiting (429), sensitive-surface redaction, and opt-in CORS/HEAD -- alongside receipt persistence (the `ReceiptStore` seam), an atomic running-budget `PaymentAuthorizer` (`BudgetAuthorizer`), an `mpp.dev/services` directory client (`ServiceDirectory`), and a SwiftNIO `AsyncHTTPClient` transport (`MPPClientAsyncHTTP`) for long-lived server / Linux processes. And a shipped **`mpp` command-line tool** (`pay` a 402 URL curl-style, plus `sign` / `discover` / `account` / `services` / `init`) rides a vendor-neutral `PaymentAuthorizer` approval seam (`MPPAuth`: per-request Touch ID, a TTY prompt, or headless auto with a spending cap). The original 1.0 gate -- server hardening, the HTML page, and conformance-vector completeness -- is now closed; the remaining step is cutting the 1.0 release tag. See [what's covered](#whats-covered) and the module table below.

## What's covered

MPP composes along three axes: the **transport** the 402 flow rides, the **rail** that moves value, and the **side** you are (payer/client vs payee/server). Client and server are independent products, so a Swift client can pay any-language server and a Swift server can charge any client. Here is the surface:

**Transports** (the wire the challenge / credential / receipt flow rides):
- **HTTP** - `MPPServer` middleware + `MPPClient` (over `URLSessionTransport`); a live server binding (`MPPHummingbird`) and a 402-protected reverse proxy (`MPPProxy`).
- **JSON-RPC / MCP** - `MPPMCP` gates a `tools/call` and pays it transparently; conformance-proven both directions over stdio.
- **WebSocket + SSE** - metered, pay-as-you-go streaming with in-band voucher top-up: `MPPWebSocket` (transport-agnostic session orchestration, server + client) + `MPPWebSocketLive` (live swift-websocket adapters), plus the Server-Sent Events codec.
- **HTML payment page** - `MPPHTML` / `MPPHTMLServer`: a self-contained, themeable HTML `402` page (multi-method tabs + a service worker) that `MPPServerMiddleware` content-negotiates for a human-facing payer, alongside the machine `problem+json`.

**Rails** (how value actually settles):
- **Tempo (EVM)** - `MPPTempo` / `MPPTempoServer`: a zero-amount proof-of-wallet-control charge; a full payment-channel session (open / voucher / topUp / close, settled on-chain); a subscription rail (a signed key authorization, a two-phase atomic renewal engine, and a concrete on-chain renewer with fee-payer gas sponsorship); and metered streaming over the channel. The `0x76` channel / charge transactions are built by a pinned Rust FFI (`MPPTempoFFI`), so only a wallet links it.
- **Stripe** - `MPPStripe` / `MPPStripeServer`: a Shared Payment Token charge into a PaymentIntent, full Stripe Connect parity, live-verified.
- **x402 on Base** - `MPPX402` / `MPPX402Server`: the Coinbase x402 `exact` scheme (an EIP-3009 `transferWithAuthorization` over USDC on Base), plus a version-negotiated bridge between MPP and x402 (v1 + v2) and an x402-facilitator settler, so the SDK interoperates with the real x402 ecosystem in both directions.

**Client building blocks:**
- **`PaymentAuthorizer`** - the vendor-neutral consent/budget seam consulted once at the credential-build chokepoint: `AllowAllAuthorizer`, `SpendingCapAuthorizer`, and `BudgetAuthorizer` (an atomic running-budget check-and-debit, TOCTOU-safe -- the spending-cap / margin enforcer for a long-lived broker).
- **`ReceiptStore`** - a persistence seam the client records each `Payment-Receipt` to after settle (auditing, never a gate).
- **`MPPClientAsyncHTTP`** - a SwiftNIO `AsyncHTTPClient` transport, the Linux/server counterpart to `URLSessionTransport` for a long-lived gateway or broker process.

**Server hardening:** single-use `ReplayStore`, `IdempotencyStore` (safe-retry, 409), `RateLimiter` (429), sensitive-surface redaction, and an opt-in CORS/HEAD policy on the discovery surfaces -- all in `MPPServer` / `MPPProxy`.

**Tooling:**
- **`mpp`** - a shipped command-line tool: `pay` a 402 URL (curl-like), `sign` a challenge, `discover` / `validate`, `account` (macOS Keychain), `services`, `init`. Approval rides a vendor-neutral `PaymentAuthorizer` seam (`MPPAuth`): per-request Touch ID, a TTY prompt, or headless auto with a spending cap.
- **`MPPDiscovery`** - OpenAPI `x-payment-info` discovery (parse, generate, validate) plus a `ServiceDirectory` client that reads the `mpp.dev/services` directory.

**Cross-SDK conformance:** every rail and transport with a reference peer is proven against the reference TypeScript SDK (`mppx`) in **both directions** (our client against their server, and their client against our server), offline in CI and, for the on-chain Tempo paths, live on the Moderato testnet. See [CONFORMANCE.md](CONFORMANCE.md).

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
| `MPPServer` | available | Framework-agnostic middleware over `swift-http-types`: challenge mint, replay, verify pipeline, plus the hardening seams -- `IdempotencyStore` (safe-retry, 409), `RateLimiter` (429), `FileReplayStore`, sensitive-surface redaction, and a pluggable HTML payment-page `presenter` (content-negotiated against `problem+json`) |
| `MPPClient` | available | The 402 client flow (send → parse → select → build → retry) over `URLSessionTransport` (with redirect-downgrade protection), recording each `Payment-Receipt` to a `ReceiptStore` seam after settle; plus the vendor-neutral `PaymentAuthorizer` consent seam (the protocol + `AllowAllAuthorizer` + `SpendingCapAuthorizer` + the atomic running-budget `BudgetAuthorizer`) consulted once at the credential-build chokepoint, shared by the HTTP and MCP clients |
| `MPPClientAsyncHTTP` | available | An `MPPHTTPTransport` over `swift-server/async-http-client` (SwiftNIO): the Linux/server-native counterpart to `URLSessionTransport` for a long-lived broker or gateway, with connection pooling and redirects disallowed (credential-leak parity with `URLSession`). The same 402 flow runs over it unchanged |
| `MPPAuth` | available | The interactive/headless payment-approval implementations + the macOS key store, used by the `mpp` CLI: `TTYPaymentAuthorizer` (y/n prompt) and `BiometricPaymentAuthorizer` (`LocalAuthentication` Touch ID), the `displaySafe` terminal sanitizer for server-controlled strings, and `KeychainAccountStore` (biometric-gated secp256k1 key items) |
| `MPPEVM` | available | EVM message-signing + JSON-RPC: Keccak-256, secp256k1 recoverable signer, EIP-712 zero-amount proof + `did:pkh` source, session voucher, channel id, `0x`-hex codec; plus `TempoKeyAuthorization` (the subscription key authorization) and a strict-canonical pure-Swift `RLP` codec, byte-verified against the chain's own `tempo-primitives` codec |
| `MPPTempo` | available | Tempo rail: zero-amount proof charge; the **402 channel-payment client `TempoChannelMethod`** (auto open + accumulating vouchers, client-initiated topUp/close, an injected deposit policy, on-chain channel recovery, optional access-key signer) behind the `TempoOpenTxBuilder` / `TempoTopUpTxBuilder` / `TempoCloseTxBuilder` seams; the `EVMRPC` JSON-RPC client; the escrow `getChannel` read (`TempoEscrow` → `OnChainChannel`); `ChannelAmount`. The `0x76` builders are the `rust/tempo-tx-ffi` FFI (below); the `TempoChannelSession` actor (in `MPPTempoFFI`) is the direct-wallet lifecycle. Also the **subscription client** `TempoSubscriptionMethod` (decodes the `tempo`/`subscription` 402, signs the `TempoKeyAuthorization` delegating the server-issued access key to the recurring `transferWithMemo`) and `SubscriptionRequest`. The `0x76` subscription-charge builder (and its optional fee-payer gas sponsor) lives in `MPPTempoFFI`. Cross-SDK conformance-proven both directions, live |
| `MPPTempoServer` | available | Tempo SERVER side: zero-amount proof verify, the 4-action `SessionMethod` (open/topUp/voucher/close), `ChannelStore`, and `RPCChannelStateProvider` (reads + relays signed txs + settle via the seam). A session reuses one challenge across its lifecycle, so the verifier honours `PaymentMethodServer.reusesChallenge` (the channel-store cumulative is the anti-replay). Plus the **subscription server** `TempoSubscriptionVerifier` (re-encode-and-compare: rebuilds the expected key authorization from its own challenge and requires byte-equality, never trusting the client decode), the `SubscriptionStore` + two-phase atomic renewal `SubscriptionEngine` (claim → charge via an injected `SubscriptionRenewer` seam → commit, with timeout takeover and supersession), the **concrete on-chain renewer** `TempoSubscriptionRenewer` (settles the recurring `transferWithMemo` via the `0x76` charge builder, signed by the server-held access key from the `AccessKeyStore` as a Tempo V2 keychain signature, with an idempotency `Attribution` memo and optional fee-payer gas sponsorship; the first charge attaches the key authorization to provision the access key on-chain), and **metered streaming**: `SessionStream` (pay-as-you-go: each chunk draws one tick, emits `payment-need-voucher` when short, then the terminal receipt) with the SSE codec `SessionStreamEvent` and the WebSocket frame codec `SessionWebSocketFrame` |
| `MPPTempoFFI` | available (opt-in) | The Rust `0x76` transaction builders over an FFI boundary: `FFITempoTxBuilder` (channel open/topUp/close) and `FFISubscriptionChargeTxBuilder` (the recurring `transferWithMemo`, with an optional fee-payer gas sponsor), plus the `TempoChannelSession` direct-wallet lifecycle actor. Only a transaction-building consumer (a wallet) links it; on Apple a checksum-pinned `tempo-tx-ffi` xcframework (no Rust toolchain), Linux builds from source. See below |
| `MPPDiscovery` | available | OpenAPI `x-payment-info` discovery: parse, `generate` an OpenAPI 3.1 document from routes (auto-declaring the required `402`), and structural + semantic `validate` (a payable op MUST have a `402`, SHOULD have a `requestBody`); served at `/openapi.json`. Also a `ServiceDirectory` client that decodes the `mpp.dev/services` registry into rail-agnostic entries (a malformed entry URL never fails decoding of the whole directory) |
| `MPPMCP` | available | JSON-RPC / Model Context Protocol payment binding (over the official MCP Swift SDK): a server gate (`tools/call` → 402 challenge / verify / receipt) and a client wrapper that pays transparently. Cross-SDK conformance-proven both directions over stdio. Requires Swift 6.2 (the MCP SDK's transitive graph) |
| `MPPProxy` | available | Framework-neutral 402-protected reverse proxy: routes `/{service}/...` to upstream origins, gates each route with `MPPServerMiddleware`, scrubs credential/cookie/hop-by-hop headers in both directions, injects upstream auth, and serves `/openapi.json` + `/llms.txt` (with an opt-in `CORSPolicy` + `HEAD` on those discovery surfaces only, never on proxied routes). Pure request/response logic over swift-http-types; no server dependency |
| `MPPHummingbird` | available | The live HTTP-server binding for `MPPProxy` (and single gated routes), over [Hummingbird 2](https://github.com/hummingbird-project/hummingbird). The only product that links swift-nio; requires macOS 14 / iOS 17 |
| `MPPStripe` | available | Stripe rail CLIENT: presents a Shared Payment Token in the credential (no Stripe secret, no crypto) |
| `MPPStripeServer` | available | Stripe rail SERVER: `StripeChargeVerifier` mints a PaymentIntent from the SPT via `StripePaymentIntentClient` (Basic auth, hashed `Idempotency-Key`, no secret leak), maps status → receipt/reject; full Stripe Connect parity. Live-verified against a real test-mode PaymentIntent |
| `MPPX402` | available | x402-on-Base rail CLIENT: the Coinbase x402 `exact` scheme over an EIP-3009 `transferWithAuthorization` (USDC on Base), the `X402ChargeMethod` payer, and a version-negotiated bridge between MPP and x402 (v1 + v2 wire: headers, `PaymentRequirements`, `PaymentPayload`). The signing digest is anchored to the canonical EIP-3009 type hash and the on-chain USDC-Base domain separator |
| `MPPX402Server` | available | x402-on-Base rail SERVER: `X402ChargeVerifier` recovers + validates the EIP-3009 authorization against the challenge (`.rejectHighS`, single-use replay), then settles via an `X402Settlement` seam -- a concrete `FacilitatorSettlement` posts to an x402 facilitator's `/verify` + `/settle` (TLS-guarded, fail-closed parsing) |
| `MPPHTML` | available | Renders a self-contained, themeable HTML payment page from a `Challenge`: per-method form fragments + an embedded config object, multi-method tabs, a sanitized/preflighted style. A human-facing alternative to `problem+json` |
| `MPPHTMLServer` | available | Wires `MPPHTML` into `MPPServerMiddleware` via a `PaymentPagePresenter` (content-negotiates HTML vs `problem+json`), plus the client script and a registerable service worker (`MPPHTMLServiceWorker`) that re-attaches the credential on the paid retry |
| `MPPWebSocket` | available | Metered-session WebSocket transport, transport-agnostic: `SessionWebSocketServer` (drives `SessionStream` over a socket; actor-serialized) + `SessionWebSocketClient` (consumes it, auto-answers `payment-need-voucher` with a fresh voucher), over the `{mpp:...}` `SessionWebSocketFrame` codec. No external deps |
| `MPPWebSocketLive` | available | The live socket adapters for `MPPWebSocket`, on hummingbird's swift-websocket (`WSCore` inbound/outbound + `WSClient`); bridges a real WebSocket into the orchestration and confines the nio WebSocket graph to this target |
| `mpp` (executable) | available | The shipped command-line tool: `pay` a 402 URL (curl-like), `sign` a challenge, `discover` generate/validate, `account` (macOS Keychain), `services`, `init`. swift-argument-parser; curl-like exit codes; approval via the `MPPAuth` seam |

The bespoke Tempo `0x76` transaction (channel open/topUp/close) is the one piece we deliberately do **not** build in Swift. Swift could encode it, but the format is Tempo-specific and evolving, so binding Tempo's own `tempo-primitives` (the chain's canonical implementation) gives byte-for-byte parity and turns an upgrade into a version bump, instead of a drift-prone Swift port we would have to chase by hand. It is produced by **`rust/tempo-tx-ffi`** and exposed to Swift over an FFI boundary. It is **only needed by a consumer that builds Tempo channel transactions** (a wallet): a non-Tempo consumer, or a Tempo server that only verifies and reads, should link none of it. It builds the three channel-bookend transactions (`open` / `topUp` / `close`) and the recurring subscription charge (a `transferWithMemo`, signed by an access key as a Tempo V2 keychain signature, with an optional fee-payer gas sponsor), and is wired into the Swift package behind the dedicated opt-in **`MPPTempoFFI`** product (the `FFITempoTxBuilder` and `FFISubscriptionChargeTxBuilder`), so only a transaction-building consumer pulls the binary and the default graph links zero Rust (see [ARCHITECTURE.md](ARCHITECTURE.md)). It links on macOS (universal), iOS (device + simulator), and Linux. It is a **build input that ships in the artifact** (unlike the dev-only npm test tooling); its dependency tree is pinned (`Cargo.lock`), built in CI on macOS and Linux, byte-golden-tested, and `cargo audit`-scanned. Its output is **proven on-chain**: a gated live Moderato e2e opens and closes a real channel through it. It is **published as a checksummed GitHub-release xcframework** (`.github/workflows/release-ffi.yml`, tag `tempo-tx-ffi-v*`), so an external Apple consumer installs it with **no env var and no Rust toolchain**. The from-source `MPP_TEMPO_FFI` path remains for dev/CI, and a Linux consumer always builds from source (SwiftPM has no Linux library binary artifact). See [SECURITY.md](SECURITY.md#rust-ffi-the-0x76-transaction-builder).

## Development (running locally)

**Prerequisites:** a Swift 6.2 toolchain (Xcode 26+ on macOS, or the Swift 6.2 toolchain on Linux). The 6.2 floor comes from `MPPMCP`'s dependency on the official MCP Swift SDK, whose transitive graph (swift-log 1.13) requires tools 6.2. The Rust FFI crate additionally needs a Rust toolchain `>= 1.93` (`rustup update stable`), but only if you build *that* crate - the Swift package builds and tests with no Rust.

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
