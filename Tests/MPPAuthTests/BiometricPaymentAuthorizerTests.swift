#if canImport(LocalAuthentication)
    import Foundation
    import LocalAuthentication
    import MPPAuth
    import MPPClient
    import MPPCore
    import Testing

    // The biometric authorizer fails closed: an unavailable check denies (it never assumes
    // approval),
    // a successful evaluation approves, and a cancelled / failed one denies. A stub LAContext
    // drives
    // the branches without a real prompt (the live prompt is non-automatable).

    private final class StubLAContext: LAContext, @unchecked Sendable {
        private let available: Bool
        private let evalSuccess: Bool
        private let evalError: (any Error)?

        init(available: Bool, evalSuccess: Bool = false, evalError: (any Error)? = nil) {
            self.available = available
            self.evalSuccess = evalSuccess
            self.evalError = evalError
            super.init()
        }

        override func canEvaluatePolicy(_: LAPolicy, error: NSErrorPointer) -> Bool {
            if !available {
                error?.pointee = NSError(
                    domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no biometry"]
                )
            }
            return available
        }

        override func evaluatePolicy(
            _: LAPolicy, localizedReason _: String, reply: @escaping (Bool, (any Error)?) -> Void
        ) {
            reply(evalSuccess, evalError)
        }
    }

    private func approvalRequest() throws -> PaymentApprovalRequest {
        try PaymentApprovalRequest(
            challengeId: "c", realm: "api.example.com",
            method: MethodName("tempo"), intent: .charge,
            amount: Amount("0"), currency: nil, recipient: nil, description: nil, expires: nil
        )
    }

    @Suite("BiometricPaymentAuthorizer")
    struct BiometricPaymentAuthorizerTests {
        @Test("an unavailable check denies (unavailable) and never assumes approval")
        func unavailableDenies() async throws {
            let auth =
                BiometricPaymentAuthorizer(contextFactory: { StubLAContext(available: false) })
            let req = try approvalRequest()
            await #expect(throws: PaymentDenied.unavailable("no biometry")) {
                try await auth.authorize(req)
            }
        }

        @Test("a successful evaluation approves")
        func successApproves() async throws {
            let auth = BiometricPaymentAuthorizer(
                contextFactory: { StubLAContext(available: true, evalSuccess: true) }
            )
            try await auth.authorize(approvalRequest())
        }

        @Test("a cancelled or failed evaluation denies")
        func failureDenies() async throws {
            let cancel = NSError(domain: LAErrorDomain, code: LAError.userCancel.rawValue)
            let auth = BiometricPaymentAuthorizer(
                contextFactory: { StubLAContext(
                    available: true,
                    evalSuccess: false,
                    evalError: cancel
                ) }
            )
            let req = try approvalRequest()
            await #expect(throws: PaymentDenied.declined) { try await auth.authorize(req) }
        }
    }
#endif
