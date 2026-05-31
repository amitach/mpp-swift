import Foundation
import MPPEVM

/// Builds the signed Tempo `0x76` transaction that tops up an open channel (a two-call
/// `approve` + escrow `topUp`). A client that adds deposit to a channel it already opened
/// (``TempoChannelMethod/buildTopUp(for:additionalDeposit:)``) needs it.
///
/// A seam (sibling of ``TempoOpenTxBuilder`` / ``TempoCloseTxBuilder``) so the client method
/// stays free of the transaction-builder dependency: the concrete implementation (the FFI
/// binding to `tempo-primitives`) holds the payer's signing key + fee parameters and is
/// injected; tests inject a stub. A client that never tops up does not need one.
public protocol TempoTopUpTxBuilder: Sendable {
    /// Returns the serialized, signed `0x76` transaction that tops up `channelID` by
    /// `additionalDeposit` (a decimal `u256` string, NOT `u128` - the escrow's `topUp`
    /// argument is `uint256`): a two-call `approve(escrow, additionalDeposit)` on `token`
    /// then `topUp(channelID, additionalDeposit)` on `escrow`. The returned bytes are
    /// broadcast verbatim (by the payer directly, or by a 402 server relaying the payload).
    func buildTopUpTransaction(
        escrow: EthereumAddress,
        token: EthereumAddress,
        channelID: Data,
        additionalDeposit: String,
        chainID: UInt64
    ) async throws -> Data
}
