import MPPCore

/// One payment method a route offers: the route binding it mints/verifies for and
/// the method-specific request to advertise (`base64url(JCS(json))`).
///
/// A single-method route carries one offer; a route that lets a client choose
/// among methods (e.g. pay with Tempo or Stripe) carries several, and answers a
/// `402` with one `WWW-Authenticate` challenge per offer. The offers typically
/// share a realm and intent and differ by `method`, but that is not required.
public struct MethodOffer: Sendable {
    /// The `(realm, method, intent)` this offer mints and verifies for.
    public let binding: RouteBinding
    /// The method-specific request advertised in the offer's challenge.
    public let request: EncodedJSON

    public init(binding: RouteBinding, request: EncodedJSON) {
        self.binding = binding
        self.request = request
    }
}
