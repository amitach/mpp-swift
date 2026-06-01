import Foundation
import MPPCore
@testable import MPPStripe

// Shared fixtures for the MPPStripe client tests: a stripe/charge challenge builder (so each test
// states only the fields it varies) and token-provider helpers.

/// Builds a `stripe`/`charge` request object (post-mint wire shape). Pass `nil` to omit a field
/// (to exercise decode failures); the defaults are a valid request.
func stripeRequest(
    amount: JSONValue? = .string("1000"),
    currency: JSONValue? = .string("usd"),
    description: JSONValue? = nil,
    externalId: JSONValue? = nil,
    recipient: JSONValue? = nil,
    methodDetails: JSONValue? = .object([
        "networkId": .string("internal"),
        "paymentMethodTypes": .array([.string("card")]),
    ])
) -> JSONValue {
    var object: [String: JSONValue] = [:]
    if let amount { object["amount"] = amount }
    if let currency { object["currency"] = currency }
    if let description { object["description"] = description }
    if let externalId { object["externalId"] = externalId }
    if let recipient { object["recipient"] = recipient }
    if let methodDetails { object["methodDetails"] = methodDetails }
    return .object(object)
}

/// A `stripe`/`charge` challenge carrying `request`. `method`/`intent` are overridable to build
/// the negative `supports` cases.
func stripeChallenge(
    id: String = "c1",
    method: String = "stripe",
    intent: IntentName = .charge,
    request: JSONValue = stripeRequest()
) throws -> Challenge {
    try Challenge(
        id: id, realm: "https://api.example.com", method: MethodName(method),
        intent: intent, request: EncodedJSON(json: request)
    )
}

/// A `stripe`/`charge` challenge whose raw `request` string is whatever is passed (used to feed a
/// non-base64url value).
func stripeChallengeRawRequest(_ raw: String) throws -> Challenge {
    try Challenge(
        id: "c1", realm: "https://api.example.com", method: MethodName("stripe"),
        intent: .charge, request: EncodedJSON(raw)
    )
}

/// A provider returning a fixed SPT.
func fixedTokenProvider(_ spt: String = "spt_test_123") -> StripeTokenProvider {
    StripeTokenProvider { _ in spt }
}

/// Extracts the string from a `JSONValue` payload entry, or nil (test-only; MPPStripe's source
/// writes the payload and never reads it back).
func jsonString(_ value: JSONValue?) -> String? {
    if case let .string(string)? = value { return string }
    return nil
}
