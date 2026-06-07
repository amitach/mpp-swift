import Foundation
import MPPCore

/// The x402 charge parameters decoded from an MPP challenge's `request`, for this SDK's x402 rail:
/// an MPP server advertises an x402/USDC charge as an ordinary `x402`/`charge` challenge, and this
/// reads the fields the client needs to build the EIP-3009 authorization.
///
/// Top-level `amount` / `recipient` / `currency` follow the MPP convention (so a
/// ``PaymentAuthorizer`` reads them uniformly across rails), and `methodDetails` carries the
/// x402-specific bits: the `chainId`, the token's EIP-712 domain `name` / `version` (which x402's
/// exact scheme advertises in `extra`, and which the payer must sign over verbatim), and the
/// `maxTimeoutSeconds` validity window. Unknown fields are ignored.
public struct X402ChargeRequest: Sendable, Hashable {
    /// The charge amount in the token's base units.
    public let amount: Amount
    /// The payee address (x402 `payTo`), if present.
    public let recipient: String?
    /// The token/asset contract address (x402 `asset`), if present.
    public let currency: String?
    /// The chain the token lives on, from `methodDetails.chainId`, if present.
    public let chainId: UInt64?
    /// The token's EIP-712 domain `name`, from `methodDetails.name`, if present.
    public let tokenName: String?
    /// The token's EIP-712 domain `version`, from `methodDetails.version`, if present.
    public let tokenVersion: String?
    /// The authorization validity window in seconds, from `methodDetails.maxTimeoutSeconds`.
    public let maxTimeoutSeconds: UInt64?

    /// Decodes the charge parameters from `challenge`'s `request`.
    ///
    /// - Throws: ``DecodingFailure`` if the `request` is not base64url, not a JSON object of the
    ///   expected shape, or carries a non-canonical `amount`.
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
        recipient = wire.recipient
        currency = wire.currency
        chainId = wire.methodDetails?.chainId
        tokenName = wire.methodDetails?.name
        tokenVersion = wire.methodDetails?.version
        maxTimeoutSeconds = wire.methodDetails?.maxTimeoutSeconds
    }

    /// A reason a charge `request` could not be decoded.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// The `request` value was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a charge-request JSON object. `reason` carries the underlying
        /// coding error's description for diagnostics.
        case invalidJSON(reason: String)
        /// The `amount` was not a canonical base-units integer string.
        case invalidAmount(Amount.ValidationError)
    }
}

/// The decodable mirror of the on-wire x402 charge request. `amount` is decoded as a string and
/// validated into `Amount` (never a number); `chainId` / `maxTimeoutSeconds` are JSON integers
/// decoded as `UInt64` so a negative or fractional value fails closed. Unknown fields are ignored.
private struct ChargeRequestWire: Decodable {
    let amount: String
    let recipient: String?
    let currency: String?
    let methodDetails: MethodDetails?
}

/// The `methodDetails` sub-object: the chain id, the token's EIP-712 domain `name` / `version`, and
/// the `maxTimeoutSeconds` validity window.
private struct MethodDetails: Decodable {
    let chainId: UInt64?
    let name: String?
    let version: String?
    let maxTimeoutSeconds: UInt64?
}
