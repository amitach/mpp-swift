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

    @Test(
        "close-request cancelling a stream that finishes-throwing emits close-ready, not an error"
    )
    func closeRequestCancelsThrowingStream() async throws {
        let socket = InProcessSocket()
        // Production shape: SessionStream.serve finishes by THROWING CancellationError on cancel
        // (its poll loop is cancelled), not by returning a clean nil. This stream models that - it
        // never yields, and on termination (the close-request cancels the consuming task) it
        // finishes throwing. The guarantee being pinned: consumer-cancellation wins, so the stream
        // task does NOT take its catch -> failStream path (no spurious payment-error / close 1011);
        // the close-request handshake owns the single payment-close-ready + normal close.
        let throwingOnCancel = AsyncThrowingStream<SessionStreamEvent, any Error> { continuation in
            continuation.onTermination = { _ in continuation.finish(throwing: CancellationError()) }
        }

        try socket.peerSend(authFrame())
        try socket.peerSend(closeRequestFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { throwingOnCancel },
            closeReceipt: { makeReceipt("0xready") }
        )

        // Exactly the auth receipt then one close-ready (no payment-error frame, no double close).
        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .closeReady(makeReceipt("0xready")),
        ])
        #expect(socket.closeCode == 1000)
    }

    @Test(
        "a genuine stream error (not a cancellation) still fails closed with payment-error + 1011"
    )
    func genuineStreamErrorFailsClosed() async throws {
        let socket = InProcessSocket()
        // The companion to closeRequestCancelsThrowingStream: a stream that finishes-throwing a
        // NON-cancellation error while the task is NOT cancelled (no close-request). This proves
        // the
        // `if Task.isCancelled { return }` guard in startStream's catch does not OVER-swallow: a
        // real
        // failure must still surface as payment-error(500) + close 1011 (the failStream path).
        struct StreamFailure: Error {}
        let failing = AsyncThrowingStream<SessionStreamEvent, any Error> { continuation in
            continuation.finish(throwing: StreamFailure())
        }

        try socket.peerSend(authFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { failing },
            closeReceipt: { makeReceipt("0xclose") }
        )

        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .error(status: 500, message: "websocket session failed"),
        ])
        #expect(socket.closeCode == 1011)
    }

    @Test("a close-request whose receipt snapshot fails surfaces payment-error + 1011")
    func closeRequestReceiptFailureFailsClosed() async throws {
        struct CloseReceiptFailure: Error {}
        let socket = InProcessSocket()
        // The close-request cancels a (production-shaped, finish-throwing-on-cancel) stream, then
        // the closeReceipt snapshot THROWS. The handshake must fail closed: not a silent close 1000
        // with no close-ready (indistinguishable from a clean settled close), but payment-error +
        // close 1011. Guards against the prior `try?` that silently swallowed the failure.
        let throwingOnCancel = AsyncThrowingStream<SessionStreamEvent, any Error> { continuation in
            continuation.onTermination = { _ in continuation.finish(throwing: CancellationError()) }
        }

        try socket.peerSend(authFrame())
        try socket.peerSend(closeRequestFrame())
        await SessionWebSocketServer.serve(
            inbound: socket.inbound, writer: socket,
            verify: { _ in SessionAuthorization(receipt: makeReceipt("0xauth"), kind: .stream) },
            makeStream: { throwingOnCancel },
            closeReceipt: { throw CloseReceiptFailure() }
        )

        #expect(socket.sent == [
            .receipt(makeReceipt("0xauth")),
            .error(status: 500, message: "close failed"),
        ])
        #expect(socket.closeCode == 1011)
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
