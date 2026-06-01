import MPPCore

/// Shared identity of the Stripe charge method: the `stripe` method name (the intent is
/// `IntentName.charge`). `MethodName` ships no predefined `stripe` constant and its unchecked
/// initializer is package-internal, so this fixed grammar-valid token is built once here and
/// reused by both the client (``StripeChargeMethod``) and the server verifier, rather than
/// duplicated.
public enum StripeMethod {
    /// The canonical `stripe` method name.
    public static let name: MethodName = {
        guard let name = try? MethodName("stripe") else {
            preconditionFailure("stripe is a valid method name")
        }
        return name
    }()
}
