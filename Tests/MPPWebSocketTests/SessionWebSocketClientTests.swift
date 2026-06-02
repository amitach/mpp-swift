import Foundation
import MPPCore
import MPPTempoServer
import Testing
@testable import MPPWebSocket

// Server -> client frame builders (the test plays the server feeding `socket.peerSend`).
private func receiptFrame(_ reference: String) throws -> String {
    try SessionWebSocketFrame.receipt(makeReceipt(reference)).encoded()
}

private func messageFrame(_ text: String) throws -> String {
    try SessionWebSocketFrame.message(text).encoded()
}

private func needVoucherFrame() throws -> String {
    try SessionWebSocketFrame.needVoucher(sampleNeedVoucher).encoded()
}

private func closeReadyFrame(_ reference: String) throws -> String {
    try SessionWebSocketFrame.closeReady(makeReceipt(reference)).encoded()
}

private func errorFrame(status: Int, message: String) throws -> String {
    try SessionWebSocketFrame.error(status: status, message: message).encoded()
}

private let neverVoucher: SessionWebSocketClient.MakeVoucher = { _ in
    Issue.record("makeVoucher should not be called")
    return ""
}

@Suite("SessionWebSocketClient")
struct SessionWebSocketClientTests {
    @Test(
        "sends the initial authorization, surfaces messages + receipts, returns the close receipt"
    )
    func happyPath() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(receiptFrame("0xauth"))
        try socket.peerSend(messageFrame("a"))
        try socket.peerSend(messageFrame("b"))
        try socket.peerSend(closeReadyFrame("0xfinal"))
        let messages = Collector<String>()
        let receipts = Collector<Receipt>()

        let receipt = try await SessionWebSocketClient.run(
            inbound: socket.inbound, writer: socket,
            authorization: "init-cred", makeVoucher: neverVoucher,
            handlers: .init(onMessage: { messages.append($0) }, onReceipt: { receipts.append($0) })
        )

        #expect(receipt == makeReceipt("0xfinal"))
        #expect(socket.sent == [.authorization("init-cred")])
        #expect(messages.values == ["a", "b"])
        #expect(receipts.values == [makeReceipt("0xauth")])
    }

    @Test("answers payment-need-voucher with a fresh authorization voucher and continues")
    func answersNeedVoucher() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(receiptFrame("0xauth"))
        try socket.peerSend(needVoucherFrame())
        try socket.peerSend(messageFrame("x"))
        try socket.peerSend(closeReadyFrame("0xfinal"))
        let seenNeed = Collector<SessionStreamEvent.NeedVoucher>()
        let messages = Collector<String>()

        let receipt = try await SessionWebSocketClient.run(
            inbound: socket.inbound, writer: socket,
            authorization: "init-cred",
            makeVoucher: { need in seenNeed.append(need); return "voucher-cred" },
            handlers: .init(onMessage: { messages.append($0) })
        )

        #expect(receipt == makeReceipt("0xfinal"))
        // Initial auth, then the voucher answering the shortfall, in order.
        #expect(socket.sent == [.authorization("init-cred"), .authorization("voucher-cred")])
        #expect(seenNeed.values == [sampleNeedVoucher])
        #expect(messages.values == ["x"])
    }

    @Test("a payment-error frame throws rejected with the server status and message")
    func paymentError() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(errorFrame(status: 402, message: "payment verification failed"))

        await #expect(throws: SessionWebSocketClient.ClientError.rejected(
            status: 402, message: "payment verification failed"
        )) {
            _ = try await SessionWebSocketClient.run(
                inbound: socket.inbound, writer: socket,
                authorization: "init-cred", makeVoucher: neverVoucher
            )
        }
        #expect(socket.sent == [.authorization("init-cred")])
    }

    @Test("inbound ending before a close-ready throws closedWithoutReceipt")
    func closedWithoutReceipt() async throws {
        let socket = InProcessSocket()
        try socket.peerSend(messageFrame("a"))
        socket.peerFinish()
        let messages = Collector<String>()

        await #expect(throws: SessionWebSocketClient.ClientError.closedWithoutReceipt) {
            _ = try await SessionWebSocketClient.run(
                inbound: socket.inbound, writer: socket,
                authorization: "init-cred", makeVoucher: neverVoucher,
                handlers: .init(onMessage: { messages.append($0) })
            )
        }
        #expect(messages.values == ["a"])
    }
}
