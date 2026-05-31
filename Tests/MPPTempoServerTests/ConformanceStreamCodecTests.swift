import Foundation
import MPPTempoServer
import Testing

// Cross-SDK codec conformance for the metered-streaming wire forms: our parsers accept
// the EXACT bytes the reference mppx SDK's own formatters emit. The golden vectors below
// were captured by running mppx's `session/Sse.js` and `session/Ws.js` formatters
// (formatMessageEvent / formatNeedVoucherEvent / formatAuthorizationMessage / ...). The
// reverse direction (mppx's parsers accept OUR output) was verified directly against the
// same mppx parsers (`Sse.parseEvent` / `Ws.parseMessage`); this hermetic suite pins the
// our-parse-their-bytes direction so a future codec drift is caught without a live peer.
//
// These are reference-SDK wire bytes, not a re-derivation of our own encoder, so they
// guard interop rather than merely round-tripping our own format.
@Suite("Cross-SDK stream codec conformance")
struct ConformanceStreamCodecTests {
    // MARK: SSE (mppx session/Sse.js formatters)

    @Test("our SSE parser accepts mppx's message event (one data line per line)")
    func sseMessageFromMppx() {
        // mppx formatMessageEvent("hi\nthere")
        let golden = "event: message\ndata: hi\ndata: there\n\n"
        #expect(SessionStreamEvent.parse(golden) == .message("hi\nthere"))
    }

    @Test("our SSE parser accepts mppx's payment-need-voucher event")
    func sseNeedVoucherFromMppx() {
        // mppx formatNeedVoucherEvent({channelId, requiredCumulative, acceptedCumulative, deposit})
        let golden = "event: payment-need-voucher\n"
            + #"data: {"channelId":"0xabcd","requiredCumulative":"30","#
            + #""acceptedCumulative":"20","deposit":"1000"}"# + "\n\n"
        #expect(SessionStreamEvent.parse(golden) == .needVoucher(.init(
            channelId: "0xabcd", requiredCumulative: "30", acceptedCumulative: "20", deposit: "1000"
        )))
    }

    // MARK: WebSocket (mppx session/Ws.js formatters)

    @Test("our WS parser accepts every mppx frame the reference formatters emit")
    func wsFramesFromMppx() {
        // Each string is the verbatim output of the corresponding mppx Ws.js formatter.
        #expect(SessionWebSocketFrame
            .parse(#"{"mpp":"authorization","authorization":"Payment abc"}"#)
            == .authorization("Payment abc"))
        #expect(SessionWebSocketFrame.parse(#"{"mpp":"message","data":"hi"}"#) == .message("hi"))
        #expect(SessionWebSocketFrame.parse(#"{"mpp":"payment-close-request"}"#) == .closeRequest)
        #expect(SessionWebSocketFrame.parse(#"{"mpp":"payment-error","message":"x","status":402}"#)
            == .error(status: 402, message: "x"))
        let needVoucher = #"{"mpp":"payment-need-voucher","data":{"channelId":"0xabcd","#
            + #""requiredCumulative":"30","acceptedCumulative":"20","deposit":"1000"}}"#
        #expect(SessionWebSocketFrame.parse(needVoucher) == .needVoucher(.init(
            channelId: "0xabcd", requiredCumulative: "30", acceptedCumulative: "20", deposit: "1000"
        )))
    }

    @Test("mppx's field order does not affect our WS decode")
    func wsFieldOrderIndependent() {
        // mppx emits payment-error as {mpp, message, status}; our struct is {mpp, status, message}.
        // JSON decode is order-independent, so both parse identically.
        #expect(SessionWebSocketFrame.parse(#"{"mpp":"payment-error","status":402,"message":"x"}"#)
            == .error(status: 402, message: "x"))
    }
}
