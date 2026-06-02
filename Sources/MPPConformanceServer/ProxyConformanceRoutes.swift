import Foundation
import HTTPTypes
import Hummingbird
import MPPDiscovery
import MPPHummingbird
import MPPProxy
import NIOCore

// The proxy conformance route. The mppx reference CLIENT pays `GET /proxy/echo/resource` on our
// MPPProxy: the proxy mints the 402, verifies the foreign Tempo proof with the SAME zero-amount
// charge gate the direct /proof route uses (``makeMiddleware``), forwards the verified request to
// the free in-server origin (`/origin/resource`), and relays its body with a Payment-Receipt. This
// proves a foreign client can pay THROUGH our proxy, not only a directly gated endpoint.
//
// Forwarding uses the proxy's default URLSessionTransport, so the proxy -> origin hop is a real
// loopback HTTP call pinned to this server's requested port. The proxy route therefore needs a
// fixed PORT (run-proxy.sh sets one), unlike the direct routes which also accept PORT=0 ephemeral.

enum ProxyConformanceError: Error {
    case malformedOriginURL
    case emptyPayment
}

/// Builds the proxy that fronts the free in-server origin behind one paid Tempo-charge route.
func makeProxyConformance() throws -> MPPProxy {
    let gate = try makeMiddleware()
    guard let originBaseURL = URL(string: "http://127.0.0.1:\(requestedPort)/origin") else {
        throw ProxyConformanceError.malformedOriginURL
    }
    // A dynamic-price advertisement for the paid route's discovery surface; the gate (not this
    // value) enforces payment, so any well-formed offer suffices for conformance.
    guard let payment = PaymentInfo(offers: [
        PaymentOffer(amount: .dynamic, currency: "USD", intent: "charge", method: "tempo"),
    ]) else {
        throw ProxyConformanceError.emptyPayment
    }
    let service = try ProxyService(
        id: "echo",
        baseURL: originBaseURL,
        routes: [
            ProxyRoute(
                method: .get,
                pattern: RoutePattern("/resource"),
                endpoint: .paid(gate, payment: payment),
                summary: "Proxy conformance: a paid passthrough to the free origin"
            ),
        ]
    )
    return try MPPProxy(
        services: [service],
        info: .init(title: "Conformance Proxy", version: "1"),
        basePath: "/proxy"
    )
}

/// Mounts the free origin (`GET /origin/resource`) and the proxy's paid route
/// (`GET|POST /proxy/echo/resource`) on `router`. The mppx client pays the proxy route; the proxy
/// verifies the foreign proof and forwards to the origin over loopback.
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
func registerProxyConformance(on router: Router<BasicRequestContext>) throws {
    router.on("origin/resource", method: .get) { _, _ in
        var buffer = ByteBuffer()
        buffer.writeString(#"{"ok":true,"origin":"hit"}"#)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: buffer)
        )
    }
    let proxyResponder = try ProxyResponder<BasicRequestContext>(proxy: makeProxyConformance())
    for method in [HTTPRequest.Method.get, .post] {
        router.on("proxy/echo/resource", method: method) { request, context in
            logIncoming(request.head)
            return try await proxyResponder.respond(to: request, context: context)
        }
    }
}
