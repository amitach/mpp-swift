import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// The zero-amount proof credential is pinned against the same viem-derived
// vectors as MPPEVM's EIP712ProofTests (private key 0x..01, chainId 1,
// challengeId "test-challenge", realm "https://api.example.com"), so a green
// suite proves the credential the method emits is byte-exact, not merely
// well-formed.
@Suite("TempoProofMethod")
struct TempoProofMethodTests {
    // Fixed inputs shared with the MPPEVM proof vectors.
    private static let chainId: UInt64 = 1
    private static let challengeId = "test-challenge"
    private static let realm = "https://api.example.com"
    private static let address = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let v2Signature = "0x499c7c6c221e2d984dedcd9cf8656dd7f2e99ad7a81f9e538606d15f29"
        + "daff057ce1854ee7328b3bc06e4ec952051b534bcf4a4d21c74e9efb5579aa3a20d6be1b"
    private static let v1Signature = "0x7744bdd24959436cace9677f5850168e387eb2a319cbdac69fcf06aff2"
        + "b19ab919fb941c39f18ca8c2b5858659a7b92e51fc0e8bb926d013e427b446e2665f881b"
    private static let specSignature = "0x864872e5ccf7559d9921b163f5a9e4136c03098e0bbaab656de9993"
        + "e4e183da00e377b98c77aed27ab86689b6c1a52ba5e53cf7b2838992da8a404e4f6768cf21b"

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
    }

    private func method(
        defaultChainId: UInt64 = TempoChain.mainnet,
        variant: ProofVariant = .v2Realm,
        approval: TempoApprovalPolicy = .allowAll
    ) throws -> TempoProofMethod {
        try #require(TempoProofMethod(
            signer: signer(),
            defaultChainId: defaultChainId,
            variant: variant,
            approval: approval
        ))
    }

    /// A `tempo` / `charge` challenge whose `request` carries `amount` and an
    /// optional `methodDetails.chainId`.
    private func chargeChallenge(
        amount: String = "0",
        chainId: UInt64? = Self.chainId,
        method: String = "tempo",
        intent: String = "charge",
        realm: String = Self.realm,
        id: String = Self.challengeId,
        requestOverride: EncodedJSON? = nil
    ) throws -> Challenge {
        var members: [String: JSONValue] = ["amount": .string(amount)]
        if let chainId {
            members["methodDetails"] = .object(["chainId": .integer(Int64(chainId))])
        }
        let request = requestOverride ?? EncodedJSON(json: .object(members))
        return try Challenge(
            id: id,
            realm: realm,
            method: MethodName(method),
            intent: IntentName(intent),
            request: request
        )
    }

    // MARK: credential content

    @Test("v2 (default) credential is byte-exact: payload, source, type")
    func v2CredentialByteExact() async throws {
        let credential = try await method().buildCredential(for: chargeChallenge())
        #expect(credential.payload["type"] == .string("proof"))
        #expect(credential.payload["signature"] == .string(Self.v2Signature))
        #expect(credential.source == "did:pkh:eip155:1:\(Self.address)")
        #expect(credential.challenge.id == Self.challengeId)
    }

    @Test("v1 variant emits the wallet-form signature")
    func v1Credential() async throws {
        let credential = try await method(variant: .v1Wallet)
            .buildCredential(for: chargeChallenge())
        #expect(credential.payload["signature"] == .string(Self.v1Signature))
        #expect(credential.payload["type"] == .string("proof"))
    }

    @Test("spec variant emits the normative single-field signature")
    func specCredential() async throws {
        let credential = try await method(variant: .specChallengeId)
            .buildCredential(for: chargeChallenge())
        #expect(credential.payload["signature"] == .string(Self.specSignature))
        #expect(credential.payload["type"] == .string("proof"))
    }

    @Test("the source DID round-trips and recovers the signing address")
    func sourceRecovers() async throws {
        let subject = try method()
        let credential = try await subject.buildCredential(for: chargeChallenge())
        let source = try #require(credential.source)
        let parsed = try #require(ProofSource.parse(source))
        #expect(parsed.address == subject.address)
        #expect(parsed.chainId == Self.chainId)

        // The recovered signer of the emitted signature equals the wallet.
        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let signature = try #require(Data(hexAfter0x: signatureHex))
        let proof = ZeroAmountProof.v2Realm(challengeId: Self.challengeId, realm: Self.realm)
        #expect(proof.recoverSigner(chainId: Self.chainId, signature: signature) == subject.address)
    }

    @Test("chainId falls back to the configured default when the challenge omits it")
    func chainIdFallback() async throws {
        let subject = try method(defaultChainId: Self.chainId)
        let credential = try await subject.buildCredential(for: chargeChallenge(chainId: nil))
        // The default chain (1) yields the chainId-1 vector.
        #expect(credential.payload["signature"] == .string(Self.v2Signature))
        #expect(credential.source == "did:pkh:eip155:1:\(Self.address)")
    }

    @Test("the challenge chainId overrides a configured default")
    func challengeChainIdOverridesDefault() async throws {
        // Default 999, but the challenge carries chainId 1: the challenge wins, so
        // the result is the chainId-1 vector, not a chainId-999 signature.
        let subject = try method(defaultChainId: 999)
        let credential = try await subject.buildCredential(for: chargeChallenge(chainId: 1))
        #expect(credential.payload["signature"] == .string(Self.v2Signature))
        #expect(credential.source == "did:pkh:eip155:1:\(Self.address)")
    }

    @Test("extra transfer fields on a zero-amount charge are ignored, proof unaffected")
    func extraFieldsIgnored() async throws {
        // A zero-amount charge that still carries currency/recipient/decimals (as
        // the reference servers emit). They are surfaced for approval but do not
        // change the proof, which is still byte-exact.
        let request = EncodedJSON(json: .object([
            "amount": .string("0"),
            "currency": .string("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            "recipient": .string("0x1111111111111111111111111111111111111111"),
            "decimals": .integer(6),
            "methodDetails": .object(["chainId": .integer(1)]),
        ]))
        let challenge = try chargeChallenge(requestOverride: request)

        let seen = FactsBox()
        let policy = TempoApprovalPolicy { facts in
            await seen.set(facts)
            return true
        }
        let credential = try await method(approval: policy).buildCredential(for: challenge)
        #expect(credential.payload["signature"] == .string(Self.v2Signature))
        let facts = await seen.value
        #expect(facts?.currency == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
        #expect(facts?.recipient == "0x1111111111111111111111111111111111111111")
    }

    @Test("a non-canonical amount is rejected")
    func rejectsNonCanonicalAmount() async throws {
        // "01" has a leading zero; not a canonical base-units integer.
        let request = EncodedJSON(json: .object([
            "amount": .string("01"),
            "methodDetails": .object(["chainId": .integer(1)]),
        ]))
        let challenge = try chargeChallenge(requestOverride: request)
        #expect(try method().supports(challenge) == false)
        let subject = try method()
        await #expect(throws: (any Error).self) {
            _ = try await subject.buildCredential(for: challenge)
        }
    }

    @Test("buildCredential refuses a wrong method/intent even when called directly")
    func buildCredentialRefusesWrongMethodIntent() async throws {
        let subject = try method()
        await #expect(throws: TempoMethodError.wrongMethodOrIntent) {
            _ = try await subject.buildCredential(for: chargeChallenge(intent: "session"))
        }
    }

    // MARK: supports() matrix

    @Test("supports a zero-amount tempo/charge challenge")
    func supportsZeroAmount() throws {
        #expect(try method().supports(chargeChallenge()))
    }

    @Test("does not support a non-zero charge (settled transfer needs the tx layer)")
    func rejectsNonZero() throws {
        #expect(try method().supports(chargeChallenge(amount: "1000")) == false)
    }

    @Test("does not support a non-charge intent or a different method")
    func rejectsWrongMethodOrIntent() throws {
        let subject = try method()
        #expect(try subject.supports(chargeChallenge(intent: "session")) == false)
        #expect(try subject.supports(chargeChallenge(method: "stripe")) == false)
    }

    @Test("falls back to Tempo mainnet when the challenge omits chainId")
    func defaultsToMainnet() async throws {
        // Matches the reference SDKs' unwrap_or(mainnet) fallback.
        let subject = try method()
        #expect(try subject.supports(chargeChallenge(chainId: nil)))
        let credential = try await subject.buildCredential(for: chargeChallenge(chainId: nil))
        #expect(credential.source == "did:pkh:eip155:4217:\(Self.address)")
    }

    @Test("does not support a malformed request")
    func rejectsMalformed() throws {
        let challenge = try chargeChallenge(requestOverride: EncodedJSON("@@@not-base64@@@"))
        #expect(try method().supports(challenge) == false)
    }

    // MARK: approval gate

    @Test("a denying policy produces no credential and throws approvalDenied")
    func approvalDenied() async throws {
        let subject = try method(approval: .deny)
        await #expect(throws: TempoMethodError.approvalDenied) {
            _ = try await subject.buildCredential(for: chargeChallenge())
        }
    }

    @Test("the policy sees the surfaced charge facts")
    func approvalSeesFacts() async throws {
        let seen = FactsBox()
        let policy = TempoApprovalPolicy { facts in
            await seen.set(facts)
            return facts.realm == Self.realm
        }
        let credential = try await method(approval: policy).buildCredential(for: chargeChallenge())
        #expect(credential.payload["type"] == .string("proof"))
        let facts = await seen.value
        #expect(facts?.realm == Self.realm)
        #expect(facts?.amount.rawValue == "0")
        // The fields that bind into the proof are visible to the policy.
        #expect(facts?.challengeId == Self.challengeId)
        #expect(facts?.chainId == Self.chainId)
    }

    // MARK: build-time errors

    @Test("a malformed request throws malformedRequest")
    func buildMalformed() async throws {
        let subject = try method()
        let challenge = try chargeChallenge(requestOverride: EncodedJSON("@@@not-base64@@@"))
        await #expect(throws: (any Error).self) {
            _ = try await subject.buildCredential(for: challenge)
        }
    }

    @Test("a non-zero charge throws notAZeroAmountCharge")
    func buildNonZero() async throws {
        let subject = try method()
        await #expect(throws: TempoMethodError.notAZeroAmountCharge) {
            _ = try await subject.buildCredential(for: chargeChallenge(amount: "1000"))
        }
    }

    // MARK: Accept-Payment advertisement

    @Test("advertises the tempo/charge range, formatting to a header value")
    func advertises() throws {
        let ranges = try method().paymentRanges
        #expect(AcceptPayment.format(ranges) == "tempo/charge")
    }

    // MARK: end-to-end through PaymentClient

    @Test("end-to-end: a 402 is paid and the retry carries Authorization: Payment")
    func endToEnd() async throws {
        let challenge = try chargeChallenge()
        let transport = RecordingTransport(challengeHeader: challenge.headerValue)
        let client = try PaymentClient(transport: transport, methods: [method()])
        let request = HTTPRequest(
            method: .get, scheme: "https", authority: "api.example.com", path: "/paid"
        )

        let (response, body) = try await client.send(request)
        #expect(response.status.code == 200)
        #expect(body == Data("paid".utf8))

        let sent = await transport.sent
        #expect(sent.count == 2)
        let auth = try #require(sent[1].request.headerFields[.authorization])
        #expect(auth.hasPrefix("Payment "))
        let credential = try Credential(headerValue: auth)
        #expect(credential.payload["type"] == .string("proof"))
        #expect(credential.payload["signature"] == .string(Self.v2Signature))
        #expect(credential.challenge.id == Self.challengeId)
    }
}

