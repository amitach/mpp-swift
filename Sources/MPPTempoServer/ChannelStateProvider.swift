import Foundation
import MPPEVM
import MPPTempo

// `OnChainChannel` and `ChannelAmount` live in MPPTempo (the shared rail) so the
// client/wallet can read channel state without depending on the server module.

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

    /// Settles `voucher` on-chain to close the channel, returning the settlement
    /// transaction hash. `signature` is the 65-byte payer/authorized-signer
    /// signature over `voucher` that the escrow recovers (`ecrecover`); the caller
    /// passes the higher of the client's final voucher and the server's stored
    /// highest accepted voucher, so a close can never settle below what was drawn.
    func settle(
        channelID: Data, voucher: Voucher, signature: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> String
}
