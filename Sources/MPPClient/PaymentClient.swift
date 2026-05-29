import Foundation
import HTTPTypes
import MPPCore

/// The 402 payment client flow.
///
/// ``send(_:body:)`` sends a request and, on a `402 Payment Required`, parses the
/// `WWW-Authenticate: Payment` challenges, selects one a registered
/// ``PaymentMethodClient`` supports, has that method build a credential, replays
/// the request once with `Authorization: Payment`, and returns the paid response
/// (surfacing any `Payment-Receipt`). A non-402 response is returned untouched.
///
/// The flow performs no network itself: it runs over an ``MPPHTTPTransport`` seam,
/// so it is exercised end-to-end against an in-memory stub. Transport security is
/// enforced before any request leaves: a non-`https` URL is rejected unless
/// `allowInsecureLocal` permits a loopback host.
public struct PaymentClient: Sendable {
    private let transport: any MPPHTTPTransport
    private let methods: [any PaymentMethodClient]
    private let acceptPaymentPolicy: AcceptPaymentPolicy
    private let advertise: String?
    private let allowInsecureLocal: Bool
    private let onEvent: @Sendable (ClientEvent) -> Void

    /// Creates a payment client over a transport and a set of payment methods.
    ///
    /// - Parameters:
    ///   - transport: The HTTP seam the flow sends over.
    ///   - methods: The payment methods, tried in order when selecting a challenge.
    ///   - acceptPaymentPolicy: Gates whether the `Accept-Payment` header is sent
    ///     (defaults to ``AcceptPaymentPolicy/always``).
    ///   - advertise: The `Accept-Payment` value to send when the policy allows and
    ///     the caller did not set the header themselves; `nil` sends none.
    ///   - allowInsecureLocal: Permit non-`https` only for a loopback host
    ///     (`localhost`, `*.localhost`, `127.0.0.1`, `::1`); for tests and local
    ///     servers. Defaults to `false` (production is `https`-only).
    ///   - onEvent: A synchronous diagnostics sink; defaults to a no-op.
    public init(
        transport: any MPPHTTPTransport,
        methods: [any PaymentMethodClient],
        acceptPaymentPolicy: AcceptPaymentPolicy = .always,
        advertise: String? = nil,
        allowInsecureLocal: Bool = false,
        onEvent: @escaping @Sendable (ClientEvent) -> Void = { _ in }
    ) {
        self.transport = transport
        self.methods = methods
        self.acceptPaymentPolicy = acceptPaymentPolicy
        self.advertise = advertise
        self.allowInsecureLocal = allowInsecureLocal
        self.onEvent = onEvent
    }

    /// Sends `request`, transparently paying a single `402` if one is returned.
    ///
    /// - Returns: the final response. If the first response is not `402`, it is
    ///   returned as-is. On a `402`, the paid retry's response is returned.
    /// - Throws: ``PaymentClientError`` for the flow's own rejections (insecure
    ///   transport, no parseable challenge, no supported method); a transport or
    ///   method error propagates unwrapped.
    public func send(
        _ request: HTTPRequest,
        body: Data = Data()
    ) async throws -> (HTTPResponse, Data) {
        let url = Self.url(of: request)
        try guardTransportSecurity(scheme: request.scheme, url: url)

        var request = request
        if let advertise, let url,
           acceptPaymentPolicy.allows(url),
           request.headerFields[Self.acceptPayment] == nil {
            request.headerFields[Self.acceptPayment] = advertise
        }

        let (response, responseBody) = try await transport.send(request, body: body)
        guard response.status.code == 402 else { return (response, responseBody) }

        // Parse every Payment challenge across all WWW-Authenticate values. A
        // value may pack several comma-separated challenges (RFC 9110 §11.6.1),
        // and a response may also carry multiple WWW-Authenticate lines.
        let challenges = response.headerFields[values: .wwwAuthenticate]
            .flatMap { Challenge.challenges(inHeaderValue: $0) }
        guard !challenges.isEmpty else {
            onEvent(.paymentFailed(.malformedChallenge))
            throw PaymentClientError.malformedChallenge
        }
        guard let selection = select(from: challenges) else {
            onEvent(.paymentFailed(.noSupportedMethod))
            throw PaymentClientError.noSupportedMethod
        }
        onEvent(.challengeReceived(selection.challenge))

        let credential = try await selection.method.buildCredential(for: selection.challenge)
        onEvent(.credentialCreated(credential))

        var retry = request
        retry.headerFields[.authorization] = try credential.headerValue
        let (paidResponse, paidBody) = try await transport.send(retry, body: body)

        let receipt = paidResponse.headerFields[Self.paymentReceipt]
            .flatMap { try? Receipt(headerValue: $0) }
        onEvent(.paymentResponse(receipt: receipt))
        return (paidResponse, paidBody)
    }

    /// The first offered challenge a registered method supports, with that method.
    /// (Challenges are tried in offered order; q-value ranking is a later refinement.)
    private func select(
        from challenges: [Challenge]
    ) -> (method: any PaymentMethodClient, challenge: Challenge)? {
        for challenge in challenges {
            if let method = methods.first(where: { $0.supports(challenge) }) {
                return (method, challenge)
            }
        }
        return nil
    }

    private func guardTransportSecurity(scheme: String?, url: URL?) throws {
        if scheme?.lowercased() == "https" { return }
        if allowInsecureLocal, let host = url?.host(percentEncoded: false), Self.isLoopback(host) {
            return
        }
        let target = url?.absoluteString ?? ""
        onEvent(.paymentFailed(.insecureTransport(url: target)))
        throw PaymentClientError.insecureTransport(url: target)
    }

    private static func url(of request: HTTPRequest) -> URL? {
        guard let scheme = request.scheme, let authority = request.authority else { return nil }
        return URL(string: "\(scheme)://\(authority)\(request.path ?? "")")
    }

    private static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "::1"
    }

    private static let acceptPayment = fieldName("Accept-Payment")
    private static let paymentReceipt = fieldName("Payment-Receipt")

    /// A non-standard field name from a compile-time-known-valid token.
    private static func fieldName(_ token: String) -> HTTPField.Name {
        guard let name = HTTPField.Name(token) else {
            preconditionFailure("\(token) is a valid HTTP field name")
        }
        return name
    }
}

/// A flow-level reason ``PaymentClient`` did not complete a payment.
///
/// These are the flow's own rejections. An error thrown by the transport or by a
/// payment method propagates to the caller unwrapped (the flow does not relabel
/// another layer's typed error).
public enum PaymentClientError: Error, Sendable, Hashable {
    /// The request URL was not `https` and `allowInsecureLocal` did not permit it.
    case insecureTransport(url: String)
    /// The `402` response carried no parseable `Payment` challenge.
    case malformedChallenge
    /// No registered payment method supports any offered challenge.
    case noSupportedMethod
}
