import ArgumentParser
import MPPAuth
import MPPClient
import MPPCore

/// How the CLI authorizes a payment.
enum ApproveMode: String, ExpressibleByArgument, CaseIterable {
    /// No prompt: approve within `--max-amount` (a spending cap), else (interactively) approve all.
    case auto
    /// Prompt yes/no at the terminal.
    case tty
    /// Prompt for Touch ID / device authentication (Apple platforms).
    case biometric
}

/// Builds the single consent ``PaymentAuthorizer`` for a payment, enforcing the headless-safety
/// rules from the security review: never prompt when there is no terminal, and never approve an
/// unbounded spend non-interactively.
enum AuthorizerFactory {
    /// - Parameters:
    ///   - approve: the chosen mode, or `nil` to default (`tty` when interactive, else `auto`).
    ///   - maxAmount: the spending cap for `auto`, if any.
    ///   - interactive: whether a terminal prompt can be shown and answered.
    static func make(
        approve: ApproveMode?,
        maxAmount: Amount?,
        interactive: Bool
    ) throws -> any PaymentAuthorizer {
        switch approve ?? (interactive ? .tty : .auto) {
        case .tty:
            guard interactive else { throw CLIError.promptUnavailable(mode: "tty") }
            return TTYPaymentAuthorizer()
        case .biometric:
            guard interactive else { throw CLIError.promptUnavailable(mode: "biometric") }
            #if canImport(LocalAuthentication)
                return BiometricPaymentAuthorizer()
            #else
                throw CLIError.biometricUnavailable
            #endif
        case .auto:
            if let maxAmount {
                return SpendingCapAuthorizer(maxAmount: maxAmount)
            }
            // Auto with no cap would approve whatever the server demands. Allowed only when a human
            // is present (they explicitly opted out of a prompt); never silently, headless.
            guard interactive else { throw CLIError.unboundedHeadlessSpend }
            return AllowAllAuthorizer()
        }
    }
}
