import Foundation

/// Derivation of the on-chain identifier for a Tempo payment channel.
///
/// The id binds every parameter that defines a channel, so a voucher signed for
/// one channel can never be redeemed against another. It is the escrow contract's
/// `computeChannelId`:
///
/// ```
/// channelId = keccak256(abi.encode(
///     address payer, address payee, address token, bytes32 salt,
///     address authorizedSigner, address escrowContract, uint256 chainId))
/// ```
///
/// All seven are static ABI types, so the encoding is the concatenation of seven
/// 32-byte words in that order (each address left-padded to a word, `salt` as a
/// `bytes32`, `chainId` as a `uint256`), hashed with keccak256. A ``Voucher`` is
/// then bound to the resulting 32-byte id (``Voucher/channelID``).
public enum Channel {
    /// The parameters that define a payment channel, and therefore its id.
    public struct Parameters: Sendable, Hashable {
        /// The address funding the channel.
        public let payer: EthereumAddress
        /// The recipient address.
        public let payee: EthereumAddress
        /// The payment token address.
        public let token: EthereumAddress
        /// A 32-byte value distinguishing channels that share every other parameter.
        public let salt: Data
        /// The address authorized to sign vouchers for the payer.
        public let authorizedSigner: EthereumAddress
        /// The escrow contract that holds the channel.
        public let escrowContract: EthereumAddress
        /// The chain the escrow is deployed on (ABI-encoded as a `uint256`).
        public let chainId: UInt64

        /// Creates channel parameters, or `nil` if `salt` is not exactly 32 bytes
        /// (a `bytes32`). Validating here makes an invalid-salt value
        /// unrepresentable, so ``Channel/id(_:)`` is total.
        public init?(
            payer: EthereumAddress,
            payee: EthereumAddress,
            token: EthereumAddress,
            salt: Data,
            authorizedSigner: EthereumAddress,
            escrowContract: EthereumAddress,
            chainId: UInt64
        ) {
            guard salt.count == 32 else { return nil }
            self.payer = payer
            self.payee = payee
            self.token = token
            self.salt = salt
            self.authorizedSigner = authorizedSigner
            self.escrowContract = escrowContract
            self.chainId = chainId
        }
    }

    /// Computes the 32-byte channel id from `parameters`. Total: ``Parameters``
    /// guarantees a `bytes32` salt at construction.
    public static func id(_ parameters: Parameters) -> Data {
        let encoded = parameters.payer.word
            + parameters.payee.word
            + parameters.token.word
            + parameters.salt
            + parameters.authorizedSigner.word
            + parameters.escrowContract.word
            + EIP712.uint256(parameters.chainId)
        return Keccak256.hash(encoded)
    }
}
