import Foundation
import MPPClient
import MPPCore
import MPPEVM
import MPPServer
import MPPX402
import MPPX402Server
import Testing

// The server-side x402 charge verifier, the counterpart to X402ChargeMethod. A stub X402Settlement
// stands in for the on-chain submit, so the recover/validate/single-use logic is proven without a
// chain (the live Base settlement is a later PR). The happy path is an end-to-end client -> verify;
// the tamper cases craft credentials whose authorization disagrees with the challenge.
@Suite("X402 charge verifier")
struct X402ChargeVerifierTests {
    private static let payerKey = Data(repeating: 0, count: 31) + Data([0x01])
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let usdcBaseHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let txHash = "0xfeedface"

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Self.payerKey)
    }

    private func payer() throws -> EthereumAddress {
        try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
    }

    private func domain() throws -> X402Domain {
        let asset = try #require(EthereumAddress(hex: Self.usdcBaseHex))
        return X402Domain(name: "USD Coin", version: "2", chainId: 8453, asset: asset)
    }

    private func verifier(
        settlement: any X402Settlement,
        replayStore: any ReplayStore = InMemoryReplayStore()
    ) -> X402ChargeVerifier {
        X402ChargeVerifier(
            settlement: settlement, replayStore: replayStore, defaultChainId: X402Chain.baseMainnet
        )
    }

    private func chargeChallenge(recipient: String = recipientHex) throws -> Challenge {
        let details: [String: JSONValue] = [
            "chainId": .integer(8453), "name": .string("USD Coin"), "version": .string("2"),
            "maxTimeoutSeconds": .integer(300),
        ]
        let object: [String: JSONValue] = [
            "amount": .string("1000000"),
            "recipient": .string(recipient),
            "currency": .string(Self.usdcBaseHex),
            "methodDetails": .object(details),
        ]
        return try Challenge(
            id: "x402-charge-1", realm: "shop.example",
            method: X402Method.name, intent: IntentName("charge"),
            request: EncodedJSON(json: .object(object))
        )
    }

    /// The credential the real client produces for `challenge` (now within the window).
    private func clientCredential(for challenge: Challenge) async throws -> Credential {
        let nonce = Data(repeating: 0xAB, count: 32)
        let clock: @Sendable () -> Date = { Self.now }
        let nonceSource: @Sendable () -> Data = { nonce }
        let client = try #require(X402ChargeMethod(
            payerPrivateKey: Self.payerKey, now: clock, nonceSource: nonceSource
        ))
        return try await client.buildCredential(for: challenge)
    }

    /// A credential whose signed authorization and `did:pkh` source are set explicitly, for the
    /// mismatch cases the client cannot produce.
    private func craftedCredential(
        authorization: X402Authorization,
        sourceAddress: EthereumAddress? = nil,
        challenge: Challenge
    ) throws -> Credential {
        let domain = try domain()
        let signature = try authorization.sign(domain: domain, with: signer())
        let payload = X402ExactPayload(authorization: authorization, signature: signature)
        return try Credential(
            challenge: challenge,
            source: ProofSource.did(address: sourceAddress ?? authorization.from, chainId: 8453),
            payload: payload.credentialPayload()
        )
    }

    private func authorization(
        recipient: String = recipientHex,
        value: String = "1000000",
        validAfter: UInt64 = 0,
        validBefore: UInt64 = 4_000_000_000
    ) throws -> X402Authorization {
        let payee = try #require(EthereumAddress(hex: recipient))
        return try #require(X402Authorization(
            from: payer(), recipient: payee,
            value: Amount(value), validAfter: validAfter, validBefore: validBefore,
            nonce: Data(repeating: 0xCD, count: 32)
        ))
    }

    @Test("supports a non-zero exact/charge challenge")
    func supports() throws {
        let subject = verifier(settlement: StubSettlement())
        #expect(try subject.supports(chargeChallenge()))
    }

    @Test("a client-built credential verifies and settles, referencing the tx hash")
    func clientCredentialSettles() async throws {
        let stub = StubSettlement()
        let subject = verifier(settlement: stub)
        let receipt = try await subject.verify(
            clientCredential(for: chargeChallenge()),
            now: Self.now
        )
        #expect(receipt.reference == Self.txHash)
        #expect(receipt.method == X402Method.name)
        #expect(stub.count == 1)
    }

    @Test("an authorization settles only once (single-use)")
    func singleUse() async throws {
        let store = InMemoryReplayStore()
        let subject = verifier(settlement: StubSettlement(), replayStore: store)
        let credential = try await clientCredential(for: chargeChallenge())
        _ = try await subject.verify(credential, now: Self.now)
        await #expect(throws: X402ChargeVerifier.VerifyError.alreadySettled) {
            _ = try await subject.verify(credential, now: Self.now)
        }
    }

    @Test("a settlement failure surfaces, and does not mint a receipt")
    func settlementFailureRejected() async throws {
        let subject = verifier(settlement: RevertingSettlement())
        await #expect(throws: X402ChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(clientCredential(for: chargeChallenge()), now: Self.now)
        }
    }

    @Test("an authorization to the wrong recipient or amount is rejected")
    func fieldMismatchRejected() async throws {
        let subject = verifier(settlement: StubSettlement())
        // Validly signed, but recipient/value disagree with the challenge.
        let wrongRecipient = try craftedCredential(
            authorization: authorization(recipient: "0x2222222222222222222222222222222222222222"),
            challenge: chargeChallenge()
        )
        let wrongAmount = try craftedCredential(
            authorization: authorization(value: "999"), challenge: chargeChallenge()
        )
        await #expect(throws: X402ChargeVerifier.VerifyError.recipientMismatch) {
            _ = try await subject.verify(wrongRecipient, now: Self.now)
        }
        await #expect(throws: X402ChargeVerifier.VerifyError.amountMismatch) {
            _ = try await subject.verify(wrongAmount, now: Self.now)
        }
    }

    @Test("a did:pkh source that is not the authorization's from is rejected")
    func sourceMismatchRejected() async throws {
        let other = try #require(EthereumAddress(hex: "0x3333333333333333333333333333333333333333"))
        let credential = try craftedCredential(
            authorization: authorization(), sourceAddress: other, challenge: chargeChallenge()
        )
        await #expect(throws: X402ChargeVerifier.VerifyError.sourceMismatch) {
            _ = try await verifier(settlement: StubSettlement()).verify(credential, now: Self.now)
        }
    }

    @Test("an authorization outside its validity window is rejected")
    func outsideWindowRejected() async throws {
        // validBefore in the past relative to `now`.
        let credential = try craftedCredential(
            authorization: authorization(validBefore: 1_000_000_000), challenge: chargeChallenge()
        )
        await #expect(throws: X402ChargeVerifier.VerifyError.outsideValidityWindow) {
            _ = try await verifier(settlement: StubSettlement()).verify(credential, now: Self.now)
        }
    }

    @Test("a credential without an x402 payload is rejected")
    func malformedPayloadRejected() async throws {
        let credential = try Credential(
            challenge: chargeChallenge(), source: ProofSource.did(address: payer(), chainId: 8453),
            payload: ["type": .string("bogus")]
        )
        await #expect(throws: X402ChargeVerifier.VerifyError.malformedPayload) {
            _ = try await verifier(settlement: StubSettlement()).verify(credential, now: Self.now)
        }
    }
}

/// A stub ``X402Settlement`` that returns a fixed hash and counts submissions.
private final class StubSettlement: X402Settlement, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    var count: Int {
        lock.withLock { submitted }
    }

    func settle(
        authorization _: X402Authorization, domain _: X402Domain, signature _: Data
    ) async throws -> String {
        lock.withLock { submitted += 1 }
        return "0xfeedface"
    }
}

/// A settlement that always reverts.
private struct RevertingSettlement: X402Settlement {
    func settle(
        authorization _: X402Authorization, domain _: X402Domain, signature _: Data
    ) async throws -> String {
        throw SettlementError.reverted
    }

    enum SettlementError: Error { case reverted }
}
