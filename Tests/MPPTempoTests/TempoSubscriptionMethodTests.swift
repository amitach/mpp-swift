import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// The subscription credential is verified byte-real, not merely well-formed: the
// signed serialization the method emits recovers the wallet (private key 0x..01)
// and deserializes back to the authorization the request reconstructs, so a green
// suite proves the signed key authorization is exactly the one the server will
// rebuild and verify.
@Suite("TempoSubscriptionMethod")
struct TempoSubscriptionMethodTests {
    private static let wallet = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let currencyHex = "0x20c0000000000000000000000000000000000001"
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let requestKeyHex = "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"
    private static let configuredKeyHex = "0x2222222222222222222222222222222222222222"
    private static let realm = "https://api.example.com"
    private static let expiryEpoch: TimeInterval = 1_893_456_000
    private static let challengeChainId: UInt64 = 42431

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [1]))
    }

    private func method(
        accessKey: SubscriptionRequest.AccessKey? = nil,
        defaultChainID: UInt64 = TempoChain.mainnet,
        approval: TempoApprovalPolicy = .allowAll
    ) throws -> TempoSubscriptionMethod {
        try #require(TempoSubscriptionMethod(
            signer: signer(),
            accessKey: accessKey,
            defaultChainID: defaultChainID,
            approval: approval
        ))
    }

    /// The ISO-8601 form of the fixed expiry epoch (never hand-mapped).
    private var expiryISO: String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Self.expiryEpoch))
    }

    private func requestJSON(
        chainId: UInt64? = challengeChainId,
        accessKey: JSONValue? = .object([
            "accessKeyAddress": .string(requestKeyHex),
            "keyType": .string("secp256k1"),
        ]),
        method: String = "tempo",
        intent: String = "subscription"
    ) throws -> Challenge {
        var methodDetails: [String: JSONValue] = [:]
        if let accessKey { methodDetails["accessKey"] = accessKey }
        if let chainId { methodDetails["chainId"] = .integer(Int64(chainId)) }
        var object: [String: JSONValue] = [
            "amount": .string("1000000"),
            "currency": .string(Self.currencyHex),
            "recipient": .string(Self.recipientHex),
            "periodCount": .string("1"),
            "periodUnit": .string("week"),
            "subscriptionExpires": .string(expiryISO),
        ]
        if !methodDetails.isEmpty { object["methodDetails"] = .object(methodDetails) }
        return try Challenge(
            id: "sub-1", realm: Self.realm, method: MethodName(method),
            intent: IntentName(intent), request: EncodedJSON(json: .object(object))
        )
    }

    private func walletAddress() throws -> EthereumAddress {
        try #require(EthereumAddress(hex: Self.wallet))
    }

    @Test("approvalFacts decodes the amount and the checksummed currency and recipient")
    func approvalFactsDecodes() throws {
        let subject = try method()
        let facts = try subject.approvalFacts(for: requestJSON())
        let request = try SubscriptionRequest(challenge: requestJSON())
        #expect(try facts.amount == Amount("1000000"))
        #expect(facts.method == TempoMethod.name)
        #expect(facts.intent == .subscription)
        #expect(facts.challengeId == "sub-1")
        #expect(facts.currency == request.currency.checksummed)
        #expect(facts.recipient == request.recipient.checksummed)
    }

    // MARK: credential content (byte-real)

    @Test("the credential carries a keyAuthorization that recovers the wallet")
    func credentialRecoversWallet() async throws {
        let subject = try method()
        let credential = try await subject.buildCredential(for: requestJSON())
        #expect(credential.payload["type"] == .string("keyAuthorization"))
        #expect(credential.source == "did:pkh:eip155:\(Self.challengeChainId):\(Self.wallet)")
        #expect(credential.challenge.id == "sub-1")

        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let serialized = try #require(Data(hexPrefixed: signatureHex))
        // Byte-real: the payer recovers, and the embedded authorization is exactly
        // the one the request reconstructs (the verifier's re-encode-and-compare).
        #expect(try TempoKeyAuthorization.recover(serialized: serialized) == walletAddress())

        let request = try SubscriptionRequest(challenge: requestJSON())
        let expectedKey = try #require(EthereumAddress(hex: Self.requestKeyHex))
        let expected = request.keyAuthorization(
            accessKey: .init(address: expectedKey, keyType: .secp256k1),
            chainId: Self.challengeChainId
        )
        let (decoded, signature) = try TempoKeyAuthorization.deserialize(serialized)
        #expect(decoded == expected)
        #expect(signature?.count == 65)
    }

    @Test("a configured access key overrides the one carried by the challenge")
    func configuredKeyOverridesRequest() async throws {
        let configured = try #require(EthereumAddress(hex: Self.configuredKeyHex))
        let subject = try method(accessKey: .init(address: configured, keyType: .secp256k1))
        let credential = try await subject.buildCredential(for: requestJSON())
        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let serialized = try #require(Data(hexPrefixed: signatureHex))
        let (decoded, _) = try TempoKeyAuthorization.deserialize(serialized)
        // The authorization delegates to the configured key, not the request's.
        #expect(decoded.address == configured)
    }

    @Test("the access key carried by the challenge is used when none is configured")
    func usesRequestKeyWhenUnconfigured() async throws {
        let subject = try method()
        let credential = try await subject.buildCredential(for: requestJSON())
        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let serialized = try #require(Data(hexPrefixed: signatureHex))
        let (decoded, _) = try TempoKeyAuthorization.deserialize(serialized)
        #expect(try decoded.address == #require(EthereumAddress(hex: Self.requestKeyHex)))
    }

    @Test("no access key on the method or the challenge throws noAccessKey")
    func noAccessKeyThrows() async throws {
        let subject = try method()
        await #expect(throws: TempoSubscriptionMethodError.noAccessKey) {
            _ = try await subject.buildCredential(for: requestJSON(accessKey: nil))
        }
    }

    // MARK: chain resolution

    @Test("chainId falls back to the configured default when the challenge omits it")
    func chainIdFallback() async throws {
        let subject = try method(defaultChainID: TempoChain.mainnet)
        let credential = try await subject.buildCredential(for: requestJSON(chainId: nil))
        #expect(credential.source == "did:pkh:eip155:4217:\(Self.wallet)")
        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let serialized = try #require(Data(hexPrefixed: signatureHex))
        let (decoded, _) = try TempoKeyAuthorization.deserialize(serialized)
        #expect(decoded.chainID == TempoChain.mainnet)
    }

    @Test("the challenge chainId overrides a configured default")
    func challengeChainIdWins() async throws {
        let subject = try method(defaultChainID: 999)
        let credential = try await subject.buildCredential(for: requestJSON())
        #expect(credential.source == "did:pkh:eip155:\(Self.challengeChainId):\(Self.wallet)")
    }

    // MARK: supports() matrix

    @Test("supports a decodable tempo/subscription challenge")
    func supportsSubscription() throws {
        #expect(try method().supports(requestJSON()))
    }

    @Test("does not support a different method or a non-subscription intent")
    func rejectsWrongMethodOrIntent() throws {
        let subject = try method()
        #expect(try subject.supports(requestJSON(method: "stripe")) == false)
        #expect(try subject.supports(requestJSON(intent: "charge")) == false)
    }

    @Test("does not support a malformed request")
    func rejectsMalformed() throws {
        let challenge = try Challenge(
            id: "x", realm: Self.realm, method: MethodName("tempo"),
            intent: .subscription, request: EncodedJSON("@@@not-base64@@@")
        )
        #expect(try method().supports(challenge) == false)
    }

    // MARK: build-time errors

    @Test("buildCredential refuses a wrong method/intent even when called directly")
    func refusesWrongMethodIntent() async throws {
        let subject = try method()
        await #expect(throws: TempoSubscriptionMethodError.wrongMethodOrIntent) {
            _ = try await subject.buildCredential(for: requestJSON(intent: "charge"))
        }
    }

    @Test("a malformed request throws malformedRequest")
    func buildMalformed() async throws {
        let subject = try method()
        let challenge = try Challenge(
            id: "x", realm: Self.realm, method: MethodName("tempo"),
            intent: .subscription, request: EncodedJSON("@@@not-base64@@@")
        )
        await #expect(throws: TempoSubscriptionMethodError.self) {
            _ = try await subject.buildCredential(for: challenge)
        }
    }

    // MARK: approval gate

    @Test("a denying policy produces no credential and throws approvalDenied")
    func approvalDenied() async throws {
        let subject = try method(approval: .deny)
        await #expect(throws: TempoSubscriptionMethodError.approvalDenied) {
            _ = try await subject.buildCredential(for: requestJSON())
        }
    }

    @Test("the policy sees the surfaced charge facts before signing")
    func approvalSeesFacts() async throws {
        let seen = FactsBox()
        let policy = TempoApprovalPolicy { facts in
            await seen.set(facts)
            return true
        }
        _ = try await method(approval: policy).buildCredential(for: requestJSON())
        let facts = await seen.value
        #expect(facts?.realm == Self.realm)
        #expect(facts?.amount.rawValue == "1000000")
        #expect(facts?.chainId == Self.challengeChainId)
        #expect(facts?.currency?.lowercased() == Self.currencyHex)
        #expect(facts?.recipient?.lowercased() == Self.recipientHex)
    }

    // MARK: Accept-Payment advertisement

    @Test("advertises the tempo/subscription range")
    func advertises() throws {
        #expect(try AcceptPayment.format(method().paymentRanges) == "tempo/subscription")
    }

    // MARK: end-to-end through PaymentClient

    @Test("end-to-end: a 402 is paid and the retry carries Authorization: Payment")
    func endToEnd() async throws {
        let challenge = try requestJSON()
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
        #expect(credential.payload["type"] == .string("keyAuthorization"))
        let signatureHex = try #require(credential.payload["signature"]?.stringValue)
        let serialized = try #require(Data(hexPrefixed: signatureHex))
        #expect(try TempoKeyAuthorization.recover(serialized: serialized) == walletAddress())
    }
}

// MARK: test support

/// Records the requests sent through it; answers the first with a 402 carrying
/// the challenge, and the paid retry with a 200.
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
