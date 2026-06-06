import Foundation
import MPPEVM
import MPPTempo

/// Builds the signed Tempo `0x76` settled-charge transaction (one `transferWithMemo`, signed
/// directly by the payer) via the Rust `tempo-tx-ffi` shim, so the transfer is byte-identical to
/// the chain's canonical encoding.
///
/// The concrete ``TempoTransferTxBuilder`` for the non-zero charge client. It holds the shared
/// infrastructure (the fee parameters and a `nonceProvider` that returns the payer's next nonce),
/// while the per-charge inputs (the payer key, currency, recipient, amount, memo) arrive in
/// ``TempoTransferParameters``. The payer's private-key bytes cross the FFI, which zeroizes its own
/// copy on every path (see the Rust crate).
public struct FFITransferTxBuilder: TempoTransferTxBuilder {
    private let fee: TempoFeeParameters
    private let nonceProvider: @Sendable (EthereumAddress) async throws -> UInt64

    /// Creates the builder.
    /// - Parameters:
    ///   - fee: the gas/fee parameters the transfer transaction carries.
    ///   - nonceProvider: returns the next nonce for the payer account the transfer executes for
    ///     (handed `parameters.payer`); typically reads `eth_getTransactionCount(..., "pending")`.
    public init(
        fee: TempoFeeParameters,
        nonceProvider: @escaping @Sendable (EthereumAddress) async throws -> UInt64
    ) {
        self.fee = fee
        self.nonceProvider = nonceProvider
    }

    public func buildTransferTransaction(
        _ parameters: TempoTransferParameters,
        chainID: UInt64
    ) async throws -> Data {
        let nonce = try await nonceProvider(parameters.payer)
        do {
            return try MPPTempoFFI.buildTransferTransaction(
                chainId: chainID,
                nonce: nonce,
                maxFeePerGas: fee.maxFeePerGas,
                maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
                gasLimit: fee.gasLimit,
                feeToken: fee.feeToken?.bytes,
                privateKey: parameters.payerPrivateKey,
                currency: parameters.currency.bytes,
                recipient: parameters.recipient.bytes,
                amount: parameters.amount,
                memo: parameters.memo
            )
        } catch let error as FfiError {
            throw FFITempoTxBuilder.map(error)
        }
    }
}
