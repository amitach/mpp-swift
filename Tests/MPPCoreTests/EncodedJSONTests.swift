import Foundation
import Testing
@testable import MPPCore

// Spec: draft-payment-intent-charge-00 — request/opaque are JCS-serialized
// (RFC 8785) then base64url-encoded without padding (RFC 4648 §5). The encoded
// string is bound by the challenge-id HMAC, so a received value must be
// preserved byte-for-byte.
@Suite("EncodedJSON")
struct EncodedJSONTests {
    @Test("wraps a received value verbatim")
    func preservesReceivedValueVerbatim() {
        // A value whose decoding would re-sort keys differently must NOT change.
        let wire = "eyJiIjoyLCJhIjoxfQ"
        #expect(EncodedJSON(wire).rawValue == wire)
    }

    @Test("encodes a JSONValue as unpadded base64url of its JCS form")
    func encodesJSONValueCanonically() {
        let json: JSONValue = ["b": 2, "a": 1]
        let encoded = EncodedJSON(json: json)
        // JCS sorts keys: {"a":1,"b":2}; base64url, no padding, no "=".
        #expect(encoded.rawValue == Base64URL.encode(Data(#"{"a":1,"b":2}"#.utf8)))
        #expect(!encoded.rawValue.contains("="))
    }

    @Test("decodes back to the canonical JSON bytes")
    func decodesToCanonicalBytes() throws {
        let json: JSONValue = ["amount": "1000000", "nested": ["x": true]]
        let encoded = EncodedJSON(json: json)
        let bytes = try encoded.decodedData()
        #expect(String(bytes: bytes, encoding: .utf8) == json.canonicalized())
    }

    @Test("decodedData throws on a non-base64url value")
    func decodeRejectsInvalidBase64URL() {
        #expect(throws: Base64URL.DecodeError.self) {
            try EncodedJSON("not valid base64url!!").decodedData()
        }
    }
}
