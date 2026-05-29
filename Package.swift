// swift-tools-version: 6.0
import PackageDescription

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
        .library(name: "MPPEVM", targets: ["MPPEVM"]),
        .library(name: "MPPDiscovery", targets: ["MPPDiscovery"]),
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
        // plugins/tests and are pruned for downstream consumers). 0.21.1 is the last
        // release on swift-tools 6.0; >= 0.22.0 requires tools 6.1, which would drop our
        // declared Swift 6.0 support (the libsecp256k1 C product and the recoverable
        // module we use are identical).
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.21.1"),
        // Keccak-256 (the Ethereum hash; swift-crypto ships only NIST SHA-3, which uses
        // different padding). AGENTS.md forbids hand-rolled cryptography, so this is the
        // vetted provider: CryptoSwift is the established pure-Swift hash library (no C,
        // no build plugins, zero external package dependencies, tools 5.6 so it resolves
        // on our Swift 6.0 CI). Pinned EXACT; source-vetted 2026-05-29; we use only its
        // SHA3(.keccak256), wrapped behind MPPEVM's own Keccak256 type.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0"),
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
            dependencies: ["MPPClient", "MPPCore"]
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
    ],
    swiftLanguageModes: [.v6]
)
