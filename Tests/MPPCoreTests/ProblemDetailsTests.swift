import Foundation
import Testing
@testable import MPPCore

// Spec: RFC 9457 problem+json, used by draft-httpauth-payment-00 §8 for 402
// error bodies. Five optional standard members (type/title/status/detail/
// instance) plus extension members (e.g. MPP's challengeId) at the same level.
@Suite("ProblemDetails")
struct ProblemDetailsTests {
    private func decode(_ json: String) throws -> ProblemDetails {
        try JSONDecoder().decode(ProblemDetails.self, from: Data(json.utf8))
    }

    private func encodedObject(_ problem: ProblemDetails) throws -> [String: Any] {
        let data = try JSONEncoder().encode(problem)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("decodes the standard members, with status as an integer")
    func decodesStandardMembers() throws {
        let problem = try decode(#"""
        {"type":"https://paymentauth.org/problems/payment-expired",
         "title":"Payment Expired","status":402,
         "detail":"The challenge expired.","instance":"/pay/42"}
        """#)
        #expect(problem.type == "https://paymentauth.org/problems/payment-expired")
        #expect(problem.title == "Payment Expired")
        #expect(problem.status == 402)
        #expect(problem.detail == "The challenge expired.")
        #expect(problem.instance == "/pay/42")
        #expect(problem.extensions.isEmpty)
    }

    @Test("captures MPP extension members (challengeId) in extensions")
    func capturesExtensionMembers() throws {
        let problem = try decode(#"""
        {"type":"https://paymentauth.org/problems/payment-required",
         "status":402,"challengeId":"qB3wErTyU7iOpAsD9fGhJk"}
        """#)
        #expect(problem.status == 402)
        #expect(problem.extensions["challengeId"] == "qB3wErTyU7iOpAsD9fGhJk")
        // Standard members never leak into extensions.
        #expect(problem.extensions["type"] == nil)
        #expect(problem.extensions["status"] == nil)
    }

    @Test("treats every standard member as optional")
    func membersAreOptional() throws {
        let problem = try decode("{}")
        #expect(problem.type == nil)
        #expect(problem.title == nil)
        #expect(problem.status == nil)
        #expect(problem.detail == nil)
        #expect(problem.instance == nil)
        #expect(problem.extensions.isEmpty)
    }

    @Test("omits absent standard members from the encoded JSON")
    func omitsAbsentMembers() throws {
        let object = try encodedObject(ProblemDetails(status: 402))
        #expect(object["status"] as? Int == 402)
        #expect(object["type"] == nil)
        #expect(object["title"] == nil)
        #expect(object["detail"] == nil)
        #expect(object["instance"] == nil)
    }

    @Test("encodes extension members at the top level alongside standard ones")
    func encodesExtensionsFlat() throws {
        let problem = ProblemDetails(
            type: "https://paymentauth.org/problems/payment-required",
            status: 402,
            extensions: ["challengeId": "abc", "retryAfter": 30]
        )
        let object = try encodedObject(problem)
        #expect(object["type"] as? String == "https://paymentauth.org/problems/payment-required")
        #expect(object["status"] as? Int == 402)
        #expect(object["challengeId"] as? String == "abc")
        #expect(object["retryAfter"] as? Int == 30)
    }

    @Test("round-trips standard and extension members unchanged")
    func roundTrips() throws {
        let problem = ProblemDetails(
            type: "https://paymentauth.org/problems/verification-failed",
            title: "Verification Failed", status: 402,
            detail: "The signature did not verify.", instance: "/pay/7",
            extensions: ["challengeId": "k9", "nested": ["a": 1]]
        )
        let data = try JSONEncoder().encode(problem)
        #expect(try JSONDecoder().decode(ProblemDetails.self, from: data) == problem)
    }

    @Test("no standard member leaks into extensions on decode, even when all are present")
    func standardMembersNeverLeakOnDecode() throws {
        let problem = try decode(#"""
        {"type":"about:blank","title":"X","status":402,
         "detail":"d","instance":"/i","challengeId":"c1"}
        """#)
        #expect(problem.extensions.count == 1)
        #expect(problem.extensions["challengeId"] == "c1")
        for key in ["type", "title", "status", "detail", "instance"] {
            #expect(problem.extensions[key] == nil)
        }
    }

    @Test("a colliding extension key never shadows a typed standard member on encode")
    func extensionDoesNotShadowStandard() throws {
        var problem = ProblemDetails(status: 402)
        problem.extensions["status"] = 200 // hostile/malformed: should be ignored
        let object = try encodedObject(problem)
        #expect(object["status"] as? Int == 402)
    }

    @Test("rejects a non-integer status rather than coercing it")
    func rejectsNonIntegerStatus() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"status":"402"}"#)
        }
    }
}
