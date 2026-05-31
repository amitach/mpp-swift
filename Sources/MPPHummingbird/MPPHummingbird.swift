import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MPPCore
import MPPProxy
import MPPServer
import NIOCore

/// The live HTTP-server binding for the framework-neutral ``MPPProxy`` engine.
///
/// ``MPPProxy`` is pure `(HTTPRequest, Data) -> (HTTPResponse, Data)` logic with no server
/// dependency. This module is the thin Hummingbird skin that runs it over a real socket: it feeds
/// each incoming request's head + collected body to the engine and writes the engine's response
/// back. The engine does its own routing, so the binding mounts it as a single catch-all
/// ``HTTPResponder`` rather than registering routes on Hummingbird's router (routing then lives in
/// one place, the same table the discovery document is generated from).
///
/// Hummingbird 2's runtime requires macOS 14 / iOS 17, so this binding is gated accordingly; the
/// engine and every other MPP product remain at the package's macOS 13 floor.
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
public enum MPPHummingbird {
    /// Builds a Hummingbird `Application` that serves `proxy` on `hostname:port`.
    ///
    /// - Parameters:
    ///   - proxy: the proxy engine to serve.
    ///   - hostname: the bind address; defaults to loopback.
    ///   - port: the bind port (`0` lets the OS assign an ephemeral port).
    ///   - maxBodyBytes: the largest request body collected before forwarding; defaults to 10 MiB.
    ///   - now: the clock the engine evaluates challenge expiry against; defaults to the system
    /// clock.
    ///   - logger: an optional logger for the application.
    ///   - onServerRunning: called once the server is listening, with the bound channel (use it to
    ///     read the OS-assigned port when `port` is `0`).
    /// - Returns: an `Application` ready to `run()` / `runService()`.
    public static func application(
        for proxy: MPPProxy,
        hostname: String = "127.0.0.1",
        port: Int,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger? = nil,
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }
    ) -> Application<ProxyResponder<BasicRequestContext>> {
        let responder = ProxyResponder<BasicRequestContext>(
            proxy: proxy, maxBodyBytes: maxBodyBytes, now: now
        )
        return Application(
            responder: responder,
            configuration: .init(address: .hostname(hostname, port: port)),
            onServerRunning: onServerRunning,
            logger: logger
        )
    }
}

/// A Hummingbird responder that serves an ``MPPProxy`` for every request (the engine self-routes).
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
public struct ProxyResponder<Context: RequestContext>: HTTPResponder {
    private let proxy: MPPProxy
    private let maxBodyBytes: Int
    private let now: @Sendable () -> Date

    public init(
        proxy: MPPProxy,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.proxy = proxy
        self.maxBodyBytes = maxBodyBytes
        self.now = now
    }

    public func respond(to request: Request, context _: Context) async throws -> Response {
        var request = request
        return try await HummingbirdBridge
            .respond(to: &request, maxBodyBytes: maxBodyBytes) { head, body in
                await proxy.handle(head, body: body, now: now())
            }
    }
}

/// A Hummingbird responder that gates a single terminal route behind one ``MPPServerMiddleware``.
///
/// Unlike ``ProxyResponder``, this does not forward upstream: on a verified payment it runs
/// `handler`
/// to produce the resource directly (the gate still mints `402`s, enforces the body bound, and
/// attaches `Payment-Receipt`). It is the primitive a server uses to charge for its own endpoints
/// (for example the cross-SDK conformance server's `/proof` and session routes).
@available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
public struct GatedResponder<Context: RequestContext>: HTTPResponder {
    private let gate: MPPServerMiddleware
    private let maxBodyBytes: Int
    private let now: @Sendable () -> Date
    private let handler: @Sendable (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)

    public init(
        gate: MPPServerMiddleware,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() },
        handler: @escaping @Sendable (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)
    ) {
        self.gate = gate
        self.maxBodyBytes = maxBodyBytes
        self.now = now
        self.handler = handler
    }

    public func respond(to request: Request, context _: Context) async throws -> Response {
        var request = request
        return try await HummingbirdBridge
            .respond(to: &request, maxBodyBytes: maxBodyBytes) { head, body in
                await gate.handle(head, body: body, now: now()) { gatedRequest, verified in
                    await handler(gatedRequest, verified)
                }
            }
    }
}
