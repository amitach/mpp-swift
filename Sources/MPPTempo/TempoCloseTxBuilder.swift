import Foundation
import MPPEVM

/// Builds the signed Tempo `0x76` transaction that calls the escrow's `close`
/// (settle) function. This is the one channel operation the server performs that
/// *writes* a transaction, so it is the only place the server needs the bespoke
/// transaction layer; everything else (reads, relaying a client's pre-signed open
/// or top-up) is plain JSON-RPC.
///
/// It is a seam so the server's ``RPCChannelStateProvider`` stays free of the
/// transaction-builder dependency: the concrete implementation (an FFI binding to
/// `tempo-primitives`, a later workstream) holds the operator's signing key and
/// fee parameters and is injected; tests inject a stub. A blob-free server that
/// never settles on-chain itself does not need one.
public protocol TempoCloseTxBuilder: Sendable {
    /// Returns the serialized, signed `0x76` transaction that settles `voucher` on
    /// `escrow` (chain `chainID`) by calling `close(channelId, cumulativeAmount,
    /// signature)`. `signature` is the payer/authorized-signer voucher signature the
    /// escrow recovers (`ecrecover`); the returned bytes are broadcast verbatim.
    func buildCloseTransaction(
        voucher: Voucher, signature: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> Data
}
