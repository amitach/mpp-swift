import Foundation
import MCP
import MPPCore
import Testing
@testable import MPPMCP

@Suite("MCP value bridge")
struct MCPValueBridgeTests {
    @Test("JSONValue round-trips through MCP.Value for every representable case")
    func roundTrip() throws {
        let original: JSONValue = [
            "string": "hi",
            "int": 42,
            "negative": -7,
            "bool": true,
            "null": .null,
            "array": [1, "two", false],
            "nested": ["k": ["deep": 9]],
        ]
        let bridged = MCP.Value(original)
        let back = try JSONValue(mcp: bridged)
        #expect(back == original)
    }

    @Test("integer maps to MCP .int and back to .integer")
    func integerMapping() throws {
        #expect(MCP.Value(JSONValue.integer(123)) == .int(123))
        let back = try JSONValue(mcp: .int(123))
        #expect(back == .integer(123))
    }

    @Test("a non-integer number fails closed (floats are unrepresentable)")
    func doubleRejected() {
        #expect(throws: JSONValue.BridgeError.unsupportedNumber) {
            try JSONValue(mcp: .double(1.5))
        }
    }

    @Test("binary data fails closed")
    func dataRejected() {
        #expect(throws: JSONValue.BridgeError.unsupportedData) {
            try JSONValue(mcp: .data(mimeType: "application/octet-stream", Data([0x01])))
        }
    }

    @Test("a nested unsupported value propagates the error")
    func nestedRejection() {
        #expect(throws: JSONValue.BridgeError.unsupportedNumber) {
            try JSONValue(mcp: .object(["outer": .array([.double(2.0)])]))
        }
    }

    @Test("a hostile, deeply-nested value fails closed instead of overflowing")
    func tooDeepRejected() {
        var deep = MCP.Value.string("leaf")
        for _ in 0 ..< (JSONValue.maxBridgeDepth + 50) {
            deep = .array([deep])
        }
        #expect(throws: JSONValue.BridgeError.tooDeep) {
            try JSONValue(mcp: deep)
        }
    }

    @Test("nesting within the depth limit still converts")
    func withinDepthLimitOK() throws {
        var value = MCP.Value.string("leaf")
        for _ in 0 ..< (JSONValue.maxBridgeDepth - 2) {
            value = .array([value])
        }
        _ = try JSONValue(mcp: value)
    }
}
