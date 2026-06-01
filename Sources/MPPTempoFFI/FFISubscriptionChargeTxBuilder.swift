import Foundation
import MPPEVM
import MPPTempo

/// Builds the signed Tempo `0x76` subscription-charge transaction (one
/// `transferWithMemo`) via the Rust `tempo-tx-ffi` shim, so the recurring charge is
/// byte-identical to the chain's canonical encoding.
///
/// Unlike ``FFITempoTxBuilder`` (which holds one channel-payer key), the signing key here
/// is the *access key*, which differs per subscription and arrives per charge in
/// ``TempoSubscriptionChargeParameters``. So this builder holds only the shared
/// infrastructure: the fee parameters and a `nonceProvider` that returns the next nonce for
/// the **payer (root) account** the charge executes for (the access key only produces the
/// keychain signature). The access key's private-key bytes cross the FFI, which zeroizes its
/// own copy on every path (see the Rust crate).
public struct FFISubscriptionChargeTxBuilder: TempoSubscriptionChargeTxBuilder {
    private let fee: TempoFeeParameters
    private let nonceProvider: @Sendable (EthereumAddress) async throws -> UInt64

    /// Creates the builder.
    /// - Parameters:
    ///   - fee: the gas/fee parameters the charge transaction carries.
    ///   - nonceProvider: returns the next nonce for the payer (root) account the charge
    ///     executes for (handed `parameters.payer`); typically reads
    ///     `eth_getTransactionCount(..., "pending")`.
    public init(
        fee: TempoFeeParameters,
        nonceProvider: @escaping @Sendable (EthereumAddress) async throws -> UInt64
    ) {
        self.fee = fee
        self.nonceProvider = nonceProvider
    }

    public func buildSubscriptionChargeTransaction(
        _ parameters: TempoSubscriptionChargeParameters,
        chainID: UInt64
    ) async throws -> Data {
        // The charge executes for the payer (root) account, so its nonce is the payer's, not the
        // access key's (the access key only signs the keychain signature).
        let nonce = try await nonceProvider(parameters.payer)
        do {
            return try MPPTempoFFI.buildSubscriptionChargeTransaction(
                chainId: chainID,
                nonce: nonce,
                maxFeePerGas: fee.maxFeePerGas,
                maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
                gasLimit: fee.gasLimit,
                feeToken: fee.feeToken?.bytes,
                privateKey: parameters.accessKeyPrivateKey,
                rootAddress: parameters.payer.bytes,
                currency: parameters.currency.bytes,
                recipient: parameters.recipient.bytes,
                amount: parameters.amount,
                memo: parameters.memo,
                keyAuthorization: parameters.keyAuthorization
            )
        } catch let error as FfiError {
            throw FFITempoTxBuilder.map(error)
        }
    }
}
