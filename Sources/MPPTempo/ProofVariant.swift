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
    /// Domain version `"2"`, message `{challengeId, realm}`. The default emitted;
    /// the form `mppx` servers verify.
    case v2Realm
    /// Domain version `"1"`, message `{challengeId, wallet}`.
    case v1Wallet
    /// Domain version `"1"`, message `{challengeId}`: the single-field form the
    /// `draft-tempo-charge-00` spec defines as normative. Select it to target a
    /// server implemented to the published spec rather than a peer SDK.
    case specChallengeId
}
