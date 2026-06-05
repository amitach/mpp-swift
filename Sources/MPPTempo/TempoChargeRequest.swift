import Foundation
import MPPCore
import MPPEVM

/// The Tempo charge parameters decoded from a challenge's `request`, limited to
/// the subset the zero-amount proof path needs plus the fields surfaced for
/// pre-sign approval.
///
/// Per `draft-tempo-charge-00`, the challenge `request` is base64url(JCS(json))
/// carrying the charge `amount` (decimal base units), the `recipient` and
/// `currency` for a settled transfer, and a `methodDetails` object whose
/// `chainId` names the chain the proof is bound to. The request carries no
/// settlement `type`: the proof path is taken when ``isZeroAmount`` holds
/// (`amount == 0`), and any non-zero amount is a settled transfer handled by the
/// on-chain transaction layer (a later PR). Unknown fields are ignored.
public struct TempoChargeRequest: Sendable, Hashable {
    /// The charge amount in base units. `"0"` for a zero-amount proof.
    public let amount: Amount
    /// The chain the proof is bound to, from `methodDetails.chainId`, if present.
    public let chainId: UInt64?
    /// The payee address for a settled transfer, surfaced for approval display.
    public let recipient: String?
    /// The token/currency address for a settled transfer, surfaced for approval.
    public let currency: String?
    /// The escrow contract holding the channel, from `methodDetails.escrowContract`
    /// (present for a session challenge; absent for a plain charge).
    public let escrowContract: String?
    /// The deposit the server suggests for a newly opened channel, from the top-level
    /// `suggestedDeposit` request field (a sibling of `amount`, a decimal base-units string),
    /// if present. A client's deposit policy may use it as one input; never the charge amount.
    public let suggestedDeposit: String?
    /// A channel the server suggests reusing, from `methodDetails.channelId` (a 32-byte
    /// `0x`-hex id), if present and well-formed. A client may attach to it on-chain rather
    /// than opening a fresh channel.
    public let suggestedChannelID: Data?
    /// The minimum increment between successive vouchers the server requires for this
    /// challenge, from `methodDetails.minVoucherDelta` (a decimal base-units string), if set.
    /// Overrides the channel session verifier's static default; a voucher whose delta over the
    /// highest accepted falls below it is rejected (the spec's anti-griefing minimum).
    public let minVoucherDelta: String?

    /// Whether this is a zero-amount charge (the EIP-712 proof path).
    ///
    /// `Amount`'s canonical form has no leading zeros, so zero is exactly `"0"`.
    public var isZeroAmount: Bool {
        amount.rawValue == "0"
    }

    /// Decodes the charge parameters from `challenge`'s `request`.
    ///
    /// - Throws: ``DecodingFailure`` if the `request` is not base64url, not a
    ///   JSON object of the expected shape, or carries a non-canonical `amount`.
    public init(challenge: Challenge) throws(DecodingFailure) {
        let wire: ChargeRequestWire
        do {
            wire = try challenge.request.decode(as: ChargeRequestWire.self)
        } catch {
            switch error {
            case let .notBase64URL(cause): throw .notBase64URL(cause)
            case let .invalidJSON(reason): throw .invalidJSON(reason: reason)
            }
        }
        do {
            amount = try Amount(wire.amount)
        } catch {
            throw .invalidAmount(error)
        }
        chainId = wire.methodDetails?.chainId
        recipient = wire.recipient
        currency = wire.currency
        escrowContract = wire.methodDetails?.escrowContract
        suggestedDeposit = wire.suggestedDeposit
        suggestedChannelID = wire.methodDetails?.channelId.flatMap(Data.init(hexPrefixed:))
        minVoucherDelta = wire.methodDetails?.minVoucherDelta
    }

    /// Whether `challenge` is a `tempo`/`charge` challenge carrying a decodable zero-amount
    /// request (the proof path).
    ///
    /// The proof rail's applicability contract, shared by the client method and the server
    /// verifier so the two cannot disagree. The chain is always resolvable (challenge `chainId`
    /// or the configured default), so it is not a support condition; a non-zero amount is a
    /// settled transfer handled elsewhere.
    public static func supportsZeroAmountProof(_ challenge: Challenge) -> Bool {
        challenge.method == TempoMethod.name && challenge.intent == .charge
            && (try? TempoChargeRequest(challenge: challenge))?.isZeroAmount == true
    }

    /// A reason a charge `request` could not be decoded.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// The `request` value was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a charge-request JSON object. `reason`
        /// carries the underlying coding error's description for diagnostics.
        case invalidJSON(reason: String)
        /// The `amount` was not a canonical base-units integer string.
        case invalidAmount(Amount.ValidationError)
    }
}

/// The decodable mirror of the on-wire charge request. `amount` is decoded as a
/// string and validated into `Amount` (never a number, so no float can reach the
/// amount path); `chainId` is a JSON integer, decoded as `UInt64` so a negative
/// or fractional value fails closed. Unknown fields are ignored.
private struct ChargeRequestWire: Decodable {
    let amount: String
    let recipient: String?
    let currency: String?
    // `suggestedDeposit` is a top-level request field (a sibling of `amount`), not a
    // `methodDetails` member, matching the reference session challenge wire.
    let suggestedDeposit: String?
    let methodDetails: MethodDetails?
}

/// The `methodDetails` sub-object: `chainId` (proof + session), the session's
/// `escrowContract`, an optional `channelId` the server suggests reusing, and the
/// optional per-challenge `minVoucherDelta` (a decimal base-units string).
private struct MethodDetails: Decodable {
    let chainId: UInt64?
    let escrowContract: String?
    let channelId: String?
    let minVoucherDelta: String?
}
