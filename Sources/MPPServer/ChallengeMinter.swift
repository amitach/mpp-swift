import MPPCore

/// Mints signed payment challenges for a route: the server side of the 402.
///
/// Given a route's ``RouteBinding`` and the method-specific request, this builds
/// a ``Challenge`` and stamps its ``Challenge/id`` with the server's HMAC (via
/// ``ChallengeSigner``), producing a challenge that ``PaymentVerifier`` on the
/// same secret will later accept. The `id` is `base64url(HMAC-SHA256(secret,
/// bindingInput))`; because ``Challenge/bindingInput`` excludes the `id`, the
/// minter computes it from a draft and returns the finished challenge.
///
/// This is pure composition over existing primitives: it adds no wire format,
/// only the mint-side counterpart to the verify pipeline.
public struct ChallengeMinter: Sendable {
    private let signer: ChallengeSigner

    /// Creates a minter over the server's challenge signer.
    public init(signer: ChallengeSigner) {
        self.signer = signer
    }

    /// Mints a signed ``Challenge`` for `binding` and `request`.
    ///
    /// - Parameters:
    ///   - binding: The route's `(realm, method, intent)`.
    ///   - request: The method-specific request data, `base64url(JCS(json))`.
    ///   - digest: Optional RFC 9530 content digest of the expected request body.
    ///   - expires: Optional expiry; omit for a challenge that does not lapse.
    ///   - description: Optional human-readable text, for display only (not bound).
    ///   - opaque: Optional server correlation data, `base64url(JCS(json))`.
    /// - Returns: A challenge whose `id` is a valid HMAC under this signer's
    ///   secret, ready to serialize into a `WWW-Authenticate: Payment` header.
    public func mint(
        binding: RouteBinding,
        request: EncodedJSON,
        digest: String? = nil,
        expires: Expires? = nil,
        description: String? = nil,
        opaque: EncodedJSON? = nil
    ) -> Challenge {
        // The id is an HMAC over bindingInput, which excludes the id itself, so a
        // draft with an empty id computes the same code as the finished challenge;
        // stamp the computed id back onto the draft (see `Challenge.withID`).
        let draft = Challenge(
            id: "",
            realm: binding.realm,
            method: binding.method,
            intent: binding.intent,
            request: request,
            digest: digest,
            expires: expires,
            description: description,
            opaque: opaque
        )
        return draft.withID(signer.computeID(for: draft))
    }
}
