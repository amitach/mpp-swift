import Foundation
import HTTPTypes
import Hummingbird
import MPPClientAsyncHTTP
import NIOCore
import Testing

// These tests run AsyncHTTPClientTransport against a real Hummingbird server bound to an ephemeral
// loopback port (the same Application + runService + onServerRunning pattern the conformance server
// uses), so the round-trip is genuine network I/O over SwiftNIO -- not a stub. The redirect test is
// the security crux: AsyncHTTPClient follows up to five redirects by default, so a passing
// "301 is returned, not followed" proves the transport's `.disallow` configuration holds.
//
// Hummingbird 2's runtime requires macOS 14 / iOS 17; swift-testing forbids @available on a suite,
// so each test guards at runtime and the time limit guards against a bind/handshake hang in CI.

@Suite("AsyncHTTPClientTransport")
struct AsyncHTTPClientTransportTests {
    private func router() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("ok") { _, _ in "PONG" }
        router.post("echo") { request, _ -> Response in
            let body = try await request.body.collect(upTo: 1024 * 1024)
            return Response(status: .ok, body: .init(byteBuffer: body))
        }
        router.get("redirect") { _, _ -> Response in
            Response(status: .movedPermanently, headers: [.location: "/ok"])
        }
        return router
    }

    /// Boots `router` on 127.0.0.1:0, hands the bound port to `body`, then shuts the server down.
    @available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
    private func withLiveServer(
        _ body: @Sendable (Int) async throws -> Void
    ) async throws {
        let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
        let app = Application(
            router: router(),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                portContinuation.yield(channel.localAddress?.port ?? 0)
                portContinuation.finish()
            }
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try? await app.runService() }
            var port = 0
            for await bound in portStream {
                port = bound; break
            }
            do {
                try await body(port)
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    private func get(_ port: Int, _ path: String) -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "http", authority: "127.0.0.1:\(port)", path: path)
    }

    /// Runs `body` with a fresh owned transport, shutting it down on both the success and the error
    /// path -- an owned `HTTPClient` traps in `deinit` if dropped un-shut, so a throwing assertion
    /// must not skip cleanup. `shutdown()` is idempotent, so this is safe even if `body` shuts down
    /// too.
    private func withTransport(
        _ body: (AsyncHTTPClientTransport) async throws -> Void
    ) async throws {
        let transport = AsyncHTTPClientTransport()
        do {
            try await body(transport)
        } catch {
            try? await transport.shutdown()
            throw error
        }
        try await transport.shutdown()
    }

    @Test("a real round-trip returns the body", .timeLimit(.minutes(1)))
    func roundTrip() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        try await withLiveServer { port in
            try await withTransport { transport in
                let (response, body) = try await transport.send(get(port, "/ok"), body: Data())
                #expect(response.status.code == 200)
                #expect(String(bytes: body, encoding: .utf8) == "PONG")
            }
        }
    }

    @Test("the request body is forwarded to the server", .timeLimit(.minutes(1)))
    func forwardsBody() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        try await withLiveServer { port in
            try await withTransport { transport in
                var request = get(port, "/echo")
                request.method = .post
                let (response, body) = try await transport.send(
                    request, body: Data("{\"hello\":\"mpp\"}".utf8)
                )
                #expect(response.status.code == 200)
                #expect(String(bytes: body, encoding: .utf8) == "{\"hello\":\"mpp\"}")
            }
        }
    }

    @Test(
        "a redirect is surfaced, not followed (no credential leak to 30x target)",
        .timeLimit(.minutes(1))
    )
    func doesNotFollowRedirects() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        try await withLiveServer { port in
            try await withTransport { transport in
                let (response, _) = try await transport.send(get(port, "/redirect"), body: Data())
                // Default AsyncHTTPClient would follow the 301 to /ok and return 200 "PONG";
                // .disallow returns the 301 itself so the caller re-applies its own policy.
                #expect(response.status.code == 301)
                #expect(response.headerFields[.location] == "/ok")
            }
        }
    }

    @Test("a request without scheme or authority is rejected before any network call")
    func rejectsUnroutableRequest() async throws {
        try await withTransport { transport in
            var request = HTTPRequest(method: .get, scheme: "https", authority: "x", path: "/x")
            request.scheme = nil
            request.authority = nil
            await #expect(throws: AsyncHTTPClientTransportError.unroutableRequest) {
                _ = try await transport.send(request, body: Data())
            }
        }
    }

    @Test("shutdown is idempotent -- a second call is a safe no-op")
    func shutdownIsIdempotent() async throws {
        let transport = AsyncHTTPClientTransport()
        try await transport.shutdown()
        try await transport.shutdown() // must not trap on the owned client's second shutdown
    }
}
