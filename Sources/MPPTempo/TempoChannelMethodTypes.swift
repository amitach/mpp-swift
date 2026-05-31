import Foundation
import MPPCore
import MPPEVM

/// The facts a ``TempoChannelMethod`` deposit policy decides a new channel's deposit
/// from: the channel's payee/token/escrow and chain, the per-request charge `amount`,
/// and the server's optional `suggestedDeposit`. The deposit the policy returns is the
/// channel deposit, never the charge amount.
public struct DepositContext: Sendable, Hashable {
    /// The channel payee.
    public let payee: EthereumAddress
    /// The channel token (currency).
    public let token: EthereumAddress
    /// The escrow contract.
    public let escrow: EthereumAddress
    /// The chain id the channel is on.
    public let chainId: UInt64
    /// The per-request charge amount (for sizing the deposit, not the deposit itself).
    public let chargeAmount: Amount
    /// The server-suggested deposit (the top-level `suggestedDeposit` request field), if any.
    public let suggestedDeposit: String?

    /// Creates the deposit facts. Public (like ``ChargeApproval``) so a consumer can
    /// construct one to unit-test its deposit policy in isolation.
    public init(
        payee: EthereumAddress,
        token: EthereumAddress,
        escrow: EthereumAddress,
        chainId: UInt64,
        chargeAmount: Amount,
        suggestedDeposit: String?
    ) {
        self.payee = payee
        self.token = token
        self.escrow = escrow
        self.chainId = chainId
        self.chargeAmount = chargeAmount
        self.suggestedDeposit = suggestedDeposit
    }
}

/// A reason ``TempoChannelMethod`` could not build (or manage) a channel credential.
public enum TempoChannelMethodError: Error, Sendable, Hashable {
    /// The challenge is not a Tempo session (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(TempoChargeRequest.DecodingFailure)
    /// The request is not a session: it lacks a valid escrow, recipient, or currency.
    case notASession
    /// The charge amount does not fit a channel `uint128`.
    case amountExceedsChannelRange
    /// The deposit policy returned no deposit for a new channel.
    case noDeposit
    /// The deposit policy returned a value that is not a canonical `uint128`.
    case invalidDeposit
    /// A topUp/close was requested but no channel is open for the key.
    case noOpenChannel
    /// A topUp was requested but no top-up transaction builder was configured.
    case topUpUnsupported
    /// Building the signed topUp transaction failed (carries the builder error's text).
    case topUpTransactionFailed(String)
    /// The channel salt was not 32 bytes.
    case invalidSalt
    /// Adding the charge to the running cumulative would overflow `uint128`.
    case cumulativeOverflow
    /// The pre-sign approval policy rejected the charge.
    case approvalDenied
    /// The voucher could not be signed.
    case signingFailed(Secp256k1Signer.SigningError)
    /// Building the signed open transaction failed (carries the builder error's text).
    case openTransactionFailed(String)
}
