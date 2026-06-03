import Foundation
import HTTPTypes
import MPPClient
import MPPCore

/// The concrete ``StripePaymentIntentCreating``: creates a PaymentIntent by POSTing to
/// `api.stripe.com/v1/payment_intents` over the shared ``MPPHTTPTransport`` seam (mirroring
/// ``EVMRPC``'s transport + TLS pattern). It holds the Stripe secret key, which is sent only in the
/// `Authorization` header and never appears in an error, the request path, or a log.
public struct StripePaymentIntentClient: StripePaymentIntentCreating {
    private let transport: any MPPHTTPTransport
    private let secretKey: String
    private let baseURL: URL

    /// Creates the client.
    ///
    /// Enforces the shared transport-security policy (`https`-only unless `allowInsecureLocal`
    /// permits a loopback host, for a local mock). The secret key travels in the auth header, so a
    /// plain-`http` endpoint is rejected up front.
    /// - Parameters:
    ///   - transport: the HTTP transport.
    ///   - secretKey: the Stripe secret key (`sk_...`); never logged.
    ///   - baseURL: the Stripe API base (default `https://api.stripe.com`); a local mock passes a
    ///     loopback URL with `allowInsecureLocal: true`.
    public init(
        transport: any MPPHTTPTransport,
        secretKey: String,
        baseURL: URL = StripePaymentIntentClient.defaultBaseURL,
        allowInsecureLocal: Bool = false
    ) throws(StripeAPIError) {
        guard TransportSecurity.isAllowed(
            scheme: baseURL.scheme, host: baseURL.host(percentEncoded: false),
            allowInsecureLocal: allowInsecureLocal
        ) else {
            let endpoint = "\(baseURL.scheme ?? "")://\(baseURL.host(percentEncoded: false) ?? "")"
            throw .insecureTransport(url: endpoint)
        }
        self.transport = transport
        self.secretKey = secretKey
        self.baseURL = baseURL
    }

    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://api.stripe.com") else {
            preconditionFailure("the Stripe API base URL literal is valid")
        }
        return url
    }()

    public func create(
        _ request: StripePaymentIntentRequest
    ) async throws(StripeAPIError) -> StripePaymentIntentResult {
        let body = Self.formEncode(Self.bodyPairs(request))
        let response: HTTPResponse
        let data: Data
        do {
            (response, data) = try await transport.send(httpRequest(request), body: body)
        } catch {
            throw .transport(String(describing: error))
        }
        guard (200 ..< 300).contains(response.status.code) else {
            throw .stripeError(message: Self.errorMessage(from: data))
        }
        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw .malformedResponse(String(describing: error))
        }
        guard let fields = decoded.objectValue,
              let id = fields["id"]?.stringValue,
              let status = fields["status"]?.stringValue
        else {
            throw .malformedResponse("PaymentIntent response is not {id, status}")
        }
        let replayed = response.headerFields[Self.idempotentReplayed] == "true"
        return StripePaymentIntentResult(id: id, status: status, replayed: replayed)
    }

    // MARK: - Body

    /// The PaymentIntent form fields, in the reference SDK's order (fixed fields, then metadata
    /// keys sorted for determinism, then Connect fields). Sends `automatic_payment_methods` only,
    /// never `payment_method_types`.
    static func bodyPairs(_ request: StripePaymentIntentRequest) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("amount", String(request.amount)),
            ("automatic_payment_methods[allow_redirects]", "never"),
            ("automatic_payment_methods[enabled]", "true"),
            ("confirm", "true"),
            ("currency", request.currency),
            (StripeAPI.sharedPaymentTokenField, request.sharedPaymentGrantedToken),
        ]
        if let description = request.description {
            pairs.append(("description", description))
        }
        for (key, value) in request.metadata.sorted(by: { $0.key < $1.key }) {
            pairs.append(("metadata[\(key)]", value))
        }
        if let settlement = request.settlement {
            if let fee = settlement.applicationFeeAmount {
                pairs.append(("application_fee_amount", String(fee)))
            }
            if let onBehalfOf = settlement.onBehalfOf {
                pairs.append(("on_behalf_of", onBehalfOf))
            }
            if let transfer = settlement.transferData {
                pairs.append(("transfer_data[destination]", transfer.destination))
                if let amount = transfer.amount {
                    pairs.append(("transfer_data[amount]", String(amount)))
                }
            }
            if let group = settlement.transferGroup {
                pairs.append(("transfer_group", group))
            }
        }
        return pairs
    }

    /// Serializes form pairs per `application/x-www-form-urlencoded` (space -> `+`, percent-encode
    /// everything but `[A-Za-z0-9*-._]`).
    static func formEncode(_ pairs: [(String, String)]) -> Data {
        let joined = pairs
            .map { "\(component($0.0))=\(component($0.1))" }
            .joined(separator: "&")
        return Data(joined.utf8)
    }

    private static func component(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A, // 0-9 A-Z a-z
                 0x2A, 0x2D, 0x2E, 0x5F: // * - . _
                out.unicodeScalars.append(UnicodeScalar(byte))
            case 0x20: // space
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    private static func errorMessage(from data: Data) -> String {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let fields = decoded.objectValue,
              let error = fields["error"]?.objectValue,
              let message = error["message"]?.stringValue
        else {
            return "Stripe returned a non-success status"
        }
        return message
    }

    // MARK: - Request

    private func httpRequest(_ request: StripePaymentIntentRequest) -> HTTPRequest {
        var fields = HTTPFields()
        fields[.contentType] = "application/x-www-form-urlencoded"
        fields[.authorization] = "Basic " + Data("\(secretKey):".utf8).base64EncodedString()
        fields[Self.idempotencyKey] = request.idempotencyKey
        fields[Self.stripeVersion] = StripeAPI.version
        if let account = request.settlement?.stripeAccount {
            fields[Self.stripeAccount] = account
        }
        let host = baseURL.host(percentEncoded: false) ?? ""
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        let authority = baseURL.port.map { "\(bracketedHost):\($0)" } ?? bracketedHost
        let prefix = baseURL.path == "/" ? "" : baseURL.path
        return HTTPRequest(
            method: .post,
            scheme: baseURL.scheme ?? "https",
            authority: authority,
            path: prefix + StripeAPI.paymentIntentsPath,
            headerFields: fields
        )
    }

    private static func headerName(_ name: String) -> HTTPField.Name {
        guard let field = HTTPField.Name(name) else {
            preconditionFailure("\(name) is a valid HTTP field name")
        }
        return field
    }

    private static let idempotencyKey = headerName("Idempotency-Key")
    private static let stripeVersion = headerName("Stripe-Version")
    private static let stripeAccount = headerName("Stripe-Account")
    private static let idempotentReplayed = headerName("idempotent-replayed")
}

/// A reason a Stripe PaymentIntent request failed.
public enum StripeAPIError: Error, Sendable, Hashable {
    /// The base URL was not `https` and `allowInsecureLocal` did not permit it.
    case insecureTransport(url: String)
    /// The underlying HTTP transport threw (connection, TLS, timeout).
    case transport(String)
    /// Stripe returned a non-2xx status; `message` is Stripe's `error.message` (no secret).
    case stripeError(message: String)
    /// The 2xx response body was not a `{id, status}` PaymentIntent object.
    case malformedResponse(String)
}
