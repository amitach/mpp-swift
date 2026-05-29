/// The `(realm, method, intent)` a payment-protected route requires, which a
/// credential's echoed challenge must match.
///
/// These are the protocol-identity slots of the challenge-id binding
/// (`draft-httpauth-payment-00` §5.1.2.1.1): the server mints a challenge for
/// this triple, and verification pins an incoming credential's challenge to it
/// so a credential minted for one route cannot be replayed against another
/// under a shared secret. The method-specific `request` is checked by the
/// payment method, not here.
///
/// Shared by the mint side (build a challenge for the route) and the verify
/// side (pin an incoming credential): one type, two consumers.
public struct RouteBinding: Sendable, Hashable {
    /// The protection space (RFC 9110 realm) this route charges under.
    public let realm: String
    /// The payment method this route accepts.
    public let method: MethodName
    /// The payment intent this route requires.
    public let intent: IntentName

    /// Creates the binding a route requires a credential's challenge to match.
    public init(realm: String, method: MethodName, intent: IntentName) {
        self.realm = realm
        self.method = method
        self.intent = intent
    }

    /// Whether `challenge` carries this route's realm, method, and intent.
    public func matches(_ challenge: Challenge) -> Bool {
        challenge.realm == realm && challenge.method == method && challenge.intent == intent
    }
}
