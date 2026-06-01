/// Builds the metadata attached to every Stripe PaymentIntent: the reference-SDK `mpp_*` analytics
/// namespace (user-overridable) plus the spec-required `challenge_id` reconciliation key, which is
/// applied last so user metadata cannot override it.
///
/// Per `draft-stripe-charge-00` §9 the PaymentIntent metadata spreads the user metadata first and
/// assigns `challenge_id` after it (non-overridable). The reference SDK (mppx) instead emits
/// `mpp_challenge_id` and lets user metadata win; we keep its `mpp_*` namespace as additive
/// analytics but follow the spec for the authoritative `challenge_id` key and its precedence.
enum StripeAnalyticsMetadata {
    /// The reference-SDK `mpp_*` analytics namespace (user-overridable). `mpp_client_id` is
    /// included
    /// only when a credential `source` is present (Stripe charges carry none, so it is usually
    /// absent). The spec's `challenge_id` is NOT built here; ``merged`` applies it last.
    static func build(
        challengeID: String, realm: String, intent: String, source: String?
    ) -> [String: String] {
        var metadata: [String: String] = [
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

    /// Merges `user` metadata over the analytics (user keys win on collision, matching the
    /// reference
    /// SDK), then sets the spec-required `challenge_id` **last** so user metadata cannot override
    /// the
    /// authoritative reconciliation key (`draft-stripe-charge-00` §9).
    static func merged(
        analytics: [String: String], user: [String: String]?, challengeID: String
    ) -> [String: String] {
        var result = analytics
        if let user {
            result.merge(user) { _, userValue in userValue }
        }
        result["challenge_id"] = challengeID
        return result
    }
}
