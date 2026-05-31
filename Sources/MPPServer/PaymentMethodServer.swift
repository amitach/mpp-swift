import Foundation
import MPPCore

/// A server-side payment method: it recognises the challenges it can settle and
/// verifies the method-specific proof in an `Authorization: Payment` credential.
///
/// ``PaymentVerifier`` performs the protocol-level checks (the challenge-id HMAC
/// binding, route binding, expiry, body digest, single-use consume) and produces
/// an ``MPPVerified`` token. That token attests the protocol layer only; whether
/// the payment actually settled on its rail (for a Tempo zero-amount charge, that
/// the EIP-712 proof recovers to the payer's wallet) is method-specific and
/// verified here. This is the server counterpart to the client's
/// `PaymentMethodClient` seam: the flow routes by method and delegates the
/// settlement check to the registered method that ``supports(_:)`` the challenge.
public protocol PaymentMethodServer: Sendable {
    /// Whether this method settles `challenge` (typically a `method`-name match,
    /// plus any method-specific applicability the method enforces).
    func supports(_ challenge: Challenge) -> Bool

    /// Verifies the method-specific settlement carried by `credential` and mints
    /// the ``Receipt`` for the `Payment-Receipt` the server returns.
    ///
    /// - Parameters:
    ///   - credential: The presented credential (its echoed challenge, payer
    ///     `source`, and method payload).
    ///   - now: The settlement time, injected, for the receipt's `timestamp`.
    /// - Returns: The method's receipt. Its `reference` is method-specific (a
    ///   transaction hash for a settled transfer, the challenge id for a
    ///   zero-amount proof). The method owns the whole receipt, so a richer method
    ///   (a future session method) can shape it rather than being constrained to a
    ///   bare reference.
    /// - Throws: to reject. The credential parsed and bound to a server-issued
    ///   challenge, but its method payload did not prove settlement (for a proof,
    ///   the signature did not recover to the credential's `source` wallet, or the
    ///   payload was the wrong shape).
    ///
    /// **Side-effect ordering (security).** The verifier consumes the single-use
    /// challenge id BEFORE calling this, so any side effect a method performs here (a
    /// session broadcasts/charges) is gated by the replay consume: a replayed
    /// credential is rejected before it can act. A method that opts into
    /// ``reusesChallenge`` (a session) skips the one-time consume and MUST therefore
    /// enforce its own atomic anti-replay so its side effects cannot run twice (the
    /// monotonic channel cumulative, decided inside the channel store's serialized
    /// update). The cost of consuming first is that a credential rejected here burns
    /// its challenge id; the client retries on a fresh `402`.
    ///
    /// `async` because a settlement check may consult an external service: a
    /// zero-amount proof is pure local recovery, but a settled transfer confirms
    /// the transaction on-chain over an RPC.
    func verify(_ credential: Credential, now: Date) async throws -> Receipt

    /// Whether this method's challenge may be presented more than once. Defaults to
    /// `false`: the verifier consumes the challenge id exactly once (the one-shot
    /// proof / charge model). A session method returns `true`: one challenge is reused
    /// across the channel lifecycle (open, vouchers, close) and the method enforces
    /// anti-replay itself (the monotonic cumulative recorded per channel), so one-time
    /// challenge consumption would wrongly reject every payment after the first.
    var reusesChallenge: Bool { get }
}

public extension PaymentMethodServer {
    /// One-shot by default: the verifier consumes the challenge id exactly once. A method
    /// that reuses its challenge (a session) overrides this to `true`.
    var reusesChallenge: Bool {
        false
    }
}
