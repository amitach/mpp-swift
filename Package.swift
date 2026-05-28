// swift-tools-version: 6.0
import PackageDescription

// mpp-swift — Swift SDK for the Machine Payments Protocol (MPP).
//
// Products and targets grow one workstream at a time (see the implementation
// plan). This bootstrap declares only `MPPCore`, the always-on protocol layer
// every other module builds on. Client/Server/MCP/Discovery/Proxy/rails are
// added as their workstreams land, each behind its own product so consumers
// depend on exactly what they need.
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
    ],
    targets: [
        .target(name: "MPPCore"),
        .testTarget(
            name: "MPPCoreTests",
            dependencies: ["MPPCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
