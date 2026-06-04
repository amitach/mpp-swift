import MPPEVM

/// Selects which zero-amount proof shape the Tempo charge method emits.
///
/// A `draft-tempo-charge-00` zero-amount proof is EIP-712 typed data, and three
/// shapes are in use across the spec and the two reference SDKs. A server that
/// issued the challenge verifies the shape it expects; the client emits one. This
/// is the client's compatibility knob for that choice, defaulting to the form
/// live `mppx` servers verify today. (Broader compatibility switches, for example
/// fee-payer sponsorship, arrive with the on-chain settlement layer in a later
/// PR; the zero-amount proof needs only this one.)
public enum ProofVariant: Sendable, Hashable {
    /// Domain version `"2"`, message `{challengeId, realm}`. The default emitted.
    ///
    /// DIVERGING_FROM_SPEC (audit D3): `draft-tempo-charge-00` §5.4.1 defines the
    /// normative proof as single-field `{challengeId}` at domain version `"1"`
    /// (``specChallengeId``). The mppx peer deliberately binds the proof to the realm
    /// as well (peer CHANGELOG: "bind signatures to the challenge realm"), so this SDK
    /// defaults to the peer's realm-bound form for interop. Select ``specChallengeId``
    /// to target a strictly spec-conformant server.
    case v2Realm
    /// Domain version `"1"`, message `{challengeId, wallet}`.
    case v1Wallet
    /// Domain version `"1"`, message `{challengeId}`: the single-field form the
    /// `draft-tempo-charge-00` spec defines as normative. Select it to target a
    /// server implemented to the published spec rather than a peer SDK.
    case specChallengeId
}

public extension ProofVariant {
    /// The ``ZeroAmountProof`` this variant signs and verifies for a challenge.
    ///
    /// Both the client (which signs) and the server (which recovers) derive the
    /// proof here, so the two sides cannot drift when a variant is added or its
    /// message shape changes.
    func proof(
        challengeId: String, realm: String, wallet: EthereumAddress
    ) -> ZeroAmountProof {
        switch self {
        case .v2Realm: .v2Realm(challengeId: challengeId, realm: realm)
        case .v1Wallet: .v1Wallet(challengeId: challengeId, wallet: wallet)
        case .specChallengeId: .v1ChallengeId(challengeId: challengeId)
        }
    }
}
