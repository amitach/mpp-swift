# mpp-swift

The Swift SDK for the [Machine Payments Protocol (MPP)](https://mpp.dev): pay for, and charge for, machine-to-machine API calls over HTTP 402.

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2013%20%7C%20iOS%2016%20%7C%20tvOS%2016%20%7C%20watchOS%209%20%7C%20visionOS%201%20%7C%20Linux-lightgrey.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

MPP standardizes machine-to-machine payments using a **challenge → credential → receipt** flow: a server answers `402 Payment Required` with a `WWW-Authenticate: Payment` challenge, the client replies with an `Authorization: Payment` credential, and the server returns the resource plus a `Payment-Receipt`. It works over HTTP, JSON-RPC/MCP, and WebSocket, with pluggable payment rails (Tempo, Stripe, and more).

This is the canonical Swift implementation of the protocol. The **client** and **server** are independent: a Swift client can pay any MPP server in any language, and a Swift server can charge any client.

> **Status:** early development. The package is built one module at a time with a strict quality bar (spec-traced tests, cross-SDK conformance, no flaky tests). `MPPCore` (protocol primitives) is the first module; client, server, MCP, discovery, proxy, and the Tempo/Stripe rails follow.

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
| `MPPCore` | in progress | Protocol primitives: Challenge, Credential, Receipt, JCS, Amount, policies |
| `MPPClient` | planned | The 402 client flow |
| `MPPServer` | planned | Framework-agnostic server middleware |
| `MPPMCP` | planned | JSON-RPC / Model Context Protocol binding |
| `MPPDiscovery` | planned | OpenAPI `x-payment-info` discovery |
| `MPPProxy` | planned | 402-protected reverse proxy |
| `MPPTempo` / `MPPStripe` | planned | Payment rails |

## Design

- **Client and server are separate products:** depend on one without the other.
- **Spec is the source of truth.** The SDK defaults to the published MPP drafts; where an interoperating peer diverges, the divergence is handled explicitly via a compatibility configuration, never silently inherited.
- **Conventions follow the Swift ecosystem**: Apple's API Design Guidelines and the `swift-*` package norms.

## License

Dual-licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

Security policy: see [SECURITY.md](SECURITY.md). Contributing: see [CONTRIBUTING.md](CONTRIBUTING.md).
