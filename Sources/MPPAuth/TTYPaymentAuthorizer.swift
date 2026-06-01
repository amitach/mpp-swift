import Foundation
import MPPClient
import MPPCore

/// A ``PaymentAuthorizer`` that asks the operator to confirm a spend at the terminal.
///
/// It writes a one-line prompt (to standard error by default, so standard output stays clean for
/// piping or `--json`) and reads a yes/no answer (from standard input by default). Only an explicit
/// `y` / `yes` approves; anything else, including end-of-input, denies
/// (``PaymentDenied/declined``).
/// Both ends are injectable so the decision is testable without a real terminal, and works on every
/// platform (unlike the biometric authorizer).
public struct TTYPaymentAuthorizer: PaymentAuthorizer {
    private let promptSink: @Sendable (String) -> Void
    private let readResponse: @Sendable () -> String?

    /// - Parameters:
    ///   - promptSink: writes the confirmation prompt; defaults to standard error.
    ///   - readResponse: reads one line of the operator's answer; defaults to standard input. The
    ///     default uses a synchronous `readLine`, which blocks the calling thread until the
    /// operator
    ///     answers - fine for an interactive CLI (one prompt at a time); inject a non-blocking
    ///     reader for a concurrent or server context.
    public init(
        promptSink: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data(message.utf8))
        },
        readResponse: @escaping @Sendable () -> String? = { readLine(strippingNewline: true) }
    ) {
        self.promptSink = promptSink
        self.readResponse = readResponse
    }

    /// Prompts for confirmation; approves only on an explicit `y` / `yes`, otherwise denies.
    public func authorize(_ request: PaymentApprovalRequest) async throws {
        promptSink(Self.prompt(for: request))
        let answer = readResponse()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard answer == "y" || answer == "yes" else {
            throw PaymentDenied.declined
        }
    }

    private static func prompt(for request: PaymentApprovalRequest) -> String {
        // The amount is a validated digits-only `Amount`, safe as-is. The currency, payee, and
        // description are server-controlled, so they are sanitized of terminal control characters
        // and length-bounded before display, so a crafted challenge cannot spoof, rewrite, or
        // flood this confirmation line.
        let amount = request.amount?.rawValue ?? "an unspecified amount"
        let currency = request.currency.map { " \(displaySafe($0, maxLength: 120))" } ?? ""
        let payee = displaySafe(request.recipient ?? request.realm, maxLength: 120)
        let detail = request.description.map { " (\(displaySafe($0, maxLength: 120)))" } ?? ""
        return "Approve payment of \(amount)\(currency) to \(payee)\(detail)? [y/N] "
    }
}
