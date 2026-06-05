import MPPCore

// RFC 9457 problem-detail construction for `MPPServerMiddleware`, factored out of the main file to
// stay under the length limits. `problem(for:)` and `problemStatus(for:)` are internal (called as
// `Self.…` from `evaluate` in the main file); the cause/spec machinery stays private to this file.
extension MPPServerMiddleware {
    enum ProblemCause {
        case freshChallenge
        case rejection(PaymentVerifier.Rejection)
    }

    /// The HTTP status a rejection answers with (402 by default; a §10.5 settlement problem may be
    /// 410 / 400). Drives whether a retry challenge is offered.
    static func problemStatus(for rejection: PaymentVerifier.Rejection) -> Int {
        spec(for: .rejection(rejection)).status
    }

    private struct Spec {
        let slug: String
        let title: String
        let detail: String
        var status: Int = 402
    }

    /// Builds the RFC 9457 problem for a cause, using the paymentauth.org problem type registry.
    /// When `challengeID` is non-nil it is carried as the `challengeId` extension member (the
    /// offered retry challenge); a terminal settlement problem passes `nil` to omit it. Most causes
    /// are `402`; a §10.5 settlement problem carries its own status (e.g. `410` / `400`).
    static func problem(for cause: ProblemCause, challengeID: String?) -> ProblemDetails {
        let spec = Self.spec(for: cause)
        return ProblemDetails(
            type: "https://paymentauth.org/problems/\(spec.slug)",
            title: spec.title,
            status: spec.status,
            detail: spec.detail,
            extensions: challengeID.map { ["challengeId": .string($0)] } ?? [:]
        )
    }

    private static func verificationFailed(_ detail: String) -> Spec {
        Spec(slug: "verification-failed", title: "Verification Failed", detail: detail)
    }

    private static func invalidChallenge(_ detail: String) -> Spec {
        Spec(slug: "invalid-challenge", title: "Invalid Challenge", detail: detail)
    }

    /// The problem for a 402 cause. `settlementUnverified`'s `reason` is deliberately
    /// not echoed to the client. An already-used id maps to `invalid-challenge` per
    /// spec (§8.2 / §4.2: "unknown, expired, or already used"), not a proof failure.
    private static func spec(for cause: ProblemCause) -> Spec {
        switch cause {
        case .freshChallenge:
            Spec(
                slug: "payment-required",
                title: "Payment Required",
                detail: "This resource requires payment."
            )
        case .rejection(.malformedCredential):
            Spec(
                slug: "malformed-credential",
                title: "Malformed Credential",
                detail: "The Authorization header was not a parseable Payment credential."
            )
        case .rejection(.expired):
            Spec(
                slug: "payment-expired",
                title: "Payment Expired",
                detail: "The challenge had expired."
            )
        case .rejection(.invalidChallenge):
            invalidChallenge("The credential's challenge was not issued by this server.")
        case .rejection(.replayed):
            invalidChallenge("The challenge has already been used.")
        case .rejection(.bindingMismatch):
            verificationFailed("The credential's challenge does not match this resource.")
        case .rejection(.digestMismatch):
            verificationFailed("The request body did not match the challenge digest.")
        case .rejection(.settlementUnverified):
            verificationFailed("The payment could not be verified on its rail.")
        case .rejection(.noSupportingMethod):
            verificationFailed("No payment method can settle this challenge.")
        case let .rejection(.settlement(problem)):
            // §10.5: the method supplied a typed problem (its own type, title, and status).
            Spec(
                slug: problem.slug, title: problem.title, detail: problem.detail,
                status: problem.status
            )
        }
    }
}
