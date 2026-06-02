import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import Logging
import MPPCore
import MPPTempoServer
import Testing
import WSCore
@testable import MPPWebSocket
@testable import MPPWebSocketLive

private func liveReceipt(_ reference: String) throws -> Receipt {
    try Receipt(
        method: MethodName("tempo"),
        timestamp: RFC3339DateTime("2026-01-02T00:00:00Z"),
        reference: reference
    )
}

/// A thread-safe string accumulator for the `@Sendable` client handlers.
private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) {
        lock.withLock { items.append(value) }
    }

    var values: [String] {
        lock.withLock { items }
    }
}

// Gated behind MPP_WS_LIVE so the parallel default `swift test` skips it (the in-process
// MPPWebSocket suites are the deterministic gate on both platforms). CI runs it isolated with the
// env set on LINUX only: the GitHub macOS runner cannot reliably bind a localhost WebSocket
// listener via NIOTransportServices (the Network.framework NWListener refuses connections in that
// sandboxed runner), so the live socket is exercised on Linux CI and in local macOS dev, not on
// the macOS runner. The connect must succeed on the first try: no retry, no sleep.
@Suite("MPPWebSocketLive", .enabled(if: ProcessInfo.processInfo.environment["MPP_WS_LIVE"] != nil))
struct LiveWebSocketSessionTests {
    @Test("a metered session runs end to end over a real WebSocket (server <-> client)")
    func roundTrip() async throws {
        let authReceipt = try liveReceipt("0xauth")
        let finalReceipt = try liveReceipt("0xfinal")

        // Server: upgrade every request and serve a fixed two-chunk stream that ends with the
        // terminal receipt. Stub verify acks the open; no shortfall, so makeVoucher is unused.
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(shouldUpgrade: { _, _, _ in
                .upgrade([:]) { inbound, outbound, _ in
                    await WebSocketSessionServer.serve(
                        inbound: inbound, outbound: outbound,
                        verify: { _ in SessionAuthorization(receipt: authReceipt, kind: .stream) },
                        makeStream: {
                            AsyncThrowingStream { continuation in
                                continuation.yield(.message("a"))
                                continuation.yield(.message("b"))
                                continuation.yield(.receipt(finalReceipt))
                                continuation.finish()
                            }
                        },
                        closeReceipt: { finalReceipt }
                    )
                }
            }),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )

        try await app.test(.live) { client in
            let port = try #require(client.port)
            let messages = StringBox()
            let receiptRefs = StringBox()

            let receipt = try await WebSocketSessionClient.run(
                url: "ws://127.0.0.1:\(port)",
                authorization: "init-cred",
                makeVoucher: { _ in
                    Issue.record("makeVoucher should not be called without a shortfall")
                    return ""
                },
                handlers: .init(
                    onMessage: { messages.append($0) },
                    onReceipt: { receiptRefs.append($0.reference) }
                ),
                logger: Logger(label: "mpp.ws.test")
            )

            #expect(receipt == finalReceipt)
            #expect(messages.values == ["a", "b"])
            #expect(receiptRefs.values == ["0xauth"])
        }
    }
}
