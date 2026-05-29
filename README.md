# mpp-swift

The Swift SDK for the [Machine Payments Protocol (MPP)](https://mpp.dev): pay for, and charge for, machine-to-machine API calls over HTTP 402.

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2013%20%7C%20iOS%2016%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201%20%7C%20Linux-lightgrey.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

MPP standardizes machine-to-machine payments using a **challenge → credential → receipt** flow: a server answers `402 Payment Required` with a `WWW-Authenticate: Payment` challenge, the client replies with an `Authorization: Payment` credential, and the server returns the resource plus a `Payment-Receipt`. It works over HTTP, JSON-RPC/MCP, and WebSocket, with pluggable payment rails (Tempo, Stripe, and more).

This is the canonical Swift implementation of the protocol. The **client** and **server** are independent: a Swift client can pay any MPP server in any language, and a Swift server can charge any client.

> **Status:** early development (pre-1.0), built one module at a time with a strict quality bar (spec-traced tests, cross-SDK conformance vs the reference SDKs, no flaky tests). The protocol core, body-digest, server middleware, the 402 client flow, and the EVM message-signing layer (Keccak-256, secp256k1, EIP-712 proof + session voucher) are implemented; the Tempo/Stripe rails, discovery, MCP, proxy, and WebSocket follow. See the module table below.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/amitach/mpp-swift", from: "0.0.1")
```

Then depend on the products you need (you pull only those):

```swift
.product(name: "MPPCore", package: "mpp-swift"),
```

## Modules

| Product | Status | Purpose |
|---|---|---|
| `MPPCore` | available | Protocol primitives: Challenge, Credential, JCS, Amount, ProblemDetails, RouteBinding, multi-challenge parsing |
| `MPPBodyDigest` | available | RFC 9530 `Content-Digest` (SHA-256) |
| `MPPServer` | available | Framework-agnostic middleware over `swift-http-types`: challenge mint, replay, verify pipeline |
| `MPPClient` | available | The 402 client flow (send → parse → select → build → retry); concrete transports in progress |
| `MPPEVM` | available | EVM message-signing: Keccak-256, secp256k1 recoverable signer, EIP-712 zero-amount proof + `did:pkh` source, session voucher |
| `MPPDiscovery` | planned | OpenAPI `x-payment-info` discovery |
| `MPPMCP` | planned | JSON-RPC / Model Context Protocol binding |
| `MPPProxy` / `MPPWebSocket` | planned | 402-protected reverse proxy; WebSocket transport |
| `MPPTempo` / `MPPStripe` | planned | Payment rails (Tempo charge + channel/voucher settlement, subscription; Stripe) |
| `MPPVapor` / `MPPHummingbird` | planned | Server framework adapters |

## Design

- **Client and server are separate products:** depend on one without the other.
- **Spec is the source of truth.** The SDK defaults to the published MPP drafts; where an interoperating peer diverges, the divergence is handled explicitly via a compatibility configuration, never silently inherited.
- **Conventions follow the Swift ecosystem**: Apple's API Design Guidelines and the `swift-*` package norms.

## License

Dual-licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

### Acknowledgments

This product includes software developed by Marcin Krzyzanowski (https://krzyzanowskim.com/), the [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) library, used for Keccak-256.

Security policy: see [SECURITY.md](SECURITY.md). Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md).
