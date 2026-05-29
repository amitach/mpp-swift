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
        .library(name: "MPPKeccak", targets: ["MPPKeccak"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // EVM secp256k1 signing. Pinned EXACT (not a range) so a future release cannot
        // auto-pull; source-vetted 2026-05-28 (thin wrapper over Bitcoin Core's
        // libsecp256k1; dev deps excluded at tagged releases; build plugin only copies
        // in-package sources). Keccak-256 is vendored, not from a package.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
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
            ]
        ),
        .testTarget(
            name: "MPPClientTests",
            dependencies: ["MPPClient", "MPPCore"]
        ),
        .target(
            name: "MPPKeccak",
            dependencies: [
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
            ]
        ),
        .testTarget(
            name: "MPPKeccakTests",
            dependencies: ["MPPKeccak"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
