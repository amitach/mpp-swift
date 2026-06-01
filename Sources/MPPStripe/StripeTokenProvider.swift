import MPPCore

/// The charge facts handed to a ``StripeTokenProvider`` when the client needs a Shared Payment
/// Token for a `stripe`/`charge` challenge. It carries the resolved charge (amount/currency), the
/// Stripe routing fields (`networkId`, `paymentMethodTypes`), and the challenge binding
/// (`challengeId`, `realm`, `expires`) so a provider can mint or fetch an SPT scoped to exactly
/// this charge.
public struct StripeTokenRequest: Sendable, Hashable {
    /// The id of the challenge being paid.
    public let challengeId: String
    /// The challenge realm (the charging server's origin).
    public let realm: String
    /// The charge amount in the currency's smallest unit.
    public let amount: Amount
    /// The three-letter ISO currency code (e.g. `"usd"`).
    public let currency: String
    /// An optional human-readable charge description.
    public let description: String?
    /// An optional recipient identifier (display/routing).
    public let recipient: String?
    /// The Stripe Business Network profile id the charge settles under.
    public let networkId: String
    /// The payment method types the charge accepts (at least one).
    public let paymentMethodTypes: [String]
    /// Optional server-supplied metadata for the charge.
    public let metadata: [String: String]?
    /// When the challenge expires, if bounded.
    public let expires: Expires?

    /// Creates a token request. Public so a consumer can construct one to unit-test its own
    /// ``StripeTokenProvider`` closure in isolation (the framework builds it during a charge).
    public init(
        challengeId: String,
        realm: String,
        amount: Amount,
        currency: String,
        description: String? = nil,
        recipient: String? = nil,
        networkId: String,
        paymentMethodTypes: [String],
        metadata: [String: String]? = nil,
        expires: Expires? = nil
    ) {
        self.challengeId = challengeId
        self.realm = realm
        self.amount = amount
        self.currency = currency
        self.description = description
        self.recipient = recipient
        self.networkId = networkId
        self.paymentMethodTypes = paymentMethodTypes
        self.metadata = metadata
        self.expires = expires
    }
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
