/// Stripe API constants for the charge rail, in one place because they are private-preview and
/// must be bumped in lockstep with the protocol.
enum StripeAPI {
    /// The `Stripe-Version` the Shared Payment Token flow requires. SPTs and the
    /// `shared_payment_granted_token` PaymentIntent field are a Stripe **private preview**: this
    /// pin is mandatory and changes when the preview moves (the live conformance job is the only
    /// thing that catches a server-side change, and it is non-required).
    static let version = "2026-02-25.preview"

    /// The PaymentIntent field that carries the Shared Payment Token (private preview).
    static let sharedPaymentTokenField = "shared_payment_granted_token"

    /// The PaymentIntents REST path.
    static let paymentIntentsPath = "/v1/payment_intents"
}
