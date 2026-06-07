import Foundation
import MPPClient
import MPPCore
import MPPEVM
import MPPX402
import Testing

// The x402 charge client: it decodes an x402/charge challenge, signs an EIP-3009 authorization, and
// emits the exact-scheme credential. The end-to-end proof is that the credential's payload recovers
// the payer as the signer under the advertised token domain.
@Suite("X402 charge client")
struct X402ChargeMethodTests {
    private static let payerKey = Data(repeating: 0, count: 31) + Data([0x01])
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let usdcBaseHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let nonce = Data(repeating: 0xAB, count: 32)

    private func method(now nowDate: Date = now, nonce nonceData: Data = nonce) throws
        -> X402ChargeMethod {
        let clock: @Sendable () -> Date = { nowDate }
        let nonceSource: @Sendable () -> Data = { nonceData }
        return try #require(X402ChargeMethod(
            payerPrivateKey: Self.payerKey,
            defaultChainId: X402Chain.baseMainnet,
            now: clock,
            nonceSource: nonceSource
        ))
    }

    private func chargeChallenge(
        amount: String = "1000000",
        recipient: String? = recipientHex,
        currency: String? = usdcBaseHex,
        chainId: UInt64? = 8453,
        name: String? = "USD Coin",
        version: String? = "2",
        maxTimeoutSeconds: UInt64? = 60
    ) throws -> Challenge {
        var details: [String: JSONValue] = [:]
        if let chainId { details["chainId"] = .integer(Int64(chainId)) }
        if let name { details["name"] = .string(name) }
        if let version { details["version"] = .string(version) }
        if let maxTimeoutSeconds {
            details["maxTimeoutSeconds"] = .integer(Int64(maxTimeoutSeconds))
        }
        var object: [String: JSONValue] = [
            "amount": .string(amount),
            "methodDetails": .object(details),
        ]
        if let recipient { object["recipient"] = .string(recipient) }
        if let currency { object["currency"] = .string(currency) }
        return try Challenge(
            id: "x402-charge-1", realm: "shop.example",
            method: X402Method.name, intent: IntentName("charge"),
            request: EncodedJSON(json: .object(object))
        )
    }

    @Test("supports a non-zero x402/charge with a token domain; rejects the under-specified")
    func supports() throws {
        let subject = try method()
        #expect(try subject.supports(chargeChallenge()))
        #expect(try subject.supports(chargeChallenge(amount: "0")) == false)
        #expect(try subject.supports(chargeChallenge(recipient: nil)) == false)
        #expect(try subject.supports(chargeChallenge(currency: "not-an-address")) == false)
        #expect(try subject.supports(chargeChallenge(name: nil)) == false)
        #expect(try subject.supports(chargeChallenge(version: nil)) == false)
    }

    @Test("the built credential recovers the payer as the signer under the token domain")
    func buildsRecoverableCredential() async throws {
        let subject = try method()
        let credential = try await subject.buildCredential(for: chargeChallenge())

        let payload = try #require(X402ExactPayload(credentialPayload: credential.payload))
        let auth = try #require(payload.authorization.decoded())
        #expect(auth.from == subject.address)
        #expect(try auth.recipient == #require(EthereumAddress(hex: Self.recipientHex)))
        #expect(try auth.value == Amount("1000000"))
        #expect(auth.validAfter == 0)
        #expect(auth.validBefore == 1_700_000_060) // now + maxTimeoutSeconds
        #expect(auth.nonce == Self.nonce)

        let domain = try X402Domain(
            name: "USD Coin", version: "2", chainId: 8453,
            asset: #require(EthereumAddress(hex: Self.usdcBaseHex))
        )
        let signature = try #require(payload.signatureBytes)
        #expect(auth.isSignedByFrom(domain: domain, signature: signature))
        // The did:pkh source names the payer on the advertised chain.
        #expect(credential.source == ProofSource.did(address: subject.address, chainId: 8453))
    }

    @Test("the window defaults when the challenge omits maxTimeoutSeconds")
    func defaultWindow() async throws {
        let subject = try method()
        let credential = try await subject.buildCredential(
            for: chargeChallenge(maxTimeoutSeconds: nil)
        )
        let auth = try #require(
            X402ExactPayload(credentialPayload: credential.payload)?.authorization.decoded()
        )
        #expect(auth.validBefore == 1_700_000_000 + X402ChargeMethod.defaultTimeoutSeconds)
    }

    @Test("a hostile near-UInt64.max maxTimeoutSeconds saturates validBefore, never traps")
    func timeoutOverflowSaturates() async throws {
        // UInt64.max is beyond Int64.max, so it cannot be built via JSONValue.integer -- craft the
        // raw wire JSON directly. now + timeout would overflow; the client must saturate, not
        // crash.
        let raw = #"""
        {"amount":"1000000","recipient":"\#(Self.recipientHex)","currency":"\#(Self.usdcBaseHex)",\#
        "methodDetails":{"chainId":8453,"name":"USD Coin","version":"2",\#
        "maxTimeoutSeconds":18446744073709551615}}
        """#
        let challenge = try Challenge(
            id: "x402-overflow", realm: "shop.example",
            method: X402Method.name, intent: IntentName("charge"),
            request: EncodedJSON(Base64URL.encode(Data(raw.utf8)))
        )
        let credential = try await method().buildCredential(for: challenge)
        let auth = try #require(
            X402ExactPayload(credentialPayload: credential.payload)?.authorization.decoded()
        )
        #expect(auth.validBefore == UInt64.max) // saturated
    }

    @Test("approval facts carry the decoded amount, currency, and recipient")
    func approvalFacts() throws {
        let facts = try method().approvalFacts(for: chargeChallenge())
        #expect(try facts.amount == Amount("1000000"))
        #expect(facts.currency == Self.usdcBaseHex)
        #expect(facts.recipient == Self.recipientHex)
    }

    @Test("a missing token domain or recipient is rejected at build time")
    func buildRejectsUnderspecified() async throws {
        let subject = try method()
        await #expect(throws: X402ChargeError.missingTokenDomain) {
            _ = try await subject.buildCredential(for: chargeChallenge(name: nil))
        }
        await #expect(throws: X402ChargeError.missingOrInvalidRecipient) {
            _ = try await subject.buildCredential(for: chargeChallenge(recipient: nil))
        }
        await #expect(throws: X402ChargeError.zeroAmount) {
            _ = try await subject.buildCredential(for: chargeChallenge(amount: "0"))
        }
    }

    @Test("two charges use distinct random nonces by default")
    func defaultNonceIsRandom() async throws {
        let subject = try #require(X402ChargeMethod(payerPrivateKey: Self.payerKey))
        let first = try await subject.buildCredential(for: chargeChallenge())
        let second = try await subject.buildCredential(for: chargeChallenge())
        let nonceA = try #require(X402ExactPayload(credentialPayload: first.payload)?
            .authorization.decoded()?.nonce)
        let nonceB = try #require(X402ExactPayload(credentialPayload: second.payload)?
            .authorization.decoded()?.nonce)
        #expect(nonceA != nonceB)
        #expect(nonceA.count == 32)
    }
}
