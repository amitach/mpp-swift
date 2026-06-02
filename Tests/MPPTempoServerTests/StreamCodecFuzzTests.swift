import Foundation
import MPPCore
import MPPTempoServer
import Testing

// Fuzz floor for the metered-session stream codecs that parse untrusted wire
// bytes: the SSE block parser (`SessionStreamEvent.parse`) and the WebSocket JSON
// frame parser (`SessionWebSocketFrame.parse`). Both return `nil` (non-throwing),
// so the fuzz target is no-trap + nil-or-valid, plus a stress round-trip corpus.
//
// Scope note (WS-15 fork, documented): the reference SDK also fuzzes a streaming
// chunk-reassembler (`iterateData`) for chunk-boundary invariance. mpp-swift has
// no such layer: URLSession/hummingbird own wire framing, and WS text frames and
// SSE blocks reach our code whole, so that category has no target here and is
// deliberately not ported (no transport code is added merely to create one). We
// fuzz the block-level parsers we actually own.
//
// Curated-deterministic corpus (the RLPTests idiom), not random property testing.

private let controlChars = String(String
    .UnicodeScalarView((0 ... 0x1F).map { Unicode.Scalar(UInt8($0)) }))

private func method() throws -> MethodName {
    try MethodName("tempo")
}

private func timestamp() throws -> RFC3339DateTime {
    try RFC3339DateTime("2030-01-01T00:00:00Z")
}

// MARK: - SSE blocks

@Suite("SSE codec fuzz")
struct SSEFuzzTests {
    static let adversarialBlocks: [String] = {
        var corpus: [String] = [
            "", "\n", "\n\n", "\r", "\r\n",
            "data:", "event:", "data: hi", "event: message", "event:message\ndata:hi",
            "event: message\ndata: hi",
            "event: unknown\ndata: x",
            "event: payment-receipt\ndata: not json",
            "event: payment-receipt\ndata: {",
            "event: payment-need-voucher\ndata: {\"channelId\":1}", // wrong-typed field
            "data: a: b: c", // colons in value
            "event: 🔥\ndata: ☃",
            "event: message\ndata: 🔥☃ café",
            // control bytes in the payload
            "event: message\ndata: " + controlChars,
        ]
        // mixed line terminators (\r\n, lone \r) must fold without trapping
        corpus.append("event: message\r\ndata: a\r\ndata: b\r\n\r\n")
        corpus.append("event: message\rdata: a\rdata: b\r\r")
        // many data lines / large block
        corpus.append("event: message\n" + String(repeating: "data: x\n", count: 5000))
        return corpus
    }()

    @Test("SSE parse never traps; an accepted message round-trips", arguments: adversarialBlocks)
    func neverTraps(_ block: String) throws {
        guard let event = SessionStreamEvent.parse(block) else { return }
        // A parsed message is already line-folded, so it must re-encode and
        // re-parse to itself. (needVoucher/receipt re-encode is covered below.)
        if case .message = event {
            #expect(try SessionStreamEvent.parse(event.sseEncoded()) == event)
        }
    }

    @Test("SSE message events round-trip for newline-only payloads", arguments: [
        "", "hello", "line1\nline2\nline3", "\n\n\n", "trailing\n", "\nleading",
        "café ☃ 🔥", "data: looks like a field", "event: also looks like a field",
        String(repeating: "x", count: 10000),
    ])
    func messageRoundTrip(_ text: String) throws {
        let event = SessionStreamEvent.message(text)
        #expect(try SessionStreamEvent.parse(event.sseEncoded()) == .message(text))
    }

    @Test("SSE folds CR and CRLF terminators to LF on parse")
    func folding() {
        // A producer using \r\n or a lone \r must parse identically to the \n form
        // (WHATWG EventSource line folding), so all three yield the same message.
        let lfForm = SessionStreamEvent.parse("event: message\ndata: a\ndata: b\n\n")
        #expect(lfForm == .message("a\nb"))
        #expect(SessionStreamEvent.parse("event: message\r\ndata: a\r\ndata: b\r\n\r\n") == lfForm)
        #expect(SessionStreamEvent.parse("event: message\rdata: a\rdata: b\r\r") == lfForm)
    }

    @Test("SSE JSON events (needVoucher, receipt) round-trip")
    func jsonEventsRoundTrip() throws {
        let needVoucher = SessionStreamEvent.needVoucher(.init(
            channelId: "0x1", requiredCumulative: "100", acceptedCumulative: "50", deposit: "1000"
        ))
        #expect(try SessionStreamEvent.parse(needVoucher.sseEncoded()) == needVoucher)

        let receipt = try SessionStreamEvent.receipt(Receipt(
            method: method(), timestamp: timestamp(), reference: "0xabc"
        ))
        #expect(try SessionStreamEvent.parse(receipt.sseEncoded()) == receipt)
    }
}

// MARK: - WebSocket frames

@Suite("WebSocket frame codec fuzz")
struct WebSocketFrameFuzzTests {
    static let adversarialFrames: [String] = {
        var corpus: [String] = [
            "", " ", "{}", "[]", "null", "12", "\"x\"", "not json", "🔥",
            // discriminator present but wrong type / unknown
            "{\"mpp\":123}", "{\"mpp\":null}", "{\"mpp\":[]}", "{\"mpp\":\"unknown-tag\"}",
            // known tag, missing or wrong-typed payload
            "{\"mpp\":\"message\"}",
            "{\"mpp\":\"message\",\"data\":123}",
            "{\"mpp\":\"payment-receipt\",\"data\":{}}",
            "{\"mpp\":\"payment-error\",\"status\":\"x\",\"message\":\"m\"}",
            "{\"mpp\":\"authorization\"}",
            // a NUL inside a JSON string is invalid JSON -> must reject, not trap
            "{\"mpp\":\"message\",\"data\":\"\u{0}\"}",
        ]
        // deeply nested JSON: rejected by Foundation's nesting cap, never traps
        corpus.append(String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000))
        return corpus
    }()

    @Test("WS frame parse never traps; accepted frames round-trip", arguments: adversarialFrames)
    func neverTraps(_ json: String) throws {
        guard let frame = SessionWebSocketFrame.parse(json) else { return }
        #expect(try SessionWebSocketFrame.parse(frame.encoded()) == frame)
    }

    @Test("WS frames round-trip at value extremes")
    func roundTripExtremes() throws {
        let receipt = try Receipt(method: method(), timestamp: timestamp(), reference: "r")
        let frames: [SessionWebSocketFrame] = [
            .authorization(""),
            .authorization(String(repeating: "P", count: 10000)),
            .message(""),
            .message("café ☃ 🔥\nmulti\nline"),
            .needVoucher(.init(
                channelId: "0x1", requiredCumulative: "1", acceptedCumulative: "0", deposit: "9"
            )),
            .receipt(receipt),
            .closeRequest,
            .closeReady(receipt),
            .error(status: Int.min, message: ""),
            .error(status: Int.max, message: "boom"),
            .error(status: -1, message: "negative"),
        ]
        for frame in frames {
            #expect(try SessionWebSocketFrame.parse(frame.encoded()) == frame)
        }
    }
}
