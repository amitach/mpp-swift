import Foundation
import MPPCore
import MPPTempoServer
import Testing

@Suite("SessionWebSocketFrame")
struct SessionWebSocketFrameTests {
    private static let now = Date(timeIntervalSince1970: 1_767_312_000)

    private func tempo() throws -> MethodName {
        try MethodName("tempo")
    }

    private func receipt() throws -> Receipt {
        try Receipt(
            method: tempo(),
            timestamp: RFC3339DateTime(date: Self.now),
            reference: "0xabcd"
        )
    }

    @Test("every frame type round-trips through its JSON form")
    func roundTrip() throws {
        let need = SessionStreamEvent.NeedVoucher(
            channelId: "0xabcd", requiredCumulative: "30", acceptedCumulative: "20", deposit: "1000"
        )
        let frames: [SessionWebSocketFrame] = try [
            .authorization("Payment abc.def"),
            .message("hello\nworld"),
            .needVoucher(need),
            .receipt(receipt()),
            .closeRequest,
            .closeReady(receipt()),
            .error(status: 402, message: "payment required"),
        ]
        for frame in frames {
            #expect(try SessionWebSocketFrame.parse(frame.encoded()) == frame)
        }
    }

    @Test("the frame carries its mpp discriminator on the wire")
    func discriminator() throws {
        #expect(try SessionWebSocketFrame.message("x").encoded().contains("\"mpp\":\"message\""))
        #expect(try SessionWebSocketFrame.closeRequest.encoded()
            == "{\"mpp\":\"payment-close-request\"}")
        let authJSON = try SessionWebSocketFrame.authorization("Payment z").encoded()
        #expect(authJSON.contains("\"authorization\":\"Payment z\""))
    }

    @Test("a metered stream event lifts into its outbound frame")
    func liftsStreamEvent() throws {
        #expect(SessionWebSocketFrame(.message("hi")) == .message("hi"))
        let need = SessionStreamEvent.NeedVoucher(
            channelId: "0xabcd", requiredCumulative: "30", acceptedCumulative: "20", deposit: "1000"
        )
        #expect(SessionWebSocketFrame(.needVoucher(need)) == .needVoucher(need))
        #expect(try SessionWebSocketFrame(.receipt(receipt())) == .receipt(receipt()))
    }

    @Test("an unknown discriminator and malformed JSON parse to nil")
    func rejectsUnknownOrMalformed() {
        #expect(SessionWebSocketFrame.parse("{\"mpp\":\"nope\"}") == nil)
        #expect(SessionWebSocketFrame.parse("not json") == nil)
        // A known tag with a missing required field is malformed.
        #expect(SessionWebSocketFrame.parse("{\"mpp\":\"payment-error\"}") == nil)
    }
}
