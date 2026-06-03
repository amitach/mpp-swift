import Foundation
import MPPCore
import MPPEVM

/// The Tempo subscription parameters decoded from a `tempo`/`subscription` challenge's `request`.
///
/// The challenge `request` is base64url(JCS(json)) carrying the recurring charge `amount` (decimal
/// base units), the `currency` and `recipient` of the recurring `transferWithMemo`, the billing
/// period (`periodCount` x `periodUnit`), the `subscriptionExpires` instant, and a `methodDetails`
/// object whose `accessKey` (the server-held key the authorization delegates to) and `chainId` bind
/// the key authorization. The client signs a ``TempoKeyAuthorization`` over these; the server
/// reconstructs the same authorization to verify it. Unknown fields are ignored.
public struct SubscriptionRequest: Sendable, Hashable {
    /// The recurring per-period charge, in base units.
    public let amount: Amount
    /// The TIP-20 token/currency address the recurring transfer moves.
    public let currency: EthereumAddress
    /// The payee the recurring transfer is scoped to.
    public let recipient: EthereumAddress
    /// The billing period in seconds (`periodCount` x `periodUnit`), validated to fit `UInt64`.
    public let periodSeconds: UInt64
    /// The key-authorization expiry, in whole Unix seconds, from `subscriptionExpires`.
    public let expirySeconds: UInt64
    /// The access key the authorization delegates to, from `methodDetails.accessKey`, if present.
    public let accessKey: AccessKey?
    /// The chain the authorization is bound to, from `methodDetails.chainId`, if present.
    public let chainId: UInt64?
    /// An optional human description, surfaced for approval display.
    public let description: String?
    /// An optional caller-defined external id (echoed into the receipt).
    public let externalId: String?

    /// A subscription access key: the address the authorization delegates to, and its key scheme.
    public struct AccessKey: Sendable, Hashable {
        public let address: EthereumAddress
        public let keyType: TempoKeyAuthorization.KeyType

        public init(address: EthereumAddress, keyType: TempoKeyAuthorization.KeyType) {
            self.address = address
            self.keyType = keyType
        }
    }

