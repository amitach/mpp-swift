import Foundation
import MPPCore
import MPPTempoServer
import Testing
@testable import MPPWebSocket

/// An in-process WebSocket stand-in: the test pushes client->server frames via
/// ``clientSend``, the server's outbound frames land in ``sent``, and a server `close`
/// finishes the inbound stream (as a real transport does), which lets `serve` return.
private final class InProcessSocket: SessionSocketWriter, @unchecked Sendable {
    let inbound: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var closeCodeValue: UInt16?

    init() {
        var captured: AsyncStream<String>.Continuation!
        inbound = AsyncStream { captured = $0 }
        continuation = captured
    }

    /// A client -> server frame.
    func clientSend(_ text: String) {
        continuation.yield(text)
    }

    /// End the inbound stream as if the client hung up without a close handshake.
    func clientFinish() {
        continuation.finish()
    }

    func send(_ text: String) async throws {
        lock.withLock { sentFrames.append(text) }
    }

    func close(code: UInt16, reason _: String) async {
        lock.withLock { if closeCodeValue == nil { closeCodeValue = code } }
        continuation.finish()
    }

    var sent: [SessionWebSocketFrame] {
        lock.withLock { sentFrames.compactMap(SessionWebSocketFrame.parse) }
    }

    var closeCode: UInt16? {
        lock.withLock { closeCodeValue }
    }
}

/// A thread-safe boolean for asserting from inside a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() {
        lock.withLock { raised = true }
    }

    var isRaised: Bool {
        lock.withLock { raised }
    }
}

private func receipt(_ reference: String) -> Receipt {
    // Force-try in a test: the literals are valid, and a throw would fail the test loudly.
    // swiftlint:disable:next force_try
    try! Receipt(
        method: MethodName("tempo"),
        timestamp: RFC3339DateTime("2026-01-02T00:00:00Z"),
        reference: reference
    )
}

private func authFrame() throws -> String {
    try SessionWebSocketFrame.authorization("Payment cred").encoded()
}

private func closeRequestFrame() throws -> String {
    try SessionWebSocketFrame.closeRequest.encoded()
}

private func stream(_ events: [SessionStreamEvent])
    -> AsyncThrowingStream<SessionStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

private let needVoucher = SessionStreamEvent.NeedVoucher(
    channelId: "0xabc", requiredCumulative: "10", acceptedCumulative: "5", deposit: "100"
)

@Suite("SessionWebSocketServer")
struct SessionWebSocketServerTests {
    @Test("open authorization echoes a payment-receipt, streams messages, ends with close-ready")
    func happyPath() async throws {
        let socket = InProcessSocket()
        try socket.clientSend(authFrame())
        let events: [SessionStreamEvent] = [
            .message("a"),
            .message("b"),
            .receipt(receipt("0xfinal")),
        ]
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: receipt("0xauth"), kind: .stream) },
            makeStream: { stream(events) },
            closeReceipt: { receipt("0xclose") }
        )

        #expect(socket.sent == [
            .receipt(receipt("0xauth")),
            .message("a"),
            .message("b"),
            .closeReady(receipt("0xfinal")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test("a mid-stream shortfall emits payment-need-voucher before the next chunk")
    func needVoucherFrame() async throws {
        let socket = InProcessSocket()
        try socket.clientSend(authFrame())
        let events: [SessionStreamEvent] = [
            .needVoucher(needVoucher),
            .message("x"),
            .receipt(receipt("0xf")),
        ]
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: receipt("0xauth"), kind: .stream) },
            makeStream: { stream(events) },
            closeReceipt: { receipt("0xclose") }
        )

        #expect(socket.sent == [
            .receipt(receipt("0xauth")),
            .needVoucher(needVoucher),
            .message("x"),
            .closeReady(receipt("0xf")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test("a close-action credential acknowledges the receipt and closes without streaming")
    func closeAction() async throws {
        let socket = InProcessSocket()
        try socket.clientSend(authFrame())
        let streamed = Flag()
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: receipt("0xclose"), kind: .close) },
            makeStream: { streamed.raise(); return stream([]) },
            closeReceipt: { receipt("0xclose") }
        )

        #expect(socket.sent == [.receipt(receipt("0xclose"))])
        #expect(socket.closeCode == 1000)
        #expect(streamed.isRaised == false)
    }

    @Test("a rejected credential emits payment-error with the status and closes 1008")
    func rejectedCredential() async throws {
        let socket = InProcessSocket()
        try socket.clientSend(authFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in
                throw SessionRejected(status: 402, message: "payment verification failed")
            },
            makeStream: { stream([]) },
            closeReceipt: { receipt("0xclose") }
        )

        #expect(socket.sent == [.error(status: 402, message: "payment verification failed")])
        #expect(socket.closeCode == 1008)
    }

    @Test("a client close-request stops the stream and sends a close-ready receipt")
    func clientCloseRequest() async throws {
        let socket = InProcessSocket()
        // A stream that blocks (never finishes) until the close-request cancels it; the
        // retained continuation keeps it from auto-finishing.
        var blockingContinuation: AsyncThrowingStream<SessionStreamEvent, any Error>.Continuation!
        let blocking = AsyncThrowingStream<SessionStreamEvent, any Error> {
            blockingContinuation = $0
        }

        try socket.clientSend(authFrame())
        try socket.clientSend(closeRequestFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: receipt("0xauth"), kind: .stream) },
            makeStream: { blocking },
            closeReceipt: { receipt("0xready") }
        )
        // Keep the continuation alive across serve so the stream stays blocked (never
        // auto-finishes) until the close-request cancels it.
        _ = blockingContinuation

        #expect(socket.sent == [.receipt(receipt("0xauth")), .closeReady(receipt("0xready"))])
        #expect(socket.closeCode == 1000)
    }

    @Test("a topUp acknowledges the receipt without streaming or closing")
    func topUpAck() async throws {
        let socket = InProcessSocket()
        try socket.clientSend(authFrame())
        socket.clientFinish() // no close from the topUp; end inbound so serve returns
        let streamed = Flag()
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: receipt("0xtopup"), kind: .ack) },
            makeStream: { streamed.raise(); return stream([]) },
            closeReceipt: { receipt("0xclose") }
        )

        #expect(socket.sent == [.receipt(receipt("0xtopup"))])
        #expect(streamed.isRaised == false)
        // serve's shutdown closes the still-open socket when inbound ends.
        #expect(socket.closeCode == 1000)
    }
}
