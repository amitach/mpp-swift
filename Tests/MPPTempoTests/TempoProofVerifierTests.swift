import Foundation
import MPPCore
import MPPEVM
import MPPServer
import Testing
@testable import MPPTempo

// Server-side proof verification, the counterpart to TempoProofMethodTests: the
// credentials our client mints (all three variants) verify, the reject matrix
// holds, an invalid proof does not burn the challenge id (it is rejected before
// the replay consume), an unsupported challenge fails closed, and a full
// mint -> pay -> verify round-trip proceeds.
@Suite("TempoProofVerifier")
struct TempoProofVerifierTests {
    private static let chainId: UInt64 = 1
    private static let realm = "https://api.example.com"

    private func signer(byte: UInt8 = 1) throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [byte]))
    }

    private func method(byte: UInt8 = 1, variant: ProofVariant = .v2Realm) throws
        -> TempoProofMethod {
        try #require(TempoProofMethod(signer: signer(byte: byte), variant: variant))
    }

    /// The charge-request JSON a server puts in the challenge.
    private func request(amount: String = "0", chainId: UInt64 = chainId) -> EncodedJSON {
        EncodedJSON(json: .object([
            "amount": .string(amount),
            "methodDetails": .object(["chainId": .integer(Int64(chainId))]),
        ]))
    }

    private func challenge(
        amount: String = "0",
        chainId: UInt64 = chainId,
        id: String = "test-challenge",
        method: String = "tempo",
        intent: String = "charge"
    ) throws -> Challenge {
        try Challenge(
            id: id, realm: Self.realm,
            method: MethodName(method), intent: IntentName(intent),
            request: request(amount: amount, chainId: chainId)
        )
    }

    // MARK: accept

    @Test("accepts a credential from every client proof variant")
    func acceptsAllVariants() async throws {
        let verifier = TempoProofVerifier()
        for variant in [ProofVariant.v2Realm, .v1Wallet, .specChallengeId] {
            let credential = try await method(variant: variant).buildCredential(for: challenge())
            #expect(throws: Never.self) { try verifier.verify(credential) }
        }
    }

    // MARK: reject matrix

    @Test("rejects a signature that does not recover to the source wallet")
    func rejectsWrongSignature() async throws {
        let credential = try await method().buildCredential(for: challenge())
        // Flip a byte in the signature so it recovers to some other address.
        let tampered = try Self.withSignature(credential) { hex in
            var chars = Array(hex)
            chars[5] = chars[5] == "a" ? "b" : "a"
            return String(chars)
        }
        #expect(throws: VerifyError.signatureMismatch) { try TempoProofVerifier().verify(tampered) }
    }

    @Test("rejects a tampered challenge id (proof was signed over a different id)")
    func rejectsTamperedChallengeID() async throws {
        let credential = try await method().buildCredential(for: challenge(id: "real-id"))
        let moved = try Credential(
            challenge: challenge(id: "tampered-id"),
            source: credential.source,
            payload: credential.payload
        )
        #expect(throws: VerifyError.signatureMismatch) { try TempoProofVerifier().verify(moved) }
    }

    @Test("rejects when the source chain does not match the challenge chain")
    func rejectsChainIdMismatch() async throws {
        // Credential built for chainId 1, but presented against a chainId-2 challenge.
        let credential = try await method().buildCredential(for: challenge(chainId: 1))
        let mismatched = try Credential(
            challenge: challenge(chainId: 2),
            source: credential.source,
            payload: credential.payload
        )
        #expect(throws: VerifyError.chainIdMismatch) { try TempoProofVerifier().verify(mismatched) }
    }

    @Test("rejects a non-proof payload, a missing signature, and a missing source")
    func rejectsMalformedPayloads() async throws {
        let base = try await method().buildCredential(for: challenge())
        let notProof = Credential(
            challenge: base.challenge, source: base.source,
            payload: [
                "type": .string("transaction"),
                "signature": base.payload["signature"] ?? .null,
            ]
        )
        #expect(throws: VerifyError.notAProof) { try TempoProofVerifier().verify(notProof) }

        let noSig = Credential(
            challenge: base.challenge, source: base.source, payload: ["type": .string("proof")]
        )
        #expect(throws: VerifyError.missingSignature) { try TempoProofVerifier().verify(noSig) }

        let noSource = Credential(
            challenge: base.challenge, source: nil, payload: base.payload
        )
        #expect(throws: VerifyError.invalidSource) { try TempoProofVerifier().verify(noSource) }
    }

    @Test("rejects a malformed (non-hex / wrong-length) signature")
    func rejectsMalformedSignature() async throws {
        let base = try await method().buildCredential(for: challenge())
        let bad = Credential(
            challenge: base.challenge, source: base.source,
            payload: ["type": .string("proof"), "signature": .string("0xdeadbeef")]
        )
        #expect(throws: VerifyError.malformedSignature) { try TempoProofVerifier().verify(bad) }
    }

    // MARK: replay ordering (Decision A) + fail closed (Decision B), via PaymentVerifier

    @Test("an invalid proof does not consume the challenge id; a later valid one succeeds")
    func invalidProofDoesNotConsume() async throws {
        let secret = Data("conformance-fixed-secret-key-0123456789".utf8)
        let minter = ChallengeMinter(signer: ChallengeSigner(secret: secret))
        let store = InMemoryReplayStore()
        let verifier = PaymentVerifier(
            signer: ChallengeSigner(secret: secret),
            replayStore: store,
            methods: [TempoProofVerifier()]
        )
        let binding = try RouteBinding(
            realm: Self.realm,
            method: MethodName("tempo"),
            intent: .charge
        )
        let minted = minter.mint(binding: binding, request: request())

        let good = try await method().buildCredential(for: minted)
        let bad = try Self.withSignature(good) { hex in
            var chars = Array(hex); chars[5] = chars[5] == "a" ? "b" : "a"; return String(chars)
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // The bad proof is rejected on settlement, NOT consumed.
        let first = try await verifier.verify(
            authorization: bad.headerValue, body: Data(), now: now, expecting: binding
        )
        guard case .rejected(.settlementUnverified) = first else {
            Issue.record("expected settlementUnverified, got \(first)"); return
        }
        // The same challenge id is still spendable: the good proof verifies.
        let second = try await verifier.verify(
            authorization: good.headerValue, body: Data(), now: now, expecting: binding
        )
        guard case .verified = second else {
            Issue.record("expected verified, got \(second)"); return
        }
    }

    @Test("fails closed when a verifier is registered but none supports the challenge")
    func failsClosedOnUnsupported() async throws {
        let secret = Data("conformance-fixed-secret-key-0123456789".utf8)
        let minter = ChallengeMinter(signer: ChallengeSigner(secret: secret))
        let verifier = PaymentVerifier(
            signer: ChallengeSigner(secret: secret),
            replayStore: InMemoryReplayStore(),
            methods: [TempoProofVerifier()]
        )
        let binding = try RouteBinding(
            realm: Self.realm,
            method: MethodName("tempo"),
            intent: .charge
        )
        // A non-zero charge: protocol-valid, but the proof verifier does not support it.
        let minted = minter.mint(binding: binding, request: request(amount: "100"))
        let credential = Credential(challenge: minted, source: nil, payload: [:])
        let outcome = try await verifier.verify(
            authorization: credential.headerValue, body: Data(),
            now: Date(timeIntervalSince1970: 1_700_000_000), expecting: binding
        )
        guard case .rejected(.noSupportingMethod) = outcome else {
            Issue.record("expected noSupportingMethod, got \(outcome)"); return
        }
    }

    // MARK: end-to-end mint -> pay -> verify

    @Test("end-to-end: server mints, client pays, verifier proceeds")
    func endToEnd() async throws {
        let secret = Data("conformance-fixed-secret-key-0123456789".utf8)
        let binding = try RouteBinding(
            realm: Self.realm,
            method: MethodName("tempo"),
            intent: .charge
        )
        let middleware = MPPServerMiddleware(
            minter: ChallengeMinter(signer: ChallengeSigner(secret: secret)),
            verifier: PaymentVerifier(
                signer: ChallengeSigner(secret: secret),
                replayStore: InMemoryReplayStore(),
                methods: [TempoProofVerifier()]
            ),
            binding: binding,
            request: request()
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // No credential -> a challenge is issued.
        guard case let .challenge(issued, _) = await middleware.evaluate(
            authorization: nil, body: Data(), now: now
        ) else { Issue.record("expected a challenge"); return }

        // The client pays it.
        let credential = try await method().buildCredential(for: issued)

        // The paid retry verifies and proceeds.
        let decision = try await middleware.evaluate(
            authorization: credential.headerValue, body: Data(), now: now
        )
        guard case .proceed = decision else {
            Issue.record("expected proceed, got \(decision)"); return
        }
    }

    /// Rebuilds `credential` with its `signature` payload string transformed.
    private static func withSignature(
        _ credential: Credential, _ transform: (String) -> String
    ) throws -> Credential {
        let hex = try #require(credential.payload["signature"].flatMap {
            if case let .string(value) = $0 { return value } else { return nil }
        })
        var payload = credential.payload
        payload["signature"] = .string(transform(hex))
        return Credential(
            challenge: credential.challenge,
            source: credential.source,
            payload: payload
        )
    }
}
