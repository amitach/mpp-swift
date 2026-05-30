import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing

// TempoProofVerifier wired through PaymentVerifier / MPPServerMiddleware: replay
// ordering (an invalid proof must not burn the challenge id, Decision A), fail
// closed when no registered method supports the challenge (Decision B), and a full
// mint -> pay -> verify round-trip. Shares the file-scope fixtures in
// TempoProofVerifierTests (method/challenge/request/withSignature/realm).
@Suite("TempoProofVerifier integration")
struct TempoProofIntegrationTests {
    private let secret = Data("conformance-fixed-secret-key-0123456789".utf8)

    private func binding() throws -> RouteBinding {
        try RouteBinding(realm: realm, method: MethodName("tempo"), intent: .charge)
    }

    @Test("an invalid proof does not consume the challenge id; a later valid one succeeds")
    func invalidProofDoesNotConsume() async throws {
        let minter = ChallengeMinter(signer: ChallengeSigner(secret: secret))
        let verifier = PaymentVerifier(
            signer: ChallengeSigner(secret: secret),
            replayStore: InMemoryReplayStore(),
            methods: [TempoProofVerifier()]
        )
        let route = try binding()
        let minted = minter.mint(binding: route, request: request())

        let good = try await method().buildCredential(for: minted)
        let bad = try withSignature(good) { hex in
            var chars = Array(hex); chars[5] = chars[5] == "a" ? "b" : "a"; return String(chars)
        }

        // The bad proof is rejected on settlement, NOT consumed.
        let first = try await verifier.verify(
            authorization: bad.headerValue, body: Data(), now: now, expecting: route
        )
        guard case .rejected(.settlementUnverified) = first else {
            Issue.record("expected settlementUnverified, got \(first)"); return
        }
        // The same challenge id is still spendable: the good proof verifies.
        let second = try await verifier.verify(
            authorization: good.headerValue, body: Data(), now: now, expecting: route
        )
        guard case .verified = second else {
            Issue.record("expected verified, got \(second)"); return
        }
    }

    @Test("fails closed when a verifier is registered but none supports the challenge")
    func failsClosedOnUnsupported() async throws {
        let minter = ChallengeMinter(signer: ChallengeSigner(secret: secret))
        let verifier = PaymentVerifier(
            signer: ChallengeSigner(secret: secret),
            replayStore: InMemoryReplayStore(),
            methods: [TempoProofVerifier()]
        )
        let route = try binding()
        // A non-zero charge: protocol-valid, but the proof verifier does not support it.
        let minted = minter.mint(binding: route, request: request(amount: "100"))
        let credential = Credential(challenge: minted, source: nil, payload: [:])
        let outcome = try await verifier.verify(
            authorization: credential.headerValue, body: Data(), now: now,
            expecting: route
        )
        guard case .rejected(.noSupportingMethod) = outcome else {
            Issue.record("expected noSupportingMethod, got \(outcome)"); return
        }
    }

    @Test("end-to-end: server mints, client pays, verifier proceeds")
    func endToEnd() async throws {
        let middleware = try MPPServerMiddleware(
            minter: ChallengeMinter(signer: ChallengeSigner(secret: secret)),
            verifier: PaymentVerifier(
                signer: ChallengeSigner(secret: secret),
                replayStore: InMemoryReplayStore(),
                methods: [TempoProofVerifier()]
            ),
            binding: binding(),
            request: request()
        )

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
