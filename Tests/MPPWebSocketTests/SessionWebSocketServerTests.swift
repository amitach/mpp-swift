import Foundation
import MPPCore
import MPPTempoServer
import Testing
@testable import MPPWebSocket

// The in-process socket, `Flag`, `makeReceipt`, and `sampleNeedVoucher` live in
// WebSocketTestSupport.swift (shared with the client suite). These helpers are
// server-specific.

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

@Suite("SessionWebSocketServer")
struct SessionWebSocketServerTests {
    @Test("open authorization echoes a payment-receipt, streams messages, ends with close-ready")
    func happyPath() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(authFrame())
        let events: [SessionStreamEvent] = [
            .message("a"),
            .message("b"),
            .receipt(makeReceipt("0xfinal")),
        ]
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { stream(events) },
            closeReceipt: { makeReceipt("0xclose") }
        )

        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .message("a"),
            .message("b"),
            .closeReady(makeReceipt("0xfinal")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test("a mid-stream shortfall emits payment-need-voucher before the next chunk")
    func needVoucherFrame() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(authFrame())
        let events: [SessionStreamEvent] = [
            .needVoucher(sampleNeedVoucher),
            .message("x"),
            .receipt(makeReceipt("0xf")),
        ]
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { stream(events) },
            closeReceipt: { makeReceipt("0xclose") }
        )

        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .needVoucher(sampleNeedVoucher),
            .message("x"),
            .closeReady(makeReceipt("0xf")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test("a close-action credential acknowledges the receipt and closes without streaming")
    func closeAction() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(authFrame())
        let streamed = Flag()
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xclose"), kind: .close) },
            makeStream: { streamed.raise(); return stream([]) },
            closeReceipt: { makeReceipt("0xclose") }
        )

        #expect(socket.sent == [.receipt(makeReceipt("0xclose"))])
        #expect(socket.closeCode == 1000)
        #expect(streamed.isRaised == false)
    }

    @Test("a rejected credential emits payment-error with the status and closes 1008")
    func rejectedCredential() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(authFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in
                throw SessionRejected(status: 402, message: "payment verification failed")
            },
            makeStream: { stream([]) },
            closeReceipt: { makeReceipt("0xclose") }
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

        try socket.peerSend(authFrame())
        try socket.peerSend(closeRequestFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { blocking },
            closeReceipt: { makeReceipt("0xready") }
        )
        // Keep the continuation alive across serve so the stream stays blocked (never
        // auto-finishes) until the close-request cancels it.
        _ = blockingContinuation

        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .closeReady(makeReceipt("0xready")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test("a topUp acknowledges the receipt without streaming or closing")
    func topUpAck() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(authFrame())
        socket.peerFinish() // no close from the topUp; end inbound so serve returns
        let streamed = Flag()
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xtopup"), kind: .ack) },
            makeStream: { streamed.raise(); return stream([]) },
            closeReceipt: { makeReceipt("0xclose") }
        )

        #expect(socket.sent == [.receipt(makeReceipt("0xtopup"))])
        #expect(streamed.isRaised == false)
        // serve's shutdown closes the still-open socket when inbound ends.
        #expect(socket.closeCode == 1000)
    }
}
