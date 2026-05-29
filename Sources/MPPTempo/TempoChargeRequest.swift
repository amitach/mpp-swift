import Foundation
import MPPCore

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
        let data: Data
        do {
            data = try challenge.request.decodedData()
        } catch {
            throw .notBase64URL(error)
        }
        let wire: ChargeRequestWire
        do {
            wire = try JSONDecoder().decode(ChargeRequestWire.self, from: data)
        } catch {
            throw .invalidJSON(reason: String(describing: error))
        }
        do {
            amount = try Amount(wire.amount)
        } catch {
            throw .invalidAmount(error)
        }
        chainId = wire.methodDetails?.chainId
        recipient = wire.recipient
        currency = wire.currency
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
    let methodDetails: MethodDetails?
}

/// The `methodDetails` sub-object; only `chainId` is read by the proof path.
private struct MethodDetails: Decodable {
    let chainId: UInt64?
}
