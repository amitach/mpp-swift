import Foundation
import MPPCore

/// The price of an operation in an `x-payment-info` offer. On the wire, an
/// explicit `null` means **dynamic pricing** (the server sets the price at
/// request time); a fixed price is a base-units integer (an ``Amount``). An
/// absent `amount` field is distinct from `null` and decodes to `nil`.
public enum PaymentAmount: Sendable, Hashable {
    /// A fixed price in base units.
    case fixed(Amount)
    /// Dynamic pricing (`amount: null` on the wire).
    case dynamic
}

/// A single payment offer: the fields of one way to pay for an operation. The
/// flat (single-offer) form of `x-payment-info` and each entry of its `offers`
/// array share this shape.
public struct PaymentOffer: Sendable, Hashable, Codable {
    /// The price, or `nil` if no `amount` field was present (`.dynamic` is an
    /// explicit `null`).
    public var amount: PaymentAmount?
    /// ISO 4217 currency code or a token address.
    public var currency: String?
    /// A human-readable description (never used for verification).
    public var description: String?
    /// The payment intent (for example `charge`).
    public var intent: String?
    /// The payment method identifier.
    public var method: String?

    public init(
        amount: PaymentAmount? = nil,
        currency: String? = nil,
        description: String? = nil,
        intent: String? = nil,
        method: String? = nil
    ) {
        self.amount = amount
        self.currency = currency
        self.description = description
        self.intent = intent
        self.method = method
    }

    private enum CodingKeys: String, CodingKey {
        case amount, currency, description, intent, method
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Distinguish absent (nil) from explicit null (.dynamic) from a fixed value.
        if container.contains(.amount) {
            amount = try container.decodeNil(forKey: .amount)
                ? .dynamic
                : .fixed(container.decode(Amount.self, forKey: .amount))
        } else {
            amount = nil
        }
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        intent = try container.decodeIfPresent(String.self, forKey: .intent)
        method = try container.decodeIfPresent(String.self, forKey: .method)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch amount {
        case let .fixed(value): try container.encode(value, forKey: .amount)
        case .dynamic: try container.encodeNil(forKey: .amount)
        case nil: break
        }
        try container.encodeIfPresent(currency, forKey: .currency)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encodeIfPresent(method, forKey: .method)
    }
}

/// The `x-payment-info` OpenAPI extension on an operation: one or more payment
/// offers. The wire form is either flat (a single offer's fields inline) or an
/// `offers` array; the two cannot be mixed. Both decode to the canonical
/// `offers` list (always at least one), and encoding always emits `offers`.
public struct PaymentInfo: Sendable, Hashable, Codable {
    /// The offers (at least one).
    public var offers: [PaymentOffer]

    /// Creates payment info from one or more offers.
    public init(offers: [PaymentOffer]) {
        self.offers = offers
    }

    /// A reason an `x-payment-info` value is malformed.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// `offers` was present but empty.
        case emptyOffers
        /// `offers` was present but explicitly `null`.
        case nullOffers
        /// `offers` was mixed with flat offer fields.
        case mixedOffersAndFlatFields
    }

    private enum CodingKeys: String, CodingKey {
        case offers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.offers) {
            // An explicit `offers: null` is malformed (not a flat form); reject it
            // rather than fall through to a phantom empty offer.
            guard try !container.decodeNil(forKey: .offers) else {
                throw DecodingFailure.nullOffers
            }
            let parsed = try container.decode([PaymentOffer].self, forKey: .offers)
            guard !parsed.isEmpty else {
                throw DecodingFailure.emptyOffers
            }
            // Offers must not be mixed with flat fields (the only key may be `offers`).
            let flat = try decoder.singleValueContainer().decode(PaymentInfoFlatProbe.self)
            guard !flat.hasFlatFields else {
                throw DecodingFailure.mixedOffersAndFlatFields
            }
            offers = parsed
        } else {
            // Flat form: the object itself is a single offer.
            offers = try [decoder.singleValueContainer().decode(PaymentOffer.self)]
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offers, forKey: .offers)
    }
}

/// Probe for any flat offer field alongside `offers` (mixing is rejected).
private struct PaymentInfoFlatProbe: Decodable {
    let hasFlatFields: Bool
    private enum Keys: String, CodingKey { case amount, currency, description, intent, method }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        hasFlatFields = !container.allKeys.isEmpty
    }
}
