import MCP
import MPPCore

// Boundary converter between MPPCore's `JSONValue` (the protocol's integer-only JSON, used for
// canonicalization + the challenge-id binding) and the MCP SDK's `Value` (its JSON-RPC payload
// type). The MCP transport carries challenges/credentials/receipts as native JSON `Value`s, so a
// codec round-trips them through `JSONValue` to reuse MPPCore's JCS + EncodedJSON machinery.
//
// `JSONValue` deliberately has no floating-point case (floats are unrepresentable, not merely
// rejected); the conversion preserves that invariant by failing closed on a `Value.double` or
// `Value.data` rather than coercing.

extension MCP.Value {
    /// Builds an MCP `Value` from a MPPCore `JSONValue`. Total: every `JSONValue` case maps.
    init(_ json: JSONValue) {
        switch json {
        case let .object(members):
            self = .object(members.mapValues(MCP.Value.init))
        case let .array(elements):
            self = .array(elements.map(MCP.Value.init))
        case let .string(string):
            self = .string(string)
        case let .integer(integer):
            self = .int(Int(integer))
        case let .bool(bool):
            self = .bool(bool)
        case .null:
            self = .null
        }
    }
}

extension JSONValue {
    /// An MCP `Value` that has no `JSONValue` representation (a non-integer number, or binary
    /// data), or one nested past ``maxBridgeDepth``.
    enum BridgeError: Error, Hashable {
        case unsupportedNumber
        case unsupportedData
        case tooDeep
    }

    /// Maximum nesting depth converted from an untrusted MCP value. Legitimate payment payloads are
    /// shallow (a credential's challenge.request is depth ~5); this bounds the recursion here (and
    /// the subsequent `canonicalized()` pass) so a hostile, deeply-nested credential / challenge
    /// fails closed instead of risking a stack overflow.
    static let maxBridgeDepth = 100

    /// Builds a MPPCore `JSONValue` from an MCP `Value`, failing closed on a value the protocol's
    /// integer-only JSON cannot represent, or on nesting past ``maxBridgeDepth``.
    init(mcp value: MCP.Value) throws(BridgeError) {
        try self.init(mcp: value, depth: 0)
    }

    private init(mcp value: MCP.Value, depth: Int) throws(BridgeError) {
        guard depth <= Self.maxBridgeDepth else { throw .tooDeep }
        switch value {
        case let .object(members):
            self = try .object(Self.bridgeObject(members, depth: depth + 1))
        case let .array(elements):
            self = try .array(Self.bridgeArray(elements, depth: depth + 1))
        case let .string(string):
            self = .string(string)
        case let .int(integer):
            self = .integer(Int64(integer))
        case let .bool(bool):
            self = .bool(bool)
        case .null:
            self = .null
        case .double:
            throw .unsupportedNumber
        case .data:
            throw .unsupportedData
        }
    }

    private static func bridgeObject(
        _ members: [String: MCP.Value], depth: Int
    ) throws(BridgeError) -> [String: JSONValue] {
        var converted: [String: JSONValue] = [:]
        converted.reserveCapacity(members.count)
        for (key, element) in members {
            converted[key] = try JSONValue(mcp: element, depth: depth)
        }
        return converted
    }

    private static func bridgeArray(
        _ elements: [MCP.Value], depth: Int
    ) throws(BridgeError) -> [JSONValue] {
        var converted: [JSONValue] = []
        converted.reserveCapacity(elements.count)
        for element in elements {
            try converted.append(JSONValue(mcp: element, depth: depth))
        }
        return converted
    }
}
