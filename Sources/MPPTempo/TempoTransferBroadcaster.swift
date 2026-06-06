import Foundation

/// Broadcasts a signed Tempo transfer transaction and returns its hash: the push-mode half of the
/// settled charge (`draft-tempo-charge-00`), where the **client** submits the transaction and sends
/// the resulting `0x`-prefixed hash to the `402` server (the `hash` credential), rather than
/// handing
/// the server a transaction to broadcast (the `transaction`/pull credential).
///
/// A seam (like ``TempoTransferTxBuilder``) so ``TempoSettledChargeMethod`` stays free of a
/// concrete
/// transport: the live implementation (``RPCTransferBroadcaster``) submits over JSON-RPC; tests
/// inject a stub.
public protocol TempoTransferBroadcaster: Sendable {
    /// Broadcasts `rawTransaction`, waits until it is mined, and returns its `0x`-prefixed
    /// transaction hash.
    ///
    /// - Throws: if the broadcast fails or the transaction reverts (a reverted charge must not be
    ///   presented as paid).
    func broadcast(_ rawTransaction: Data) async throws -> String
}

/// The live ``TempoTransferBroadcaster`` over ``EVMRPC``'s submit-and-wait
/// (`eth_sendRawTransactionSync`): one round trip that broadcasts and blocks until the transaction
/// is mined, so the returned hash is for a transaction already on-chain (no client poll loop). A
/// reverted transaction throws rather than returning a hash for a failed charge.
public struct RPCTransferBroadcaster: TempoTransferBroadcaster {
    private let rpc: EVMRPC

    /// Creates a broadcaster over an ``EVMRPC`` client.
    public init(rpc: EVMRPC) {
        self.rpc = rpc
    }

    public func broadcast(_ rawTransaction: Data) async throws -> String {
        let receipt = try await rpc.sendRawTransactionSync(rawTransaction)
        guard receipt.succeeded else {
            throw TempoBroadcastError.reverted(receipt.transactionHash)
        }
        return receipt.transactionHash
    }
}

/// A reason a push-mode broadcast did not yield a usable charge hash.
public enum TempoBroadcastError: Error, Sendable, Hashable {
    /// The transaction was mined but reverted (its `0x`-hash is carried for diagnostics); the
    /// charge
    /// did not settle, so no `hash` credential is produced.
    case reverted(String)
}
