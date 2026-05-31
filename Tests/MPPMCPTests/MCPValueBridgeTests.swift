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
}