// MARK: test support

/// Records the requests sent through it; answers the first with a 402 carrying
/// the challenge, and the second (the paid retry) with a 200.
private actor RecordingTransport: MPPHTTPTransport {
    private(set) var sent: [(request: HTTPRequest, body: Data)] = []
    private let challengeHeader: String

    init(challengeHeader: String) {
        self.challengeHeader = challengeHeader
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        sent.append((request, body))
        if sent.count == 1 {
            var response = HTTPResponse(status: .init(code: 402))
            response.headerFields[.wwwAuthenticate] = challengeHeader
            return (response, Data())
        }
        return (HTTPResponse(status: .ok), Data("paid".utf8))
    }
}

/// A Sendable box so an `async` approval closure can record the facts it saw.
private actor FactsBox {
    private(set) var value: ChargeApproval?
    func set(_ facts: ChargeApproval) {
        value = facts
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

private extension Data {
    /// Parses a `0x`-prefixed hex string into bytes, or `nil` if malformed.
    init?(hexAfter0x hex: String) {
        guard hex.hasPrefix("0x") else { return nil }
        let digits = Array(hex.dropFirst(2))
        guard digits.count.isMultiple(of: 2) else { return nil }
        var raw = Data()
        raw.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = digits[index].hexDigitValue,
                  let low = digits[index + 1].hexDigitValue else { return nil }
            raw.append(UInt8(high << 4 | low))
            index += 2
        }
        self = raw
    }
}
