import Foundation
import MPPCore

/// The x402 HTTP header names (which differ by version) and the base64(JSON) value encoding they
/// share. x402 carries its protocol data in headers as standard-base64-encoded JSON.
public enum X402Header {
    /// The request header carrying the ``X402PaymentPayload``: `X-PAYMENT` (v1) or
    /// `PAYMENT-SIGNATURE` (v2).
    public static func payment(for version: X402Version) -> String {
        version == .v1 ? "X-PAYMENT" : "PAYMENT-SIGNATURE"
    }

    /// The response header carrying settlement info: `X-PAYMENT-RESPONSE` (v1) or
    /// `PAYMENT-RESPONSE`
    /// (v2).
    public static func paymentResponse(for version: X402Version) -> String {
        version == .v1 ? "X-PAYMENT-RESPONSE" : "PAYMENT-RESPONSE"
    }

    /// Encodes `value` as the standard-base64(JSON) string an x402 header carries. The JSON is JCS
    /// canonical, so the encoding is deterministic.
    public static func encode(_ value: JSONValue) -> String {
        Data(value.canonicalized().utf8).base64EncodedString()
    }

    /// Decodes a base64(JSON) x402 header value, or `nil` if it is not valid base64 or not JSON.
    public static func decode(_ header: String) -> JSONValue? {
        guard let data = Data(base64Encoded: header) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// The x402 payment the client sends in the `X-PAYMENT` / `PAYMENT-SIGNATURE` header: which
/// version,
/// scheme, and chain, wrapping the signed EIP-3009 ``X402ExactPayload``. The `network` is written
/// in
/// the version's form (CAIP-2 for v2, a short name for v1); the inner `payload` is version-stable.
public struct X402PaymentPayload: Sendable, Hashable {
    /// The protocol version this payload is encoded for.
    public let version: X402Version
    /// The x402 scheme (`exact`).
    public let scheme: String
    /// The chain the transfer settles on.
    public let network: X402Network
    /// The signed EIP-3009 authorization.
    public let payload: X402ExactPayload

    public init(
        version: X402Version,
        scheme: String = "exact",
        network: X402Network,
        payload: X402ExactPayload
    ) {
        self.version = version
        self.scheme = scheme
        self.network = network
        self.payload = payload
    }

    /// The x402 wire JSON for this payload.
    public func json() -> JSONValue {
        .object([
            "x402Version": .integer(Int64(version.rawValue)),
            "scheme": .string(scheme),
            "network": .string(network.wireValue(for: version)),
            "payload": .object(payload.jsonObject()),
        ])
    }

    /// Parses x402 wire JSON (the `x402Version` field selects the version), or `nil` if malformed.
    public init?(json: JSONValue) {
        guard case let .object(object) = json,
              let version = object.x402Version,
              let scheme = object["scheme"]?.stringValue,
              let networkWire = object["network"]?.stringValue,
              let network = X402Network(wire: networkWire),
              let payloadObject = object["payload"]?.objectValue,
              let payload = X402ExactPayload(jsonObject: payloadObject)
        else { return nil }
        self.init(version: version, scheme: scheme, network: network, payload: payload)
    }

    /// The `X-PAYMENT` / `PAYMENT-SIGNATURE` header value (base64 JSON).
    public var headerValue: String {
        X402Header.encode(json())
    }

    /// Parses an `X-PAYMENT` / `PAYMENT-SIGNATURE` header value, or `nil` if malformed.
    public init?(headerValue: String) {
        guard let json = X402Header.decode(headerValue) else { return nil }
        self.init(json: json)
    }
}

/// An x402 `402 Payment Required` response: the protocol version, the payment options the server
/// `accepts`, and an optional human `error`. In x402 v1 this JSON is the 402 body; in v2 it rides
/// the `PAYMENT-REQUIRED` header (base64 JSON) over an empty body.
public struct X402PaymentRequired: Sendable, Hashable {
    /// The protocol version the response is encoded for.
    public let version: X402Version
    /// The payment options the server will accept.
    public let accepts: [X402PaymentRequirements]
    /// An optional human-readable error/explanation.
    public let error: String?

    public init(version: X402Version, accepts: [X402PaymentRequirements], error: String? = nil) {
        self.version = version
        self.accepts = accepts
        self.error = error
    }

    /// The x402 wire JSON for this 402 response (each `accepts` entry encoded for `version`).
    public func json() -> JSONValue {
        var object: [String: JSONValue] = [
            "x402Version": .integer(Int64(version.rawValue)),
            "accepts": .array(accepts.map { $0.json(for: version) }),
        ]
        if let error {
            object["error"] = .string(error)
        }
        return .object(object)
    }

    /// Parses x402 wire JSON, or `nil` if malformed or any `accepts` entry is malformed
    /// (fail-closed).
    public init?(json: JSONValue) {
        guard case let .object(object) = json,
              let version = object.x402Version,
              let acceptsValue = object["accepts"], case let .array(acceptsArray) = acceptsValue
        else { return nil }
        var accepts: [X402PaymentRequirements] = []
        for entry in acceptsArray {
            guard let requirement = X402PaymentRequirements(json: entry, version: version) else {
                return nil
            }
            accepts.append(requirement)
        }
        self.init(version: version, accepts: accepts, error: object["error"]?.stringValue)
    }

    /// The v2 `PAYMENT-REQUIRED` header value (base64 JSON). (v1 carries this JSON in the body.)
    public var headerValue: String {
        X402Header.encode(json())
    }

    /// Parses a `PAYMENT-REQUIRED` header (or any base64-JSON 402 body), or `nil` if malformed.
    public init?(headerValue: String) {
        guard let json = X402Header.decode(headerValue) else { return nil }
        self.init(json: json)
    }
}

private extension [String: JSONValue] {
    /// The `x402Version` field as a validated ``X402Version``, fail-closed (a non-1/2 or out-of-Int
    /// value yields `nil`).
    var x402Version: X402Version? {
        guard let raw = self["x402Version"]?.integerValue,
              let int = Int(exactly: raw) else { return nil }
        return X402Version(rawValue: int)
    }
}
