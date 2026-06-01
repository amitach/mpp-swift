import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPStripe
@testable import MPPStripeServer

// Fixtures for the MPPStripeServer tests: a stub PaymentIntent seam (captures the request, returns
// a canned result or throws), a stub HTTP transport (captures the request + body, returns a canned
// response), and stripe/charge challenge + credential builders.

/// A stub ``StripePaymentIntentCreating`` that records the request it was handed and returns a
/// canned result (or throws), so the verifier's state machine is exercised with no network.
actor StubPaymentIntent: StripePaymentIntentCreating {
    private(set) var captured: StripePaymentIntentRequest?
    private let result: StripePaymentIntentResult
    private let failure: (any Error)?

    init(status: String = "succeeded", id: String = "pi_stub", replayed: Bool = false) {
        result = StripePaymentIntentResult(id: id, status: status, replayed: replayed)
        failure = nil
    }

    init(throwing failure: any Error) {
        result = StripePaymentIntentResult(id: "", status: "", replayed: false)
        self.failure = failure
    }

    func create(_ request: StripePaymentIntentRequest) async throws -> StripePaymentIntentResult {
        captured = request
        if let failure { throw failure }
        return result
    }
}

/// A stub ``MPPHTTPTransport`` that records the request + body and returns a canned response.
final class StubTransport: MPPHTTPTransport, @unchecked Sendable {
    let response: HTTPResponse
    let body: Data
    private let box = CaptureBox()

    init(status: Int, headers: HTTPFields = HTTPFields(), body: Data) {
        response = HTTPResponse(status: .init(code: status), headerFields: headers)
        self.body = body
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        await box.capture(request: request, body: body)
        return (response, self.body)
    }

    var capturedRequest: HTTPRequest? {
        get async { await box.request }
    }

    var capturedBody: Data? {
        get async { await box.body }
    }

    private actor CaptureBox {
        private(set) var request: HTTPRequest?
        private(set) var body: Data?
        func capture(request: HTTPRequest, body: Data) {
            self.request = request
            self.body = body
        }
    }
}

func stripeChargeChallenge(
    id: String = "c1",
    request: JSONValue = .object([
        "amount": .string("1000"),
        "currency": .string("usd"),
        "methodDetails": .object([
            "networkId": .string("internal"),
            "paymentMethodTypes": .array([.string("card")]),
        ]),
    ])
) throws -> Challenge {
    try Challenge(
        id: id, realm: "https://api.example.com", method: MethodName("stripe"),
        intent: .charge, request: EncodedJSON(json: request)
    )
}

func stripeCredential(
    spt: JSONValue? = .string("spt_test_123"),
    externalId: String? = nil,
    source: String? = nil,
    challenge: Challenge? = nil
) throws -> Credential {
    var payload: [String: JSONValue] = [:]
    if let spt { payload["spt"] = spt }
    if let externalId { payload["externalId"] = .string(externalId) }
    return try Credential(
        challenge: challenge ?? stripeChargeChallenge(),
        source: source,
        payload: payload
    )
}

/// Reads a `Receipt.ReceiptValue` string extra.
func receiptString(_ value: Receipt.ReceiptValue?) -> String? {
    if case let .string(string)? = value { return string }
    return nil
}

/// Builds `HTTPFields` from name/value pairs (skipping any invalid name), so tests avoid `!`.
func headerFields(_ pairs: [(String, String)]) -> HTTPFields {
    var fields = HTTPFields()
    for (name, value) in pairs {
        guard let fieldName = HTTPField.Name(name) else { continue }
        fields[fieldName] = value
    }
    return fields
}

/// Reads a header value by raw name (nil if the name is invalid or absent).
func header(_ fields: HTTPFields, _ name: String) -> String? {
    guard let fieldName = HTTPField.Name(name) else { return nil }
    return fields[fieldName]
}
