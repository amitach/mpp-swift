import Foundation
import MPPEVM
import MPPTempo

/// A ``ChannelStateProvider`` backed by an Ethereum JSON-RPC endpoint
/// (``EVMRPC``): it reads channel state from the escrow and relays the client's
/// pre-signed open / top-up transactions, all blob-free. The one write the server
/// builds itself, the `close` settlement, is delegated to an injected
/// ``TempoCloseTxBuilder`` (the transaction-builder seam), so the Rust FFI is
/// confined to that single operation.
public struct RPCChannelStateProvider: ChannelStateProvider {
    private let rpc: EVMRPC
    private let closeTxBuilder: any TempoCloseTxBuilder
    private let maxReceiptPolls: Int
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - rpc: the JSON-RPC client (reads + broadcasts).
    ///   - closeTxBuilder: builds the signed `close` transaction for ``settle``.
    ///   - maxReceiptPolls: how many times to poll for a broadcast tx's receipt
    ///     before timing out.
    ///   - pollInterval: the delay between receipt polls.
    ///   - sleep: the delay primitive (injectable for deterministic tests).
    public init(
        rpc: EVMRPC,
        closeTxBuilder: any TempoCloseTxBuilder,
        maxReceiptPolls: Int = 60,
        pollInterval: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.rpc = rpc
        self.closeTxBuilder = closeTxBuilder
        self.maxReceiptPolls = maxReceiptPolls
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    public func channelState(
        channelID: Data, escrow: EthereumAddress, chainID _: UInt64
    ) async throws -> OnChainChannel {
        try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
    }

    public func broadcastOpen(
        serializedTransaction: Data, channelID: Data, escrow: EthereumAddress, chainID _: UInt64
    ) async throws -> (state: OnChainChannel, txHash: String) {
        try await broadcastAndRead(serializedTransaction, channelID: channelID, escrow: escrow)
    }

    public func broadcastTopUp(
        serializedTransaction: Data, channelID: Data, escrow: EthereumAddress, chainID _: UInt64
    ) async throws -> (state: OnChainChannel, txHash: String) {
        try await broadcastAndRead(serializedTransaction, channelID: channelID, escrow: escrow)
    }

    public func settle(
        channelID _: Data, voucher: Voucher, signature: Data,
        escrow: EthereumAddress, chainID: UInt64
    ) async throws -> String {
        let raw = try await closeTxBuilder.buildCloseTransaction(
            voucher: voucher, signature: signature, escrow: escrow, chainID: chainID
        )
        let txHash = try await rpc.sendRawTransaction(raw)
        // Confirm it landed (throws on revert / timeout) before reporting success.
        _ = try await awaitReceipt(txHash)
        return txHash
    }

    /// Broadcasts an already-signed transaction, waits for it to land, then reads the
    /// resulting channel state.
    private func broadcastAndRead(
        _ raw: Data, channelID: Data, escrow: EthereumAddress
    ) async throws -> (state: OnChainChannel, txHash: String) {
        let txHash = try await rpc.sendRawTransaction(raw)
        _ = try await awaitReceipt(txHash)
        let state = try await TempoEscrow.readChannel(channelID, escrow: escrow, via: rpc)
        return (state, txHash)
    }

    /// Polls for `txHash`'s receipt until it lands, throwing if it reverted or did
    /// not appear within ``maxReceiptPolls``.
    @discardableResult
    private func awaitReceipt(_ txHash: String) async throws -> TransactionReceipt {
        for attempt in 0 ..< maxReceiptPolls {
            if let receipt = try await rpc.transactionReceipt(txHash) {
                guard receipt.succeeded else { throw RPCProviderError.transactionReverted(txHash) }
                return receipt
            }
            if attempt < maxReceiptPolls - 1 { try await sleep(pollInterval) }
        }
        throw RPCProviderError.receiptTimeout(txHash)
    }
}

/// A reason an RPC-backed channel operation failed beyond the JSON-RPC layer.
public enum RPCProviderError: Error, Sendable, Hashable {
    /// The broadcast transaction landed but its on-chain status was a revert (`0x0`).
    case transactionReverted(String)
    /// No receipt appeared within the poll budget.
    case receiptTimeout(String)
}
