import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1: Authorization: Payment 1*SP
// base64url-nopad, where the payload is a JSON object {challenge, source?,
// payload}. The challenge is echoed verbatim for the server's binding re-check.
@Suite("Credential")
struct CredentialTests {
    private func sampleChallenge() throws -> Challenge {
        try Challenge(
            id: "x7Tg2", realm: "api", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON(json: ["amount": "1000000"])
        )
    }

    private func sample() throws -> Credential {
        try Credential(
            challenge: sampleChallenge(),
            source: "did:pkh:eip155:1:0xabc",
            payload: ["signature": "0xdeadbeef", "nonce": 7]
        )
    }

    @Test("round-trips through the Authorization header value")
    func roundTripsThroughHeader() throws {
        let credential = try sample()
        let header = try credential.headerValue
        #expect(header.hasPrefix("Payment "))
        #expect(try Credential(headerValue: header) == credential)
    }

    @Test("echoes the challenge verbatim, preserving the bound request bytes")
    func echoesChallengeVerbatim() throws {
        let credential = try sample()
        let decoded = try Credential(headerValue: credential.headerValue)
        #expect(try decoded.challenge == sampleChallenge())
        #expect(try decoded.challenge.request.rawValue == sampleChallenge().request.rawValue)
    }

    @Test("carries a method-specific payload opaquely, including nested values")
    func carriesPayload() throws {
        let credential = try Credential(
            challenge: sampleChallenge(),
            payload: ["proof": ["v": 2, "parts": [1, 2]], "addr": "0xabc"]
        )
        let decoded = try Credential(headerValue: credential.headerValue)
        #expect(decoded.payload == credential.payload)
        #expect(decoded.source == nil)
    }

    @Test("omits source from the JSON when absent")
    func omitsAbsentSource() throws {
        let credential = try Credential(challenge: sampleChallenge(), payload: ["k": "v"])
        let token = try credential.headerValue.split(separator: " ")[1]
        let json = try #require(String(bytes: Base64URL.decode(String(token)), encoding: .utf8))
        #expect(!json.contains("source"))
    }

    @Test("accepts the Payment scheme case-insensitively")
    func schemeIsCaseInsensitive() throws {
        let header = try sample().headerValue
        let lowercased = header.replacingOccurrences(of: "Payment ", with: "payment ")
        #expect(try Credential(headerValue: lowercased) == sample())
    }

    @Test("accepts one or more spaces between scheme and token (1*SP)")
    func acceptsMultipleSpaces() throws {
        let token = try sample().headerValue.split(separator: " ")[1]
        #expect(try Credential(headerValue: "Payment   \(token)") == sample())
    }

    @Test("rejects a value with no Payment scheme")
    func rejectsMissingScheme() {
        #expect(throws: Credential.ParsingError.missingScheme) {
            try Credential(headerValue: "Bearer abc")
        }
        #expect(throws: Credential.ParsingError.missingScheme) {
            try Credential(headerValue: "Payment")
        }
    }

    @Test("rejects a non-base64url token")
    func rejectsInvalidBase64URL() {
        #expect(throws: Credential.ParsingError.self) {
            try Credential(headerValue: "Payment not+base64url=")
        }
    }

    @Test("rejects a token that is not a valid credential object")
    func rejectsInvalidJSON() {
        let token = Base64URL.encode(Data(#"{"source":"x"}"#.utf8)) // missing challenge/payload
        #expect(throws: Credential.ParsingError.self) {
            try Credential(headerValue: "Payment \(token)")
        }
    }
}
