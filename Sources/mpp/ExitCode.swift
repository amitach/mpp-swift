import Foundation
import MPPAuth
import MPPClient
import MPPCore
import MPPStripe

/// A command-line failure the `mpp` tool raises, each carrying a curl / mppx-style exit code.
enum CLIError: Error {
    case invalidURL(String)
    case invalidMethod(String)
    case invalidPrivateKey
    case invalidMaxAmount(String)
    case noPaymentMethod
    case unboundedHeadlessSpend
    case promptUnavailable(mode: String)
    case biometricUnavailable
    case httpError(status: Int)
    case invalidChallenge
    case noMethodForChallenge
    case cannotLoad(String)
    case invalidInput(String)
    case accountsUnsupported
    case accountExists(String)
    case invalidAccountName(String)
}

/// The resolved outcome for any thrown error: a process exit code (curl / mppx convention: 0 ok,
/// 2 usage, 22 http, 60 insecure-transport, 69 no payment method, 75 payment rejected, 77 stripe),
/// a short machine-readable code, and a human message.
struct CLIOutcome {
    /// One resolved (exitCode, code, message) triple. A named type rather than a 3-member tuple.
    struct Fields {
        let exitCode: Int32
        let code: String
        let message: String
        init(_ exitCode: Int32, _ code: String, _ message: String) {
            self.exitCode = exitCode
            self.code = code
            self.message = message
        }
    }

    let exitCode: Int32
    let code: String
    let message: String

    init(error: any Error) {
        let fields = Self.resolve(error)
        exitCode = fields.exitCode
        code = fields.code
        message = fields.message
    }

    private static func resolve(_ error: any Error) -> Fields {
        switch error {
        case let cli as CLIError: cli.fields
        case is PaymentDenied:
            .init(75, "payment_rejected", "Payment was not authorized (\(error)).")
        case let flow as PaymentClientError: flow.fields
        case let store as AccountStoreError: store.fields
        case is StripeMethodError:
            .init(77, "stripe_error", "The Stripe payment method failed (\(error)).")
        case is Amount.ValidationError:
            .init(2, "usage", "Invalid amount (\(error)).")
        default:
            .init(1, "error", "\(error)")
        }
    }
}

private extension CLIError {
    var fields: CLIOutcome.Fields {
        switch self {
        case let .invalidURL(url):
            .init(2, "usage", "Not a valid URL: \(url)")
        case let .invalidMethod(method):
            .init(2, "usage", "Not a valid HTTP method: \(method)")
        case .invalidPrivateKey:
            .init(2, "usage", "MPP_PRIVATE_KEY is not valid 0x-prefixed 32-byte hex.")
        case let .invalidMaxAmount(value):
            .init(2, "usage", "Invalid --max-amount (a base-units integer): \(value)")
        case .noPaymentMethod:
            .init(69, "no_method", "No payment method. Set MPP_PRIVATE_KEY or MPP_STRIPE_SPT.")
        case .unboundedHeadlessSpend:
            .init(2, "usage", "A non-interactive payment requires an explicit --max-amount.")
        case let .promptUnavailable(mode):
            .init(2, "usage", "--approve \(mode) requires an interactive terminal.")
        case .biometricUnavailable:
            .init(2, "usage", "Biometric approval is unavailable on this platform.")
        case let .httpError(status):
            .init(22, "http_error", "The server returned HTTP \(status).")
        case .invalidChallenge:
            .init(2, "usage", "Not a valid Payment challenge.")
        case .noMethodForChallenge:
            .init(75, "payment_rejected", "No configured method can sign this challenge.")
        case let .cannotLoad(source):
            .init(2, "usage", "Could not read: \(source)")
        case let .invalidInput(reason):
            .init(2, "usage", "Invalid input: \(reason)")
        case .accountsUnsupported:
            .init(2, "usage", "Named accounts need macOS; on this platform set MPP_PRIVATE_KEY.")
        case let .accountExists(name):
            .init(2, "usage", "An account named '\(name)' already exists.")
        case let .invalidAccountName(name):
            .init(2, "usage", "Invalid account name '\(name)' (use letters, digits, - and _).")
        }
    }
}

private extension AccountStoreError {
    var fields: CLIOutcome.Fields {
        switch self {
        case let .notFound(name):
            .init(69, "no_account", "No such account: \(name)")
        case let .ioFailure(detail):
            .init(1, "keychain_error", "Account store error: \(detail)")
        }
    }
}

private extension PaymentClientError {
    var fields: CLIOutcome.Fields {
        switch self {
        case .insecureTransport:
            .init(60, "insecure_transport", "Refusing to pay over an insecure (non-https) link.")
        case .malformedChallenge, .noSupportedMethod:
            .init(75, "payment_rejected", "No usable payment for the server's challenge.")
        }
    }
}
