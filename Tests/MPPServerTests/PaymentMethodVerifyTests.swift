import Foundation
import MPPCore
import MPPServer
import Testing

// The method-verify wiring in PaymentVerifier / MPPServerMiddleware: a registered
// PaymentMethodServer that rejects (or does not support) the challenge maps to a
// `verification-failed` 402. MPPServer has no concrete method, so a stub stands in.
private struct StubMethod: PaymentMethodServer {
    struct Rejected: Error {}
    let supportsChallenge: Bool
    func supports(_: Challenge) -> Bool {
        supportsChallenge
    }

    func verify(_: Credential) async throws -> String {
        throw Rejected()
    }
}

/// A 402 problem type from driving a paid header through a middleware whose verifier
/// has `method` registered.
private func problemType(withMethod method: StubMethod) async throws -> String? {
    let middleware = try makeMiddleware(methods: [method])
    let decision = try await middleware.evaluate(
        authorization: paidHeader(), body: Data(), now: now
    )
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
