import Foundation
import MPPCore

/// One route to advertise in a generated discovery document: an operation at `path` + `method`,
/// optionally payment-gated and/or carrying a `requestBody` schema.
public struct DiscoveryRoute: Sendable, Hashable {
    /// The OpenAPI path (e.g. `/v1/translate`).
    public var path: String
    /// The HTTP method.
    public var method: HTTPMethod
    /// The payment offers for this operation, or `nil` for a free operation.
    public var payment: PaymentInfo?
    /// The OpenAPI `requestBody` object for this operation, if any (a raw JSON object).
    public var requestBody: JSONValue?
    /// A short summary for the operation.
    public var summary: String?

    public init(
        path: String,
        method: HTTPMethod,
        payment: PaymentInfo? = nil,
        requestBody: JSONValue? = nil,
        summary: String? = nil
    ) {
        self.path = path
        self.method = method
        self.payment = payment
        self.requestBody = requestBody
        self.summary = summary
    }
}

/// Generates the OpenAPI discovery document a service publishes at
/// ``DiscoveryDocument/conventionalPath``.
///
/// Produces the full OpenAPI object (not the payment-projection ``DiscoveryDocument``, which omits
/// `responses` / `requestBody`): a payment-gated operation gets the spec-mandated `402` response
/// declaration plus a `200`, its `x-payment-info`, and its `requestBody` when supplied. The result
/// validates cleanly under ``DiscoveryValidator/validate(_:)``.
public enum DiscoveryGenerator {
    /// - Parameters:
    ///   - info: the document `info` (title + version).
    ///   - routes: the operations to advertise.
    ///   - serviceInfo: optional document-root `x-service-info`.
    ///   - openAPIVersion: the OpenAPI version string (default `"3.1.0"`).
    /// - Returns: the OpenAPI document as a `JSONValue` (encode it with `JSONEncoder` to serve).
    public static func generate(
        info: DiscoveryDocument.Info,
        routes: [DiscoveryRoute],
        serviceInfo: ServiceInfo? = nil,
        openAPIVersion: String = "3.1.0"
    ) throws -> JSONValue {
        var pathItems: [String: [String: JSONValue]] = [:]
        for route in routes {
            pathItems[route.path, default: [:]][route.method.rawValue] = try operation(for: route)
        }
        var paths: [String: JSONValue] = [:]
        for (path, methods) in pathItems {
            paths[path] = .object(methods)
        }

        var document: [String: JSONValue] = [
            "openapi": .string(openAPIVersion),
            "info": .object(["title": .string(info.title), "version": .string(info.version)]),
            "paths": .object(paths),
        ]
        if let serviceInfo {
            document["x-service-info"] = try encodedJSON(serviceInfo)
        }
        return .object(document)
    }

    private static func operation(for route: DiscoveryRoute) throws -> JSONValue {
        var operation: [String: JSONValue] = [:]
        if let summary = route.summary {
            operation["summary"] = .string(summary)
        }
        // A payable operation MUST declare a 402 response (the discovery spec); every operation
        // declares a 200 so it is a well-formed OpenAPI operation.
        var responses: [String: JSONValue] = [
            "200": .object(["description": .string("Successful response")]),
        ]
        if let payment = route.payment {
            responses["402"] = .object(["description": .string("Payment Required")])
            operation["x-payment-info"] = try encodedJSON(payment)
        }
        operation["responses"] = .object(responses)
        if let requestBody = route.requestBody {
            operation["requestBody"] = requestBody
        }
        return .object(operation)
    }

    /// Re-encodes a Codable payment/service value to a `JSONValue` for embedding in the document.
    private static func encodedJSON(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
