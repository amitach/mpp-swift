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

    /// Verifies the method-specific settlement carried by `credential` and returns
    /// the settlement reference for the `Payment-Receipt` the verifier mints.
    ///
    /// - Returns: The method-specific settlement `reference`: a transaction hash
    ///   for a settled transfer, or the challenge id for a zero-amount proof
    ///   (which references no on-chain settlement of its own). Its format is
    ///   defined by the method.
    /// - Throws: to reject. The credential parsed and bound to a server-issued
    ///   challenge, but its method payload did not prove settlement (for a proof,
    ///   the signature did not recover to the credential's `source` wallet, or the
    ///   payload was the wrong shape). The verifier runs this BEFORE consuming the
    ///   challenge id, so a credential rejected here does not burn a legitimate
    ///   payer's challenge.
    ///
    /// `async` because a settlement check may consult an external service: a
    /// zero-amount proof is pure local recovery, but a settled transfer confirms
    /// the transaction on-chain over an RPC. Defining the seam as `async` now keeps
    /// that later method from forcing a source-breaking protocol change.
    func verify(_ credential: Credential) async throws -> String
}
