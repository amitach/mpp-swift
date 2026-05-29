import Foundation

/// A zero-amount charge proof: an EIP-712 credential proving control of a wallet
/// for a given challenge, with no on-chain settlement. The two reference SDKs
/// diverge on the proof shape, so both variants are first-class; a server verifies
/// either, and a client emits ``v2`` by default.
///
/// Both use the EIP-712 domain `name = "MPP"` with only `name`, `version`, and
/// `chainId` (no `verifyingContract`, no `salt`). The signing hash is
/// `keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(Proof))`, signed directly by
/// ``Secp256k1Signer``.
public enum ZeroAmountProof: Sendable, Hashable {
    /// Domain version `"1"`, `Proof(string challengeId,address wallet)` (mpp-rs).
    /// The type string has no spaces after commas: it is the canonical EIP-712
    /// `encodeType`, and its exact bytes determine the type hash.
    case v1Wallet(challengeId: String, wallet: EthereumAddress)
    /// Domain version `"2"`, `Proof(string challengeId,string realm)` (mppx).
    case v2Realm(challengeId: String, realm: String)

    /// The EIP-712 domain version for this variant (`"1"` or `"2"`).
    private var domainVersion: String {
        switch self {
        case .v1Wallet: "1"
        case .v2Realm: "2"
        }
    }

    /// The `Proof` type hash for this variant: `keccak256(encodeType)`.
    private var typeHash: Data {
        switch self {
        case .v1Wallet: Keccak256.hash(Data("Proof(string challengeId,address wallet)".utf8))
        case .v2Realm: Keccak256.hash(Data("Proof(string challengeId,string realm)".utf8))
        }
    }

    /// `hashStruct(Proof)` for this variant.
    public var structHash: Data {
        switch self {
        case let .v1Wallet(challengeId, wallet):
            EIP712.hashStruct(typeHash: typeHash, fields: [EIP712.string(challengeId), wallet.word])
        case let .v2Realm(challengeId, realm):
            EIP712.hashStruct(
                typeHash: typeHash,
                fields: [EIP712.string(challengeId), EIP712.string(realm)]
            )
        }
    }

    /// The 32-byte EIP-712 signing hash for the `MPP` domain at `chainId`.
    public func signingHash(chainId: UInt64) -> Data {
        let separator = EIP712.domainSeparator(
            name: "MPP",
            version: domainVersion,
            chainId: chainId
        )
        return EIP712.signingHash(domainSeparator: separator, structHash: structHash)
    }

    /// Signs the proof, returning the 65-byte Ethereum signature `r ‖ s ‖ v` with
    /// `v = recoveryID + 27` (the Ethereum recovery-id offset; raw recovery ids come
    /// from ``Secp256k1Signer``, which leaves the wire convention to this layer).
    public func sign(
        chainId: UInt64, with signer: Secp256k1Signer
    ) throws(Secp256k1Signer.SigningError) -> Data {
        let signature = try signer.sign(hash: signingHash(chainId: chainId))
        return signature.compact + Data([signature.recoveryID + 27])
    }

    /// Recovers the Ethereum address that produced `signature` over this proof at
    /// `chainId`, or `nil` if `signature` is not a well-formed 65-byte `r ‖ s ‖ v`
    /// (with `v` in `27...30`) or recovery fails. This is the cryptographic half of
    /// verification: compare the recovered address against the expected wallet. It
    /// does not apply any acceptance policy.
    public func recoverSigner(chainId: UInt64, signature: Data) -> EthereumAddress? {
        EthereumAddress.recover(hash: signingHash(chainId: chainId), signature: signature)
    }
}
