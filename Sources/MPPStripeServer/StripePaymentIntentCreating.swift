/// The inputs for creating one Stripe PaymentIntent from a Shared Payment Token: the amount (in
/// the currency's smallest unit), currency, the SPT, the resolved metadata (analytics + user),
/// the idempotency key, and an optional Connect settlement. The amount is an `Int` (the only place
/// the rail leaves the canonical-string amount domain; converted, overflow-checked, at the verifier
/// boundary).
public struct StripePaymentIntentRequest: Sendable, Hashable {
    public let amount: Int
    public let currency: String
    public let sharedPaymentGrantedToken: String
    public let metadata: [String: String]
    public let idempotencyKey: String
    public let settlement: StripeConnectSettlement?

    public init(
        amount: Int,
        currency: String,
        sharedPaymentGrantedToken: String,
        metadata: [String: String],
        idempotencyKey: String,
        settlement: StripeConnectSettlement? = nil
    ) {
        self.amount = amount
        self.currency = currency
        self.sharedPaymentGrantedToken = sharedPaymentGrantedToken
        self.metadata = metadata
        self.idempotencyKey = idempotencyKey
        self.settlement = settlement
    }
}

/// The PaymentIntent fields the verifier maps to a receipt or a rejection: the id, the raw Stripe
/// status string, and whether Stripe replayed an idempotent request.
public struct StripePaymentIntentResult: Sendable, Hashable {
    public let id: String
    public let status: String
    public let replayed: Bool

    public init(id: String, status: String, replayed: Bool) {
        self.id = id
        self.status = status
        self.replayed = replayed
    }
}

/// Creates a Stripe PaymentIntent. The concrete ``StripePaymentIntentClient`` posts to
/// `api.stripe.com`; tests inject a stub returning a canned result, so the full verifier state
/// machine runs with no Stripe account or network.
public protocol StripePaymentIntentCreating: Sendable {
    func create(_ request: StripePaymentIntentRequest) async throws -> StripePaymentIntentResult
}
