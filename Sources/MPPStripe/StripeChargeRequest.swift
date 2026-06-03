import Foundation
import MPPCore

/// The Stripe charge parameters decoded from a challenge's `request`.
///
/// The challenge `request` is the post-mint wire shape: the charge `amount` is already in the
/// currency's smallest unit (a canonical base-units decimal string, never re-scaled by a client
/// `decimals`), alongside the `currency`, optional `description`/`recipient`, and a
/// `methodDetails` object carrying the Stripe Business Network `networkId`, the non-empty
/// `paymentMethodTypes`, and optional `metadata`. `paymentMethodTypes` describes the charge but is
/// not sent to the PaymentIntent (the server uses Stripe automatic payment methods). The wire's
/// optional `externalId` is the server's own reference and has no client-side consumer, so it is
/// not decoded (the credential's `externalId` is a separate, client-set value). Unknown fields are
/// ignored.
public struct StripeChargeRequest: Sendable, Hashable {
    /// The charge amount in the currency's smallest unit (already base units, no `decimals`).
    public let amount: Amount
    /// The three-letter ISO currency code (e.g. `"usd"`).
    public let currency: String
    /// An optional human-readable description for the charge.
    public let description: String?
    /// An optional recipient identifier (display/routing), surfaced to the token provider.
    public let recipient: String?
    /// The Stripe Business Network profile id the charge settles under.
    public let networkId: String
    /// The payment method types the charge accepts (at least one). Carried for the token provider
    /// and the challenge metadata; NOT sent to the PaymentIntent create call.
    public let paymentMethodTypes: [String]
    /// Optional server-supplied metadata to attach to the PaymentIntent.
    public let metadata: [String: String]?

    /// Decodes the charge parameters from `challenge`'s `request`.
    ///
    /// - Throws: ``DecodingFailure`` if the `request` is not base64url, not a JSON object of the
    ///   expected shape, carries a non-canonical `amount`, or has an empty `paymentMethodTypes`.
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
        guard !wire.methodDetails.paymentMethodTypes.isEmpty else {
            throw .emptyPaymentMethodTypes
        }
        currency = wire.currency
        description = wire.description
        recipient = wire.recipient
        networkId = wire.methodDetails.networkId
        paymentMethodTypes = wire.methodDetails.paymentMethodTypes
        metadata = wire.methodDetails.metadata
    }

    /// A reason a charge `request` could not be decoded.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// The `request` value was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a charge-request JSON object (a required field such as
        /// `currency`, `methodDetails`, or `networkId` was absent or the wrong type). `reason`
        /// carries the underlying coding error's description for diagnostics.
        case invalidJSON(reason: String)
        /// The `amount` was not a canonical base-units integer string.
        case invalidAmount(Amount.ValidationError)
        /// `methodDetails.paymentMethodTypes` was present but empty.
        case emptyPaymentMethodTypes
    }
}

/// The decodable mirror of the on-wire charge request. `amount` is decoded as a string and
/// validated into `Amount` (never a number, so no float can reach the amount path). `currency`
/// and `methodDetails` are required; unknown fields are ignored.
private struct ChargeRequestWire: Decodable {
    let amount: String
    let currency: String
    let description: String?
    let recipient: String?
    let methodDetails: MethodDetailsWire
}

/// The `methodDetails` sub-object: the required `networkId` and `paymentMethodTypes`, plus
/// optional `metadata`.
private struct MethodDetailsWire: Decodable {
    let networkId: String
    let paymentMethodTypes: [String]
    let metadata: [String: String]?
}
