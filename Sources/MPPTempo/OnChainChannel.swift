import Foundation
import MPPEVM

/// A snapshot of a payment channel's on-chain state, read from the escrow contract.
///
/// Lives in MPPTempo (the shared rail) so both the client/wallet and the server can
/// read channel state blob-free: a voucher's cumulative amount must sit above what is
/// already `settled` on-chain and within the `deposit`, and its signature must
/// recover to the channel's `authorizedSigner` (or the `payer`, when no separate
/// signer was set). `finalized` / `closeRequestedAt` mark a channel that can no
/// longer be drawn.
public struct OnChainChannel: Sendable, Hashable {
    public let payer: EthereumAddress
    public let payee: EthereumAddress
    public let token: EthereumAddress
    /// The address authorized to sign vouchers; the zero address means none was
    /// set, and the `payer` signs (see ``effectiveAuthorizedSigner``).
    public let authorizedSigner: EthereumAddress
    /// The amount funded into the channel on-chain.
    public let deposit: ChannelAmount
    /// The amount already settled (withdrawn) on-chain.
    public let settled: ChannelAmount
    /// The channel has been finalized (closed) on-chain.
    public let finalized: Bool
    /// The block timestamp of a pending close request, or `0` if none.
    public let closeRequestedAt: UInt64

    public init(
        payer: EthereumAddress,
        payee: EthereumAddress,
        token: EthereumAddress,
        authorizedSigner: EthereumAddress,
        deposit: ChannelAmount,
        settled: ChannelAmount,
        finalized: Bool,
        closeRequestedAt: UInt64
    ) {
        self.payer = payer
        self.payee = payee
        self.token = token
        self.authorizedSigner = authorizedSigner
        self.deposit = deposit
        self.settled = settled
        self.finalized = finalized
        self.closeRequestedAt = closeRequestedAt
    }

    /// The address whose signature authorizes vouchers: the `authorizedSigner`, or
    /// the `payer` when no separate signer was set (the zero address).
    public var effectiveAuthorizedSigner: EthereumAddress {
        authorizedSigner.bytes.allSatisfy { $0 == 0 } ? payer : authorizedSigner
    }
}
