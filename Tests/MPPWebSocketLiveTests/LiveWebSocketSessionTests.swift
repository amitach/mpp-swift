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

@Suite("MPPWebSocketLive")
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
            let result = try await runSessionWithRetry(port: port)
            #expect(result.receipt == finalReceipt)
            #expect(result.messages == ["a", "b"])
            #expect(result.receiptRefs == ["0xauth"])
        }
    }
}

/// The collected result of one client session.
private struct SessionResult {
    let receipt: Receipt
    let messages: [String]
    let receiptRefs: [String]
}

/// Runs the client session, retrying only a transport-level connect race: a live socket can
/// transiently refuse a connection right at server-ready under the heavy parallel load of the
/// full test run. A session-level `ClientError` is a real failure and is never retried. Fresh
/// collectors per attempt, so a retried run never double-counts messages or receipts.
private func runSessionWithRetry(port: Int, attempts: Int = 5) async throws -> SessionResult {
    var lastError: (any Error)?
    for attempt in 1 ... attempts {
        let messages = StringBox()
        let receiptRefs = StringBox()
        do {
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
            return SessionResult(
                receipt: receipt, messages: messages.values, receiptRefs: receiptRefs.values
            )
        } catch let error as SessionWebSocketClient.ClientError {
            throw error // a session-level failure is real, never a flaky connect
        } catch {
            lastError = error
            if attempt < attempts { try? await Task.sleep(for: .milliseconds(150)) }
        }
    }
    throw lastError ?? SessionWebSocketClient.ClientError.closedWithoutReceipt
}
