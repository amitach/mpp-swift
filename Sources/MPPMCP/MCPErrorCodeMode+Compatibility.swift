import MPPCore

public extension MCPErrorCodeMode {
    /// The MCP error-code mode a compatibility profile selects: `.mppx` maps to ``peerCompatible``
    /// (the `-32042` the reference client recognizes, this type's default); `.specCorrect` maps to
    /// ``specCorrect`` (the §10.1 spec codes).
    init(_ compatibility: MPPCompatibility) {
        self = switch compatibility {
        case .mppx: .peerCompatible
        case .specCorrect: .specCorrect
        }
    }
}
