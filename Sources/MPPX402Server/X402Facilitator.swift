import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPX402

/// The result of an x402 facilitator `/verify`: whether the payment is acceptable (the facilitator
/// checked the EIP-3009 signature, the payer's balance, and that the fields match the
/// requirements).
public struct X402VerifyResponse: Sendable, Hashable {
    /// Whether the payment is valid.
    public let isValid: Bool
    /// The reason it was rejected, if any.
    public let invalidReason: String?
    /// The recovered payer address, if the facilitator reported one.
    public let payer: String?

    public init(isValid: Bool, invalidReason: String? = nil, payer: String? = nil) {
        self.isValid = isValid
        self.invalidReason = invalidReason
        self.payer = payer
    }
}

/// The result of an x402 facilitator `/settle`: the on-chain outcome (also the body of the
/// `X-PAYMENT-RESPONSE` / `PAYMENT-RESPONSE` header).
public struct X402SettlementResponse: Sendable, Hashable {
    /// Whether the transfer settled.
    public let success: Bool
    /// The settled transaction hash (empty on failure).
    public let transaction: String
    /// The network it settled on, if reported.
    public let network: String?
    /// The payer address, if reported.
    public let payer: String?
    /// The failure reason, if any.
    public let errorReason: String?

    public init(
        success: Bool, transaction: String, network: String? = nil, payer: String? = nil,
        errorReason: String? = nil
    ) {
        self.success = success
        self.transaction = transaction
        self.network = network
        self.payer = payer
        self.errorReason = errorReason
    }
}

/// A client for an x402 facilitator -- its `/verify` and `/settle` endpoints -- over an
/// ``MPPHTTPTransport``. A resource server posts `{x402Version, paymentPayload,
/// paymentRequirements}`
/// and the facilitator validates the EIP-3009 authorization and submits the transfer on its behalf
/// (x402's native, gasless-for-everyone settlement model).
public struct X402Facilitator: Sendable {
    private let baseURL: URL
    private let transport: any MPPHTTPTransport

    /// Creates a facilitator client.
    /// - Parameters:
    ///   - baseURL: the facilitator's base URL (its `/verify` and `/settle` are resolved against
    /// it).
    ///   - transport: the HTTP transport to post over.
    public init(baseURL: URL, transport: any MPPHTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `POST /verify`: asks the facilitator whether `payment` satisfies `requirements`.
    public func verify(
        payment: X402PaymentPayload, requirements: X402PaymentRequirements
    ) async throws(X402FacilitatorError) -> X402VerifyResponse {
        let object = try await post("/verify", payment: payment, requirements: requirements)
        guard case let .bool(isValid)? = object["isValid"] else {
            throw .malformedResponse("verify response has no isValid")
        }
        return X402VerifyResponse(
            isValid: isValid,
            invalidReason: object["invalidReason"]?.stringValue,
            payer: object["payer"]?.stringValue
        )
    }

    /// `POST /settle`: asks the facilitator to submit `payment` on-chain.
    public func settle(
        payment: X402PaymentPayload, requirements: X402PaymentRequirements
    ) async throws(X402FacilitatorError) -> X402SettlementResponse {
        let object = try await post("/settle", payment: payment, requirements: requirements)
        guard case let .bool(success)? = object["success"] else {
            throw .malformedResponse("settle response has no success")
        }
        return X402SettlementResponse(
            success: success,
            transaction: object["transaction"]?.stringValue ?? "",
            network: object["network"]?.stringValue,
            payer: object["payer"]?.stringValue,
            errorReason: object["errorReason"]?.stringValue
        )
    }

    /// POSTs `{x402Version, paymentPayload, paymentRequirements}` to `path` and returns the decoded
    /// JSON object.
    private func post(
        _ path: String, payment: X402PaymentPayload, requirements: X402PaymentRequirements
    ) async throws(X402FacilitatorError) -> [String: JSONValue] {
        let body = JSONValue.object([
            "x402Version": .integer(Int64(payment.version.rawValue)),
            "paymentPayload": payment.json(),
            "paymentRequirements": requirements.json(for: payment.version),
        ])
        let response: HTTPResponse
        let data: Data
        do {
            (response, data) = try await transport.send(
                httpRequest(path), body: Data(body.canonicalized().utf8)
            )
        } catch {
            throw .transport(String(describing: error))
        }
        guard (200 ..< 300).contains(response.status.code) else {
            throw .httpStatus(response.status.code)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = json.objectValue
        else {
            throw .malformedResponse("facilitator response is not a JSON object")
        }
        return object
    }

    private func httpRequest(_ path: String) -> HTTPRequest {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        let prefix = baseURL.path == "/" ? "" : baseURL.path
        return HTTPRequest(
            method: .post,
            scheme: baseURL.scheme ?? "https",
            authority: MPPHTTPEndpoint(baseURL).authority,
            path: prefix + path,
            headerFields: fields
        )
    }
}

/// A reason an ``X402Facilitator`` call failed.
public enum X402FacilitatorError: Error, Sendable, Hashable {
    /// The HTTP transport threw (connection, TLS, timeout).
    case transport(String)
    /// The facilitator answered with a non-2xx status.
    case httpStatus(Int)
    /// The facilitator's response was not the expected JSON.
    case malformedResponse(String)
}
