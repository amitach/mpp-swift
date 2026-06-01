import MPPCore

/// The charge facts handed to a ``StripeTokenProvider`` when the client needs a Shared Payment
/// Token for a `stripe`/`charge` challenge. It carries the resolved charge (amount/currency), the
/// Stripe routing fields (`networkId`, `paymentMethodTypes`), and the challenge binding
/// (`challengeId`, `realm`, `expires`) so a provider can mint or fetch an SPT scoped to exactly
/// this charge.
public struct StripeTokenRequest: Sendable, Hashable {
    public let challengeId: String
    public let realm: String
    public let amount: Amount
    public let currency: String
    public let description: String?
    public let recipient: String?
    public let networkId: String
    public let paymentMethodTypes: [String]
    public let metadata: [String: String]?
    public let expires: Expires?
}

/// Supplies the Stripe **Shared Payment Token** the client presents for a charge.
///
/// There is no Stripe.js in Swift, so the paying agent obtains the SPT out of band (Stripe's
/// issued-tokens API, a wallet, a test helper) and injects it through this seam, mirroring the
/// reference SDK's `createToken` callback. The provider is also the **pre-pay gate**: throwing
/// (rather than returning a token) rejects the charge, so no separate approval policy is needed.
///
/// - Important: the returned string is a payment-authorizing secret. It is never logged, and the
///   credential that carries it redacts it in its description.
public struct StripeTokenProvider: Sendable {
    private let create: @Sendable (StripeTokenRequest) async throws -> String

    /// Creates a provider from a closure that returns an SPT for the charge, or throws to refuse.
    public init(_ create: @escaping @Sendable (StripeTokenRequest) async throws -> String) {
        self.create = create
    }

    /// Returns the SPT for `request`, or rethrows the provider's refusal.
    public func token(for request: StripeTokenRequest) async throws -> String {
        try await create(request)
    }

    /// A provider that always refuses, for tests of the rejection path.
    public static let failing = StripeTokenProvider { _ in
        throw TokenError.unavailable
    }

    /// The error ``failing`` throws.
    public enum TokenError: Error, Sendable, Hashable {
        case unavailable
    }
}
