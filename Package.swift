// swift-tools-version: 6.2
// swiftlint:disable file_length
// The file_length rule enforces source-file discipline ("one type per file, split before a file
// sprawls"); a package manifest has no types and cannot be split, and grows with the module list.
// All other rules stay enforced here.
import Foundation
import PackageDescription

// Whether the Tempo FFI (the Rust 0x76 builder) is built from source this run. Computed up
// front because it also gates an optional dependency of MPPConformanceServer: the reverse
// session-conformance route needs the FFI close builder (RPCChannelStateProvider settles
// on-chain). The default (proof-only) reverse server stays Rust-free.
let ffiFromSource = ProcessInfo.processInfo.environment["MPP_TEMPO_FFI"] != nil
// MPPClient (URLSessionTransport) + MPPEVM (EthereumAddress / Secp256k1Signer) are used only
// by the FFI-gated session route, so they ride the same gate: the default proof-only server
// pulls neither.
let conformanceServerFFIDeps: [Target.Dependency] =
    ffiFromSource ? ["MPPTempoFFI", "MPPClient", "MPPEVM"] : []
let conformanceServerFFISettings: [SwiftSetting] =
    ffiFromSource ? [.define("MPP_TEMPO_FFI_ENABLED")] : []

// mpp-swift: Swift SDK for the Machine Payments Protocol (MPP).
//
// Products and targets grow one workstream at a time (see the implementation
// plan). `MPPCore` is the always-on protocol layer every other module builds on;
// `MPPBodyDigest` is the optional RFC 9530 Content-Digest codec (the first module
// to use cryptography). Client/Server/MCP/Discovery/Proxy/rails are added as
// their workstreams land, each behind its own product so consumers depend on
// exactly what they need.
let package = Package(
    name: "mpp-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MPPCore", targets: ["MPPCore"]),
        .library(name: "MPPBodyDigest", targets: ["MPPBodyDigest"]),
        .library(name: "MPPServer", targets: ["MPPServer"]),
        .library(name: "MPPClient", targets: ["MPPClient"]),
        .library(name: "MPPClientAsyncHTTP", targets: ["MPPClientAsyncHTTP"]),
        .library(name: "MPPAuth", targets: ["MPPAuth"]),
        .library(name: "MPPEVM", targets: ["MPPEVM"]),
        .library(name: "MPPDiscovery", targets: ["MPPDiscovery"]),
        .library(name: "MPPTempo", targets: ["MPPTempo"]),
        .library(name: "MPPTempoServer", targets: ["MPPTempoServer"]),
        .library(name: "MPPStripe", targets: ["MPPStripe"]),
        .library(name: "MPPStripeServer", targets: ["MPPStripeServer"]),
        .library(name: "MPPHTML", targets: ["MPPHTML"]),
        .library(name: "MPPHTMLServer", targets: ["MPPHTMLServer"]),
        .library(name: "MPPMCP", targets: ["MPPMCP"]),
        .library(name: "MPPProxy", targets: ["MPPProxy"]),
        .library(name: "MPPHummingbird", targets: ["MPPHummingbird"]),
        .library(name: "MPPWebSocket", targets: ["MPPWebSocket"]),
        .library(name: "MPPWebSocketLive", targets: ["MPPWebSocketLive"]),
        .executable(name: "mpp", targets: ["mpp"]),
    ],
    dependencies: [
        // swift-crypto and CryptoSwift (below) do NOT overlap; neither replaces the
        // other. swift-crypto (Apple, BoringSSL-backed) is the primary library and owns
        // the standard NIST primitives we use: SHA-256 (Content-Digest, MPPBodyDigest)
        // and HMAC-SHA256 (challenge mint/verify, MPPServer). CryptoSwift exists solely
        // for Keccak-256, the Ethereum hash, which swift-crypto does not provide (it
        // ships only NIST SHA-3, a different padding and a different digest). Each
        // library is used where it is strongest.
        // Pinning policy (see SECURITY.md). The widely-shared Apple packages use a
        // FLOOR range (>= a reviewed-safe version, < next major): exact-pinning them
        // in a library would cause unresolvable diamond conflicts for any consumer
        // that also depends on swift-crypto / swift-http-types, while a floor still
        // prevents a silent DOWNGRADE to an older vulnerable release and the OSV CI
        // gate flags any advisory. The 3.15.1 ..< 4.0.0 cap keeps us on the 3.x line
        // (the 4.x X-Wing HPKE advisory CVE-2026-28815 does not affect 3.x). The
        // niche, security-critical crypto deps below stay EXACT (low conflict risk).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.15.1" ..< "4.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.5.1"),
        // EVM secp256k1 signing. Pinned EXACT (not a range) so a future release cannot
        // auto-pull; source-vetted 2026-05-29 (thin wrapper over Bitcoin Core's
        // libsecp256k1; the package's dev deps are reachable only from its own
        // plugins/tests and are pruned for downstream consumers). Kept at 0.21.1 (the
        // source-vetted pin); the libsecp256k1 C product and the recoverable module we use are
        // unchanged in later releases, so there is no reason to bump it (the Swift floor is now
        // 6.2 regardless, so the old "stay on tools 6.0" constraint no longer applies).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.21.1"),
        // Keccak-256 (the Ethereum hash; swift-crypto ships only NIST SHA-3, which uses
        // different padding). AGENTS.md forbids hand-rolled cryptography, so this is the
        // vetted provider: CryptoSwift is the established pure-Swift hash library (no C,
        // no build plugins, zero external package dependencies, tools 5.6 so it resolves
        // on our Swift 6.2 CI). Pinned EXACT; source-vetted 2026-05-29; we use only its
        // SHA3(.keccak256), wrapped behind MPPEVM's own Keccak256 type.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0"),
        // The official Model Context Protocol Swift SDK (module `MCP`), used by MPPMCP to bind
        // the 402 flow to JSON-RPC / MCP. Pinned to an IMMUTABLE commit on our fork
        // (amitach/swift-sdk) because the stock SDK cannot carry the MPP payment error frame:
        // `MCPError` has no `data` and hardwires -32042 to URL elicitation. The fork adds an
        // additive `MCPError.paymentRequired(code:message:data:)` case (the decoder disambiguates
        // by payload, so existing behavior is unchanged). The identical patch is upstream as
        // modelcontextprotocol/swift-sdk#229; swap this to a tagged upstream release once it
        // merges.
        // The SDK's own manifest supports Swift 6.0, but its transitive graph does not: swift-log
        // 1.13.x needs tools 6.2, swift-nio 2.100 + eventsource need 6.1. Pulling `MCP` therefore
        // raises this package's floor to Swift 6.2 (see the tools-version above). Package identity
        // is `swift-sdk` for both the fork and upstream URLs.
        .package(
            url: "https://github.com/amitach/swift-sdk.git",
            revision: "fe4faf15a7e51888f945ae74481453b172276164"
        ),
        // Hummingbird 2: the live HTTP-server binding for MPPProxy. Built natively on
        // swift-http-types (so the binding is a thin adapter; chosen over Vapor for that) and
        // reachable only from MPPHummingbird (the server stack). FLOOR range (Apple-package pinning
        // policy); swift-nio is already in the graph via the MCP SDK (and the MPPClientAsyncHTTP
        // transport links it directly).
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            "2.25.0" ..< "3.0.0"
        ),
        // hummingbird-websocket: the Hummingbird server-side WebSocket upgrade, used only by the
        // MPPWebSocketLive test target to boot a live server for the round-trip test (the adapter
        // itself is written against the framework-agnostic swift-websocket primitives below).
        // FLOOR range (Apple-ecosystem pinning policy); swift-nio is already in the graph.
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
            "2.7.0" ..< "3.0.0"
        ),
        // swift-websocket: the framework-agnostic WebSocket primitives (WSCore inbound/outbound,
        // WSClient). The MPPWebSocketLive adapter is written against these, not Hummingbird, so the
        // server binding works with any host that exposes a WSCore upgrade. Already in the graph
        // via
        // hummingbird-websocket; declared directly so the products are importable.
        .package(
            url: "https://github.com/hummingbird-project/swift-websocket.git",
            "1.6.0" ..< "2.0.0"
        ),
        // swift-argument-parser: the command-line surface for the shipped `mpp` executable. Apple
        // first-party with first-class Linux support, so the Linux CI builds it. FLOOR range
        // (Apple-package pinning policy); reachable only from the `mpp` executable, so no library
        // consumer pulls it.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // async-http-client: the SwiftNIO HTTP client backing MPPClientAsyncHTTP's transport, the
        // server-side / Linux-native counterpart to the URLSession transport. Reachable only from
        // that one library target, so a consumer that uses the URLSession transport pulls neither
        // it nor swift-nio. FLOOR range (Apple-ecosystem pinning policy); already in the graph
        // (resolved 1.33.1 transitively via the Hummingbird / MCP stacks).
        .package(
            url: "https://github.com/swift-server/async-http-client.git",
            "1.33.0" ..< "2.0.0"
        ),
        // swift-nio: NIOCore (ByteBuffer) + NIOHTTP1 (HTTPMethod / HTTPHeaders / HTTPResponseStatus)
        // for that transport's request/response mapping. Declared directly so the products are
        // importable; already in the graph (resolved 2.100.0 via Hummingbird / async-http-client).
        // FLOOR range (Apple-ecosystem pinning policy).
        .package(url: "https://github.com/apple/swift-nio.git", "2.100.0" ..< "3.0.0"),
    ],
    targets: [
        .target(name: "MPPCore"),
        .testTarget(
            name: "MPPCoreTests",
            dependencies: ["MPPCore"]
        ),
        .target(
            name: "MPPBodyDigest",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "MPPBodyDigestTests",
            dependencies: ["MPPBodyDigest"]
        ),
        .target(
            name: "MPPServer",
            dependencies: [
                "MPPCore",
                "MPPBodyDigest",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "MPPServerTests",
            dependencies: ["MPPServer", "MPPCore", "MPPBodyDigest"]
        ),
        .target(
            name: "MPPClient",
            dependencies: [
                "MPPCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                // HTTPTypesFoundation (same package) provides URLSession <-> HTTPRequest/
                // HTTPResponse bridging for the concrete URLSession transport. No new
                // package dependency.
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "MPPClientTests",
            dependencies: ["MPPClient", "MPPCore", "MPPDiscovery"]
        ),
        // MPPClientAsyncHTTP: an MPPHTTPTransport backed by async-http-client (SwiftNIO), the
        // server-side / Linux-native counterpart to MPPClient's URLSession transport. Isolated in
        // its own target so a consumer on the URLSession transport links neither async-http-client
        // nor swift-nio (only this target and the server-side MPPHummingbird pull swift-nio).
        // Mirrors URLSessionTransport's redirect block.
        .target(
            name: "MPPClientAsyncHTTP",
            dependencies: [
                "MPPClient",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // The live round-trip test boots a real Hummingbird server on an ephemeral loopback port
        // and
        // drives the transport over genuine network I/O (a stub cannot prove redirect handling).
        .testTarget(
            name: "MPPClientAsyncHTTPTests",
            dependencies: [
                "MPPClientAsyncHTTP",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPAuth: concrete PaymentAuthorizer implementations for an interactive or headless
        // payer (a terminal y/n prompt, and an Apple-only Touch ID / device-auth prompt). The
        // protocol and the pure authorizers (AllowAll, SpendingCap) live in MPPClient; the
        // I/O-bound ones live here so a library consumer that only needs the seam pulls neither
        // a TTY nor LocalAuthentication. BiometricPaymentAuthorizer is `#if`-guarded to Apple
        // platforms, so this target builds on Linux (TTY only).
        .target(
            name: "MPPAuth",
            dependencies: ["MPPClient", "MPPCore"]
        ),
        .testTarget(
            name: "MPPAuthTests",
            dependencies: ["MPPAuth", "MPPClient", "MPPCore"]
        ),
        // mpp: the shipped command-line tool. A thin ArgumentParser front end over the client
        // libraries (pay a 402 URL today; sign / discover / account / services / --mcp follow). It
        // links the client rails + MPPAuth (authorizers) but no server/FFI; biometric is guarded
        // out on Linux via MPPAuth, so the executable builds there too.
        .executableTarget(
            name: "mpp",
            dependencies: [
                "MPPCore",
                "MPPClient",
                "MPPAuth",
                "MPPEVM",
                "MPPTempo",
                "MPPStripe",
                "MPPDiscovery",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "MPPCLITests",
            dependencies: [
                "mpp", "MPPClient", "MPPCore", "MPPEVM", "MPPTempo", "MPPDiscovery",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPEVM: the EVM message-signing layer (Keccak-256, the secp256k1 recoverable
        // signer, and EIP-712 struct hashing). Kept out of MPPCore/MPPClient so a
        // non-EVM consumer pulls neither CryptoSwift nor swift-secp256k1.
        .target(
            name: "MPPEVM",
            dependencies: [
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ]
        ),
        .testTarget(
            name: "MPPEVMTests",
            dependencies: ["MPPEVM"]
        ),
        // MPPDiscovery: OpenAPI 3.x discovery (x-payment-info / x-service-info).
        // Reuses MPPCore's Amount (integer-string validation) and pure Foundation
        // JSON; no EVM / crypto dependency.
        .target(
            name: "MPPDiscovery",
            dependencies: ["MPPCore"]
        ),
        .testTarget(
            name: "MPPDiscoveryTests",
            dependencies: ["MPPDiscovery", "MPPCore"]
        ),
        // MPPProxy: framework-neutral 402 reverse-proxy engine; no server dependency, zero Rust.
        .target(
            name: "MPPProxy",
            dependencies: ["MPPServer", "MPPClient", "MPPCore", "MPPDiscovery"]
        ),
        .testTarget(
            name: "MPPProxyTests",
            dependencies: ["MPPProxy", "MPPServer", "MPPClient", "MPPCore", "MPPDiscovery"]
        ),
        // MPPHummingbird: live HTTP-server binding for MPPProxy; the only target linking Hummingbird
        // (it shares swift-nio with the MPPClientAsyncHTTP transport); entry points @available
        // macOS 14 (package platform stays 13).
        .target(
            name: "MPPHummingbird",
            dependencies: [
                "MPPProxy", "MPPServer", "MPPCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "MPPHummingbirdTests",
            dependencies: [
                "MPPHummingbird", "MPPProxy", "MPPServer", "MPPClient", "MPPCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        // MPPTempo: the Tempo charge payment method, CLIENT side. Ships the
        // zero-amount EIP-712 proof credential (no on-chain settlement, no FFI 0x76
        // transaction layer). Wires MPPEVM's proof signer into MPPClient's
        // PaymentMethodClient seam over MPPCore's Challenge/Credential types. Kept
        // off MPPServer so a client-only consumer does not pull the server stack
        // (MPPServer / MPPBodyDigest / swift-crypto); the verifier lives in
        // MPPTempoServer below.
        .target(
            name: "MPPTempo",
            dependencies: [
                "MPPCore", "MPPEVM", "MPPClient",
                // HTTPRequest/HTTPResponse for the JSON-RPC client, which runs over the
                // shared MPPHTTPTransport seam (same currency type as the 402 flow).
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "MPPTempoTests",
            dependencies: [
                "MPPTempo",
                "MPPCore",
                "MPPEVM",
                "MPPClient",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPTempoServer: the Tempo charge method, SERVER side (TempoProofVerifier).
        // Split from MPPTempo so a client-only consumer is not forced to depend on
        // MPPServer + swift-crypto. Reuses MPPTempo's shared types (TempoChargeRequest,
        // ProofVariant, TempoChain, TempoMethod) and MPPServer's PaymentMethodServer
        // seam; recovers the proof via MPPEVM.
        .target(
            name: "MPPTempoServer",
            dependencies: ["MPPTempo", "MPPCore", "MPPEVM", "MPPServer"]
        ),
        .testTarget(
            name: "MPPTempoServerTests",
            dependencies: [
                "MPPTempoServer", "MPPTempo", "MPPCore", "MPPEVM", "MPPServer",
                // Construct EVMRPC + a stub MPPHTTPTransport for the RPC provider tests.
                "MPPClient",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPWebSocket: the live WebSocket transport for metered Tempo sessions. This first cut is
        // the transport-agnostic SERVER orchestration over a `SessionSocket` abstraction, atop the
        // MPPTempoServer metering core (SessionStream) + the SessionWebSocketFrame codec. The live
        // hummingbird-websocket socket adapter and the cross-SDK conformance land in later PRs, so
        // the nio dependency is added when it is first exercised over a real socket, not before.
        .target(
            name: "MPPWebSocket",
            dependencies: ["MPPCore", "MPPTempoServer"]
        ),
        .testTarget(
            name: "MPPWebSocketTests",
            dependencies: ["MPPWebSocket", "MPPCore", "MPPTempoServer"]
        ),
        // MPPWebSocketLive: the live socket adapters that drive MPPWebSocket's orchestration over a
        // real WebSocket - a hummingbird-websocket server upgrade handler and a WSClient consumer.
        // The only target that links the swift-websocket / nio WebSocket graph, so the pure
        // orchestration core (MPPWebSocket) stays dependency-free.
        .target(
            name: "MPPWebSocketLive",
            dependencies: [
                // MPPCore for Receipt; MPPWebSocket for the orchestration seams. MPPTempoServer is
                // pulled transitively via MPPWebSocket and is not used here directly.
                "MPPWebSocket", "MPPCore",
                .product(name: "WSClient", package: "swift-websocket"),
                .product(name: "WSCore", package: "swift-websocket"),
            ]
        ),
        .testTarget(
            name: "MPPWebSocketLiveTests",
            dependencies: [
                "MPPWebSocketLive", "MPPWebSocket", "MPPCore", "MPPTempoServer",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        // MPPStripe: the Stripe charge method, CLIENT side (StripeChargeMethod). Presents a
        // Shared Payment Token in the credential; no crypto (no MPPEVM) and no Stripe secret. The
        // server side (StripeChargeVerifier + the PaymentIntent client) lands in MPPStripeServer,
        // split off so a client-only consumer is not forced onto MPPServer + swift-crypto.
        .target(
            name: "MPPStripe",
            dependencies: ["MPPCore", "MPPClient"]
        ),
        .testTarget(
            name: "MPPStripeTests",
            dependencies: ["MPPStripe", "MPPCore", "MPPClient"]
        ),
        // MPPStripeServer: the Stripe charge method, SERVER side (StripeChargeVerifier + the
        // concrete StripePaymentIntentClient over MPPHTTPTransport). Reuses MPPStripe's shared
        // types, MPPServer's PaymentMethodServer seam, and swift-crypto for the idempotency key.
        .target(
            name: "MPPStripeServer",
            dependencies: [
                "MPPStripe", "MPPCore", "MPPServer", "MPPClient",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "MPPStripeServerTests",
            dependencies: [
                "MPPStripeServer", "MPPStripe", "MPPCore", "MPPServer", "MPPClient",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPHTML: the server-rendered HTML payment page. A pure renderer from a Challenge plus a
        // payment method's HTML hook, themeable and opt-in; depends only on MPPCore (no server or
        // transport), so a host wires it into any 402 path. Identifiers (DOM ids, classes, CSS
        // vars) match the mppx peer for cross-implementation method-script interop.
        .target(
            name: "MPPHTML",
            dependencies: ["MPPCore"]
        ),
        .testTarget(
            name: "MPPHTMLTests",
            dependencies: ["MPPHTML", "MPPCore"]
        ),
        // MPPHTMLServer: wires MPPHTML into MPPServer's 402 path -- a ChallengePresenter that
        // renders the HTML page on Accept: text/html, plus the browser service worker that submits
        // the credential. Split from MPPHTML (like MPPStripe/MPPStripeServer) so a renderer-only
        // consumer is not forced onto MPPServer.
        .target(
            name: "MPPHTMLServer",
            dependencies: [
                "MPPHTML", "MPPServer", "MPPCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "MPPHTMLServerTests",
            dependencies: [
                "MPPHTMLServer", "MPPHTML", "MPPServer", "MPPCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        // MPPMCP: binds the 402 flow to JSON-RPC / Model Context Protocol on the official MCP
        // SDK (module `MCP`). Rail-agnostic: it composes MPPServer's mint/verify pipeline and
        // MPPClient's method seam, so it depends on neither MPPTempo nor any Rust. The payment
        // method (e.g. the Tempo zero-amount proof) is injected by the consumer / tests.
        .target(
            name: "MPPMCP",
            dependencies: [
                "MPPCore",
                "MPPServer",
                "MPPClient",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "MPPMCPTests",
            dependencies: [
                "MPPMCP",
                "MPPCore",
                "MPPServer",
                "MPPClient",
                // The Tempo zero-amount proof method is the payment method exercised end to end
                // (client builds it, server verifies it); MPPEVM provides the Secp256k1Signer.
                "MPPTempo",
                "MPPTempoServer",
                "MPPEVM",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        // MPPConformanceServer: a dev-only HTTP listener (a Hummingbird server via MPPHummingbird's
        // GatedResponder) that exposes MPPTempoServer's verifier so the mppx reference CLIENT can
        // pay
        // our server over a real socket (the reverse conformance direction). No `.executable`
        // product
        // is declared, so it is internal tooling (run via `swift run MPPConformanceServer`), never
        // part of the shipped library surface.
        .executableTarget(
            name: "MPPConformanceServer",
            dependencies: [
                "MPPCore",
                "MPPServer",
                "MPPTempo",
                "MPPTempoServer",
                "MPPHummingbird",
                // MPPProxy + MPPDiscovery back the proxy conformance route: the proxy engine
                // gates a paid route, and PaymentInfo/Info come from the discovery model.
                "MPPProxy",
                "MPPDiscovery",
                // The reverse session route's deps (MPPClient/MPPEVM for live RPC + the
                // operator key, MPPTempoFFI for the close builder) are added only under the
                // FFI gate via conformanceServerFFIDeps, so the default proof-only server
                // pulls none of them.
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ] + conformanceServerFFIDeps,
            swiftSettings: conformanceServerFFISettings
        ),
        // MPPMCPConformanceServer: a dev-only MCP server over stdio (no product) that gates a
        // `premium` tool behind a zero-amount Tempo proof via MPPMCP. The reference mppx
        // `mcp-sdk` CLIENT spawns it and pays it, proving the JSON-RPC / MCP payment binding
        // interoperates with the real peer over a real transport (run via the conformance scripts).
        .executableTarget(
            name: "MPPMCPConformanceServer",
            dependencies: [
                "MPPCore",
                "MPPServer",
                "MPPTempoServer",
                "MPPMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        // MPPMCPConformanceClient: the reverse direction. A dev-only MCP CLIENT (no product) that
        // spawns the reference mppx mcp-sdk SERVER over stdio and pays its payment-gated tool via
        // MPPMCP's MCPPaymentClient + the Tempo zero-amount proof. Proves our client interoperates
        // with the real peer's MCP server (run via the conformance scripts).
        .executableTarget(
            name: "MPPMCPConformanceClient",
            dependencies: [
                "MPPCore",
                "MPPClient",
                "MPPEVM",
                "MPPTempo",
                "MPPMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// MPPTempoFFI: the OPT-IN Tempo `0x76` transaction builder, the only target that links
// the Rust `tempo-tx-ffi` shim. MPPCore / MPPClient / MPPServer / MPPTempo never depend
// on it, so a consumer of those pulls ZERO Rust (the isolation invariant, enforced by
// Scripts/assert-ffi-isolation.sh). It is wired one of two ways:
//
//   - PUBLISHED (Apple, external consumers): when the tempoFFIReleaseURL +
//     tempoFFIReleaseChecksum constants below are set, an always-declared
//     `binaryTarget(url:checksum:)` downloads the released xcframework. No env gate, no
//     Rust toolchain on the consumer.
//   - FROM SOURCE (dev / CI, and Linux): when the `MPP_TEMPO_FFI` env var is set, the
//     xcframework (Apple) or the static archive (Linux, via CTempoTxFFI + linkerSettings)
//     is built locally by the rust/tempo-tx-ffi scripts. This is how CI exercises the
//     actual build, so it takes PRECEDENCE over the published asset when both are present.
//
// SwiftPM has no library binaryTarget on Linux (only .xcframework / .artifactbundle), so
// Linux always builds from source; the linkerSettings unsafeFlags make the package
// non-consumable as a remote dependency there, which is acceptable (Apple is the
// published-install target; a Linux consumer builds from source).
// Set by the release process (see .github/workflows/release-ffi.yml, which prints both
// values). When BOTH are non-empty, an external Apple consumer downloads the published
// xcframework via a url+checksum binaryTarget: no env gate, no Rust toolchain. Kept as
// literal constants here (not an external file) so editing them invalidates SwiftPM's
// manifest cache, which is keyed on Package.swift.
let tempoFFIReleaseURL =
    "https://github.com/amitach/mpp-swift/releases/download/tempo-tx-ffi-v0.0.8/TempoTxFFI.xcframework.zip"
let tempoFFIReleaseChecksum = "3ae4479b23c550850897939c5df59f6f4365bcd62e85e9cfe50d87c1ad52fab3"

// The MPPTempoFFI target + test target that sit on top of a given binary target
// (returned, not appended, so this stays free of the main-actor-isolated `package`).
func mppTempoFFITargets(binaryName: String) -> [Target] {
    [
        .target(
            name: "MPPTempoFFI",
            dependencies: ["MPPTempo", "MPPEVM", .target(name: binaryName)]
        ),
        .testTarget(
            name: "MPPTempoFFITests",
            // MPPClient (URLSessionTransport) + MPPCore (JSONValue) for the gated live
            // Moderato e2e, which drives EVMRPC over a real transport. MPPTempoServer for the
            // subscription-renewer live e2e (TempoSubscriptionRenewer + AccessKeyStore).
            dependencies: [
                "MPPTempoFFI",
                "MPPTempo",
                "MPPTempoServer",
                "MPPEVM",
                "MPPClient",
                "MPPCore",
            ]
        ),
    ]
}

#if os(Linux)
    if ffiFromSource {
        package.products.append(.library(name: "MPPTempoFFI", targets: ["MPPTempoFFI"]))
        package.targets.append(.target(name: "CTempoTxFFI"))
        package.targets.append(contentsOf: [
            .target(
                name: "MPPTempoFFI",
                dependencies: ["MPPTempo", "MPPEVM", "CTempoTxFFI"],
                linkerSettings: [
                    // The static archive built by rust/tempo-tx-ffi/build-linux-lib.sh,
                    // plus the system libraries a Rust staticlib pulls in on linux-gnu
                    // (from `rustc --print native-static-libs`; libc is already on the
                    // Swift link line, gcc_s is the unwinder).
                    .unsafeFlags([
                        "-L", "artifacts/linux", "-ltempo_tx_ffi",
                        "-lm", "-ldl", "-lpthread", "-lrt", "-lutil", "-lgcc_s",
                    ]),
                ]
            ),
            .testTarget(
                name: "MPPTempoFFITests",
                dependencies: [
                    "MPPTempoFFI", "MPPTempo", "MPPTempoServer", "MPPEVM", "MPPClient", "MPPCore",
                ]
            ),
        ])
    }
#else
    if ffiFromSource {
        // CI / dev: build + link the local xcframework so the build itself is exercised.
        package.products.append(.library(name: "MPPTempoFFI", targets: ["MPPTempoFFI"]))
        package.targets.append(.binaryTarget(
            name: "TempoTxFFIBinary",
            path: "artifacts/TempoTxFFI.xcframework"
        ))
        package.targets.append(contentsOf: mppTempoFFITargets(binaryName: "TempoTxFFIBinary"))
    } else if !tempoFFIReleaseURL.isEmpty, !tempoFFIReleaseChecksum.isEmpty {
        // Published: external consumers download the released xcframework. No gate.
        package.products.append(.library(name: "MPPTempoFFI", targets: ["MPPTempoFFI"]))
        package.targets.append(.binaryTarget(
            name: "TempoTxFFIBinary",
            url: tempoFFIReleaseURL,
            checksum: tempoFFIReleaseChecksum
        ))
        package.targets.append(contentsOf: mppTempoFFITargets(binaryName: "TempoTxFFIBinary"))
    }
#endif
