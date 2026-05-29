import Foundation

/// A session voucher: an EIP-712 credential authorizing a cumulative payment over
/// a payment channel, signed by the channel's authorized signer and redeemed at an
/// escrow contract. Vouchers are cumulative and monotonic across a session; that
/// ordering policy lives in the server's voucher store, not in this signing and
/// verification primitive.
///
/// Domain: `name = "Tempo Stream Channel"`, `version = "1"`, with the escrow as the
/// `verifyingContract` (a four-field domain, unlike the proof's three). Message:
/// `Voucher(bytes32 channelId,uint128 cumulativeAmount)`. The signing hash is
/// `keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(Voucher))`.
public struct Voucher: Sendable, Hashable {
    /// The 32-byte channel identifier (see
    /// ``channelID(payer:payee:token:salt:authorizedSigner:escrowContract:chainId:)``).
    public let channelID: Data
    /// The cumulative authorized amount, as the base-10 string it arrives as on the
    /// wire (a `uint128`).
    public let cumulativeAmount: String
    /// The 32-byte big-endian encoding of ``cumulativeAmount`` (validated at init).
    private let amountWord: Data

    /// Creates a voucher, or `nil` if `channelID` is not 32 bytes or
    /// `cumulativeAmount` is not a base-10 integer that fits in a `uint128`.
    public init?(channelID: Data, cumulativeAmount: String) {
        guard channelID.count == 32,
              let word = EIP712.uint256(decimal: cumulativeAmount),
              word.prefix(16).allSatisfy({ $0 == 0 }) // fits uint128 (high 16 bytes zero)
        else { return nil }
        self.channelID = channelID
        self.cumulativeAmount = cumulativeAmount
        amountWord = word
    }

    private static let typeHash: Data =
        Keccak256.hash(Data("Voucher(bytes32 channelId,uint128 cumulativeAmount)".utf8))

    /// `hashStruct(Voucher)`.
    public var structHash: Data {
        EIP712.hashStruct(typeHash: Self.typeHash, fields: [channelID, amountWord])
    }

    /// The 32-byte EIP-712 signing hash for the voucher domain bound to
    /// `escrowContract` at `chainId`.
    public func signingHash(escrowContract: EthereumAddress, chainId: UInt64) -> Data {
        let separator = EIP712.domainSeparator(
            name: "Tempo Stream Channel",
            version: "1",
            chainId: chainId,
            verifyingContract: escrowContract
        )
        return EIP712.signingHash(domainSeparator: separator, structHash: structHash)
    }

    /// Signs the voucher, returning the 65-byte Ethereum signature `r ‖ s ‖ v`
    /// (`v = recoveryID + 27`).
    public func sign(
        escrowContract: EthereumAddress, chainId: UInt64, with signer: Secp256k1Signer
    ) throws(Secp256k1Signer.SigningError) -> Data {
        let signature = try signer.sign(
            hash: signingHash(escrowContract: escrowContract, chainId: chainId)
        )
        return signature.compact + Data([signature.recoveryID + 27])
    }

    /// Verifies that `signature` over this voucher recovers to `expectedSigner`.
    ///
    /// Accepts **only a canonical, bare 65-byte secp256k1 signature** (`r ‖ s ‖ v`).
    /// Anything else returns `false`: a keychain envelope, or a signature carrying
    /// Tempo's signature-envelope magic-bytes trailer (a transport artifact appended
    /// by local-account RPC routing). A voucher signature is canonically magic-free,
    /// and the escrow redeems only a raw `ecrecover` signature, so canonical-form is
    /// enforced here rather than defensively stripped. Stripping / envelope unwrap,
    /// when needed, belongs at the signature-envelope boundary, not in this crypto
    /// primitive. (`recover` already rejects any non-65-byte input.)
    public func verify(
        escrowContract: EthereumAddress,
        chainId: UInt64,
        signature: Data,
        expectedSigner: EthereumAddress
    ) -> Bool {
        guard let recovered = EthereumAddress.recover(
            hash: signingHash(escrowContract: escrowContract, chainId: chainId),
            signature: signature
        ) else { return false }
        return recovered == expectedSigner
    }

    // The channel id (keccak256(abi.encode(payer, payee, token, salt,
    // authorizedSigner, escrowContract, chainId))) is derived in the channel-open
    // flow (WS-10), which is where its inputs and only callers live; the voucher
    // credential takes the resulting 32-byte channelId as input.
}
