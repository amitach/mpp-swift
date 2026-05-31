import Foundation
import MCP
import MPPCore
import Testing
@testable import MPPMCP

@Suite("MCP payment codec")
struct MCPPaymentCodecTests {
    // A representative `-32042` frame in the exact shape mppx 0.6.28 emits over the MCP transport
    // (captured from `Mppx.create({transport: Transport.mcp()}).charge`): native `request` object,
    // no `digest`, an RFC 3339 `expires` with milliseconds, and a `problem` block.
    private static let mppxFrame = """
    {
      "code": -32042,
      "message": "Payment is required (zero-amount proof).",
      "data": {
        "httpStatus": 402,
        "challenges": [{
          "id": "PAcI-4eYJ1moCMfuVqVDwIrngQcGwA1RLGes6oxQSzw",
          "realm": "example",
          "intent": "charge",
          "method": "tempo",
          "expires": "2026-05-31T03:18:23.512Z",
          "description": "zero-amount proof",
          "request": {
            "currency": "0x20c0000000000000000000000000000000000000",
            "recipient": "0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A",
            "amount": "0",
            "methodDetails": { "chainId": 42431 }
          }
        }],
        "problem": {
          "type": "https://paymentauth.org/problems/payment-required",
          "title": "Payment Required",
          "status": 402,
          "detail": "Payment is required (zero-amount proof).",
          "challengeId": "PAcI-4eYJ1moCMfuVqVDwIrngQcGwA1RLGes6oxQSzw"
        }
      }
    }
    """

    private func errorData(_ json: String) throws -> [String: Value] {
        let value = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        guard let data = value.objectValue?["data"]?.objectValue else {
            throw CocoaError(.coderInvalidValue)
        }
        return data
    }

    private func sampleChallenge() throws -> Challenge {
        try Challenge(
            id: "cid-1",
            realm: "example",
            method: MethodName("tempo"),
            intent: IntentName("charge"),
            request: EncodedJSON(json: [
                "amount": "0",
                "recipient": "0xabc",
                "methodDetails": ["chainId": 42431],
            ]),
            expires: Expires("2026-05-31T00:00:00Z"),
            description: "proof"
        )
    }

    // MARK: parse a real mppx frame

    @Test("parses a real mppx MCP -32042 frame into challenges + problem")
    func parseMppxFrame() throws {
        let data = try errorData(Self.mppxFrame)
        let challenges = try MCPPaymentCodec.challenges(fromErrorData: data)
        #expect(challenges.count == 1)
        let challenge = challenges[0]
        #expect(challenge.id == "PAcI-4eYJ1moCMfuVqVDwIrngQcGwA1RLGes6oxQSzw")
        #expect(challenge.realm == "example")
        #expect(challenge.method.rawValue == "tempo")
        #expect(challenge.intent.rawValue == "charge")
        #expect(challenge.digest == nil)
        // The native request decodes back into a JCS-canonical EncodedJSON we can read.
        let requestJSON = try JSONDecoder().decode(
            JSONValue.self, from: challenge.request.decodedData()
        )
        guard case let .object(request) = requestJSON else {
            #expect(Bool(false), "request should be an object"); return
        }
        #expect(request["amount"] == .string("0"))
        #expect(request["methodDetails"] == .object(["chainId": .integer(42431)]))

        let problem = try MCPPaymentCodec.problem(fromErrorData: data)
        #expect(problem?.status == 402)
        #expect(problem?.title == "Payment Required")
    }

    // MARK: challenge round-trip

    @Test("challenge round-trips, preserving the JCS binding (request.rawValue)")
    func challengeRoundTrip() throws {
        let challenge = try sampleChallenge()
        let value = try MCPPaymentCodec.value(for: challenge)
        let parsed = try MCPPaymentCodec.challenge(from: value)
        #expect(parsed.id == challenge.id)
        #expect(parsed.realm == challenge.realm)
        #expect(parsed.method == challenge.method)
        #expect(parsed.intent == challenge.intent)
        #expect(parsed.request.rawValue == challenge.request.rawValue)
        #expect(parsed.expires?.rawValue == challenge.expires?.rawValue)
        #expect(parsed.description == challenge.description)
    }

    @Test("request is emitted as a native object, not a base64url string")
    func requestIsNative() throws {
        let value = try MCPPaymentCodec.value(for: sampleChallenge())
        let request = value.objectValue?["request"]
        #expect(request?.objectValue != nil)
        #expect(request?.objectValue?["amount"] == .string("0"))
    }

