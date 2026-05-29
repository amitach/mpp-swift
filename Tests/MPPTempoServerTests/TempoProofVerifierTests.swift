import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing

// Server-side proof verification, the counterpart to TempoProofMethodTests: the
// credentials our client mints (all three variants) verify, the reject matrix
// holds, an invalid proof does not burn the challenge id (it is rejected before
// the replay consume), an unsupported challenge fails closed, and a full
// mint -> pay -> verify round-trip proceeds.
// File-scope fixtures (kept out of the suite body so it stays under the type-length
// cap; one home for the shared helpers).
private let chainId: UInt64 = 1
private let realm = "https://api.example.com"

private func signer(byte: UInt8 = 1) throws -> Secp256k1Signer {
    try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [byte]))
}

private func method(
    byte: UInt8 = 1,
    variant: ProofVariant = .v2Realm,
    defaultChainId: UInt64 = TempoChain.mainnet
) throws -> TempoProofMethod {
    try #require(TempoProofMethod(
        signer: signer(byte: byte), defaultChainId: defaultChainId, variant: variant
    ))
}

/// The charge-request JSON a server puts in the challenge. A `nil` `chainId` omits
/// `methodDetails` entirely (so the configured default resolves it).
private func request(amount: String = "0", chainId: UInt64? = chainId) -> EncodedJSON {
    var members: [String: JSONValue] = ["amount": .string(amount)]
    if let chainId {
        members["methodDetails"] = .object(["chainId": .integer(Int64(chainId))])
    }
    return EncodedJSON(json: .object(members))
}

private func challenge(
    amount: String = "0",
    chainId: UInt64? = chainId,
    id: String = "test-challenge",
    realm: String = realm,
    method: String = "tempo",
    intent: String = "charge"
) throws -> Challenge {
    try Challenge(
        id: id, realm: realm,
        method: MethodName(method), intent: IntentName(intent),
        request: request(amount: amount, chainId: chainId)
    )
}

/// Rebuilds `credential` with its `signature` payload string transformed.
private func withSignature(
    _ credential: Credential, _ transform: (String) -> String
) throws -> Credential {
    let hex = try #require(credential.payload["signature"].flatMap {
        if case let .string(value) = $0 { return value } else { return nil }
    })
    var payload = credential.payload
    payload["signature"] = .string(transform(hex))
    return Credential(challenge: credential.challenge, source: credential.source, payload: payload)
}

@Suite("TempoProofVerifier")
struct TempoProofVerifierTests {
    // MARK: accept

    @Test("accepts a credential from every client proof variant")
    func acceptsAllVariants() async throws {
        let verifier = TempoProofVerifier()
        for variant in [ProofVariant.v2Realm, .v1Wallet, .specChallengeId] {
            let credential = try await method(variant: variant).buildCredential(for: challenge())
            await #expect(throws: Never.self) { try await verifier.verify(credential) }
        }
    }

    // MARK: reject matrix

