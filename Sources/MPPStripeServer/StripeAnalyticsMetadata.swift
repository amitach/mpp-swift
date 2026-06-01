/// Builds the metadata attached to every Stripe PaymentIntent, then merges the charge's user
/// metadata over it (user keys win on collision, matching the reference SDK; these flags are
/// best-effort, not a security boundary).
///
/// The spec (`draft-stripe-charge-00` §9) requires a `challenge_id` reconciliation key on the
/// PaymentIntent; the `mpp_*` keys are the reference SDK's additional analytics namespace, kept
/// alongside it.
enum StripeAnalyticsMetadata {
    /// `challenge_id` is the spec-mandated reconciliation key. `mpp_client_id` is included only
    /// when
    /// a credential `source` is present (Stripe charges carry none, so it is usually absent).
    static func build(
        challengeID: String, realm: String, intent: String, source: String?
    ) -> [String: String] {
        var metadata: [String: String] = [
            // Spec-required reconciliation key (draft-stripe-charge-00 §9).
            "challenge_id": challengeID,
            // Reference-SDK analytics namespace.
            "mpp_version": "1",
            "mpp_is_mpp": "true",
            "mpp_intent": intent,
            "mpp_challenge_id": challengeID,
            "mpp_server_id": realm,
        ]
        if let source {
            metadata["mpp_client_id"] = source
        }
        return metadata
    }

    /// Merges `user` metadata over the analytics, with user keys winning on collision.
    static func merged(
        analytics: [String: String], user: [String: String]?
    ) -> [String: String] {
        guard let user else { return analytics }
        return analytics.merging(user) { _, userValue in userValue }
    }
}
