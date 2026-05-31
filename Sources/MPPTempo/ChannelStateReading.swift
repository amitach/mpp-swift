import Foundation
import MPPEVM

/// A read-only seam for attaching to an existing on-chain channel: given a channel id, it
/// returns the channel's current escrow state. ``TempoChannelMethod`` uses it (optionally)
/// to recover a server-suggested channel instead of opening a fresh one. Kept separate from
/// the server's `ChannelStateProvider` (which also relays/settles) so a client takes only the
/// read dependency; a client that never recovers injects none.
public protocol ChannelStateReading: Sendable {
    /// Reads the on-chain state of `channelID` from `escrow` on `chainID`. Throws on an RPC
    /// failure (the caller treats a throw as "not recoverable").
    func onChainChannel(
        channelID: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> OnChainChannel
}

/// An ``EVMRPC``-backed ``ChannelStateReading``: reads the channel from the escrow via
/// `eth_call` (the same read the server uses). The only dependency a recovering client needs.
public struct EVMChannelReader: ChannelStateReading {
    private let rpc: EVMRPC

    public init(rpc: EVMRPC) {
        self.rpc = rpc
    }

    public func onChainChannel(
        channelID: Data, escrow: EthereumAddress, chainID _: UInt64
    ) async throws -> OnChainChannel {
        try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
    }
}
