import Crypto
import Foundation

/// Derives the Stripe `Idempotency-Key` for a charge: stable per `(challenge, spt)`, so a retry of
/// the exact same charge collides and Stripe replays the original (which the verifier rejects as
/// already processed) rather than charging twice.
///
/// The MPP spec mandates no key format (it is server-internal), so this hashes the SPT rather than
/// inlining it: the SPT is a payment-authorizing secret and the key travels in a header that
/// intermediaries may log, so we keep the secret out of it. This is a deliberate divergence from
/// the reference SDK's raw-`spt` key: a Swift server's idempotency is intentionally not
/// interoperable with the reference server's for the same SPT, which is acceptable because a
/// deployment runs one SDK and the MPP replay store already dedupes the challenge before any
/// PaymentIntent is created (this key is defense-in-depth at Stripe).
enum StripeIdempotencyKey {
    static func derive(challengeID: String, spt: String) -> String {
        let digest = SHA256.hash(data: Data(spt.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "mpp-swift_\(challengeID)_\(hex)"
    }
}