    @Test("rejects a signature that does not recover to the source wallet")
    func rejectsWrongSignature() async throws {
        let credential = try await method().buildCredential(for: challenge())
        // Flip a byte in the signature so it recovers to some other address.
        let tampered = try withSignature(credential) { hex in
            var chars = Array(hex)
            chars[5] = chars[5] == "a" ? "b" : "a"
            return String(chars)
        }
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier().verify(tampered)
        }
    }

    @Test("rejects a tampered challenge id (proof was signed over a different id)")
    func rejectsTamperedChallengeID() async throws {
        let credential = try await method().buildCredential(for: challenge(id: "real-id"))
        let moved = try Credential(
            challenge: challenge(id: "tampered-id"),
            source: credential.source,
            payload: credential.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier().verify(moved)
        }
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
        await #expect(throws: TempoProofVerifier.VerifyError.chainIdMismatch) {
            try await TempoProofVerifier().verify(mismatched)
        }
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
        await #expect(throws: TempoProofVerifier.VerifyError.notAProof) {
            try await TempoProofVerifier().verify(notProof)
        }

        let noSig = Credential(
            challenge: base.challenge, source: base.source, payload: ["type": .string("proof")]
        )
        await #expect(throws: TempoProofVerifier.VerifyError.missingSignature) {
            try await TempoProofVerifier().verify(noSig)
        }

        let noSource = Credential(
            challenge: base.challenge, source: nil, payload: base.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.invalidSource) {
            try await TempoProofVerifier().verify(noSource)
        }
    }

    @Test("rejects a malformed (non-hex / wrong-length) signature")
    func rejectsMalformedSignature() async throws {
        let base = try await method().buildCredential(for: challenge())
        let bad = Credential(
            challenge: base.challenge, source: base.source,
            payload: ["type": .string("proof"), "signature": .string("0xdeadbeef")]
        )
        await #expect(throws: TempoProofVerifier.VerifyError.malformedSignature) {
            try await TempoProofVerifier().verify(bad)
        }
    }

    @Test("rejects a valid signature whose recovered signer is not the claimed source")
    func rejectsValidSignatureFromWrongSigner() async throws {
        // Signer 2 produces a well-formed proof, but the credential claims signer 1's
        // wallet as its source: recovery yields signer 2's address, not the claim.
        let signedByTwo = try await method(byte: 2).buildCredential(for: challenge())
        let claimSignerOne = try Credential(
            challenge: signedByTwo.challenge,
            source: ProofSource.did(address: method(byte: 1).address, chainId: chainId),
            payload: signedByTwo.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier().verify(claimSignerOne)
        }
    }

    @Test("rejects a hash payload on a zero-amount challenge (proof required)")
    func rejectsHashPayload() async throws {
        let base = try await method().buildCredential(for: challenge())
        let hashPayload = Credential(
            challenge: base.challenge, source: base.source,
            payload: ["type": .string("hash"), "hash": .string("0xabc123")]
        )
        await #expect(throws: TempoProofVerifier.VerifyError.notAProof) {
            try await TempoProofVerifier().verify(hashPayload)
        }
    }

    @Test("rejects a proof presented against a non-zero charge")
    func rejectsProofOnNonZeroCharge() async throws {
        let base = try await method().buildCredential(for: challenge())
        let onNonZero = try Credential(
            challenge: challenge(amount: "100"), source: base.source, payload: base.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.notAZeroAmountCharge) {
            try await TempoProofVerifier().verify(onNonZero)
        }
    }

    @Test("rejects a proof signed over a different realm")
    func rejectsWrongRealm() async throws {
        // The v2 proof binds realm; signing over a different realm must not verify
        // against the real challenge (the other variants do not recover either).
        let evil = try await method(variant: .v2Realm)
            .buildCredential(for: challenge(realm: "evil.example.com"))
        let moved = try Credential(
            challenge: challenge(realm: realm), source: evil.source, payload: evil.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier().verify(moved)
        }
    }

    @Test("rejects a proof signed under a different chainId domain")
    func rejectsWrongChainIdDomain() async throws {
        // Signed under chainId 2, but the source claims chainId 1 against a chainId-1
        // challenge: the chainId pin passes, but recovery under chainId 1 fails.
        let signedOnTwo = try await method().buildCredential(for: challenge(chainId: 2))
        let moved = try Credential(
            challenge: challenge(chainId: 1),
            source: ProofSource.did(address: method().address, chainId: 1),
            payload: signedOnTwo.payload
        )
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier().verify(moved)
        }
    }

    // MARK: configuration (acceptedVariants, defaultChainId)

    @Test("a restricted accepted-variant set rejects an excluded variant, accepts an allowed one")
    func restrictedVariants() async throws {
        let specCredential = try await method(variant: .specChallengeId)
            .buildCredential(for: challenge())
        await #expect(throws: TempoProofVerifier.VerifyError.signatureMismatch) {
            try await TempoProofVerifier(acceptedVariants: [.v2Realm]).verify(specCredential)
        }
        await #expect(throws: Never.self) {
            try await TempoProofVerifier(acceptedVariants: [.specChallengeId])
                .verify(specCredential)
        }
    }

    @Test("the configured defaultChainId resolves a challenge that omits chainId")
    func defaultChainIdResolves() async throws {
        // The challenge carries no methodDetails.chainId; client and verifier agree
        // on the testnet default, so the proof verifies.
        let chainless = try challenge(chainId: nil)
        let credential = try await method(defaultChainId: TempoChain.moderatoTestnet)
            .buildCredential(for: chainless)
        await #expect(throws: Never.self) {
            try await TempoProofVerifier(defaultChainId: TempoChain.moderatoTestnet)
                .verify(credential)
        }
        // A verifier with a different default resolves a different chain, so the
        // source chainId no longer matches.
        await #expect(throws: TempoProofVerifier.VerifyError.chainIdMismatch) {
            try await TempoProofVerifier(defaultChainId: TempoChain.mainnet).verify(credential)
        }
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
            realm: realm,
            method: MethodName("tempo"),
            intent: .charge
        )
        let minted = minter.mint(binding: binding, request: request())

        let good = try await method().buildCredential(for: minted)
        let bad = try withSignature(good) { hex in
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
            realm: realm,
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
            realm: realm,
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
}
