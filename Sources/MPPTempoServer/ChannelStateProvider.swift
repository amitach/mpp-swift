import Foundation
import MPPEVM

/// A snapshot of a payment channel's on-chain state, read from the escrow contract.
///
/// The session method reads this to verify a voucher against the channel's actual
/// funding and signer: the voucher's cumulative amount must sit above what is
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

/// The on-chain seam for the Tempo session method: reads channel state from the
/// escrow and broadcasts the channel-lifecycle transactions (open, top-up, settle).
///
/// Like the reference SDKs (mppx injects a viem client, mpp-rs an alloy provider),
/// the SDK ships the session orchestration and the operator injects the provider;
/// a concrete Ethereum-RPC implementation is a separate workstream. Tests inject a
/// stub. This keeps the session method free of any RPC dependency.
public protocol ChannelStateProvider: Sendable {
    /// Reads the current on-chain state of `channelID` from `escrow` on `chainID`.
    func channelState(
        channelID: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> OnChainChannel

    /// Broadcasts the client's signed channel-open transaction and returns the
    /// resulting on-chain state and the transaction hash.
    func broadcastOpen(
        serializedTransaction: Data, channelID: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> (state: OnChainChannel, txHash: String)

    /// Broadcasts the client's signed top-up transaction (additional deposit) and
    /// returns the resulting on-chain state and the transaction hash.
    func broadcastTopUp(
        serializedTransaction: Data, channelID: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> (state: OnChainChannel, txHash: String)

    /// Settles `voucher` (the highest accepted) on-chain to close the channel,
    /// returning the settlement transaction hash.
    func settle(
        channelID: Data, voucher: Voucher, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> String
}
