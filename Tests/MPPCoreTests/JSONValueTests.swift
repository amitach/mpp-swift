import Testing
@testable import MPPCore

// Spec: RFC 8785 (JSON Canonicalization Scheme), used for the base64url `request`
// parameter (draft-payment-intent-charge-00: "serialized using JCS").
// Reference comparison: both refs delegate JCS to a library — mppx to ox's
// Json.canonicalize, mpp-rs to the serde_json_canonicalizer crate — so there is
// no ref code to port; RFC 8785 is authoritative. MPP request JSON is
// integer-only (amounts are strings), so the float-serialization rule is not
// exercised; numbers are modelled as integers, structurally excluding floats.
@Suite("JSONValue canonicalization (RFC 8785)")
struct JSONValueTests {
    // A single backslash, built from its code point so expected strings can be
    // composed without literal escape sequences.
    private let backslash = "\u{5C}"

    @Test("sorts object keys lexicographically")
    func sortsKeys() {
        let value: JSONValue = ["b": 1, "a": 2, "c": 3]
        #expect(value.canonicalized() == #"{"a":2,"b":1,"c":3}"#)
    }

    @Test("sorts object keys by UTF-16 code units (ASCII before non-ASCII)")
    func sortsKeysByUTF16() {
        let value: JSONValue = ["é": 1, "a": 2, "z": 3]
        // 'a'=U+0061, 'z'=U+007A, 'é'=U+00E9 -> a, z, é
        #expect(value.canonicalized() == #"{"a":2,"z":3,"é":1}"#)
    }

    @Test("emits no insignificant whitespace and sorts nested objects")
    func nestedNoWhitespace() {
        let value: JSONValue = ["outer": ["y": 2, "x": 1], "first": "v"]
        #expect(value.canonicalized() == #"{"first":"v","outer":{"x":1,"y":2}}"#)
    }

    @Test("serializes arrays in order, preserving element order")
    func arraysPreserveOrder() {
        let value: JSONValue = ["list": [3, 1, 2]]
        #expect(value.canonicalized() == #"{"list":[3,1,2]}"#)
    }

    @Test("escapes quote, backslash, and the named control characters")
    func escapesNamedControls() {
        #expect(JSONValue.string("a\"b\\c").canonicalized() == #""a\"b\\c""#)
        let named = "\u{08}\u{09}\u{0A}\u{0C}\u{0D}"
        #expect(JSONValue.string(named).canonicalized() == #""\b\t\n\f\r""#)
    }

    @Test("escapes other control characters as lowercase u00xx")
    func escapesOtherControls() {
        #expect(JSONValue.string("\u{00}").canonicalized() == "\"\(backslash)u0000\"")
        #expect(JSONValue.string("\u{01}").canonicalized() == "\"\(backslash)u0001\"")
        #expect(JSONValue.string("\u{1F}").canonicalized() == "\"\(backslash)u001f\"")
    }

    @Test("emits non-ASCII characters literally, not as escape sequences")
    func nonAsciiLiteral() {
        #expect(JSONValue.string("café €").canonicalized() == #""café €""#)
    }

    @Test("serializes booleans, null, and integers canonically")
    func scalars() {
        #expect(JSONValue.bool(true).canonicalized() == "true")
        #expect(JSONValue.bool(false).canonicalized() == "false")
        #expect(JSONValue.null.canonicalized() == "null")
        #expect(JSONValue.integer(0).canonicalized() == "0")
        #expect(JSONValue.integer(-7).canonicalized() == "-7")
        #expect(JSONValue.integer(42431).canonicalized() == "42431")
    }

    @Test("canonicalizes an MPP-style charge request (amounts as strings)")
    func mppChargeRequest() {
        let request: JSONValue = [
            "currency": "0xabc",
            "amount": "1000000",
            "recipient": "0xdef",
            "methodDetails": ["chainId": 42431, "feePayer": true],
        ]
        let expected = #"{"amount":"1000000","currency":"0xabc","#
            + #""methodDetails":{"chainId":42431,"feePayer":true},"recipient":"0xdef"}"#
        #expect(request.canonicalized() == expected)
    }
}
