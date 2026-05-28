import Foundation
import MPPBodyDigest
import MPPCore

/// Verifies an `Authorization: Payment` credential against this server's secret:
/// the protocol-level gate that turns an untrusted request into an ``MPPVerified``
/// token, or a typed rejection.
///
/// The pipeline runs in order: parse the credential; confirm its echoed challenge
/// is one this server signed (HMAC, via ``ChallengeSigner``); confirm the
/// challenge's realm/method/intent match the route's ``RouteBinding``; confirm
/// it has not expired; confirm the request body matches the challenge digest
/// (when the challenge carries one); and finally consume the challenge id exactly
/// once (``ReplayStore``).
///
/// Consume is LAST on purpose: an invalid credential must never burn a legitimate
/// payer's challenge id, and the consume must precede any side effect the caller
/// performs (it returns inside `verify`, before the handler runs). Consume also
/// fails closed: if first use cannot be confirmed, the credential is rejected.
public struct PaymentVerifier: Sendable {
    private let signer: ChallengeSigner
    private let replayStore: any ReplayStore

    /// Creates a verifier over the server's challenge signer and replay store.
    public init(signer: ChallengeSigner, replayStore: any ReplayStore) {
        self.signer = signer
        self.replayStore = replayStore
    }

    /// Verifies the `Authorization: Payment` header value against `body` as of
    /// `now`, for a route that requires `expecting`.
    ///
    /// `expecting` is required, not optional: the HMAC proves only that this
    /// server issued *a* challenge with the credential's realm/method/intent, not
    /// that they match the resource being accessed. Pinning them here prevents a
    /// confused-deputy / cross-route replay (a credential minted for a cheap
    /// route presented to an expensive one under a shared secret). A nil-able
    /// default would let a caller silently skip the pin, so the parameter is
    /// mandatory.
    public func verify(
        authorization: String,
        body: Data,
        now: Date,
        expecting: RouteBinding
    ) async -> Outcome {
        guard let credential = try? Credential(headerValue: authorization) else {
            return .rejected(.malformedCredential)
        }
        let challenge = credential.challenge

        // The id is an HMAC over the challenge's binding input; this proves the
        // server issued exactly these (unmodified) challenge parameters.
        guard signer.verify(challenge) else { return .rejected(.invalidChallenge) }

        // ...but not that they are this route's parameters: pin them.
        guard expecting.matches(challenge) else { return .rejected(.bindingMismatch) }

        if let expires = challenge.expires, expires.isExpired(at: now) {
            return .rejected(.expired)
        }

        if let digest = challenge.digest {
            // A malformed digest in our own signed challenge, or a body mismatch,
            // both reject (fail closed).
            guard (try? ContentDigest.verify(body, matches: digest)) == true else {
                return .rejected(.digestMismatch)
            }
        }

        guard await replayStore.consume(challenge.id) else { return .rejected(.replayed) }

        return .verified(MPPVerified(credential: credential))
    }

    /// The result of verifying a credential.
    public enum Outcome: Sendable {
        /// The credential is protocol-valid; the request may be served.
        case verified(MPPVerified)
        /// The credential was rejected; the server answers `402` with the
        /// corresponding problem.
        case rejected(Rejection)
    }

    /// Why a credential was rejected.
    public enum Rejection: Sendable, Hashable {
        /// The Authorization value was not a parseable `Payment` credential.
        case malformedCredential
        /// The echoed challenge was not signed by this server (bad id binding).
        case invalidChallenge
        /// The challenge's realm/method/intent did not match the route's
        /// (a credential minted for a different resource).
        case bindingMismatch
        /// The challenge had expired as of `now`.
        case expired
        /// The request body did not match the challenge's content digest.
        case digestMismatch
        /// The challenge id had already been consumed (replay).
        case replayed
    }
}
