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
    ///   zero-amount proof); a method may add its own fields via `Receipt.extras`
    ///   (a Tempo session receipt's `channelId`/`acceptedCumulative`/...). The
    ///   method owns the receipt so a richer method (session) is not constrained to
    ///   the base shape.
    /// - Throws: to reject. The credential parsed and bound to a server-issued
    ///   challenge, but its method payload did not prove settlement (for a proof,
    ///   the signature did not recover to the credential's `source` wallet, or the
    ///   payload was the wrong shape). The verifier runs this BEFORE consuming the
    ///   challenge id, so a credential rejected here does not burn a legitimate
    ///   payer's challenge.
    ///
    /// `async` because a settlement check may consult an external service: a
    /// zero-amount proof is pure local recovery, but a settled transfer confirms
    /// the transaction on-chain over an RPC.
    func verify(_ credential: Credential, now: Date) async throws -> Receipt
}
