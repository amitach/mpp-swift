import Foundation
import MPPCore
import MPPServer
import Testing

// The method-verify wiring in PaymentVerifier / MPPServerMiddleware: a registered
// PaymentMethodServer that rejects (or does not support) the challenge maps to a
// `verification-failed` 402. MPPServer has no concrete method, so a stub stands in.
private let methodSecret = Data("method-verify-test-secret-key-123".utf8)
private let methodNow = Date(timeIntervalSince1970: 1_767_312_000)

private struct StubMethod: PaymentMethodServer {
    struct Rejected: Error {}
    let supportsChallenge: Bool
    func supports(_: Challenge) -> Bool {
        supportsChallenge
    }

    func verify(_: Credential) throws {
        throw Rejected()
    }
}

private func methodBinding() throws -> RouteBinding {
    try RouteBinding(realm: "api.example.com", method: MethodName("tempo"), intent: .charge)
}

/// A 402 problem type from driving a paid header through a middleware whose verifier
/// has `method` registered.
private func problemType(withMethod method: StubMethod) async throws -> String? {
    let signer = ChallengeSigner(secret: methodSecret)
    let middleware = try MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(
            signer: signer, replayStore: InMemoryReplayStore(), methods: [method]
        ),
        binding: methodBinding(),
        request: EncodedJSON("e30"),
        expiresIn: 300
    )
    let challenge = try ChallengeMinter(signer: signer)
        .mint(binding: methodBinding(), request: EncodedJSON("e30"))
    let header = try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
    let decision = await middleware.evaluate(authorization: header, body: Data(), now: methodNow)
    if case let .challenge(_, problem) = decision { return problem.type }
    return nil
}

@Suite("PaymentMethodServer wiring")
struct PaymentMethodVerifyTests {
    @Test("a registered verifier that rejects maps to verification-failed")
    func settlementFailedProblemType() async throws {
        #expect(try await problemType(withMethod: StubMethod(supportsChallenge: true))
            == "https://paymentauth.org/problems/verification-failed")
    }

    @Test("fail-closed: no supporting verifier maps to verification-failed")
    func noSupportingMethodProblemType() async throws {
        #expect(try await problemType(withMethod: StubMethod(supportsChallenge: false))
            == "https://paymentauth.org/problems/verification-failed")
    }
}
