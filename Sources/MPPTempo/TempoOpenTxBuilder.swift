import Foundation
import MPPEVM

/// The escrow `open` inputs (besides the held key/fee/nonce and the chain id): the
/// escrow and TIP-20 token addresses, the channel payee, the initial `deposit` (decimal
/// `u128` string), the channel `salt` (32 bytes), and the `authorizedSigner` that will
/// sign vouchers. Grouped into a value so the builder method stays legible.
///
/// Declared here (not in the FFI target) so the seam below and its client callers can
/// name the inputs without depending on the `0x76` transaction layer; the concrete
/// FFI builder reuses this type verbatim.
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

/// Builds the signed Tempo `0x76` transaction that opens a channel (a two-call `approve`
/// + escrow `open`). This is the one channel-open write a *payer* performs, so a client
/// that auto-opens channels (``TempoChannelMethod``) needs it; everything else the client
/// does is off-chain voucher signing.
///
/// It is a seam (mirroring ``TempoCloseTxBuilder``) so the client method stays free of the
/// transaction-builder dependency: the concrete implementation (the FFI binding to
/// `tempo-primitives`) holds the payer's signing key and fee parameters and is injected;
/// tests inject a stub. A consumer that never opens a channel itself does not need one.
public protocol TempoOpenTxBuilder: Sendable {
    /// Returns the serialized, signed `0x76` transaction that opens the channel described
    /// by `parameters` on chain `chainID`: a two-call `approve(escrow, deposit)` on the
    /// token then `open(payee, token, deposit, salt, authorizedSigner)` on the escrow. The
    /// returned bytes are broadcast verbatim (by the payer directly, or by a 402 server
    /// relaying the client's payload).
    func buildOpenTransaction(
        _ parameters: TempoOpenParameters, chainID: UInt64
    ) async throws -> Data
}
