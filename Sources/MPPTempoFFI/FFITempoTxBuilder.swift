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

/// The escrow `open` inputs (besides the held key/fee/nonce and the chain id): the
/// escrow and TIP-20 token addresses, the channel payee, the initial `deposit` (decimal
/// `u128` string), the channel `salt` (32 bytes), and the `authorizedSigner` that will
/// sign vouchers. Grouped into a value so the builder method stays legible.
public struct TempoOpenParameters: Sendable, Hashable {
    /// The escrow contract address.
    public let escrow: EthereumAddress
    /// The TIP-20 token the channel is denominated in (also `approve`d to the escrow).
    public let token: EthereumAddress
    /// The channel payee.
    public let payee: EthereumAddress
    /// The initial deposit, as a base-10 `u128` string.
    public let deposit: String
    /// The 32-byte channel salt.
    public let salt: Data
    /// The address authorized to sign vouchers for the channel.
    public let authorizedSigner: EthereumAddress

    /// Creates the open inputs.
    public init(
        escrow: EthereumAddress,
        token: EthereumAddress,
        payee: EthereumAddress,
        deposit: String,
        salt: Data,
        authorizedSigner: EthereumAddress
    ) {
        self.escrow = escrow
        self.token = token
        self.payee = payee
        self.deposit = deposit
        self.salt = salt
        self.authorizedSigner = authorizedSigner
    }
}

/// A reason the FFI transaction build failed.
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

/// Builds the signed Tempo `0x76` escrow transactions for one account, backed by the
/// Rust `tempo-tx-ffi` shim (which binds Tempo's own `tempo-primitives` so the output
/// is byte-identical to the chain). Covers the channel bookends a wallet performs:
/// `open` and `topUp` (each a two-call `approve` + escrow-call transaction) and
/// `close` (settlement). It conforms to ``TempoCloseTxBuilder`` so the server's
/// ``RPCChannelStateProvider`` can inject it for settle without taking on the FFI
/// dependency directly.
///
/// It holds the account's signing key (which pays the gas) and the fee parameters, and
/// is injected with a `nonceProvider` returning the account's next nonce (the Swift
/// side reads it over JSON-RPC; tests inject a stub). The signing key is held only for
/// the lifetime of this value; the FFI zeroizes its own copy of the key bytes on every
/// path (see the Rust crate).
public struct FFITempoTxBuilder: TempoCloseTxBuilder {
    private let signingKey: Data
    private let fee: TempoFeeParameters
    private let nonceProvider: @Sendable (EthereumAddress) async throws -> UInt64

    /// Creates the builder.
    /// - Parameters:
    ///   - signingKey: the 32-byte secp256k1 private key that signs (and pays gas for)
    ///     the transactions.
    ///   - fee: the gas/fee parameters the transactions carry.
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

    /// Reads the next nonce for the sender derived from the signing key.
    private func nextNonce() async throws -> UInt64 {
        let sender = try senderAddress()
        return try await nonceProvider(sender)
    }

    /// Builds the signed `0x76` transaction that opens a channel: a two-call `approve`
    /// (the escrow pulls `deposit` of `token`) then `escrow.open(payee, token, deposit,
    /// salt, authorizedSigner)`. Returns the raw bytes to broadcast.
    public func buildOpenTransaction(
        _ parameters: TempoOpenParameters,
        chainID: UInt64
    ) async throws -> Data {
        let nonce = try await nextNonce()
        do {
            return try MPPTempoFFI.buildOpenTransaction(
                chainId: chainID,
                nonce: nonce,
                maxFeePerGas: fee.maxFeePerGas,
                maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
                gasLimit: fee.gasLimit,
                feeToken: fee.feeToken?.bytes,
                privateKey: signingKey,
                escrow: parameters.escrow.bytes,
                token: parameters.token.bytes,
                payee: parameters.payee.bytes,
                deposit: parameters.deposit,
                salt: parameters.salt,
                authorizedSigner: parameters.authorizedSigner.bytes
            )
        } catch let error as FfiError {
            throw Self.map(error)
        }
    }

    /// Builds the signed `0x76` transaction that tops up a channel: a two-call `approve`
    /// (the escrow pulls `additionalDeposit` of `token`) then `escrow.topUp(channelID,
    /// additionalDeposit)`. `additionalDeposit` is a decimal `u256` string.
    public func buildTopUpTransaction(
        escrow: EthereumAddress,
        token: EthereumAddress,
        channelID: Data,
        additionalDeposit: String,
        chainID: UInt64
    ) async throws -> Data {
        let nonce = try await nextNonce()
        do {
            return try MPPTempoFFI.buildTopUpTransaction(
                chainId: chainID,
                nonce: nonce,
                maxFeePerGas: fee.maxFeePerGas,
                maxPriorityFeePerGas: fee.maxPriorityFeePerGas,
                gasLimit: fee.gasLimit,
                feeToken: fee.feeToken?.bytes,
                privateKey: signingKey,
                escrow: escrow.bytes,
                token: token.bytes,
                channelId: channelID,
                additionalDeposit: additionalDeposit
            )
        } catch let error as FfiError {
            throw Self.map(error)
        }
    }

    public func buildCloseTransaction(
        voucher: Voucher, signature: Data, escrow: EthereumAddress, chainID: UInt64
    ) async throws -> Data {
        let nonce = try await nextNonce()
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
