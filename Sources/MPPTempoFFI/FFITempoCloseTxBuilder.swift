import Foundation
import MPPEVM
import MPPTempo

/// The fee parameters a Tempo `0x76` transaction carries: the EIP-1559-style gas
/// price caps (as decimal `u128` strings, since `u128` exceeds Swift's `UInt64`),
/// the gas limit, and an optional TIP-20 fee token (paying gas in a token other
/// than the native asset). These come from the chain's gas/fee oracle; this slice
/// takes them as an injected value, and a later workstream sources them over RPC.
public struct TempoFeeParameters: Sendable, Hashable {
    /// The maximum total fee per gas, as a base-10 `u128` string.
    public let maxFeePerGas: String
    /// The maximum priority fee per gas, as a base-10 `u128` string.
    public let maxPriorityFeePerGas: String
    /// The gas limit.
    public let gasLimit: UInt64
    /// The TIP-20 fee token, or `nil` to pay gas in the native asset.
    public let feeToken: EthereumAddress?

    /// Creates fee parameters. `maxFeePerGas` / `maxPriorityFeePerGas` are decimal
    /// `u128` strings (validated by the FFI when the transaction is built).
    public init(
        maxFeePerGas: String,
        maxPriorityFeePerGas: String,
        gasLimit: UInt64,
        feeToken: EthereumAddress? = nil
    ) {
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.gasLimit = gasLimit
        self.feeToken = feeToken
    }
}

/// A reason the FFI close-transaction build failed.
public enum FFITempoTxError: Error, Sendable, Equatable {
    /// The configured signing key was not a valid secp256k1 private key.
    case invalidSigningKey
    /// An input was the wrong length or out of range (carries the FFI's message).
    case invalidInput(String)
    /// Signing the transaction hash failed.
    case signingFailed
    /// The sender address could not be derived from the signing key.
    case senderAddressDerivationFailed
}

/// The concrete ``TempoCloseTxBuilder`` backed by the Rust `tempo-tx-ffi` shim, which
/// binds Tempo's own `tempo-primitives` crate to build, sign, and RLP-encode the
/// bespoke `0x76` escrow `close` transaction byte-identically to the chain.
///
/// It holds the operator's signing key (it pays the gas) and the fee parameters, and
/// is injected with a `nonceProvider` that returns the account's next nonce (the
/// Swift side reads it over JSON-RPC; tests inject a stub). The seam keeps the
/// server's ``RPCChannelStateProvider`` free of the FFI dependency.
///
/// The signing key is held only for the lifetime of this value; the FFI zeroizes its
/// own copy of the key bytes on every path (see the Rust crate).
public struct FFITempoCloseTxBuilder: TempoCloseTxBuilder {
    private let signingKey: Data
    private let fee: TempoFeeParameters
    private let nonceProvider: @Sendable (EthereumAddress) async throws -> UInt64

    /// Creates the builder.
    /// - Parameters:
    ///   - signingKey: the 32-byte secp256k1 private key that signs (and pays gas for)
    ///     the settlement transaction.
    ///   - fee: the gas/fee parameters the transaction carries.
    ///   - nonceProvider: returns the next nonce for the sender address (derived from
    ///     `signingKey`); typically reads `eth_getTransactionCount(..., "pending")`.
    public init(
        signingKey: Data,
        fee: TempoFeeParameters,
        nonceProvider: @escaping @Sendable (EthereumAddress) async throws -> UInt64
    ) {
        self.signingKey = signingKey
        self.fee = fee
        self.nonceProvider = nonceProvider
    }

    /// The sender (gas-payer) address derived from the configured signing key.
    private func senderAddress() throws(FFITempoTxError) -> EthereumAddress {
        let signer: Secp256k1Signer
        do {
            signer = try Secp256k1Signer(privateKey: signingKey)
        } catch {
            throw FFITempoTxError.invalidSigningKey
        }
        guard let address = EthereumAddress(uncompressedPublicKey: signer.publicKey) else {
            throw FFITempoTxError.senderAddressDerivationFailed
        }
        return address
    }

    public func buildCloseTransaction(
        voucher: Voucher, signature: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> Data {
        let sender = try senderAddress()
        let nonce = try await nonceProvider(sender)
        do {
            // The module-level function from the UniFFI-generated bindings. Decimal
            // `u128` strings and raw byte buffers cross the FFI; it validates and
            // returns the signed EIP-2718 `0x76` bytes ready for eth_sendRawTransaction.
            return try MPPTempoFFI.buildCloseTransaction(
                chainId: chainID,
                nonce: nonce,
                maxFeePerGas: fee.maxFeePerGas,
                maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
                gasLimit: fee.gasLimit,
                feeToken: fee.feeToken?.bytes,
                privateKey: signingKey,
                escrow: escrow.bytes,
                channelId: voucher.channelID,
                cumulativeAmount: voucher.cumulativeAmount,
                voucherSignature: signature
            )
        } catch let error as FfiError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: FfiError) -> FFITempoTxError {
        switch error {
        case let .InvalidInput(message): .invalidInput(message)
        case .InvalidKey: .invalidSigningKey
        case .SigningFailed: .signingFailed
        }
    }
}