    /// Decodes the subscription parameters from `challenge`'s `request`, fully validating every
    /// field
    /// (a `SubscriptionRequest` that exists is well-formed).
    public init(challenge: Challenge) throws(DecodingFailure) {
        let wire: Wire
        do {
            wire = try challenge.request.decode(as: Wire.self)
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
        guard let currency = EthereumAddress(hex: wire.currency) else {
            throw .invalidAddress(field: "currency")
        }
        guard let recipient = EthereumAddress(hex: wire.recipient) else {
            throw .invalidAddress(field: "recipient")
        }
        self.currency = currency
        self.recipient = recipient
        periodSeconds = try Self.periodSeconds(count: wire.periodCount, unit: wire.periodUnit)
        expirySeconds = try Self.expirySeconds(wire.subscriptionExpires)
        accessKey = try Self.accessKey(wire.methodDetails?.accessKey)
        chainId = wire.methodDetails?.chainId
        description = wire.description
        externalId = wire.externalId
    }

    /// Whether `challenge` is a `tempo`/`subscription` challenge carrying a decodable request.
    ///
    /// The rail's applicability contract, shared by the client method and the server verifier
    /// so the two cannot disagree on what this rail handles.
    public static func supports(_ challenge: Challenge) -> Bool {
        challenge.method == TempoMethod.name && challenge.intent == .subscription
            && (try? SubscriptionRequest(challenge: challenge)) != nil
    }

    /// `periodCount` x the unit's seconds, rejecting a non-canonical count, an unknown unit, or a
    /// product that overflows `UInt64`.
    private static func periodSeconds(
        count: String,
        unit: String
    ) throws(DecodingFailure) -> UInt64 {
        // Canonical positive integer per the spec grammar `[1-9][0-9]*`: an ASCII leading digit
        // 1-9 then ASCII digits (so "0", leading-zero, and non-ASCII-digit forms are rejected).
        // Scalar-range checks mirror `Amount.validate`, precise rather than `Character.isNumber`.
        guard let first = count.unicodeScalars.first, (0x31 ... 0x39).contains(first.value),
              count.unicodeScalars.dropFirst().allSatisfy({ (0x30 ... 0x39).contains($0.value) }),
              let value = UInt64(count)
        else { throw .invalidPeriod }
        let unitSeconds: UInt64
        switch unit {
        case "dev_second": unitSeconds = 1
        case "day": unitSeconds = 86400
        case "week": unitSeconds = 604_800
        default: throw .invalidPeriod
        }
        let (product, overflow) = value.multipliedReportingOverflow(by: unitSeconds)
        guard !overflow else { throw .invalidPeriod }
        return product
    }

    /// The whole-second Unix timestamp of an ISO-8601 `subscriptionExpires`, rejecting a malformed
    /// or sub-second value (a key authorization's expiry is whole seconds).
    private static func expirySeconds(_ iso: String) throws(DecodingFailure) -> UInt64 {
        // Whole seconds only, checked at the STRING level so Double precision can never
        // round a sub-second value to whole. A fractional-seconds field is allowed only if
        // it is all zeros: `Date.toISOString()` (and the reference SDK's serializer) emit a
        // whole second as `...:02.000Z`, which must be accepted, while `.5` is sub-second
        // and rejected. (The fractional field is the only place `.` appears in an RFC-3339
        // date-time; the timezone uses `Z`/`+`/`-`/`:`.)
        if let dot = iso.firstIndex(of: ".") {
            let fraction = iso[iso.index(after: dot)...].prefix { $0.isNumber }
            guard fraction.allSatisfy({ $0 == "0" }) else { throw .invalidExpiry }
        }
        guard let date = RFC3339DateTime.parse(iso) else { throw .invalidExpiry }
        let seconds = date.timeIntervalSince1970
        // Strict `<`: `Double(UInt64.max)` rounds UP to `2^64`, so `<=` would let `UInt64(seconds)`
        // trap at the boundary. The largest Double below it is well within `UInt64`.
        guard seconds > 0, seconds < Double(UInt64.max) else { throw .invalidExpiry }
        return UInt64(seconds)
    }

    private static func accessKey(_ wire: Wire.AccessKey?) throws(DecodingFailure) -> AccessKey? {
        guard let wire else { return nil }
        guard let address = EthereumAddress(hex: wire.accessKeyAddress) else {
            throw .invalidAccessKey
        }
        let keyType: TempoKeyAuthorization.KeyType
        switch wire.keyType {
        case "secp256k1": keyType = .secp256k1
        case "p256": keyType = .p256
        case "webAuthn": keyType = .webAuthn
        default: throw .invalidAccessKey
        }
        return AccessKey(address: address, keyType: keyType)
    }

    /// The TIP-20 `transferWithMemo(address,uint256,bytes32)` 4-byte selector the subscription
    /// authorization scopes the access key to.
    public static let transferWithMemoSelector = Data([0x95, 0x77, 0x7D, 0x59])

    /// The ``TempoKeyAuthorization`` this request authorizes for `accessKey` on `chainId`: a single
    /// per-period `limit` on `currency` and one `transferWithMemo` scope to `recipient`, expiring
    /// at
    /// ``expirySeconds``. The client signs exactly this; the server reconstructs it to verify, so
    /// both sides derive the authorization from one place (no drift between sign and verify).
    public func keyAuthorization(
        accessKey: AccessKey, chainId: UInt64
    ) -> TempoKeyAuthorization {
        TempoKeyAuthorization(
            address: accessKey.address,
            chainID: chainId,
            expiry: expirySeconds,
            keyType: accessKey.keyType,
            limits: [.init(token: currency, limit: amount.rawValue, period: periodSeconds)],
            scopes: [
                .init(
                    address: currency,
                    selector: Self.transferWithMemoSelector,
                    recipients: [recipient],
                ),
            ]
        )
    }

    /// A reason a subscription `request` could not be decoded.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// The `request` value was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a subscription-request JSON object.
        case invalidJSON(reason: String)
        /// The `amount` was not a canonical base-units integer string.
        case invalidAmount(Amount.ValidationError)
        /// `currency` or `recipient` was not a 20-byte address (`field` names which).
        case invalidAddress(field: String)
        /// `periodCount` was not a canonical positive integer, the unit was unknown, or the period
        /// overflowed `UInt64`.
        case invalidPeriod
        /// `subscriptionExpires` was not a whole-second ISO-8601 instant.
        case invalidExpiry
        /// `methodDetails.accessKey` had a malformed address or key type.
        case invalidAccessKey
    }
}

/// The decodable mirror of the on-wire subscription request. `amount`/`periodCount` are strings
/// (validated into `Amount` / `UInt64`, never numbers, so no float can reach them); `chainId` is a
/// JSON integer decoded as `UInt64` so a negative/fractional value fails closed. Unknown fields are
/// ignored.
private struct Wire: Decodable {
    let amount: String
    let currency: String
    let recipient: String
    let periodCount: String
    let periodUnit: String
    let subscriptionExpires: String
    let description: String?
    let externalId: String?
    let methodDetails: MethodDetails?

    struct MethodDetails: Decodable {
        let accessKey: AccessKey?
        let chainId: UInt64?
    }

    struct AccessKey: Decodable {
        let accessKeyAddress: String
        let keyType: String
    }
}
