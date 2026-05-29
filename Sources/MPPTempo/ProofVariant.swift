/// Selects which zero-amount proof shape the Tempo charge method emits.
///
/// A `draft-tempo-charge-00` zero-amount proof is EIP-712 typed data, and two
/// shapes are in use: `Proof(string challengeId,string realm)` under domain
/// version `"2"` (the default), and `Proof(string challengeId,address wallet)`
/// under domain version `"1"`. A server that issued the challenge verifies the
/// shape it expects; the client emits one. This is the client's compatibility
/// knob for that choice. (Broader compatibility switches, for example fee-payer
/// sponsorship, arrive with the on-chain settlement layer in a later PR; the
/// zero-amount proof needs only this one.)
public enum ProofVariant: Sendable, Hashable {
    /// Domain version `"2"`, message `{challengeId, realm}`. The default emitted.
    case v2Realm
    /// Domain version `"1"`, message `{challengeId, wallet}`.
    case v1Wallet
}