    @Test("challenge parse rejects a missing required field")
    func challengeMissingField() {
        #expect(throws: MCPPaymentCodec.CodecError.missingField("realm")) {
            try MCPPaymentCodec.challenge(from: .object(["id": .string("x")]))
        }
    }

    @Test("an opaque string round-trips verbatim (it binds into the challenge id)")
    func opaqueStringRoundTrips() throws {
        let base = try sampleChallenge()
        let challenge = Challenge(
            id: base.id, realm: base.realm, method: base.method, intent: base.intent,
            request: base.request, opaque: EncodedJSON("c2VydmVyLW9wYXF1ZQ")
        )
        let value = try MCPPaymentCodec.value(for: challenge)
        #expect(value.objectValue?["opaque"] == .string("c2VydmVyLW9wYXF1ZQ"))
        let parsed = try MCPPaymentCodec.challenge(from: value)
        #expect(parsed.opaque?.rawValue == "c2VydmVyLW9wYXF1ZQ")
    }

    @Test("a non-string opaque fails closed (never silently dropped)")
    func nonStringOpaqueRejected() throws {
        var object = try #require(MCPPaymentCodec.value(for: sampleChallenge()).objectValue)
        object["opaque"] = .object(["unexpected": .string("native")])
        #expect(throws: MCPPaymentCodec.CodecError.invalidField("opaque")) {
            try MCPPaymentCodec.challenge(from: .object(object))
        }
    }

    // MARK: credential round-trip

    @Test("credential round-trips with its echoed challenge and payload")
    func credentialRoundTrip() throws {
        let challenge = try sampleChallenge()
        let credential = Credential(
            challenge: challenge,
            source: "did:pkh:eip155:42431:0xabc",
            payload: ["signature": "0xdead", "variant": "v2Realm"]
        )
        let value = try MCPPaymentCodec.value(for: credential)
        let parsed = try MCPPaymentCodec.credential(from: value)
        #expect(parsed.source == credential.source)
        #expect(parsed.payload == credential.payload)
        #expect(parsed.challenge.id == challenge.id)
        #expect(parsed.challenge.request.rawValue == challenge.request.rawValue)
    }

    @Test("credential parse rejects a missing payload")
    func credentialMissingPayload() throws {
        let challengeValue = try MCPPaymentCodec.value(for: sampleChallenge())
        #expect(throws: MCPPaymentCodec.CodecError.missingField("payload")) {
            try MCPPaymentCodec.credential(from: .object(["challenge": challengeValue]))
        }
    }

    // MARK: receipt round-trip

    @Test("receipt round-trips and carries the challengeId on the wire")
    func receiptRoundTrip() throws {
        let receipt = try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime("2026-05-31T00:00:00Z"),
            reference: "ref-1",
            extras: ["externalId": .string("ext-9")]
        )
        let value = try MCPPaymentCodec.value(for: receipt, challengeID: "cid-1")
        #expect(value.objectValue?[MCPPaymentCodec.challengeIDKey] == .string("cid-1"))

        let parsed = try MCPPaymentCodec.receipt(from: value)
        #expect(parsed.method == receipt.method)
        #expect(parsed.reference == receipt.reference)
        #expect(parsed.timestamp.rawValue == receipt.timestamp.rawValue)
        #expect(parsed.extras["externalId"] == .string("ext-9"))
        #expect(parsed.extras["challengeId"] == .string("cid-1"))
    }

    // MARK: error.data frame

    @Test("errorData builds the {httpStatus, challenges, problem} frame and round-trips")
    func errorDataFrame() throws {
        let challenge = try sampleChallenge()
        let problem = ProblemDetails(
            type: "https://paymentauth.org/problems/payment-required",
            title: "Payment Required",
            status: 402,
            detail: "pay up",
            extensions: ["challengeId": .string("cid-1")]
        )
        let data = try MCPPaymentCodec.errorData(challenge: challenge, problem: problem)
        #expect(data["httpStatus"] == .int(402))
        #expect(data["challenges"]?.arrayValue?.count == 1)

        let challenges = try MCPPaymentCodec.challenges(fromErrorData: data)
        #expect(challenges.first?.id == challenge.id)
        #expect(challenges.first?.request.rawValue == challenge.request.rawValue)

        let parsedProblem = try MCPPaymentCodec.problem(fromErrorData: data)
        #expect(parsedProblem?.status == 402)
        #expect(parsedProblem?.title == "Payment Required")
    }

    @Test("errorData with no problem omits the key")
    func errorDataNoProblem() throws {
        let data = try MCPPaymentCodec.errorData(challenge: sampleChallenge(), problem: nil)
        #expect(data["problem"] == nil)
        #expect(try MCPPaymentCodec.problem(fromErrorData: data) == nil)
    }
}
