#if canImport(LocalAuthentication)
    import Foundation
    import LocalAuthentication
    import MPPClient
    import MPPCore

    /// A ``PaymentAuthorizer`` that gates a spend behind a Touch ID / device-authentication prompt
    /// (Apple platforms only; the type is absent where `LocalAuthentication` cannot be imported,
    /// e.g.
    /// Linux, so a cross-platform target builds without it).
    ///
    /// It probes `canEvaluatePolicy` first and, when neither biometrics nor a device passcode is
    /// available, denies (``PaymentDenied/unavailable(_:)``) rather than assume approval. It uses
    /// `.deviceOwnerAuthentication`, so biometrics with an automatic passcode fallback. A user
    /// cancel
    /// or a failed match denies (``PaymentDenied/declined``).
    ///
    /// - Note: `LAContext` from a bare CLI binary (no app bundle / signing identity) is unreliable;
    /// the
    ///   prompt is best-effort there. The GUI consumer (Kapsicum) is where this is exercised for
    /// real,
    ///   constructed in-process so the prompt belongs to that app.
    public struct BiometricPaymentAuthorizer: PaymentAuthorizer {
        private let reasonBuilder: @Sendable (PaymentApprovalRequest) -> String
        private let contextFactory: @Sendable () -> LAContext

        /// - Parameters:
        ///   - reason: builds the localized reason shown in the system prompt; defaults to a
        /// summary of
        ///     the amount, currency, and payee.
        ///   - contextFactory: makes a fresh `LAContext` per authorization (one prompt each);
        /// injectable
        ///     for testing.
        public init(
            reason: @escaping @Sendable (PaymentApprovalRequest) -> String = Self.defaultReason,
            contextFactory: @escaping @Sendable () -> LAContext = { LAContext() }
        ) {
            reasonBuilder = reason
            self.contextFactory = contextFactory
        }

        /// Presents the system authentication prompt; returns on approval, throws ``PaymentDenied``
        /// on
        /// an unavailable check or a declined / cancelled prompt.
        public func authorize(_ request: PaymentApprovalRequest) async throws {
            let context = contextFactory()
            var probeError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &probeError) else {
                throw PaymentDenied.unavailable(
                    probeError?.localizedDescription ?? "device authentication unavailable"
                )
            }
            let reasonText = reasonBuilder(request)
            let approved: Bool
            do {
                approved = try await withCheckedThrowingContinuation { continuation in
                    context.evaluatePolicy(
                        .deviceOwnerAuthentication, localizedReason: reasonText
                    ) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: success)
                        }
                    }
                }
            } catch {
                // A user cancel, failed match, or system cancel all mean: not approved.
                throw PaymentDenied.declined
            }
            guard approved else { throw PaymentDenied.declined }
        }

        /// The default prompt text: a short summary of the amount, currency, and payee. The
        /// server-controlled currency and payee are sanitized of control characters (defense in
        /// depth; a system auth dialog does not interpret terminal escapes, but a malicious field
        /// should not reach the prompt raw).
        public static func defaultReason(_ request: PaymentApprovalRequest) -> String {
            let amount = request.amount?.rawValue ?? "a payment"
            let currency = request.currency.map { " \(displaySafe($0, maxLength: 120))" } ?? ""
            let payee = displaySafe(request.recipient ?? request.realm, maxLength: 120)
            return "Approve \(amount)\(currency) to \(payee)"
        }
    }
#endif
